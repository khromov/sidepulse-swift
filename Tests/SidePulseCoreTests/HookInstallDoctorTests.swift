import XCTest
@testable import SidePulseCore

final class HookInstallDoctorTests: XCTestCase {
    typealias T = HookInstallTestData

    func testEmptyHome() throws {
        let box = try HookInstallSandbox()
        let infos = HookDoctor.inspectAll(paths: box.paths)
        XCTAssertEqual(infos.map(\.provider), [.claude, .codex])
        for info in infos {
            XCTAssertFalse(info.configExists)
            XCTAssertFalse(info.agentDetected)
            XCTAssertEqual(info.installedEvents, [])
            XCTAssertEqual(info.missingEvents, info.provider.events)
            XCTAssertFalse(info.fullyInstalled)
            XCTAssertNil(info.error)
        }
        XCTAssertTrue(infos[0].hooksEnabled)
        XCTAssertFalse(infos[1].hooksEnabled)
        XCTAssertEqual(HookDoctor.renderText(infos), """
        claude:
          config: \(box.paths.claudeSettingsFile.path) (missing)
          hooks: not installed
          legacy python hooks: 0
          log: \(box.paths.logFile(for: "claude").path) (missing)
        codex:
          config: \(box.paths.codexConfigFile.path) (missing)
          hooks: not installed
          legacy python hooks: 0
          log: \(box.paths.logFile(for: "codex").path) (missing)
        """)
    }

    func testFullyInstalled() throws {
        let box = try HookInstallSandbox()
        let cli = try box.makeBundledCLI()
        _ = try ClaudeHookInstaller.install(paths: box.paths, cliPath: cli, dryRun: false)
        _ = try CodexHookInstaller.install(paths: box.paths, cliPath: cli, dryRun: false, trust: false)
        try box.trustCodexHooks()
        try box.write("", to: box.paths.logFile(for: "claude"))
        let infos = HookDoctor.inspectAll(paths: box.paths)
        XCTAssertTrue(infos.allSatisfy(\.fullyInstalled))
        XCTAssertTrue(infos.allSatisfy(\.agentDetected))
        XCTAssertEqual(infos[1].installedEvents, HookProvider.codex.events)
        XCTAssertEqual(infos.map(\.hookCLIPaths), [[cli], [cli]])
        XCTAssertEqual(HookDoctor.renderText(infos), """
        claude:
          config: \(box.paths.claudeSettingsFile.path) (found)
          hooks: installed (12/12 events)
          hook cli: \(cli) (ok)
          legacy python hooks: 0
          log: \(box.paths.logFile(for: "claude").path) (found)
        codex:
          config: \(box.paths.codexConfigFile.path) (found)
          hooks: installed (11/11 events)
          hook cli: \(cli) (ok)
          trust: 11/11 hooks trusted
          legacy python hooks: 0
          log: \(box.paths.logFile(for: "codex").path) (missing)
        """)

        let json = HookDoctor.renderJSON(infos)
        let first = json["providers"]?.arrayValue?.first
        XCTAssertEqual(first?.objectValue?.keys, ["provider", "config_path", "config_exists", "agent_detected", "hooks_enabled",
                                                  "installed_events", "missing_events", "legacy_hooks", "log_path", "log_exists", "error",
                                                  "hook_cli_paths", "hook_cli_problems", "untrusted_events"])
        XCTAssertEqual(first?["hook_cli_paths"], .array([.string(cli)]))
        XCTAssertEqual(first?["hook_cli_problems"], .array([]))
        XCTAssertEqual(first?["provider"], .string("claude"))
        XCTAssertEqual(first?["config_path"], .string(box.paths.claudeSettingsFile.path))
        XCTAssertEqual(first?["installed_events"]?.arrayValue?.count, 12)
        XCTAssertEqual(first?["missing_events"], .array([]))
        XCTAssertEqual(first?["legacy_hooks"], .number("0"))
        XCTAssertEqual(first?["log_exists"], .bool(true))
        XCTAssertEqual(first?["error"], .null)
        XCTAssertEqual(json["providers"]?.arrayValue?.last?["hooks_enabled"], .bool(true))
    }

    func testPartialLegacyAndErrors() throws {
        let box = try HookInstallSandbox()
        let partial = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\#(T.claudeCommand)"}]}],"#
            + #""SessionStart":[{"hooks":[{"type":"command","command":"\#(T.claudeCommand)"}]}],"#
            + #""PreToolUse":[{"hooks":[{"type":"command","command":"python /x/hook_entry.py --provider claude --log /l ; true"}]}]}}"#
        try box.write(partial, to: box.paths.claudeSettingsFile)
        try box.write("[features]\nhooks = false\n\n" + CodexHookInstaller.block(command: T.codexCommand), to: box.paths.codexConfigFile)

        let claude = HookDoctor.inspect(paths: box.paths, provider: .claude)
        XCTAssertEqual(claude.installedEvents, ["SessionStart", "Stop"])
        XCTAssertEqual(claude.legacyHooks, 1)
        XCTAssertEqual(claude.missingEvents.count, 10)
        let codex = HookDoctor.inspect(paths: box.paths, provider: .codex)
        XCTAssertFalse(codex.hooksEnabled)
        XCTAssertFalse(codex.fullyInstalled)
        let text = HookDoctor.renderText([claude, codex])
        XCTAssertTrue(text.contains("  hooks: partial (2/12)\n  missing events: UserPromptSubmit, PreToolUse, PostToolUse,"))
        XCTAssertTrue(text.contains("  legacy python hooks: 1\n"))
        XCTAssertTrue(text.contains("  hooks: installed (11/11 events)\n"))
        XCTAssertTrue(text.contains("  hooks feature: disabled ([features] hooks is not true, so Codex runs no hooks)\n"))

        try box.write("{ broken", to: box.paths.claudeSettingsFile)
        let broken = HookDoctor.inspect(paths: box.paths, provider: .claude)
        XCTAssertTrue(broken.configExists)
        XCTAssertFalse(broken.hooksEnabled)
        XCTAssertNotNil(broken.error)
        XCTAssertTrue(HookDoctor.renderText([broken]).contains("\n  error: Invalid JSON"))
        XCTAssertEqual(HookDoctor.renderJSON([broken])["providers"]?.arrayValue?.first?["error"]?.stringValue, broken.error)

        try box.write("[1]", to: box.paths.claudeSettingsFile)
        XCTAssertEqual(HookDoctor.inspect(paths: box.paths, provider: .claude).error, "the top level is not a JSON object")
    }

    /// Regression: hooks whose CLI is gone (the app moved, the ~/.local/bin link
    /// dangles) were reported as installed while every hook failed behind `; true`.
    func testHooksCallingAMissingCLIAreNotInstalled() throws {
        let box = try HookInstallSandbox()
        _ = try ClaudeHookInstaller.install(paths: box.paths, cliPath: T.cli, dryRun: false)
        let info = HookDoctor.inspect(paths: box.paths, provider: .claude)
        XCTAssertEqual(info.installedEvents.count, 12)
        XCTAssertEqual(info.hookCLIPaths, [T.cli])
        XCTAssertEqual(info.hookCLIProblems, ["\(T.cli) (missing)"])
        XCTAssertFalse(info.fullyInstalled)
        XCTAssertTrue(HookDoctor.renderText([info]).contains(
            "  hooks: installed (12/12 events)\n  hook cli: \(T.cli) (missing); run 'sidepulse install claude' to repair\n"))
    }

    /// Regression: hooks calling a foreign `sidepulse` (the Python CLI) looked fine.
    func testHooksCallingAForeignCLIAreReported() throws {
        let box = try HookInstallSandbox()
        let python = box.root.appendingPathComponent("venv/bin/sidepulse")
        try box.write("#!/bin/sh\nexit 2\n", to: python)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        _ = try ClaudeHookInstaller.install(paths: box.paths, cliPath: python.path, dryRun: false)
        let info = HookDoctor.inspect(paths: box.paths, provider: .claude)
        XCTAssertEqual(info.hookCLIProblems, ["\(python.path) (not the SidePulse CLI)"])
        // The same file counts when it is the CLI running the doctor.
        XCTAssertEqual(HookDoctor.inspect(paths: box.paths, provider: .claude, runningExecutable: python.path).hookCLIProblems, [])
    }

    /// Regression: hooks written from an explicit $SIDEPULSE_CLI_PATH (which install
    /// takes as is) were reported as "not the SidePulse CLI; run 'sidepulse install'
    /// to repair", and that install would write the same path again.
    func testExplicitCLIPathOverrideIsOnlyCheckedForExistence() throws {
        let box = try HookInstallSandbox()
        let wrapper = box.root.appendingPathComponent("bin/sp-wrapper")
        try box.write("#!/bin/sh\n", to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        _ = try ClaudeHookInstaller.install(paths: box.paths, cliPath: wrapper.path, dryRun: false)
        var environment = box.paths.environment
        environment["SIDEPULSE_CLI_PATH"] = wrapper.path
        let overridden = SidePulsePaths(environment: environment, home: box.home)
        XCTAssertEqual(HookDoctor.inspect(paths: overridden, provider: .claude).hookCLIProblems, [])
        XCTAssertEqual(HookDoctor.inspect(paths: box.paths, provider: .claude).hookCLIProblems,
                       ["\(wrapper.path) (not the SidePulse CLI)"])
        try FileManager.default.removeItem(at: wrapper)
        XCTAssertEqual(HookDoctor.inspect(paths: overridden, provider: .claude).hookCLIProblems, ["\(wrapper.path) (missing)"])
    }

    /// Regression: Codex hooks without trust entries (Codex skips them until
    /// approved) were reported as fully installed.
    func testUntrustedCodexHooksAreReported() throws {
        let box = try HookInstallSandbox()
        let cli = try box.makeBundledCLI()
        _ = try CodexHookInstaller.install(paths: box.paths, cliPath: cli, dryRun: false, trust: false)
        var info = HookDoctor.inspect(paths: box.paths, provider: .codex)
        XCTAssertEqual(info.untrustedEvents, HookProvider.codex.events)
        XCTAssertFalse(info.fullyInstalled)
        XCTAssertTrue(HookDoctor.renderText([info]).contains(
            "  trust: 0/11 hooks trusted; approve them with /hooks in Codex, or run 'sidepulse install codex'\n"))
        XCTAssertEqual(HookDoctor.renderJSON([info])["providers"]?.arrayValue?.first?["untrusted_events"]?.arrayValue?.count, 11)

        try box.trustCodexHooks(HookProvider.codex.events.filter { $0 != "Stop" })
        info = HookDoctor.inspect(paths: box.paths, provider: .codex)
        XCTAssertEqual(info.untrustedEvents, ["Stop"])
        XCTAssertTrue(HookDoctor.renderText([info]).contains("  trust: 10/11 hooks trusted;"))
        try box.trustCodexHooks(["Stop"])
        XCTAssertTrue(HookDoctor.inspect(paths: box.paths, provider: .codex).fullyInstalled)
        // Claude has no trust step.
        XCTAssertEqual(HookDoctor.inspect(paths: box.paths, provider: .claude).untrustedEvents, [])
    }

    /// Regression: with `[features] hooks = false` doctor advised /hooks (Codex lists
    /// nothing then) or reinstalling (which skips trust while hooks are off).
    func testDisabledCodexHooksGetNoTrustAdvice() throws {
        let box = try HookInstallSandbox()
        try box.write("[features]\nhooks = false\n", to: box.paths.codexConfigFile)
        _ = try CodexHookInstaller.install(paths: box.paths, cliPath: try box.makeBundledCLI(), dryRun: false, trust: true)
        let text = HookDoctor.renderText([HookDoctor.inspect(paths: box.paths, provider: .codex)])
        XCTAssertTrue(text.contains("  trust: 0/11 hooks trusted\n  hooks feature: disabled"), text)
        XCTAssertFalse(text.contains("/hooks in Codex"), text)
    }

    func testLegacyPythonCounts() throws {
        let box = try HookInstallSandbox()
        try box.write(HookInstallFixtures.pythonClaudeSettings, to: box.paths.claudeSettingsFile)
        try box.write(HookInstallFixtures.pythonCodexConfigReinstalled, to: box.paths.codexConfigFile)
        let infos = HookDoctor.inspectAll(paths: box.paths)
        XCTAssertEqual(infos.map(\.legacyHooks), [14, 11])
        XCTAssertEqual(infos.map(\.installedEvents), [[], []])
        XCTAssertTrue(infos[1].hooksEnabled)
    }
}
