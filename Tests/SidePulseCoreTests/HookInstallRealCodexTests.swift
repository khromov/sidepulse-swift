import XCTest
@testable import SidePulseCore

/// Runs the real `codex` in a throwaway HOME, and `childEnvironment` drops `CODEX_HOME`, so the real
/// `~/.codex` is never touched.
final class HookInstallRealCodexTests: XCTestCase {
    typealias T = HookInstallTestData

    private func codexBinary() throws -> String {
        let env = ProcessInfo.processInfo.environment
        if env["SIDEPULSE_SKIP_CODEX_TESTS"] == "1" { throw XCTSkip("SIDEPULSE_SKIP_CODEX_TESTS=1") }
        guard let codex = CodexTrust.findCodexBinary(environment: env) else { throw XCTSkip("codex is not installed") }
        return codex
    }

    private func hooks(_ box: HookInstallSandbox, _ paths: SidePulsePaths, codex: String) throws -> [JSONValue] {
        let result = try CodexTrust.listHooks(codexPath: codex, configFile: paths.codexConfigFile, timeout: 20,
                                              environment: CodexTrust.childEnvironment(for: paths))
        return result["data"]?.arrayValue?.flatMap { $0["hooks"]?.arrayValue ?? [] } ?? []
    }

    func testInstallMakesCodexTrustOurHooks() throws {
        let codex = try codexBinary()
        let box = try HookInstallSandbox(extraEnvironment: ["CODEX_CLI_PATH": codex])
        let paths = box.paths
        let config = paths.codexConfigFile
        try box.write("""
        model = "gpt-6"

        [[hooks.Stop]]
        matcher = "*"
        [[hooks.Stop.hooks]]
        type = "command"
        command = "say done >> /tmp/user-notify.log"

        """, to: config)

        let result = try CodexHookInstaller.install(paths: paths, cliPath: T.cli, dryRun: false)
        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.notes, ["trusted 11 Codex hooks"])
        let installedText = try box.read(config)

        let listed = try hooks(box, paths, codex: codex)
        let ours = listed.filter { $0["command"]?.stringValue == T.codexCommand }
        XCTAssertEqual(ours.count, 11)
        XCTAssertEqual(Set(ours.compactMap { $0["trustStatus"]?.stringValue }), ["trusted"])
        // Codex clamps Interrupt hooks to 3 s; everything else keeps our 10 s.
        for hook in ours {
            XCTAssertEqual(hook["timeoutSec"]?.intValue, hook["eventName"] == .string("interrupt") ? 3 : 10)
        }
        XCTAssertEqual(Set(ours.compactMap { $0["sourcePath"]?.stringValue }), [config.path])
        // Our Stop hook follows the user's group.
        XCTAssertTrue(ours.contains { $0["key"]?.stringValue == "\(config.path):stop:1:0" })
        let user = listed.first { $0["command"]?.stringValue == "say done >> /tmp/user-notify.log" }
        XCTAssertEqual(user?["trustStatus"], .string("untrusted"))

        let again = try CodexHookInstaller.install(paths: paths, cliPath: T.cli, dryRun: false)
        XCTAssertFalse(again.changed)
        XCTAssertEqual(try box.read(config), installedText)

        let removed = try CodexHookInstaller.uninstall(paths: paths, dryRun: false)
        XCTAssertTrue(removed.changed)
        let after = try box.read(config)
        XCTAssertFalse(after.contains("trusted_hash"))
        XCTAssertFalse(after.contains("hook-log"))
        let remaining = try hooks(box, paths, codex: codex)
        XCTAssertEqual(remaining.compactMap { $0["command"]?.stringValue }, ["say done >> /tmp/user-notify.log"])
    }

    /// Regression: after uninstall, a user's inline `hooks = [...]` group kept SidePulse's old key and read "modified".
    func testInlineUserGroupStaysTrustedAfterUninstall() throws {
        let codex = try codexBinary()
        let box = try HookInstallSandbox(extraEnvironment: ["CODEX_CLI_PATH": codex])
        let paths = box.paths
        let config = paths.codexConfigFile
        _ = try CodexHookInstaller.install(paths: paths, cliPath: T.cli, dryRun: false)
        try box.write(try box.read(config) + """

        [[hooks.Stop]]
        matcher = "*"
        hooks = [{ type = "command", command = "say mine" }]

        """, to: config)
        let mine = try XCTUnwrap(try hooks(box, paths, codex: codex).first { $0["command"]?.stringValue == "say mine" })
        let key = try XCTUnwrap(mine["key"]?.stringValue)
        XCTAssertTrue(key.hasSuffix(":stop:1:0"), key)
        try box.write(CodexTrust.applyTrustedHashes([key: mine["currentHash"]!.stringValue!], to: try box.read(config)), to: config)

        _ = try CodexHookInstaller.uninstall(paths: paths, dryRun: false)
        XCTAssertEqual(T.count("[hooks.state.", in: try box.read(config)), 1)
        let after = try hooks(box, paths, codex: codex)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?["trustStatus"], .string("trusted"))
        XCTAssertTrue(after.first?["key"]?.stringValue?.hasSuffix(":stop:0:0") ?? false)
    }

    func testUserTrustSurvivesLegacyCleanup() throws {
        let codex = try codexBinary()
        let box = try HookInstallSandbox(extraEnvironment: ["CODEX_CLI_PATH": codex])
        let paths = box.paths
        let config = paths.codexConfigFile
        let legacy = "/usr/bin/python3 /x/sidepulse/hook_entry.py --provider codex --log /tmp/l.jsonl ; true"
        try box.write("""
        [features]
        hooks = true

        [[hooks.PreToolUse]]
        matcher = "*"
        [[hooks.PreToolUse.hooks]]
        type = "command"
        command = '''\(legacy)'''

        [[hooks.PreToolUse]]
        matcher = "*"
        [[hooks.PreToolUse.hooks]]
        type = "command"
        command = '''\(legacy)'''

        [[hooks.PreToolUse]]
        matcher = "Bash"
        [[hooks.PreToolUse.hooks]]
        type = "command"
        command = "echo mine"

        """, to: config)
        // Trust the user's hook the way Codex's /hooks review would.
        let before = try hooks(box, paths, codex: codex)
        let mine = try XCTUnwrap(before.first { $0["command"]?.stringValue == "echo mine" })
        let key = try XCTUnwrap(mine["key"]?.stringValue)
        XCTAssertTrue(key.hasSuffix(":pre_tool_use:2:0"))
        try box.write(CodexTrust.applyTrustedHashes([key: mine["currentHash"]!.stringValue!], to: try box.read(config)), to: config)

        _ = try CodexHookInstaller.install(paths: paths, cliPath: T.cli, dryRun: false)
        let after = try hooks(box, paths, codex: codex)
        let mineAfter = try XCTUnwrap(after.first { $0["command"]?.stringValue == "echo mine" })
        XCTAssertTrue(mineAfter["key"]?.stringValue?.hasSuffix(":pre_tool_use:1:0") ?? false)
        XCTAssertEqual(mineAfter["trustStatus"], .string("trusted"))
        XCTAssertEqual(after.filter { $0["trustStatus"]?.stringValue == "trusted" }.count, 12)

        _ = try CodexHookInstaller.uninstall(paths: paths, dryRun: false)
        let final = try hooks(box, paths, codex: codex)
        XCTAssertEqual(final.count, 1)
        XCTAssertEqual(final.first?["trustStatus"], .string("trusted"))
        XCTAssertTrue(final.first?["key"]?.stringValue?.hasSuffix(":pre_tool_use:0:0") ?? false)
    }
}
