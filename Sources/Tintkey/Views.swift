import SwiftUI
import AppKit

struct MenuView: View {
    @ObservedObject var controller: Controller

    var body: some View {
        Text(controller.connected ? "Connected: \(controller.deviceName)" : "No VIA keyboard found")
        Picker("Mode", selection: $controller.mode) {
            ForEach(Mode.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.inline)
        Divider()
        if let app = controller.frontApp {
            Text("Frontmost: \(app.name)")
            if controller.rule(for: app) == nil {
                Button("Add rule for \(app.name)") { controller.addRuleForFrontApp() }
            }
        }
        Button("Test alert") { controller.alert(controller.alertColor, style: controller.alertStyle) }
            .disabled(!controller.connected)
        Button("Open Tintkey…") { WindowOpener.shared.show() }
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

struct AppsTab: View {
    @ObservedObject var controller: Controller

    private var runningApps: [(id: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in app.bundleIdentifier.map { (id: $0, name: app.localizedName ?? $0) } }
            .filter { app in !controller.rules.contains { $0.bundleID == app.id } && app.id != Bundle.main.bundleIdentifier }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section {
                Text("The keyboard takes the color of the app you're using. Apps in the background, or without a rule, keep your keyboard's own color.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("App colors") {
                ForEach($controller.rules) { $rule in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Image(nsImage: appIcon(rule.bundleID)).resizable().frame(width: 24, height: 24)
                            Text(rule.name).fontWeight(.medium)
                            Spacer()
                            ColorPicker("Color", selection: colorBinding({ rule.base }, { rule.setBase($0) }), supportsOpacity: false)
                                .labelsHidden()
                            Button(role: .destructive) {
                                controller.rules.removeAll { $0.bundleID == rule.bundleID }
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                        }
                        HStack(spacing: 10) {
                            Toggle("Notify", isOn: $rule.alertsOn).toggleStyle(.checkbox)
                            if rule.alertsOn {
                                ColorPicker("Notification color", selection: colorBinding({ rule.alert ?? controller.alertColor }, { rule.setAlert($0) }), supportsOpacity: false)
                                if rule.alert != nil { Button("Reset") { rule.setAlert(nil) }.buttonStyle(.link) }
                                Picker("Style", selection: $rule.alertStyle) {
                                    Text("Default").tag(AlertStyle?.none)
                                    ForEach(AlertStyle.allCases) { Text($0.title).tag(AlertStyle?.some($0)) }
                                }
                                .fixedSize()
                            }
                        }
                        .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
                Menu("Add running app…") {
                    ForEach(runningApps, id: \.id) { app in
                        Button(app.name) {
                            controller.rules.append(Rule(bundleID: app.id, name: app.name, hue: 0, sat: 255))
                        }
                    }
                }
                .fixedSize()
            }
        }
        .formStyle(.grouped)
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
                Text("Each app can use its own color and style on the Apps tab.")
                    .font(.callout).foregroundStyle(.secondary)
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
