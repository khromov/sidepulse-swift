import AppKit
import SidePulseCore

struct HookOutcome {
    let provider: HookProvider
    let action: HookAction
    let result: Result<InstallResult, Error>

    var message: String {
        switch result {
        case .success(let install):
            return HookPresentation.resultMessage(provider: provider, action: action, changed: install.changed)
        case .failure(let error):
            return HookPresentation.failureMessage(provider: provider, error: ErrorText.describe(error))
        }
    }

    var details: [String] {
        guard case .success(let install) = result else { return [] }
        return HookPresentation.detailLines(notes: install.notes, backupPath: install.backupPath?.path,
                                            configPath: install.configPath.path)
    }
}

@MainActor
final class AppServices {
    let runtime: SidePulseRuntime

    init(runtime: SidePulseRuntime) {
        self.runtime = runtime
    }

    var paths: SidePulsePaths { runtime.paths }

    // MARK: Hooks

    func hookStates() -> [HookState] {
        HookDoctor.inspectAll(paths: paths)
    }

    var hookCLIPath: String? {
        HookCLIPath.resolve(paths: paths)
    }

    /// Runs off the main thread because the Codex trust refresh can take seconds.
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
                    completion(outcome)
                }
            }
        }
    }

    // MARK: Launch at login

    private var launchAgent: LaunchAgentManager { LaunchAgentManager(paths: paths) }

    var launchAtLoginEnabled: Bool {
        FileManager.default.fileExists(atPath: paths.launchAgentPlist(label: launchAgent.label).path)
    }

    /// When this process was started by the LaunchAgent, disabling only deletes the plist because `bootout`
    /// would kill the app.
    func setLaunchAtLogin(_ enabled: Bool) throws {
        let manager = launchAgent
        if enabled {
            let executable = SidePulsePaths.currentExecutablePath
            try AppTranslocated.check(executable)
            try manager.install(programArguments: [executable], start: false)
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
}
