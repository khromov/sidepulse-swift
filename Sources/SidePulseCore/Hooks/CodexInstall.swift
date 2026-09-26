import Foundation

/// Edits `~/.codex/config.toml` as text so the user's formatting and comments survive.
/// Codex keys trust by position (`<config path>:<snake_event>:<group>:<handler>`) but the hash
/// ignores it, so when an edit shifts a user's group its `[hooks.state."…"]` table is renamed.
public enum CodexHookInstaller {
    public static let managedStart = "# >>> sidepulse hooks >>>"
    public static let managedEnd = "# <<< sidepulse hooks <<<"
    static let legacyMarkers: Set<String> = ["# >>> agent-monitor hooks >>>", "# <<< agent-monitor hooks <<<"]
    /// Comment line the Python installer piled up on every reinstall.
    static let legacyCommentPrefix = "# Provider-neutral status collection"
    /// Comment written by pre-release Python installers.
    static let legacyEventLoggingComment = "Event logging hooks:"

    /// Codex 0.153 clamps Interrupt hooks to 3 s, but a uniform `timeout = 10` keeps every group the same shape.
    public static func block(command: String) -> String {
        var lines = [managedStart]
        let value = TOMLString.literalPreferred(command)
        for event in HookProvider.codex.events {
            lines += [
                "[[hooks.\(event)]]",
                "matcher = \"*\"",
                "[[hooks.\(event).hooks]]",
                "type = \"command\"",
                "command = \(value)",
                "timeout = \(HookCommand.timeoutSeconds)",
                "",
            ]
        }
        lines.append(managedEnd)
        return TOMLLines.join(lines)
    }

    /// Files flagged by `staticHookDefinitionProblem` must be rejected first, as the block cannot extend them.
    public static func installing(into text: String, command: String, configPath: String? = nil) -> String {
        let original = TOMLLines(text)
        let removal = removeSidePulse(from: original)
        var lines = removal.lines
        let anchor = removal.anchor.flatMap { $0 < lines.count && isTableBoundary(lines, at: $0) ? $0 : nil }
        insertBlock(TOMLLines(block(command: command)).lines, into: &lines, at: anchor)
        if let configPath {
            lines = reconcileTrustState(old: original, new: lines, configPath: configPath)
        }
        // Dropped trust tables can leave trailing blank lines, which would make a rerun differ.
        while let last = lines.last, TOMLLines.isBlank(last) { lines.removeLast() }
        return TOMLLines.join(lines)
    }

    public static func uninstalling(from text: String, configPath: String) -> String {
        let original = TOMLLines(text)
        let removal = removeSidePulse(from: original)
        var lines = reconcileTrustState(old: original, new: removal.lines, configPath: configPath)
        guard lines != original.lines else { return text }
        while let last = lines.last, TOMLLines.isBlank(last) { lines.removeLast() }
        return TOMLLines.join(lines)
    }

    public static func installedEvents(in text: String) -> [String] {
        let groups = hookGroups(in: TOMLLines(text))
        let found = groups.filter { $0.commands.contains(where: HookCommand.isCurrentStyleCommand) }.map(\.event)
        let known = HookProvider.codex.events.filter(found.contains)
        var others: [String] = []
        for event in found where !known.contains(event) && !others.contains(event) { others.append(event) }
        return known + others
    }

    public static func hookCLIPaths(in text: String) -> [String] {
        uniqued(hookGroups(in: TOMLLines(text)).flatMap(\.commands).compactMap(HookCommand.cliPath(of:)))
    }

    /// Only checks that a `trusted_hash` exists, since whether it still matches is Codex's call.
    public static func untrustedEvents(in text: String, configPath: String) -> [String] {
        let doc = TOMLLines(text)
        var trusted = Set<String>()
        for i in doc.lines.indices {
            guard let header = doc.headerPath(at: i), !header.isArray, header.path.count == 3,
                  header.path[0] == "hooks", header.path[1] == "state" else { continue }
            if (i + 1..<doc.nextHeader(after: i)).contains(where: { doc.keyPath(at: $0) == ["trusted_hash"] }) {
                trusted.insert(header.path[2])
            }
        }
        let prefixes = keyPrefixes(for: configPath)
        var groupIndex: [String: Int] = [:]
        var out: [String] = []
        for group in hookGroups(in: doc) {
            let g = groupIndex[group.event, default: 0]
            groupIndex[group.event] = g + 1
            for (h, command) in group.commands.enumerated() where HookCommand.isCurrentStyleCommand(command) {
                let key = "\(snakeCase(group.event)):\(g):\(h)"
                if !prefixes.contains(where: { trusted.contains($0 + key) }), !out.contains(group.event) {
                    out.append(group.event)
                }
            }
        }
        return out
    }

    public static func legacyBlockCount(in text: String) -> Int {
        hookGroups(in: TOMLLines(text)).filter { $0.commands.contains(where: HookCommand.isLegacyCommand) }.count
    }

    /// Codex enables hooks by default, and the deprecated `codex_hooks` only counts when `hooks` is absent.
    public static func hooksFeatureEnabled(in text: String) -> Bool {
        let doc = TOMLLines(text)
        guard let line = featureLine("hooks", in: doc) ?? featureLine("codex_hooks", in: doc) else { return true }
        return doc.rawValue(at: line) != "false"
    }

    /// Trust is skipped while `[features]` turns hooks off because Codex lists no hooks then.
    public static func install(paths: SidePulsePaths, cliPath: String, dryRun: Bool, trust: Bool = true, now: Date = Date()) throws -> InstallResult {
        let config = paths.codexConfigFile
        let command = HookCommand.command(cliPath: cliPath, provider: .codex)
        let original = try HookConfigFile.read(config)
        if let original, let problem = staticHookDefinitionProblem(in: TOMLLines(original)) {
            throw HookInstallError.invalidStructure(path: config.path, message: problem)
        }
        let updated = installing(into: original ?? "", command: command, configPath: config.path)
        var changed = updated != original
        var notes: [String] = []
        let legacy = legacyBlockCount(in: original ?? "")
        if legacy > 0 {
            notes.append("\(dryRun ? "would remove" : "removed") \(HookConfigFile.plural(legacy, "legacy Python hook block"))")
        }
        var backup: URL?
        if changed && !dryRun {
            backup = try HookConfigFile.write(updated, to: config, now: now)
        }
        let turnedOff = !hooksFeatureEnabled(in: updated)
        if turnedOff {
            notes.append("Codex hooks are turned off in [features]; SidePulse left that alone, "
                + "so Codex runs no hooks until you turn them back on")
        } else if !trust && !dryRun && !untrustedEvents(in: updated, configPath: config.path).isEmpty {
            notes.append("hooks not marked trusted; approve them with /hooks in Codex")
        }
        if trust && !dryRun && !turnedOff {
            if let codex = CodexTrust.findCodexBinary(environment: paths.environment) {
                do {
                    // One backup per run, and none for a file this run created.
                    let outcome = try CodexTrust.refreshConfig(configFile: config, codexPath: codex, timeout: 8,
                                                               environment: CodexTrust.childEnvironment(for: paths, codexPath: codex),
                                                               backupAt: original != nil && backup == nil ? now : nil)
                    if outcome.changed { changed = true }
                    if backup == nil { backup = outcome.backup }
                    if outcome.trusted > 0 {
                        notes.append("trusted \(HookConfigFile.plural(outcome.trusted, "Codex hook"))")
                    } else {
                        notes.append("Codex did not list the SidePulse hooks; approve them with /hooks in Codex")
                    }
                } catch {
                    notes.append("could not mark Codex hooks trusted (\(error)); approve them with /hooks in Codex")
                }
            } else {
                notes.append("Codex not found; approve hooks with /hooks in Codex")
            }
        }
        return InstallResult(provider: .codex, configPath: config, changed: changed, backupPath: backup, dryRun: dryRun, notes: notes)
    }

    public static func uninstall(paths: SidePulsePaths, dryRun: Bool, now: Date = Date()) throws -> InstallResult {
        let config = paths.codexConfigFile
        guard let original = try HookConfigFile.read(config) else {
            return InstallResult(provider: .codex, configPath: config, changed: false, dryRun: dryRun)
        }
        let updated = uninstalling(from: original, configPath: config.path)
        let changed = updated != original
        var notes: [String] = []
        let legacy = legacyBlockCount(in: original)
        if legacy > 0 {
            notes.append("\(dryRun ? "would remove" : "removed") \(HookConfigFile.plural(legacy, "legacy Python hook block"))")
        }
        var backup: URL?
        if changed && !dryRun {
            backup = try HookConfigFile.write(updated, to: config, now: now)
        }
        return InstallResult(provider: .codex, configPath: config, changed: changed, backupPath: backup, dryRun: dryRun, notes: notes)
    }

    // MARK: - Hook groups

    struct HookGroup {
        var event: String
        var range: ClosedRange<Int>
        var handlerCount: Int
        var commands: [String]
        /// Trimmed content lines, used to recognise an unchanged group.
        var signature: String

        var isSidePulse: Bool { commands.contains(where: HookCommand.isSidePulseCommand) }
    }

    static func hookGroups(in doc: TOMLLines) -> [HookGroup] {
        var groups: [HookGroup] = []
        var i = 0
        while i < doc.lines.count {
            guard let header = doc.headerPath(at: i), header.isArray, header.path.count == 2, header.path[0] == "hooks" else {
                i += 1
                continue
            }
            let event = header.path[1]
            var end = doc.nextHeader(after: i)
            var handlers = 0
            while end < doc.lines.count, let next = doc.headerPath(at: end),
                  next.path.count > 2, next.path[0] == "hooks", next.path[1] == event {
                if next.isArray && next.path.count == 3 && next.path[2] == "hooks" { handlers += 1 }
                end = doc.nextHeader(after: end)
            }
            let last = doc.contentEnd(start: i, end: end)
            var commands: [String] = []
            var signature: [String] = []
            for j in i...last where doc.kinds[j] != .blank && doc.kinds[j] != .comment {
                signature.append(doc.lines[j].trimmingCharacters(in: .whitespacesAndNewlines))
                if let command = doc.stringValue(at: j, key: "command") { commands.append(command) }
            }
            groups.append(HookGroup(event: event, range: i...last, handlerCount: handlers, commands: commands,
                                    signature: signature.joined(separator: "\n")))
            i = end
        }
        return groups
    }

    // MARK: - Removal

    struct Removal {
        var lines: [String]
        /// Where the first removed marker or group was, so reinstalling never moves the block.
        var anchor: Int?
    }

    static func removeSidePulse(from doc: TOMLLines) -> Removal {
        var remove = Set<Int>()
        var anchors = Set<Int>()
        for group in hookGroups(in: doc) where group.isSidePulse {
            remove.formUnion(group.range)
            anchors.insert(group.range.lowerBound)
        }
        for (i, line) in doc.lines.enumerated() where doc.kinds[i] == .comment {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == managedStart || trimmed == managedEnd || legacyMarkers.contains(trimmed) {
                remove.insert(i)
                anchors.insert(i)
            } else if trimmed.hasPrefix(legacyCommentPrefix) {
                remove.insert(i)
            }
        }
        if !anchors.isEmpty {
            for (i, line) in doc.lines.enumerated() where doc.kinds[i] == .comment && line.contains(legacyEventLoggingComment) {
                remove.insert(i)
            }
        }
        let firstAnchor = anchors.min()
        var anchor: Int?
        let lines = dropLines(doc.lines, remove) { index, outputCount in
            if index == firstAnchor { anchor = outputCount }
        }
        return Removal(lines: lines, anchor: anchor)
    }

    static func dropLines(_ lines: [String], _ indices: Set<Int>,
                          onRemove: (Int, Int) -> Void = { _, _ in }) -> [String] {
        var out: [String] = []
        var collapsing = false
        for (i, line) in lines.enumerated() {
            if indices.contains(i) {
                onRemove(i, out.count)
                collapsing = true
                continue
            }
            if collapsing && TOMLLines.isBlank(line) && (out.last.map(TOMLLines.isBlank) ?? true) { continue }
            collapsing = false
            out.append(line)
        }
        return out
    }

    // MARK: - Features and block placement

    static func featureLine(_ name: String, in doc: TOMLLines) -> Int? {
        var table: (path: [String], isArray: Bool)?   // nil = root table
        for i in doc.lines.indices {
            if let header = doc.headerPath(at: i) {
                table = header
                continue
            }
            guard let key = doc.keyPath(at: i) else { continue }
            if let table, !table.isArray, table.path == ["features"], key == [name] { return i }
            if table == nil && key == ["features", name] { return i }
        }
        return nil
    }

    /// Tables inserted before key/value lines would capture them, such as after a stray marker
    /// in the middle of a table.
    static func isTableBoundary(_ lines: [String], at index: Int) -> Bool {
        let doc = TOMLLines(lines: lines)
        for i in index..<lines.count {
            switch doc.kinds[i] {
            case .blank, .comment: continue
            case .header: return true
            case .content, .continuation: return false
            }
        }
        return true
    }

    /// TOML forbids extending a table or array defined inline or as a plain `[hooks.Stop]`
    /// table, so appending the block would leave a config Codex refuses to load.
    static func staticHookDefinitionProblem(in doc: TOMLLines) -> String? {
        let events = Set(HookProvider.codex.events)
        var table: (path: [String], isArray: Bool)?   // nil = root table
        for i in doc.lines.indices {
            if let header = doc.headerPath(at: i) {
                table = header
                if !header.isArray, header.path.count >= 2, header.path[0] == "hooks", events.contains(header.path[1]) {
                    return "hooks.\(header.path[1]) is a plain [table]; SidePulse can only add [[hooks.\(header.path[1])]] tables next to it"
                }
                continue
            }
            // Keys inside array tables (a group's inline `hooks = […]`) and inside
            // tables below hooks.<name> cannot redefine hooks.<name> itself.
            guard let key = doc.keyPath(at: i) else { continue }
            let base: [String]
            switch table {
            case nil: base = []
            case let t? where !t.isArray && t.path == ["hooks"]: base = ["hooks"]
            default: continue
            }
            let full = base + key
            guard full.first == "hooks" else { continue }
            if full.count == 1 { return "hooks is an inline table; SidePulse can only add [[hooks.<Event>]] tables" }
            let name = full[1]
            if events.contains(name) || name == "state" {
                return "hooks.\(name) is defined inline; SidePulse can only add [[hooks.<Event>]] and [hooks.state.\"…\"] tables"
            }
        }
        return nil
    }

    static func insertBlock(_ block: [String], into lines: inout [String], at anchor: Int?) {
        guard let anchor else {
            while let last = lines.last, TOMLLines.isBlank(last) { lines.removeLast() }
            if !lines.isEmpty { lines.append("") }
            lines += block
            return
        }
        var insertion: [String] = []
        if anchor > 0 && !TOMLLines.isBlank(lines[anchor - 1]) { insertion.append("") }
        insertion += block
        if anchor < lines.count && !TOMLLines.isBlank(lines[anchor]) { insertion.append("") }
        lines.insert(contentsOf: insertion, at: anchor)
    }

    // MARK: - Trust state

    static func snakeCase(_ event: String) -> String {
        var out = ""
        for (i, c) in event.enumerated() {
            if c.isUppercase {
                if i > 0 { out.append("_") }
                out.append(contentsOf: c.lowercased())
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// Codex may key trust by the path as given or with symlinks resolved.
    static func keyPrefixes(for configPath: String) -> [String] {
        var out: [String] = []
        for candidate in [configPath, CodexTrust.canonicalPath(configPath),
                          URL(fileURLWithPath: configPath).resolvingSymlinksInPath().path] {
            let prefix = candidate + ":"
            if !out.contains(prefix) { out.append(prefix) }
        }
        return out
    }

    /// Hooks defined in a form `hookGroups` does not see make its group indices unreliable.
    static func hasUnrecognizedHookDefinitions(_ doc: TOMLLines) -> Bool {
        var table: [String] = []
        var inGroup = false
        for i in doc.lines.indices {
            if let header = doc.headerPath(at: i) {
                table = header.path
                inGroup = header.isArray && header.path.count == 2 && header.path[0] == "hooks"
                if header.path == ["hooks"] { return true }
                if !header.isArray && header.path.count == 2 && header.path[0] == "hooks" && header.path[1] != "state" { return true }
                continue
            }
            guard let key = doc.keyPath(at: i) else { continue }
            if table.isEmpty && key.first == "hooks" { return true }
            if inGroup && key == ["hooks"] { return true }
        }
        return false
    }

    static func reconcileTrustState(old: TOMLLines, new newLines: [String], configPath: String) -> [String] {
        let new = TOMLLines(lines: newLines)
        guard !hasUnrecognizedHookDefinitions(old), !hasUnrecognizedHookDefinitions(new) else { return newLines }

        let oldGroups = Dictionary(grouping: hookGroups(in: old), by: \.event)
        let newGroups = Dictionary(grouping: hookGroups(in: new), by: \.event)
        var bySnake: [String: String] = [:]
        for event in oldGroups.keys { bySnake[snakeCase(event)] = event }

        var mapping: [String: [Int: Int]] = [:]
        for (event, olds) in oldGroups {
            let news = newGroups[event] ?? []
            let oldUser = olds.indices.filter { !olds[$0].isSidePulse }
            let newUser = news.indices.filter { !news[$0].isSidePulse }
            guard oldUser.count == newUser.count else { return newLines }
            var map: [Int: Int] = [:]
            for (o, n) in zip(oldUser, newUser) { map[o] = n }
            let oldOurs = olds.indices.filter { olds[$0].isSidePulse }
            let newOurs = news.indices.filter { news[$0].isSidePulse }
            for (o, n) in zip(oldOurs, newOurs) where olds[o].signature == news[n].signature { map[o] = n }
            mapping[event] = map
        }

        let prefixes = keyPrefixes(for: configPath)
        var drop = Set<Int>()
        var renames: [Int: String] = [:]
        var stateHeader: Int?
        for i in new.lines.indices {
            guard let header = new.headerPath(at: i), !header.isArray, header.path.count >= 2,
                  header.path[0] == "hooks", header.path[1] == "state" else { continue }
            if header.path.count == 2 { stateHeader = stateHeader ?? i; continue }
            guard header.path.count == 3, let prefix = prefixes.first(where: { header.path[2].hasPrefix($0) }) else { continue }
            let parts = header.path[2].dropFirst(prefix.count).split(separator: ":", omittingEmptySubsequences: false)
            let end = new.contentEnd(start: i, end: new.nextHeader(after: i))
            guard parts.count == 3, let g = Int(parts[1]), let h = Int(parts[2]),
                  let event = bySnake[String(parts[0])], let olds = oldGroups[event],
                  g >= 0, g < olds.count, h >= 0, h < olds[g].handlerCount,
                  let target = mapping[event]?[g] else {
                drop.formUnion(i...end)
                continue
            }
            if target != g {
                let key = "\(prefix)\(parts[0]):\(target):\(h)"
                renames[i] = "[hooks.state.\(TOMLString.basic(key))]"
            }
        }
        guard !drop.isEmpty || !renames.isEmpty else { return newLines }

        var lines = newLines
        for (i, header) in renames { lines[i] = header }
        if !drop.isEmpty, let s = stateHeader {
            let body = new.contentEnd(start: s, end: new.nextHeader(after: s))
            let remainingState = new.lines.indices.contains { i in
                guard !drop.contains(i), let h = new.headerPath(at: i) else { return false }
                return h.path.count > 2 && h.path[0] == "hooks" && h.path[1] == "state"
            }
            if body == s && !remainingState { drop.insert(s) }
        }
        return dropLines(lines, drop)
    }
}
