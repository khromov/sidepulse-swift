import Foundation
import SidePulseCore

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

    static func programText(_ argument: String?, stdin: StandardInput) -> String? {
        if argument == "-" { return String(decoding: stdin.readAll(), as: UTF8.self) }
        if let argument { return argument }
        // Never block on a terminal or on a pipe nobody writes to.
        guard !stdin.isTTY, stdin.hasPendingData(0.25) else { return nil }
        let piped = String(decoding: stdin.readAll(), as: UTF8.self)
        return isBlankAfterDecoding(piped) ? nil : piped
    }

    /// Python strips the implicit stdin program after decoding, so a piped literal `\n` counts as
    /// no program too.
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

    /// Not `standardizedFileURL`, which strips a leading `/private` and would key settings
    /// differently from `DeviceCandidate.id`.
    static func deviceID(forTarget target: URL) -> String {
        target.deletingLastPathComponent().standardized.path
    }

    /// Settings match device ids exactly, so a typed path is matched to the device the app discovers.
    static func discoveredDevice(forTarget target: URL, env: CLIEnvironment) -> DeviceCandidate? {
        let volume = URL(fileURLWithPath: deviceID(forTarget: target), isDirectory: true)
        guard ProviderSelection.directoryExists(volume) else { return nil }
        return DeviceDiscovery.candidate(forVolume: volume, among: DeviceDiscovery.discover(roots: env.mountRoots))
    }

    /// Skips unmounted volumes because the write is about to fail, and never saves Manual for a
    /// volume that is not a discovered device, which would leave a phantom device in settings.
    static func coordinateWithApp(target: URL, manual: Bool, dryRun: Bool, env: CLIEnvironment,
                                  volumeExists: (String) -> Bool = { ProviderSelection.directoryExists(URL(fileURLWithPath: $0)) },
                                  resolveDevice: ((URL) -> DeviceCandidate?)? = nil) {
        let volume = deviceID(forTarget: target)
        guard volumeExists(volume) else { return }
        guard let device = resolveDevice.map({ $0(target) }) ?? discoveredDevice(forTarget: target, env: env) else {
            if manual {
                env.stderr.line("\(prefix): warning: --manual ignored: \(volume) is not a SidePulse device the app "
                    + "drives, so nothing was switched to Manual.")
            }
            return
        }
        let id = device.id
        let store = SettingsStore(url: env.paths.settingsFile)
        guard store.load().display(forDevice: id) == .agent else { return }
        let name = device.displayName

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
        // The app waits up to 2 s for an LED write to this device started with the old settings, so
        // allow 3 s for the reload.
        let reply = env.app.request("reload-settings", ["device": .string(id)], 3)
        env.stdout.line("Set \(name) (\(id)) to Manual: SidePulse will not overwrite it "
            + "(switch back under Devices in the menu bar).")
        if !AppConnection.isOK(reply), reply != nil || env.app.isRunning() {
            env.stderr.line("\(prefix): warning: the SidePulse app is still writing to \(name); it may overwrite "
                + "this program. Run the command again if the LEDs do not show it.")
        }
    }
}
