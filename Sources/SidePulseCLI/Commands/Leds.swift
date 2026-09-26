import Foundation
import SidePulseCore

/// `--once` exits 2 on any device error, as the Python CLI does.
enum LedsCommand: CLICommand {
    static let spec = CommandSpec(
        name: "leds",
        synopsis: "[--once] [--dry-run] [--device PATH] [--interval SECONDS]",
        summary: "Mirror agent status to the LEDs (headless)",
        details: "Without --once, runs the SidePulse runtime in the foreground (like the menu-bar\n"
            + "app, without UI) until Ctrl-C. It refuses to start while the app is running.",
        options: foregroundOptions + [
            OptionSpec("once", help: "sync once and exit (2 on error)"),
            OptionSpec("device", value: "PATH", help: "with --once: only this device volume (or its LEDS.LED)"),
        ]
    )

    static let foregroundOptions = [
        OptionSpec("dry-run", help: "compute programs but never write them"),
        OptionSpec("interval", value: "SECONDS", help: "status refresh interval in the foreground (default 15)"),
    ]

    static func run(_ arguments: ParsedArguments, _ env: CLIEnvironment) throws -> Int32 {
        if arguments.has("once") {
            return once(device: arguments.value("device"), dryRun: arguments.has("dry-run"), env: env)
        }
        if arguments.value("device") != nil {
            throw UsageError("--device requires --once (the foreground runtime drives every connected device; "
                + "use SIDEPULSE_MOUNT_ROOTS to limit discovery)")
        }
        return try foreground(arguments, env: env)
    }

    // MARK: --once

    static func once(device: String?, dryRun: Bool, env: CLIEnvironment) -> Int32 {
        let (snapshot, _) = env.snapshots.load(env, offline: false)
        let mode = snapshot.aggregate.mode
        let state = mode.displayState.label
        let settings = SettingsStore(url: env.paths.settingsFile).load()

        if let device {
            let target: URL
            do {
                target = try DeviceDiscovery.resolveTarget(devicePath: device, roots: env.mountRoots)
            } catch {
                env.stdout.line(LedsText.errorLine(state: state, message: ErrorText.describe(error)))
                return ExitCode.usage
            }
            let id = WriteCommand.discoveredDevice(forTarget: target, env: env)?.id ?? WriteCommand.deviceID(forTarget: target)
            let controller = AgentLedController(target: target, brightness: settings.brightness(forDevice: id),
                                                dryRun: dryRun)
            let result = controller.sync(mode: mode, animationID: settings.animationID(for: mode))
            env.stdout.line(LedsText.render(result, snapshot: snapshot, dryRun: dryRun))
            return result.error == nil ? ExitCode.ok : ExitCode.usage
        }

        let service = LedSyncService(settings: { settings }, roots: env.mountRoots, dryRun: dryRun)
        service.pollDevices()
        let devices = service.connectedDevices.sorted { $0.id < $1.id }
        guard !devices.isEmpty else {
            env.stdout.line(LedsText.errorLine(state: state, message: ErrorText.describe(LedError.noDevice)))
            return ExitCode.usage
        }
        let results = service.syncNow(mode: mode)
        var failed = false
        for device in devices {
            if settings.display(forDevice: device.id) == .manual {
                env.stdout.line("LEDs: skipped \(device.displayName) at \(device.root.path) (Manual)")
                continue
            }
            guard let result = results[device.id] else {
                env.stdout.line("LEDs: skipped \(device.displayName) at \(device.root.path) (not synced)")
                continue
            }
            if result.error != nil { failed = true }
            env.stdout.line(LedsText.render(result, snapshot: snapshot, dryRun: dryRun))
        }
        return failed ? ExitCode.usage : ExitCode.ok
    }

    // MARK: Foreground runtime

    static func foreground(_ arguments: ParsedArguments, env: CLIEnvironment) throws -> Int32 {
        var options = RuntimeOptions()
        options.dryRun = arguments.has("dry-run")
        options.refreshInterval = try arguments.double("interval", default: options.refreshInterval,
                                                       minimum: 0, exclusive: true)
        if env.variables["SIDEPULSE_MOUNT_ROOTS"] != nil { options.mountRoots = env.mountRoots }

        if env.app.isRunning() {
            throw CommandFailure(message: AppLauncher.ownerRefusal(
                env, app: "the SidePulse app is running and already drives the LEDs. "
                    + "Stop it first (sidepulse app stop) or use 'sidepulse leds --once'.",
                headlessAlternative: ", or use 'sidepulse leds --once'"))
        }

        DiagnosticsLog.shared.url = env.paths.appLogFile
        DiagnosticsLog.shared.echo = true

        let runtime = SidePulseRuntime(paths: env.paths, options: options)
        var lastState: DisplayState?
        let stderr = env.stderr
        runtime.onUpdate = { snapshot in
            let state = snapshot.aggregate.mode.displayState
            guard state != lastState else { return }
            lastState = state
            stderr.line("LEDs: \(state.label) (aggregate=\(snapshot.aggregate.mode.label), "
                + "active=\(snapshot.aggregate.activeCount))")
        }
        // Trap Ctrl-C before starting so an early signal still stops cleanly.
        let trap = SignalTrap()
        defer { trap.cancel() }
        do {
            try runtime.start()
        } catch {
            throw CommandFailure(message: ErrorText.describe(error))
        }
        env.stderr.line("SidePulse runtime running in the foreground\(options.dryRun ? " (dry run)" : "") "
            + "on \(env.paths.socketPath). Press Ctrl-C to stop.")

        trap.runMainLoopUntilSignal()
        runtime.stop()
        DiagnosticsLog.shared.flush()
        env.stderr.line("SidePulse runtime stopped.")
        return ExitCode.ok
    }
}
