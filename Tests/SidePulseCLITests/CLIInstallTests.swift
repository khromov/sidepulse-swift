import XCTest
@testable import SidePulseCLI
import SidePulseCore

final class CLIInstallTests: XCTestCase {
    private let config = URL(fileURLWithPath: "/Users/x/.claude/settings.json")

    // MARK: Result blocks

    func testInstallHeadlines() {
        func headline(changed: Bool, dryRun: Bool, _ action: HookAction) -> String {
            InstallText.headline(InstallResult(provider: .claude, configPath: config, changed: changed, dryRun: dryRun),
                                 action: action)
        }
        XCTAssertEqual(headline(changed: true, dryRun: false, .install), "updated")
        XCTAssertEqual(headline(changed: true, dryRun: true, .install), "would update")
        XCTAssertEqual(headline(changed: false, dryRun: false, .install), "already configured")
        XCTAssertEqual(headline(changed: false, dryRun: true, .install), "already configured")
        XCTAssertEqual(headline(changed: true, dryRun: false, .uninstall), "removed")
        XCTAssertEqual(headline(changed: true, dryRun: true, .uninstall), "would remove")
        XCTAssertEqual(headline(changed: false, dryRun: true, .uninstall), "already uninstalled")
    }

    func testInstallBlock() {
        let result = InstallResult(provider: .claude, configPath: config, changed: true,
                                   backupPath: URL(fileURLWithPath: "/Users/x/.claude/settings.json.bak.20260926T100000Z"),
                                   dryRun: false, notes: ["trusted 11 Codex hooks"])
        XCTAssertEqual(InstallText.render(result, action: .install, logPath: URL(fileURLWithPath: "/state/logs/claude.jsonl")),
                       """
                       claude: updated
                         config: /Users/x/.claude/settings.json
                         log: /state/logs/claude.jsonl
                         backup: /Users/x/.claude/settings.json.bak.20260926T100000Z
                         note: trusted 11 Codex hooks
                       """)
    }

    func testUninstallBlockHasNoLogLine() {
        let result = InstallResult(provider: .codex, configPath: URL(fileURLWithPath: "/Users/x/.codex/config.toml"),
                                   changed: false, dryRun: true)
        XCTAssertEqual(InstallText.render(result, action: .uninstall, logPath: URL(fileURLWithPath: "/l")),
                       "codex: already uninstalled\n  config: /Users/x/.codex/config.toml")
    }

    func testFailureBlock() {
        XCTAssertEqual(InstallText.renderFailure(provider: .claude, configPath: config,
                                                 message: "Invalid JSON at byte 1: Unexpected character", action: .install),
                       "claude: install failed\n  config: /Users/x/.claude/settings.json\n"
                           + "  error: Invalid JSON at byte 1: Unexpected character")
    }

    // MARK: Provider selection

    func testProviderSelection() throws {
        let harness = CLIHarness()
        let paths = harness.paths
        XCTAssertEqual(ProviderSelection.resolve([], paths: paths, defaultToDetected: true), [])
        XCTAssertEqual(ProviderSelection.resolve([], paths: paths, defaultToDetected: false), [.claude, .codex, .opencode])
        try FileManager.default.createDirectory(at: paths.codexDir, withIntermediateDirectories: true)
        XCTAssertEqual(ProviderSelection.resolve([], paths: paths, defaultToDetected: true), [.codex])
        try FileManager.default.createDirectory(at: paths.claudeDir, withIntermediateDirectories: true)
        XCTAssertEqual(ProviderSelection.resolve([], paths: paths, defaultToDetected: true), [.claude, .codex])
        XCTAssertEqual(ProviderSelection.resolve(["codex", "claude", "codex"], paths: paths, defaultToDetected: true),
                       [.claude, .codex])
        XCTAssertEqual(ProviderSelection.resolve(["codex"], paths: paths, defaultToDetected: true), [.codex])
        XCTAssertEqual(ProviderSelection.resolve(["opencode"], paths: paths, defaultToDetected: true), [.opencode])
        XCTAssertEqual(ProviderSelection.resolve(["all"], paths: paths, defaultToDetected: true), [.claude, .codex, .opencode])
    }

    func testOpenCodeIsDetectedByItsConfigDirectoryOrBinary() throws {
        let harness = CLIHarness()
        let binary = harness.home.appendingPathComponent(".opencode/bin/opencode")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: binary.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        XCTAssertEqual(ProviderSelection.resolve([], paths: harness.paths, defaultToDetected: true), [.opencode])
        try FileManager.default.removeItem(at: binary)
        XCTAssertEqual(ProviderSelection.resolve([], paths: harness.paths, defaultToDetected: true), [])
        try FileManager.default.createDirectory(at: harness.paths.openCodeConfigDir, withIntermediateDirectories: true)
        XCTAssertEqual(ProviderSelection.resolve([], paths: harness.paths, defaultToDetected: true), [.opencode])
    }

    func testProviderPositionalsAcceptEveryProvider() {
        let harness = CLIHarness()
        let log = HookLog()
        harness.env.hooks = hooks(log)
        XCTAssertEqual(harness.run(["install", "opencode", "claude", "codex", "all", "--dry-run"]), 0)
        XCTAssertEqual(log.installs.map(\.0), [.claude, .codex, .opencode])
        XCTAssertEqual(harness.run(["uninstall", "grok"]), 2)
        XCTAssertTrue(harness.stderr.text.contains("(choose from 'claude', 'codex', 'opencode', 'all')"), harness.stderr.text)
    }

    func testAFileNamedLikeTheConfigDirDoesNotCountAsDetected() {
        let harness = CLIHarness()
        FileManager.default.createFile(atPath: harness.paths.claudeDir.path, contents: Data())
        XCTAssertEqual(ProviderSelection.resolve([], paths: harness.paths, defaultToDetected: true), [])
    }

    // MARK: install / uninstall commands

    private final class HookLog {
        var installs: [(HookProvider, String, Bool, Bool)] = []
        var uninstalls: [(HookProvider, Bool)] = []
    }

    private func hooks(_ log: HookLog, failing: HookProvider? = nil) -> HookOperations {
        HookOperations(
            install: { provider, paths, cliPath, dryRun, trust in
                log.installs.append((provider, cliPath, dryRun, trust))
                if provider == failing { throw JSONError("Unexpected character", offset: 1) }
                return InstallResult(provider: provider, configPath: provider.configFile(paths), changed: true,
                                     dryRun: dryRun, notes: provider == .codex && trust ? ["trusted 11 Codex hooks"] : [])
            },
            uninstall: { provider, paths, dryRun in
                log.uninstalls.append((provider, dryRun))
                if provider == failing { throw JSONError("Unexpected character", offset: 1) }
                return InstallResult(provider: provider, configPath: provider.configFile(paths), changed: false,
                                     dryRun: dryRun)
            }
        )
    }

    func testInstallDefaultsToDetectedAgents() throws {
        let harness = CLIHarness()
        let log = HookLog()
        harness.env.hooks = hooks(log)
        try FileManager.default.createDirectory(at: harness.paths.claudeDir, withIntermediateDirectories: true)
        XCTAssertEqual(harness.run(["install"]), 0)
        XCTAssertEqual(log.installs.map(\.0), [.claude])
        XCTAssertEqual(log.installs.first?.1, CLIHarness.cliPath)
        XCTAssertEqual(harness.stdout.text, """
            claude: updated
              config: \(harness.paths.claudeSettingsFile.path)
              log: \(harness.paths.logFile(for: "claude").path)

            """)
        // SIDEPULSE_CLI_PATH is explicit, so no unstable-path note.
        XCTAssertEqual(harness.stderr.text, "")
    }

    func testInstallWithNoAgentsDoesNothing() {
        let harness = CLIHarness()
        let log = HookLog()
        harness.env.hooks = hooks(log)
        XCTAssertEqual(harness.run(["install"]), 0)
        XCTAssertTrue(log.installs.isEmpty)
        XCTAssertEqual(harness.stdout.text, ProviderSelection.noAgentsMessage + "\n")
    }

    func testInstallExplicitProvidersDryRunAndNoTrust() {
        let harness = CLIHarness()
        let log = HookLog()
        harness.env.hooks = hooks(log)
        XCTAssertEqual(harness.run(["install", "all", "--dry-run", "--no-trust"]), 0)
        XCTAssertEqual(log.installs.map(\.0), [.claude, .codex, .opencode])
        XCTAssertTrue(log.installs.allSatisfy { $0.2 && !$0.3 })
        XCTAssertTrue(harness.stdout.text.contains("claude: would update\n"))
        XCTAssertTrue(harness.stdout.text.contains("codex: would update\n"))
        XCTAssertFalse(harness.stdout.text.contains("trusted"))
    }

    func testInstallContinuesAfterAFailureAndExitsOne() {
        let harness = CLIHarness()
        let log = HookLog()
        harness.env.hooks = hooks(log, failing: .claude)
        XCTAssertEqual(harness.run(["install", "claude", "codex"]), 1)
        XCTAssertEqual(log.installs.map(\.0), [.claude, .codex])
        XCTAssertEqual(harness.stderr.text, """
            claude: install failed
              config: \(harness.paths.claudeSettingsFile.path)
              error: Invalid JSON at byte 1: Unexpected character

            """)
        XCTAssertTrue(harness.stdout.text.hasPrefix("codex: updated\n"))
        XCTAssertTrue(harness.stdout.text.contains("  note: trusted 11 Codex hooks\n"))
    }

    func testUnstableCLIPathNote() {
        let harness = CLIHarness(variables: ["SIDEPULSE_CLI_PATH": ""])
        let env = harness.env!
        XCTAssertNotNil(InstallCommand.unstableCLINote(cliPath: "/tmp/build/debug/sidepulse", env: env))
        XCTAssertNil(InstallCommand.unstableCLINote(cliPath: env.paths.defaultCLILink.path, env: env))
        XCTAssertNil(InstallCommand.unstableCLINote(
            cliPath: "/Applications/SidePulse.app/Contents/Helpers/sidepulse", env: env))
        XCTAssertNil(InstallCommand.unstableCLINote(cliPath: "/x", env: CLIHarness().env))
    }

    func testUninstallDefaultsToEveryProvider() {
        let harness = CLIHarness()
        let log = HookLog()
        harness.env.hooks = hooks(log)
        XCTAssertEqual(harness.run(["uninstall", "--dry-run"]), 0)
        XCTAssertEqual(log.uninstalls.map(\.0), [.claude, .codex, .opencode])
        XCTAssertTrue(log.uninstalls.allSatisfy(\.1))
        XCTAssertEqual(harness.stdout.text, """
            claude: already uninstalled
              config: \(harness.paths.claudeSettingsFile.path)
            codex: already uninstalled
              config: \(harness.paths.codexConfigFile.path)
            opencode: already uninstalled
              config: \(harness.paths.openCodePluginFile.path)

            """)
    }

    func testUninstallFailureExitsOne() {
        let harness = CLIHarness()
        let log = HookLog()
        harness.env.hooks = hooks(log, failing: .codex)
        XCTAssertEqual(harness.run(["uninstall", "codex"]), 1)
        XCTAssertTrue(harness.stderr.text.hasPrefix("codex: uninstall failed\n"))
    }
}
