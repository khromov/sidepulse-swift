import Foundation

/// Edits `~/.gemini/config/hooks.json` in place, managing a `"sidepulse"` named hook while preserving other
/// named hooks and any `"enabled": false` toggle the user sets.
public enum AntigravityHookInstaller {
    public static let hookName = "sidepulse"
    /// Antigravity expects a `{matcher, hooks}` wrapper for tool events and a flat handler array for the rest.
    public static let groupedEvents: Set<String> = ["PreToolUse", "PostToolUse"]

    public static func installing(into text: String?, command: String) throws -> String {
        let original: JSONValue?
        var root: JSONObject
        if let text, !ClaudeHookInstaller.isBlank(text) {
            let parsed = try parse(text)
            guard case .object(let object) = parsed else {
                throw HookInstallError.invalidStructure(path: "hooks.json", message: "the top level is not a JSON object")
            }
            original = parsed
            root = object
        } else {
            original = nil
            root = JSONObject()
        }

        // Strip stray SidePulse handlers from other named hooks so hooks never run twice.
        for (name, value) in root.entries where name != hookName {
            guard case .object(let other) = value else { continue }
            let cleaned = removingSidePulse(fromNamedHook: other, keepEnabledOnly: true)
            guard cleaned.changed else { continue }
            if cleaned.spec.isEmpty {
                root.removeValue(forKey: name)
            } else {
                root[name] = .object(cleaned.spec)
            }
        }

        var spec: JSONObject
        switch root[hookName] {
        case nil, .null?: spec = JSONObject()
        case .object(let object)?: spec = object
        default: throw HookInstallError.invalidStructure(path: "hooks.json", message: "\"\(hookName)\" is not an object")
        }

        for (event, value) in spec.entries where event != "enabled" && !HookProvider.antigravity.events.contains(event) {
            guard case .array(let entries) = value else { continue }
            let cleaned = entries.compactMap(removingSidePulseHandlers)
            guard cleaned != entries else { continue }
            if cleaned.isEmpty {
                spec.removeValue(forKey: event)
            } else {
                spec[event] = .array(cleaned)
            }
        }

        for event in HookProvider.antigravity.events {
            let entries: [JSONValue]
            switch spec[event] {
            case nil, .null?: entries = []
            case .array(let items)?: entries = items
            default:
                throw HookInstallError.invalidStructure(path: "hooks.json",
                                                        message: "\"\(hookName).\(event)\" is not an array")
            }
            spec[event] = .array(installEntries(entries, desired: desiredEntry(event: event, command: command)))
        }
        root[hookName] = .object(spec)

        let updated = JSONValue.object(root)
        if let text, let original, original == updated { return text }
        return updated.serialized(pretty: true) + "\n"
    }

    public static func uninstalling(from text: String) throws -> String {
        guard !ClaudeHookInstaller.isBlank(text) else { return text }
        guard case .object(var root) = try parse(text) else { return text }

        var removedAny = false
        for (name, value) in root.entries {
            guard case .object(let spec) = value else { continue }
            let cleaned = removingSidePulse(fromNamedHook: spec, keepEnabledOnly: name != hookName)
            guard cleaned.changed else { continue }
            removedAny = true
            if cleaned.spec.isEmpty {
                root.removeValue(forKey: name)
            } else {
                root[name] = .object(cleaned.spec)
            }
        }
        guard removedAny else { return text }
        return JSONValue.object(root).serialized(pretty: true) + "\n"
    }

    public static func installedEvents(in text: String) -> [String] {
        let found = handlerCommands(in: text)
            .filter { HookCommand.isCurrentStyleCommand($0.command) }
            .map(\.event)
        let known = HookProvider.antigravity.events.filter(found.contains)
        var others: [String] = []
        for event in found where !known.contains(event) && !others.contains(event) { others.append(event) }
        return known + others
    }

    public static func hookCLIPaths(in text: String) -> [String] {
        uniqued(handlerCommands(in: text).compactMap { HookCommand.cliPath(of: $0.command) })
    }

    public static func hooksDisabled(in text: String) -> Bool {
        guard let root = try? JSONValue.parse(text), case .object(let hooks) = root else { return false }
        if hooks[hookName]?["enabled"] == .bool(false) { return true }
        let ours = handlerCommands(in: text).filter { HookCommand.isCurrentStyleCommand($0.command) }
        return !ours.isEmpty && ours.allSatisfy { !$0.enabled }
    }

    /// Avoids bare `~/.gemini` because Gemini CLI also uses it.
    public static func isDetected(paths: SidePulsePaths) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: paths.antigravityHooksFile.path, isDirectory: &isDir), !isDir.boolValue { return true }
        for dir in paths.antigravityDataDirs {
            if fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue { return true }
        }
        let userApp = paths.home.appendingPathComponent("Applications/Antigravity.app")
        if fm.fileExists(atPath: userApp.path, isDirectory: &isDir), isDir.boolValue { return true }
        return findBinary(paths: paths) != nil
    }

    public static func findBinary(paths: SidePulsePaths) -> String? {
        let dirs = [
            paths.home.appendingPathComponent(".antigravity/antigravity/bin").path,
            paths.home.appendingPathComponent(".local/bin").path,
        ] + (paths.environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        return dirs.map { $0 + "/agy" }.first { path in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
                && FileManager.default.isExecutableFile(atPath: path)
        }
    }

    public static func install(paths: SidePulsePaths, cliPath: String, dryRun: Bool, now: Date = Date()) throws -> InstallResult {
        let config = paths.antigravityHooksFile
        let command = HookCommand.command(cliPath: cliPath, provider: .antigravity)
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
        let notes = hooksDisabled(in: updated)
            ? ["Antigravity hooks are turned off by \"enabled\": false on \"\(hookName)\"; SidePulse left that alone, "
                + "so Antigravity runs no SidePulse hooks until you turn them back on"]
            : []
        return InstallResult(provider: .antigravity, configPath: config, changed: changed, backupPath: backup,
                             dryRun: dryRun, notes: notes)
    }

    public static func uninstall(paths: SidePulsePaths, dryRun: Bool, now: Date = Date()) throws -> InstallResult {
        let config = paths.antigravityHooksFile
        guard let original = try HookConfigFile.read(config) else {
            return InstallResult(provider: .antigravity, configPath: config, changed: false, dryRun: dryRun)
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
        return InstallResult(provider: .antigravity, configPath: config, changed: changed, backupPath: backup, dryRun: dryRun)
    }

    // MARK: - Helpers

    static func desiredEntry(event: String, command: String) -> JSONValue {
        let handler: JSONObject = [
            "type": .string("command"),
            "command": .string(command),
            "timeout": JSONValue(HookCommand.timeoutSeconds),
        ]
        if groupedEvents.contains(event) {
            return .object(["matcher": .string("*"), "hooks": .array([.object(handler)])])
        }
        return .object(handler)
    }

    static func installEntries(_ entries: [JSONValue], desired: JSONValue) -> [JSONValue] {
        let ours = entries.indices.filter { containsSidePulseHandler(entries[$0]) }
        if ours.count == 1, entries[ours[0]] == desired { return entries }
        return entries.compactMap(removingSidePulseHandlers) + [desired]
    }

    static func containsSidePulseHandler(_ entry: JSONValue) -> Bool {
        if let command = entry["command"]?.stringValue, HookCommand.isSidePulseCommand(command) { return true }
        guard case .array(let handlers)? = entry["hooks"] else { return false }
        return handlers.contains { $0["command"]?.stringValue.map(HookCommand.isSidePulseCommand) ?? false }
    }

    static func removingSidePulseHandlers(_ entry: JSONValue) -> JSONValue? {
        if let command = entry["command"]?.stringValue, HookCommand.isSidePulseCommand(command) { return nil }
        guard case .object(var object) = entry, case .array(let handlers)? = object["hooks"] else { return entry }
        let kept = handlers.filter { !($0["command"]?.stringValue.map(HookCommand.isSidePulseCommand) ?? false) }
        if kept.count == handlers.count { return entry }
        if kept.isEmpty { return nil }
        object["hooks"] = .array(kept)
        return .object(object)
    }

    private static func removingSidePulse(fromNamedHook spec: JSONObject,
                                          keepEnabledOnly: Bool) -> (spec: JSONObject, changed: Bool) {
        var updated = spec
        var changed = false
        for (event, value) in spec.entries where event != "enabled" {
            guard case .array(let entries) = value else { continue }
            let cleaned = entries.compactMap(removingSidePulseHandlers)
            guard cleaned != entries else { continue }
            changed = true
            if cleaned.isEmpty {
                updated.removeValue(forKey: event)
            } else {
                updated[event] = .array(cleaned)
            }
        }
        if changed && !keepEnabledOnly && updated.entries.allSatisfy({ $0.0 == "enabled" }) {
            updated = JSONObject()
        }
        return (updated, changed)
    }

    static func handlerCommands(in text: String) -> [(hookName: String, event: String, command: String, enabled: Bool)] {
        guard let root = try? JSONValue.parse(text), case .object(let hooks) = root else { return [] }
        var out: [(String, String, String, Bool)] = []
        for (name, specValue) in hooks {
            guard case .object(let spec) = specValue else { continue }
            let enabled = spec["enabled"] != .bool(false)
            for (event, value) in spec where event != "enabled" {
                let entries = value.arrayValue ?? []
                if groupedEvents.contains(event) {
                    for entry in entries {
                        for handler in entry["hooks"]?.arrayValue ?? [] {
                            if let command = handler["command"]?.stringValue { out.append((name, event, command, enabled)) }
                        }
                    }
                } else {
                    for entry in entries {
                        if let command = entry["command"]?.stringValue { out.append((name, event, command, enabled)) }
                    }
                }
            }
        }
        return out
    }

    static func parse(_ text: String) throws -> JSONValue {
        do {
            return try JSONValue.parse(text)
        } catch let error as JSONError {
            throw HookInstallError.invalidJSON(path: "hooks.json", message: error.description)
        }
    }
}
