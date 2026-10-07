import Foundation
@preconcurrency import TintkeyKit

/// Per-key lighting on Keychron boards. Everything here changes live (RAM) state only and runs on the HID queue.
/// It remembers the keyboard's own per-key colors, type and effect the first time it takes over, and puts them
/// back in `leave()`. Unplugging the keyboard also resets it, since nothing is ever saved to its memory.
final class KeyDriver: @unchecked Sendable {
    private let via: VIAClient
    private(set) var ledCount: Int?
    private(set) var active = false
    private var baseline: [HSV]?
    private var originalType: UInt8?
    private var originalEffect: UInt8?
    private var last: [HSV]?

    init(_ via: VIAClient) { self.via = via }

    /// Read-only. True when the keyboard answers Keychron's RGB commands and has the LED layout we know.
    func probe() -> Bool {
        guard let n = via.keychronLEDCount(), n == KeyLayout.ledCount else { return false }
        ledCount = n
        return true
    }

    /// Shows one color per LED (`frame` has `ledCount` entries). Returns false if anything failed, after restoring.
    func show(_ frame: [HSV]) -> Bool {
        guard let n = ledCount, frame.count == n else { return false }
        if active { return write(frame) }

        guard let colors = via.keychronColors(ledCount: n), let effect = via.rgbMatrixEffect(), let type = via.keychronType() else { return false }
        baseline = colors; originalEffect = effect; originalType = type; last = colors
        guard via.keychronSetType(0), write(frame), via.setRGBMatrixEffect(KeychronRGB.perKeyEffectID) else {
            active = true      // so leave() undoes whatever got applied
            leave()
            return false
        }
        active = true
        return true
    }

    /// Restores the keyboard's own per-key colors, type and effect.
    @discardableResult
    func leave() -> Bool {
        guard active, ledCount != nil else { return true }
        var ok = true
        if let base = baseline { ok = write(base) && ok }
        if let t = originalType { ok = via.keychronSetType(t) && ok }
        if let e = originalEffect { ok = via.setRGBMatrixEffect(e) && ok }
        active = false; baseline = nil; last = nil
        return ok
    }

    /// Sends only the nine-LED chunks that changed, spaced a few milliseconds apart.
    private func write(_ frame: [HSV]) -> Bool {
        guard let n = ledCount else { return false }
        var ok = true
        var start = 0
        while start < n {
            let end = min(start + KeychronRGB.maxPerPacket, n)
            let chunk = Array(frame[start..<end])
            if last == nil || Array(last![start..<end]) != chunk {
                let sent = via.keychronSetColors(start: start, chunk, ledCount: n) || via.keychronSetColors(start: start, chunk, ledCount: n)
                if sent { last = (last ?? frame).enumerated().map { $0.offset >= start && $0.offset < end ? frame[$0.offset] : $0.element } } else { ok = false }
                Thread.sleep(forTimeInterval: 0.005)
            }
            start = end
        }
        return ok
    }
}
