import Foundation

public struct KeyDef: Equatable, Sendable, Identifiable {
    public let id: String      // stable name used in saved templates, e.g. "esc", "q", "lshift"
    public let label: String
    public let led: Int        // index used by Keychron's per-key commands
    public let x: Double       // position and width in key units (1 = a standard key)
    public let y: Double
    public let w: Double
}

/// Key positions and LED indexes for the Keychron V1 Max ANSI (81 LEDs; the knob press has none).
/// LED order is from Keychron's `g_led_config` (research/per-key-protocol.md, section 5).
public enum KeyLayout {
    public static let v1MaxANSI: [KeyDef] = {
        var keys: [KeyDef] = []
        var led = 0
        func row(_ y: Double, _ x0: Double, _ items: [(String, String, Double)]) {
            var x = x0
            for (id, label, w) in items {
                keys.append(KeyDef(id: id, label: label, led: led, x: x, y: y, w: w))
                led += 1
                x += w
            }
        }
        func k(_ s: String) -> (String, String, Double) { (s.lowercased(), s.uppercased(), 1) }
        func k(_ id: String, _ label: String, _ w: Double = 1) -> (String, String, Double) { (id, label, w) }

        row(0, 0, [k("esc", "Esc")] + (1...12).map { k("f\($0)", "F\($0)") } + [k("del", "Del")])
        row(1, 0, [k("grave", "`")] + "1234567890".map { k(String($0)) } + [k("minus", "-"), k("equal", "="), k("bksp", "Bksp", 2)])
        row(1, 15, [k("pgup", "PgUp")])
        row(2, 0, [k("tab", "Tab", 1.5)] + "qwertyuiop".map { k(String($0)) } + [k("lbracket", "["), k("rbracket", "]"), k("backslash", "\\", 1.5)])
        row(2, 15, [k("pgdn", "PgDn")])
        row(3, 0, [k("caps", "Caps", 1.75)] + "asdfghjkl".map { k(String($0)) } + [k("semicolon", ";"), k("quote", "'"), k("enter", "Enter", 2.25)])
        row(3, 15, [k("home", "Home")])
        row(4, 0, [k("lshift", "Shift", 2.25)] + "zxcvbnm".map { k(String($0)) } + [k("comma", ","), k("period", "."), k("slash", "/"), k("rshift", "Shift", 1.75)])
        row(4, 14, [k("up", "↑")])
        row(5, 0, [k("lctrl", "Ctrl", 1.25), k("lcmd", "Cmd", 1.25), k("lopt", "Opt", 1.25), k("space", "", 6.25),
                   k("rcmd", "Cmd"), k("fn", "Fn"), k("rctrl", "Ctrl"), k("left", "←"), k("down", "↓"), k("right", "→")])
        return keys
    }()

    public static var ledCount: Int { v1MaxANSI.count }
}
