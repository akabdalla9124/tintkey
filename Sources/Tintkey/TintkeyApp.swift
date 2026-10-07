import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Started by the login item: stay in the menu bar instead of opening the window.
        let event = NSAppleEventManager.shared().currentAppleEvent
        if event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                NSApp.windows.filter { $0.title == "Tintkey" }.forEach { $0.close() }
            }
        }
    }

    /// Double-clicking the app while it's already running brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowOpener.shared.show() }
        return true
    }
}

@main
struct TintkeyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller = Controller()

    /// Template image shipped in the app bundle; nil when running unbundled (e.g. `swift run`).
    private static let menuBarIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.size = NSSize(width: 18, height: 18)
        img.isTemplate = true
        return img
    }()

    var body: some Scene {
        Window("Tintkey", id: "main") {
            MainView(controller: controller)
        }
        .windowResizability(.contentMinSize)
        MenuBarExtra {
            MenuView(controller: controller)
        } label: {
            if let icon = Self.menuBarIcon {
                Image(nsImage: icon).opacity(controller.connected ? 1 : 0.45)
            } else {
                Image(systemName: controller.connected ? "keyboard.fill" : "keyboard")
            }
        }
    }
}
