import SwiftUI
import AppKit
import ServiceManagement
@preconcurrency import TintkeyKit

struct FrontApp: Equatable {
    var bundleID: String
    var name: String
}

/// Receives `tintkey://` links. NSAppleEventManager needs an NSObject target.
private final class URLReceiver: NSObject {
    var handler: ((URL) -> Void)?
    @objc func handle(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s) else { return }
        handler?(url)
    }
}

/// Owns the keyboard connection and decides what color it shows.
/// Priority: alert blink > mode (locked / per-app of the FRONTMOST app / keyboard's own color).
/// Apps in the background never affect the color. All HID traffic runs on one serial queue.
@MainActor
final class Controller: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var rules: [Rule] { didSet { save(rules, "rules"); apply() } }
    @Published var mode: Mode { didSet { defaults.set(mode.rawValue, forKey: "mode"); apply() } }
    @Published var lockColor: HS { didSet { save(lockColor, "lockColor"); apply() } }
    @Published var alertsEnabled: Bool { didSet { defaults.set(alertsEnabled, forKey: "alertsEnabled") } }
    @Published var alertColor: HS { didSet { save(alertColor, "alertColor") } }
    @Published var alertStyle: AlertStyle { didSet { defaults.set(alertStyle.rawValue, forKey: "alertStyle") } }
    /// Flashes or breaths per alert.
    @Published var alertBlinks: Int { didSet { defaults.set(alertBlinks, forKey: "alertBlinks") } }
    @Published var meetingEnabled: Bool { didSet { defaults.set(meetingEnabled, forKey: "meetingEnabled"); refreshMeeting() } }
    @Published var meetingColor: HS { didSet { save(meetingColor, "meetingColor"); apply() } }
    @Published var meetingCamera: Bool { didSet { defaults.set(meetingCamera, forKey: "meetingCamera"); refreshMeeting() } }
    @Published var meetingMic: Bool { didSet { defaults.set(meetingMic, forKey: "meetingMic"); refreshMeeting() } }
    @Published private(set) var meetingActive = false
    @Published var focusEnabled: Bool { didSet { defaults.set(focusEnabled, forKey: "focusEnabled"); refreshFocus() } }
    @Published var focusColor: HS { didSet { save(focusColor, "focusColor"); apply() } }
    @Published private(set) var focusActive = false
    /// Colors per Focus mode identifier; modes without one use `focusColor`.
    @Published var focusColors: [String: HS] { didSet { save(focusColors, "focusColors"); apply() } }
    @Published var focusIgnored: Set<String> { didSet { defaults.set(Array(focusIgnored), forKey: "focusIgnored"); refreshFocus() } }
    /// Focus modes seen so far (identifier -> name), kept so their rows stay in Settings when no Focus is on.
    @Published private(set) var knownFocus: [String: String]
    @Published private(set) var focusActiveNames: [String] = []
    private var focusActiveColor: HS?
    /// nil = Focus can't be read from the system (needs Full Disk Access); the URL scheme still works.
    @Published private(set) var focusReadable: Bool?
    private var focusViaURL: Bool?
    private var focusURLMode: String?
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var connected = false
    @Published private(set) var deviceName = "No keyboard"
    @Published private(set) var frontApp: FrontApp?
    @Published private(set) var dockAccess = DockBadgeWatcher.isTrusted
    /// The keyboard answered Keychron's per-key commands and matches the V1 Max layout.
    @Published private(set) var perKeySupported = false

    private let hid = DispatchQueue(label: "tintkey.hid")
    private var via: VIAClient?
    private var original: HS?
    private var originalBrightness: UInt8 = 255
    private var lastBrightness: UInt8?
    private var alertGen = 0
    private var connecting = false
    private var pending: DispatchWorkItem?
    private var lastSent: HS?
    private var driver: KeyDriver?
    private var keysActive = false
    private var lastFrame: [HSV]?
    private var alertOverride: HS?
    private var blinkTask: Task<Void, Never>?
    private let watcher = DockBadgeWatcher()
    private let urls = URLReceiver()

    init() {
        rules = Self.load([Rule].self, "rules") ?? Rule.defaults
        mode = Mode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .perApp
        lockColor = Self.load(HS.self, "lockColor") ?? HS(hue: 171, sat: 255)
        alertsEnabled = defaults.object(forKey: "alertsEnabled") as? Bool ?? true
        alertColor = Self.load(HS.self, "alertColor") ?? HS(hue: 0, sat: 255)
        alertStyle = AlertStyle(rawValue: defaults.string(forKey: "alertStyle") ?? "") ?? .flash
        meetingEnabled = defaults.object(forKey: "meetingEnabled") as? Bool ?? false
        meetingColor = Self.load(HS.self, "meetingColor") ?? HS(hue: 0, sat: 255)
        meetingCamera = defaults.object(forKey: "meetingCamera") as? Bool ?? true
        meetingMic = defaults.object(forKey: "meetingMic") as? Bool ?? true
        focusEnabled = defaults.object(forKey: "focusEnabled") as? Bool ?? false
        focusColor = Self.load(HS.self, "focusColor") ?? HS(hue: 190, sat: 255)
        focusColors = Self.load([String: HS].self, "focusColors") ?? [:]
        focusIgnored = Set(defaults.stringArray(forKey: "focusIgnored") ?? [])
        knownFocus = Self.load([String: String].self, "knownFocus") ?? [:]
        alertBlinks = defaults.object(forKey: "alertBlinks") as? Int ?? 3

        if let app = NSWorkspace.shared.frontmostApplication { note(app) }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.note(app) }
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lastSent = nil; self?.poll(); self?.apply() }
        }
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMeeting(); self?.refreshFocus() }
        }
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.dockAccess = DockBadgeWatcher.isTrusted; self?.poll() }
        }

        watcher.onIncrease = { [weak self] name in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.badgeAppeared(for: name) } }
        }
        watcher.start()

        urls.handler = { [weak self] url in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(url) } }
        }
        NSAppleEventManager.shared().setEventHandler(urls, andSelector: #selector(URLReceiver.handle(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restoreOriginal() }
        }
        poll()
    }

    /// This firmware reads back one less than what was set (255 reads 254, 100 reads 99; 0 and 1 both read 0).
    /// Converting reads to "set" units keeps save/restore from losing a step each time.
    nonisolated static func level(fromRead r: UInt8) -> UInt8 { r == 0 ? 0 : UInt8(min(255, Int(r) + 1)) }

    // MARK: Frontmost app

    private func note(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return }
        frontApp = FrontApp(bundleID: id, name: app.localizedName ?? id)
        apply()
    }

    func rule(for app: FrontApp?) -> Rule? { app.flatMap { a in rules.first { $0.bundleID == a.bundleID } } }

    func addRuleForFrontApp() {
        guard let app = frontApp else { return }
        addRule(bundleID: app.bundleID, name: app.name, to: .colors)
    }

    enum RuleList { case colors, notifications }

    /// Adds an app to one of the two lists, reusing its rule if it is already in the other.
    func addRule(bundleID: String, name: String, to list: RuleList) {
        if let i = rules.firstIndex(where: { $0.bundleID == bundleID }) {
            if list == .colors { rules[i].baseOn = true } else { rules[i].inNotifications = true }
            return
        }
        var r = Rule(bundleID: bundleID, name: name, hue: 0, sat: 255)
        r.baseOn = list == .colors
        r.inNotifications = list == .notifications
        rules.append(r)
    }

    /// Takes an app off one list; the rule is deleted once it is on neither.
    func removeRule(bundleID: String, from list: RuleList) {
        guard let i = rules.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        if list == .colors { rules[i].baseOn = false } else {
            rules[i].inNotifications = false; rules[i].alertsOn = true
            rules[i].setAlert(nil); rules[i].alertStyle = nil
        }
        if !rules[i].baseOn && !rules[i].inNotifications { rules.remove(at: i) }
    }

    // MARK: Alerts

    /// A Dock badge appeared on `name`. Alerts for the app you're already looking at are skipped.
    private func badgeAppeared(for name: String) {
        guard alertsEnabled else { return }
        // Only apps listed on the Notifications tab alert; everything else stays silent.
        guard let rule = rules.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
              rule.inNotifications, rule.alertsOn else { return }
        if let front = frontApp, front.name.caseInsensitiveCompare(name) == .orderedSame { return }
        alert(rule.alert ?? alertColor, style: rule.alertStyle ?? alertStyle)
    }

    /// Flashing swaps between the alert color and the normal color. Breathing holds the alert color
    /// and fades the keyboard's brightness down and up. A newer alert replaces one still running.
    func alert(_ color: HS, style: AlertStyle) {
        guard connected else { return }
        blinkTask?.cancel()
        alertGen += 1
        let gen = alertGen
        let cycles = alertBlinks
        let hi = originalBrightness
        let lo = min(hi, UInt8(max(8, Int(hi) / 20)))   // never above hi, so hi - lo can't underflow
        blinkTask = Task { @MainActor [weak self] in
            switch style {
            case .flash:
                for _ in 0..<cycles {
                    guard let self, !Task.isCancelled else { break }
                    self.alertOverride = color; self.apply(delay: 0)
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    self.alertOverride = nil; self.apply(delay: 0)
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            case .breathe:
                self?.alertOverride = color; self?.apply(delay: 0)
                try? await Task.sleep(nanoseconds: 250_000_000)
                let steps = 28
                outer: for _ in 0..<cycles {
                    for step in 0..<steps {
                        guard let self, !Task.isCancelled else { break outer }
                        let k = 0.5 + 0.5 * cos(2 * Double.pi * Double(step) / Double(steps))
                        self.sendBrightness(UInt8((Double(lo) + Double(hi - lo) * k).rounded()))
                        try? await Task.sleep(nanoseconds: 60_000_000)
                    }
                }
            }
            guard let self, self.alertGen == gen else { return }
            self.alertOverride = nil
            self.apply(delay: 0)
            self.sendBrightness(self.originalBrightness)
        }
    }

    private func sendBrightness(_ level: UInt8) {
        guard let via, level != lastBrightness else { return }
        lastBrightness = level
        hid.async { [weak self] in
            // A failed send must not be remembered as applied, or the restore to the original would be skipped.
            if !via.setBrightness(.rgbMatrix, level) {
                DispatchQueue.main.async { MainActor.assumeIsolated { if self?.via === via { self?.lastBrightness = nil } } }
            }
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Tintkey: launch at login failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// tintkey://alert[?app=Slack | ?hue=0&sat=255]   tintkey://lock?hue=..&sat=..   tintkey://unlock
    private func handle(_ url: URL) {
        let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .compactMap { i in i.value.map { (i.name, $0) } })
        let custom = q["hue"].flatMap(UInt8.init).flatMap { h in q["sat"].flatMap(UInt8.init).map { HS(hue: h, sat: $0) } }
        switch url.host {
        case "alert":
            let named = q["app"].flatMap { n in rules.first { $0.name.caseInsensitiveCompare(n) == .orderedSame } }
            let style = q["style"].flatMap(AlertStyle.init) ?? named?.alertStyle ?? alertStyle
            alert(custom ?? named?.alert ?? alertColor, style: style)
        case "lock":
            if let custom { lockColor = custom }
            mode = .locked
        case "unlock": mode = .perApp
        case "focus":
            focusViaURL = q["on"] == "1"
            focusURLMode = q["mode"]
            refreshFocus()
        default: break
        }
    }

    private func refreshMeeting() {
        let on = meetingEnabled && ((meetingCamera && MediaUse.cameraInUse()) || (meetingMic && MediaUse.micInUse()))
        if on != meetingActive { meetingActive = on; apply(delay: 0.2) }
    }

    private func refreshFocus() {
        let snap = FocusState.read()
        if focusReadable != snap.readable { focusReadable = snap.readable }

        var ids: [String] = []
        if snap.readable {
            var known = knownFocus
            for (id, name) in snap.names where known[id] != name { known[id] = name }
            for id in snap.active where known[id] == nil && id != "unknown" { known[id] = Self.prettyFocusName(id) }
            if known != knownFocus { knownFocus = known; save(known, "knownFocus") }
            ids = snap.active
        } else if focusViaURL == true {
            // A Shortcuts automation reported it. Match the optional mode name to a known mode.
            let match = focusURLMode.flatMap { n in knownFocus.first { $0.value.caseInsensitiveCompare(n) == .orderedSame }?.key }
            ids = [match ?? "unknown"]
        }

        let live = focusEnabled ? ids.filter { !focusIgnored.contains($0) } : []
        let color = live.first.map { focusColors[$0] ?? focusColor }
        let names = live.map { knownFocus[$0] ?? "Focus" }
        if names != focusActiveNames { focusActiveNames = names }
        let on = color != nil
        if on != focusActive || color != focusActiveColor { focusActive = on; focusActiveColor = color; apply(delay: 0.2) }
    }

    private static func prettyFocusName(_ id: String) -> String {
        let tail = id.split(separator: ".").last.map(String.init) ?? id
        return tail == "default" ? "Do Not Disturb" : tail.capitalized
    }

    func requestDockAccess() { DockBadgeWatcher.requestTrust() }

    // MARK: Keyboard

    /// Looks for the raw HID interface; connects/disconnects as the cable or dongle comes and goes.
    private func poll() {
        hid.async { [weak self] in
            let found = HIDScanner.rawHIDDevices().first
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handleScan(found) } }
        }
    }

    private func handleScan(_ found: HIDDeviceInfo?) {
        guard let found else {
            if connected { disconnect() }
            return
        }
        guard !connected, !connecting else { return }
        connecting = true
        let client = VIAClient(found)
        hid.async { [weak self] in
            let version = client.protocolVersion()
            let color = client.lighting(.rgbMatrix, .color)
            let brightness = client.lighting(.rgbMatrix, .brightness)?.first.map(Self.level(fromRead:))
            let drv = KeyDriver(client)
            let keys = drv.probe()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.connecting = false
                    guard version != nil, let c = color, c.count >= 2 else { return }
                    self.via = client
                    self.driver = drv
                    self.perKeySupported = keys
                    // If the keyboard is still showing the last color we sent (we were killed or dropped
                    // mid-session), the user's real colors are the ones we saved, not what it shows now.
                    let shown = HS(hue: c[0], sat: c[1])
                    if let saved = Self.load(HS.self, "savedOriginal"), let applied = Self.load(HS.self, "savedApplied"), applied == shown {
                        self.original = saved
                        self.originalBrightness = UInt8(clamping: self.defaults.integer(forKey: "savedBrightness"))
                    } else {
                        self.original = shown
                        self.originalBrightness = brightness ?? 255
                    }
                    self.save(self.original, "savedOriginal")
                    self.defaults.set(Int(self.originalBrightness), forKey: "savedBrightness")
                    self.save(shown, "savedApplied")
                    self.lastSent = shown
                    self.lastBrightness = brightness
                    // A crash mid-breathe leaves the keyboard dim; put the saved brightness back.
                    if let b = brightness, b != self.originalBrightness { self.sendBrightness(self.originalBrightness) }
                    self.deviceName = found.product.trimmingCharacters(in: .whitespaces)
                    self.connected = true
                    self.apply()
                }
            }
        }
    }

    private func disconnect() {
        pending?.cancel()
        blinkTask?.cancel()
        alertOverride = nil
        via = nil; original = nil; lastSent = nil; lastBrightness = nil
        driver = nil; perKeySupported = false; keysActive = false; lastFrame = nil
        connected = false
        deviceName = "No keyboard"
    }

    private enum Desired { case solid(HS), frame([HSV]) }

    private func fill(_ c: HS) -> [HSV] { Array(repeating: HSV(h: c.hue, s: c.sat, v: 255), count: KeyLayout.ledCount) }

    private func desired() -> Desired? {
        guard let original else { return nil }
        // While the per-key effect is showing, an alert paints every key so it isn't hidden behind the key map.
        if let alertOverride { return keysActive ? .frame(fill(alertOverride)) : .solid(alertOverride) }
        // Meeting and Focus colors sit above the normal modes; a meeting wins over a Focus.
        func over(_ c: HS) -> Desired { keysActive ? .frame(fill(c)) : .solid(c) }
        if meetingActive { return over(meetingColor) }
        if focusActive, let c = focusActiveColor { return over(c) }
        switch mode {
        case .off: return .solid(original)
        case .locked: return .solid(lockColor)
        case .perApp:
            guard let r = rule(for: frontApp) else { return .solid(original) }
            let base = r.baseOn ? r.base : original
            guard perKeySupported, !r.keyColors.isEmpty else { return .solid(base) }
            var f = fill(base)
            for key in KeyLayout.v1MaxANSI { if let c = r.keyColors[key.id] { f[key.led] = HSV(h: c.hue, s: c.sat, v: 255) } }
            return .frame(f)
        }
    }

    /// Debounced so rapid app switches only send the last state; alerts pass delay 0.
    private func apply(delay: TimeInterval = 0.12) {
        pending?.cancel()
        guard connected, let via, let d = desired() else { return }
        let drv = driver
        let work: DispatchWorkItem
        switch d {
        case .solid(let t):
            if t == lastSent && !keysActive { return }
            work = DispatchWorkItem { [weak self] in
                // Leaving per-key mode first brings the keyboard's own effect back, then the solid color goes on top.
                let left = drv?.leave() ?? true
                // One slow reply isn't a disconnect, so retry once before giving up.
                let ok = via.setColor(.rgbMatrix, hue: t.hue, saturation: t.sat) != nil
                    || via.setColor(.rgbMatrix, hue: t.hue, saturation: t.sat) != nil
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        // Ignore results from a client that was already replaced by a disconnect/reconnect.
                        guard let self, self.via === via else { return }
                        if ok { self.lastSent = t; self.keysActive = !left; self.lastFrame = nil; self.save(t, "savedApplied") }
                        else { self.disconnect() }
                    }
                }
            }
        case .frame(let f):
            if keysActive && f == lastFrame { return }
            work = DispatchWorkItem { [weak self] in
                let ok = drv?.show(f) ?? false
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.via === via else { return }
                        if ok { self.keysActive = true; self.lastFrame = f; self.lastSent = nil }
                        else { self.perKeySupported = false; self.keysActive = false; self.lastFrame = nil; self.lastSent = nil; self.apply(delay: 0) }
                    }
                }
            }
        }
        pending = work
        hid.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Puts the user's own color back. Runs on every quit path, including `osascript ... quit`.
    private func restoreOriginal() {
        pending?.cancel()
        blinkTask?.cancel()
        if let via, let original {
            let brightness = originalBrightness
            let drv = driver
            hid.sync {
                drv?.leave()
                _ = via.setColor(.rgbMatrix, hue: original.hue, saturation: original.sat)
                _ = via.setBrightness(.rgbMatrix, brightness)
            }
            save(original, "savedApplied")
        }
    }

    func quit() { NSApp.terminate(nil) }

    private func save<T: Encodable>(_ v: T, _ key: String) {
        if let data = try? JSONEncoder().encode(v) { defaults.set(data, forKey: key) }
    }
    private static func load<T: Decodable>(_ t: T.Type, _ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(t, from: $0) }
    }
}
