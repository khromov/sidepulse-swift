import Foundation
import SidePulseCore

/// `sidepulse run`: `leds` in the foreground (no `--once`).
enum RunCommand: CLICommand {
    static let spec = CommandSpec(
        name: "run",
        synopsis: "[--dry-run] [--interval SECONDS]",
        summary: "Run the headless SidePulse runtime in the foreground",
        options: LedsCommand.foregroundOptions
    )

    static func run(_ arguments: ParsedArguments, _ env: CLIEnvironment) throws -> Int32 {
        try LedsCommand.foreground(arguments, env: env)
    }
}
