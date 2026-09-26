import XCTest
@testable import SidePulseCLI
import SidePulseCore

final class CLISetupCommandTests: XCTestCase {
    private func harnessWithHooks() -> (CLIHarness, () -> [HookProvider]) {
        let harness = CLIHarness()
        var installed: [HookProvider] = []
        harness.env.hooks = HookOperations(
            install: { provider, paths, _, dryRun, _ in
                installed.append(provider)
                return InstallResult(provider: provider, configPath: provider.configFile(paths), changed: true, dryRun: dryRun)
            },
            uninstall: { _, _, _ in throw CommandFailure(message: "unexpected") }
        )
        return (harness, { installed })
    }

    func testFullSetup() throws {
        let (harness, installed) = harnessWithHooks()
        try FileManager.default.createDirectory(at: harness.paths.claudeDir, withIntermediateDirectories: true)
        harness.launchAgent.legacyMessages = ["removed io.sidepulse.service"]
        let binary = harness.installFakeApp()
        XCTAssertEqual(harness.run(["setup"]), 0)
        XCTAssertEqual(harness.launchAgent.migrations, [false])
        XCTAssertEqual(installed(), [.claude])
        XCTAssertEqual(harness.launchAgent.installs.map(\.arguments), [[binary]])
        XCTAssertEqual(harness.stdout.text, """
            legacy: removed io.sidepulse.service
            claude: updated
              config: \(harness.paths.claudeSettingsFile.path)
              log: \(harness.paths.logFile(for: "claude").path)
            app: installed and started
              plist: \(harness.paths.launchAgentPlist().path)
              binary: \(binary)

            SidePulse is set up. New agent sessions report their status; run 'sidepulse doctor' to check the hooks and the app.

            """)
    }

    func testDryRunChangesNothing() {
        let (harness, installed) = harnessWithHooks()
        harness.installFakeApp()
        XCTAssertEqual(harness.run(["setup", "codex", "--dry-run"]), 0)
        XCTAssertEqual(harness.launchAgent.migrations, [true])
        XCTAssertEqual(installed(), [.codex])
        XCTAssertTrue(harness.launchAgent.installs.isEmpty)
        XCTAssertTrue(harness.stdout.text.contains("legacy: no Python SidePulse background agents found\n"))
        XCTAssertTrue(harness.stdout.text.contains("codex: would update\n"))
        XCTAssertTrue(harness.stdout.text.contains("app: would install and start\n"))
        XCTAssertTrue(harness.stdout.text.hasSuffix("\nDry run: nothing was changed.\n"))
    }

    /// Regression: with nothing installed, setup still closed with "SidePulse is
    /// set up" and exit 0.
    func testNoAppNoMigrateAndNoAgents() {
        let (harness, installed) = harnessWithHooks()
        XCTAssertEqual(harness.run(["setup", "--no-app", "--no-migrate"]), 1)
        XCTAssertTrue(harness.launchAgent.migrations.isEmpty)
        XCTAssertTrue(installed().isEmpty)
        XCTAssertTrue(harness.launchAgent.installs.isEmpty)
        XCTAssertTrue(harness.stdout.text.hasPrefix("hooks: skipped. No Claude Code"))
        XCTAssertFalse(harness.stdout.text.contains("app:"))
        XCTAssertTrue(harness.stdout.text.hasSuffix("\nSidePulse is not set up yet: no agent hooks were installed. "
            + "Install Claude Code or Codex, then run 'sidepulse setup' again (or name the agent: 'sidepulse setup claude').\n"))
        XCTAssertFalse(harness.stdout.text.contains("SidePulse is set up"))
    }

    func testNoAgentsButTheAppIsStillNotSetUp() {
        let (harness, _) = harnessWithHooks()
        harness.installFakeApp()
        XCTAssertEqual(harness.run(["setup", "--no-migrate"]), 0)
        XCTAssertTrue(harness.stdout.text.contains("app: installed and started\n"))
        XCTAssertTrue(harness.stdout.text.contains("SidePulse is not set up yet: no agent hooks were installed."))
    }

    func testMissingAppIsSkippedWithGuidance() {
        let (harness, _) = harnessWithHooks()
        XCTAssertEqual(harness.run(["setup", "claude", "--no-migrate"]), 0)
        XCTAssertTrue(harness.stdout.text.contains("app: not found; skipped\n  SidePulse.app was not found"))
        XCTAssertTrue(harness.stdout.text.hasSuffix("\nHooks are installed, but the SidePulse app was not found, so nothing "
            + "shows their status yet. Install it with scripts/install.sh.\n"))
    }

    /// Regression: setup started a second copy next to an app running outside launchd.
    func testSetupNextToARunningAppDoesNotStartASecondCopy() {
        let (harness, _) = harnessWithHooks()
        harness.installFakeApp()
        harness.app.replies["ping"] = Data(#"{"ok":true,"pid":9}"#.utf8)
        XCTAssertEqual(harness.run(["setup", "claude", "--no-migrate"]), 0)
        XCTAssertEqual(harness.launchAgent.installs.map(\.start), [false])
        XCTAssertTrue(harness.stdout.text.contains("app: installed, not started: SidePulse already runs outside launchd (pid 9)"))
    }

    func testLaunchdFailureExitsOne() {
        let (harness, _) = harnessWithHooks()
        harness.installFakeApp()
        harness.launchAgent.installError = CommandFailure(message: "Bootstrap failed: 5: Input/output error")
        XCTAssertEqual(harness.run(["setup", "claude", "--no-migrate"]), 1)
        XCTAssertTrue(harness.stderr.text.contains("app: launch agent failed\n"))
        XCTAssertTrue(harness.stderr.text.contains("  error: Bootstrap failed: 5: Input/output error\n"))
        XCTAssertTrue(harness.stdout.text.contains("Setup finished with errors"))
    }

    func testHookFailureExitsOneButStillInstallsApp() {
        let harness = CLIHarness()
        harness.env.hooks = HookOperations(
            install: { _, _, _, _, _ in throw JSONError("Unexpected character", offset: 0) },
            uninstall: { _, _, _ in throw CommandFailure(message: "unexpected") }
        )
        harness.installFakeApp()
        XCTAssertEqual(harness.run(["setup", "claude", "--no-migrate"]), 1)
        XCTAssertEqual(harness.launchAgent.installs.count, 1)
        XCTAssertTrue(harness.stderr.text.contains("claude: install failed"))
    }
}
