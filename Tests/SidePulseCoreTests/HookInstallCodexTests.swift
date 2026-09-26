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
        XCTAssertEqual(CodexHookInstaller.installing(into: "", command: cmd), "[features]\nhooks = true\n\n" + block)
    }

    func testInstallAppendsAfterExactlyOneBlankLine() {
        XCTAssertEqual(CodexHookInstaller.installing(into: "model = \"x\"", command: cmd),
                       "model = \"x\"\n\n[features]\nhooks = true\n\n" + block)
        XCTAssertEqual(CodexHookInstaller.installing(into: "model = \"x\"\n\n\n\n[features]\nhooks = true\n\n\n", command: cmd),
                       "model = \"x\"\n\n\n\n[features]\nhooks = true\n\n" + block)
    }

    // MARK: [features] hooks = true

    func testFeatureFlagVariants() {
        func features(_ input: String) -> String {
            let out = CodexHookInstaller.installing(into: input, command: cmd)
            return String(out[..<(out.range(of: CodexHookInstaller.managedStart)?.lowerBound ?? out.endIndex)])
        }
        XCTAssertEqual(features("[features]\njs_repl = false\n\n[tui]\nx = 1\n"),
                       "[features]\njs_repl = false\nhooks = true\n\n[tui]\nx = 1\n\n")
        // An explicit `false` is the user's choice (see testExplicitHooksFalseIsLeftAlone).
        XCTAssertEqual(features("[features]\nhooks = false\n"), "[features]\nhooks = false\n\n")
        XCTAssertEqual(features("[features]\n  hooks=false # off\n"), "[features]\n  hooks=false # off\n\n")
        XCTAssertEqual(features("[features]\n  hooks = 1\n"), "[features]\n  hooks = true\n\n")
        XCTAssertEqual(features("[features]\nhooks = true # keep my comment\n"), "[features]\nhooks = true # keep my comment\n\n")
        XCTAssertEqual(features("[features] # flags\n"), "[features] # flags\nhooks = true\n\n")
        XCTAssertEqual(features("features.hooks = false\n[tui]\n"), "features.hooks = false\n[tui]\n\n")
        // An inline table cannot be extended safely; it is left alone.
        XCTAssertEqual(features("features = { js_repl = false }\n"), "features = { js_repl = false }\n\n")
        // `hooks = …` in another table is not the feature flag.
        XCTAssertEqual(features("[profiles.x]\nhooks = false\n"), "[profiles.x]\nhooks = false\n\n[features]\nhooks = true\n\n")
    }

    /// Regression: root dotted keys already define [features]; appending a
    /// `[features]` header made the file invalid TOML ("Cannot declare
    /// ('features',) twice"), so Codex could not load its config at all.
    func testRootDottedFeaturesGetASiblingKey() {
        let input = "model = 1\nfeatures.js_repl = false\n\n[tui]\nx = 1\n"
        let installed = CodexHookInstaller.installing(into: input, command: cmd)
        XCTAssertEqual(installed, "model = 1\nfeatures.hooks = true\nfeatures.js_repl = false\n\n[tui]\nx = 1\n\n" + block)
        XCTAssertFalse(installed.contains("[features]"))
        XCTAssertTrue(CodexHookInstaller.hooksFeatureEnabled(in: installed))
        XCTAssertEqual(CodexHookInstaller.installing(into: installed, command: cmd), installed)
        XCTAssertEqual(CodexHookInstaller.uninstalling(from: installed, configPath: cfg),
                       "model = 1\nfeatures.hooks = true\nfeatures.js_repl = false\n\n[tui]\nx = 1\n")
    }

    /// Regression: lines inside a multi-line value are not keys, so a
    /// `hooks = false` line inside a string is neither the flag nor rewritten.
    func testLinesInsideMultilineValuesAreNotKeys() {
        let input = "[features]\nnote = \"\"\"\nhooks = false\n\"\"\"\n"
        XCTAssertFalse(CodexHookInstaller.hooksFeatureEnabled(in: input))
        XCTAssertEqual(CodexHookInstaller.installing(into: input, command: cmd),
                       "[features]\nnote = \"\"\"\nhooks = false\n\"\"\"\nhooks = true\n\n" + block)
        let rootString = "prompt = '''\nfeatures.hooks = false\n'''\n"
        XCTAssertEqual(CodexHookInstaller.installing(into: rootString, command: cmd),
                       rootString + "\n[features]\nhooks = true\n\n" + block)
    }

    /// Regression: install rewrote `hooks = false # disabled for now` to `hooks = true`
    /// (dropping the comment and enabling the user's own disabled hooks for good,
    /// since uninstall never restored it).
    func testExplicitHooksFalseIsLeftAlone() throws {
        let box = try HookInstallSandbox()
        let original = "[features]\nhooks = false # disabled for now\n\n[[hooks.Stop]]\nmatcher = \"*\"\n"
            + "[[hooks.Stop.hooks]]\ntype = \"command\"\ncommand = \"say done\"\n"
        try box.write(original, to: box.paths.codexConfigFile)
        let result = try CodexHookInstaller.install(paths: box.paths, cliPath: T.cli, dryRun: false, trust: true)
        let installed = try box.read(box.paths.codexConfigFile)
        XCTAssertTrue(installed.hasPrefix("[features]\nhooks = false # disabled for now\n"))
        XCTAssertEqual(CodexHookInstaller.installedEvents(in: installed), HookProvider.codex.events)
        XCTAssertTrue(result.notes.contains { $0.contains("hooks = false") && $0.contains("left that alone") }, "\(result.notes)")
        // Codex lists no hooks while they are off, so trust is not attempted.
        XCTAssertFalse(result.notes.contains { $0.contains("Codex not found") || $0.contains("trusted") }, "\(result.notes)")
        _ = try CodexHookInstaller.uninstall(paths: box.paths, dryRun: false)
        XCTAssertEqual(try box.read(box.paths.codexConfigFile), original.trimmingCharacters(in: .newlines) + "\n")
    }

    /// `--no-trust` leaves the hooks untrusted; say how to approve them.
    func testNoTrustInstallRemindsAboutApproval() throws {
        let box = try HookInstallSandbox()
        let result = try CodexHookInstaller.install(paths: box.paths, cliPath: T.cli, dryRun: false, trust: false)
        XCTAssertEqual(result.notes, ["hooks not marked trusted; approve them with /hooks in Codex"])
        let dry = try CodexHookInstaller.install(paths: box.paths, cliPath: T.cli, dryRun: true, trust: false)
        XCTAssertEqual(dry.notes, [])
    }

    func testHooksFeatureEnabled() {
        XCTAssertTrue(CodexHookInstaller.hooksFeatureEnabled(in: "[features]\nhooks = true\n"))
        XCTAssertTrue(CodexHookInstaller.hooksFeatureEnabled(in: "[features]\njs_repl = false\n\nhooks = true # x\n[a]\n"))
        XCTAssertTrue(CodexHookInstaller.hooksFeatureEnabled(in: "features.hooks = true\n"))
        XCTAssertFalse(CodexHookInstaller.hooksFeatureEnabled(in: "[features]\nhooks = false\n"))
        XCTAssertFalse(CodexHookInstaller.hooksFeatureEnabled(in: "[features]\n[a]\nhooks = true\n"))
        XCTAssertFalse(CodexHookInstaller.hooksFeatureEnabled(in: ""))
        XCTAssertFalse(CodexHookInstaller.hooksFeatureEnabled(in: "x = \"\"\"\n[features]\nhooks = true\n\"\"\"\n"))
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
            // Legacy block followed by stale trust tables that get dropped: the
            // block lands in place and must not leave a trailing blank line.
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
        // At the very top of the file.
        let top = block + "\n[features]\nhooks = true\n"
        XCTAssertEqual(CodexHookInstaller.installing(into: top, command: cmd), top)
    }

    /// Regression: a stray marker in the middle of a table (or above root keys)
    /// used to become the insertion point, so the keys after it ended up inside
    /// our last hook table, and uninstall then deleted them with that table.
    func testStrayMarkerNeverSplitsATable() {
        let features = "\n[features]\nhooks = true\n"
        let inTable = "[tui]\na = 1\n# >>> sidepulse hooks >>>\nb = 2\n"
        let installed = CodexHookInstaller.installing(into: inTable, command: cmd, configPath: cfg)
        XCTAssertEqual(installed, "[tui]\na = 1\nb = 2\n" + features + "\n" + block)
        XCTAssertEqual(CodexHookInstaller.uninstalling(from: installed, configPath: cfg), "[tui]\na = 1\nb = 2\n" + features)

        let aboveRootKeys = "# >>> agent-monitor hooks >>>\nmodel = 1\n[tui]\nx = 1\n"
        let top = CodexHookInstaller.installing(into: aboveRootKeys, command: cmd, configPath: cfg)
        XCTAssertEqual(top, "model = 1\n[tui]\nx = 1\n" + features + "\n" + block)
        XCTAssertTrue(CodexHookInstaller.uninstalling(from: top, configPath: cfg).hasPrefix("model = 1\n"))

        // At a table boundary the old position is still reused.
        let boundary = "[tui]\na = 1\n\n# >>> agent-monitor hooks >>>\n# a note\n\n[mcp_servers.x]\nurl = \"u\"\n"
        XCTAssertEqual(CodexHookInstaller.installing(into: boundary, command: cmd, configPath: cfg),
                       "[tui]\na = 1\n\n" + block + "\n# a note\n\n[mcp_servers.x]\nurl = \"u\"\n" + features)
    }

    /// Regression: TOML cannot extend a hook event (or hooks.state) that is
    /// defined inline or as a plain table, so install refuses such a file
    /// instead of writing a config Codex cannot load.
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

    /// Port of test_codex_installer_replaces_monitor_hook_and_preserves_state. The
    /// Python installer deleted `echo old >> <log>` because it matched the log
    /// path; the Swift installer keeps user hooks.
    func testInstallPreservesStateAndUserHooks() {
        let input = [
            "[features]", "js_repl = false", "",
            "[[hooks.PreToolUse]]", "[[hooks.PreToolUse.hooks]]", "type = \"command\"",
            "command = '''echo old >> /Users/tester/.local/state/sidepulse/agent-monitor/codex.jsonl'''", "",
            "[hooks.state]", "source = \"keep-me\"", "",
        ].joined(separator: "\n")
        let text = CodexHookInstaller.installing(into: input, command: cmd, configPath: cfg)
        XCTAssertTrue(text.contains("[features]\njs_repl = false\nhooks = true\n"))
        XCTAssertTrue(text.contains("[hooks.state]\nsource = \"keep-me\"\n"))
        XCTAssertTrue(text.contains("echo old >>"))
        XCTAssertTrue(text.contains("--provider codex"))
        XCTAssertTrue(text.components(separatedBy: "[[hooks.Interrupt.hooks]]")[1].contains("timeout = 10"))
        XCTAssertEqual(CodexHookInstaller.installedEvents(in: text), HookProvider.codex.events)
        let again = CodexHookInstaller.installing(into: text, command: cmd, configPath: cfg)
        XCTAssertEqual(T.count("[[hooks.Interrupt]]", in: again), 1)
        XCTAssertEqual(again, text)
    }

    /// Port of test_codex_uninstaller_removes_monitor_hooks_and_preserves_config.
    func testUninstallPreservesConfig() {
        let input = "[features]\njs_repl = false\n\n[hooks.state]\nsource = \"keep-me\"\n"
        let installed = CodexHookInstaller.installing(into: input, command: cmd, configPath: cfg)
        let removed = CodexHookInstaller.uninstalling(from: installed, configPath: cfg)
        XCTAssertEqual(removed, "[features]\njs_repl = false\nhooks = true\n\n[hooks.state]\nsource = \"keep-me\"\n")
        XCTAssertFalse(removed.contains("sidepulse hooks"))
        XCTAssertFalse(removed.contains("hook-log"))
    }

    func testUninstallWithNothingToRemoveReturnsTextVerbatim() {
        for text in ["", "model = 1", "model = 1\n\n\n", "[features]\nhooks = true\n",
                     "[[hooks.Stop]]\n[[hooks.Stop.hooks]]\ncommand = \"say\"\n\n"] {
            XCTAssertEqual(CodexHookInstaller.uninstalling(from: text, configPath: cfg), text)
        }
    }

    func testUninstallOfFreshInstallLeavesOnlyFeatures() {
        let installed = CodexHookInstaller.installing(into: "", command: cmd)
        XCTAssertEqual(CodexHookInstaller.uninstalling(from: installed, configPath: cfg), "[features]\nhooks = true\n")
    }

    // MARK: Legacy Python configs

    func testCleansPythonReinstalledConfig() {
        let python = HookInstallFixtures.pythonCodexConfigReinstalled
        XCTAssertEqual(CodexHookInstaller.legacyBlockCount(in: python), 11)
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
        XCTAssertEqual(CodexHookInstaller.legacyBlockCount(in: text), 0)
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
        // Without a config path the trust tables are not touched.
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
        // Two legacy groups (a duplicate left by a hand edit) precede the user's
        // group. The new block replaces them in place, so the user's group moves
        // from index 2 to 1 and its trust entries must follow.
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

        // Trust ours (group 0) and reinstall: nothing moves.
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
        // A [hooks.state] table with its own keys stays.
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

    // MARK: Detection

    func testInstalledEventsAndLegacyBlocks() {
        let partial = "[[hooks.Stop]]\n[[hooks.Stop.hooks]]\ncommand = \"\(cmd)\"\n[[hooks.PreToolUse]]\n[[hooks.PreToolUse.hooks]]\ncommand = '''python3 /x/hook_entry.py --provider codex --log /l ; true'''\n[[hooks.Custom]]\n[[hooks.Custom.hooks]]\ncommand = '''\(cmd)'''\n"
        XCTAssertEqual(CodexHookInstaller.installedEvents(in: partial), ["Stop", "Custom"])
        XCTAssertEqual(CodexHookInstaller.legacyBlockCount(in: partial), 1)
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
