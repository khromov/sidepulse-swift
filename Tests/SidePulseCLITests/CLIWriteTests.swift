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
        // Whitespace-only piped input counts as no program.
        XCTAssertNil(WriteCommand.programText(nil, stdin: .data(Data(" \n\t".utf8))))
        // Never read from a terminal.
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

    func testManualWarnsWhenTheAppIsStillWriting() throws {
        let harness = CLIHarness()
        harness.app.running = true
        harness.app.replies["reload-settings"] = Data(#"{"ok":false,"error":"LED write in progress"}"#.utf8)
        WriteCommand.coordinateWithApp(target: URL(fileURLWithPath: "/Volumes/PulseDot/LEDS.LED"), manual: true,
                                       dryRun: false, env: harness.env, volumeExists: { _ in true })
        XCTAssertEqual(harness.app.requests, ["reload-settings"])
        XCTAssertTrue(harness.stdout.text.contains("to Manual"))
        XCTAssertTrue(harness.stderr.text.contains("still writing"), harness.stderr.text)
        XCTAssertEqual(SettingsStore(url: harness.paths.settingsFile).load().display(forDevice: "/Volumes/PulseDot"), .manual)
    }

    func testManualIsQuietWhenTheAppAcknowledges() {
        let harness = CLIHarness()
        harness.app.running = true
        harness.app.replies["reload-settings"] = Data("ok".utf8)
        WriteCommand.coordinateWithApp(target: URL(fileURLWithPath: "/Volumes/PulseDot/LEDS.LED"), manual: true,
                                       dryRun: false, env: harness.env, volumeExists: { _ in true })
        XCTAssertEqual(harness.stderr.text, "")
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
