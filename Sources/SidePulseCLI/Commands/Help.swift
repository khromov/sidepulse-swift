import Foundation
import SidePulseCore

enum HelpCommand: CLICommand {
    static let spec = CommandSpec(
        name: "help",
        synopsis: "[COMMAND]",
        summary: "Show help for sidepulse or one command",
        positionals: PositionalSpec(name: "command")
    )

    static func run(_ arguments: ParsedArguments, _ env: CLIEnvironment) throws -> Int32 {
        guard let name = arguments.positionals.first else {
            env.stdout.line(overview)
            return ExitCode.ok
        }
        guard let command = SidePulseCLI.command(named: name) else {
            throw UsageError("unknown command '\(name)'")
        }
        env.stdout.line(command.spec.helpText)
        return ExitCode.ok
    }

    static var overview: String {
        var rows: [(String, String)] = []
        for command in SidePulseCLI.commands {
            rows.append((command.spec.name, command.spec.summary))
            if command == LedsCommand.self { rows.append((RunCommand.spec.name, RunCommand.spec.summary)) }
        }
        let width = rows.map(\.0.count).max() ?? 0
        var lines = [
            "usage: sidepulse <command> [options]",
            "",
            "SidePulse shows Claude Code, Codex and OpenCode agent status on SidePulse",
            "Pro / Dot LEDs and in the menu bar.",
            "",
            "commands:",
        ]
        for (name, summary) in rows {
            lines.append("  \(name.padding(toLength: width, withPad: " ", startingAt: 0))  \(summary)")
        }
        lines += [
            "",
            "Run 'sidepulse <command> --help' for the options of a command.",
            "-V, --version prints the version.",
        ]
        return lines.joined(separator: "\n")
    }
}
