import SwiftUI
import AppKit

/// Hue/saturation on the keyboard's 0-255 scale.
struct HS: Codable, Equatable {
    var hue: UInt8
    var sat: UInt8

    var color: Color { Color(hue: Double(hue) / 255, saturation: Double(sat) / 255, brightness: 1) }

    init(hue: UInt8, sat: UInt8) { self.hue = hue; self.sat = sat }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        self.init(hue: UInt8((h * 255).rounded()), sat: UInt8((s * 255).rounded()))
    }
}

enum AlertStyle: String, Codable, CaseIterable, Identifiable {
    case flash, breathe
    var id: String { rawValue }
    var title: String { self == .flash ? "Flashing" : "Breathing" }
}

/// "When this app is frontmost, use this color" plus how it signals a notification.
struct Rule: Codable, Identifiable, Equatable {
    var bundleID: String
    var name: String
    var hue: UInt8
    var sat: UInt8
    /// false = notifications only: the app never changes the keyboard color while in front.
    var baseOn: Bool = true
    /// Listed on the Notifications tab (the app has its own notification settings).
    var inNotifications: Bool = false
    var alertsOn: Bool = true
    /// Per-key template: key id (see KeyLayout) -> color. Empty = the whole board uses the app color.
    var keyColors: [String: HS] = [:]
    /// nil = use the global alert color.
    var alertHue: UInt8?
    var alertSat: UInt8?
    /// nil = use the global alert style.
    var alertStyle: AlertStyle?

    var id: String { bundleID }
    var base: HS { HS(hue: hue, sat: sat) }
    var alert: HS? { get { alertHue.flatMap { h in alertSat.map { HS(hue: h, sat: $0) } } } }

    mutating func setBase(_ c: HS) { hue = c.hue; sat = c.sat }
    mutating func setAlert(_ c: HS?) { alertHue = c?.hue; alertSat = c?.sat }

    static let defaults: [Rule] = [
        Rule(bundleID: "us.zoom.xos", name: "Zoom", hue: 0, sat: 255),
        Rule(bundleID: "com.apple.dt.Xcode", name: "Xcode", hue: 170, sat: 255),
        Rule(bundleID: "com.obsproject.obs-studio", name: "OBS", hue: 85, sat: 255),
        Rule(bundleID: "com.figma.Desktop", name: "Figma", hue: 190, sat: 255),
        Rule(bundleID: "com.apple.Terminal", name: "Terminal", hue: 25, sat: 255),
    ]
}

extension Rule {
    /// Tolerates rules saved by older builds that had no alert fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try c.decode(String.self, forKey: .bundleID)
        name = try c.decode(String.self, forKey: .name)
        hue = try c.decode(UInt8.self, forKey: .hue)
        sat = try c.decode(UInt8.self, forKey: .sat)
        baseOn = try c.decodeIfPresent(Bool.self, forKey: .baseOn) ?? true
        alertsOn = try c.decodeIfPresent(Bool.self, forKey: .alertsOn) ?? true
        keyColors = try c.decodeIfPresent([String: HS].self, forKey: .keyColors) ?? [:]
        alertHue = try c.decodeIfPresent(UInt8.self, forKey: .alertHue)
        alertSat = try c.decodeIfPresent(UInt8.self, forKey: .alertSat)
        alertStyle = try c.decodeIfPresent(AlertStyle.self, forKey: .alertStyle)
        // Rules saved before the Notifications tab listed apps: show those that already had custom alert settings.
        inNotifications = try c.decodeIfPresent(Bool.self, forKey: .inNotifications)
            ?? (alertHue != nil || alertStyle != nil || !alertsOn)
    }
}

enum Mode: String, CaseIterable, Identifiable {
    case off, perApp, locked
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Keyboard's own color"
        case .perApp: return "Per-app colors"
        case .locked: return "Locked color"
        }
    }
}
