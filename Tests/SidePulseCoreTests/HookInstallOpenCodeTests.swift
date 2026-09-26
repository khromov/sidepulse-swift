import Foundation
import XCTest
@testable import SidePulseCore

final class HookInstallOpenCodeTests: XCTestCase {
    typealias T = HookInstallTestData

    func testConfigDirFollowsOpenCodesOwnLookup() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        func dir(_ environment: [String: String]) -> String {
            SidePulsePaths(environment: environment, home: home).openCodeConfigDir.path
        }
        XCTAssertEqual(dir([:]), "/Users/tester/.config/opencode")
        XCTAssertEqual(dir(["XDG_CONFIG_HOME": "/x/config"]), "/x/config/opencode")
        XCTAssertEqual(dir(["XDG_CONFIG_HOME": "", "OPENCODE_CONFIG_DIR": ""]), "/Users/tester/.config/opencode")
        XCTAssertEqual(dir(["XDG_CONFIG_HOME": "/x/config", "OPENCODE_CONFIG_DIR": "/y/oc"]), "/y/oc")
        XCTAssertEqual(SidePulsePaths(environment: ["OPENCODE_CONFIG_DIR": "/y/oc/"], home: home).openCodePluginFile.path,
                       "/y/oc/plugins/sidepulse.js")
    }

    func testInstallWritesThePluginWithTheCLIAsAJavaScriptString() throws {
        let box = try HookInstallSandbox()
        let cli = "/Users/o'brien \"q\"/back\\slash/\u{E9}\u{2028}/sidepulse"
        let result = try OpenCodePluginInstaller.install(paths: box.paths, cliPath: cli, dryRun: false)
        XCTAssertTrue(result.changed)
        XCTAssertNil(result.backupPath)
        XCTAssertEqual(result.notes, [])
        XCTAssertEqual(result.configPath, box.paths.openCodePluginFile)
        let text = try box.read(box.paths.openCodePluginFile)
        XCTAssertEqual(text, OpenCodePluginInstaller.source(cliPath: cli))
        XCTAssertTrue(text.hasPrefix("// Managed by SidePulse: `sidepulse install opencode` rewrites this file"))
        XCTAssertTrue(text.contains("\n// sidepulse hook-log --provider opencode\n"))
        XCTAssertTrue(text.contains(#"const CLI = "/Users/o'brien \"q\"/back\\slash/\#u{E9}\u2028/sidepulse""#), text)
        XCTAssertTrue(text.contains(#"spawn(CLI, ["hook-log", "--provider", "opencode"]"#))
        XCTAssertEqual(OpenCodePluginInstaller.cliPath(in: text), cli)
        XCTAssertTrue(OpenCodePluginInstaller.isSidePulsePlugin(text))
        XCTAssertEqual(OpenCodePluginInstaller.installedEvents(in: text), HookProvider.opencode.events)
        XCTAssertFalse(text.contains("console."), "the plugin never writes to stdout")
    }

    func testReinstallIsIdempotentAndACLIChangeBacksUpOurOldFile() throws {
        let box = try HookInstallSandbox()
        let file = box.paths.openCodePluginFile
        _ = try OpenCodePluginInstaller.install(paths: box.paths, cliPath: T.cli, dryRun: false)
        let again = try OpenCodePluginInstaller.install(paths: box.paths, cliPath: T.cli, dryRun: false)
        XCTAssertFalse(again.changed)
        XCTAssertNil(again.backupPath)
        XCTAssertEqual(box.backups(of: file), [])

        let moved = "/Applications/SidePulse.app/Contents/Helpers/sidepulse"
        XCTAssertTrue(try OpenCodePluginInstaller.install(paths: box.paths, cliPath: moved, dryRun: true).changed)
        XCTAssertEqual(OpenCodePluginInstaller.cliPath(in: try box.read(file)), T.cli, "a dry run writes nothing")
        let changed = try OpenCodePluginInstaller.install(paths: box.paths, cliPath: moved, dryRun: false)
        XCTAssertTrue(changed.changed)
        XCTAssertEqual(box.backups(of: file), [try XCTUnwrap(changed.backupPath)])
        XCTAssertEqual(OpenCodePluginInstaller.cliPath(in: try box.read(try XCTUnwrap(changed.backupPath))), T.cli)
        XCTAssertEqual(OpenCodePluginInstaller.cliPath(in: try box.read(file)), moved)
    }

    func testUninstallDeletesOnlyOurPlugin() throws {
        let box = try HookInstallSandbox()
        let file = box.paths.openCodePluginFile
        XCTAssertFalse(try OpenCodePluginInstaller.uninstall(paths: box.paths, dryRun: false).changed)
        _ = try OpenCodePluginInstaller.install(paths: box.paths, cliPath: T.cli, dryRun: false)
        XCTAssertTrue(try OpenCodePluginInstaller.uninstall(paths: box.paths, dryRun: true).changed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "a dry run deletes nothing")
        let removed = try HookInstaller.perform(.uninstall, provider: .opencode, paths: box.paths, cliPath: nil)
        XCTAssertTrue(removed.changed)
        XCTAssertNil(removed.backupPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(try OpenCodePluginInstaller.uninstall(paths: box.paths, dryRun: false).changed)
    }

    func testAForeignPluginWithOurNameIsNeverTouched() throws {
        let box = try HookInstallSandbox()
        let file = box.paths.openCodePluginFile
        let foreign = "// sidepulse hook-log --provider opencode, but with my own changes\nexport default { id: \"mine\" }\n"
        try box.write(foreign, to: file)
        XCTAssertThrowsError(try HookInstaller.perform(.install, provider: .opencode, paths: box.paths, cliPath: T.cli)) { error in
            XCTAssertEqual(error as? HookInstallError, .notOurs(path: file.path))
            XCTAssertEqual(String(describing: error), "\(file.path) was not written by SidePulse; move it away, then retry")
        }
        let uninstall = try OpenCodePluginInstaller.uninstall(paths: box.paths, dryRun: false)
        XCTAssertFalse(uninstall.changed)
        XCTAssertEqual(uninstall.notes, ["left it alone: it was not written by SidePulse"])
        XCTAssertEqual(try box.read(file), foreign)
        XCTAssertEqual(box.backups(of: file), [])

        let info = HookDoctor.inspect(paths: box.paths, provider: .opencode)
        XCTAssertEqual(info.error, "not written by SidePulse; move it away, then run 'sidepulse install opencode'")
        XCTAssertEqual(info.installedEvents, [])
        XCTAssertFalse(info.fullyInstalled)
    }

    func testReadOnlyPluginIsRefused() throws {
        let box = try HookInstallSandbox()
        let file = box.paths.openCodePluginFile
        _ = try OpenCodePluginInstaller.install(paths: box.paths, cliPath: T.cli, dryRun: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        XCTAssertThrowsError(try OpenCodePluginInstaller.install(paths: box.paths, cliPath: "/x/sidepulse", dryRun: false))
        XCTAssertThrowsError(try OpenCodePluginInstaller.uninstall(paths: box.paths, dryRun: false))
        XCTAssertEqual(OpenCodePluginInstaller.cliPath(in: try box.read(file)), T.cli)
    }

    func testDetection() throws {
        let box = try HookInstallSandbox()
        XCTAssertFalse(HookProvider.opencode.isDetected(box.paths))
        let binary = box.home.appendingPathComponent(".opencode/bin/opencode")
        try FileManager.default.createDirectory(at: binary, withIntermediateDirectories: true)
        XCTAssertFalse(HookProvider.opencode.isDetected(box.paths), "a directory is not a binary")
        try FileManager.default.removeItem(at: binary)
        try makeOpenCode(at: binary, version: "2.0.18")
        XCTAssertTrue(HookProvider.opencode.isDetected(box.paths))
        try FileManager.default.removeItem(at: binary)

        let onPath = box.root.appendingPathComponent("bin/opencode")
        try makeOpenCode(at: onPath, version: "2.0.18")
        var environment = box.paths.environment
        environment["PATH"] = "relative:" + onPath.deletingLastPathComponent().path
        XCTAssertEqual(OpenCodePluginInstaller.findOpenCodeBinary(paths: SidePulsePaths(environment: environment, home: box.home)),
                       onPath.path)
        XCTAssertFalse(HookProvider.opencode.isDetected(box.paths))
        try FileManager.default.createDirectory(at: box.paths.openCodeConfigDir, withIntermediateDirectories: true)
        XCTAssertTrue(HookProvider.opencode.isDetected(box.paths))
    }

    func testDoctorReportsCLIProblemsAndOlderPlugins() throws {
        let box = try HookInstallSandbox()
        _ = try OpenCodePluginInstaller.install(paths: box.paths, cliPath: T.cli, dryRun: false)
        var info = HookDoctor.inspect(paths: box.paths, provider: .opencode)
        XCTAssertTrue(info.agentDetected)
        XCTAssertTrue(info.hooksEnabled)
        XCTAssertEqual(info.hookCLIPaths, [T.cli])
        XCTAssertEqual(info.hookCLIProblems, ["\(T.cli) (missing)"])
        XCTAssertFalse(info.fullyInstalled)
        XCTAssertEqual(info.shortStatus, "Needs repair")
        XCTAssertTrue(HookDoctor.renderText([info]).contains(
            "  hooks: installed (14/14 events)\n  hook cli: \(T.cli) (missing); run 'sidepulse install opencode' to repair\n"))

        let cli = try box.makeBundledCLI()
        let file = box.paths.openCodePluginFile
        let older = OpenCodePluginInstaller.source(cliPath: cli).replacingOccurrences(of: "\"StopFailure\"", with: "\"Stop\"")
        try box.write(older, to: file)
        info = HookDoctor.inspect(paths: box.paths, provider: .opencode)
        XCTAssertEqual(info.hookCLIProblems, [])
        XCTAssertEqual(info.missingEvents, ["StopFailure"])
        XCTAssertEqual(info.error, OpenCodePluginInstaller.outdatedProblem)
        XCTAssertEqual(info.toggleAction, .install)
        XCTAssertTrue(HookDoctor.renderText([info]).contains("  hooks: partial (13/14)\n  missing events: StopFailure\n"))

        let sameEvents = OpenCodePluginInstaller.source(cliPath: cli)
            .replacingOccurrences(of: "setTimeout(finish, 2000)", with: "setTimeout(finish, 5000)")
        try box.write(sameEvents, to: file)
        info = HookDoctor.inspect(paths: box.paths, provider: .opencode)
        XCTAssertEqual(info.missingEvents, [])
        XCTAssertEqual(info.error, OpenCodePluginInstaller.outdatedProblem, "a logic change keeps every event name")
        XCTAssertEqual(info.menuTitle, "OpenCode \u{2014} Error")
        XCTAssertEqual(info.toggleAction, .install)
        XCTAssertTrue(HookDoctor.renderText([info]).contains("  error: written by another SidePulse version; "
            + "run 'sidepulse install opencode' to update it\n  hooks: installed (14/14 events)\n"))

        try box.write(OpenCodePluginInstaller.source(cliPath: cli).replacingOccurrences(of: "const CLI = ", with: "const cli = "), to: file)
        info = HookDoctor.inspect(paths: box.paths, provider: .opencode)
        XCTAssertEqual(info.hookCLIPaths, [])
        XCTAssertEqual(info.error, OpenCodePluginInstaller.outdatedProblem)

        _ = try OpenCodePluginInstaller.install(paths: box.paths, cliPath: cli, dryRun: false)
        info = HookDoctor.inspect(paths: box.paths, provider: .opencode)
        XCTAssertTrue(info.fullyInstalled)
        XCTAssertEqual(info.menuTitle, "OpenCode \u{2014} Installed")
        XCTAssertEqual(info.toggleAction, .uninstall)
    }

    func testOpenCode1IsReportedByInstallAndDoctor() throws {
        let box = try HookInstallSandbox()
        let binary = box.home.appendingPathComponent(".opencode/bin/opencode")
        try makeOpenCode(at: binary, version: "opencode v1.4.2")
        let result = try OpenCodePluginInstaller.install(paths: box.paths, cliPath: try box.makeBundledCLI(), dryRun: false)
        let problem = "OpenCode 1.4.2 cannot load the SidePulse plugin; update to OpenCode 2 or later"
        XCTAssertEqual(result.notes, [problem])
        XCTAssertNil(HookDoctor.inspect(paths: box.paths, provider: .opencode).error, "the menu never runs the binary")
        let checked = HookDoctor.inspect(paths: box.paths, provider: .opencode, checkVersions: true)
        XCTAssertEqual(checked.error, problem)
        XCTAssertFalse(checked.fullyInstalled)

        try makeOpenCode(at: binary, version: "2.0.18")
        XCTAssertNil(OpenCodePluginInstaller.versionProblem(paths: box.paths))
        XCTAssertTrue(HookDoctor.inspect(paths: box.paths, provider: .opencode, checkVersions: true).fullyInstalled)
    }

    func testParseVersion() {
        XCTAssertEqual(OpenCodePluginInstaller.parseVersion("opencode v2.0.18\n"), "2.0.18")
        XCTAssertEqual(OpenCodePluginInstaller.parseVersion("1.18.29"), "1.18.29")
        XCTAssertNil(OpenCodePluginInstaller.parseVersion("error: unknown flag"))
        XCTAssertNil(OpenCodePluginInstaller.parseVersion(""))
    }

    func testUninstallConfirmationSaysThePluginIsDeleted() {
        XCTAssertEqual(HookPresentation.uninstallConfirmation(provider: .opencode, configPath: "/p/sidepulse.js"),
                       "SidePulse will stop receiving OpenCode status updates. SidePulse deletes /p/sidepulse.js.")
        XCTAssertEqual(HookPresentation.uninstallConfirmation(provider: .claude, configPath: "/c/settings.json"),
                       "SidePulse will stop receiving Claude Code status updates. A backup of /c/settings.json is kept.")
    }

    // MARK: The plugin script

    /// Runs the generated plugin under Bun (what OpenCode uses) or Node, as two copies fed the same events the
    /// way OpenCode's per-project instances are, with a fake CLI that records what it receives.
    func testPluginTurnsOpenCodeEventsIntoHookRecords() throws {
        guard let runtime = Self.javaScriptRuntime() else { throw XCTSkip("neither bun nor node is installed") }
        let box = try HookInstallSandbox()
        let received = box.root.appendingPathComponent("received.txt")
        let cli = box.root.appendingPathComponent("fake cli")
        try box.write("#!/bin/sh\n{ printf '%s\\t' \"$*\"; cat; printf '\\n'; } >> '\(received.path)'\n", to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let source = OpenCodePluginInstaller.source(cliPath: cli.path)
        try box.write(source, to: box.root.appendingPathComponent("a/sidepulse.js"))
        try box.write(source, to: box.root.appendingPathComponent("b/sidepulse.js"))
        try box.write("[" + Self.events.joined(separator: ",\n") + "]", to: box.root.appendingPathComponent("events.json"))
        try box.write(Self.driver, to: box.root.appendingPathComponent("driver.mjs"))
        try box.write(#"{"type":"module"}"#, to: box.root.appendingPathComponent("package.json"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: runtime)
        process.arguments = ["driver.mjs"]
        process.currentDirectoryURL = box.root
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate() }
        XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "",
                       "the plugin never writes to stdout or stderr")

        let lines = try box.read(received).split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("hook-log --provider opencode\t") })
        let origin = #","agent_origin":"OpenCode","agent_origin_kind":"opencode","agent_origin_source":"plugin","#
            + #""agent_origin_confidence":"explicit"}"#
        XCTAssertTrue(lines.allSatisfy { $0.hasSuffix(origin) }, lines.joined(separator: "\n"))
        let records = lines.map { String($0.drop { $0 != "\t" }.dropFirst().dropLast(origin.count)) + "}" }
        XCTAssertEqual(records.count, Self.expectedRecords.count, records.joined(separator: "\n"))
        for (record, expected) in zip(records, Self.expectedRecords) where record != expected {
            XCTFail("got      \(record)\nexpected \(expected)")
        }

        let state = try JSONValue.parse(try box.read(box.root.appendingPathComponent("state.json")))
        let seen = state["seen"]?.arrayValue?.compactMap(\.stringValue) ?? []
        XCTAssertFalse(seen.contains { ["evt_00", "evt_04d", "evt_28b"].contains($0) }, "unhandled events are not tracked")
        XCTAssertTrue(seen.contains("evt_37"))
        XCTAssertEqual(state["tools"], .array([.object(["name": .string("write")])]), "a tool's input is never kept")
    }

    // MARK: Helpers

    private func makeOpenCode(at url: URL, version: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho '\(version)'\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    static func javaScriptRuntime() -> String? {
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for name in ["bun", "node"] {
            if let found = dirs.map({ "\($0)/\(name)" }).first(where: FileManager.default.isExecutableFile) { return found }
        }
        return nil
    }

    static let driver = """
    import { readFileSync, writeFileSync } from "node:fs"
    const events = JSON.parse(readFileSync("events.json", "utf8"))
    let finished = 0
    const ctx = () => ({ event: { subscribe: () => (async function* () {
      for (const event of events) { await new Promise((resolve) => setImmediate(resolve)); yield event }
      finished++
    })() } })
    const plugins = [await import("./a/sidepulse.js"), await import("./b/sidepulse.js")]
    const cleanups = await Promise.all(plugins.map((plugin) => plugin.default.setup(ctx())))
    const deadline = Date.now() + 20000
    const poll = setInterval(() => {
      const state = globalThis.__sidepulseOpenCode1
      if ((finished === 2 && state.queue.length === 0 && !state.running) || Date.now() > deadline) {
        clearInterval(poll)
        cleanups.forEach((cleanup) => cleanup())
        writeFileSync("state.json", JSON.stringify({ seen: [...state.seen], tools: [...state.tools.values()] }))
      }
    }, 20)
    """

    /// Shapes from OpenCode 2.0.18 captures, trimmed, plus malformed events a handler must survive; evt_37 repeats
    /// to check deduplication, and evt_38 deletes a session this process never saw.
    static let events = [
        #"{"id":"evt_00","type":"plugin.updated","data":{}}"#,
        "null",
        #"{"id":"evt_00x","type":"form.created","data":{"sessionID":"ses_A"}}"#,
        #"{"id":"evt_01","type":"session.created","location":{"directory":"/work/projA"},"data":{"sessionID":"ses_A","location":{"directory":"/work/projA"},"slug":"x"}}"#,
        #"{"id":"evt_02","type":"session.inbox.enqueued","location":{"directory":"/work/projA"},"data":{"sessionID":"ses_A","item":{"type":"user","payload":{"text":"Run echo hi"},"delivery":"queue"}}}"#,
        #"{"id":"evt_03","type":"session.execution.started","data":{"sessionID":"ses_A"}}"#,
        #"{"id":"evt_04","type":"session.text.ended","data":{"sessionID":"ses_A","assistantMessageID":"msg_1","ordinal":0,"text":"Running it now."}}"#,
        #"{"id":"evt_04d","type":"session.text.delta","data":{"sessionID":"ses_A","assistantMessageID":"msg_1","ordinal":0,"delta":"Running"}}"#,
        #"{"id":"evt_05","type":"session.tool.input.started","data":{"sessionID":"ses_A","assistantMessageID":"msg_1","id":"call_1","name":"shell"}}"#,
        #"{"id":"evt_06","type":"session.tool.called","data":{"sessionID":"ses_A","assistantMessageID":"msg_1","id":"call_1","input":{"command":"echo hi"},"executed":false}}"#,
        #"{"id":"evt_07","type":"permission.asked","data":{"id":"per_1","sessionID":"ses_A","action":"shell","resources":["echo hi"],"source":{"type":"tool","messageID":"msg_1","id":"call_1"}}}"#,
        #"{"id":"evt_08","type":"session.tool.success","data":{"sessionID":"ses_A","id":"call_1","content":[],"metadata":{"status":"completed","exit":0}}}"#,
        #"{"id":"evt_09","type":"session.inbox.enqueued","data":{"sessionID":"ses_A","item":{"type":"user","payload":{"text":"also list files"},"delivery":"steer"}}}"#,
        #"{"id":"evt_10","type":"session.tool.input.started","data":{"sessionID":"ses_A","id":"call_2","name":"shell"}}"#,
        #"{"id":"evt_11","type":"session.tool.called","data":{"sessionID":"ses_A","id":"call_2","input":{"command":"ls missing"}}}"#,
        #"{"id":"evt_12","type":"session.tool.success","data":{"sessionID":"ses_A","id":"call_2","metadata":{"status":"completed","exit":1}}}"#,
        #"{"id":"evt_13","type":"session.tool.input.started","data":{"sessionID":"ses_A","id":"call_3","name":"subagent"}}"#,
        #"{"id":"evt_14","type":"session.tool.called","data":{"sessionID":"ses_A","id":"call_3","input":{"agent":"general","prompt":"look"}}}"#,
        #"{"id":"evt_15","type":"session.created","location":{"directory":"/work/projA"},"data":{"sessionID":"ses_B","parentID":"ses_A","agent":"general","location":{"directory":"/work/projA"}}}"#,
        #"{"id":"evt_16","type":"session.inbox.enqueued","data":{"sessionID":"ses_B","item":{"type":"user","payload":{"text":"You are a subagent"}}}}"#,
        #"{"id":"evt_17","type":"session.execution.started","data":{"sessionID":"ses_B"}}"#,
        #"{"id":"evt_18","type":"session.tool.input.started","data":{"sessionID":"ses_B","id":"call_4","name":"read"}}"#,
        #"{"id":"evt_19","type":"session.tool.called","data":{"sessionID":"ses_B","id":"call_4","input":{"filePath":"/etc/hosts"}}}"#,
        #"{"id":"evt_20","type":"permission.asked","data":{"id":"per_2","sessionID":"ses_B","action":"external_directory","resources":["/etc/*"],"source":{"type":"tool","id":"call_4"}}}"#,
        #"{"id":"evt_21","type":"session.tool.failed","data":{"sessionID":"ses_B","id":"call_4","error":{"type":"aborted","message":"The user declined this tool call"}}}"#,
        #"{"id":"evt_22","type":"session.text.ended","data":{"sessionID":"ses_B","assistantMessageID":"msg_b1","ordinal":0,"text":"Could not read it."}}"#,
        #"{"id":"evt_23","type":"session.execution.succeeded","data":{"sessionID":"ses_B"}}"#,
        #"{"id":"evt_24","type":"session.tool.success","data":{"sessionID":"ses_A","id":"call_3","metadata":{}}}"#,
        #"{"id":"evt_25","type":"session.tool.input.started","data":{"sessionID":"ses_A","id":"call_5","name":"question"}}"#,
        #"{"id":"evt_26","type":"session.tool.called","data":{"sessionID":"ses_A","id":"call_5","input":{"questions":[]}}}"#,
        #"{"id":"evt_27","type":"form.created","data":{"form":{"id":"frm_1","sessionID":"ses_A","title":"Questions","metadata":{"kind":"question","tool":{"id":"call_5"}},"fields":[{"key":"q","description":"Tea or coffee?"}]}}}"#,
        #"{"id":"evt_28","type":"session.tool.success","data":{"sessionID":"ses_A","id":"call_5","metadata":{}}}"#,
        #"{"id":"evt_28a","type":"session.tool.input.started","data":{"sessionID":"ses_A","id":"call_6","name":"write"}}"#,
        #"{"id":"evt_28b","type":"session.tool.input.delta","data":{"sessionID":"ses_A","id":"call_6","delta":"{"}}"#,
        #"{"id":"evt_28c","type":"session.tool.called","data":{"sessionID":"ses_A","id":"call_6","input":{"filePath":"/work/projA/big.txt","content":"\#(String(repeating: "y", count: 5000))"}}}"#,
        #"{"id":"evt_29","type":"session.text.ended","data":{"sessionID":"ses_A","assistantMessageID":"msg_9","ordinal":0,"text":"All set."}}"#,
        #"{"id":"evt_30","type":"session.text.ended","data":{"sessionID":"ses_A","assistantMessageID":"msg_9","ordinal":1,"text":"Should I also add tests?"}}"#,
        #"{"id":"evt_31","type":"session.execution.succeeded","data":{"sessionID":"ses_A"}}"#,
        #"{"id":"evt_32","type":"session.inbox.enqueued","data":{"sessionID":"ses_A","item":{"type":"user","payload":{"text":"again \#(String(repeating: "x", count: 9000))"}}}}"#,
        #"{"id":"evt_33","type":"session.execution.started","data":{"sessionID":"ses_A"}}"#,
        #"{"id":"evt_34","type":"session.execution.failed","data":{"sessionID":"ses_A","error":{"type":"provider.no-route","message":"Model unavailable: x"}}}"#,
        #"{"id":"evt_35","type":"session.execution.started","data":{"sessionID":"ses_A"}}"#,
        #"{"id":"evt_36","type":"session.execution.interrupted","data":{"sessionID":"ses_A","reason":"user"}}"#,
        #"{"id":"evt_37","type":"session.deleted","data":{"sessionID":"ses_A"}}"#,
        #"{"id":"evt_37","type":"session.deleted","data":{"sessionID":"ses_A"}}"#,
        #"{"id":"evt_38","type":"session.deleted","data":{"sessionID":"ses_old"}}"#,
    ]

    static let expectedRecords = [
        #"{"hook_event_name":"SessionStart","session_id":"ses_A","cwd":"/work/projA"}"#,
        #"{"hook_event_name":"UserPromptSubmit","session_id":"ses_A","cwd":"/work/projA","prompt":"Run echo hi"}"#,
        #"{"hook_event_name":"PreToolUse","session_id":"ses_A","cwd":"/work/projA","tool_name":"shell","tool_input":{"command":"echo hi"}}"#,
        #"{"hook_event_name":"PermissionRequest","session_id":"ses_A","cwd":"/work/projA","tool_name":"shell","tool_input":{"command":"echo hi"},"message":"OpenCode needs permission: shell echo hi"}"#,
        #"{"hook_event_name":"PostToolUse","session_id":"ses_A","cwd":"/work/projA","tool_name":"shell","tool_input":{"command":"echo hi"},"tool_response":{"exit_code":0}}"#,
        #"{"hook_event_name":"UserPromptSubmit","session_id":"ses_A","cwd":"/work/projA","prompt":"also list files"}"#,
        #"{"hook_event_name":"PreToolUse","session_id":"ses_A","cwd":"/work/projA","tool_name":"shell","tool_input":{"command":"ls missing"}}"#,
        #"{"hook_event_name":"PostToolUse","session_id":"ses_A","cwd":"/work/projA","tool_name":"shell","tool_input":{"command":"ls missing"},"tool_response":{"exit_code":1}}"#,
        #"{"hook_event_name":"PreToolUse","session_id":"ses_A","cwd":"/work/projA","tool_name":"subagent"}"#,
        #"{"hook_event_name":"SubagentStart","session_id":"ses_A","cwd":"/work/projA","agent_id":"ses_B","agent_type":"general"}"#,
        #"{"hook_event_name":"PreToolUse","session_id":"ses_A","cwd":"/work/projA","agent_id":"ses_B","agent_type":"general","tool_name":"read"}"#,
        #"{"hook_event_name":"PermissionRequest","session_id":"ses_A","cwd":"/work/projA","agent_id":"ses_B","agent_type":"general","tool_name":"read","message":"OpenCode needs permission: external_directory /etc/*"}"#,
        #"{"hook_event_name":"PostToolUseFailure","session_id":"ses_A","cwd":"/work/projA","agent_id":"ses_B","agent_type":"general","tool_name":"read","error":"The user declined this tool call"}"#,
        #"{"hook_event_name":"SubagentStop","session_id":"ses_A","cwd":"/work/projA","agent_id":"ses_B","agent_type":"general","last_assistant_message":"Could not read it."}"#,
        #"{"hook_event_name":"PostToolUse","session_id":"ses_A","cwd":"/work/projA","tool_name":"subagent"}"#,
        #"{"hook_event_name":"PreToolUse","session_id":"ses_A","cwd":"/work/projA","tool_name":"question"}"#,
        #"{"hook_event_name":"PermissionRequest","session_id":"ses_A","cwd":"/work/projA","tool_name":"question","message":"OpenCode is asking: Tea or coffee?"}"#,
        #"{"hook_event_name":"PostToolUse","session_id":"ses_A","cwd":"/work/projA","tool_name":"question"}"#,
        #"{"hook_event_name":"PreToolUse","session_id":"ses_A","cwd":"/work/projA","tool_name":"write"}"#,
        #"{"hook_event_name":"Stop","session_id":"ses_A","cwd":"/work/projA","last_assistant_message":"All set.\n\nShould I also add tests?"}"#,
        #"{"hook_event_name":"UserPromptSubmit","session_id":"ses_A","cwd":"/work/projA","prompt":"again \#(String(repeating: "x", count: 7994))"}"#,
        #"{"hook_event_name":"StopFailure","session_id":"ses_A","cwd":"/work/projA","error":"provider.no-route","error_details":"Model unavailable: x"}"#,
        #"{"hook_event_name":"UserPromptSubmit","session_id":"ses_A","cwd":"/work/projA"}"#,
        #"{"hook_event_name":"Interrupt","session_id":"ses_A","cwd":"/work/projA","reason":"user"}"#,
        #"{"hook_event_name":"SessionEnd","session_id":"ses_A","cwd":"/work/projA"}"#,
    ]
}
