import Foundation

// Clean-room implementation of the OpenRGB network SDK wire format, written from OpenRGB's public
// protocol documentation (Documentation/OpenRGBSDK.md and RGBControllerAPI.md). No OpenRGB (GPL)
// source code was copied or translated; only the documented byte layouts are used.
//
// Implemented/parsed protocol versions: 1...3 (OpenRGB clients may always negotiate downward; the
// server answers every client at min(server, client)). Version 3 is the newest we parse: it adds the
// per-mode brightness fields. Versions 4+ (zone segments, flags, per-zone modes, display names,
// JSON configuration) change the controller-data layout and are deliberately NOT requested.

/// 8-bit-per-channel color.
public struct RGB: Equatable, Hashable {
    public var r: UInt8, g: UInt8, b: UInt8
    public init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }
}

/// Packet ids this client is allowed to send. Profile save/delete, SAVEMODE (1102), settings and
/// plugin ids are intentionally not defined anywhere in this module, so they cannot be sent.
enum OpenRGBPacketID {
    static let requestControllerCount: UInt32 = 0
    static let requestControllerData: UInt32 = 1
    static let requestProtocolVersion: UInt32 = 40
    static let setClientName: UInt32 = 50
    static let deviceListUpdated: UInt32 = 100
    static let updateLEDs: UInt32 = 1050
    static let setCustomMode: UInt32 = 1100
    static let updateMode: UInt32 = 1101
}

public enum OpenRGBDeviceType: Int32 {
    case motherboard = 0, dram, gpu, cooler, ledStrip, keyboard, mouse, mousemat, headset, headsetStand
    case gamepad, light, speaker, virtual, storage, `case`, microphone, accessory, keypad, laptop, monitor, unknown
}

public struct OpenRGBMode: Equatable {
    public static let flagHasSpeed: UInt32 = 1 << 0
    public static let flagHasBrightness: UInt32 = 1 << 4
    public static let flagPerLEDColor: UInt32 = 1 << 5
    public static let flagModeSpecificColor: UInt32 = 1 << 6
    public static let flagManualSave: UInt32 = 1 << 8
    public static let flagAutoSave: UInt32 = 1 << 9

    public var index: Int
    public var name: String
    public var flags: UInt32
    public var colorMode: UInt32
    /// The exact serialized mode block as received, re-sent verbatim by restore().
    var raw: [UInt8]

    public var supportsPerLEDColor: Bool { flags & OpenRGBMode.flagPerLEDColor != 0 }
    /// "Direct", "Custom" or "Static" (the names SetCustomMode targets), case-insensitive.
    public var isDirectLike: Bool { ["direct", "custom", "static"].contains(name.lowercased()) }
}

public struct OpenRGBZone: Equatable {
    public var name: String
    public var type: Int32
    public var ledCount: Int
}

public struct OpenRGBDevice: Equatable {
    public var index: Int
    public var name: String
    public var type: OpenRGBDeviceType
    public var vendor: String
    public var description: String
    public var location: String
    public var ledCount: Int
    public var zones: [OpenRGBZone]
    public var modes: [OpenRGBMode]
    public var activeMode: Int
    public var currentColors: [RGB]

    public var hasDirectMode: Bool { modes.contains { $0.name.lowercased() == "direct" } }
    public var hasCustomMode: Bool { modes.contains { $0.name.lowercased() == "custom" } }
    public var hasStaticMode: Bool { modes.contains { $0.name.lowercased() == "static" } }
}

/// Saved state for restore(): active mode plus per-LED colors.
public struct OpenRGBSnapshot: Equatable {
    public var deviceIndex: Int
    public var activeMode: Int
    public var mode: OpenRGBMode?
    public var colors: [RGB]
}

enum OpenRGBParseError: Error { case truncated, badMagic, tooLarge, invalid }

/// Bounds-checked little-endian reader. Every read throws instead of trapping.
struct OpenRGBReader {
    let bytes: [UInt8]
    private(set) var pos = 0
    init(_ bytes: [UInt8]) { self.bytes = bytes }
    var remaining: Int { bytes.count - pos }

    mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard n >= 0, n <= remaining else { throw OpenRGBParseError.truncated }
        defer { pos += n }
        return bytes[pos..<pos + n]
    }
    mutating func u16() throws -> UInt16 {
        let s = try take(2); return UInt16(s[s.startIndex]) | UInt16(s[s.startIndex + 1]) << 8
    }
    mutating func u32() throws -> UInt32 {
        let s = try take(4); var v: UInt32 = 0
        for (i, b) in s.enumerated() { v |= UInt32(b) << (8 * UInt32(i)) }
        return v
    }
    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
    /// u16 length (including NUL terminator) then that many bytes.
    mutating func string() throws -> String {
        let n = Int(try u16())
        var s = Array(try take(n))
        if let z = s.firstIndex(of: 0) { s.removeSubrange(z...) }
        return String(decoding: s, as: UTF8.self)
    }
    /// u16 count then count 4-byte colors (R, G, B, pad).
    mutating func colors() throws -> [RGB] {
        let n = Int(try u16())
        guard n * 4 <= remaining else { throw OpenRGBParseError.truncated }
        var out: [RGB] = []; out.reserveCapacity(n)
        for _ in 0..<n { let c = try take(4); let i = c.startIndex; out.append(RGB(r: c[i], g: c[i + 1], b: c[i + 2])) }
        return out
    }
}

enum OpenRGBWire {
    static let maxPayload = 4 << 20
    static let maxProtocol: UInt32 = 3

    static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
    static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }

    static func packet(device: UInt32, id: UInt32, payload: [UInt8] = []) -> [UInt8] {
        Array("ORGB".utf8) + le32(device) + le32(id) + le32(UInt32(payload.count)) + payload
    }

    static func colorBlock(_ colors: [RGB]) -> [UInt8] {
        le16(UInt16(colors.count)) + colors.flatMap { [$0.r, $0.g, $0.b, 0] }
    }

    /// UPDATELEDS payload: u32 data_size (includes itself) + color block.
    static func updateLEDsPayload(_ colors: [RGB]) -> [UInt8] {
        let body = colorBlock(colors)
        return le32(UInt32(4 + body.count)) + body
    }

    /// UPDATEMODE payload: u32 data_size (includes itself), i32 mode index, mode block.
    static func updateModePayload(index: Int, raw: [UInt8]) -> [UInt8] {
        let body = le32(UInt32(bitPattern: Int32(index))) + raw
        return le32(UInt32(4 + body.count)) + body
    }

    static func parseHeader(_ h: [UInt8]) throws -> (device: UInt32, id: UInt32, size: Int) {
        guard h.count == 16 else { throw OpenRGBParseError.truncated }
        guard Array(h[0..<4]) == Array("ORGB".utf8) else { throw OpenRGBParseError.badMagic }
        var r = OpenRGBReader(h); _ = try r.take(4)
        let d = try r.u32(), id = try r.u32(), size = try r.u32()
        guard Int(size) <= maxPayload else { throw OpenRGBParseError.tooLarge }
        return (d, id, Int(size))
    }

    /// Parses one mode block. `version` is the negotiated protocol version (1...3).
    static func parseMode(_ r: inout OpenRGBReader, index: Int, version: UInt32) throws -> OpenRGBMode {
        let start = r.pos
        let name = try r.string()
        _ = try r.i32()                       // mode value
        let flags = try r.u32()
        _ = try r.u32(); _ = try r.u32()      // speed min, max
        if version >= 3 { _ = try r.u32(); _ = try r.u32() }   // brightness min, max
        _ = try r.u32(); _ = try r.u32()      // colors min, max
        _ = try r.u32()                       // speed
        if version >= 3 { _ = try r.u32() }   // brightness
        _ = try r.u32()                       // direction
        let colorMode = try r.u32()
        _ = try r.colors()                    // mode colors
        return OpenRGBMode(index: index, name: name, flags: flags, colorMode: colorMode, raw: Array(r.bytes[start..<r.pos]))
    }

    /// Parses a controller-data block (the part after the u32 data_size).
    static func parseDevice(_ block: [UInt8], index: Int, version: UInt32) throws -> OpenRGBDevice {
        guard (1...maxProtocol).contains(version) else { throw OpenRGBParseError.invalid }
        var r = OpenRGBReader(block)
        let rawType = try r.i32()
        let name = try r.string()
        let vendor = try r.string()           // present from protocol 1
        let desc = try r.string()
        _ = try r.string(); _ = try r.string()  // version, serial
        let location = try r.string()
        let numModes = Int(try r.u16())
        let active = Int(try r.i32())
        var modes: [OpenRGBMode] = []
        for i in 0..<numModes { modes.append(try parseMode(&r, index: i, version: version)) }
        let numZones = Int(try r.u16())
        var zones: [OpenRGBZone] = []
        for _ in 0..<numZones {
            let zn = try r.string()
            let zt = try r.i32()
            _ = try r.u32(); _ = try r.u32()
            let count = try r.u32()
            let matrixLen = Int(try r.u16())
            _ = try r.take(matrixLen)         // matrix map (height, width, indices) is not needed
            zones.append(OpenRGBZone(name: zn, type: zt, ledCount: Int(count)))
        }
        let numLEDs = Int(try r.u16())
        for _ in 0..<numLEDs { _ = try r.string(); _ = try r.u32() }
        let colors = try r.colors()
        guard active >= 0, active < modes.count || modes.isEmpty && active == 0 else { throw OpenRGBParseError.invalid }
        return OpenRGBDevice(index: index, name: name, type: OpenRGBDeviceType(rawValue: rawType) ?? .unknown,
                             vendor: vendor, description: desc, location: location, ledCount: numLEDs,
                             zones: zones, modes: modes, activeMode: active, currentColors: colors)
    }
}
