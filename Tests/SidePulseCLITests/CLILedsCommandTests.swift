import XCTest
@testable import SidePulseCLI
import SidePulseCore

/// The runtime itself is covered by CLIIntegrationTests.
final class CLILedsCommandTests: XCTestCase {
    func testForegroundRefusesWhileTheAppDrivesTheLEDs() {
        for arguments in [["leds"], ["run"], ["leds", "--dry-run", "--interval", "5"]] {
            let harness = CLIHarness()
            harness.app.running = true
            XCTAssertEqual(harness.run(arguments), 1, "\(arguments)")
            XCTAssertTrue(harness.stderr.text.hasPrefix("sidepulse "), "\(arguments)")
            XCTAssertTrue(harness.stderr.text.contains("already drives the LEDs"), "\(arguments)")
            XCTAssertTrue(harness.stderr.text.contains("sidepulse leds --once"), "\(arguments)")
            XCTAssertEqual(harness.stdout.text, "")
        }
    }

    func testForegroundRefusalNamesAHeadlessOwner() {
        for arguments in [["leds"], ["run"]] {
            let harness = CLIHarness()
            harness.app.running = true
            harness.app.replies["ping"] = Data(#"{"ok":true,"pid":9,"version":"0.1.0","kind":"headless"}"#.utf8)
            XCTAssertEqual(harness.run(arguments), 1, "\(arguments)")
            XCTAssertTrue(harness.stderr.text.contains("a headless 'sidepulse run' (pid 9) already drives the LEDs; "
                + "stop it with Ctrl-C in its terminal or 'kill 9', or use 'sidepulse leds --once'."), harness.stderr.text)
            XCTAssertFalse(harness.stderr.text.contains("app stop"), "\(arguments)")
        }
    }

    func testForegroundIntervalMustBePositive() {
        for value in ["0", "-1", "soon"] {
            let harness = CLIHarness()
            XCTAssertEqual(harness.run(["run", "--interval", value]), 2, value)
            XCTAssertTrue(harness.stderr.text.hasPrefix("usage: sidepulse run [--dry-run] [--interval SECONDS]\n"), value)
        }
    }

    func testDeviceIsOnlyAcceptedWithOnce() {
        let harness = CLIHarness()
        XCTAssertEqual(harness.run(["run", "--device", "/Volumes/PulseDot"]), 2)
        XCTAssertTrue(harness.stderr.text.contains("unrecognized arguments: --device"))
    }
}
