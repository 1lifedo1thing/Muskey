import AppKit
import Sparkle

final class Updates: NSObject, SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    static let shared = Updates()
    /// Settings > Updates > Update channel: true for Beta.
    static let channelKey = "betaUpdates"

    private(set) lazy var controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    var updater: SPUUpdater { controller.updater }

    func start() { _ = controller }

    func check() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    /// Betas are published on the beta channel of the same feed.
    func allowedChannels(for _: SPUUpdater) -> Set<String> {
        UserDefaults.standard.bool(forKey: Self.channelKey) ? ["beta"] : []
    }

    // Muskey has no Dock icon, so a scheduled update waits behind other windows instead of taking focus.
    var supportsGentleScheduledUpdateReminders: Bool { true }
}
