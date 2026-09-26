import Foundation

/// Display-name helpers (spec collector §7).
///
/// Lengths and cut points count Unicode scalars, like Python's code points, so
/// labels match the Python collector exactly.
public enum DisplayNames {
    /// Display names are truncated to this many code points (plus "...").
    public static let displayNameLimit = 96
    /// Prompt titles and Codex thread names are truncated to this many code points.
    public static let titleLimit = 72

    /// The provider word in fallback row labels such as "Claude agent 1234abcd"
    /// (Python `provider_label`): codex→"Codex", claude→"Claude", else Title-case.
    /// The menu's provider name is `HookProvider.label` ("Claude Code").
    public static func fallbackProviderLabel(_ provider: String) -> String {
        switch provider {
        case "codex": return "Codex"
        case "claude": return "Claude"
        default: return pythonTitle(provider)
        }
    }

    /// Python `str.title()`: a cased letter is upper-cased when the previous
    /// character is not cased, lower-cased otherwise ("my-agent2x" → "My-Agent2X").
    static func pythonTitle(_ text: String) -> String {
        var out = ""
        var previousCased = false
        for scalar in text.unicodeScalars {
            let properties = scalar.properties
            if properties.isCased {
                out += previousCased ? properties.lowercaseMapping : properties.titlecaseMapping
                previousCased = true
            } else {
                out.unicodeScalars.append(scalar)
                previousCased = false
            }
        }
        return out
    }

    /// Python `truncate_text`: unchanged if count <= n; else cut to n-1, rstrip, back
    /// off to the last space/comma/semicolon if it is at >= n/2, append "...".
    public static func truncate(_ text: String, _ limit: Int) -> String {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count > limit else { return text }
        var trimmed = rstripped(scalars.prefix(max(0, limit - 1)))
        if let boundary = trimmed.lastIndex(where: { $0 == " " || $0 == "," || $0 == ";" }), boundary >= limit / 2 {
            trimmed = rstripped(trimmed[..<boundary])
        }
        return String(String.UnicodeScalarView(trimmed)) + "..."
    }

    private static func rstripped(_ scalars: ArraySlice<Unicode.Scalar>) -> ArraySlice<Unicode.Scalar> {
        var end = scalars.endIndex
        while end > scalars.startIndex, PyText.isSpace(scalars[end - 1]) { end -= 1 }
        return scalars[scalars.startIndex..<end]
    }

    // MARK: Prompt summaries

    private static let space = "[\(PyText.regexSpaceClass)]"
    private static let requestMarker = TextRegex(
        #"##\#(space)+My request for [^:\n]+:\#(space)*(.*)"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let inlineCode = TextRegex("`([^`]+)`")
    private static let quotedPath = TextRegex(#"(['"])(?:~|/Users|/var|/private|/tmp)[^'"]+\1"#)
    private static let barePath = TextRegex(#"(?:~|/Users|/var|/private|/tmp)/[^\#(PyText.regexSpaceClass),;)'"`]+"#)
    private static let tag = TextRegex("<[^>]+>")
    private static let headingMarks = TextRegex(#"#+\#(space)*"#)

    /// Python `summarize_prompt` (10 steps incl. "## My request for X:" extraction,
    /// code/path/tag scrubbing). Returns nil for empty / `<task-notification>` prompts.
    ///
    /// 1. strip; empty or starting with `<task-notification>` → nil
    /// 2. keep only the text after `## My request for <X>:` if present
    /// 3. fenced blocks → " "; 4. unwrap `inline code`
    /// 5–6. quoted and bare paths under ~, /Users, /var, /private, /tmp → "..."
    /// 7. `<tags>` → " "; 8. `#` heading marks → " "
    /// 9. collapse whitespace, strip " -:\n\t"; 10. empty → nil, else truncate.
    public static func summarizePrompt(_ prompt: String?, limit: Int = 72) -> String? {
        guard let prompt else { return nil }
        var text = PyText.strip(prompt)
        if text.isEmpty || PyText.startsWith(text, "<task-notification>") { return nil }

        if let request = requestMarker.firstGroup(1, in: text) { text = request }
        text = stripFencedCodeBlocks(text, replacement: " ")
        text = inlineCode.replacing(in: text, with: "$1")
        text = quotedPath.replacing(in: text, with: "$1...$1")
        text = barePath.replacing(in: text, with: "...")
        text = tag.replacing(in: text, with: " ")
        text = headingMarks.replacing(in: text, with: " ")
        text = PyText.strip(collapseWhitespaceRuns(text), characters: " -:\n\t")

        return text.isEmpty ? nil : truncate(text, limit)
    }

    /// Python `re.sub(r"\s+", " ", text)`: every whitespace run becomes one space
    /// (leading/trailing runs included).
    private static func collapseWhitespaceRuns(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var inRun = false
        for scalar in text.unicodeScalars {
            if PyText.isSpace(scalar) {
                if !inRun { out.append(" ") }
                inRun = true
            } else {
                out.append(scalar)
                inRun = false
            }
        }
        return String(out)
    }

    // MARK: Projects

    private static let projectCache = ProjectNameCache()

    /// Name of the first directory (cwd or an ancestor) containing a `.git` entry,
    /// else basename(cwd), else cwd. Results are cached per cwd for a minute
    /// (thread-safe), so a later `git init` is noticed without walking the
    /// filesystem on every event as Python did.
    public static func projectName(cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        if let cached = projectCache.get(cwd) { return cached }
        let name = resolveProjectName(cwd: cwd)
        projectCache.set(cwd, name)
        return name
    }

    /// Uncached `projectName` (Python `project_name`, with pathlib's parsing: empty
    /// and `.` components are ignored, so a trailing slash is fine). Splits on the
    /// `/` byte, not on Characters: a combining mark right after a slash would
    /// otherwise glue the two into one grapheme and hide the separator.
    static func resolveProjectName(cwd: String) -> String {
        let slash = UInt8(ascii: "/")
        let isAbsolute = cwd.utf8.first == slash
        let parts = cwd.utf8.split(separator: slash).map { String(decoding: $0, as: UTF8.self) }.filter { $0 != "." }
        let fm = FileManager.default
        for length in stride(from: parts.count, through: 0, by: -1) {
            let joined = parts[0..<length].joined(separator: "/")
            let candidate = isAbsolute ? "/" + joined : (joined.isEmpty ? "." : joined)
            if fm.fileExists(atPath: (candidate as NSString).appendingPathComponent(".git")) {
                return length > 0 ? parts[length - 1] : candidate
            }
        }
        return parts.last ?? cwd
    }

    // MARK: Names

    /// Python `display_name_from_parts` (96-char truncation, normalized equality).
    ///
    /// project + title → `"{project}: {title} ({short})"`, or `"{title} ({short})"`
    /// when both normalize equal; title only → `"{title} ({short})"`; project only →
    /// `"{project} ({short})"`; neither → `fallback` (not truncated).
    public static func displayName(project: String?, title: String?, short: String, fallback: String) -> String {
        let project = project.flatMap { $0.isEmpty ? nil : $0 }
        let title = title.flatMap { $0.isEmpty ? nil : $0 }
        switch (project, title) {
        case let (project?, title?):
            if normalizeForComparison(project) == normalizeForComparison(title) {
                return truncate("\(title) (\(short))", displayNameLimit)
            }
            return truncate("\(project): \(title) (\(short))", displayNameLimit)
        case let (nil, title?):
            return truncate("\(title) (\(short))", displayNameLimit)
        case let (project?, nil):
            return truncate("\(project) (\(short))", displayNameLimit)
        case (nil, nil):
            return fallback
        }
    }

    /// Replace `_`/`-` with spaces, collapse whitespace, case-fold (Python
    /// `casefold()`, so "Straße" and "STRASSE" compare equal; `lowercased()` would
    /// keep the ß).
    ///
    /// The replacement works on code points: `replacingOccurrences` compares
    /// graphemes and would miss a `-` followed by a combining mark.
    public static func normalizeForComparison(_ text: String) -> String {
        var spaced = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            spaced.append(scalar == "_" || scalar == "-" ? " " : scalar)
        }
        return PyText.collapseWhitespace(String(spaced)).folding(options: .caseInsensitive, locale: nil)
    }
}

/// Thread-safe cwd → project name cache. Entries expire after `lifetime` seconds
/// of monotonic time; the cache is cleared when it grows past `limit` entries
/// (cwds are few in practice).
private final class ProjectNameCache: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String: (name: String, expires: TimeInterval)] = [:]
    private let limit = 1024
    private let lifetime: TimeInterval = 60

    func get(_ cwd: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = names[cwd], entry.expires > ProcessInfo.processInfo.systemUptime else { return nil }
        return entry.name
    }

    func set(_ cwd: String, _ name: String) {
        lock.lock(); defer { lock.unlock() }
        if names.count >= limit { names.removeAll(keepingCapacity: true) }
        names[cwd] = (name, ProcessInfo.processInfo.systemUptime + lifetime)
    }
}
