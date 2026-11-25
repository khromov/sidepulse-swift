import Foundation
import XCTest
@testable import SidePulseCore

final class HookInstallAntigravityTests: XCTestCase {
    typealias T = HookInstallTestData
    let cmd = HookInstallTestData.antigravityCommand

    func testConfigPaths() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let paths = SidePulsePaths(environment: [:], home: home)
        XCTAssertEqual(paths.antigravityConfigDir.path, "/Users/tester/.gemini/config")
        XCTAssertEqual(paths.antigravityHooksFile.path, "/Users/tester/.gemini/config/hooks.json")
        XCTAssertEqual(HookProvider.antigravity.configFile(paths).path, "/Users/tester/.gemini/config/hooks.json")
        XCTAssertEqual(HookProvider.antigravity.configDir(paths).path, "/Users/tester/.gemini/config")
    }

    // MARK: Pure transform

    func testFreshInstallWritesFlatAndGroupedEventsWithTimeout() throws {
        let text = try AntigravityHookInstaller.installing(into: nil, command: cmd)
        let root = try JSONValue.parse(text)
        XCTAssertEqual(root.objectValue?.keys, ["sidepulse"])
        let spec = try XCTUnwrap(root["sidepulse"]?.objectValue)
        XCTAssertEqual(spec.keys, HookProvider.antigravity.events)
        for event in HookProvider.antigravity.events {
            XCTAssertEqual(spec[event], .array([AntigravityHookInstaller.desiredEntry(event: event, command: cmd)]), event)
        }
        // Flat events hold handler objects directly without a matcher/hooks wrapper.
        XCTAssertEqual(spec["SessionStart"]?.arrayValue?.first?.serialized(),
                       #"{"type":"command","command":"\#(cmd)","timeout":10}"#)
        XCTAssertEqual(spec["Stop"]?.arrayValue?.first?.serialized(),
                       #"{"type":"command","command":"\#(cmd)","timeout":10}"#)
        // Tool events wrap handlers in a matcher group.
        XCTAssertEqual(spec["PreToolUse"]?.arrayValue?.first?.serialized(),
                       #"{"matcher":"*","hooks":[{"type":"command","command":"\#(cmd)","timeout":10}]}"#)
        XCTAssertEqual(spec["PostToolUse"]?.arrayValue?.first?.serialized(),
                       #"{"matcher":"*","hooks":[{"type":"command","command":"\#(cmd)","timeout":10}]}"#)
        XCTAssertTrue(text.hasSuffix("}\n"))
        XCTAssertEqual(try AntigravityHookInstaller.installing(into: "", command: cmd), text)
        XCTAssertEqual(try AntigravityHookInstaller.installing(into: " \n\t ", command: cmd), text)
    }

    func testReinstallIsByteIdenticalAndPreservesFormattingWhenUnchanged() throws {
        let once = try AntigravityHookInstaller.installing(into: #"{"lint":{"Stop":[{"command":"./lint.sh"}]}}"#, command: cmd)
        let twice = try AntigravityHookInstaller.installing(into: once, command: cmd)
        XCTAssertEqual(once, twice)

        let compact = try JSONValue.parse(once).serialized()
        XCTAssertEqual(try AntigravityHookInstaller.installing(into: compact, command: cmd), compact)
    }

    func testInstallPreservesOtherNamedHooksAndUserHandlers() throws {
        let input = #"""
        {
          "lint-checker": {
            "PostToolUse": [{"matcher": "run_command", "hooks": [{"type": "command", "command": "./lint.sh", "timeout": 15}]}]
          },
          "sidepulse": {
            "enabled": false,
            "Stop": [{"type": "command", "command": "say done"}],
            "PreToolUse": [{"matcher": "run_command", "hooks": [
              {"type": "command", "command": "echo guard"},
              {"type": "command", "command": "/old/sidepulse hook-log --provider antigravity ; true"}
            ]}]
          },
          "safety-gate": {
            "PreInvocation": [{"type": "command", "command": "./gate.sh"}]
          }
        }
        """#
        let output = try AntigravityHookInstaller.installing(into: input, command: cmd)
        let root = try JSONValue.parse(output)
        XCTAssertEqual(root.objectValue?.keys, ["lint-checker", "sidepulse", "safety-gate"])
        XCTAssertEqual(root["lint-checker"]?["PostToolUse"]?.arrayValue?.first?["hooks"]?.arrayValue?.first?["command"],
                       .string("./lint.sh"))
        XCTAssertEqual(root["safety-gate"]?["PreInvocation"]?.arrayValue?.first?["command"], .string("./gate.sh"))
        XCTAssertEqual(root["sidepulse"]?["enabled"], .bool(false))
        XCTAssertEqual(root["sidepulse"]?["Stop"]?.arrayValue?.compactMap { $0["command"]?.stringValue },
                       ["say done", cmd])
        let pre = root["sidepulse"]?["PreToolUse"]?.arrayValue ?? []
        XCTAssertEqual(pre.count, 2)
        XCTAssertEqual(pre[0], .object(["matcher": .string("run_command"),
                                        "hooks": .array([.object(["type": .string("command"), "command": .string("echo guard")])])]))
        XCTAssertEqual(pre[1], AntigravityHookInstaller.desiredEntry(event: "PreToolUse", command: cmd))
    }

    func testInstallStripsStraySidePulseHandlersFromOtherNamedHooks() throws {
        let input = #"""
        {
          "custom": {
            "Stop": [
              {"type": "command", "command": "echo keep"},
              {"type": "command", "command": "/old/sidepulse hook-log --provider antigravity ; true"}
            ]
          },
          "old-sidepulse": {
            "SessionStart": [{"type": "command", "command": "/old/sidepulse hook-log --provider antigravity ; true"}]
          }
        }
        """#
        let output = try AntigravityHookInstaller.installing(into: input, command: cmd)
        let root = try JSONValue.parse(output)
        XCTAssertEqual(root.objectValue?.keys, ["custom", "sidepulse"])
        XCTAssertEqual(root["custom"]?["Stop"]?.arrayValue?.compactMap { $0["command"]?.stringValue }, ["echo keep"])
        XCTAssertEqual(AntigravityHookInstaller.installedEvents(in: output), HookProvider.antigravity.events)
    }

    func testUninstallRemovesOnlySidePulseHandlersAndKeepsUserHooks() throws {
        let input = #"""
        {
          "lint-checker": {
            "PostToolUse": [{"matcher": "run_command", "hooks": [{"type": "command", "command": "./lint.sh"}]}]
          }
        }
        """#
        let installed = try AntigravityHookInstaller.installing(into: input, command: cmd)
        let removed = try AntigravityHookInstaller.uninstalling(from: installed)
        XCTAssertEqual(try JSONValue.parse(removed), try JSONValue.parse(input))

        // Removing the only hook leaves an empty JSON object.
        let bare = try AntigravityHookInstaller.installing(into: nil, command: cmd)
        XCTAssertEqual(try AntigravityHookInstaller.uninstalling(from: bare), "{}\n")

        // Removing a disabled `"sidepulse"` hook drops the whole `"sidepulse"` entry.
        let disabled = try AntigravityHookInstaller.installing(into: #"{"sidepulse":{"enabled":false}}"#, command: cmd)
        XCTAssertEqual(try AntigravityHookInstaller.uninstalling(from: disabled), "{}\n")
    }

    func testUninstallWithoutOurHooksReturnsTextVerbatim() throws {
        for text in ["", "{ }", #"{"lint":{"Stop":[{"command":"echo hi"}]}}"#, "[1]"] {
            XCTAssertEqual(try AntigravityHookInstaller.uninstalling(from: text), text, text)
        }
    }

    func testMalformedJSONAndInvalidShapesThrow() {
        for bad in ["{", #"{"sidepulse": }"#, "nope"] {
            XCTAssertThrowsError(try AntigravityHookInstaller.installing(into: bad, command: cmd), bad) { error in
                guard case HookInstallError.invalidJSON = error else { return XCTFail("\(error)") }
            }
            XCTAssertThrowsError(try AntigravityHookInstaller.uninstalling(from: bad), bad)
        }
        for bad in ["[]", "\"text\"", #"{"sidepulse":[]}"#, #"{"sidepulse":"x"}"#, #"{"sidepulse":{"Stop":{}}}"#] {
            XCTAssertThrowsError(try AntigravityHookInstaller.installing(into: bad, command: cmd), bad) { error in
                guard case HookInstallError.invalidStructure = error else { return XCTFail("\(error)") }
            }
        }
        XCTAssertNoThrow(try AntigravityHookInstaller.installing(into: #"{"sidepulse":null}"#, command: cmd))
        XCTAssertNoThrow(try AntigravityHookInstaller.installing(into: #"{"sidepulse":{"Stop":null}}"#, command: cmd))
    }

    func testInstalledEventsRequiresValidFlatOrGroupedShape() {
        // A grouped entry in a flat event or a flat entry in a grouped event does not count as installed.
        let wrongShapes = #"""
        {
          "sidepulse": {
            "Stop": [{"matcher": "*", "hooks": [{"type": "command", "command": "\#(cmd)"}]}],
            "PreToolUse": [{"type": "command", "command": "\#(cmd)"}],
            "SessionStart": [{"type": "command", "command": "\#(cmd)"}]
          }
        }
        """#
        XCTAssertEqual(AntigravityHookInstaller.installedEvents(in: wrongShapes), ["SessionStart"])
    }

    // MARK: Files, detection and doctor

    func testInstallRoundTripBackupsDryRunAndReadOnly() throws {
        let box = try HookInstallSandbox()
        let file = box.paths.antigravityHooksFile
        let dry = try AntigravityHookInstaller.install(paths: box.paths, cliPath: T.cli, dryRun: true)
        XCTAssertTrue(dry.changed)
        XCTAssertTrue(dry.dryRun)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        let first = try AntigravityHookInstaller.install(paths: box.paths, cliPath: T.cli, dryRun: false)
        XCTAssertTrue(first.changed)
        XCTAssertNil(first.backupPath)
        let written = try box.read(file)
        XCTAssertEqual(AntigravityHookInstaller.installedEvents(in: written), HookProvider.antigravity.events)

        let second = try AntigravityHookInstaller.install(paths: box.paths, cliPath: T.cli, dryRun: false)
        XCTAssertFalse(second.changed)
        XCTAssertEqual(box.backups(of: file), [])

        chmod(file.path, 0o444)
        defer { chmod(file.path, 0o644) }
        XCTAssertThrowsError(try AntigravityHookInstaller.uninstall(paths: box.paths, dryRun: false))
        chmod(file.path, 0o644)

        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let removed = try HookInstaller.perform(.uninstall, provider: .antigravity, paths: box.paths, cliPath: nil)
        XCTAssertTrue(removed.changed)
        XCTAssertNotNil(removed.backupPath)
        XCTAssertEqual(try box.read(file), "{}\n")

        _ = try AntigravityHookInstaller.install(paths: box.paths, cliPath: T.cli, dryRun: false, now: t0)
        XCTAssertEqual(try AntigravityHookInstaller.uninstall(paths: box.paths, dryRun: true, now: t0).changed, true)
    }

    func testDetectionAvoidsBareGeminiDirAndRecognizesAntigravityInstallations() throws {
        let box = try HookInstallSandbox()
        XCTAssertFalse(HookProvider.antigravity.isDetected(box.paths))

        // Bare `~/.gemini` (used by Gemini CLI) and an empty `~/.gemini/config` do not count.
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent(".gemini/config"),
                                                withIntermediateDirectories: true)
        XCTAssertFalse(HookProvider.antigravity.isDetected(box.paths))

        for rel in [".gemini/antigravity", ".gemini/antigravity-cli", ".gemini/antigravity-ide", "Applications/Antigravity.app"] {
            let dir = box.home.appendingPathComponent(rel, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            XCTAssertTrue(HookProvider.antigravity.isDetected(box.paths), rel)
            try FileManager.default.removeItem(at: dir)
            XCTAssertFalse(HookProvider.antigravity.isDetected(box.paths), rel)
        }

        // An existing hooks.json file counts.
        try box.write("{}", to: box.paths.antigravityHooksFile)
        XCTAssertTrue(HookProvider.antigravity.isDetected(box.paths))
        try FileManager.default.removeItem(at: box.paths.antigravityHooksFile)

        // `agy` in `~/.antigravity/antigravity/bin`, `~/.local/bin`, or `PATH` counts.
        let localBin = box.home.appendingPathComponent(".local/bin/agy")
        try box.write("#!/bin/sh\n", to: localBin)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: localBin.path)
        XCTAssertTrue(HookProvider.antigravity.isDetected(box.paths))
        try FileManager.default.removeItem(at: localBin)

        let onPath = box.root.appendingPathComponent("bin/agy")
        try box.write("#!/bin/sh\n", to: onPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: onPath.path)
        var env = box.paths.environment
        env["PATH"] = "relative:" + onPath.deletingLastPathComponent().path
        XCTAssertTrue(HookProvider.antigravity.isDetected(SidePulsePaths(environment: env, home: box.home)))
    }

    func testDisabledHookAndMalformedFileReportedByInstallAndDoctor() throws {
        let box = try HookInstallSandbox()
        let cli = try box.makeBundledCLI()
        try box.write(#"{"sidepulse":{"enabled":false}}"#, to: box.paths.antigravityHooksFile)
        let result = try AntigravityHookInstaller.install(paths: box.paths, cliPath: cli, dryRun: false)
        XCTAssertEqual(result.notes, [
            "Antigravity hooks are turned off by \"enabled\": false on \"sidepulse\"; SidePulse left that alone, "
                + "so Antigravity runs no SidePulse hooks until you turn them back on",
        ])

        let info = HookDoctor.inspect(paths: box.paths, provider: .antigravity)
        XCTAssertEqual(info.installedEvents.count, 6)
        XCTAssertFalse(info.hooksEnabled)
        XCTAssertFalse(info.fullyInstalled)
        XCTAssertEqual(info.statusText, "Installed, but Antigravity hooks are disabled")
        XCTAssertTrue(HookDoctor.renderText([info]).contains(
            "  hooks feature: disabled (\"enabled\": false on \"sidepulse\", so Antigravity runs no SidePulse hooks)\n"))

        try box.write("{ broken", to: box.paths.antigravityHooksFile)
        let broken = HookDoctor.inspect(paths: box.paths, provider: .antigravity)
        XCTAssertFalse(broken.hooksEnabled)
        XCTAssertNotNil(broken.error)
        XCTAssertFalse(broken.fullyInstalled)

        try box.write("[1]", to: box.paths.antigravityHooksFile)
        XCTAssertEqual(HookDoctor.inspect(paths: box.paths, provider: .antigravity).error,
                       "the top level is not a JSON object")
    }
}
