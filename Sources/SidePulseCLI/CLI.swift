import Foundation
import SidePulseCore

/// `run` throws `UsageError` for exit 2 with usage, `CommandFailure` for its own exit code, and
/// anything else for exit 1.
protocol CLICommand {
    static var spec: CommandSpec { get }
    static func run(_ arguments: ParsedArguments, _ env: CLIEnvironment) throws -> Int32
}

/// A leading `agent-monitor` token, the Python CLI's legacy command tree, is accepted and ignored.
public enum SidePulseCLI {
    /// Commands in the order `sidepulse --help` lists them.
    static let commands: [any CLICommand.Type] = [
        SetupCommand.self, StatusCommand.self, WriteCommand.self, LedsCommand.self,
        InstallCommand.self, UninstallCommand.self, DoctorCommand.self, AppCommand.self,
        SettingsCommand.self, VersionCommand.self, HelpCommand.self,
    ]

    /// Hidden from the help listing, except `run`.
    static let aliases: [String: any CLICommand.Type] = [
        "status-bar": AppCommand.self,
        "run": RunCommand.self,
    ]

    static func command(named name: String) -> (any CLICommand.Type)? {
        commands.first { $0.spec.name == name } ?? aliases[name]
    }

    public static func main(_ arguments: [String]) -> Int32 {
        // The hook path runs inside every agent hook: dispatch before anything else,
        // never print, always exit 0.
        if let hookArguments = hookLogArguments(arguments) {
            return HookRuntime.runFromProcess(arguments: hookArguments)
        }
        return run(arguments, environment: .live())
    }

    /// Tests call this directly with a fake `env`.
    public static func run(_ arguments: [String], environment env: CLIEnvironment) -> Int32 {
        if let hookArguments = hookLogArguments(arguments) {
            return HookRuntime.run(arguments: hookArguments, stdin: env.stdin.readAll(),
                                   environment: env.variables, paths: env.paths)
        }

        var arguments = arguments
        let legacyPrefix = arguments.first == "agent-monitor"
        if legacyPrefix { arguments.removeFirst() }

        guard let name = arguments.first else {
            if legacyPrefix {
                env.stderr.line("usage: sidepulse <command> [options]")
                env.stderr.line("sidepulse: error: the following arguments are required: command")
                return ExitCode.usage
            }
            env.stdout.line(HelpCommand.overview)
            return ExitCode.ok
        }
        switch name {
        case "-h", "--help":
            env.stdout.line(HelpCommand.overview)
            return ExitCode.ok
        case "-V", "--version":
            env.stdout.line(VersionCommand.versionLine)
            return ExitCode.ok
        default:
            break
        }
        guard let command = command(named: name) else {
            env.stderr.line("usage: sidepulse <command> [options]")
            env.stderr.line("sidepulse: error: unknown command '\(name)' (run 'sidepulse --help' for the list)")
            return ExitCode.usage
        }

        let spec = command.spec
        do {
            switch try ArgumentParser.parse(Array(arguments.dropFirst()), spec: spec) {
            case .help:
                env.stdout.line(spec.helpText)
                return ExitCode.ok
            case .arguments(let parsed):
                return try command.run(parsed, env)
            }
        } catch let error as UsageError {
            env.stderr.line(spec.usageLine)
            env.stderr.line("sidepulse \(spec.name): error: \(error.message)")
            return ExitCode.usage
        } catch let failure as CommandFailure {
            env.stderr.line("sidepulse \(spec.name): \(failure.message)")
            return failure.exitCode
        } catch {
            env.stderr.line("sidepulse \(spec.name): \(ErrorText.describe(error))")
            return ExitCode.failure
        }
    }

    /// `agent-monitor hook-log` is the form Python-era hook commands used.
    static func hookLogArguments(_ arguments: [String]) -> [String]? {
        if arguments.first == "hook-log" { return Array(arguments.dropFirst()) }
        if arguments.count >= 2, arguments[0] == "agent-monitor", arguments[1] == "hook-log" {
            return Array(arguments.dropFirst(2))
        }
        return nil
    }
}
