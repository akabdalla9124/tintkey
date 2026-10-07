import SwiftUI
import AppKit
import UniformTypeIdentifiers
@preconcurrency import TintkeyKit

struct MenuView: View {
    @ObservedObject var controller: Controller

    var body: some View {
        Text(controller.connected ? "Connected: \(controller.deviceName)" : "No VIA keyboard found")
        if controller.meetingActive {
            Label("Meeting mode is overriding app colors", systemImage: "video.fill")
        } else if controller.focusActive {
            Label("Focus (\(controller.focusActiveNames.joined(separator: ", "))) is overriding app colors", systemImage: "moon.fill")
        }
        Picker("Mode", selection: $controller.mode) {
            ForEach(Mode.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.inline)
        Divider()
        if let app = controller.frontApp {
            Text("Frontmost: \(app.name)")
            if controller.rule(for: app)?.baseOn != true {
                Button("Add rule for \(app.name)") { controller.addRuleForFrontApp() }
            }
        }
        Button("Test alert") { controller.alert(controller.alertColor, style: controller.alertStyle) }
            .disabled(!controller.connected)
        Button("Open Tintkey…") { WindowOpener.shared.show() }
        Button("Check for Updates…") { Updater.shared.check() }
        Divider()
        Button("Quit Tintkey") { controller.quit() }
            .keyboardShortcut("q")
    }
}

/// Lets the app delegate and the menu bring the main window back after it was closed.
@MainActor
final class WindowOpener {
    static let shared = WindowOpener()
    var open: (() -> Void)?

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.title == "Tintkey" }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            open?()
        }
    }
}

private func colorBinding(_ get: @escaping () -> HS, _ set: @escaping (HS) -> Void) -> Binding<Color> {
    Binding(get: { get().color }, set: { set(HS($0)) })
}

private func appIcon(_ bundleID: String) -> NSImage {
    let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    return url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
}

struct MainView: View {
    @ObservedObject var controller: Controller
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(controller.connected ? Color.green : Color.orange).frame(width: 9, height: 9)
                Text(controller.connected ? "Connected: \(controller.deviceName)" : "No VIA keyboard found. Plug it in or insert its 2.4GHz dongle.")
                    .font(.callout)
                Spacer()
            }
            .padding(.horizontal).padding(.vertical, 10)
            Divider()
            TabView {
                AppsTab(controller: controller).tabItem { Label("Apps", systemImage: "app.badge") }
                NotificationsTab(controller: controller).tabItem { Label("Notifications", systemImage: "bell") }
                GeneralTab(controller: controller).tabItem { Label("General", systemImage: "gearshape") }
            }
        }
        .frame(minWidth: 520, minHeight: 560)
        .onAppear { WindowOpener.shared.open = { openWindow(id: "main") } }
    }
}

// MARK: Apps

/// Running apps that aren't yet on the given list, for the "Add app" menus.
@MainActor
private func addableApps(_ controller: Controller, _ list: Controller.RuleList) -> [(id: String, name: String)] {
    NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular }
        .compactMap { app in app.bundleIdentifier.map { (id: $0, name: app.localizedName ?? $0) } }
        .filter { app in
            app.id != Bundle.main.bundleIdentifier &&
            !controller.rules.contains { $0.bundleID == app.id && (list == .colors ? $0.baseOn : $0.inNotifications) }
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

@MainActor
private func addMenu(_ controller: Controller, _ list: Controller.RuleList) -> some View {
    Menu("Add app…") {
        ForEach(addableApps(controller, list), id: \.id) { app in
            Button(app.name) { controller.addRule(bundleID: app.id, name: app.name, to: list) }
        }
        Divider()
        Button("Choose from Applications…") {
            let panel = NSOpenPanel()
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.allowedContentTypes = [.application]
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
            controller.addRule(bundleID: id, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""), to: list)
        }
    }
    .fixedSize()
}

private struct EditTarget: Identifiable { let id: String }

struct AppsTab: View {
    @ObservedObject var controller: Controller
    @State private var editing: EditTarget?

    var body: some View {
        Form {
            Section {
                Text("The keyboard takes the color of the app you're using. Apps in the background, or without a color here, keep your keyboard's own color. Notification colors are on the Notifications tab.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("App colors") {
                ForEach($controller.rules) { $rule in
                    if rule.baseOn {
                        HStack(spacing: 10) {
                            Image(nsImage: appIcon(rule.bundleID)).resizable().frame(width: 24, height: 24)
                            Text(rule.name).fontWeight(.medium)
                            Spacer()
                            ColorPicker("Color", selection: colorBinding({ rule.base }, { rule.setBase($0) }), supportsOpacity: false)
                                .labelsHidden()
                            Button(rule.keyColors.isEmpty ? "Keys…" : "Keys (\(rule.keyColors.count))…") { editing = EditTarget(id: rule.bundleID) }
                                .help("Give individual keys their own colors while this app is in front")
                            Button(role: .destructive) {
                                controller.removeRule(bundleID: rule.bundleID, from: .colors)
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 2)
                    }
                }
                addMenu(controller, .colors)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { target in KeyEditorView(controller: controller, bundleID: target.id) }
    }
}

// MARK: Key editor

/// Click keys to select them, pick a color, and apply it. Saved per app in the rule's `keyColors`.
struct KeyEditorView: View {
    @ObservedObject var controller: Controller
    let bundleID: String
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var pick = Color.red

    private let unit: CGFloat = 40
    private var index: Int? { controller.rules.firstIndex { $0.bundleID == bundleID } }
    private var rule: Rule? { index.map { controller.rules[$0] } }

    private func apply(_ color: HS?) {
        guard let i = index else { return }
        for id in selected {
            if let color { controller.rules[i].keyColors[id] = color } else { controller.rules[i].keyColors.removeValue(forKey: id) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if let rule { Image(nsImage: appIcon(rule.bundleID)).resizable().frame(width: 28, height: 28) }
                Text("Keys for \(rule?.name ?? "app")").font(.title3.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("Click keys to select them (click again to deselect), choose a color, then press Apply. Keys you don't change use the app color.")
                .font(.callout).foregroundStyle(.secondary)

            ScrollView(.horizontal) {
                ZStack(alignment: .topLeading) {
                    ForEach(KeyLayout.v1MaxANSI) { key in
                        let custom = rule?.keyColors[key.id]
                        let fill = custom?.color ?? (rule?.base.color.opacity(0.45) ?? .gray)
                        RoundedRectangle(cornerRadius: 5)
                            .fill(fill)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected.contains(key.id) ? Color.primary : Color.black.opacity(0.35),
                                                                              lineWidth: selected.contains(key.id) ? 3 : 1))
                            .overlay(Text(key.label).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(custom == nil ? Color.primary : Color.black.opacity(0.8)))
                            .frame(width: key.w * unit - 4, height: unit - 4)
                            .offset(x: key.x * unit, y: key.y * unit)
                            .onTapGesture { if selected.contains(key.id) { selected.remove(key.id) } else { selected.insert(key.id) } }
                            .accessibilityLabel(key.label.isEmpty ? "Space" : key.label)
                    }
                }
                .frame(width: 16 * unit, height: 6 * unit, alignment: .topLeading)
                .padding(8)
            }

            HStack(spacing: 12) {
                ColorPicker("Color", selection: $pick, supportsOpacity: false)
                Button("Apply to \(selected.count) key\(selected.count == 1 ? "" : "s")") { apply(HS(pick)) }
                    .disabled(selected.isEmpty)
                Button("Clear selected") { apply(nil) }.disabled(selected.isEmpty)
                Spacer()
                Button("Select none") { selected = [] }.disabled(selected.isEmpty)
                Button("Clear all keys", role: .destructive) {
                    if let i = index { controller.rules[i].keyColors = [:] }
                }
                .disabled(rule?.keyColors.isEmpty ?? true)
            }

            Group {
                if controller.perKeySupported {
                    Label("Per-key lighting detected on your keyboard.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Label("Per-key lighting not detected yet. Your choices are saved and apply once the keyboard reports it (this needs Keychron firmware with Per Key RGB, and may need the USB cable).", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
                Text("Every key shows a color; a single key can't be switched off. Your keyboard's own lighting returns when you leave the app or quit.")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .padding(20)
        .frame(minWidth: 700, minHeight: 440)
    }
}

// MARK: Notifications

struct NotificationsTab: View {
    @ObservedObject var controller: Controller

    var body: some View {
        Form {
            Section {
                Toggle("Light up the keyboard when an app gets a notification", isOn: $controller.alertsEnabled)
            }
            Section("Look") {
                Picker("Style", selection: $controller.alertStyle) {
                    ForEach(AlertStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(controller.alertStyle == .flash
                     ? "Flashing swaps between the notification color and your normal color."
                     : "Breathing holds the notification color and fades the keyboard's brightness in and out.")
                    .font(.callout).foregroundStyle(.secondary)
                ColorPicker("Default notification color", selection: colorBinding({ controller.alertColor }, { controller.alertColor = $0 }), supportsOpacity: false)
                Stepper("\(controller.alertStyle == .flash ? "Flashes" : "Breaths"): \(controller.alertBlinks)", value: $controller.alertBlinks, in: 1...10)
                HStack {
                    Button("Test flashing") { controller.alert(controller.alertColor, style: .flash) }
                    Button("Test breathing") { controller.alert(controller.alertColor, style: .breathe) }
                }
                .disabled(!controller.connected)
            }
            Section("Notification colors by app") {
                Text("Only apps listed here light up the keyboard. Each uses its own color and style, or the defaults above.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach($controller.rules) { $rule in
                    if rule.inNotifications {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 10) {
                                Image(nsImage: appIcon(rule.bundleID)).resizable().frame(width: 24, height: 24)
                                Text(rule.name).fontWeight(.medium)
                                Spacer()
                                Toggle("Notify", isOn: $rule.alertsOn).toggleStyle(.checkbox).font(.callout)
                                Button(role: .destructive) {
                                    controller.removeRule(bundleID: rule.bundleID, from: .notifications)
                                } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                            }
                            if rule.alertsOn {
                                HStack(spacing: 10) {
                                    ColorPicker("Color", selection: colorBinding({ rule.alert ?? controller.alertColor }, { rule.setAlert($0) }), supportsOpacity: false)
                                    if rule.alert != nil { Button("Reset") { rule.setAlert(nil) }.buttonStyle(.link) }
                                    Picker("Style", selection: $rule.alertStyle) {
                                        Text("Default").tag(AlertStyle?.none)
                                        ForEach(AlertStyle.allCases) { Text($0.title).tag(AlertStyle?.some($0)) }
                                    }
                                    .fixedSize()
                                    Button("Test") { controller.alert(rule.alert ?? controller.alertColor, style: rule.alertStyle ?? controller.alertStyle) }
                                        .disabled(!controller.connected)
                                }
                                .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
                addMenu(controller, .notifications)
            }
            Section("Detection") {
                if controller.dockAccess {
                    Label("Watching Dock badges", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Works for apps that show a badge on their Dock icon (Mail, Messages, Slack and more). Banners without a badge can't be detected. Other tools can trigger an alert with tintkey://alert?app=Name&style=breathe.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Button("Allow Accessibility to detect badges…") { controller.requestDockAccess() }
                    Text("macOS doesn't let apps read other apps' notifications. Tintkey reads Dock badge counts instead, which needs the Accessibility permission.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: General

struct GeneralTab: View {
    @ObservedObject var controller: Controller

    var body: some View {
        Form {
            Section("Color mode") {
                Picker("Mode", selection: $controller.mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                switch controller.mode {
                case .perApp:
                    Text("Each app sets its own color while it's in front.").font(.callout).foregroundStyle(.secondary)
                case .locked:
                    ColorPicker("Locked color", selection: colorBinding({ controller.lockColor }, { controller.lockColor = $0 }), supportsOpacity: false)
                    Text("Always this color, whichever apps open or close. Notifications still show on top.")
                        .font(.callout).foregroundStyle(.secondary)
                case .off:
                    Text("Tintkey leaves your keyboard's own lighting alone, except for notifications.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Keyboard") {
                Picker("Control", selection: $controller.selectedDevice) {
                    Text("Automatic (first keyboard that answers)").tag(String?.none)
                    ForEach(controller.devices, id: \.uid) { d in
                        Text(d.label).tag(Optional(d.uid))
                    }
                }
                ForEach(controller.devices, id: \.uid) { d in
                    HStack {
                        Image(systemName: controller.connectedUID == d.uid ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(controller.connectedUID == d.uid ? Color.green : Color.secondary)
                        Text(d.label)
                        Spacer()
                        Button("Flash it") { controller.identify(d) }
                    }
                    .font(.callout)
                }
                if controller.devices.isEmpty {
                    Text("No VIA keyboard found. Plug one in, or insert its 2.4GHz dongle with the keyboard switched to 2.4G.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Two keyboards of the same kind look identical, so use Flash it to see which one a row is, then pick it above. Tintkey controls one keyboard at a time, and it's remembered by its USB port.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Meeting mode") {
                Toggle("Change the keyboard color while a camera or microphone is in use", isOn: $controller.meetingEnabled)
                if controller.meetingEnabled {
                    ColorPicker("Meeting color", selection: colorBinding({ controller.meetingColor }, { controller.meetingColor = $0 }), supportsOpacity: false)
                    Toggle("Camera", isOn: $controller.meetingCamera)
                    Toggle("Microphone", isOn: $controller.meetingMic)
                    Label(controller.meetingActive ? "In use right now" : "Nothing is using them right now",
                          systemImage: controller.meetingActive ? "circle.fill" : "circle")
                        .font(.callout).foregroundStyle(controller.meetingActive ? Color.red : Color.secondary)
                }
                Text("Works with any call app and needs no permission. Dictation, Siri or a voice recorder also count as the microphone being in use, so turn Microphone off if that gets in the way.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Focus mode") {
                Toggle("Change the keyboard color while a macOS Focus is on", isOn: $controller.focusEnabled)
                if controller.focusEnabled {
                    ColorPicker("Default Focus color", selection: colorBinding({ controller.focusColor }, { controller.focusColor = $0 }), supportsOpacity: false)
                    if controller.focusReadable == true {
                        Label(controller.focusActiveNames.isEmpty ? "No Focus is on" : "On now: " + controller.focusActiveNames.joined(separator: ", "),
                              systemImage: "moon.fill").font(.callout)
                        ForEach(controller.knownFocus.sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }, id: \.key) { id, name in
                            HStack {
                                Text(name)
                                Spacer()
                                Toggle("Use", isOn: Binding(get: { controller.focusUsed.contains(id) },
                                                            set: { on in if on { controller.focusUsed.insert(id) } else { controller.focusUsed.remove(id) } }))
                                    .toggleStyle(.checkbox).font(.callout)
                                if controller.focusUsed.contains(id) {
                                    ColorPicker("Color", selection: colorBinding({ controller.focusColors[id] ?? controller.focusColor }, { controller.focusColors[id] = $0 }), supportsOpacity: false)
                                        .labelsHidden()
                                    if controller.focusColors[id] != nil { Button("Reset") { controller.focusColors[id] = nil }.buttonStyle(.link).font(.callout) }
                                }
                            }
                        }
                        Text("Tick \"Use\" for the Focuses that should change the keyboard, and give each its own color. Focuses you don't tick leave the keyboard alone, so a scheduled one like Sleep can't override your app colors. New Focuses appear here the first time they turn on.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("macOS only lets apps read the Focus state with Full Disk Access. Either grant it to Tintkey, or in the Shortcuts app create automations (when a Focus turns on and off) that open tintkey://focus?on=1&mode=Work and tintkey://focus?on=0.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Open Full Disk Access settings…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                        }
                    }
                }
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: Binding(get: { Updater.shared.automaticChecks }, set: { Updater.shared.automaticChecks = $0 }))
                Button("Check now") { Updater.shared.check() }
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"). Updates are signed, so only releases from Tintkey are installed.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Startup") {
                Toggle("Open Tintkey at login", isOn: Binding(get: { controller.launchAtLogin }, set: { controller.setLaunchAtLogin($0) }))
                Text("Tintkey lives in the menu bar. Your keyboard's own color comes back whenever you quit.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Button("Quit Tintkey") { controller.quit() }
            }
        }
        .formStyle(.grouped)
    }
}
