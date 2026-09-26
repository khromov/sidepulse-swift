import Foundation
import SidePulseCore

/// Exits 1 not only when a step failed but also when nothing at all was installed (no agent found
/// and no app).
enum SetupCommand: CLICommand {
    static let spec = CommandSpec(
        name: "setup",
        synopsis: "[claude|codex|all]... [--no-app] [--dry-run] [--no-migrate] [--no-trust]",
        summary: "Install agent hooks and start the menu-bar app",
        details: "Removes the Python SidePulse background agents, installs hooks for the detected\n"
            + "agents (or the named ones) and installs the SidePulse app LaunchAgent\n"
            + "(starts at login).",
        positionals: ProviderSelection.positionals,
        options: [
            OptionSpec("no-app", help: "only install hooks; do not install/start the menu-bar app"),
            OptionSpec("dry-run", help: "show what would change without changing anything"),
            OptionSpec("no-migrate", help: "leave the Python SidePulse LaunchAgents alone"),
            OptionSpec("no-trust", help: "do not mark the Codex hooks trusted"),
        ]
    )

    enum AppStep { case installed, notFound, failed, skipped }

    static func run(_ arguments: ParsedArguments, _ env: CLIEnvironment) throws -> Int32 {
        let dryRun = arguments.has("dry-run")
        var succeeded = true

        if !arguments.has("no-migrate") {
            let messages = env.launchAgent.migrateLegacy(dryRun)
            if messages.isEmpty {
                env.stdout.line("legacy: no Python SidePulse background agents found")
            } else {
                messages.forEach { env.stdout.line("legacy: \($0)") }
            }
        }

        let providers = ProviderSelection.resolve(arguments.positionals, paths: env.paths, defaultToDetected: true)
        if providers.isEmpty {
            env.stdout.line("hooks: skipped. \(ProviderSelection.noAgentsMessage)")
        } else if !InstallCommand.installHooks(providers, env: env, dryRun: dryRun, trust: !arguments.has("no-trust")) {
            succeeded = false
        }

        let app = arguments.has("no-app") ? AppStep.skipped : installApp(env, dryRun: dryRun)
        if app == .failed { succeeded = false }

        env.stdout.line("")
        if dryRun {
            env.stdout.line("Dry run: nothing was changed.")
        } else if !succeeded {
            env.stdout.line("Setup finished with errors (see above). Run 'sidepulse doctor' for details.")
        } else if providers.isEmpty {
            env.stdout.line("SidePulse is not set up yet: no agent hooks were installed. Install Claude Code or "
                + "Codex, then run 'sidepulse setup' again (or name the agent: 'sidepulse setup claude').")
            return app == .installed ? ExitCode.ok : ExitCode.failure
        } else if app == .notFound {
            env.stdout.line("Hooks are installed, but the SidePulse app was not found, so nothing shows their "
                + "status yet. Install it with scripts/install.sh.")
        } else {
            env.stdout.line("SidePulse is set up. New agent sessions report their status; "
                + "run 'sidepulse doctor' to check the hooks and the app.")
        }
        return succeeded ? ExitCode.ok : ExitCode.failure
    }

    static func installApp(_ env: CLIEnvironment, dryRun: Bool) -> AppStep {
        let plist = "  plist: \(env.launchAgent.plistPath.path)"
        guard let binary = env.appLocator.locate() else {
            env.stdout.line("app: not found; skipped")
            env.stdout.line("  \(env.appLocator.notFoundMessage)")
            return .notFound
        }
        if dryRun {
            env.stdout.line("app: would install and start")
        } else {
            do {
                env.stdout.line("app: \(try AppLauncher.install(env, binary: binary))")
            } catch {
                env.stderr.line("app: launch agent failed")
                env.stderr.line(plist)
                env.stderr.line("  error: \(ErrorText.describe(error))")
                return .failed
            }
        }
        env.stdout.line(plist)
        env.stdout.line("  binary: \(binary)")
        return .installed
    }
}
