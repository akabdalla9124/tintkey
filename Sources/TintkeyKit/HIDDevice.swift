import Foundation
import IOKit
import IOKit.hid

/// VIA / QMK raw HID endpoint: usage page 0xFF60, usage 0x61, 32-byte reports.
public enum RawHID {
    public static let usagePage = 0xFF60
    public static let usage = 0x61
    public static let reportSize = 32
}

public struct HIDDeviceInfo {
    public let device: IOHIDDevice
    public let vendorID: Int
    public let productID: Int
    public let product: String
    public let manufacturer: String
    public let transport: String
    public let usagePage: Int
    public let usage: Int
    public let locationID: Int

    public var isRawHID: Bool { usagePage == RawHID.usagePage && usage == RawHID.usage }
    public var idString: String { String(format: "%04X:%04X", vendorID, productID) }
}

private func prop<T>(_ d: IOHIDDevice, _ key: String) -> T? {
    IOHIDDeviceGetProperty(d, key as CFString) as? T
}

public enum HIDScanner {
    /// Lists every HID interface the system exposes. Raw HID interfaces are flagged via `isRawHID`.
    /// Last IOKit status from `scan`. 0xE00002E2 (not permitted) means macOS Input Monitoring is
    /// required, which only happens when the manager also matches keyboards/mice.
    public private(set) static var lastStatus: IOReturn = kIOReturnSuccess

    /// - Parameter rawOnly: match just the VIA raw HID interface. This avoids the Input Monitoring
    ///   permission, which macOS demands whenever keyboard/mouse interfaces are opened.
    public static func scan(rawOnly: Bool = false) -> [HIDDeviceInfo] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        if rawOnly {
            IOHIDManagerSetDeviceMatching(manager, [
                kIOHIDDeviceUsagePageKey: RawHID.usagePage,
                kIOHIDDeviceUsageKey: RawHID.usage,
            ] as CFDictionary)
        } else {
            IOHIDManagerSetDeviceMatching(manager, nil)
        }
        lastStatus = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard lastStatus == kIOReturnSuccess else { return [] }
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }

        return set.map { d in
            HIDDeviceInfo(
                device: d,
                vendorID: prop(d, kIOHIDVendorIDKey) ?? 0,
                productID: prop(d, kIOHIDProductIDKey) ?? 0,
                product: prop(d, kIOHIDProductKey) ?? "?",
                manufacturer: prop(d, kIOHIDManufacturerKey) ?? "?",
                transport: prop(d, kIOHIDTransportKey) ?? "?",
                usagePage: prop(d, kIOHIDPrimaryUsagePageKey) ?? 0,
                usage: prop(d, kIOHIDPrimaryUsageKey) ?? 0,
                locationID: prop(d, kIOHIDLocationIDKey) ?? 0
            )
        }
        .sorted { ($0.vendorID, $0.productID, $0.usagePage) < ($1.vendorID, $1.productID, $1.usagePage) }
    }

    public static func rawHIDDevices() -> [HIDDeviceInfo] { scan(rawOnly: true).filter(\.isRawHID) }
}
