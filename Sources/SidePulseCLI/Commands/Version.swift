import Foundation
import SidePulseCore

/// `sidepulse version` / `--version` / `-V`.
enum VersionCommand: CLICommand {
    static let spec = CommandSpec(name: "version", synopsis: "", summary: "Print the version")

    static var versionLine: String { "sidepulse \(SidePulseConstants.version)" }

    static func run(_ arguments: ParsedArguments, _ env: CLIEnvironment) throws -> Int32 {
        env.stdout.line(versionLine)
        return ExitCode.ok
    }
}
