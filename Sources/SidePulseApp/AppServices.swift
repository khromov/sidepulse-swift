import AppKit
import SidePulseCore

/// The outcome of a hook install/uninstall, ready for an alert or the settings window.
struct HookOutcome {
    let provider: HookProvider
    let action: HookAction
    let result: Result<InstallResult, Error>

    var succeeded: Bool {
        if case .success = result { return true }
        return false
    }

    /// `Codex hooks installed.` / `Codex hooks failed: …`.
    var message: String {
        switch result {
        case .success(let install):
            return HookPresentation.resultMessage(provider: provider, action: action, changed: install.changed)
        case .failure(let error):
            return HookPresentation.failureMessage(provider: provider, error: ErrorText.describe(error))
        }
    }

    /// Notes, backup and config path (empty on failure).
    var details: [String] {
        guard case .success(let install) = result else { return [] }
        return HookPresentation.detailLines(notes: install.notes, backupPath: install.backupPath?.path,
                                            configPath: install.configPath.path)
    }
}

/// Actions shared by the status menu and the settings window: hooks, launch at
/// login, the logs folder and alerts. Main-thread only.
@MainActor
final class AppServices {
    let runtime: SidePulseRuntime
    /// Called after a hook action or a Launch at Login change, whichever UI started
    /// it, so the other one (menu or settings window) can re-read that state.
    var onStateChange: (() -> Void)?

    init(runtime: SidePulseRuntime) {
        self.runtime = runtime
    }

    var paths: SidePulsePaths { runtime.paths }

    // MARK: Hooks

    /// Current hook state of every provider (reads the agent configs).
    func hookStates() -> [HookState] {
        HookDoctor.inspectAll(paths: paths)
    }

    /// CLI path for new hook commands (`HookCLIPath.resolve`): the stable
    /// `~/.local/bin/sidepulse` when it is ours, else the bundled helper; nil when
    /// neither exists (never the menu-bar binary).
    var hookCLIPath: String? {
        HookCLIPath.resolve(paths: paths)
    }

    /// Runs the installer off the main thread (Codex trust refresh can take seconds),
    /// logs the result, refreshes the runtime and calls `completion` on the main thread.
    func performHook(_ action: HookAction, provider: HookProvider,
                     completion: @escaping @MainActor (HookOutcome) -> Void) {
        let paths = self.paths
        let cliPath = hookCLIPath
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result<InstallResult, Error> {
                var result = try HookInstaller.perform(action, provider: provider, paths: paths, cliPath: cliPath)
                if action == .install, let note = HookCLIPath.foreignLinkNote(paths: paths) { result.notes.append(note) }
                return result
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let outcome = HookOutcome(provider: provider, action: action, result: result)
                    DiagnosticsLog.shared.log("settings: \(outcome.message)")
                    self.runtime.refresh()
                    self.onStateChange?()
                    completion(outcome)
                }
            }
        }
    }

    /// Alert with the outcome's message and details.
    func showHookOutcome(_ outcome: HookOutcome) {
        Self.showAlert(title: outcome.message, message: outcome.details.joined(separator: "\n"),
                       style: outcome.succeeded ? .informational : .warning)
    }

    // MARK: Launch at login

    private var launchAgent: LaunchAgentManager { LaunchAgentManager(paths: paths) }

    /// The LaunchAgent plist exists.
    var launchAtLoginEnabled: Bool {
        FileManager.default.fileExists(atPath: paths.launchAgentPlist(label: launchAgent.label).path)
    }

    /// Enabling writes the plist for the running app binary without starting a second
    /// instance. Disabling removes it; when this process was itself started by that
    /// LaunchAgent only the plist is deleted, because `bootout` would kill the app.
    func setLaunchAtLogin(_ enabled: Bool) throws {
        defer { onStateChange?() }
        let manager = launchAgent
        if enabled {
            try manager.install(programArguments: [SidePulsePaths.currentExecutablePath], start: false)
        } else if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == manager.label {
            let plist = paths.launchAgentPlist(label: manager.label)
            if FileManager.default.fileExists(atPath: plist.path) {
                try FileManager.default.removeItem(at: plist)
            }
        } else {
            try manager.uninstall()
        }
        DiagnosticsLog.shared.log("settings: launch at login \(enabled ? "enabled" : "disabled")")
    }

    // MARK: Misc

    /// Reveals `logs/` (next to `app.log` and `settings.json`) in Finder.
    func openLogsFolder() {
        try? paths.ensureDirectories()
        NSWorkspace.shared.activateFileViewerSelecting([paths.logsDir])
    }

    static func showAlert(title: String, message: String, style: NSAlert.Style = .informational) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.runModal()
    }

    /// Two-button confirmation; true when the user picked `confirmTitle`.
    static func confirm(title: String, message: String, confirmTitle: String) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
