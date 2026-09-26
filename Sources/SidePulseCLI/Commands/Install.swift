import Foundation
import SidePulseCore

/// Without a provider only agents that look installed get hooks, so we never create configs for agents
/// that aren't installed.
enum InstallCommand: CLICommand {
    static let spec = CommandSpec(
        name: "install",
        synopsis: "[claude|codex|opencode|all]... [--dry-run] [--no-trust]",
        summary: "Install agent hooks (Claude Code, Codex, OpenCode)",
        details: "Without a provider, installs hooks for each agent that looks installed\n"
            + "(~/.claude, ~/.codex, ~/.config/opencode or an opencode binary).\n"
            + "Python-era SidePulse hooks are replaced. OpenCode gets the SidePulse plugin\n"
            + "~/.config/opencode/plugins/sidepulse.js.",
        positionals: ProviderSelection.positionals,
        options: [
            OptionSpec("dry-run", help: "show what would change without writing"),
            OptionSpec("no-trust", help: "do not mark the Codex hooks trusted (approve them with /hooks)"),
        ]
    )

    static func run(_ arguments: ParsedArguments, _ env: CLIEnvironment) throws -> Int32 {
        let providers = ProviderSelection.resolve(arguments.positionals, paths: env.paths, defaultToDetected: true)
        guard !providers.isEmpty else {
            env.stdout.line(ProviderSelection.noAgentsMessage)
            return ExitCode.ok
        }
        let succeeded = installHooks(providers, env: env, dryRun: arguments.has("dry-run"),
                                     trust: !arguments.has("no-trust"))
        return succeeded ? ExitCode.ok : ExitCode.failure
    }

    static func installHooks(_ providers: [HookProvider], env: CLIEnvironment, dryRun: Bool, trust: Bool) -> Bool {
        if let note = HookCLIPath.foreignLinkNote(paths: env.paths, runningExecutable: env.executablePath) {
            env.stderr.line("note: \(note)")
        }
        guard let cliPath = HookCLIPath.resolve(paths: env.paths, runningExecutable: env.executablePath) else {
            env.stderr.line("hooks: not installed. \(HookCLIPath.notFoundMessage)")
            return false
        }
        var succeeded = true
        for provider in providers {
            do {
                let result = try env.hooks.install(provider, env.paths, cliPath, dryRun, trust)
                env.stdout.line(InstallText.render(result, action: .install,
                                                   logPath: env.paths.logFile(for: provider.rawValue)))
            } catch {
                succeeded = false
                env.stderr.line(InstallText.renderFailure(provider: provider, configPath: provider.configFile(env.paths),
                                                          message: ErrorText.describe(error), action: .install))
            }
        }
        if let note = unstableCLINote(cliPath: cliPath, env: env) { env.stderr.line(note) }
        return succeeded
    }

    /// Hook commands must survive rebuilds and app updates because Codex trust hashes bind to the
    /// exact command.
    static func unstableCLINote(cliPath: String, env: CLIEnvironment) -> String? {
        if let explicit = env.variables["SIDEPULSE_CLI_PATH"], !explicit.isEmpty { return nil }
        if cliPath == env.paths.defaultCLILink.path || HookCLIPath.enclosingBundle(of: cliPath) != nil { return nil }
        return "note: the hooks call \(cliPath). Install SidePulse with scripts/install.sh so they use the stable "
            + "\(env.paths.defaultCLILink.path) and keep working after rebuilds."
    }
}

enum ProviderSelection {
    static let positionals = PositionalSpec(name: "provider", maxCount: HookProvider.allCases.count + 1,
                                            choices: HookProvider.allCases.map(\.rawValue) + ["all"])

    static let noAgentsMessage = "No Claude Code (~/.claude), Codex (~/.codex) or OpenCode (~/.config/opencode) found, "
        + "so no hooks were installed. Install an agent first, or name it explicitly (sidepulse install claude)."

    static func resolve(_ names: [String], paths: SidePulsePaths, defaultToDetected: Bool) -> [HookProvider] {
        if names.contains("all") { return HookProvider.allCases }
        if !names.isEmpty { return HookProvider.allCases.filter { names.contains($0.rawValue) } }
        guard defaultToDetected else { return HookProvider.allCases }
        return HookProvider.allCases.filter { $0.isDetected(paths) }
    }

    static func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
