import SwiftUI
import Sparkle

/// Wraps Sparkle's standard updater. The feed URL and public key come from Info.plist (see scripts/build-app.sh),
/// so an unbundled `swift run` build simply has nothing to check against.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    @Published var automaticChecks: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticChecks }
    }

    private init() { automaticChecks = controller.updater.automaticallyChecksForUpdates }

    func check() { controller.checkForUpdates(nil) }
}
