import Foundation
import SidePulseCore

enum UninstallCommand: CLICommand {
    static let spec = CommandSpec(
        name: "uninstall",
        synopsis: "[claude|codex|all]... [--dry-run]",
        summary: "Remove agent hooks",
        details: "Removes SidePulse hooks (including Python-era ones) from ~/.claude/settings.json\n"
            + "and ~/.codex/config.toml. Other hooks are left untouched.",
        positionals: ProviderSelection.positionals,
        options: [OptionSpec("dry-run", help: "show what would change without writing")]
    )

    static func run(_ arguments: ParsedArguments, _ env: CLIEnvironment) throws -> Int32 {
        let providers = ProviderSelection.resolve(arguments.positionals, paths: env.paths, defaultToDetected: false)
        let dryRun = arguments.has("dry-run")
        var succeeded = true
        for provider in providers {
            do {
                let result = try env.hooks.uninstall(provider, env.paths, dryRun)
                env.stdout.line(InstallText.render(result, action: .uninstall))
            } catch {
                succeeded = false
                env.stderr.line(InstallText.renderFailure(provider: provider, configPath: provider.configFile(env.paths),
                                                          message: ErrorText.describe(error), action: .uninstall))
            }
        }
        return succeeded ? ExitCode.ok : ExitCode.failure
    }
}
