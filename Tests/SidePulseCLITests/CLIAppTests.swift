import XCTest
@testable import SidePulseCLI
import SidePulseCore

final class CLIAppLocatorTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/x", isDirectory: true)
    private let system = URL(fileURLWithPath: "/Applications", isDirectory: true)

    private func locator(cli: String, existing: Set<String>, environment: [String: String] = [:]) -> AppLocator {
        AppLocator(executablePath: cli, home: home, environment: environment, systemApplicationsDir: system,
                   isExecutable: { existing.contains($0) })
    }

    func testBundledCLIUsesItsOwnApp() {
        let bundled = "/Volumes/Dev/SidePulse.app/Contents/MacOS/SidePulse"
        let installed = "/Applications/SidePulse.app/Contents/MacOS/SidePulse"
        let l = locator(cli: "/Volumes/Dev/SidePulse.app/Contents/Helpers/sidepulse", existing: [bundled, installed])
        XCTAssertEqual(l.locate(), bundled)
    }

    func testFallsBackToUserThenSystemApplications() {
        let user = "/Users/x/Applications/SidePulse.app/Contents/MacOS/SidePulse"
        let system = "/Applications/SidePulse.app/Contents/MacOS/SidePulse"
        XCTAssertEqual(locator(cli: "/usr/local/bin/sidepulse", existing: [user, system]).locate(), user)
        XCTAssertEqual(locator(cli: "/usr/local/bin/sidepulse", existing: [system]).locate(), system)
        XCTAssertNil(locator(cli: "/usr/local/bin/sidepulse", existing: []).locate())
        // A bundled CLI whose bundle lacks the app binary still finds an installed app.
        XCTAssertEqual(locator(cli: "/tmp/SidePulse.app/Contents/Helpers/sidepulse", existing: [system]).locate(), system)
    }

    func testExplicitOverride() {
        let custom = "/opt/SidePulse.app/Contents/MacOS/SidePulse"
        let system = "/Applications/SidePulse.app/Contents/MacOS/SidePulse"
        XCTAssertEqual(locator(cli: "/x", existing: [custom, system], environment: ["SIDEPULSE_APP_PATH": "/opt/SidePulse.app"])
            .locate(), custom)
        XCTAssertEqual(locator(cli: "/x", existing: ["/opt/bin/app", system], environment: ["SIDEPULSE_APP_PATH": "/opt/bin/app"])
            .locate(), "/opt/bin/app")
        // A missing override falls through to the normal lookup.
        XCTAssertEqual(locator(cli: "/x", existing: [system], environment: ["SIDEPULSE_APP_PATH": "/missing"]).locate(), system)
    }

    func testCandidatesOrder() {
        let l = locator(cli: "/B/SidePulse.app/Contents/Helpers/sidepulse", existing: [])
        XCTAssertEqual(l.candidates, [
            "/B/SidePulse.app/Contents/MacOS/SidePulse",
            "/Users/x/Applications/SidePulse.app/Contents/MacOS/SidePulse",
            "/Applications/SidePulse.app/Contents/MacOS/SidePulse",
        ])
    }

    /// Regression: the Python install's /Applications/SidePulse.app (same layout,
    /// bundle id io.sidepulse.cli) was taken for the app.
    func testBundleOfAnotherAppIsSkipped() throws {
        let harness = CLIHarness()
        let binary = harness.installFakeApp()
        let info = harness.applicationsDir.appendingPathComponent("SidePulse.app/Contents/Info.plist")
        func writeIdentifier(_ id: String) throws {
            let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
            try plist.write(to: info)
        }
        try writeIdentifier("io.sidepulse.cli")
        XCTAssertNil(harness.env.appLocator.locate())
        try writeIdentifier(SidePulseConstants.bundleIdentifier)
        XCTAssertEqual(harness.env.appLocator.locate(), binary)
    }

    func testRealFilesystemLookupInHarness() {
        let harness = CLIHarness()
        XCTAssertNil(harness.env.appLocator.locate())
        let path = harness.installFakeApp()
        XCTAssertEqual(harness.env.appLocator.locate(), path)
        let userApp = harness.makeExecutable(AppLocator.appBinary(
            inBundle: harness.home.appendingPathComponent("Applications/SidePulse.app")))
        XCTAssertEqual(harness.env.appLocator.locate(), userApp)
    }
}

final class CLIAppCommandTests: XCTestCase {
    func testPingReply() {
        XCTAssertEqual(PingReply(data: Data(#"{"ok":true,"pid":42,"version":"0.1.0"}"#.utf8)),
                       PingReply(pid: 42, version: "0.1.0"))
        XCTAssertEqual(PingReply(data: Data(#"{"ok":true}"#.utf8)), PingReply(pid: nil, version: nil))
        XCTAssertNil(PingReply(data: Data(#"{"ok":false}"#.utf8)))
        XCTAssertNil(PingReply(data: Data("ok".utf8)))
        XCTAssertNil(PingReply(data: nil))
    }

    func testOKReply() {
        XCTAssertTrue(AppConnection.isOK(Data("ok".utf8)))
        XCTAssertTrue(AppConnection.isOK(Data("ok\n".utf8)))
        XCTAssertFalse(AppConnection.isOK(Data(#"{"ok":false,"error":"unknown command"}"#.utf8)))
        XCTAssertFalse(AppConnection.isOK(nil))
    }

    func testStatusText() {
        let plist = URL(fileURLWithPath: "/Users/x/Library/LaunchAgents/io.sidepulse.swift.plist")
        XCTAssertEqual(
            AppStatusText.render(state: LaunchAgentStatus(installed: true, loaded: true, pid: 42), plistPath: plist,
                                 socketPath: "/s/events.sock", ping: PingReply(pid: 42, version: "0.1.0"),
                                 appBinary: "/Applications/SidePulse.app/Contents/MacOS/SidePulse"),
            """
            app: running
              plist: /Users/x/Library/LaunchAgents/io.sidepulse.swift.plist (installed)
              launchd: loaded (pid 42)
              socket: /s/events.sock (responding, pid 42, version 0.1.0)
              binary: /Applications/SidePulse.app/Contents/MacOS/SidePulse
            """)
        XCTAssertEqual(
            AppStatusText.render(state: LaunchAgentStatus(installed: false, loaded: false), plistPath: plist,
                                 socketPath: "/s/events.sock", ping: nil, appBinary: nil),
            """
            app: not running
              plist: /Users/x/Library/LaunchAgents/io.sidepulse.swift.plist (missing)
              launchd: not loaded
              socket: /s/events.sock (not responding)
              binary: not found
            """)
        XCTAssertTrue(AppStatusText.render(state: LaunchAgentStatus(installed: true, loaded: true), plistPath: plist,
                                           socketPath: "/s", ping: nil, appBinary: nil)
            .contains("  launchd: loaded, not running\n"))
    }

    func testStatusCommandExitCodeFollowsPing() {
        let harness = CLIHarness()
        harness.launchAgent.state = LaunchAgentStatus(installed: true, loaded: true, pid: 7)
        XCTAssertEqual(harness.run(["app", "status"]), 1)
        XCTAssertTrue(harness.stdout.text.hasPrefix("app: not running\n"))

        let running = CLIHarness()
        running.app.replies["ping"] = Data(#"{"ok":true,"pid":7,"version":"0.1.0"}"#.utf8)
        XCTAssertEqual(running.run(["status-bar", "status"]), 0)
        XCTAssertTrue(running.stdout.text.hasPrefix("app: running\n"))
    }

    /// Regression: `app start` (and `settings`) wrote the login LaunchAgent when it
    /// was missing, silently turning Launch at Login back on.
    func testStartWithoutPlistOpensTheAppWithoutALoginItem() {
        let harness = CLIHarness()
        let binary = harness.installFakeApp()
        XCTAssertEqual(harness.run(["app"]), 0)
        XCTAssertEqual(harness.launchAgent.opened, [binary])
        XCTAssertTrue(harness.launchAgent.installs.isEmpty && harness.launchAgent.starts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.paths.launchAgentPlist().path))
        XCTAssertTrue(harness.stdout.text.hasPrefix("app: started (Launch at Login is off; 'sidepulse app install' turns it on)\n"))
    }

    func testStartUsesAnExistingLaunchAgent() throws {
        let harness = CLIHarness()
        let binary = harness.installFakeApp()
        let plist = harness.paths.launchAgentPlist()
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try CLIFakeLaunchAgent.plist([binary]).write(to: plist, atomically: true, encoding: .utf8)
        XCTAssertEqual(harness.run(["app", "start"]), 0)
        XCTAssertEqual(harness.launchAgent.starts, [false])
        XCTAssertEqual(harness.stdout.text, "app: started\n  plist: \(plist.path)\n")
        XCTAssertEqual(harness.run(["app", "restart"]), 0)
        XCTAssertEqual(harness.launchAgent.starts, [false, true])
        XCTAssertTrue(harness.launchAgent.installs.isEmpty && harness.launchAgent.opened.isEmpty)
    }

    /// A LaunchAgent that runs another binary is started as it is, never repointed
    /// (a build/SidePulse.app would be deleted by the next build).
    func testStartLeavesAStalePlistAloneWithANote() throws {
        let harness = CLIHarness()
        let binary = harness.installFakeApp()
        let plist = harness.paths.launchAgentPlist()
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try CLIFakeLaunchAgent.plist(["/old/SidePulse"]).write(to: plist, atomically: true, encoding: .utf8)
        XCTAssertEqual(harness.run(["app", "start"]), 0)
        XCTAssertTrue(harness.launchAgent.installs.isEmpty)
        XCTAssertEqual(harness.launchAgent.starts, [false])
        XCTAssertTrue(harness.stdout.text.hasPrefix("app: started\n"))
        XCTAssertTrue(harness.stdout.text.contains(
            "  note: the LaunchAgent runs /old/SidePulse; 'sidepulse app install' points it at \(binary)\n"))
    }

    /// Regression: start/restart bootstrapped a second copy next to a running app;
    /// it found the socket taken, showed a modal alert and exited, while the CLI
    /// reported success.
    func testStartAndRestartLeaveARunningAppAlone() {
        let harness = CLIHarness()
        harness.installFakeApp()
        harness.app.replies["ping"] = Data(#"{"ok":true,"pid":9,"version":"0.1.0"}"#.utf8)
        XCTAssertEqual(harness.run(["app", "start"]), 0)
        XCTAssertTrue(harness.stdout.text.hasPrefix("app: already running outside launchd (pid 9)\n"))
        XCTAssertEqual(harness.run(["app", "restart"]), 1)
        XCTAssertTrue(harness.stderr.text.contains("running outside launchd (pid 9); quit it from the menu bar"))

        harness.launchAgent.state = LaunchAgentStatus(installed: true, loaded: true, pid: 9)
        XCTAssertEqual(harness.run(["app", "start"]), 0)
        XCTAssertTrue(harness.stdout.text.contains("app: already running (pid 9)\n"))
        XCTAssertTrue(harness.launchAgent.starts.isEmpty && harness.launchAgent.opened.isEmpty)
        XCTAssertEqual(harness.run(["app", "restart"]), 0)
        XCTAssertEqual(harness.launchAgent.starts, [true])
        XCTAssertTrue(harness.launchAgent.installs.isEmpty)
    }

    func testStartWithoutAppOrPlistFails() {
        let harness = CLIHarness()
        XCTAssertEqual(harness.run(["app", "start"]), 1)
        XCTAssertTrue(harness.stderr.text.hasPrefix("sidepulse app: SidePulse.app was not found"))
        XCTAssertTrue(harness.stderr.text.contains("scripts/install.sh"))
    }

    func testStartWithExistingPlistButNoApp() throws {
        let harness = CLIHarness()
        let plist = harness.paths.launchAgentPlist()
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: plist, atomically: true, encoding: .utf8)
        XCTAssertEqual(harness.run(["app", "start"]), 0)
        XCTAssertEqual(harness.launchAgent.starts, [false])
    }

    func testStopAndUninstall() throws {
        let harness = CLIHarness()
        XCTAssertEqual(harness.run(["app", "stop"]), 0)
        XCTAssertEqual(harness.stdout.text, "app: not running\n")
        XCTAssertEqual(harness.launchAgent.stops, 0)

        harness.launchAgent.state = LaunchAgentStatus(installed: true, loaded: true, pid: 3)
        XCTAssertEqual(harness.run(["app", "stop"]), 0)
        XCTAssertEqual(harness.launchAgent.stops, 1)
        XCTAssertTrue(harness.stdout.text.contains("app: stopped\n"))

        let removed = CLIHarness()
        XCTAssertEqual(removed.run(["app", "uninstall"]), 0)
        XCTAssertTrue(removed.stdout.text.hasPrefix("app: already removed\n"))
        XCTAssertEqual(removed.launchAgent.uninstalls, 0)
        removed.launchAgent.state = LaunchAgentStatus(installed: true, loaded: true)
        XCTAssertEqual(removed.run(["app", "uninstall"]), 0)
        XCTAssertEqual(removed.launchAgent.uninstalls, 1)
    }

    func testStopRefusesAppRunningOutsideLaunchd() {
        let harness = CLIHarness()
        harness.app.running = true
        XCTAssertEqual(harness.run(["app", "stop"]), 1)
        XCTAssertTrue(harness.stderr.text.contains("outside launchd"))
    }

    func testInstallSubcommand() {
        let harness = CLIHarness()
        XCTAssertEqual(harness.run(["app", "install"]), 1)
        let binary = harness.installFakeApp()
        harness.launchAgent.installChanged = false
        XCTAssertEqual(harness.run(["app", "install"]), 0)
        XCTAssertEqual(harness.launchAgent.installs.map(\.arguments), [[binary]])
        XCTAssertEqual(harness.launchAgent.installs.map(\.start), [true])
        XCTAssertTrue(harness.stdout.text.hasPrefix("app: already installed and started\n"))
        XCTAssertTrue(harness.stdout.text.contains("  binary: \(binary)\n"))
    }

    /// Regression: `app install` / `setup` next to an app running outside launchd
    /// started a copy that exited at once ("already running"), leaving no crash
    /// restart, while the CLI said "installed and started".
    func testInstallNextToARunningAppOnlyWritesThePlist() {
        let harness = CLIHarness()
        let binary = harness.installFakeApp()
        harness.app.replies["ping"] = Data(#"{"ok":true,"pid":9}"#.utf8)
        XCTAssertEqual(harness.run(["app", "install"]), 0)
        XCTAssertEqual(harness.launchAgent.installs.map(\.arguments), [[binary]])
        XCTAssertEqual(harness.launchAgent.installs.map(\.start), [false])
        XCTAssertTrue(harness.stdout.text.hasPrefix("app: installed, not started: SidePulse already runs outside "
            + "launchd (pid 9); the LaunchAgent takes over at the next login\n"))

        // The LaunchAgent's own instance: unchanged is left running, changed is reloaded.
        let managed = CLIHarness()
        managed.installFakeApp()
        managed.app.replies["ping"] = Data(#"{"ok":true,"pid":9}"#.utf8)
        managed.launchAgent.state = LaunchAgentStatus(installed: true, loaded: true, pid: 9)
        managed.launchAgent.installChanged = false
        XCTAssertEqual(managed.run(["app", "install"]), 0)
        XCTAssertEqual(managed.launchAgent.installs.map(\.start), [false])
        XCTAssertTrue(managed.stdout.text.hasPrefix("app: already installed and running (pid 9)\n"))
        managed.launchAgent.installChanged = true
        XCTAssertEqual(managed.run(["app", "install"]), 0)
        XCTAssertEqual(managed.launchAgent.installs.map(\.start), [false, false, true])
        XCTAssertTrue(managed.stdout.text.contains("app: updated and restarted\n"))
    }

    func testForegroundRefusesWhenAppIsRunning() {
        let harness = CLIHarness()
        harness.installFakeApp()
        harness.app.running = true
        XCTAssertEqual(harness.run(["app", "--foreground"]), 1)
        XCTAssertTrue(harness.stderr.text.contains("already running"))
    }

    func testForegroundRunsTheAppBinaryAndReturnsItsStatus() {
        let harness = CLIHarness()
        let binary = AppLocator.appBinary(inBundle: harness.applicationsDir.appendingPathComponent(AppLocator.bundleName))
        try? FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: binary.path, contents: Data("#!/bin/sh\nexit 3\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        XCTAssertEqual(harness.run(["app", "start", "--foreground"]), 3)
    }
}
