import XCTest
@testable import SidePulseCLI
import SidePulseCore

final class CLISettingsCommandTests: XCTestCase {
    func testReusesRunningApp() {
        let harness = CLIHarness()
        harness.app.replies["open-settings"] = Data("ok".utf8)
        XCTAssertEqual(harness.run(["settings"]), 0)
        XCTAssertEqual(harness.app.requests, ["open-settings"])
        XCTAssertTrue(harness.launchAgent.starts.isEmpty && harness.launchAgent.installs.isEmpty)
        XCTAssertEqual(harness.stdout.text, "Opened SidePulse settings.\n")
    }

    func testStartsAppAndRetries() {
        let harness = CLIHarness()
        harness.installFakeApp()
        var attempts = 0
        harness.app.onRequest = { [unowned harness] command in
            guard command == "open-settings" else { return }
            attempts += 1
            if attempts == 4 { harness.app.replies["open-settings"] = Data("ok".utf8) }
        }
        XCTAssertEqual(harness.run(["settings"]), 0)
        XCTAssertEqual(attempts, 4)
        XCTAssertEqual(harness.launchAgent.opened.count, 1)
        XCTAssertEqual(harness.stdout.text, "Opened SidePulse settings.\n")
    }

    /// Regression: with Launch at Login turned off (no plist), `settings` wrote the
    /// LaunchAgent again, turning the login item back on without saying so.
    func testNeverTurnsLaunchAtLoginBackOn() throws {
        let harness = CLIHarness()
        let binary = harness.installFakeApp()
        harness.app.onRequest = { [unowned harness] command in
            if command == "open-settings" && !harness.launchAgent.opened.isEmpty {
                harness.app.replies["open-settings"] = Data("ok".utf8)
            }
        }
        XCTAssertEqual(harness.run(["settings"]), 0)
        XCTAssertEqual(harness.launchAgent.opened, [binary])
        XCTAssertTrue(harness.launchAgent.installs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.paths.launchAgentPlist().path))

        // With the login item on, launchd starts it (and the plist is not rewritten).
        let plist = harness.paths.launchAgentPlist()
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try CLIFakeLaunchAgent.plist(["/old/SidePulse"]).write(to: plist, atomically: true, encoding: .utf8)
        harness.app.replies["open-settings"] = nil
        harness.app.onRequest = { [unowned harness] command in
            if command == "open-settings" && !harness.launchAgent.starts.isEmpty {
                harness.app.replies["open-settings"] = Data("ok".utf8)
            }
        }
        XCTAssertEqual(harness.run(["settings"]), 0)
        XCTAssertEqual(harness.launchAgent.starts, [false])
        XCTAssertTrue(harness.launchAgent.installs.isEmpty)
    }

    func testGivesUpAfterTimeout() {
        let harness = CLIHarness()
        harness.installFakeApp()
        let start = harness.clock
        XCTAssertEqual(harness.run(["settings"]), 1)
        XCTAssertEqual(harness.clock.timeIntervalSince(start), SettingsCommand.startupTimeout, accuracy: 0.11)
        XCTAssertGreaterThan(harness.app.requests.count, 40)
        XCTAssertTrue(harness.stderr.text.contains("Could not open SidePulse settings. Check \(harness.paths.appLogFile.path)."))
    }

    func testHeadlessRuntimeIsReportedInsteadOfStartingTheApp() {
        let harness = CLIHarness()
        harness.installFakeApp()
        harness.app.running = true
        XCTAssertEqual(harness.run(["settings"]), 1)
        XCTAssertTrue(harness.stderr.text.contains("has no settings window"))
        XCTAssertTrue(harness.launchAgent.installs.isEmpty && harness.launchAgent.starts.isEmpty)
    }

    func testFailsWhenAppCannotBeStarted() {
        let harness = CLIHarness()
        XCTAssertEqual(harness.run(["settings"]), 1)
        XCTAssertTrue(harness.stderr.text.hasPrefix("sidepulse settings: could not start the SidePulse app: SidePulse.app was not found"))
    }
}
