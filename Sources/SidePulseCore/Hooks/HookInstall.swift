import Foundation

public enum HookProvider: String, CaseIterable, Sendable {
    case claude
    case codex
    case opencode

    public var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        }
    }

    /// For OpenCode, the records the SidePulse plugin emits, since OpenCode has no hook config.
    public var events: [String] {
        switch self {
        case .claude:
            return ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
                    "PermissionRequest", "Notification", "PreCompact", "PostCompact", "SubagentStop", "Stop", "SessionEnd"]
        case .codex:
            return ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
                    "PreCompact", "PostCompact", "SubagentStart", "SubagentStop", "Stop", "Interrupt"]
        case .opencode:
            return ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
                    "PermissionRequest", "PreCompact", "PostCompact", "SubagentStart", "SubagentStop", "Stop",
                    "StopFailure", "Interrupt", "SessionEnd"]
        }
    }

    public func configFile(_ paths: SidePulsePaths) -> URL {
        switch self {
        case .claude: return paths.claudeSettingsFile
        case .codex: return paths.codexConfigFile
        case .opencode: return paths.openCodePluginFile
        }
    }

    public func configDir(_ paths: SidePulsePaths) -> URL {
        switch self {
        case .claude: return paths.claudeDir
        case .codex: return paths.codexDir
        case .opencode: return paths.openCodeConfigDir
        }
    }

    /// Whether the agent looks installed; OpenCode only creates its config directory on first run.
    public func isDetected(_ paths: SidePulsePaths) -> Bool {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: configDir(paths).path, isDirectory: &isDir), isDir.boolValue { return true }
        return self == .opencode && OpenCodePluginInstaller.findOpenCodeBinary(paths: paths) != nil
    }
}

public enum HookCommand {
    /// Only bounds a wedged process; the hook itself finishes in milliseconds.
    public static let timeoutSeconds = 10

    /// Deliberately never a log path or a `>>` redirect, so a user's own `say done >> /tmp/x.log` hook
    /// never looks like ours.
    static let markers = [
        "hook-log --provider",     // every CLI form, Swift and Python
        "hook_entry.py",           // the non-frozen Python install's `python3 …/hook_entry.py`
    ]

    /// The trailing `; true` makes the hook fail open.
    public static func command(cliPath: String, provider: HookProvider) -> String {
        "\(shellQuote(cliPath)) hook-log --provider \(provider.rawValue) ; true"
    }

    /// Python `shlex.quote` semantics.
    public static func shellQuote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        let safe = s.unicodeScalars.allSatisfy { c in
            switch c {
            case "a"..."z", "A"..."Z", "0"..."9", "_", "@", "%", "+", "=", ":", ",", ".", "/", "-": return true
            default: return false
            }
        }
        if safe { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    public static func isSidePulseCommand(_ command: String) -> Bool {
        markers.contains { command.contains($0) }
    }

    /// Only the exact shape `command(cliPath:provider:)` writes, so a foreign command that merely embeds ours
    /// (`curl … | sh ; /x/sidepulse hook-log …`) never gets Codex trust.
    public static func isCurrentStyleCommand(_ command: String) -> Bool {
        cliPath(of: command) != nil
    }

    public static func cliPath(of command: String) -> String? {
        for provider in HookProvider.allCases {
            let suffix = " hook-log --provider \(provider.rawValue) ; true"
            guard command.hasSuffix(suffix) else { continue }
            return unquotedShellWord(String(command.dropLast(suffix.count)))
        }
        return nil
    }

    /// Inverse of `shellQuote`: nil for any word it could not have produced.
    static func unquotedShellWord(_ word: String) -> String? {
        guard !word.isEmpty else { return nil }
        if shellQuote(word) == word { return word }
        guard word.count >= 2, word.hasPrefix("'"), word.hasSuffix("'") else { return nil }
        let inner = String(word.dropFirst().dropLast()).replacingOccurrences(of: "'\"'\"'", with: "'")
        return shellQuote(inner) == word ? inner : nil
    }
}

public struct InstallResult: Sendable, Equatable {
    public var provider: HookProvider
    public var configPath: URL
    public var changed: Bool
    public var backupPath: URL?
    public var dryRun: Bool
    public var notes: [String]

    public init(provider: HookProvider, configPath: URL, changed: Bool, backupPath: URL? = nil, dryRun: Bool, notes: [String] = []) {
        self.provider = provider; self.configPath = configPath; self.changed = changed
        self.backupPath = backupPath; self.dryRun = dryRun; self.notes = notes
    }
}

public enum HookInstaller {
    /// A nil `cliPath` throws `HookCLINotFound` on install rather than writing hooks that run nothing.
    public static func perform(_ action: HookAction, provider: HookProvider, paths: SidePulsePaths, cliPath: String?,
                               dryRun: Bool = false, trust: Bool = true) throws -> InstallResult {
        switch (action, provider) {
        case (.uninstall, .claude): return try ClaudeHookInstaller.uninstall(paths: paths, dryRun: dryRun)
        case (.uninstall, .codex): return try CodexHookInstaller.uninstall(paths: paths, dryRun: dryRun)
        case (.uninstall, .opencode): return try OpenCodePluginInstaller.uninstall(paths: paths, dryRun: dryRun)
        case (.install, _):
            guard let cliPath else { throw HookCLINotFound() }
            switch provider {
            case .claude: return try ClaudeHookInstaller.install(paths: paths, cliPath: cliPath, dryRun: dryRun)
            case .codex: return try CodexHookInstaller.install(paths: paths, cliPath: cliPath, dryRun: dryRun, trust: trust)
            case .opencode: return try OpenCodePluginInstaller.install(paths: paths, cliPath: cliPath, dryRun: dryRun)
            }
        }
    }
}

func uniqued(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
}

/// The config file is never touched when one of these is thrown.
public enum HookInstallError: Error, Equatable, CustomStringConvertible {
    case invalidJSON(path: String, message: String)
    /// A shape we refuse to rewrite (e.g. `"hooks": []`) because rewriting it would destroy user data.
    case invalidStructure(path: String, message: String)
    case unreadable(path: String, message: String)
    case notOurs(path: String)

    public var description: String {
        switch self {
        case .invalidJSON(let path, let message):
            return "\(path) is not valid JSON (\(message)); fix or move it, then retry"
        case .invalidStructure(let path, let message):
            return "\(path): \(message); fix it by hand, then retry"
        case .unreadable(let path, let message):
            return "could not read \(path): \(message)"
        case .notOurs(let path):
            return "\(path) was not written by SidePulse; move it away, then retry"
        }
    }

    /// The pure transforms do not know the real path, so callers attach it here.
    func at(_ path: String) -> HookInstallError {
        switch self {
        case .invalidJSON(_, let m): return .invalidJSON(path: path, message: m)
        case .invalidStructure(_, let m): return .invalidStructure(path: path, message: m)
        case .unreadable(_, let m): return .unreadable(path: path, message: m)
        case .notOurs: return .notOurs(path: path)
        }
    }
}

enum HookConfigFile {
    /// Throws rather than returning nil for an unreadable or non-UTF-8 file, so it is never mistaken for a
    /// new one or written back lossily.
    static func read(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw HookInstallError.unreadable(path: url.path, message: error.localizedDescription)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw HookInstallError.unreadable(path: url.path, message: "not valid UTF-8")
        }
        return text
    }

    static func write(_ text: String, to url: URL, now: Date) throws -> URL? {
        try FileUtil.ensureWritable(url)
        let backup = try FileUtil.backup(url, now: now)
        try FileUtil.atomicWrite(text, to: url)
        return backup
    }

    static func plural(_ n: Int, _ singular: String, _ pluralForm: String? = nil) -> String {
        "\(n) \(n == 1 ? singular : (pluralForm ?? singular + "s"))"
    }
}

/// Unchanged documents come back byte-for-byte and an event already holding exactly our entry is left in
/// place, so reinstalling never reformats or reorders a user's hooks.
public enum ClaudeHookInstaller {
    public static func installing(into text: String?, command: String) throws -> String {
        let original: JSONValue?
        var root: JSONObject
        if let text, !isBlank(text) {
            let parsed = try parse(text)
            guard case .object(let object) = parsed else {
                throw HookInstallError.invalidStructure(path: "settings.json", message: "the top level is not a JSON object")
            }
            original = parsed
            root = object
        } else {
            original = nil
            root = JSONObject()
        }

        var hooks: JSONObject
        switch root["hooks"] {
        case nil, .null?: hooks = JSONObject()
        case .object(let object)?: hooks = object
        default: throw HookInstallError.invalidStructure(path: "settings.json", message: "\"hooks\" is not an object")
        }

        let desired = desiredEntry(command: command)
        // Strip our handlers from other events too so no Python-era hook survives; non-arrays there are not
        // ours to judge.
        for (event, value) in hooks.entries where !HookProvider.claude.events.contains(event) {
            guard case .array(let entries) = value else { continue }
            let cleaned = entries.compactMap(removingSidePulseHandlers)
            guard cleaned != entries else { continue }
            if cleaned.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = .array(cleaned)
            }
        }
        for event in HookProvider.claude.events {
            let entries: [JSONValue]
            switch hooks[event] {
            case nil, .null?: entries = []
            case .array(let items)?: entries = items
            default: throw HookInstallError.invalidStructure(path: "settings.json", message: "\"hooks.\(event)\" is not an array")
            }
            hooks[event] = .array(installEntries(entries, desired: desired))
        }
        root["hooks"] = .object(hooks)

        let updated = JSONValue.object(root)
        if let text, let original, original == updated { return text }
        return updated.serialized(pretty: true) + "\n"
    }

    public static func uninstalling(from text: String) throws -> String {
        guard !isBlank(text) else { return text }
        guard case .object(var root) = try parse(text),
              case .object(var hooks)? = root["hooks"] else { return text }

        var removedAny = false
        for (event, value) in hooks.entries {
            guard case .array(let entries) = value else { continue }
            let cleaned = entries.compactMap(removingSidePulseHandlers)
            guard cleaned != entries else { continue }
            removedAny = true
            if cleaned.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = .array(cleaned)
            }
        }
        guard removedAny else { return text }
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = .object(hooks)
        }
        return JSONValue.object(root).serialized(pretty: true) + "\n"
    }

    public static func installedEvents(in text: String) -> [String] {
        let found = handlerCommands(in: text)
            .filter { HookCommand.isCurrentStyleCommand($0.command) }
            .map(\.event)
        let known = HookProvider.claude.events.filter(found.contains)
        var others: [String] = []
        for event in found where !known.contains(event) && !others.contains(event) { others.append(event) }
        return known + others
    }

    public static func hookCLIPaths(in text: String) -> [String] {
        uniqued(handlerCommands(in: text).compactMap { HookCommand.cliPath(of: $0.command) })
    }

    public static func install(paths: SidePulsePaths, cliPath: String, dryRun: Bool, now: Date = Date()) throws -> InstallResult {
        let config = paths.claudeSettingsFile
        let command = HookCommand.command(cliPath: cliPath, provider: .claude)
        let original = try HookConfigFile.read(config)
        let updated: String
        do {
            updated = try installing(into: original, command: command)
        } catch let error as HookInstallError {
            throw error.at(config.path)
        }
        let changed = updated != original
        var backup: URL?
        if changed && !dryRun {
            backup = try HookConfigFile.write(updated, to: config, now: now)
        }
        return InstallResult(provider: .claude, configPath: config, changed: changed, backupPath: backup, dryRun: dryRun)
    }

    public static func uninstall(paths: SidePulsePaths, dryRun: Bool, now: Date = Date()) throws -> InstallResult {
        let config = paths.claudeSettingsFile
        guard let original = try HookConfigFile.read(config) else {
            return InstallResult(provider: .claude, configPath: config, changed: false, dryRun: dryRun)
        }
        let updated: String
        do {
            updated = try uninstalling(from: original)
        } catch let error as HookInstallError {
            throw error.at(config.path)
        }
        let changed = updated != original
        var backup: URL?
        if changed && !dryRun {
            backup = try HookConfigFile.write(updated, to: config, now: now)
        }
        return InstallResult(provider: .claude, configPath: config, changed: changed, backupPath: backup, dryRun: dryRun)
    }

    // MARK: - Helpers

    static func desiredEntry(command: String) -> JSONValue {
        let handler: JSONObject = [
            "type": .string("command"),
            "command": .string(command),
            "timeout": JSONValue(HookCommand.timeoutSeconds),
        ]
        return .object(["matcher": .string("*"), "hooks": .array([.object(handler)])])
    }

    static func installEntries(_ entries: [JSONValue], desired: JSONValue) -> [JSONValue] {
        let ours = entries.indices.filter { containsSidePulseHandler(entries[$0]) }
        if ours.count == 1, entries[ours[0]] == desired { return entries }
        return entries.compactMap(removingSidePulseHandlers) + [desired]
    }

    static func containsSidePulseHandler(_ entry: JSONValue) -> Bool {
        guard case .array(let handlers)? = entry["hooks"] else { return false }
        return handlers.contains { $0["command"]?.stringValue.map(HookCommand.isSidePulseCommand) ?? false }
    }

    static func removingSidePulseHandlers(_ entry: JSONValue) -> JSONValue? {
        guard case .object(var object) = entry, case .array(let handlers)? = object["hooks"] else { return entry }
        let kept = handlers.filter { !($0["command"]?.stringValue.map(HookCommand.isSidePulseCommand) ?? false) }
        if kept.count == handlers.count { return entry }
        if kept.isEmpty { return nil }
        object["hooks"] = .array(kept)
        return .object(object)
    }

    static func handlerCommands(in text: String) -> [(event: String, command: String)] {
        guard let root = try? JSONValue.parse(text), case .object(let hooks)? = root["hooks"] else { return [] }
        var out: [(String, String)] = []
        for (event, value) in hooks {
            for entry in value.arrayValue ?? [] {
                for handler in entry["hooks"]?.arrayValue ?? [] {
                    if let command = handler["command"]?.stringValue { out.append((event, command)) }
                }
            }
        }
        return out
    }

    static func parse(_ text: String) throws -> JSONValue {
        do {
            return try JSONValue.parse(text)
        } catch let error as JSONError {
            throw HookInstallError.invalidJSON(path: "settings.json", message: error.description)
        }
    }

    static func isBlank(_ text: String) -> Bool {
        text.allSatisfy { $0.isWhitespace }
    }
}
