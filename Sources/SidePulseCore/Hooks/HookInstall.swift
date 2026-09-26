import Foundation

public enum HookProvider: String, CaseIterable, Sendable {
    case claude
    case codex

    public var label: String { self == .claude ? "Claude Code" : "Codex" }

    /// Events registered in the agent config.
    public var events: [String] {
        switch self {
        case .claude:
            return ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
                    "PermissionRequest", "Notification", "PreCompact", "PostCompact", "SubagentStop", "Stop", "SessionEnd"]
        case .codex:
            return ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
                    "PreCompact", "PostCompact", "SubagentStart", "SubagentStop", "Stop", "Interrupt"]
        }
    }

    public func configFile(_ paths: SidePulsePaths) -> URL {
        self == .claude ? paths.claudeSettingsFile : paths.codexConfigFile
    }

    /// The agent's config directory (~/.claude, ~/.codex); used to decide whether
    /// the agent looks installed.
    public func configDir(_ paths: SidePulsePaths) -> URL {
        self == .claude ? paths.claudeDir : paths.codexDir
    }
}

public enum HookCommand {
    /// Timeout (seconds) written next to every hook we install. The hook itself
    /// finishes in milliseconds; this only bounds a wedged process.
    public static let timeoutSeconds = 10

    /// Substrings that identify a SidePulse hook command, current or Python-era.
    /// Deliberately never a log path or a `>>` redirect: a user's own
    /// `say done >> /tmp/x.log` hook must never look like ours.
    static let markers = [
        "hook-log --provider",     // current Swift form (and every Python CLI form)
        "hook_entry.py",           // Python installer (non-frozen)
        "sidepulse.cursor_hook",   // Python legacy Cursor entry
        "agent-monitor hook-log",  // Python frozen-app / agent-monitor CLI
        "agent_monitor hook-log",  // pre-rename `python -m agent_monitor hook-log`
        "sidepulse hook-log",      // `sidepulse hook-log` / `python -m sidepulse hook-log`
    ]

    /// `<quoted cli> hook-log --provider <p> ; true` — `; true` makes the hook fail
    /// open. The CLI path is POSIX-shell-quoted only when needed.
    public static func command(cliPath: String, provider: HookProvider) -> String {
        "\(shellQuote(cliPath)) hook-log --provider \(provider.rawValue) ; true"
    }

    /// Single-quote shell quoting when the string contains anything outside
    /// `[A-Za-z0-9_@%+=:,./-]` (Python shlex.quote semantics).
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

    /// True for our commands and every Python-era SidePulse hook command:
    /// contains "hook-log --provider", "hook_entry.py", "sidepulse.cursor_hook",
    /// "agent-monitor hook-log" (or the pre-rename "agent_monitor hook-log") or
    /// "sidepulse hook-log". Never matches on log paths or `>>` redirects.
    public static func isSidePulseCommand(_ command: String) -> Bool {
        markers.contains { command.contains($0) }
    }

    /// True only for the current Swift-style command (contains "hook-log --provider"
    /// and does NOT contain "hook_entry.py"/"agent-monitor"): exactly the shape
    /// `command(cliPath:provider:)` writes, one shell word followed by
    /// ` hook-log --provider <claude|codex> ; true`. Every Python form fails it
    /// (`agent-monitor hook-log …`, `-m sidepulse hook-log …` and every `--log`),
    /// and so does a foreign command that merely embeds ours
    /// (`curl … | sh ; /x/sidepulse hook-log …`), which Codex trust must never
    /// approve. A CLI path that happens to contain `agent-monitor` still passes.
    public static func isCurrentStyleCommand(_ command: String) -> Bool {
        cliPath(of: command) != nil
    }

    /// The CLI a current-style command runs (its first word, unquoted), else nil.
    public static func cliPath(of command: String) -> String? {
        for provider in HookProvider.allCases {
            let suffix = " hook-log --provider \(provider.rawValue) ; true"
            guard command.hasSuffix(suffix) else { continue }
            return unquotedShellWord(String(command.dropLast(suffix.count)))
        }
        return nil
    }

    /// The string `shellQuote` turned into `word`, or nil when `word` is not exactly
    /// such a single literal shell word.
    static func unquotedShellWord(_ word: String) -> String? {
        guard !word.isEmpty else { return nil }
        if shellQuote(word) == word { return word }
        guard word.count >= 2, word.hasPrefix("'"), word.hasSuffix("'") else { return nil }
        let inner = String(word.dropFirst().dropLast()).replacingOccurrences(of: "'\"'\"'", with: "'")
        return shellQuote(inner) == word ? inner : nil
    }

    /// A SidePulse command that is not current-style (Python-era).
    public static func isLegacyCommand(_ command: String) -> Bool {
        isSidePulseCommand(command) && !isCurrentStyleCommand(command)
    }
}

public struct InstallResult: Sendable, Equatable {
    public var provider: HookProvider
    public var configPath: URL
    public var changed: Bool
    public var backupPath: URL?
    public var dryRun: Bool
    /// Extra notes (e.g. "removed 12 legacy Python hooks", "trusted 11 Codex hooks",
    /// "Codex not found; approve hooks with /hooks in Codex").
    public var notes: [String]

    public init(provider: HookProvider, configPath: URL, changed: Bool, backupPath: URL? = nil, dryRun: Bool, notes: [String] = []) {
        self.provider = provider; self.configPath = configPath; self.changed = changed
        self.backupPath = backupPath; self.dryRun = dryRun; self.notes = notes
    }
}

/// Install/uninstall dispatch shared by the CLI and the app.
public enum HookInstaller {
    /// Runs the provider's installer. Installing needs `cliPath` (`HookCLIPath.resolve`);
    /// nil throws `HookCLINotFound` rather than writing hooks that run nothing.
    public static func perform(_ action: HookAction, provider: HookProvider, paths: SidePulsePaths, cliPath: String?,
                               dryRun: Bool = false, trust: Bool = true) throws -> InstallResult {
        switch (action, provider) {
        case (.uninstall, .claude): return try ClaudeHookInstaller.uninstall(paths: paths, dryRun: dryRun)
        case (.uninstall, .codex): return try CodexHookInstaller.uninstall(paths: paths, dryRun: dryRun)
        case (.install, _):
            guard let cliPath else { throw HookCLINotFound() }
            return provider == .claude
                ? try ClaudeHookInstaller.install(paths: paths, cliPath: cliPath, dryRun: dryRun)
                : try CodexHookInstaller.install(paths: paths, cliPath: cliPath, dryRun: dryRun, trust: trust)
        }
    }
}

/// Distinct values in first-seen order.
func uniqued(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
}

/// Errors raised by the hook installers. The config file is never touched when
/// one of these is thrown.
public enum HookInstallError: Error, Equatable, CustomStringConvertible {
    /// The config file is not valid JSON.
    case invalidJSON(path: String, message: String)
    /// The config parses but has a shape we refuse to rewrite (for example
    /// `"hooks": []`), because rewriting it would destroy user data.
    case invalidStructure(path: String, message: String)
    /// The config file exists but could not be read.
    case unreadable(path: String, message: String)

    public var description: String {
        switch self {
        case .invalidJSON(let path, let message):
            return "\(path) is not valid JSON (\(message)); fix or move it, then retry"
        case .invalidStructure(let path, let message):
            return "\(path): \(message); fix it by hand, then retry"
        case .unreadable(let path, let message):
            return "could not read \(path): \(message)"
        }
    }

    /// Same error, attributed to `path` (the pure transforms do not know it).
    func at(_ path: String) -> HookInstallError {
        switch self {
        case .invalidJSON(_, let m): return .invalidJSON(path: path, message: m)
        case .invalidStructure(_, let m): return .invalidStructure(path: path, message: m)
        case .unreadable(_, let m): return .unreadable(path: path, message: m)
        }
    }
}

/// Shared file plumbing for the installers.
enum HookConfigFile {
    /// Returns the file's text, nil when it does not exist. Throws when it exists
    /// but cannot be read or is not UTF-8 (so we never mistake an unreadable file
    /// for a new one, and never write back a lossy decoding of it).
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

    /// Backs up (when the file exists) and atomically writes `text`.
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

/// Claude Code: `~/.claude/settings.json` (order-preserving edit via JSONValue).
/// Install: for each event, drop SidePulse handlers (current + legacy), drop
/// entries left with no handlers, then append
/// `{"matcher":"*","hooks":[{"type":"command","command":CMD,"timeout":10}]}`.
/// Uninstall: remove SidePulse handlers from all events; remove empty events; remove
/// `hooks` if empty. Non-dict entries / entries without a `hooks` array are kept
/// untouched. Invalid JSON → throws (file untouched). Output: pretty 2-space JSON +
/// "\n". Writes are atomic, with a `.bak.<stamp>` backup when the file changed and
/// existed.
///
/// When the transform does not change the parsed document, the original text is
/// returned byte-for-byte (the user's formatting is only rewritten when we
/// actually change something). An event that already holds exactly our entry,
/// and no other SidePulse handler, is left in place, so reinstalling never
/// reorders a user's hooks. SidePulse handlers under events outside the 12 are
/// removed too (as uninstall does), so no Python-era hook survives an install.
public enum ClaudeHookInstaller {
    /// Pure transform. `text` nil/empty = new file.
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
        // Other events: only strip our handlers (non-arrays are not ours to judge).
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

    /// Events whose entries contain a current-style SidePulse command. Known
    /// Claude events come first in `HookProvider.claude.events` order, then any
    /// other event in file order. Invalid JSON → [].
    public static func installedEvents(in text: String) -> [String] {
        let found = handlerCommands(in: text)
            .filter { HookCommand.isCurrentStyleCommand($0.command) }
            .map(\.event)
        let known = HookProvider.claude.events.filter(found.contains)
        var others: [String] = []
        for event in found where !known.contains(event) && !others.contains(event) { others.append(event) }
        return known + others
    }

    /// Distinct CLI paths called by current-style SidePulse commands.
    public static func hookCLIPaths(in text: String) -> [String] {
        uniqued(handlerCommands(in: text).compactMap { HookCommand.cliPath(of: $0.command) })
    }

    /// Count of legacy (Python-era) SidePulse handlers.
    public static func legacyHandlerCount(in text: String) -> Int {
        handlerCommands(in: text).filter { HookCommand.isLegacyCommand($0.command) }.count
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
        var notes: [String] = []
        let legacy = original.map(legacyHandlerCount(in:)) ?? 0
        if legacy > 0 {
            notes.append("\(dryRun ? "would remove" : "removed") \(HookConfigFile.plural(legacy, "legacy Python hook"))")
        }
        var backup: URL?
        if changed && !dryRun {
            backup = try HookConfigFile.write(updated, to: config, now: now)
        }
        return InstallResult(provider: .claude, configPath: config, changed: changed, backupPath: backup, dryRun: dryRun, notes: notes)
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
        var notes: [String] = []
        let legacy = legacyHandlerCount(in: original)
        if legacy > 0 {
            notes.append("\(dryRun ? "would remove" : "removed") \(HookConfigFile.plural(legacy, "legacy Python hook"))")
        }
        var backup: URL?
        if changed && !dryRun {
            backup = try HookConfigFile.write(updated, to: config, now: now)
        }
        return InstallResult(provider: .claude, configPath: config, changed: changed, backupPath: backup, dryRun: dryRun, notes: notes)
    }

    // MARK: - Helpers

    /// `{"matcher":"*","hooks":[{"type":"command","command":CMD,"timeout":10}]}`
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

    /// The entry without SidePulse handlers; nil when nothing else is left.
    /// Anything that is not an object with a `hooks` array is returned unchanged.
    static func removingSidePulseHandlers(_ entry: JSONValue) -> JSONValue? {
        guard case .object(var object) = entry, case .array(let handlers)? = object["hooks"] else { return entry }
        let kept = handlers.filter { !($0["command"]?.stringValue.map(HookCommand.isSidePulseCommand) ?? false) }
        if kept.count == handlers.count { return entry }
        if kept.isEmpty { return nil }
        object["hooks"] = .array(kept)
        return .object(object)
    }

    /// (event, command) for every handler with a string command.
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
