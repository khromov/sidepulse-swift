import Foundation
import SidePulseCore

/// `sidepulse settings`: asks the app to open its Settings window (`open-settings`
/// socket command, acknowledged with `ok`). When nobody answers, starts the app
/// (`AppLauncher.start`, which never changes the login item) and retries for up to
/// `startupTimeout` seconds. An
/// instance that answers `ping` but not `open-settings` is the headless runtime,
/// which cannot show a window: that is reported instead of starting a second copy.
enum SettingsCommand: CLICommand {
    static let spec = CommandSpec(
        name: "settings",
        synopsis: "",
        summary: "Open the SidePulse settings window (starts the app if needed)"
    )

    static let startupTimeout: TimeInterval = 5
    static let retryInterval: TimeInterval = 0.1

    static func run(_ arguments: ParsedArguments, _ env: CLIEnvironment) throws -> Int32 {
        if requestSettingsWindow(env) {
            env.stdout.line("Opened SidePulse settings.")
            return ExitCode.ok
        }
        // Something owns the socket but has no settings window: the headless runtime.
        if env.app.isRunning() {
            throw CommandFailure(message: "the running SidePulse instance has no settings window "
                + "(is 'sidepulse run' or 'sidepulse leds' running?). Stop it, then run 'sidepulse app start'.")
        }
        do {
            _ = try AppLauncher.start(env, restart: false)
        } catch {
            throw CommandFailure(message: "could not start the SidePulse app: \(ErrorText.describe(error))")
        }
        let deadline = env.now().addingTimeInterval(startupTimeout)
        repeat {
            env.sleep(retryInterval)
            if requestSettingsWindow(env) {
                env.stdout.line("Opened SidePulse settings.")
                return ExitCode.ok
            }
        } while env.now() < deadline
        throw CommandFailure(message: "Could not open SidePulse settings. Check \(env.paths.appLogFile.path).")
    }

    static func requestSettingsWindow(_ env: CLIEnvironment) -> Bool {
        AppConnection.isOK(env.app.request("open-settings", JSONObject(), 1))
    }
}
