import XCTest
@testable import SidePulseCore

final class HookInstallCodexTests: XCTestCase {
    typealias T = HookInstallTestData
    let cmd = HookInstallTestData.codexCommand
    let cfg = "/Users/tester/.codex/config.toml"

    var block: String { CodexHookInstaller.block(command: cmd) }

    // MARK: Block and fresh installs

    func testBlockLayout() {
        let lines = block.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "# >>> sidepulse hooks >>>")
        XCTAssertTrue(block.hasSuffix("\n# <<< sidepulse hooks <<<\n"))
        XCTAssertEqual(Array(lines[1...8]), [
            "[[hooks.SessionStart]]",
            "matcher = \"*\"",
            "[[hooks.SessionStart.hooks]]",
            "type = \"command\"",
            "command = '''\(cmd)'''",
            "timeout = 10",
            "",
            "[[hooks.UserPromptSubmit]]",
        ])
        let headers = lines.filter { $0.hasPrefix("[[hooks.") && !$0.hasSuffix(".hooks]]") }
        XCTAssertEqual(headers, HookProvider.codex.events.map { "[[hooks.\($0)]]" })
        XCTAssertEqual(T.count("timeout = 10", in: block), 11)
        XCTAssertEqual(lines.count, 1 + 11 * 7 + 1 + 1)
    }

    func testCommandQuotingFallsBackToBasicStrings() {
        XCTAssertEqual(TOMLString.literalPreferred("a b"), "'''a b'''")
        XCTAssertEqual(TOMLString.literalPreferred("'/x y/sp' hook-log"), "''''/x y/sp' hook-log'''")
        XCTAssertEqual(TOMLString.literalPreferred("x '''y"), #""x '''y""#)
        XCTAssertEqual(TOMLString.literalPreferred("ends'"), #""ends'""#)
        XCTAssertEqual(TOMLString.basic("a\\b\"c\u{01}"), #""a\\b\"c\u0001""#)
        for odd in ["/it's/sidepulse hook-log --provider codex ; true", "x '''y hook-log --provider codex ; true", "t'"] {
            let text = CodexHookInstaller.installing(into: "", command: odd)
            let doc = TOMLLines(text)
            let commands = CodexHookInstaller.hookGroups(in: doc).flatMap(\.commands)
            XCTAssertEqual(commands, Array(repeating: odd, count: 11), odd)
        }
    }

    func testFreshInstallExactText() {
        XCTAssertEqual(CodexHookInstaller.installing(into: "", command: cmd), block)
    }

    func testInstallAppendsAfterExactlyOneBlankLine() {
        XCTAssertEqual(CodexHookInstaller.installing(into: "model = \"x\"", command: cmd),
                       "model = \"x\"\n\n" + block)
        XCTAssertEqual(CodexHookInstaller.installing(into: "model = \"x\"\n\n\n\n[features]\nhooks = true\n\n\n", command: cmd),
                       "model = \"x\"\n\n\n\n[features]\nhooks = true\n\n" + block)
    }

    // MARK: [features]

    /// Codex enables hooks by default, so install leaves `[features]` exactly as it was.
    func testInstallLeavesFeaturesAlone() {
        for input in ["[features]\njs_repl = false\n", "[features]\nhooks = false\n", "features.js_repl = false\n",
                      "features = { js_repl = false }\n", "[features]\ncodex_hooks = false\n"] {
            XCTAssertEqual(CodexHookInstaller.installing(into: input, command: cmd), input + "\n" + block, input)
        }
    }

    /// Regression: rewriting it to `true` enabled the user's disabled hooks for good, since
    /// uninstall never restored it.
    func testExplicitHooksFalseIsLeftAlone() throws {
        let box = try HookInstallSandbox()
        let original = "[features]\nhooks = false # disabled for now\n\n[[hooks.Stop]]\nmatcher = \"*\"\n"
            + "[[hooks.Stop.hooks]]\ntype = \"command\"\ncommand = \"say done\"\n"
        try box.write(original, to: box.paths.codexConfigFile)
        let result = try CodexHookInstaller.install(paths: box.paths, cliPath: T.cli, dryRun: false, trust: true)
        let installed = try box.read(box.paths.codexConfigFile)
        XCTAssertTrue(installed.hasPrefix("[features]\nhooks = false # disabled for now\n"))
        XCTAssertEqual(CodexHookInstaller.installedEvents(in: installed), HookProvider.codex.events)
        XCTAssertTrue(result.notes.contains { $0.contains("turned off") && $0.contains("left that alone") }, "\(result.notes)")
        // Codex lists no hooks while they are off, so trust is not attempted.
        XCTAssertFalse(result.notes.contains { $0.contains("Codex not found") || $0.contains("trusted") }, "\(result.notes)")
        _ = try CodexHookInstaller.uninstall(paths: box.paths, dryRun: false)
        XCTAssertEqual(try box.read(box.paths.codexConfigFile), original.trimmingCharacters(in: .newlines) + "\n")
    }

    func testNoTrustInstallRemindsAboutApproval() throws {
        let box = try HookInstallSandbox()
        let result = try CodexHookInstaller.install(paths: box.paths, cliPath: T.cli, dryRun: false, trust: false)
        XCTAssertEqual(result.notes, ["hooks not marked trusted; approve them with /hooks in Codex"])
        let dry = try CodexHookInstaller.install(paths: box.paths, cliPath: T.cli, dryRun: true, trust: false)
        XCTAssertEqual(dry.notes, [])
    }

    /// Regression: a config without the key reported hooks as disabled, although Codex enables them by default.
    func testHooksFeatureEnabled() {
        XCTAssertTrue(CodexHookInstaller.hooksFeatureEnabled(in: ""))
        XCTAssertTrue(CodexHookInstaller.hooksFeatureEnabled(in: "[features]\nhooks = true\n"))
        XCTAssertTrue(CodexHookInstaller.hooksFeatureEnabled(in: "[features]\njs_repl = false\n\nhooks = true # x\n[a]\n"))
        XCTAssertFalse(CodexHookInstaller.hooksFeatureEnabled(in: "[features]\nhooks = false\n"))
        XCTAssertFalse(CodexHookInstaller.hooksFeatureEnabled(in: "[features]\n  hooks=false # off\n"))
        XCTAssertFalse(CodexHookInstaller.hooksFeatureEnabled(in: "features.hooks = false\n[tui]\n"))
        XCTAssertFalse(CodexHookInstaller.hooksFeatureEnabled(in: "[features]\ncodex_hooks = false\n"))
        XCTAssertTrue(CodexHookInstaller.hooksFeatureEnabled(in: "[features]\ncodex_hooks = false\nhooks = true\n"))
        // `hooks = false` in another table or inside a multi-line string is not the feature flag.
        XCTAssertTrue(CodexHookInstaller.hooksFeatureEnabled(in: "[features]\n[a]\nhooks = false\n"))
        XCTAssertTrue(CodexHookInstaller.hooksFeatureEnabled(in: "[profiles.x]\nhooks = false\n"))
        XCTAssertTrue(CodexHookInstaller.hooksFeatureEnabled(in: "[features]\nnote = \"\"\"\nhooks = false\n\"\"\"\n"))
        XCTAssertTrue(CodexHookInstaller.hooksFeatureEnabled(in: "prompt = '''\nfeatures.hooks = false\n'''\n"))
    }

    // MARK: Idempotency and placement

    func testReinstallIsByteIdentical() {
        let inputs = [
            "",
            "model = \"gpt-6\"\n",
            "model = \"gpt-6\"",
            "# only a comment",
            "[features]\njs_repl = false\n\n[mcp_servers.x]\nurl = \"u\"\n\n\n",
            HookInstallFixtures.pythonCodexConfigReinstalled,
            HookInstallFixtures.pythonCodexConfigTrusted.replacingOccurrences(of: "@CONFIG@", with: cfg),
            "[[hooks.Stop]]\nmatcher = \"*\"\n[[hooks.Stop.hooks]]\ntype = \"command\"\ncommand = \"say done\"\n",
            // Dropping stale trust tables after an in-place block must not leave a trailing blank line.
            "model = 1\n\n# >>> agent-monitor hooks >>>\n[[hooks.Stop]]\n[[hooks.Stop.hooks]]\ncommand = '''python3 /x/hook_entry.py --provider codex --log /l ; true'''\n\n# <<< agent-monitor hooks <<<\n\n[hooks.state]\n\n[hooks.state.\"\(cfg):stop:0:0\"]\ntrusted_hash = \"sha256:x\"\n",
        ]
        for input in inputs {
            for path in [nil, cfg] {
                let once = CodexHookInstaller.installing(into: input, command: cmd, configPath: path)
                let twice = CodexHookInstaller.installing(into: once, command: cmd, configPath: path)
                XCTAssertEqual(twice, once, input)
                XCTAssertEqual(CodexHookInstaller.installedEvents(in: once), HookProvider.codex.events)
                XCTAssertEqual(T.count("# >>> sidepulse hooks >>>", in: once), 1)
            }
        }
    }

    func testBlockStaysInPlaceWhenTablesFollowIt() {
        let installed = "model = \"x\"\n\n" + block + "\n# my servers\n[mcp_servers.a]\nurl = \"u\"\n"
        XCTAssertEqual(CodexHookInstaller.installing(into: "[features]\nhooks = true\n\n" + installed, command: cmd),
                       "[features]\nhooks = true\n\n" + installed)
        let top = block + "\n[features]\nhooks = true\n"
        XCTAssertEqual(CodexHookInstaller.installing(into: top, command: cmd), top)
    }

    /// Regression: a stray marker used as the insertion point pulled the keys after it into our
    /// last hook table, and uninstall deleted them.
    func testStrayMarkerNeverSplitsATable() {
        let inTable = "[tui]\na = 1\n# >>> sidepulse hooks >>>\nb = 2\n"
        let installed = CodexHookInstaller.installing(into: inTable, command: cmd, configPath: cfg)
        XCTAssertEqual(installed, "[tui]\na = 1\nb = 2\n\n" + block)
        XCTAssertEqual(CodexHookInstaller.uninstalling(from: installed, configPath: cfg), "[tui]\na = 1\nb = 2\n")

        let aboveRootKeys = "# >>> agent-monitor hooks >>>\nmodel = 1\n[tui]\nx = 1\n"
        let top = CodexHookInstaller.installing(into: aboveRootKeys, command: cmd, configPath: cfg)
        XCTAssertEqual(top, "model = 1\n[tui]\nx = 1\n\n" + block)
        XCTAssertTrue(CodexHookInstaller.uninstalling(from: top, configPath: cfg).hasPrefix("model = 1\n"))

        // At a table boundary the old position is still reused.
        let boundary = "[tui]\na = 1\n\n# >>> agent-monitor hooks >>>\n# a note\n\n[mcp_servers.x]\nurl = \"u\"\n"
        XCTAssertEqual(CodexHookInstaller.installing(into: boundary, command: cmd, configPath: cfg),
                       "[tui]\na = 1\n\n" + block + "\n# a note\n\n[mcp_servers.x]\nurl = \"u\"\n")
    }

    /// Regression: TOML cannot extend a hook event defined inline or as a plain table, so
    /// installing wrote a config Codex cannot load.
    func testStaticHookDefinitionsAreRefused() throws {
        let refused = [
            "[hooks]\nStop = [{ hooks = [{ type = \"command\", command = \"say\" }] }]\n",
            "hooks = {}\n",
            "hooks.PreToolUse = []\n",
            "[hooks.Stop]\nmatcher = \"*\"\n",
            "[hooks.Interrupt.extra]\nx = 1\n",
            "[hooks]\nstate = { x = 1 }\n",
            "hooks.state.\"k\".trusted_hash = \"x\"\n",
        ]
        for text in refused {
            XCTAssertNotNil(CodexHookInstaller.staticHookDefinitionProblem(in: TOMLLines(text)), text)
            let box = try HookInstallSandbox()
            try box.write(text, to: box.paths.codexConfigFile)
            XCTAssertThrowsError(try CodexHookInstaller.install(paths: box.paths, cliPath: T.cli, dryRun: false, trust: false), text) { error in
                guard case HookInstallError.invalidStructure(let path, _)? = error as? HookInstallError else { return XCTFail("\(error)") }
                XCTAssertEqual(path, box.paths.codexConfigFile.path)
            }
            XCTAssertEqual(try box.read(box.paths.codexConfigFile), text)
            XCTAssertEqual(box.backups(of: box.paths.codexConfigFile), [])
        }
        let allowed = [
            "",
            "[hooks]\nfoo = 1\n",
            "[hooks.state]\nsource = \"keep\"\n[hooks.state.\"k\"]\ntrusted_hash = \"x\"\n",
            "[[hooks.Stop]]\nhooks = [{ type = \"command\", command = \"say\" }]\n",
            "[[hooks.Custom]]\n[hooks.Custom.extra]\nx = 1\n",
            "[profiles.p]\nhooks = { Stop = [] }\n",
            HookInstallFixtures.pythonCodexConfigTrusted,
            CodexHookInstaller.installing(into: "", command: cmd),
        ]
        for text in allowed {
            XCTAssertNil(CodexHookInstaller.staticHookDefinitionProblem(in: TOMLLines(text)), text)
        }
    }

    /// Regression: TOML puts a key appended after the block into SidePulse's last table, where Codex ignored it and
    /// the next install or uninstall deleted it.
    func testKeysAppendedAfterTheBlockAreRefused() throws {
        for trusted in [false, true] {
            let box = try HookInstallSandbox()
            let config = box.paths.codexConfigFile
            try box.write("model = \"gpt-6\"\n", to: config)
            _ = try CodexHookInstaller.install(paths: box.paths, cliPath: T.cli, dryRun: false, trust: false)
            if trusted { try box.trustCodexHooks() }
            let table = trusted ? "[hooks.state.\"\u{2026}:interrupt:0:0\"]" : "[[hooks.Interrupt.hooks]]"
            let base = try box.read(config)
            XCTAssertTrue(base.hasSuffix(trusted ? "trusted_hash = \"sha256:test\"\n" : "\(CodexHookInstaller.managedEnd)\n"))
            for appended in ["approval_policy = \"never\"\n", "\n# mine\nmodel_reasoning_effort = \"high\" # x\n"] {
                let text = base + appended
                try box.write(text, to: config)
                let backups = box.backups(of: config)
                let key = appended.contains("approval") ? "approval_policy" : "model_reasoning_effort"
                let message = "TOML puts \(key) in SidePulse's \(table) table; move it above the SidePulse block"
                for action in [HookAction.install, .uninstall] {
                    for dryRun in [true, false] {
                        XCTAssertThrowsError(try HookInstaller.perform(action, provider: .codex, paths: box.paths, cliPath: T.cli,
                                                                       dryRun: dryRun, trust: false)) { error in
                            XCTAssertEqual(error as? HookInstallError, .invalidStructure(path: config.path, message: message))
                            XCTAssertEqual(String(describing: error), "\(config.path): \(message); fix it by hand, then retry")
                        }
                    }
                }
                XCTAssertEqual(try box.read(config), text)
                XCTAssertEqual(box.backups(of: config), backups)
                // Our last group also ends at the end marker, so even the pure transforms keep a key after it.
                if !trusted {
                    XCTAssertTrue(CodexHookInstaller.uninstalling(from: text, configPath: config.path).contains(key))
                    XCTAssertTrue(CodexHookInstaller.installing(into: text, command: cmd, configPath: config.path).contains(key))
                }
            }
        }
    }

    func testForeignContentInSidePulseTablesIsRefused() {
        let installed = CodexHookInstaller.installing(into: "model = 1\n", command: cmd)
        func problem(_ text: String) -> String? { CodexHookInstaller.managedTableProblem(in: TOMLLines(text), configPath: cfg) }
        let trust = "\n[hooks.state]\n\n[hooks.state.\"\(cfg):stop:0:0\"]\ntrusted_hash = \"sha256:x\"\nenabled = false\n"
            + "\n[hooks.state.\"\(cfg):stop:1:0\"]\ntrusted_hash = \"sha256:y\"\nnote = \"mine\"\n"
        let user = "\n[[hooks.Stop]]\nmatcher = \"*\"\nstatusMessage = \"x\"\n[[hooks.Stop.hooks]]\ntype = \"command\"\ncommand = \"say\"\n"
        for text in ["", installed, installed + user + trust, HookInstallFixtures.pythonCodexConfigTrusted,
                     HookInstallFixtures.pythonCodexConfigTrusted.replacingOccurrences(of: "@CONFIG@", with: cfg),
                     "[hooks.state.\"/elsewhere/config.toml:stop:0:0\"]\nx = 1\n"] {
            XCTAssertNil(problem(text), text)
        }
        XCTAssertEqual(problem(installed.replacingOccurrences(of: "[[hooks.Stop.hooks]]\n", with: "[[hooks.Stop.hooks]]\nasync = true\n")),
                       "TOML puts async in SidePulse's [[hooks.Stop.hooks]] table; move it above the SidePulse block")
        XCTAssertEqual(problem(installed + "[hooks.Interrupt.hooks.env]\nX = \"1\"\n"),
                       "TOML puts [hooks.Interrupt.hooks.env] in SidePulse's [[hooks.Interrupt.hooks]] table; "
                        + "move it above the SidePulse block")
        XCTAssertNotNil(problem("[[hooks.PreToolUse]]\n[[hooks.PreToolUse.hooks]]\ncommand = \"\(cmd)\"\n[hooks.PreToolUse.hooks.extra]\nx = 1\n"))
        // A trust table of a hook that no longer exists is dropped too.
        XCTAssertEqual(problem(installed + "\n[hooks.state.\"\(cfg):stop:5:0\"]\ntrusted_hash = \"x\"\n\"a.b\" = 1\n"),
                       "TOML puts \"a.b\" in SidePulse's [hooks.state.\"\u{2026}:stop:5:0\"] table; "
                        + "move it above the SidePulse block")
    }

    func testCommandChangeReplacesBlockInPlace() {
        let old = HookCommand.command(cliPath: "/old/sidepulse", provider: .codex)
        let before = "[features]\nhooks = true\n\n" + CodexHookInstaller.block(command: old) + "\n[tui]\nx = 1\n"
        XCTAssertEqual(CodexHookInstaller.installing(into: before, command: cmd),
                       "[features]\nhooks = true\n\n" + block + "\n[tui]\nx = 1\n")
    }

    /// Codex may append its own tables inside our markers when it rewrites the
    /// file; only the markers and our groups go.
    func testForeignTablesBetweenMarkersSurvive() {
        let text = "[features]\nhooks = true\n\n# >>> sidepulse hooks >>>\n[[hooks.Stop]]\nmatcher = \"*\"\n[[hooks.Stop.hooks]]\ntype = \"command\"\ncommand = '''\(cmd)'''\ntimeout = 10\n\n[hooks.state]\nsource = \"keep\"\n# <<< sidepulse hooks <<<\n"
        let removed = CodexHookInstaller.uninstalling(from: text, configPath: cfg)
        XCTAssertEqual(removed, "[features]\nhooks = true\n\n[hooks.state]\nsource = \"keep\"\n")
    }

    // MARK: Python vectors

    /// Port of test_codex_installer_replaces_monitor_hook_and_preserves_state, deliberately
    /// keeping the `echo old >> <log>` user hook that Python deleted by its log path.
    func testInstallPreservesStateAndUserHooks() {
        let input = [
            "[features]", "js_repl = false", "",
            "[[hooks.PreToolUse]]", "[[hooks.PreToolUse.hooks]]", "type = \"command\"",
            "command = '''echo old >> /Users/tester/.local/state/sidepulse/agent-monitor/codex.jsonl'''", "",
            "[hooks.state]", "source = \"keep-me\"", "",
        ].joined(separator: "\n")
        let text = CodexHookInstaller.installing(into: input, command: cmd, configPath: cfg)
        XCTAssertTrue(text.hasPrefix("[features]\njs_repl = false\n\n[[hooks.PreToolUse]]\n"))
        XCTAssertTrue(text.contains("[hooks.state]\nsource = \"keep-me\"\n"))
        XCTAssertTrue(text.contains("echo old >>"))
        XCTAssertTrue(text.contains("--provider codex"))
        XCTAssertTrue(text.components(separatedBy: "[[hooks.Interrupt.hooks]]")[1].contains("timeout = 10"))
        XCTAssertEqual(CodexHookInstaller.installedEvents(in: text), HookProvider.codex.events)
        let again = CodexHookInstaller.installing(into: text, command: cmd, configPath: cfg)
        XCTAssertEqual(T.count("[[hooks.Interrupt]]", in: again), 1)
        XCTAssertEqual(again, text)
    }

    func testUninstallPreservesConfig() {
        let input = "[features]\njs_repl = false\n\n[hooks.state]\nsource = \"keep-me\"\n"
        let installed = CodexHookInstaller.installing(into: input, command: cmd, configPath: cfg)
        let removed = CodexHookInstaller.uninstalling(from: installed, configPath: cfg)
        XCTAssertEqual(removed, input)
        XCTAssertFalse(removed.contains("sidepulse hooks"))
        XCTAssertFalse(removed.contains("hook-log"))
    }

    func testUninstallWithNothingToRemoveReturnsTextVerbatim() {
        for text in ["", "model = 1", "model = 1\n\n\n", "[features]\nhooks = true\n",
                     "[[hooks.Stop]]\n[[hooks.Stop.hooks]]\ncommand = \"say\"\n\n"] {
            XCTAssertEqual(CodexHookInstaller.uninstalling(from: text, configPath: cfg), text)
        }
    }

    func testUninstallOfFreshInstallLeavesNothing() {
        let installed = CodexHookInstaller.installing(into: "", command: cmd)
        XCTAssertEqual(CodexHookInstaller.uninstalling(from: installed, configPath: cfg), "")
    }

    // MARK: Legacy Python configs

    func testCleansPythonReinstalledConfig() {
        let python = HookInstallFixtures.pythonCodexConfigReinstalled
        XCTAssertEqual(HookInstallTestData.pythonEraCodexGroups(python), 11)
        XCTAssertEqual(CodexHookInstaller.installedEvents(in: python), [])
        let text = CodexHookInstaller.installing(into: python, command: cmd, configPath: cfg)
        XCTAssertEqual(text, """
        # Codex settings
        model = "gpt-6"

        [features]
        js_repl = false

        hooks = true
        [mcp_servers.svelte]
        url = "https://mcp.svelte.dev/mcp"

        """ + "\n" + block)
        XCTAssertEqual(HookInstallTestData.pythonEraCodexGroups(text), 0)
        XCTAssertEqual(CodexHookInstaller.uninstalling(from: python, configPath: cfg), """
        # Codex settings
        model = "gpt-6"

        [features]
        js_repl = false

        hooks = true
        [mcp_servers.svelte]
        url = "https://mcp.svelte.dev/mcp"

        """)
    }

    func testCleansPythonTrustedConfigAndItsStaleTrustState() {
        let python = HookInstallFixtures.pythonCodexConfigTrusted.replacingOccurrences(of: "@CONFIG@", with: cfg)
        XCTAssertEqual(T.count("trusted_hash", in: python), 11)
        let userGroup = "[[hooks.Stop]]\nmatcher = \"*\"\n[[hooks.Stop.hooks]]\ntype = \"command\"\ncommand = \"say done >> /tmp/user-notify.log\"\n"
        let prefix = "model = \"gpt-6\"\nnotify = [\"say\", \"turn-ended\"]\n\n[features]\njs_repl = false\n\nhooks = true\n"
            + userGroup + "\n[mcp_servers.svelte]\nurl = \"https://mcp.svelte.dev/mcp\"\n"

        let installed = CodexHookInstaller.installing(into: python, command: cmd, configPath: cfg)
        XCTAssertEqual(installed, prefix + "\n" + block)
        let removed = CodexHookInstaller.uninstalling(from: python, configPath: cfg)
        XCTAssertEqual(removed, prefix)
        // Trust tables keyed by another config path are not touched.
        XCTAssertEqual(T.count("trusted_hash", in: CodexHookInstaller.uninstalling(from: python, configPath: "/elsewhere/config.toml")), 11)
    }

    func testLegacyEventLoggingCommentRemovedOnlyWithOurBlocks() {
        let legacy = "# Event logging hooks: codex\n[[hooks.Stop]]\n[[hooks.Stop.hooks]]\ncommand = '''python3 /x/hook_entry.py --provider codex --log /l ; true'''\n"
        XCTAssertEqual(CodexHookInstaller.uninstalling(from: legacy, configPath: cfg), "")
        let alone = "# Event logging hooks: my own note\nmodel = 1\n"
        XCTAssertEqual(CodexHookInstaller.uninstalling(from: alone, configPath: cfg), alone)
    }

    func testRemovalKeepsCommentsIntroducingTheNextTable() {
        let text = "[[hooks.Stop]]\n[[hooks.Stop.hooks]]\ncommand = '''\(cmd)'''\ntimeout = 10\n\n# My MCP servers\n[mcp_servers.a]\nurl = \"u\"\n"
        XCTAssertEqual(CodexHookInstaller.uninstalling(from: text, configPath: cfg), "# My MCP servers\n[mcp_servers.a]\nurl = \"u\"\n")
    }

    func testWholeGroupIsRemovedIncludingNestedTables() {
        let text = "[[hooks.PreToolUse]]\nmatcher = \"*\"\n[[hooks.PreToolUse.hooks]]\ncommand = \"\(cmd)\"\n[hooks.PreToolUse.hooks.extra]\nx = 1\n[[hooks.PreToolUse]]\nmatcher = \"Bash\"\n[[hooks.PreToolUse.hooks]]\ncommand = \"say\"\n"
        XCTAssertEqual(CodexHookInstaller.uninstalling(from: text, configPath: cfg),
                       "[[hooks.PreToolUse]]\nmatcher = \"Bash\"\n[[hooks.PreToolUse.hooks]]\ncommand = \"say\"\n")
    }

    // MARK: Trust state bookkeeping

    func testUserTrustFollowsGroupIndexShifts() {
        // The block replaces two legacy groups in place, so the user's group moves from index 2 to 1.
        let legacy = "python3 /x/hook_entry.py --provider codex --log /l ; true"
        let input = """
        [[hooks.PreToolUse]]
        matcher = "*"
        [[hooks.PreToolUse.hooks]]
        command = '''\(legacy)'''

        [[hooks.PreToolUse]]
        [[hooks.PreToolUse.hooks]]
        command = '''\(legacy)'''

        [[hooks.PreToolUse]]
        matcher = "Bash"
        [[hooks.PreToolUse.hooks]]
        command = "echo one"
        [[hooks.PreToolUse.hooks]]
        command = "echo two"

        [hooks.state]

        [hooks.state."\(cfg):pre_tool_use:0:0"]
        trusted_hash = "sha256:legacy"

        [hooks.state."\(cfg):pre_tool_use:1:0"]
        trusted_hash = "sha256:legacy2"

        [hooks.state."\(cfg):pre_tool_use:2:0"]
        trusted_hash = "sha256:one"

        [hooks.state."\(cfg):pre_tool_use:2:1"]
        trusted_hash = "sha256:two"

        [hooks.state."/Users/tester/project/.codex/config.toml:pre_tool_use:0:0"]
        trusted_hash = "sha256:project"

        """
        let installed = CodexHookInstaller.installing(into: input, command: cmd, configPath: cfg)
        XCTAssertTrue(installed.hasPrefix(CodexHookInstaller.managedStart))
        XCTAssertFalse(installed.contains("sha256:legacy"))
        XCTAssertTrue(installed.contains("[hooks.state.\"\(cfg):pre_tool_use:1:0\"]\ntrusted_hash = \"sha256:one\""))
        XCTAssertTrue(installed.contains("[hooks.state.\"\(cfg):pre_tool_use:1:1\"]\ntrusted_hash = \"sha256:two\""))
        XCTAssertFalse(installed.contains("pre_tool_use:2:"))
        XCTAssertFalse(installed.contains("\(cfg):pre_tool_use:0:0"), "the stale legacy hash is not carried over to our hook")
        XCTAssertTrue(installed.contains("sha256:project"), "other config layers are left alone")

        let trusted = CodexTrust.applyTrustedHashes(["\(cfg):pre_tool_use:0:0": "sha256:ours"], to: installed)
        XCTAssertEqual(CodexHookInstaller.installing(into: trusted, command: cmd, configPath: cfg), trusted)
        // Uninstall: the user's group becomes index 0 again.
        let removed = CodexHookInstaller.uninstalling(from: trusted, configPath: cfg)
        XCTAssertFalse(removed.contains("sha256:ours"))
        XCTAssertTrue(removed.contains("[hooks.state.\"\(cfg):pre_tool_use:0:0\"]\ntrusted_hash = \"sha256:one\""))
        XCTAssertTrue(removed.contains("[hooks.state.\"\(cfg):pre_tool_use:0:1\"]\ntrusted_hash = \"sha256:two\""))
        XCTAssertTrue(removed.contains("sha256:project"))
        XCTAssertTrue(removed.hasPrefix("[[hooks.PreToolUse]]\nmatcher = \"Bash\""))
    }

    func testUninstallShiftsUserGroupDownWhenOurGroupCameFirst() {
        let input = """
        [[hooks.Stop]]
        matcher = "*"
        [[hooks.Stop.hooks]]
        type = "command"
        command = '''\(cmd)'''
        timeout = 10

        [[hooks.Stop]]
        [[hooks.Stop.hooks]]
        command = "say done"

        [hooks.state."\(cfg):stop:0:0"]
        trusted_hash = "sha256:ours"

        [hooks.state."\(cfg):stop:1:0"]
        trusted_hash = "sha256:user"

        """
        XCTAssertEqual(CodexHookInstaller.uninstalling(from: input, configPath: cfg), """
        [[hooks.Stop]]
        [[hooks.Stop.hooks]]
        command = "say done"

        [hooks.state."\(cfg):stop:0:0"]
        trusted_hash = "sha256:user"

        """)
    }

    func testOrphanTrustTablesAreDroppedWithEmptyStateTable() {
        let input = "model = 1\n\n# Provider-neutral status collection. Do not edit inside this block.\n[hooks.state]\n\n[hooks.state.\"\(cfg):stop:0:0\"]\ntrusted_hash = \"sha256:a\"\n\n[hooks.state.\"\(cfg):interrupt:0:0\"]\ntrusted_hash = \"sha256:b\"\n\n# Provider-neutral status collection. Do not edit inside this block.\n"
        XCTAssertEqual(CodexHookInstaller.uninstalling(from: input, configPath: cfg), "model = 1\n")
        let keep = "[hooks.state]\nsource = \"keep\"\n\n[hooks.state.\"\(cfg):stop:0:0\"]\ntrusted_hash = \"sha256:a\"\n"
        XCTAssertEqual(CodexHookInstaller.uninstalling(from: keep, configPath: cfg), "[hooks.state]\nsource = \"keep\"\n")
    }

    func testTrustKeysMatchResolvedConfigPath() throws {
        let box = try HookInstallSandbox()
        let config = box.paths.codexConfigFile
        try box.write("", to: config)
        let resolved = CodexTrust.canonicalPath(config.path)
        let input = "[hooks.state.\"\(resolved):stop:0:0\"]\ntrusted_hash = \"x\"\n"
        XCTAssertEqual(CodexHookInstaller.uninstalling(from: input, configPath: config.path), "")
    }

    func testUnrecognizedHookSyntaxLeavesTrustStateAlone() {
        let inline = "[hooks]\nPreToolUse = [{ hooks = [{ type = \"command\", command = \"say\" }] }]\n\n[hooks.state.\"\(cfg):pre_tool_use:0:0\"]\ntrusted_hash = \"sha256:a\"\n"
        XCTAssertEqual(CodexHookInstaller.uninstalling(from: inline, configPath: cfg), inline)
        let installed = CodexHookInstaller.installing(into: inline, command: cmd, configPath: cfg)
        XCTAssertTrue(installed.contains("sha256:a"))
        let dotted = "hooks.Stop = []\n[hooks.state.\"\(cfg):stop:0:0\"]\ntrusted_hash = \"sha256:a\"\n"
        XCTAssertEqual(CodexHookInstaller.uninstalling(from: dotted, configPath: cfg), dotted)
    }

    /// Regression: one group with inline `hooks = [...]` turned off all trust bookkeeping, so uninstall left
    /// SidePulse's trust tables behind and the user's group kept a key that no longer named it.
    func testInlineUserGroupKeepsTrustInStep() {
        let installed = CodexHookInstaller.installing(into: "model = \"gpt-6\"\n", command: cmd)
        var input = installed + """

        [[hooks.Stop]]
        matcher = "*"
        hooks = [
          { type = "command", command = "say one" },
          { type = "command", command = "say two" },
        ]

        [hooks.state]

        """
        let ours = HookProvider.codex.events.map(CodexHookInstaller.snakeCase)
        for event in ours { input += "\n[hooks.state.\"\(cfg):\(event):0:0\"]\ntrusted_hash = \"sha256:ours\"\n" }
        input += "\n[hooks.state.\"\(cfg):stop:1:0\"]\ntrusted_hash = \"sha256:one\"\n"
        input += "\n[hooks.state.\"\(cfg):stop:1:1\"]\ntrusted_hash = \"sha256:two\"\nenabled = false\n"

        XCTAssertEqual(CodexHookInstaller.installing(into: input, command: cmd, configPath: cfg), input)
        let removed = CodexHookInstaller.uninstalling(from: input, configPath: cfg)
        XCTAssertFalse(removed.contains("sha256:ours"), removed)
        XCTAssertTrue(removed.hasSuffix("""
        [hooks.state]

        [hooks.state."\(cfg):stop:0:0"]
        trusted_hash = "sha256:one"

        [hooks.state."\(cfg):stop:0:1"]
        trusted_hash = "sha256:two"
        enabled = false

        """), removed)
        let reinstalled = CodexHookInstaller.installing(into: removed, command: cmd, configPath: cfg)
        XCTAssertEqual(CodexHookInstaller.installing(into: reinstalled, command: cmd, configPath: cfg), reinstalled)
        XCTAssertTrue(reinstalled.contains("[hooks.state.\"\(cfg):stop:0:1\"]\ntrusted_hash = \"sha256:two\""),
                      "the block goes after the user's group, so its keys stay")
    }

    /// Codex's /hooks marks a hook `enabled = false`; install must not turn it back on when our command changes.
    func testHookTurnedOffStaysOffWhenOurCommandChanges() {
        let old = HookCommand.command(cliPath: "/old/sidepulse", provider: .codex)
        let input = CodexHookInstaller.block(command: old) + """

        [hooks.state]

        [hooks.state."\(cfg):stop:0:0"]
        trusted_hash = "sha256:old-stop"
        enabled = false

        [hooks.state."\(cfg):interrupt:0:0"]
        trusted_hash = "sha256:old-interrupt"

        """
        XCTAssertEqual(CodexHookInstaller.installing(into: input, command: cmd, configPath: cfg), block + """

        [hooks.state]

        [hooks.state."\(cfg):stop:0:0"]
        enabled = false

        """)
        XCTAssertEqual(CodexHookInstaller.uninstalling(from: input, configPath: cfg), "")
    }

    // MARK: Detection

    func testInstalledEventsAndLegacyBlocks() {
        let partial = "[[hooks.Stop]]\n[[hooks.Stop.hooks]]\ncommand = \"\(cmd)\"\n[[hooks.PreToolUse]]\n[[hooks.PreToolUse.hooks]]\ncommand = '''python3 /x/hook_entry.py --provider codex --log /l ; true'''\n[[hooks.Custom]]\n[[hooks.Custom.hooks]]\ncommand = '''\(cmd)'''\n"
        XCTAssertEqual(CodexHookInstaller.installedEvents(in: partial), ["Stop", "Custom"])
        XCTAssertEqual(HookInstallTestData.pythonEraCodexGroups(partial), 1)
        XCTAssertEqual(CodexHookInstaller.installedEvents(in: ""), [])
    }

    // MARK: TOML scanner

    func testScannerIgnoresLookalikesInsideMultilineValues() {
        let text = """
        prompt = '''
        [[hooks.Stop]]
        # >>> sidepulse hooks >>>
        command = '''
        notes = \"\"\"
        [not.a.table]
        \\\"\"\" still inside
        \"\"\"
        matrix = [
          [1, 2],
          [3, 4]
        ]
        [projects ]
        "/a" = { trust_level = "trusted" }
        [ hooks . "state" . "q\\"k" ] # comment
        """
        let doc = TOMLLines(text)
        let headers = doc.kinds.compactMap { kind -> [String]? in
            if case .header(let path, _) = kind { return path }
            return nil
        }
        XCTAssertEqual(headers, [["projects"], ["hooks", "state", "q\"k"]])
        XCTAssertEqual(doc.kinds.filter { $0 == .comment }.count, 0)
        XCTAssertEqual(CodexHookInstaller.uninstalling(from: text + "\n", configPath: cfg), text + "\n")
        XCTAssertEqual(CodexHookInstaller.installedEvents(in: text), [])
    }

    func testScannerDecodesAllStringForms() {
        let doc = TOMLLines("""
        command = "a \\"b\\" \\\\ \\u00e9"
        command = 'c:\\d'
        command = '''e 'f' '''
        command = \"\"\"
        g \\
          h\"\"\"
        command = '''''i'''''
        other = "x"
        """)
        let values = doc.lines.indices.compactMap { doc.stringValue(at: $0, key: "command") }
        XCTAssertEqual(values, ["a \"b\" \\ \u{E9}", "c:\\d", "e 'f' ", "g h", "''i''"])
    }
}
