import Foundation
import IOKit
import IOKit.hid

// Read-only access to the stock-firmware Glorious GMMK PRO (VID 0x320F).
//
// Protocol facts come from MechNoxer/Open-Glorious-Core (MIT), commit 425b2ef,
// src/open_glorious_core/backend.py, class StockGmmkProBackend: HID FEATURE reports, report ID 7,
// 256 bytes including the ID byte, on the interface whose report descriptor starts
// 06 01 FF 09 01 A1 01 85 07. The reference has no checksum; a read is
// SetReport([7, 129, profile, layer, 0...]) followed by GetReport(7).
//
// SAFETY: this file is deliberately an allowlist. The only packet builder is the cmd-129 read
// request. Commands 1 (profile update), 2 (effect) and 7 (properties) are NOT representable here,
// and the only call to IOHIDDeviceSetReport takes a `GloriousReadRequest`, whose initializer is
// the only way to produce a packet.

public enum GloriousStock {
    public static let vendorID = 0x320F
    public static let controlUsagePage = 0xFF01
    public static let controlUsage = 1
    public static let reportID: UInt8 = 7
    public static let reportLength = 256
    /// Descriptor prefix the reference uses to identify the control interface.
    public static let descriptorPrefix: [UInt8] = [0x06, 0x01, 0xFF, 0x09, 0x01, 0xA1, 0x01, 0x85, 0x07]
}

/// The complete set of commands this type can send. One case, on purpose.
public enum GloriousReadCommand: UInt8, CaseIterable {
    case readState = 129
}

/// A cmd-129 read request. Cannot carry any other command.
public struct GloriousReadRequest {
    public let bytes: [UInt8]

    /// The only packet builder. Layout (reference `_make_request(129)`): [7, 129, profile, layer, 0 ...].
    public init(profile: UInt8 = 1, layer: UInt8 = 1) {
        var b = [UInt8](repeating: 0, count: GloriousStock.reportLength)
        b[0] = GloriousStock.reportID
        b[1] = GloriousReadCommand.readState.rawValue
        b[2] = profile
        b[3] = layer
        bytes = b
    }
}

public struct GloriousInterfaceInfo {
    public let device: IOHIDDevice
    public let productID: Int
    public let product: String
    public let usagePage: Int
    public let usage: Int
    public let locationID: Int
    public let descriptor: [UInt8]
    public let maxInputReportSize: Int
    public let maxOutputReportSize: Int
    public let maxFeatureReportSize: Int

    public var isControlInterface: Bool {
        usagePage == GloriousStock.controlUsagePage && usage == GloriousStock.controlUsage
    }
    public var descriptorMatchesReference: Bool { descriptor.starts(with: GloriousStock.descriptorPrefix) }
}

public enum GloriousError: Error, CustomStringConvertible {
    case openFailed(IOReturn)
    case setReportFailed(IOReturn)
    case getReportFailed(IOReturn)
    case timeout(String)

    public var description: String {
        func hex(_ r: IOReturn) -> String { "0x" + String(UInt32(bitPattern: r), radix: 16) }
        switch self {
        case .openFailed(let r): return "IOHIDDeviceOpen failed \(hex(r))"
        case .setReportFailed(let r): return "IOHIDDeviceSetReport (cmd 129 request) failed \(hex(r))"
        case .getReportFailed(let r): return "IOHIDDeviceGetReport failed \(hex(r))"
        case .timeout(let s): return "timed out: \(s)"
        }
    }
}

public enum GloriousProbe {
    private static func prop<T>(_ d: IOHIDDevice, _ key: String) -> T? {
        IOHIDDeviceGetProperty(d, key as CFString) as? T
    }

    /// Lists every HID interface of VID 0x320F. Only reads IOKit properties; opens nothing.
    public static func interfaces() -> [GloriousInterfaceInfo] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: GloriousStock.vendorID] as CFDictionary)
        // Copying devices does not require opening the manager (and so avoids Input Monitoring).
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return set.map { d in
            let desc: [UInt8] = (prop(d, kIOHIDReportDescriptorKey) as Data?).map { [UInt8]($0) } ?? []
            return GloriousInterfaceInfo(
                device: d,
                productID: prop(d, kIOHIDProductIDKey) ?? 0,
                product: prop(d, kIOHIDProductKey) ?? "?",
                usagePage: prop(d, kIOHIDPrimaryUsagePageKey) ?? 0,
                usage: prop(d, kIOHIDPrimaryUsageKey) ?? 0,
                locationID: prop(d, kIOHIDLocationIDKey) ?? 0,
                descriptor: desc,
                maxInputReportSize: prop(d, kIOHIDMaxInputReportSizeKey) ?? 0,
                maxOutputReportSize: prop(d, kIOHIDMaxOutputReportSizeKey) ?? 0,
                maxFeatureReportSize: prop(d, kIOHIDMaxFeatureReportSizeKey) ?? 0)
        }
        .sorted { ($0.productID, $0.usagePage, $0.usage) < ($1.productID, $1.usagePage, $1.usage) }
    }

    public static func controlInterface() -> GloriousInterfaceInfo? {
        interfaces().first(where: \.isControlInterface)
    }
}

/// Read-only handle on the 0xFF01/1 interface. Its only operation is `readState`.
public final class GloriousReadOnlyDevice {
    private let info: GloriousInterfaceInfo
    public init(_ info: GloriousInterfaceInfo) { self.info = info }

    /// SetReport(feature, 7, cmd-129 request) then GetReport(feature, 7), as the reference does.
    /// Returns the raw 256-byte buffer as delivered by IOKit.
    public func readState(request: GloriousReadRequest = GloriousReadRequest(), timeout: TimeInterval = 5) throws -> [UInt8] {
        let dev = info.device
        let r = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else { throw GloriousError.openFailed(r) }
        defer { IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone)) }

        // Run on a worker so a stuck control transfer cannot hang the probe.
        let sem = DispatchSemaphore(value: 0)
        var result: Result<[UInt8], GloriousError> = .failure(.timeout("no response"))
        DispatchQueue.global().async {
            let req = request.bytes
            let s = req.withUnsafeBufferPointer {
                IOHIDDeviceSetReport(dev, kIOHIDReportTypeFeature, CFIndex(GloriousStock.reportID), $0.baseAddress!, $0.count)
            }
            guard s == kIOReturnSuccess else { result = .failure(.setReportFailed(s)); sem.signal(); return }
            var buf = [UInt8](repeating: 0, count: GloriousStock.reportLength)
            buf[0] = GloriousStock.reportID
            var len = CFIndex(buf.count)
            let g = buf.withUnsafeMutableBufferPointer {
                IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, CFIndex(GloriousStock.reportID), $0.baseAddress!, &len)
            }
            if g == kIOReturnSuccess { result = .success(Array(buf.prefix(Int(len)))) } else { result = .failure(.getReportFailed(g)) }
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut { throw GloriousError.timeout("SetReport/GetReport > \(timeout)s") }
        return try result.get()
    }
}
