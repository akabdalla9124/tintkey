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
    /// Blinks the keyboard white a few times so a person can tell which one it is.
    func flash()
}

/// A keyboard found by a scan, with a way to open it. `make` is cheap and has no side effects.
struct KeyboardEntry: Identifiable {
    enum Kind: String { case via = "VIA" }
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
        return out
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

