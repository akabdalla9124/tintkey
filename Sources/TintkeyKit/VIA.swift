import Foundation
import IOKit
import IOKit.hid

/// Minimal read-only VIA protocol client (command ids from the VIA spec).
public final class VIAClient {
    public enum Command: UInt8 {
        case getProtocolVersion = 0x01
        case lightingSetValue = 0x07
        case lightingGetValue = 0x08
    }
    /// VIA lighting channels / value ids (QMK `via.h`).
    public enum Channel: UInt8 { case backlight = 1, rgblight = 2, rgbMatrix = 3, audio = 4, ledMatrix = 5 }
    public enum Value: UInt8 { case brightness = 1, effect = 2, effectSpeed = 3, color = 4 }

    private let device: IOHIDDevice
    private let mailbox: Mailbox

    public init(_ info: HIDDeviceInfo) {
        self.device = info.device
        self.mailbox = Mailbox.shared(for: info.device)
    }

    /// Per-device callback target and report buffer. IOKit may keep delivering to a registration after we
    /// think we removed it (and to every opener of the device), so the context and buffer handed to it must
    /// never be freed: mailboxes are immortal (one per device, retained by the registry), and a late or
    /// duplicate callback just appends to a list nobody is waiting on.
    final class Mailbox {
        let device: IOHIDDevice
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: RawHID.reportSize)
        let requestLock = NSLock()   // serializes whole requests (one in-flight per device in this process)
        private let repliesLock = NSLock()
        private var replies: [[UInt8]] = []
        private static let registryLock = NSLock()
        nonisolated(unsafe) private static var registry: [UInt: Mailbox] = [:]

        private init(_ device: IOHIDDevice) {
            self.device = device
            buffer.initialize(repeating: 0, count: RawHID.reportSize)
        }

        static func shared(for device: IOHIDDevice) -> Mailbox {
            registryLock.lock(); defer { registryLock.unlock() }
            let key = UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque())
            if let m = registry[key] { return m }
            let m = Mailbox(device)
            registry[key] = m
            return m
        }

        func append(_ r: [UInt8]) { repliesLock.lock(); replies.append(r); repliesLock.unlock() }
        func clear() { repliesLock.lock(); replies.removeAll(); repliesLock.unlock() }
        func firstMatch(for request: [UInt8]) -> [UInt8]? {
            repliesLock.lock(); defer { repliesLock.unlock() }
            return replies.first { VIAClient.matches(request: request, reply: $0) }
        }
    }

    /// Pads/truncates a request to the fixed 32-byte report (no leading report-id byte; id 0 is implicit).
    static func packet(_ bytes: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: RawHID.reportSize)
        for (i, b) in bytes.prefix(RawHID.reportSize).enumerated() { out[i] = b }
        return out
    }

    /// VIA echoes the command id, and for lighting get/set also the channel and value id, before any data.
    /// A reply only answers a request if those echoed bytes match, so stale replies are ignored.
    static func matches(request: [UInt8], reply: [UInt8]) -> Bool {
        // Keychron's 0xA0-0xA2 queries echo only the command; 0xA8 (Keychron RGB) echoes command + subcommand.
        let n: Int
        switch request.first {
        case .some(Command.getProtocolVersion.rawValue), .some(0xA0), .some(0xA1), .some(0xA2): n = 1
        case .some(0xA8): n = 2
        case .some: n = 3
        case .none: n = 0
        }
        guard n > 0, request.count >= n, reply.count >= n else { return false }
        return Array(request.prefix(n)) == Array(reply.prefix(n))
    }

    /// Sends one 32-byte request and waits up to `timeout` seconds for the matching reply.
    public func request(_ bytes: [UInt8], timeout: TimeInterval = 1.0) -> [UInt8]? {
        mailbox.requestLock.lock(); defer { mailbox.requestLock.unlock() }
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return nil }
        let mode = CFRunLoopMode.defaultMode.rawValue
        let loop: CFRunLoop = CFRunLoopGetCurrent()!
        let ctx = Unmanaged.passUnretained(mailbox).toOpaque()   // immortal, see Mailbox
        let buf = mailbox.buffer
        defer {
            // Unregister (same context) before unscheduling/closing.
            IOHIDDeviceRegisterInputReportCallback(device, buf, RawHID.reportSize, nil, ctx)
            IOHIDDeviceUnscheduleFromRunLoop(device, loop, mode)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }

        mailbox.clear()
        IOHIDDeviceScheduleWithRunLoop(device, loop, mode)
        IOHIDDeviceRegisterInputReportCallback(device, buf, RawHID.reportSize, { ctx, _, _, _, _, report, length in
            guard let ctx = ctx, length > 0 else { return }
            let box = Unmanaged<Mailbox>.fromOpaque(ctx).takeUnretainedValue()
            // Raw HID uses no report ids, but if one is prefixed keep only the trailing 32 payload bytes.
            let all = Array(UnsafeBufferPointer(start: report, count: length))
            box.append(all.count > RawHID.reportSize ? Array(all.suffix(RawHID.reportSize)) : all)
        }, ctx)

        let out = VIAClient.packet(bytes)
        // Report ID 0: the payload must not include a leading report-id byte.
        guard IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, out, out.count) == kIOReturnSuccess else { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let hit = mailbox.firstMatch(for: out) { return hit }
            CFRunLoopRunInMode(.defaultMode, 0.05, true)
        }
        return mailbox.firstMatch(for: out)
    }

    public func protocolVersion() -> Int? {
        guard let r = request([Command.getProtocolVersion.rawValue]), r.count >= 3, r[0] == 0x01 else { return nil }
        return Int(r[1]) << 8 | Int(r[2])
    }

    public func lighting(_ channel: Channel, _ value: Value) -> [UInt8]? {
        // Reply layout: [cmd, channel, value id, data...]; `request` already verified the first three echo ours.
        guard let r = request([Command.lightingGetValue.rawValue, channel.rawValue, value.rawValue]),
              r.count >= 5 else { return nil }
        return Array(r[3...].prefix(2))
    }

    /// Sets the color on a lighting channel (VIA `lighting_set_value`, value id 4: hue, saturation, both 0-255).
    /// This is the live, non-persistent setter; it never sends VIA's save command, so no EEPROM write.
    /// Returns the values read back from the keyboard afterwards, or nil if the write wasn't acknowledged.
    @discardableResult
    public func setColor(_ channel: Channel, hue: UInt8, saturation: UInt8) -> (hue: UInt8, sat: UInt8)? {
        guard request([Command.lightingSetValue.rawValue, channel.rawValue, Value.color.rawValue, hue, saturation]) != nil else { return nil }
        guard let now = lighting(channel, .color), now.count >= 2 else { return nil }
        return (now[0], now[1])
    }

    /// Fire-and-check setter for one lighting value (no readback), cheap enough for animation steps.
    /// Non-persistent like `setColor`: it never sends VIA's save command.
    @discardableResult
    public func setValue(_ channel: Channel, _ value: Value, _ data: [UInt8]) -> Bool {
        request([Command.lightingSetValue.rawValue, channel.rawValue, value.rawValue] + data) != nil
    }

    @discardableResult
    public func setBrightness(_ channel: Channel, _ level: UInt8) -> Bool { setValue(channel, .brightness, [level]) }
}
