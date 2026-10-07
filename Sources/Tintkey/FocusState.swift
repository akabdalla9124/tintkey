import Foundation

/// macOS has no public API for "is a Focus on". The state lives in files under ~/Library/DoNotDisturb that macOS
/// only lets apps read with Full Disk Access, so this is optional. Without it, a Shortcuts automation can tell
/// Tintkey about Focus changes with tintkey://focus?on=1&mode=Work and tintkey://focus?on=0.
enum FocusState {
    struct Snapshot {
        var readable = false
        /// Mode identifiers (e.g. com.apple.donotdisturb.mode.default) of the Focus modes currently on.
        var active: [String] = []
        /// Every mode macOS knows about: identifier -> the name shown in Control Center.
        var names: [String: String] = [:]
    }

    private static func json(_ file: String) -> Any? {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/DoNotDisturb/DB/" + file)
        return (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    /// Walks arbitrary JSON, calling `visit` for every dictionary. The files' nesting differs between macOS versions.
    private static func walk(_ node: Any, _ visit: ([String: Any]) -> Void) {
        if let d = node as? [String: Any] { visit(d); d.values.forEach { walk($0, visit) } }
        else if let a = node as? [Any] { a.forEach { walk($0, visit) } }
    }

    static func read() -> Snapshot {
        guard let assertions = json("Assertions.json") else { return Snapshot() }
        var snap = Snapshot(readable: true)
        var hasRecords = false
        walk(assertions) { d in
            if let r = d["storeAssertionRecords"] as? [Any], !r.isEmpty { hasRecords = true }
            if let id = d["assertionDetailsModeIdentifier"] as? String, !snap.active.contains(id) { snap.active.append(id) }
        }
        if hasRecords && snap.active.isEmpty { snap.active = ["unknown"] }   // a Focus is on but we couldn't tell which

        if let modes = json("ModeConfigurations.json") {
            walk(modes) { d in
                if let id = d["modeIdentifier"] as? String, let name = d["name"] as? String { snap.names[id] = name }
            }
        }
        return snap
    }
}
