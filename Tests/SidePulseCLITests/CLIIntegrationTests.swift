import XCTest
@testable import SidePulseCLI
import SidePulseCore

/// The LaunchAgent operations stay faked and `setup` runs with `--no-app --no-migrate`, so launchd
/// is never touched.
final class CLIIntegrationTests: XCTestCase {
    /// Harnesses share temp directories within a test, so they all stay alive until it ends.
    private var harnesses: [CLIHarness] = []

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SIDEPULSE_INTEGRATION"] == "1",
                          "set SIDEPULSE_INTEGRATION=1 to run the end-to-end CLI tests")
    }

    override func tearDown() {
        harnesses.removeAll()
        super.tearDown()
    }

    private func makeHarness(_ extra: [String: String] = [:]) -> CLIHarness {
        let harness = CLIHarness(variables: extra, now: Date())
        harnesses.append(harness)
        harness.env.now = Date.init
        harness.env.snapshots = .standard
        harness.env.hooks = .standard
        harness.env.app = .socket(path: harness.paths.socketPath)
        return harness
    }

    @discardableResult
    private func makeDevice(_ harness: CLIHarness, name: String = "PulseDot") throws -> URL {
        let volume = harness.root.appendingPathComponent("mounts/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        return volume
    }

    private func useTempMounts(_ harness: CLIHarness) {
        harness.env.variables["SIDEPULSE_MOUNT_ROOTS"] = harness.root.appendingPathComponent("mounts").path
    }

    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    /// Appended to from the socket server's queue, hence the lock.
    private final class CommandRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ name: String) { lock.lock(); storage.append(name); lock.unlock() }
        var names: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    private func writeLog(_ harness: CLIHarness, provider: String, records: [JSONObject]) throws {
        try harness.paths.ensureDirectories()
        let text = records.map { JSONValue.object($0).serialized() + "\n" }.joined()
        try text.write(to: harness.paths.logFile(for: provider), atomically: true, encoding: .utf8)
    }

    private func record(_ event: String, session: String, secondsAgo: Double, extra: [(String, JSONValue)] = []) -> JSONObject {
        var object: JSONObject = [
            "logged_at": .string(TimeFormat.iso8601Millis(Date().addingTimeInterval(-secondsAgo))),
            "hook_event_name": .string(event),
            "session_id": .string(session),
            "cwd": .string("/tmp/proj-\(session)"),
        ]
        for (key, value) in extra { object[key] = value }
        return object
    }

    // MARK: write

    func testWriteDiscoversTheTempDevice() throws {
        let h = makeHarness()
        useTempMounts(h)
        let volume = try makeDevice(h)
        let target = volume.appendingPathComponent("LEDS.LED")

        XCTAssertEqual(h.run(["write", "off\\n#FF00FF pulse"]), 0, h.stderr.text)
        XCTAssertEqual(read(target), "off\n#FF00FF pulse")
        XCTAssertEqual(h.stdout.text, "Wrote 17 bytes to \(target.path)\n")

        let dry = makeHarness()
        useTempMounts(dry)
        let dryVolume = try makeDevice(dry)
        XCTAssertEqual(dry.run(["write", "idle\\nrepeat", "--dry-run"]), 0)
        XCTAssertNil(read(dryVolume.appendingPathComponent("LEDS.LED")))
        XCTAssertEqual(dry.stdout.text, "Would write to \(dryVolume.appendingPathComponent("LEDS.LED").path):\nidle\nrepeat\n")
    }

    func testWriteExplicitDeviceAndStdin() throws {
        let h = makeHarness()
        let volume = h.root.appendingPathComponent("elsewhere/SidePulseDot", isDirectory: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        h.env.stdin = .data(Data("#00FF66 320ms cosine\\nrepeat".utf8))
        XCTAssertEqual(h.run(["write", "-", "--device", volume.path]), 0, h.stderr.text)
        XCTAssertEqual(read(volume.appendingPathComponent("LEDS.LED")), "#00FF66 320ms cosine\nrepeat")

        let custom = makeHarness()
        XCTAssertEqual(custom.run(["write", "off", "--device", volume.path, "--file-name", "TEST.LED"]), 0)
        XCTAssertEqual(read(volume.appendingPathComponent("TEST.LED")), "off")
    }

    func testWriteValidationAndSelectionErrors() throws {
        let h = makeHarness()
        useTempMounts(h)
        try makeDevice(h)
        let tooManyLines = Array(repeating: "off", count: 21).joined(separator: "\\n")
        XCTAssertEqual(h.run(["write", tooManyLines]), 2)
        XCTAssertEqual(h.stderr.text, "sidepulse write: LED program has 21 lines; max is 20.\n")

        let big = makeHarness()
        XCTAssertEqual(big.run(["write", String(repeating: "a", count: 513), "--device", "/nonexistent"]), 2)
        XCTAssertEqual(big.stderr.text, "sidepulse write: LED program is 513 bytes; max is 512.\n")

        let none = makeHarness()
        useTempMounts(none)
        try FileManager.default.createDirectory(at: none.root.appendingPathComponent("mounts"), withIntermediateDirectories: true)
        XCTAssertEqual(none.run(["write", "off"]), 2)
        XCTAssertTrue(none.stderr.text.contains("No SidePulse Pro or SidePulse Dot device found."))

        let many = makeHarness()
        useTempMounts(many)
        try makeDevice(many, name: "PulseDot")
        try makeDevice(many, name: "SidePulsePro")
        XCTAssertEqual(many.run(["write", "off"]), 2)
        XCTAssertTrue(many.stderr.text.contains("Multiple possible devices found. Pass --device with one of:"))

        // A missing volume must fail as a write error, never create folders.
        let missing = makeHarness()
        let ghost = missing.root.appendingPathComponent("NotMounted")
        XCTAssertEqual(missing.run(["write", "off", "--device", ghost.path]), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ghost.path))
    }

    func testWriteManualSwitchesTheDeviceToManual() throws {
        let h = makeHarness()
        useTempMounts(h)
        let volume = try makeDevice(h)
        XCTAssertEqual(h.run(["write", "off", "--manual"]), 0, h.stderr.text)
        let settings = SettingsStore(url: h.paths.settingsFile).load()
        XCTAssertEqual(settings.display(forDevice: volume.path), .manual)
        XCTAssertTrue(h.stdout.text.contains("to Manual"))

        // A volume that is not mounted is not remembered as a Manual device.
        let ghost = makeHarness()
        let missing = ghost.root.appendingPathComponent("NotMounted")
        XCTAssertEqual(ghost.run(["write", "off", "--device", missing.path, "--manual"]), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ghost.paths.settingsFile.path))
        XCTAssertFalse(ghost.stdout.text.contains("Manual"), ghost.stdout.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    /// Regression: `standardizedFileURL` stripped `/private` from existing paths, so `--manual`
    /// keyed the setting differently from the runtime's discovery.
    func testManualUsesTheDiscoveredDeviceID() throws {
        let h = makeHarness()
        let root = URL(fileURLWithPath: "/private" + h.root.path, isDirectory: true).appendingPathComponent("mounts")
        try XCTSkipUnless(root.path.hasPrefix("/private/var/"), "needs a temp dir under /var")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("PulseDot"), withIntermediateDirectories: true)
        h.env.variables["SIDEPULSE_MOUNT_ROOTS"] = root.path
        let device = try XCTUnwrap(DeviceDiscovery.discover(roots: [root]).first)

        XCTAssertEqual(h.run(["write", "off", "--manual"]), 0, h.stderr.text)
        let settings = SettingsStore(url: h.paths.settingsFile).load()
        XCTAssertEqual(settings.devices.map(\.id), [device.id])
        XCTAssertEqual(settings.display(forDevice: device.id), .manual)
        XCTAssertTrue(h.stdout.text.contains("(\(device.id)) to Manual"), h.stdout.text)
    }

    /// Regression: `FileHandle.readDataToEndOfFile` aborted the hook when a non-blocking stdin's
    /// payload arrived late.
    func testHookLogBinaryWithNonBlockingStdin() throws {
        let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("sidepulse")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary.path),
                          "build the sidepulse executable first (swift build)")
        let h = makeHarness()
        let process = Process()
        process.executableURL = binary
        process.arguments = ["agent-monitor", "hook-log", "--provider", "claude"]
        process.environment = ["HOME": h.home.path, "SIDEPULSE_HOME": h.stateDir.path,
                               "SIDEPULSE_DISABLE_EVENT_SOCKET": "1", "PATH": "/usr/bin:/bin"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        let readFD = input.fileHandleForReading.fileDescriptor
        XCTAssertEqual(fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK), 0)
        try process.run()
        usleep(200_000)
        input.fileHandleForWriting.write(Data(#"{"hook_event_name":"Stop","session_id":"nb-1","cwd":"/tmp/x"}"#.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(output.fileHandleForReading.readDataToEndOfFile(), Data())
        let log = read(h.paths.logFile(for: "claude")) ?? ""
        XCTAssertEqual(log.split(separator: "\n").count, 1, log)
        XCTAssertTrue(log.contains("\"session_id\":\"nb-1\""), log)
    }

    // MARK: hook-log + status

    func testHookLogThenOfflineStatus() throws {
        let h = makeHarness(["SIDEPULSE_DISABLE_EVENT_SOCKET": "1"])
        h.env.stdin = .data(Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"s-1","cwd":"/tmp/proj","prompt":"Fix the login bug"}"#.utf8))
        XCTAssertEqual(h.run(["hook-log", "--provider", "claude"]), 0)
        XCTAssertEqual(h.stdout.text, "")
        let log = read(h.paths.logFile(for: "claude")) ?? ""
        XCTAssertEqual(log.split(separator: "\n").count, 1)
        XCTAssertTrue(log.contains("UserPromptSubmit"))

        XCTAssertEqual(h.run(["status", "--offline"]), 0)
        XCTAssertTrue(h.stdout.text.hasPrefix("Source: hook logs (offline)\nAggregate: Working (1 active, 0 stale)"),
                      h.stdout.text)

        // Bad arguments never fail the hook.
        let bad = makeHarness()
        XCTAssertEqual(bad.run(["hook-log", "--provider", "nope"]), 0)
        XCTAssertEqual(bad.stdout.text, "")
    }

    func testOpenCodeHookLogThenOfflineStatus() throws {
        let h = makeHarness(["SIDEPULSE_DISABLE_EVENT_SOCKET": "1"])
        h.env.stdin = .data(Data((#"{"hook_event_name":"Stop","session_id":"ses_1","cwd":"/tmp/proj","#
            + #""last_assistant_message":"Should I also add unit tests for this?","agent_origin":"OpenCode","#
            + #""agent_origin_kind":"opencode","agent_origin_source":"plugin","agent_origin_confidence":"explicit"}"#).utf8))
        XCTAssertEqual(h.run(["hook-log", "--provider", "opencode"]), 0)
        XCTAssertEqual(h.stdout.text, "")
        XCTAssertEqual((read(h.paths.logFile(for: "opencode")) ?? "").split(separator: "\n").count, 1)

        XCTAssertEqual(h.run(["status", "--offline", "--json"]), 0)
        let value = try JSONValue.parse(h.stdout.text)
        XCTAssertEqual(value["aggregate"]?["mode"]?.stringValue, "waiting_for_input")
        let row = value["statuses"]?.arrayValue?.first
        XCTAssertEqual(row?["provider"]?.stringValue, "opencode")
        XCTAssertEqual(row?["origin"]?.stringValue, "OpenCode")
        XCTAssertEqual(value["sources"]?.arrayValue?.compactMap { $0["provider"]?.stringValue }, ["claude", "codex", "opencode"])
    }

    func testOfflineStatusOverTempLogs() throws {
        let h = makeHarness()
        try writeLog(h, provider: "claude", records: [
            record("UserPromptSubmit", session: "s1", secondsAgo: 30, extra: [("prompt", .string("Refactor the parser"))]),
            record("PermissionRequest", session: "s2", secondsAgo: 10,
                   extra: [("tool_name", .string("Bash")), ("tool_input", .object(["command": .string("rm -rf build")]))]),
        ])
        XCTAssertEqual(h.run(["status"]), 0)
        XCTAssertTrue(h.stdout.text.hasPrefix("Source: hook logs (app not running)\nAggregate: Waiting for Input (2 active, 0 stale)"),
                      h.stdout.text)
        XCTAssertTrue(h.stdout.text.contains("  claude: \(h.paths.logFile(for: "claude").path) [ok]"))
        XCTAssertTrue(h.stdout.text.contains("  codex: \(h.paths.logFile(for: "codex").path) [missing]"))

        let json = makeHarness()
        json.env.paths = h.paths
        json.env.app = .socket(path: h.paths.socketPath)
        XCTAssertEqual(json.run(["status", "--offline", "--json"]), 0)
        let value = try JSONValue.parse(json.stdout.text)
        XCTAssertEqual(value["aggregate"]?["mode"]?.stringValue, "waiting_for_input")
        XCTAssertEqual(value["statuses"]?.arrayValue?.count, 2)
        XCTAssertEqual(value["aggregate"]?.objectValue?.keys,
                       ["mode", "mode_label", "active_count", "stale_count", "representative"])
    }

    // MARK: live app over the socket

    /// A scripted "app" on the real event socket, so no runtime is needed.
    func testCommandsTalkToAnAppOnTheSocket() throws {
        let h = makeHarness()
        useTempMounts(h)
        let volume = try makeDevice(h)
        // Empty optional strings would be normalized to null by the JSON round trip.
        var subagent = CLIFixtures.d
        subagent.toolName = nil
        subagent.origin = nil
        var snapshot = CLIFixtures.snapshot
        snapshot.statuses = [CLIFixtures.b, CLIFixtures.a, subagent]
        let commands = CommandRecorder()
        let served = snapshot
        let server = EventSocketServer(path: h.paths.socketPath) { message in
            guard case .command(let name, _) = message else { return nil }
            commands.append(name)
            switch name {
            case "ping": return Data(#"{"ok":true,"pid":4242,"version":"9.9.9"}"#.utf8)
            case "status": return Data(served.toJSON().serialized().utf8)
            case "open-settings", "reload-settings": return Data("ok".utf8)
            default: return Data(#"{"ok":false,"error":"unknown command"}"#.utf8)
            }
        }
        try server.start()
        defer { server.stop() }

        XCTAssertEqual(h.run(["status"]), 0)
        XCTAssertEqual(h.stdout.text, "Source: SidePulse app (live)\n"
            + StatusText.render(snapshot, includeStale: false) + "\n")

        let json = makeHarness()
        json.env.paths = h.paths
        json.env.app = .socket(path: h.paths.socketPath)
        XCTAssertEqual(json.run(["status", "--json"]), 0)
        XCTAssertEqual(try JSONValue.parse(json.stdout.text), snapshot.toJSON())

        let write = makeHarness()
        write.env.paths = h.paths
        write.env.variables = h.env.variables
        write.env.app = .socket(path: h.paths.socketPath)
        XCTAssertEqual(write.run(["write", "off"]), 0)
        XCTAssertTrue(write.stderr.text.contains("will restore it at its next update"), write.stderr.text)
        XCTAssertEqual(read(volume.appendingPathComponent("LEDS.LED")), "off")

        XCTAssertEqual(write.run(["write", "idle", "--manual"]), 0)
        XCTAssertTrue(commands.names.contains("reload-settings"))
        XCTAssertEqual(SettingsStore(url: h.paths.settingsFile).load().display(forDevice: volume.path),
                       .manual)

        XCTAssertEqual(h.run(["leds"]), 1)
        XCTAssertTrue(h.stderr.text.contains("already drives the LEDs"))

        let settings = makeHarness()
        settings.env.paths = h.paths
        settings.env.app = .socket(path: h.paths.socketPath)
        XCTAssertEqual(settings.run(["settings"]), 0)
        XCTAssertEqual(settings.stdout.text, "Opened SidePulse settings.\n")
        XCTAssertTrue(settings.launchAgent.installs.isEmpty && settings.launchAgent.starts.isEmpty)

        let app = makeHarness()
        app.env.paths = h.paths
        app.env.app = .socket(path: h.paths.socketPath)
        XCTAssertEqual(app.run(["doctor"]), 0)
        XCTAssertTrue(app.stdout.text.contains("  running: yes (pid 4242, version 9.9.9)\n"), app.stdout.text)
    }

    func testStatusAndWriteTalkToARunningRuntime() throws {
        let h = makeHarness()
        let volume = try makeDevice(h)
        useTempMounts(h)
        var options = RuntimeOptions()
        options.keepAwake = false
        options.mountRoots = [h.root.appendingPathComponent("no-devices")]
        let runtime = SidePulseRuntime(paths: h.paths, options: options)
        try runtime.start()
        defer { runtime.stop() }
        runtime.ingest(provider: "claude", line: record("UserPromptSubmit", session: "live", secondsAgo: 1))

        XCTAssertEqual(h.run(["status"]), 0)
        XCTAssertTrue(h.stdout.text.hasPrefix("Source: SidePulse app (live)\nAggregate: Working"), h.stdout.text)

        XCTAssertEqual(h.run(["write", "off"]), 0)
        XCTAssertTrue(h.stderr.text.contains("will restore it at its next update"))
        XCTAssertEqual(read(volume.appendingPathComponent("LEDS.LED")), "off")

        // Only one process may own the LEDs.
        XCTAssertEqual(h.run(["leds"]), 1)
        XCTAssertTrue(h.stderr.text.contains("already drives the LEDs"))

        let ping = PingReply(data: h.env.app.request("ping", JSONObject(), 1))
        XCTAssertEqual(ping?.version, SidePulseConstants.version)
    }

    // MARK: leds --once

    func testLedsOnceDryRunAndWrite() throws {
        let h = makeHarness()
        useTempMounts(h)
        let volume = try makeDevice(h)
        let target = volume.appendingPathComponent("LEDS.LED")
        try writeLog(h, provider: "claude", records: [record("UserPromptSubmit", session: "s1", secondsAgo: 5)])

        XCTAssertEqual(h.run(["leds", "--once", "--dry-run"]), 0, h.stdout.text)
        XCTAssertTrue(h.stdout.text.hasPrefix("LEDs: would write Working to \(target.path) (aggregate=Working, active=1)\n"),
                      h.stdout.text)
        XCTAssertNil(read(target))

        let write = makeHarness()
        write.env.paths = h.paths
        write.env.variables = h.env.variables
        write.env.app = .socket(path: h.paths.socketPath)
        XCTAssertEqual(write.run(["leds", "--once"]), 0, write.stdout.text)
        XCTAssertTrue(write.stdout.text.hasPrefix("LEDs: wrote Working to \(target.path)"))
        let expected = try LedProgram.program(animationID: SidePulseSettings().animationID(for: .working), ledCount: 2,
                                              brightness: 255)
        XCTAssertEqual(read(target), expected)

        let noDevice = makeHarness(["SIDEPULSE_MOUNT_ROOTS": ""])
        XCTAssertEqual(noDevice.run(["leds", "--once"]), 2)
        XCTAssertTrue(noDevice.stdout.text.hasPrefix("LEDs: Idle error=No SidePulse Pro or SidePulse Dot device found."))
    }

    func testLedsOnceWithExplicitDevice() throws {
        let h = makeHarness()
        let volume = try makeDevice(h)
        let target = volume.appendingPathComponent("LEDS.LED")
        try writeLog(h, provider: "claude", records: [record("UserPromptSubmit", session: "s1", secondsAgo: 5)])

        XCTAssertEqual(h.run(["leds", "--once", "--dry-run", "--device", volume.path]), 0, h.stdout.text)
        XCTAssertTrue(h.stdout.text.hasPrefix("LEDs: would write Working to \(target.path) (aggregate=Working, active=1)\n"),
                      h.stdout.text)
        XCTAssertNil(read(target))

        try SettingsStore(url: h.paths.settingsFile).update {
            $0.setBrightness(128, forDevice: volume.path)
        }
        let write = makeHarness()
        write.env.paths = h.paths
        XCTAssertEqual(write.run(["leds", "--once", "--device", volume.path]), 0, write.stdout.text)
        XCTAssertEqual(write.stdout.text, "LEDs: wrote Working to \(target.path) (aggregate=Working, active=1)\n")
        let expected = try LedProgram.program(animationID: SidePulseSettings().animationID(for: .working), ledCount: 2,
                                              brightness: 128)
        XCTAssertEqual(read(target), expected)

        let missing = makeHarness()
        missing.env.paths = h.paths
        XCTAssertEqual(missing.run(["leds", "--once", "--device", h.root.appendingPathComponent("Gone").path]), 2)
        XCTAssertTrue(missing.stdout.text.hasPrefix("LEDs: Working error="), missing.stdout.text)
    }

    // MARK: install / uninstall / doctor / setup

    func testInstallDoctorUninstallInTempHome() throws {
        let h = makeHarness()
        try FileManager.default.createDirectory(at: h.paths.claudeDir, withIntermediateDirectories: true)

        XCTAssertEqual(h.run(["install"]), 0, h.stderr.text)
        let claude = read(h.paths.claudeSettingsFile) ?? ""
        XCTAssertTrue(claude.contains("hook-log --provider claude"))
        XCTAssertTrue(claude.contains(CLIHarness.cliPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.paths.codexConfigFile.path),
                       "codex is not installed, so its config must not be created")
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.paths.openCodePluginFile.path))
        XCTAssertTrue(h.stdout.text.hasPrefix("claude: updated\n"))

        let again = makeHarness()
        again.env.paths = h.paths
        XCTAssertEqual(again.run(["install", "claude"]), 0)
        XCTAssertTrue(again.stdout.text.hasPrefix("claude: already configured\n"))

        let codex = makeHarness()
        codex.env.paths = h.paths
        XCTAssertEqual(codex.run(["install", "codex", "--no-trust"]), 0, codex.stderr.text)
        XCTAssertTrue((read(h.paths.codexConfigFile) ?? "").contains("# >>> sidepulse hooks >>>"))

        let opencode = makeHarness()
        opencode.env.paths = h.paths
        XCTAssertEqual(opencode.run(["install", "opencode"]), 0, opencode.stderr.text)
        XCTAssertEqual(read(h.paths.openCodePluginFile), OpenCodePluginInstaller.source(cliPath: CLIHarness.cliPath))
        XCTAssertEqual(opencode.stdout.text, """
            opencode: updated
              config: \(h.paths.openCodePluginFile.path)
              log: \(h.paths.logFile(for: "opencode").path)

            """)

        let doctor = makeHarness()
        doctor.env.paths = h.paths
        doctor.env.app = .socket(path: h.paths.socketPath)
        XCTAssertEqual(doctor.run(["doctor", "--json"]), 0)
        let report = try JSONValue.parse(doctor.stdout.text)
        let providers = report["providers"]?.arrayValue ?? []
        XCTAssertEqual(providers.compactMap { $0["provider"]?.stringValue }, ["claude", "codex", "opencode"])
        XCTAssertEqual(providers.first?["missing_events"]?.arrayValue?.count, 0)
        XCTAssertEqual(providers.last?["missing_events"]?.arrayValue?.count, 0)
        XCTAssertEqual(providers.last?["hook_cli_paths"], .array([.string(CLIHarness.cliPath)]))
        XCTAssertEqual(report["app"]?["running"]?.boolValue, false)
        XCTAssertEqual(report["app"]?["cli_path"]?.stringValue, CLIHarness.cliPath)

        let text = makeHarness()
        text.env.paths = h.paths
        XCTAssertEqual(text.run(["doctor"]), 0)
        XCTAssertTrue(text.stdout.text.hasPrefix("claude:\n"), text.stdout.text)
        XCTAssertTrue(text.stdout.text.contains("\napp:\n  binary: not found"))

        let remove = makeHarness()
        remove.env.paths = h.paths
        XCTAssertEqual(remove.run(["uninstall"]), 0, remove.stderr.text)
        XCTAssertFalse((read(h.paths.claudeSettingsFile) ?? "").contains("hook-log"))
        XCTAssertFalse((read(h.paths.codexConfigFile) ?? "").contains("sidepulse hooks"))
        XCTAssertTrue(remove.stdout.text.contains("claude: removed\n"))
        XCTAssertTrue(remove.stdout.text.contains("codex: removed\n"))
        XCTAssertTrue(remove.stdout.text.contains("opencode: removed\n"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.paths.openCodePluginFile.path))
    }

    func testMalformedClaudeConfigIsReportedAndLeftAlone() throws {
        let h = makeHarness()
        try FileManager.default.createDirectory(at: h.paths.claudeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: h.paths.codexDir, withIntermediateDirectories: true)
        try "{not json".write(to: h.paths.claudeSettingsFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(h.run(["install", "--no-trust"]), 1)
        XCTAssertEqual(read(h.paths.claudeSettingsFile), "{not json")
        XCTAssertTrue(h.stderr.text.hasPrefix("claude: install failed\n"))
        XCTAssertTrue(h.stdout.text.contains("codex: updated\n"), "other providers are still installed")
    }

    func testSetupHooksOnly() throws {
        let h = makeHarness()
        try FileManager.default.createDirectory(at: h.paths.claudeDir, withIntermediateDirectories: true)
        XCTAssertEqual(h.run(["setup", "--no-app", "--no-migrate"]), 0, h.stderr.text)
        XCTAssertTrue((read(h.paths.claudeSettingsFile) ?? "").contains("hook-log --provider claude"))
        XCTAssertTrue(h.stdout.text.contains("sidepulse doctor"))
        XCTAssertTrue(h.launchAgent.installs.isEmpty)
    }
}
