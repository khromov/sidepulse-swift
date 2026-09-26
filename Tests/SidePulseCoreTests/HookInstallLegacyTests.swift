import XCTest
@testable import SidePulseCore

/// This machine's real configs are only read, and skipped when absent; every write goes to a sandbox.
final class HookInstallLegacyTests: XCTestCase {
    typealias T = HookInstallTestData

    // MARK: Python fixtures

    func testPythonClaudeHooksAreReplacedAndUserHooksKept() throws {
        let python = HookInstallFixtures.pythonClaudeSettings
        XCTAssertEqual(ClaudeHookInstaller.legacyHandlerCount(in: python), 14)
        XCTAssertEqual(ClaudeHookInstaller.installedEvents(in: python), [])

        let installed = try ClaudeHookInstaller.installing(into: python, command: T.claudeCommand)
        XCTAssertEqual(ClaudeHookInstaller.legacyHandlerCount(in: installed), 0)
        XCTAssertEqual(ClaudeHookInstaller.installedEvents(in: installed), HookProvider.claude.events)
        let commands = try T.claudeCommands(installed)
        XCTAssertEqual(commands["Stop"], ["say done >> /tmp/user-notify.log", T.claudeCommand])
        XCTAssertEqual(commands["Notification"], ["terminal-notifier -message \"Claude Code Needs Help\" -sound Basso", T.claudeCommand])
        XCTAssertEqual(commands["UserPromptSubmit"], ["echo prompt >> /tmp/prompts.log", T.claudeCommand])
        XCTAssertEqual(commands["PreToolUse"], ["echo pre >> /tmp/pre.log", T.claudeCommand])
        for event in ["SessionStart", "PostToolUse", "SessionEnd"] { XCTAssertEqual(commands[event], [T.claudeCommand], event) }

        let before = try JSONValue.parse(python).objectValue!
        let after = try JSONValue.parse(installed).objectValue!
        XCTAssertEqual(after.keys, before.keys)
        for key in before.keys where key != "hooks" { XCTAssertEqual(after[key], before[key], key) }
        // The user's UserPromptSubmit entry keeps its own matcher and timeout.
        XCTAssertEqual(after["hooks"]?["UserPromptSubmit"]?.arrayValue?.first,
                       before["hooks"]?["UserPromptSubmit"]?.arrayValue?.first)

        let removed = try ClaudeHookInstaller.uninstalling(from: installed)
        XCTAssertEqual(try T.claudeCommands(removed), [
            "Stop": ["say done >> /tmp/user-notify.log"],
            "Notification": ["terminal-notifier -message \"Claude Code Needs Help\" -sound Basso"],
            "UserPromptSubmit": ["echo prompt >> /tmp/prompts.log"],
            "PreToolUse": ["echo pre >> /tmp/pre.log"],
        ])
        XCTAssertEqual(try ClaudeHookInstaller.uninstalling(from: python), removed, "uninstall cleans Python hooks directly too")
    }

    func testPythonClaudeMigrationThroughFiles() throws {
        let box = try HookInstallSandbox()
        try box.write(HookInstallFixtures.pythonClaudeSettings, to: box.paths.claudeSettingsFile)
        let result = try ClaudeHookInstaller.install(paths: box.paths, cliPath: try box.makeBundledCLI(), dryRun: false)
        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.notes, ["removed 14 legacy Python hooks"])
        XCTAssertEqual(try box.read(result.backupPath!), HookInstallFixtures.pythonClaudeSettings)
        let doctor = HookDoctor.inspect(paths: box.paths, provider: .claude)
        XCTAssertTrue(doctor.fullyInstalled)
        XCTAssertEqual(doctor.legacyHooks, 0)
    }

    // MARK: Real configs (read-only copies)

    private func realFile(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(relative)
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("\(relative) not present") }
        return String(decoding: data, as: UTF8.self)
    }

    func testCopyOfRealClaudeSettingsOnlyGainsHooks() throws {
        let original = try realFile(".claude/settings.json")
        let box = try HookInstallSandbox()
        try box.write(original, to: box.paths.claudeSettingsFile)
        guard (try? JSONValue.parse(original)) != nil else { throw XCTSkip("real settings.json does not parse") }

        let result = try ClaudeHookInstaller.install(paths: box.paths, cliPath: T.cli, dryRun: false)
        let installed = try box.read(box.paths.claudeSettingsFile)
        XCTAssertEqual(try box.read(result.backupPath ?? box.paths.claudeSettingsFile), original)
        let before = try JSONValue.parse(original).objectValue!
        let after = try JSONValue.parse(installed).objectValue!
        let expectedKeys = before.keys.contains("hooks") ? before.keys : before.keys + ["hooks"]
        XCTAssertEqual(after.keys, expectedKeys, "no key moves; hooks is appended only if absent")
        for key in before.keys where key != "hooks" { XCTAssertEqual(after[key], before[key], key) }
        XCTAssertEqual(ClaudeHookInstaller.installedEvents(in: installed), HookProvider.claude.events)
        let userBefore = try T.claudeCommands(original).mapValues { $0.filter { !HookCommand.isSidePulseCommand($0) } }
        let userAfter = try T.claudeCommands(installed).mapValues { $0.filter { !HookCommand.isSidePulseCommand($0) } }
        for (event, commands) in userBefore where !commands.isEmpty { XCTAssertEqual(userAfter[event], commands, event) }

        _ = try ClaudeHookInstaller.uninstall(paths: box.paths, dryRun: false)
        let removed = try box.read(box.paths.claudeSettingsFile)
        let cleaned = try JSONValue.parse(try ClaudeHookInstaller.uninstalling(from: original))
        XCTAssertEqual(try JSONValue.parse(removed), cleaned)
        XCTAssertEqual(try JSONValue.parse(removed).objectValue?.keys.filter { $0 != "hooks" }, before.keys.filter { $0 != "hooks" })
    }

    func testCopiesOfRealClaudeBackupsMigrate() throws {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("settings.json.bak") }
        var checked = 0
        for name in names.sorted() {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            guard case .object? = try? JSONValue.parse(text) else { continue }
            checked += 1
            let installed = try ClaudeHookInstaller.installing(into: text, command: T.claudeCommand)
            XCTAssertEqual(ClaudeHookInstaller.legacyHandlerCount(in: installed), 0, name)
            XCTAssertEqual(ClaudeHookInstaller.installedEvents(in: installed), HookProvider.claude.events, name)
            let removed = try ClaudeHookInstaller.uninstalling(from: installed)
            let userBefore = try T.claudeCommands(text).mapValues { $0.filter { !HookCommand.isSidePulseCommand($0) } }.filter { !$0.value.isEmpty }
            XCTAssertEqual(try T.claudeCommands(removed), userBefore, name)
            XCTAssertEqual(try JSONValue.parse(installed).objectValue?.keys.filter { $0 != "hooks" },
                           try JSONValue.parse(text).objectValue?.keys.filter { $0 != "hooks" }, name)
        }
        if checked == 0 { throw XCTSkip("no Claude settings backups present") }
    }

    /// Works whether or not SidePulse's own hooks are already installed in the real
    /// file: the invariants treat our managed block like any other SidePulse hooks.
    func testCopyOfRealCodexConfig() throws {
        let original = try realFile(".codex/config.toml")
        let realPath = NSHomeDirectory() + "/.codex/config.toml"
        try checkCodexMigration(original, configPath: realPath, label: "config.toml")

        // Trust keys in the sandbox copy still refer to the real path, so its trust tables are left as they are.
        let box = try HookInstallSandbox()
        try box.write(original, to: box.paths.codexConfigFile)
        let result = try CodexHookInstaller.install(paths: box.paths, cliPath: T.cli, dryRun: false, trust: false)
        XCTAssertEqual(try box.read(result.backupPath ?? box.paths.codexConfigFile), original)
        let again = try CodexHookInstaller.install(paths: box.paths, cliPath: T.cli, dryRun: false, trust: false)
        XCTAssertFalse(again.changed)
    }

    func testCopiesOfRealCodexBackupsMigrate() throws {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("config.toml.bak") }
        guard !names.isEmpty else { throw XCTSkip("no Codex config backups present") }
        for name in names.sorted() {
            let text = String(decoding: try Data(contentsOf: dir.appendingPathComponent(name)), as: UTF8.self)
            try checkCodexMigration(text, configPath: dir.path + "/config.toml", label: name)
        }
    }

    private func checkCodexMigration(_ original: String, configPath: String, label: String) throws {
        let installed = CodexHookInstaller.installing(into: original, command: T.codexCommand, configPath: configPath)
        XCTAssertEqual(CodexHookInstaller.installedEvents(in: installed), HookProvider.codex.events, label)
        XCTAssertEqual(CodexHookInstaller.legacyBlockCount(in: installed), 0, label)
        XCTAssertTrue(CodexHookInstaller.hooksFeatureEnabled(in: installed), label)
        XCTAssertEqual(T.count(CodexHookInstaller.managedStart, in: installed), 1, label)
        XCTAssertFalse(installed.contains("Provider-neutral status collection"), label)
        XCTAssertFalse(installed.contains("agent-monitor hooks"), label)
        XCTAssertFalse(installed.contains("hook_entry.py"), label)
        XCTAssertEqual(CodexHookInstaller.installing(into: installed, command: T.codexCommand, configPath: configPath), installed, label)

        // Uninstall after install = uninstall alone, except that install may have
        // added `hooks = true` to [features], which uninstall leaves in place.
        let removed = CodexHookInstaller.uninstalling(from: original, configPath: configPath)
        var roundTrip = TOMLLines(CodexHookInstaller.uninstalling(from: installed, configPath: configPath)).lines
        if !CodexHookInstaller.hooksFeatureEnabled(in: original), let added = roundTrip.firstIndex(of: "hooks = true") {
            roundTrip.remove(at: added)
        }
        XCTAssertEqual(roundTrip, TOMLLines(removed).lines, label)
        XCTAssertFalse(removed.contains("hook-log"), label)
        XCTAssertFalse(removed.contains("sidepulse hooks"), label)

        // Nothing of the user's is lost: the result is the original minus our
        // blocks, managed and legacy markers, stray comments and this file's trust tables.
        let originalDoc = TOMLLines(original)
        let removedLines = TOMLLines(removed).lines
        var ours = Set<Int>()
        for group in CodexHookInstaller.hookGroups(in: originalDoc) where group.isSidePulse { ours.formUnion(group.range) }
        for i in originalDoc.lines.indices {
            guard let header = originalDoc.headerPath(at: i), header.path.count == 3, header.path[0] == "hooks",
                  header.path[1] == "state", header.path[2].hasPrefix(configPath + ":") else { continue }
            ours.formUnion(i...originalDoc.contentEnd(start: i, end: originalDoc.nextHeader(after: i)))
        }
        var expected: [String] = []
        for (i, line) in originalDoc.lines.enumerated() where !ours.contains(i) && !TOMLLines.isBlank(line) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# Provider-neutral") || trimmed.contains("agent-monitor hooks") || trimmed == "[hooks.state]"
                || trimmed == CodexHookInstaller.managedStart || trimmed == CodexHookInstaller.managedEnd { continue }
            expected.append(line)
        }
        XCTAssertEqual(removedLines.filter { !TOMLLines.isBlank($0) && $0.trimmingCharacters(in: .whitespaces) != "[hooks.state]" },
                       expected, label)
    }
}
