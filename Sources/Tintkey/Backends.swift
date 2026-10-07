import Foundation
@preconcurrency import TintkeyKit

/// What a backend reads from a keyboard when Tintkey takes control, used to give the user's own lighting back.
struct BackendSnapshot {
    var color: HS
    var brightness: UInt8?
    var perKey: Bool = false
}

/// One physical keyboard Tintkey can control, whatever protocol it speaks. Every method runs on the HID queue.
/// Backends only change live state; none may write to the keyboard's own memory.
protocol KeyboardBackend: AnyObject, Sendable {
    /// Reads the keyboard's current lighting. Nil if it isn't answering (asleep, off, wrong mode).
    func open() -> BackendSnapshot?
    func setSolid(_ c: HS) -> Bool
    func setBrightness(_ level: UInt8) -> Bool
    /// Per-key frame, one HSV per LED in `KeyLayout.v1MaxANSI` order. False if unsupported or it failed.
    func showFrame(_ frame: [HSV]) -> Bool
    /// Leaves per-key mode. True if nothing is left over.
    func leaveFrame() -> Bool
    var perKeyActive: Bool { get }
    /// Puts the keyboard's own lighting back.
    func restore(_ s: BackendSnapshot)
    /// Shows "the keyboard's own lighting" (no per-app color). Defaults to its remembered solid color; backends whose
    /// own lighting is an animated mode override this to bring the mode back.
    func setOwn(_ s: BackendSnapshot) -> Bool
    /// Blinks the keyboard white a few times so a person can tell which one it is.
    func flash()
}

extension KeyboardBackend {
    func setOwn(_ s: BackendSnapshot) -> Bool { setSolid(s.color) }
}

/// A keyboard found by a scan, with a way to open it. `make` is cheap and has no side effects.
struct KeyboardEntry: Identifiable {
    enum Kind: String { case via = "VIA", openrgb = "OpenRGB" }
    let uid: String
    let label: String        // shown in Settings
    let name: String         // shown in the menu
    let kind: Kind
    let make: @Sendable () -> KeyboardBackend
    var id: String { uid }
}

enum Discovery {
    /// Everything controllable right now. Runs on the HID queue.
    static func scan() -> [KeyboardEntry] {
        var out: [KeyboardEntry] = []
        for d in HIDScanner.rawHIDDevices() {
            let product = d.product.trimmingCharacters(in: .whitespaces)
            out.append(KeyboardEntry(uid: d.uid, label: "\(product), port \(d.portLabel)", name: product, kind: .via, make: { ViaBackend(d) }))
        }
        out += scanOpenRGB()
        return out
    }

    /// Keyboards that a locally running OpenRGB (SDK server on 127.0.0.1:6742) exposes. Nothing happens if it isn't running.
    private static func scanOpenRGB() -> [KeyboardEntry] {
        let client = OpenRGBClient()
        client.connectTimeout = 0.3
        guard client.connect() else { return [] }
        defer { client.close() }
        return client.devices.filter { $0.type == .keyboard }.map { d in
            let uid = "openrgb#\(d.name)#\(d.location)"
            let name = d.name
            return KeyboardEntry(uid: uid, label: "\(name) (via OpenRGB)", name: name, kind: .openrgb,
                                 make: { OpenRGBBackend(uid: uid, name: name, location: d.location) })
        }
    }
}

/// QMK/VIA keyboards, including Keychron's per-key extension.
final class ViaBackend: KeyboardBackend, @unchecked Sendable {
    private let client: VIAClient
    private let driver: KeyDriver

    init(_ info: HIDDeviceInfo) {
        client = VIAClient(info)
        driver = KeyDriver(client)
    }

    /// This firmware reads back one less than what was set (255 reads 254, 100 reads 99; 0 and 1 both read 0).
    /// Converting reads to "set" units keeps save/restore from losing a step each time.
    static func level(fromRead r: UInt8) -> UInt8 { r == 0 ? 0 : UInt8(min(255, Int(r) + 1)) }

    func open() -> BackendSnapshot? {
        guard client.protocolVersion() != nil,
              let c = client.lighting(.rgbMatrix, .color), c.count >= 2 else { return nil }
        let brightness = client.lighting(.rgbMatrix, .brightness)?.first.map(Self.level(fromRead:))
        return BackendSnapshot(color: HS(hue: c[0], sat: c[1]), brightness: brightness, perKey: driver.probe())
    }

    var perKeyActive: Bool { driver.active }

    func setSolid(_ c: HS) -> Bool {
        // Leaving per-key mode first brings the keyboard's own effect back, then the solid color goes on top.
        driver.leave()
        // One slow reply isn't a failure, so retry once.
        return client.setColor(.rgbMatrix, hue: c.hue, saturation: c.sat) != nil
            || client.setColor(.rgbMatrix, hue: c.hue, saturation: c.sat) != nil
    }

    func setBrightness(_ level: UInt8) -> Bool { client.setBrightness(.rgbMatrix, level) }
    func showFrame(_ frame: [HSV]) -> Bool { driver.show(frame) }
    func leaveFrame() -> Bool { driver.leave() }

    func restore(_ s: BackendSnapshot) {
        driver.leave()
        _ = client.setColor(.rgbMatrix, hue: s.color.hue, saturation: s.color.sat)
        if let b = s.brightness { _ = client.setBrightness(.rgbMatrix, b) }
    }

    func flash() {
        guard let cur = client.lighting(.rgbMatrix, .color), cur.count >= 2 else { return }
        for _ in 0..<3 {
            _ = client.setColor(.rgbMatrix, hue: 0, saturation: 0)
            Thread.sleep(forTimeInterval: 0.35)
            _ = client.setColor(.rgbMatrix, hue: cur[0], saturation: cur[1])
            Thread.sleep(forTimeInterval: 0.3)
        }
    }
}


/// Any keyboard OpenRGB supports, controlled through its local SDK server. Colors are sent as plain RGB; there is no
/// separate brightness control, so brightness is emulated by scaling the color (which also makes breathing work).
final class OpenRGBBackend: KeyboardBackend, @unchecked Sendable {
    private let uid: String
    private let name: String
    private let location: String
    private let client = OpenRGBClient()
    private var device: OpenRGBDevice?
    private var snapshot: OpenRGBSnapshot?
    private var color = HS(hue: 0, sat: 0)
    private var scale = 1.0
    let perKeyActive = false

    init(uid: String, name: String, location: String) { self.uid = uid; self.name = name; self.location = location }

    private func connectAndFind() -> OpenRGBDevice? {
        if !client.isConnected { guard client.connect() else { return nil } }
        guard client.refreshDevices() else { return nil }
        device = client.devices.first { $0.type == .keyboard && $0.name == name && $0.location == location }
        return device
    }

    static func rgb(_ c: HS, scale: Double) -> RGB {
        let h = Double(c.hue) / 255 * 6, s = Double(c.sat) / 255, v = max(0, min(1, scale))
        let i = Int(h) % 6, f = h - Double(Int(h))
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        let (r, g, b): (Double, Double, Double) = [(v, t, p), (q, v, p), (p, v, t), (p, q, v), (t, p, v), (v, p, q)][i]
        return RGB(r: UInt8((r * 255).rounded()), g: UInt8((g * 255).rounded()), b: UInt8((b * 255).rounded()))
    }

    static func hs(_ c: RGB) -> HS {
        let r = Double(c.r) / 255, g = Double(c.g) / 255, b = Double(c.b) / 255
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
            if h < 0 { h += 6 }
        }
        return HS(hue: UInt8((h / 6 * 255).rounded()) , sat: UInt8(((mx == 0 ? 0 : d / mx) * 255).rounded()))
    }

    func open() -> BackendSnapshot? {
        guard let d = connectAndFind(), let snap = client.snapshot(device: d.index) else { return nil }
        snapshot = snap
        color = snap.colors.first.map(Self.hs) ?? HS(hue: 0, sat: 0)
        return BackendSnapshot(color: color, brightness: nil)
    }

    private func push() -> Bool {
        guard let d = device else { return false }
        return client.setAll(device: d.index, color: Self.rgb(color, scale: scale))
    }

    func setSolid(_ c: HS) -> Bool { color = c; return push() }

    func setBrightness(_ level: UInt8) -> Bool { scale = Double(level) / 255; return push() }

    func showFrame(_ frame: [HSV]) -> Bool { false }
    func leaveFrame() -> Bool { true }

    /// The keyboard's own lighting may be an animated mode, so bring the saved mode and colors back.
    func setOwn(_ s: BackendSnapshot) -> Bool {
        scale = 1
        guard let d = device, let snap = snapshot else { return false }
        return client.restore(device: d.index, snapshot: snap)
    }

    func restore(_ s: BackendSnapshot) {
        scale = 1
        if let d = device ?? connectAndFind(), let snap = snapshot { _ = client.restore(device: d.index, snapshot: snap) }
        client.close()
    }

    func flash() {
        guard let d = connectAndFind(), let snap = client.snapshot(device: d.index) else { return }
        for _ in 0..<3 {
            _ = client.setAll(device: d.index, color: RGB(r: 255, g: 255, b: 255))
            Thread.sleep(forTimeInterval: 0.35)
            _ = client.restore(device: d.index, snapshot: snap)
            Thread.sleep(forTimeInterval: 0.3)
        }
        client.close()
    }
}
