import XCTest
@testable import SidePulseCLI
import SidePulseCore

final class CLIWriteInputTests: XCTestCase {
    func testProgramFromArgumentIsTakenVerbatim() {
        XCTAssertEqual(WriteCommand.programText("off\\n#FF00FF pulse", stdin: .terminal), "off\\n#FF00FF pulse")
    }

    func testDashReadsStdinEvenIfEmpty() {
        XCTAssertEqual(WriteCommand.programText("-", stdin: .data(Data("off\n".utf8))), "off\n")
        XCTAssertEqual(WriteCommand.programText("-", stdin: .data(Data())), "")
    }

    func testImplicitStdin() {
        XCTAssertEqual(WriteCommand.programText(nil, stdin: .data(Data("#00FF66 320ms cosine\n".utf8))),
                       "#00FF66 320ms cosine\n")
        XCTAssertNil(WriteCommand.programText(nil, stdin: .data(Data(" \n\t".utf8))))
        XCTAssertNil(WriteCommand.programText(nil, stdin: .terminal))
        // Nothing pending on a non-TTY stdin: don't block.
        var readCalled = false
        let idle = StandardInput(isTTY: false, readAll: { readCalled = true; return Data() }, hasPendingData: { _ in false })
        XCTAssertNil(WriteCommand.programText(nil, stdin: idle))
        XCTAssertFalse(readCalled)
    }

    func testImplicitStdinThatDecodesToWhitespaceCountsAsNone() {
        // Python strips the piped program after decoding escapes.
        XCTAssertNil(WriteCommand.programText(nil, stdin: .data(Data("\\n\\t \\r\n".utf8))))
        XCTAssertEqual(WriteCommand.programText(nil, stdin: .data(Data("\\\\n".utf8))), "\\\\n")
        // `-` is an explicit request: kept as is (validation judges it later).
        XCTAssertEqual(WriteCommand.programText("-", stdin: .data(Data("\\n".utf8))), "\\n")
    }

    func testIsBlankAfterDecoding() {
        for blank in ["", " ", "\n\t", "\\n", "\\r\\n\\t", " \\n "] {
            XCTAssertTrue(WriteCommand.isBlankAfterDecoding(blank), blank)
        }
        // `\\` decodes to a backslash, a trailing `\` and unknown escapes stay literal.
        for program in ["off", "\\\\", "\\", "\\x", "\\n off", "\\\\n"] {
            XCTAssertFalse(WriteCommand.isBlankAfterDecoding(program), program)
        }
    }

    func testManualIsIgnoredForAVolumeThatIsNotMounted() {
        let harness = CLIHarness()
        harness.app.running = true
        WriteCommand.coordinateWithApp(target: URL(fileURLWithPath: "/Volumes/Ghost/LEDS.LED"), manual: true,
                                       dryRun: false, env: harness.env, volumeExists: { _ in false })
        XCTAssertTrue(harness.app.requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.paths.settingsFile.path))
        XCTAssertEqual(harness.stdout.text + harness.stderr.text, "")
    }

    private static let pulseDot = DeviceCandidate(root: URL(fileURLWithPath: "/Volumes/PulseDot"),
                                                  target: URL(fileURLWithPath: "/Volumes/PulseDot/LEDS.LED"),
                                                  reason: "contains LEDS.LED")

    /// Records each request's arguments, which `CLIFakeApp` drops.
    private func recordRequests(_ harness: CLIHarness, reply: Data?) -> RequestLog {
        let log = RequestLog()
        harness.env.app = AppConnection(isRunning: { true }, request: { command, args, _ in
            log.append(command, args)
            return reply
        })
        return log
    }

    private final class RequestLog {
        private(set) var items: [(command: String, args: JSONObject)] = []
        func append(_ command: String, _ args: JSONObject) { items.append((command, args)) }
    }

    func testManualWarnsWhenTheAppIsStillWriting() throws {
        let harness = CLIHarness()
        let requests = recordRequests(harness, reply: Data(#"{"ok":false,"error":"LED write in progress"}"#.utf8))
        WriteCommand.coordinateWithApp(target: URL(fileURLWithPath: "/Volumes/PulseDot/LEDS.LED"), manual: true,
                                       dryRun: false, env: harness.env, volumeExists: { _ in true },
                                       resolveDevice: { _ in Self.pulseDot })
        XCTAssertEqual(requests.items.map(\.command), ["reload-settings"])
        XCTAssertEqual(requests.items.first?.args, ["device": .string("/Volumes/PulseDot")], "only that device's writes count")
        XCTAssertTrue(harness.stdout.text.contains("to Manual"))
        XCTAssertTrue(harness.stderr.text.contains("still writing"), harness.stderr.text)
        XCTAssertEqual(SettingsStore(url: harness.paths.settingsFile).load().display(forDevice: "/Volumes/PulseDot"), .manual)
    }

    func testManualIsQuietWhenTheAppAcknowledges() {
        let harness = CLIHarness()
        harness.app.running = true
        harness.app.replies["reload-settings"] = Data("ok".utf8)
        WriteCommand.coordinateWithApp(target: URL(fileURLWithPath: "/Volumes/PulseDot/LEDS.LED"), manual: true,
                                       dryRun: false, env: harness.env, volumeExists: { _ in true },
                                       resolveDevice: { _ in Self.pulseDot })
        XCTAssertEqual(harness.stderr.text, "")
    }

    /// Regression: `--device /volumes/pulsedot --manual` saved Manual for that spelling, so the real
    /// device stayed in Agent mode and a phantom device appeared in settings.
    func testManualResolvesACaseVariantOrSymlinkedPathToTheDiscoveredDevice() throws {
        let probe = CLIHarness()
        defer { withExtendedLifetime(probe) {} }
        let mounts = probe.root.appendingPathComponent("mounts", isDirectory: true)
        let dot = mounts.appendingPathComponent("PulseDot", isDirectory: true)
        try FileManager.default.createDirectory(at: dot, withIntermediateDirectories: true)
        let link = probe.root.appendingPathComponent("dot-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dot)
        var typed = [link, link.appendingPathComponent("LEDS.LED")]
        let variant = mounts.appendingPathComponent("pulsedot")
        if FileManager.default.fileExists(atPath: variant.path) { typed.append(variant) }

        for path in typed {
            let harness = CLIHarness(variables: ["SIDEPULSE_MOUNT_ROOTS": mounts.path])
            let requests = recordRequests(harness, reply: Data("ok".utf8))
            let target = DeviceDiscovery.target(forDevicePath: path)
            WriteCommand.coordinateWithApp(target: target, manual: true, dryRun: false, env: harness.env)
            let settings = SettingsStore(url: harness.paths.settingsFile).load()
            XCTAssertEqual(settings.devices.map(\.id), [dot.path], path.path)
            XCTAssertEqual(settings.display(forDevice: dot.path), .manual, path.path)
            XCTAssertEqual(requests.items.first?.args, ["device": .string(dot.path)], path.path)
            XCTAssertEqual(harness.stdout.text, "Set SidePulse Dot (\(dot.path)) to Manual: SidePulse will not overwrite it "
                + "(switch back under Devices in the menu bar).\n", path.path)
            XCTAssertEqual(harness.stderr.text, "", path.path)
        }
    }

    func testManualForAPathThatIsNoDiscoveredDeviceWarnsAndSavesNothing() throws {
        let harness = CLIHarness()
        let mounts = harness.root.appendingPathComponent("mounts", isDirectory: true)
        try FileManager.default.createDirectory(at: mounts.appendingPathComponent("PulseDot"), withIntermediateDirectories: true)
        let elsewhere = harness.root.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        harness.env.variables["SIDEPULSE_MOUNT_ROOTS"] = mounts.path
        let requests = recordRequests(harness, reply: Data("ok".utf8))

        WriteCommand.coordinateWithApp(target: elsewhere.appendingPathComponent("LEDS.LED"), manual: true, dryRun: false,
                                       env: harness.env)

        XCTAssertEqual(harness.stderr.text, "sidepulse write: warning: --manual ignored: \(elsewhere.path) is not a "
            + "SidePulse device the app drives, so nothing was switched to Manual.\n")
        XCTAssertEqual(harness.stdout.text, "")
        XCTAssertTrue(requests.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.paths.settingsFile.path))
    }

    func testDeviceIDIsTheVolumeRoot() {
        XCTAssertEqual(WriteCommand.deviceID(forTarget: URL(fileURLWithPath: "/Volumes/PulseDot/LEDS.LED")), "/Volumes/PulseDot")
        XCTAssertEqual(WriteCommand.deviceID(forTarget: URL(fileURLWithPath: "/Volumes/A/../PulseDot/LEDS.LED")),
                       "/Volumes/PulseDot")
        // Regression: standardizedFileURL turned existing /private/... paths into
        // /tmp/... or /var/..., unlike the DeviceCandidate.id the runtime uses.
        XCTAssertEqual(WriteCommand.deviceID(forTarget: URL(fileURLWithPath: "/private/var/tmp/LEDS.LED")),
                       "/private/var/tmp")
        XCTAssertEqual(WriteCommand.deviceID(forTarget: URL(fileURLWithPath: "/private/tmp/LEDS.LED")), "/private/tmp")
    }

    func testTooManyArgumentsIsUsageError() {
        let harness = CLIHarness()
        XCTAssertEqual(harness.run(["write", "off", "extra"]), 2)
        XCTAssertTrue(harness.stderr.text.contains("unrecognized arguments: extra"))
    }
}
