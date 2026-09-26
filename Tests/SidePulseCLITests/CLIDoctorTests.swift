import XCTest
@testable import SidePulseCLI
import SidePulseCore

final class CLIDoctorTextTests: XCTestCase {
    func testAppBlock() {
        let info = DoctorAppInfo(appBinary: "/Applications/SidePulse.app/Contents/MacOS/SidePulse",
                                 plistPath: "/Users/x/Library/LaunchAgents/io.sidepulse.swift.plist", plistInstalled: true,
                                 ping: PingReply(pid: 9, version: "0.1.0"), socketPath: "/s/events.sock",
                                 cliPath: "/Users/x/.local/bin/sidepulse")
        XCTAssertEqual(info.text, """
            app:
              binary: /Applications/SidePulse.app/Contents/MacOS/SidePulse
              launch agent: /Users/x/Library/LaunchAgents/io.sidepulse.swift.plist (installed)
              running: yes (pid 9, version 0.1.0)
              socket: /s/events.sock
            cli: /Users/x/.local/bin/sidepulse (written by install)
            """)
        XCTAssertEqual(JSONValue.object(info.json).serialized(),
                       #"{"binary":"/Applications/SidePulse.app/Contents/MacOS/SidePulse","#
                           + #""launch_agent_plist":"/Users/x/Library/LaunchAgents/io.sidepulse.swift.plist","#
                           + #""launch_agent_installed":true,"running":true,"pid":9,"version":"0.1.0","#
                           + #""socket_path":"/s/events.sock","cli_path":"/Users/x/.local/bin/sidepulse","cli_note":null}"#)
    }

    func testCLILineWhenNothingQualifies() {
        let info = DoctorAppInfo(appBinary: nil, plistPath: "/p", plistInstalled: false, ping: PingReply(pid: nil, version: nil),
                                 socketPath: "/s", cliPath: nil, cliNote: "/h/.local/bin/sidepulse is not the SidePulse CLI")
        XCTAssertTrue(info.text.contains("  running: yes\n"))
        XCTAssertTrue(info.text.hasSuffix("\ncli: not found (\(HookCLIPath.notFoundMessage))\n"
            + "  note: /h/.local/bin/sidepulse is not the SidePulse CLI"))
        XCTAssertEqual(info.json["cli_path"], .null)
    }

    /// Regression: doctor printed the path install would write as "used by hook
    /// commands" and never looked at what the installed hooks call.
    func testDoctorChecksTheCLIInTheInstalledHooks() throws {
        let harness = CLIHarness()
        try FileManager.default.createDirectory(at: harness.paths.claudeDir, withIntermediateDirectories: true)
        let gone = harness.root.appendingPathComponent("moved/SidePulse.app/Contents/Helpers/sidepulse").path
        _ = try ClaudeHookInstaller.install(paths: harness.paths, cliPath: gone, dryRun: false)
        XCTAssertEqual(harness.run(["doctor"]), 0)
        XCTAssertTrue(harness.stdout.text.contains("  hooks: installed (12/12 events)\n"
            + "  hook cli: \(gone) (missing); run 'sidepulse install claude' to repair\n"), harness.stdout.text)
        XCTAssertTrue(harness.stdout.text.contains("\ncli: \(CLIHarness.cliPath) (written by install)\n"))
    }

    func testAppBlockWhenNothingIsInstalled() {
        let info = DoctorAppInfo(appBinary: nil, plistPath: "/p", plistInstalled: false, ping: nil, socketPath: "/s",
                                 cliPath: "/c")
        XCTAssertTrue(info.text.contains("  binary: not found (run scripts/install.sh)\n"))
        XCTAssertTrue(info.text.contains("  launch agent: /p (missing)\n"))
        XCTAssertTrue(info.text.contains("  running: no\n"))
        XCTAssertEqual(info.json["binary"], .null)
        XCTAssertEqual(info.json["pid"], .null)
        XCTAssertEqual(info.json["running"], .bool(false))
    }
}
