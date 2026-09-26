import Foundation
import SidePulseCore

/// `sidepulse install [claude|codex|all]... [--dry-run] [--no-trust]`
///
/// Without a provider, installs hooks for every agent whose config directory
/// exists (`~/.claude`, `~/.codex`) so we never create configs for agents that
/// are not installed. Hook commands call `HookCLIPath.resolve`. A provider that
/// fails (e.g. malformed JSON) is reported and the others are still processed;
/// the exit code is then 1.
enum InstallCommand: CLICommand {
    static let spec = CommandSpec(
        name: "install",
        synopsis: "[claude|codex|all]... [--dry-run] [--no-trust]",
        summary: "Install agent hooks (Claude Code, Codex)",
        details: "Without a provider, installs hooks for each agent whose config directory exists\n"
            + "(~/.claude, ~/.codex). Python-era SidePulse hooks are replaced.",
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

    /// Installs and prints one block per provider (shared with `setup`). Returns
    /// false if any provider failed.
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

    /// Hook commands must survive rebuilds and app updates (Codex trust hashes bind
    /// to the exact command). Warn when they point at a transient binary.
    static func unstableCLINote(cliPath: String, env: CLIEnvironment) -> String? {
        if let explicit = env.variables["SIDEPULSE_CLI_PATH"], !explicit.isEmpty { return nil }
        if cliPath == env.paths.defaultCLILink.path || HookCLIPath.enclosingBundle(of: cliPath) != nil { return nil }
        return "note: the hooks call \(cliPath). Install SidePulse with scripts/install.sh so they use the stable "
            + "\(env.paths.defaultCLILink.path) and keep working after rebuilds."
    }
}

/// Which providers `install` / `uninstall` / `setup` act on.
enum ProviderSelection {
    static let positionals = PositionalSpec(name: "provider", maxCount: 3, choices: ["claude", "codex", "all"])

    static let noAgentsMessage = "No Claude Code (~/.claude) or Codex (~/.codex) config found, so no hooks were installed. "
        + "Install an agent first, or name it explicitly (sidepulse install claude)."

    /// Named providers (in `HookProvider.allCases` order, `all` = every provider);
    /// with none named, either the detected ones or all of them.
    static func resolve(_ names: [String], paths: SidePulsePaths, defaultToDetected: Bool,
                        directoryExists: (URL) -> Bool = directoryExists) -> [HookProvider] {
        if names.contains("all") { return HookProvider.allCases }
        if !names.isEmpty { return HookProvider.allCases.filter { names.contains($0.rawValue) } }
        guard defaultToDetected else { return HookProvider.allCases }
        return HookProvider.allCases.filter { directoryExists($0.configDir(paths)) }
    }

    static func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
