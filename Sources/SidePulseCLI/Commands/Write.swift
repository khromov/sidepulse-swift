import Foundation
import SidePulseCore

/// `sidepulse write [PROGRAM|-] [--device P] [--file-name NAME] [--dry-run] [--manual]`
///
/// 1. Program: the argument, all of stdin for `-`, or piped stdin when no argument
///    is given (whitespace-only piped input counts as none). Escapes (`\n` `\r`
///    `\t` `\\`) are decoded exactly once, then the program is validated
///    (512 bytes / 20 lines).
/// 2. Target: `--device`, else the single discovered SidePulse volume.
/// 3. The app shows agent status on devices in Agent mode and would restore it at
///    its next update: `--manual` switches the device to Manual first (and asks a
///    running app to reload settings); otherwise a running app earns a warning.
/// 4. Writes `LEDS.LED` in place (`LedWriter`).
///
/// Exit codes: 0 ok, 2 invalid program / no or ambiguous device, 1 write failure.
enum WriteCommand: CLICommand {
    static let spec = CommandSpec(
        name: "write",
        synopsis: "[PROGRAM|-] [--device PATH] [--file-name NAME] [--dry-run] [--manual]",
        summary: "Write an LED program to a SidePulse device",
        details: "PROGRAM is LED DSL text; \\n, \\r, \\t and \\\\ escapes are decoded. Use '-' (or pipe\n"
            + "into sidepulse write) to read the program from stdin. Example:\n"
            + "  sidepulse write 'off\\n#FF3A00 pulse\\nrepeat'",
        positionals: PositionalSpec(name: "program"),
        options: [
            OptionSpec("device", value: "PATH", help: "device volume or its LEDS.LED (default: auto-discover)"),
            OptionSpec("file-name", value: "NAME", help: "file to write on the volume (default LEDS.LED)"),
            OptionSpec("dry-run", help: "validate and print the program without writing"),
            OptionSpec("manual", help: "switch the device to Manual so the app leaves it alone"),
        ]
    )

    static let prefix = "sidepulse write"

    static func run(_ arguments: ParsedArguments, _ env: CLIEnvironment) throws -> Int32 {
        let dryRun = arguments.has("dry-run")
        guard let raw = programText(arguments.positionals.first, stdin: env.stdin) else {
            throw CommandFailure(message: "Provide an LED program (as an argument, '-' or on stdin).",
                                 exitCode: ExitCode.usage)
        }
        let program = LedText.decodeEscapes(raw)
        do {
            try LedText.validate(program)
        } catch {
            throw CommandFailure(message: ErrorText.describe(error), exitCode: ExitCode.usage)
        }

        let target: URL
        do {
            target = try DeviceDiscovery.resolveTarget(
                devicePath: arguments.value("device"),
                fileName: arguments.value("file-name") ?? DeviceDiscovery.fileName,
                roots: env.mountRoots
            )
        } catch {
            throw CommandFailure(message: ErrorText.describe(error), exitCode: ExitCode.usage)
        }

        coordinateWithApp(target: target, manual: arguments.has("manual"), dryRun: dryRun, env: env)

        if dryRun {
            env.stdout.line("Would write to \(target.path):")
            env.stdout.line(program.hasSuffix("\n") ? String(program.dropLast()) : program)
            return ExitCode.ok
        }
        do {
            try LedWriter.write(program, to: target)
        } catch {
            throw CommandFailure(message: ErrorText.describe(error), exitCode: ExitCode.failure)
        }
        env.stdout.line("Wrote \(program.utf8.count) bytes to \(target.path)")
        return ExitCode.ok
    }

    /// The raw (undecoded) program text, or nil when none was given.
    static func programText(_ argument: String?, stdin: StandardInput) -> String? {
        if argument == "-" { return String(decoding: stdin.readAll(), as: UTF8.self) }
        if let argument { return argument }
        // Implicit stdin: only when something is actually piped in (never block on a
        // terminal or on a pipe nobody writes to).
        guard !stdin.isTTY, stdin.hasPendingData(0.25) else { return nil }
        let piped = String(decoding: stdin.readAll(), as: UTF8.self)
        return isBlankAfterDecoding(piped) ? nil : piped
    }

    /// True when `raw` decodes (`LedText.decodeEscapes`) to whitespace only: every
    /// character is whitespace or one of the escapes `\n`, `\r`, `\t`. Python strips
    /// the implicit stdin program after decoding, so a piped literal `\n` is "no
    /// program" too.
    static func isBlankAfterDecoding(_ raw: String) -> Bool {
        var characters = raw.makeIterator()
        while let character = characters.next() {
            if character == "\\" {
                guard let escaped = characters.next(), ["n", "r", "t"].contains(escaped) else { return false }
            } else if !character.isWhitespace {
                return false
            }
        }
        return true
    }

    /// Device id used in settings: the volume root path, as `DeviceCandidate.id`
    /// spells it for the same volume. Only `.`/`..` segments are removed:
    /// `standardizedFileURL` would also strip a leading `/private` from existing
    /// paths, and settings would then be keyed differently from the runtime's.
    static func deviceID(forTarget target: URL) -> String {
        target.deletingLastPathComponent().standardized.path
    }

    /// `--manual` handling and the "the app will restore agent status" warning.
    /// Nothing happens for a volume that is not mounted: the write is about to fail,
    /// and a Manual entry for it would only leave a phantom device in settings.
    static func coordinateWithApp(target: URL, manual: Bool, dryRun: Bool, env: CLIEnvironment,
                                  volumeExists: (String) -> Bool = { ProviderSelection.directoryExists(URL(fileURLWithPath: $0)) }) {
        let id = deviceID(forTarget: target)
        guard volumeExists(id) else { return }
        let store = SettingsStore(url: env.paths.settingsFile)
        guard store.load().display(forDevice: id) == .agent else { return }
        let name = DeviceDiscovery.displayName(forVolumeName: URL(fileURLWithPath: id).lastPathComponent)

        guard manual else {
            if env.app.isRunning() {
                env.stderr.line("\(prefix): note: the SidePulse app shows agent status on \(name) and will restore it "
                    + "at its next update. Pass --manual to switch this device to Manual.")
            }
            return
        }
        if dryRun {
            env.stdout.line("Would set \(name) (\(id)) to Manual.")
            return
        }
        do {
            try store.update { $0.setDisplay(.manual, forDevice: id, name: name, path: id) }
        } catch {
            env.stderr.line("\(prefix): could not switch \(name) to Manual: \(ErrorText.describe(error))")
            return
        }
        // Make a running app pick the change up before we write. The app waits up to
        // 2 s for an LED write that started with the old settings, so allow 3 s.
        let reply = env.app.request("reload-settings", JSONObject(), 3)
        env.stdout.line("Set \(name) (\(id)) to Manual: SidePulse will not overwrite it "
            + "(switch back under Devices in the menu bar).")
        if !AppConnection.isOK(reply), reply != nil || env.app.isRunning() {
            env.stderr.line("\(prefix): warning: the SidePulse app is still writing to \(name); it may overwrite "
                + "this program. Run the command again if the LEDs do not show it.")
        }
    }
}
