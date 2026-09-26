import Foundation

/// Codex: `~/.codex/config.toml`, edited as text.
/// Managed block (event order = HookProvider.codex.events):
/// ```
/// # >>> sidepulse hooks >>>
/// [[hooks.SessionStart]]
/// matcher = "*"
/// [[hooks.SessionStart.hooks]]
/// type = "command"
/// command = '''CMD'''
/// timeout = 10
///
/// ...
/// # <<< sidepulse hooks <<<
/// ```
/// Install: remove our managed block, legacy `# >>> agent-monitor hooks >>>` markers,
/// the stray `# Provider-neutral status collection...` comment lines, and any
/// `[[hooks.<Event>]]` block (up to the next non-`[[hooks.<Event>.hooks]]` table
/// header) containing a SidePulse command; ensure `[features]\nhooks = true`
/// (an explicit `hooks = false` is the user's choice and stays; `install` notes it);
/// append the block. Uninstall: remove the same things (leave `[features]`), and remove
/// `[hooks.state."<config path>:<event>:N:M"]` tables that belong to removed hooks.
/// Idempotent: reinstall on an installed file returns identical text.
///
/// Details of the text edit:
/// - A block ends at its last non-blank, non-comment line, so a user comment that
///   introduces the next table survives. Blank lines left behind by a removal are
///   collapsed to one.
/// - The new block goes where the old managed block (or the first removed
///   SidePulse block) was, otherwise at the end of the file, separated by one
///   blank line. Reinstalling therefore never moves it. The old position is
///   only reused when a table header (not a key/value line) follows it, so the
///   block can never capture keys of the table above.
/// - `hooks = true` goes after the last key of `[features]`; with root dotted
///   keys (`features.x = …`) it is added as `features.hooks = true`, since a
///   `[features]` header would redefine the table. An inline
///   `features = { … }` is left alone.
/// - Hook events defined inline or as plain tables (`[hooks]` + `Stop = […]`,
///   `[hooks.Stop]`) cannot take `[[hooks.Stop]]` tables; `install` throws
///   `HookInstallError.invalidStructure` for such files.
/// - Codex keys hook trust as `<config path>:<snake_event>:<group>:<handler>`
///   and the hash does not depend on the position (verified with codex-cli
///   0.153.4). When `configPath` is given, `[hooks.state."…"]` tables for this
///   file are kept in step with the edit: tables of removed hooks and orphans
///   (no hook at that position) are dropped, and tables of the user's own hooks
///   are renamed when their group index shifts, so the user's trusted hooks stay
///   trusted. If the file defines hooks in a form we do not parse (inline arrays,
///   a `[hooks]` table), the state tables are left alone.
public enum CodexHookInstaller {
    public static let managedStart = "# >>> sidepulse hooks >>>"
    public static let managedEnd = "# <<< sidepulse hooks <<<"
    static let legacyMarkers: Set<String> = ["# >>> agent-monitor hooks >>>", "# <<< agent-monitor hooks <<<"]
    /// Comment line the Python installer piled up on every reinstall.
    static let legacyCommentPrefix = "# Provider-neutral status collection"
    /// Comment written by pre-release Python installers.
    static let legacyEventLoggingComment = "Event logging hooks:"

    /// The managed block text (ends with a newline). Codex 0.153 clamps an
    /// Interrupt hook's timeout to 3 s (it reports `timeoutSec: 3`); the uniform
    /// `timeout = 10` is still written so every group has the same shape.
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

    /// Pure transform. With `configPath` (the absolute path Codex reports as the
    /// hooks' `sourcePath`), trust-state tables are kept consistent (see above).
    /// A file that defines hook events statically (see
    /// `staticHookDefinitionProblem`) cannot take the block; `install` refuses it.
    public static func installing(into text: String, command: String, configPath: String? = nil) -> String {
        let original = TOMLLines(text)
        let removal = removeSidePulse(from: original)
        var lines = removal.lines
        var anchor = removal.anchor.flatMap { $0 < lines.count && isTableBoundary(lines, at: $0) ? $0 : nil }
        ensureHooksFeature(&lines, anchor: &anchor)
        insertBlock(TOMLLines(block(command: command)).lines, into: &lines, at: anchor)
        if let configPath {
            lines = reconcileTrustState(old: original, new: lines, configPath: configPath)
        }
        // Dropped trust tables after the block can leave blank lines at the end;
        // the file always ends right after its last line so a rerun is a no-op.
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

    /// Events (in `HookProvider.codex.events` order, then others) with a group
    /// holding a current-style SidePulse command.
    public static func installedEvents(in text: String) -> [String] {
        let groups = hookGroups(in: TOMLLines(text))
        let found = groups.filter { $0.commands.contains(where: HookCommand.isCurrentStyleCommand) }.map(\.event)
        let known = HookProvider.codex.events.filter(found.contains)
        var others: [String] = []
        for event in found where !known.contains(event) && !others.contains(event) { others.append(event) }
        return known + others
    }

    /// Distinct CLI paths called by current-style SidePulse commands.
    public static func hookCLIPaths(in text: String) -> [String] {
        uniqued(hookGroups(in: TOMLLines(text)).flatMap(\.commands).compactMap(HookCommand.cliPath(of:)))
    }

    /// Events whose SidePulse hook has no `[hooks.state."<key>"]` table with a
    /// `trusted_hash` (keys as in the type documentation). Codex does not run such a
    /// hook until the user approves it with /hooks or `install` refreshes trust.
    /// Only presence is checked; whether the hash still matches is Codex's call.
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

    /// Number of `[[hooks.<Event>]]` groups holding a Python-era SidePulse command.
    public static func legacyBlockCount(in text: String) -> Int {
        hookGroups(in: TOMLLines(text)).filter { $0.commands.contains(where: HookCommand.isLegacyCommand) }.count
    }

    /// `hooks = true` in `[features]` (or a root-level `features.hooks = true`).
    public static func hooksFeatureEnabled(in text: String) -> Bool {
        let doc = TOMLLines(text)
        guard let location = hooksFeatureLine(in: doc) else { return false }
        return doc.rawValue(at: location) == "true"
    }

    /// Writes config (atomic + backup), then (unless dryRun or `trust == false`)
    /// runs `CodexTrust.refresh`. With `[features] hooks = false` trust is skipped
    /// (Codex lists no hooks then) and a note says hooks are off in Codex.
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
        let updatedDoc = TOMLLines(updated)
        let turnedOff = hooksFeatureLine(in: updatedDoc).map { updatedDoc.rawValue(at: $0) == "false" } ?? false
        if turnedOff {
            notes.append("Codex hooks are turned off ([features] hooks = false); SidePulse left that alone, "
                + "so Codex runs no hooks until you set it to true")
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

    /// One `[[hooks.<Event>]]` matcher group with its `[[hooks.<Event>.hooks]]`
    /// handler tables.
    struct HookGroup {
        var event: String
        /// Header line through the last content line of the group.
        var range: ClosedRange<Int>
        var handlerCount: Int
        var commands: [String]
        /// Content lines, trimmed; used to recognise an unchanged group.
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
        /// Output index where the first removed marker or SidePulse group was.
        var anchor: Int?
    }

    /// Removes our managed markers, the legacy Python markers and stray
    /// comments, and every hook group holding a SidePulse command. Blank lines
    /// left at a removal site are collapsed.
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

    /// Drops the lines at `indices`. After each removal, blank lines are skipped
    /// while the output is empty or already ends with a blank line.
    /// `onRemove(index, outputCount)` reports where each removed line was.
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

    /// The `hooks = …` line inside `[features]`, or a root-level `features.hooks`.
    static func hooksFeatureLine(in doc: TOMLLines) -> Int? {
        var table: (path: [String], isArray: Bool)?   // nil = root table
        for i in doc.lines.indices {
            if let header = doc.headerPath(at: i) {
                table = header
                continue
            }
            guard let key = doc.keyPath(at: i) else { continue }
            if let table, !table.isArray, table.path == ["features"], key == ["hooks"] { return i }
            if table == nil && key == ["features", "hooks"] { return i }
        }
        return nil
    }

    /// Ensures `[features] hooks = true`, keeping `anchor` pointing at the same line.
    /// An explicit `hooks = false` is left as it is: turning it on would also enable
    /// every other hook the user switched off with it, and uninstall could not undo it.
    static func ensureHooksFeature(_ lines: inout [String], anchor: inout Int?) {
        let doc = TOMLLines(lines: lines)
        if let i = hooksFeatureLine(in: doc) {
            guard doc.rawValue(at: i) != "true", doc.rawValue(at: i) != "false" else { return }
            let indent = String(lines[i].prefix(while: { $0 == " " || $0 == "\t" }))
            let key = doc.keyPath(at: i) == ["hooks"] ? "hooks" : "features.hooks"
            lines[i] = "\(indent)\(key) = true"
            return
        }
        if let header = lines.indices.first(where: { doc.headerPath(at: $0).map { !$0.isArray && $0.path == ["features"] } ?? false }) {
            let insertAt = doc.contentEnd(start: header, end: doc.nextHeader(after: header)) + 1
            lines.insert("hooks = true", at: insertAt)
            if let a = anchor, a >= insertAt { anchor = a + 1 }
            return
        }
        for i in lines.indices {
            if case .header = doc.kinds[i] { break }
            guard let key = doc.keyPath(at: i), key.first == "features" else { continue }
            // A root-level `features = { ... }` inline table cannot take another
            // key without rewriting it; leave it to the user.
            if key.count == 1 { return }
            // Root dotted keys (`features.x = …`) already define the table, so a
            // `[features]` header would be a duplicate; add a sibling key instead.
            // Inserting before the first one keeps it clear of multi-line values.
            lines.insert("features.hooks = true", at: i)
            if let a = anchor, a >= i { anchor = a + 1 }
            return
        }
        while let last = lines.last, TOMLLines.isBlank(last) { lines.removeLast() }
        if let a = anchor, a >= lines.count { anchor = nil }
        if !lines.isEmpty { lines.append("") }
        lines += ["[features]", "hooks = true"]
    }

    /// True when a table header (or nothing but comments and blank lines) comes
    /// next at `index`, so tables inserted there cannot capture key/value lines
    /// that belong to the table above (for example after a stray marker comment
    /// in the middle of a table, or above root keys).
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

    /// Why `[[hooks.<Event>]]` tables (and `[hooks.state."…"]` trust tables)
    /// cannot be added to this file, or nil. TOML forbids extending a table or
    /// array that is defined inline (`hooks = {…}`, `[hooks]` + `Stop = […]`,
    /// `hooks.Stop = […]`) or as a plain table (`[hooks.Stop]`), so appending the
    /// block would leave a config Codex refuses to load.
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

    /// Inserts the managed block at `anchor` with one blank line on each side, or
    /// appends it after one blank line.
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

    /// Codex's snake_case event name used in hook keys (`PreToolUse` → `pre_tool_use`).
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

    /// Key prefixes Codex may use for `configPath` (as given, and with symlinks
    /// resolved), each ending in ":".
    static func keyPrefixes(for configPath: String) -> [String] {
        var out: [String] = []
        for candidate in [configPath, CodexTrust.canonicalPath(configPath),
                          URL(fileURLWithPath: configPath).resolvingSymlinksInPath().path] {
            let prefix = candidate + ":"
            if !out.contains(prefix) { out.append(prefix) }
        }
        return out
    }

    /// True when hooks are also defined in a form `hookGroups` does not see, so
    /// group indices cannot be trusted.
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

    /// Rewrites this config's `[hooks.state."<path>:<event>:G:H"]` tables to
    /// match the hook groups in `new` (see the type documentation).
    static func reconcileTrustState(old: TOMLLines, new newLines: [String], configPath: String) -> [String] {
        let new = TOMLLines(lines: newLines)
        guard !hasUnrecognizedHookDefinitions(old), !hasUnrecognizedHookDefinitions(new) else { return newLines }

        let oldGroups = Dictionary(grouping: hookGroups(in: old), by: \.event)
        let newGroups = Dictionary(grouping: hookGroups(in: new), by: \.event)
        var bySnake: [String: String] = [:]
        for event in oldGroups.keys { bySnake[snakeCase(event)] = event }

        // old (event, group index) → new group index
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
        // An emptied `[hooks.state]` table goes too, once nothing hangs off it.
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
