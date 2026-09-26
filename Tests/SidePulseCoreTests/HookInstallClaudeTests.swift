import XCTest
@testable import SidePulseCore

final class HookInstallClaudeTests: XCTestCase {
    typealias T = HookInstallTestData
    let cmd = HookInstallTestData.claudeCommand

    // MARK: Pure transform

    func testFreshInstallWritesAllEventsWithTimeout() throws {
        let text = try ClaudeHookInstaller.installing(into: nil, command: cmd)
        let root = try JSONValue.parse(text)
        XCTAssertEqual(root.objectValue?.keys, ["hooks"])
        XCTAssertEqual(root["hooks"]?.objectValue?.keys, HookProvider.claude.events)
        for event in HookProvider.claude.events {
            XCTAssertEqual(root["hooks"]?[event], ClaudeHookInstaller.desiredEntry(command: cmd).asArray, event)
        }
        XCTAssertTrue(text.hasSuffix("}\n"))
        XCTAssertTrue(text.contains("\n  \"hooks\": {\n    \"SessionStart\": [\n      {\n        \"matcher\": \"*\","))
        XCTAssertTrue(text.contains(#""timeout": 10"#))
        XCTAssertEqual(try ClaudeHookInstaller.installing(into: "", command: cmd), text)
        XCTAssertEqual(try ClaudeHookInstaller.installing(into: "  \n", command: cmd), text)
    }

    func testHandlerShape() throws {
        let text = try ClaudeHookInstaller.installing(into: nil, command: cmd)
        let handler = try JSONValue.parse(text)["hooks"]?["Stop"]?.arrayValue?.first?["hooks"]?.arrayValue?.first
        XCTAssertEqual(handler?.serialized(), #"{"type":"command","command":"\#(cmd)","timeout":10}"#)
    }

    func testReinstallIsByteIdentical() throws {
        let once = try ClaudeHookInstaller.installing(into: #"{"model":"opus"}"#, command: cmd)
        let twice = try ClaudeHookInstaller.installing(into: once, command: cmd)
        XCTAssertEqual(once, twice)
    }

    func testUnchangedDocumentKeepsOriginalFormatting() throws {
        // Already installed but written compactly by someone else: nothing to do,
        // so the user's formatting must survive.
        let pretty = try ClaudeHookInstaller.installing(into: nil, command: cmd)
        let compact = try JSONValue.parse(pretty).serialized()
        XCTAssertEqual(try ClaudeHookInstaller.installing(into: compact, command: cmd), compact)
    }

    func testReinstallDoesNotReorderUserEntriesAddedAfterOurs() throws {
        var root = try JSONValue.parse(try ClaudeHookInstaller.installing(into: nil, command: cmd)).objectValue!
        var hooks = root["hooks"]!.objectValue!
        let user: JSONValue = .object(["hooks": .array([.object(["type": .string("command"), "command": .string("say hi")])])])
        hooks["Stop"] = .array(hooks["Stop"]!.arrayValue! + [user])
        root["hooks"] = .object(hooks)
        let text = JSONValue.object(root).serialized(pretty: true) + "\n"
        XCTAssertEqual(try ClaudeHookInstaller.installing(into: text, command: cmd), text)
    }

    /// Port of test_claude_installer_replaces_target_hook_and_preserves_other_hooks,
    /// adjusted: a user hook that appends to a log is NOT ours (Python matched on
    /// the log path and deleted it).
    func testInstallPreservesOtherSettingsAndUserHooks() throws {
        let input = #"""
        {"permissions": {"allow": ["Bash(date)"]}, "hooks": {"PreToolUse": [{"matcher": "*", "hooks": [
          {"type": "command", "command": "jq -c . >> /Users/tester/.local/state/sidepulse/agent-monitor/claude.jsonl"},
          {"type": "command", "command": "echo keep >> /tmp/other.log"}]}]}}
        """#
        let output = try ClaudeHookInstaller.installing(into: input, command: cmd)
        let root = try JSONValue.parse(output)
        XCTAssertEqual(root.objectValue?.keys, ["permissions", "hooks"])
        XCTAssertEqual(root["permissions"]?["allow"], .array([.string("Bash(date)")]))
        let commands = try T.claudeCommands(output)["PreToolUse"]!
        XCTAssertEqual(commands, [
            "jq -c . >> /Users/tester/.local/state/sidepulse/agent-monitor/claude.jsonl",
            "echo keep >> /tmp/other.log",
            cmd,
        ])
    }

    func testUserHookWithRedirectSurvivesInstallAndUninstall() throws {
        let input = #"{"hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"say done >> /tmp/user-notify.log"}]}]}}"#
        let installed = try ClaudeHookInstaller.installing(into: input, command: cmd)
        XCTAssertEqual(try T.claudeCommands(installed)["Stop"], ["say done >> /tmp/user-notify.log", cmd])
        let removed = try ClaudeHookInstaller.uninstalling(from: installed)
        XCTAssertEqual(try JSONValue.parse(removed), try JSONValue.parse(input))
    }

    func testInstallReplacesLegacyHandlersButKeepsUserHandlersInTheSameEntry() throws {
        let input = #"""
        {"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [
            {"type": "command", "command": "echo pre"},
            {"type": "command", "command": "/usr/bin/python3 /x/sidepulse/hook_entry.py --provider claude --log /tmp/c.jsonl ; true"}]}],
          "Stop": [{"matcher": "*", "hooks": [{"type": "command", "command": "/old/sidepulse hook-log --provider claude ; true"}]}]}}
        """#
        let output = try ClaudeHookInstaller.installing(into: input, command: cmd)
        let pre = try JSONValue.parse(output)["hooks"]?["PreToolUse"]?.arrayValue ?? []
        XCTAssertEqual(pre.count, 2)
        XCTAssertEqual(pre[0], .object(["matcher": .string("Bash"), "hooks": .array([
            .object(["type": .string("command"), "command": .string("echo pre")]),
        ])]))
        XCTAssertEqual(try T.claudeCommands(output)["Stop"], [cmd])
    }

    func testNonStandardEntriesAreKeptUntouched() throws {
        let input = #"{"hooks":{"Stop":["future-hook",{"matcher":"*"},{"hooks":"odd"},{"hooks":[]},{"hooks":[42,{"type":"command"}]}]}}"#
        let output = try ClaudeHookInstaller.installing(into: input, command: cmd)
        let stop = try JSONValue.parse(output)["hooks"]?["Stop"]?.arrayValue ?? []
        XCTAssertEqual(Array(stop.dropLast()), try JSONValue.parse(input)["hooks"]?["Stop"]?.arrayValue)
        XCTAssertEqual(stop.last, ClaudeHookInstaller.desiredEntry(command: cmd))
        XCTAssertEqual(try ClaudeHookInstaller.uninstalling(from: output).trimmingCharacters(in: .newlines),
                       try JSONValue.parse(input).serialized(pretty: true))
    }

    func testKeyOrderAndUnicodeArePreserved() throws {
        let input = "{\"z\":1,\"tagline\":\"caf\\u00e9 \u{2603}\",\"a\":{\"y\":true,\"b\":null},\"hooks\":{\"Custom\":[]},\"n\":3600.0}"
        let output = try ClaudeHookInstaller.installing(into: input, command: cmd)
        let root = try JSONValue.parse(output)
        XCTAssertEqual(root.objectValue?.keys, ["z", "tagline", "a", "hooks", "n"])
        XCTAssertEqual(root["a"]?.objectValue?.keys, ["y", "b"])
        XCTAssertEqual(root["n"], .number("3600.0"))
        XCTAssertEqual(root["tagline"], .string("caf\u{E9} \u{2603}"))
        XCTAssertTrue(output.contains("caf\u{E9} \u{2603}"), "non-ASCII is written as UTF-8, not \\u escapes")
        XCTAssertEqual(root["hooks"]?.objectValue?.keys, ["Custom"] + HookProvider.claude.events)
    }

    func testMalformedJSONThrows() {
        for bad in ["{", "{\"hooks\": }", "[1,]", "nope"] {
            XCTAssertThrowsError(try ClaudeHookInstaller.installing(into: bad, command: cmd), bad) { error in
                guard case HookInstallError.invalidJSON = error else { return XCTFail("\(error)") }
            }
            XCTAssertThrowsError(try ClaudeHookInstaller.uninstalling(from: bad), bad)
        }
    }

    func testRefusesToClobberUnexpectedShapes() {
        for bad in ["[]", "\"text\"", #"{"hooks":[]}"#, #"{"hooks":"x"}"#, #"{"hooks":{"Stop":{}}}"#] {
            XCTAssertThrowsError(try ClaudeHookInstaller.installing(into: bad, command: cmd), bad) { error in
                guard case HookInstallError.invalidStructure = error else { return XCTFail("\(error)") }
            }
        }
        // Null values are treated as absent.
        XCTAssertNoThrow(try ClaudeHookInstaller.installing(into: #"{"hooks":{"Stop":null}}"#, command: cmd))
        XCTAssertNoThrow(try ClaudeHookInstaller.installing(into: #"{"hooks":null}"#, command: cmd))
    }

    // MARK: Uninstall

    /// Port of test_claude_uninstaller_removes_monitor_hooks_and_preserves_other_hooks.
    func testUninstallRemovesOnlyOurHooks() throws {
        let input = #"{"permissions":{"allow":["Bash(date)"]},"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"echo keep >> /tmp/other.log"}]}]}}"#
        let installed = try ClaudeHookInstaller.installing(into: input, command: cmd)
        let removed = try ClaudeHookInstaller.uninstalling(from: installed)
        XCTAssertEqual(try T.claudeCommands(removed), ["PreToolUse": ["echo keep >> /tmp/other.log"]])
        XCTAssertEqual(try JSONValue.parse(removed)["permissions"]?["allow"], .array([.string("Bash(date)")]))
        XCTAssertEqual(removed, try JSONValue.parse(input).serialized(pretty: true) + "\n")
    }

    func testUninstallDropsEmptyHooksKeyButKeepsFile() throws {
        let installed = try ClaudeHookInstaller.installing(into: #"{"model":"opus"}"#, command: cmd)
        XCTAssertEqual(try ClaudeHookInstaller.uninstalling(from: installed), "{\n  \"model\": \"opus\"\n}\n")
        let bare = try ClaudeHookInstaller.installing(into: nil, command: cmd)
        XCTAssertEqual(try ClaudeHookInstaller.uninstalling(from: bare), "{}\n")
    }

    func testUninstallWithoutOurHooksReturnsTextVerbatim() throws {
        for text in ["", "{ }", "{\"hooks\": {}}", "{\"hooks\":{\"Stop\":[]}}", "[1]", "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"command\":\"say\"}]}]}}"] {
            XCTAssertEqual(try ClaudeHookInstaller.uninstalling(from: text), text)
        }
    }

    /// Regression: install used to clean only the 12 Claude events, so a legacy
    /// handler elsewhere survived while the note claimed it was removed.
    func testInstallRemovesSidePulseHandlersFromOtherEventsToo() throws {
        let legacy = "python /x/hook_entry.py --provider claude --log /l ; true"
        let input = #"{"hooks":{"PermissionDenied":[{"hooks":[{"type":"command","command":"\#(legacy)"}]}],"#
            + #""Custom":[{"hooks":[{"type":"command","command":"say custom"},{"type":"command","command":"\#(cmd)"}]}],"#
            + #""Odd":{"keep":true},"Empty":[]}}"#
        let output = try ClaudeHookInstaller.installing(into: input, command: cmd)
        let hooks = try XCTUnwrap(try JSONValue.parse(output)["hooks"]?.objectValue)
        XCTAssertEqual(hooks.keys, ["Custom", "Odd", "Empty"] + HookProvider.claude.events)
        XCTAssertEqual(try T.claudeCommands(output)["Custom"], ["say custom"])
        XCTAssertEqual(hooks["Odd"], .object(["keep": .bool(true)]))
        XCTAssertEqual(hooks["Empty"], .array([]))
        XCTAssertEqual(ClaudeHookInstaller.legacyHandlerCount(in: output), 0)
        XCTAssertEqual(try ClaudeHookInstaller.installing(into: output, command: cmd), output)
    }

    func testUninstallCleansEveryEventIncludingUnknownOnes() throws {
        let input = #"{"hooks":{"PermissionDenied":[{"hooks":[{"type":"command","command":"/x/sidepulse hook-log --provider claude ; true"}]}],"Stop":{"odd":true}}}"#
        let output = try ClaudeHookInstaller.uninstalling(from: input)
        XCTAssertEqual(try JSONValue.parse(output), try JSONValue.parse(#"{"hooks":{"Stop":{"odd":true}}}"#))
    }

    // MARK: Detection

    func testInstalledEventsAndLegacyCount() throws {
        XCTAssertEqual(ClaudeHookInstaller.installedEvents(in: try ClaudeHookInstaller.installing(into: nil, command: cmd)),
                       HookProvider.claude.events)
        XCTAssertEqual(ClaudeHookInstaller.installedEvents(in: "{"), [])
        XCTAssertEqual(ClaudeHookInstaller.legacyHandlerCount(in: "{"), 0)
        let mixed = #"{"hooks":{"Stop":[{"hooks":[{"command":"/x/sidepulse hook-log --provider claude ; true"}]}],"#
            + #""PreToolUse":[{"hooks":[{"command":"python /x/hook_entry.py --provider claude --log /l ; true"},{"command":"say"}]}],"#
            + #""Grok":[{"hooks":[{"command":"/x/sidepulse hook-log --provider claude ; true"}]}]}}"#
        XCTAssertEqual(ClaudeHookInstaller.installedEvents(in: mixed), ["Stop", "Grok"])
        XCTAssertEqual(ClaudeHookInstaller.legacyHandlerCount(in: mixed), 1)
    }

    // MARK: Files

    func testInstallCreatesFileWithoutBackupThenIsIdempotent() throws {
        let box = try HookInstallSandbox()
        let file = box.paths.claudeSettingsFile
        let first = try ClaudeHookInstaller.install(paths: box.paths, cliPath: T.cli, dryRun: false)
        XCTAssertTrue(first.changed)
        XCTAssertNil(first.backupPath)
        XCTAssertEqual(first.configPath, file)
        XCTAssertEqual(box.backups(of: file), [])
        let written = try box.read(file)
        XCTAssertEqual(ClaudeHookInstaller.installedEvents(in: written), HookProvider.claude.events)

        let second = try ClaudeHookInstaller.install(paths: box.paths, cliPath: T.cli, dryRun: false)
        XCTAssertFalse(second.changed)
        XCTAssertNil(second.backupPath)
        XCTAssertEqual(try box.read(file), written)
        XCTAssertEqual(box.backups(of: file), [])
    }

    func testInstallBacksUpExistingFileAndReportsLegacyRemoval() throws {
        let box = try HookInstallSandbox()
        let file = box.paths.claudeSettingsFile
        let original = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"python /x/hook_entry.py --provider claude --log /l ; true"}]}]}}"#
        try box.write(original, to: file)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let result = try ClaudeHookInstaller.install(paths: box.paths, cliPath: T.cli, dryRun: false, now: now)
        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.backupPath?.lastPathComponent, "settings.json.bak.\(TimeFormat.backupStamp(now))")
        XCTAssertEqual(try box.read(result.backupPath!), original)
        XCTAssertEqual(result.notes, ["removed 1 legacy Python hook"])
        XCTAssertEqual(try T.claudeCommands(try box.read(file))["Stop"], [T.claudeCommand])
    }

    func testDryRunWritesNothing() throws {
        let box = try HookInstallSandbox()
        let file = box.paths.claudeSettingsFile
        let fresh = try ClaudeHookInstaller.install(paths: box.paths, cliPath: T.cli, dryRun: true)
        XCTAssertTrue(fresh.changed)
        XCTAssertTrue(fresh.dryRun)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        try box.write("{\"hooks\":{\"Stop\":[{\"hooks\":[{\"command\":\"python /x/hook_entry.py --log /l\"}]}]}}", to: file)
        let before = try box.read(file)
        let result = try ClaudeHookInstaller.install(paths: box.paths, cliPath: T.cli, dryRun: true)
        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.notes, ["would remove 1 legacy Python hook"])
        XCTAssertEqual(try box.read(file), before)
        let removal = try ClaudeHookInstaller.uninstall(paths: box.paths, dryRun: true)
        XCTAssertTrue(removal.changed)
        XCTAssertEqual(try box.read(file), before)
        XCTAssertEqual(box.backups(of: file), [])
    }

    func testMalformedFileIsLeftUntouched() throws {
        let box = try HookInstallSandbox()
        let file = box.paths.claudeSettingsFile
        let broken = "{\n  \"model\": \"opus\",\n"
        try box.write(broken, to: file)
        XCTAssertThrowsError(try ClaudeHookInstaller.install(paths: box.paths, cliPath: T.cli, dryRun: false)) { error in
            guard case HookInstallError.invalidJSON(let path, _)? = error as? HookInstallError else { return XCTFail("\(error)") }
            XCTAssertEqual(path, file.path)
            XCTAssertTrue(String(describing: error).contains(file.path))
        }
        XCTAssertThrowsError(try ClaudeHookInstaller.uninstall(paths: box.paths, dryRun: false))
        XCTAssertEqual(try box.read(file), broken)
        XCTAssertEqual(box.backups(of: file), [])
    }

    func testNonUTF8FileIsLeftUntouched() throws {
        let box = try HookInstallSandbox()
        let bytes = Data([0x7B, 0x22, 0x61, 0x22, 0x3A, 0x22, 0xFF, 0xFE, 0x22, 0x7D])  // {"a":"\xFF\xFE"}
        try FileManager.default.createDirectory(at: box.paths.claudeDir, withIntermediateDirectories: true)
        try bytes.write(to: box.paths.claudeSettingsFile)
        XCTAssertThrowsError(try ClaudeHookInstaller.install(paths: box.paths, cliPath: T.cli, dryRun: false)) { error in
            guard case HookInstallError.unreadable? = error as? HookInstallError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: box.paths.claudeSettingsFile), bytes)
        try FileManager.default.createDirectory(at: box.paths.codexDir, withIntermediateDirectories: true)
        try bytes.write(to: box.paths.codexConfigFile)
        XCTAssertThrowsError(try CodexHookInstaller.install(paths: box.paths, cliPath: T.cli, dryRun: false, trust: false))
        XCTAssertEqual(try Data(contentsOf: box.paths.codexConfigFile), bytes)
    }

    func testUninstallMissingFileIsNoop() throws {
        let box = try HookInstallSandbox()
        let result = try ClaudeHookInstaller.uninstall(paths: box.paths, dryRun: false)
        XCTAssertFalse(result.changed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: box.paths.claudeSettingsFile.path))
    }

    func testInstallThenUninstallRoundTripWithBackups() throws {
        let box = try HookInstallSandbox()
        let file = box.paths.claudeSettingsFile
        let original = "{\n  \"model\": \"opus\",\n  \"hooks\": {\n    \"Stop\": [\n      {\n        \"matcher\": \"*\",\n        \"hooks\": [\n          {\n            \"type\": \"command\",\n            \"command\": \"say done >> /tmp/user-notify.log\"\n          }\n        ]\n      }\n    ]\n  }\n}\n"
        try box.write(original, to: file)
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        _ = try ClaudeHookInstaller.install(paths: box.paths, cliPath: T.cli, dryRun: false, now: t0)
        let result = try ClaudeHookInstaller.uninstall(paths: box.paths, dryRun: false, now: t0)
        XCTAssertTrue(result.changed)
        XCTAssertEqual(try box.read(file), original)
        // Same-second backups do not overwrite each other.
        XCTAssertEqual(box.backups(of: file).map(\.lastPathComponent),
                       ["settings.json.bak.\(TimeFormat.backupStamp(t0))", "settings.json.bak.\(TimeFormat.backupStamp(t0))-2"])
    }

    func testReadOnlySettingsAreRefusedWithoutBackup() throws {
        let box = try HookInstallSandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let file = box.paths.claudeSettingsFile
        try box.write(#"{"model":"opus"}"#, to: file)
        chmod(file.path, 0o444)
        defer { chmod(file.path, 0o644) }
        XCTAssertThrowsError(try ClaudeHookInstaller.install(paths: box.paths, cliPath: T.cli, dryRun: false)) { error in
            XCTAssertTrue(error.localizedDescription.contains("read-only"), error.localizedDescription)
        }
        XCTAssertEqual(try box.read(file), #"{"model":"opus"}"#)
        XCTAssertEqual(box.backups(of: file), [])
    }
}

private extension JSONValue {
    var asArray: JSONValue { .array([self]) }
}
