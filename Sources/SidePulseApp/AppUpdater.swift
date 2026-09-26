import AppKit
import Sparkle
import SidePulseCore

struct UpdatePreferences: Equatable {
    var automaticallyChecks: Bool
    var automaticallyDownloads: Bool
}

/// The only file that imports Sparkle.
@MainActor
final class AppUpdater: NSObject {
    /// A scheduled check's find that the menu offers, because a menu-bar app's alert would open behind other windows.
    private(set) var pendingVersion: String?

    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)

    /// `build-app.sh` drops `SUFeedURL` from builds made from source, so they never update into a release build.
    static func startIfConfigured() -> AppUpdater? {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return nil }
        let updater = AppUpdater()
        updater.controller.startUpdater()
        return updater
    }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    func checkForUpdates() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    var preferences: UpdatePreferences {
        UpdatePreferences(automaticallyChecks: controller.updater.automaticallyChecksForUpdates,
                          automaticallyDownloads: controller.updater.automaticallyDownloadsUpdates)
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyDownloads(_ enabled: Bool) {
        controller.updater.automaticallyDownloadsUpdates = enabled
    }
}

extension AppUpdater: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        DiagnosticsLog.shared.log("app: installing update \(item.displayVersionString)")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        guard (error as NSError).code != Int(SUError.noUpdateError.rawValue) else { return }
        DiagnosticsLog.shared.log("app: update failed: \(ErrorText.describe(error))")
    }
}

extension AppUpdater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle proposes immediate focus only right after launch.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        if !handleShowingUpdate { pendingVersion = update.displayVersionString }
    }

    func standardUserDriverWillFinishUpdateSession() {
        pendingVersion = nil
    }
}
