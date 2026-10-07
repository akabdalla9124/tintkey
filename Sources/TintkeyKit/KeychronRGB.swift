import Foundation

public struct HSV: Equatable, Sendable {
    public var h: UInt8, s: UInt8, v: UInt8
    public init(h: UInt8, s: UInt8, v: UInt8) { self.h = h; self.s = s; self.v = v }
}

/// Keychron's per-key RGB raw HID commands: command 0xA8 with a sub-command in byte 1, status in byte 2 of the reply
/// (0 = ok). Layouts are from Keychron's firmware (common/rgb/keychron_rgb.c, branch 2025q3); see research/per-key-protocol.md.
///
/// The save sub-command (0x02) is deliberately not defined: Tintkey only ever changes the live (RAM) state and never
/// writes the keyboard's memory. Every builder checks `start + count <= ledCount` because the firmware does not.
public enum KeychronRGB {
    public static let command: UInt8 = 0xA8
    public static let maxPerPacket = 9
    /// RGB matrix effect id of "Per Key RGB" in the V1 Max's VIA definition.
    public static let perKeyEffectID: UInt8 = 23

    enum Sub: UInt8 { case version = 0x01, ledCount = 0x05, getType = 0x07, setType = 0x08, getColors = 0x09, setColors = 0x0A }

    public static func versionRequest() -> [UInt8] { [command, Sub.version.rawValue] }
    public static func ledCountRequest() -> [UInt8] { [command, Sub.ledCount.rawValue] }
    public static func getTypeRequest() -> [UInt8] { [command, Sub.getType.rawValue] }
    public static func setTypeRequest(_ type: UInt8) -> [UInt8] { [command, Sub.setType.rawValue, type] }

    public static func getColorsRequest(start: Int, count: Int, ledCount: Int) -> [UInt8]? {
        guard inRange(start, count, ledCount) else { return nil }
        return [command, Sub.getColors.rawValue, UInt8(start), UInt8(count)]
    }

    public static func setColorsRequest(start: Int, colors: [HSV], ledCount: Int) -> [UInt8]? {
        guard inRange(start, colors.count, ledCount) else { return nil }
        return [command, Sub.setColors.rawValue, UInt8(start), UInt8(colors.count)] + colors.flatMap { [$0.h, $0.s, $0.v] }
    }

    /// Reply to `getColorsRequest`: H, S, V triples start at byte 3.
    public static func parseColors(_ reply: [UInt8], count: Int) -> [HSV]? {
        guard reply.count >= 3 + 3 * count, reply[0] == command, reply[2] == 0 else { return nil }
        return (0..<count).map { HSV(h: reply[3 + 3 * $0], s: reply[4 + 3 * $0], v: reply[5 + 3 * $0]) }
    }

    private static func inRange(_ start: Int, _ count: Int, _ ledCount: Int) -> Bool {
        (1...maxPerPacket).contains(count) && start >= 0 && start + count <= ledCount && ledCount <= 255
    }
}

public extension VIAClient {
    /// Read-only. Number of LEDs if the keyboard answers Keychron's RGB commands, else nil.
    func keychronLEDCount() -> Int? {
        guard let v = request(KeychronRGB.versionRequest()), v.count >= 3, v[0] == KeychronRGB.command, v[2] == 0,
              let c = request(KeychronRGB.ledCountRequest()), c.count >= 4, c[0] == KeychronRGB.command, c[2] == 0 else { return nil }
        return Int(c[3])
    }

    func keychronType() -> UInt8? {
        guard let r = request(KeychronRGB.getTypeRequest()), r.count >= 4, r[2] == 0 else { return nil }
        return r[3]
    }

    @discardableResult
    func keychronSetType(_ type: UInt8) -> Bool {
        guard let r = request(KeychronRGB.setTypeRequest(type)), r.count >= 3 else { return false }
        return r[2] == 0
    }

    /// Current colors of all LEDs, nine per request.
    func keychronColors(ledCount: Int) -> [HSV]? {
        var out: [HSV] = []
        var start = 0
        while start < ledCount {
            let n = min(KeychronRGB.maxPerPacket, ledCount - start)
            guard let req = KeychronRGB.getColorsRequest(start: start, count: n, ledCount: ledCount),
                  let reply = request(req), let part = KeychronRGB.parseColors(reply, count: n) else { return nil }
            out += part
            start += n
        }
        return out
    }

    @discardableResult
    func keychronSetColors(start: Int, _ colors: [HSV], ledCount: Int) -> Bool {
        guard let req = KeychronRGB.setColorsRequest(start: start, colors: colors, ledCount: ledCount),
              let r = request(req), r.count >= 3 else { return false }
        return r[2] == 0
    }

    func rgbMatrixEffect() -> UInt8? { lighting(.rgbMatrix, .effect)?.first }

    @discardableResult
    func setRGBMatrixEffect(_ id: UInt8) -> Bool { setValue(.rgbMatrix, .effect, [id]) }
}
