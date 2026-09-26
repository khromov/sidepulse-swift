import Foundation
import XCTest
@testable import SidePulseCore

/// A throwaway home + SIDEPULSE_HOME under the temp directory. Never touches the
/// real ~/.claude, ~/.codex or ~/Library.
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
        precondition(paths.claudeSettingsFile.path.hasPrefix(root.path) && paths.codexConfigFile.path.hasPrefix(root.path))
    }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    /// Backup files next to `url`.
    func backups(of url: URL) -> [URL] {
        let dir = url.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix(url.lastPathComponent + ".bak.") }.sorted().map { dir.appendingPathComponent($0) }
    }

    /// An executable `SidePulse.app/Contents/Helpers/sidepulse` in the sandbox (a
    /// CLI path the doctor accepts); returns its path.
    func makeBundledCLI() throws -> String {
        let cli = root.appendingPathComponent("SidePulse.app/Contents/Helpers/sidepulse")
        try write("#!/bin/sh\n", to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        return cli.path
    }

    /// Adds a `trusted_hash` for the SidePulse hook of each `events` (the first
    /// group of each event) to the Codex config, as `CodexTrust.refresh` would.
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

    /// Every handler command in a Claude settings document, per event.
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
