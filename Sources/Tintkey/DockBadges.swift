import AppKit
import ApplicationServices

/// macOS has no API for reading other apps' notifications. The most reliable public signal is the
/// Dock badge count, which the Accessibility API exposes as "AXStatusLabel" on each Dock item.
/// Needs the Accessibility permission. Only apps that show a Dock badge are detected.
final class DockBadgeWatcher {
    var onIncrease: ((String) -> Void)?

    private let queue = DispatchQueue(label: "tintkey.dock")
    private var timer: DispatchSourceTimer?
    private var last: [String: Int]?

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        guard AXIsProcessTrusted() else { last = nil; return }
        let now = Self.readBadges()
        // The first successful read is only a baseline, so badges that already exist don't fire.
        if let last {
            for (name, count) in now where count > (last[name] ?? 0) { onIncrease?(name) }
        }
        last = now
    }

    private static func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    static func readBadges() -> [String: Int] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [:] }
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        var out: [String: Int] = [:]
        for list in (attr(root, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            for item in (attr(list, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                guard let name = attr(item, kAXTitleAttribute) as? String,
                      let label = attr(item, "AXStatusLabel") as? String, !label.isEmpty else { continue }
                out[name] = Int(label) ?? 1   // a non-numeric badge (e.g. a dot) counts as one
            }
        }
        return out
    }
}
