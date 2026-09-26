import Foundation
import XCTest
@testable import SidePulseCore

/// Never touches the real ~/.claude, ~/.codex, ~/.config/opencode or ~/Library.
final class HookInstallSandbox {
    let root: URL
    let home: URL
    let paths: SidePulsePaths

    init(extraEnvironment: [String: String] = [:]) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidepulse-hookinstall-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var env = ["SIDEPULSE_HOME": root.appendingPathComponent("state").path, "HOME": home.path]
        for (k, v) in extraEnvironment { env[k] = v }
        paths = SidePulsePaths(environment: env, home: home)
        precondition(HookProvider.allCases.allSatisfy { $0.configFile(paths).path.hasPrefix(root.path) })
    }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    func backups(of url: URL) -> [URL] {
        let dir = url.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix(url.lastPathComponent + ".bak.") }.sorted().map { dir.appendingPathComponent($0) }
    }

    /// Lives in an app bundle so the doctor accepts it as the SidePulse CLI.
    func makeBundledCLI() throws -> String {
        let cli = root.appendingPathComponent("SidePulse.app/Contents/Helpers/sidepulse")
        try write("#!/bin/sh\n", to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        return cli.path
    }

    /// Mimics `CodexTrust.refresh`, assuming our hook is the first group of each event.
    func trustCodexHooks(_ events: [String] = HookProvider.codex.events) throws {
        let config = paths.codexConfigFile
        var hashes: [String: String] = [:]
        for event in events { hashes["\(config.path):\(CodexHookInstaller.snakeCase(event)):0:0"] = "sha256:test" }
        try write(CodexTrust.applyTrustedHashes(hashes, to: try read(config)), to: config)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    deinit { cleanup() }
}

enum HookInstallTestData {
    static let cli = "/Users/tester/.local/bin/sidepulse"
    static var claudeCommand: String { HookCommand.command(cliPath: cli, provider: .claude) }
    static var codexCommand: String { HookCommand.command(cliPath: cli, provider: .codex) }

    /// A SidePulse command in any shape but the one written today, i.e. a Python-era hook.
    static func isPythonEra(_ command: String) -> Bool {
        HookCommand.isSidePulseCommand(command) && !HookCommand.isCurrentStyleCommand(command)
    }

    static func pythonEraClaudeHandlers(_ text: String) -> Int {
        ClaudeHookInstaller.handlerCommands(in: text).filter { isPythonEra($0.command) }.count
    }

    static func pythonEraCodexGroups(_ text: String) -> Int {
        CodexHookInstaller.hookGroups(in: TOMLLines(text)).filter { $0.commands.contains(where: isPythonEra) }.count
    }

    static func claudeCommands(_ text: String) throws -> [String: [String]] {
        guard case .object(let hooks)? = try JSONValue.parse(text)["hooks"] else { return [:] }
        var out: [String: [String]] = [:]
        for (event, value) in hooks {
            out[event] = (value.arrayValue ?? []).flatMap { entry in
                (entry["hooks"]?.arrayValue ?? []).compactMap { $0["command"]?.stringValue }
            }
        }
        return out
    }

    static func count(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
