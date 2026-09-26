import Foundation

/// Works on Unicode scalars rather than grapheme clusters so the collector rules,
/// written against Python `str` semantics, give the same answers.
enum PyText {
    /// Python `str.isspace()` for one code point (bidi class WS/B/S or category Zs).
    static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    /// `isSpace` as an ICU character class, because ICU's `\s` misses `\v` and
    /// U+001C–U+001F.
    static let regexSpaceClass = #"\t\n\x{0B}\f\r\x{1C}-\x{20}\x{85}\x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}"#

    static func strip(_ text: String) -> String {
        strip(text, where: isSpace)
    }

    static func strip(_ text: String, characters: String) -> String {
        let set = Set(characters.unicodeScalars)
        return strip(text, where: { set.contains($0) })
    }

    private static func strip(_ text: String, where predicate: (Unicode.Scalar) -> Bool) -> String {
        let scalars = text.unicodeScalars
        var start = scalars.startIndex
        var end = scalars.endIndex
        while start < end, predicate(scalars[start]) { start = scalars.index(after: start) }
        while end > start {
            let before = scalars.index(before: end)
            guard predicate(scalars[before]) else { break }
            end = before
        }
        if start == scalars.startIndex, end == scalars.endIndex { return text }
        return String(scalars[start..<end])
    }

    static func collapseWhitespace(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if isSpace(scalar) {
                pendingSpace = !out.isEmpty
            } else {
                if pendingSpace { out.append(" ") }
                pendingSpace = false
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// Python `str.splitlines()`, for message text only since JSONL is split on `\n`
    /// alone.
    static func splitLines(_ text: String) -> [String] {
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        var previousWasCR = false
        var sawAny = false
        for scalar in text.unicodeScalars {
            sawAny = true
            if scalar == "\n" && previousWasCR {
                previousWasCR = false
                continue
            }
            previousWasCR = false
            switch scalar.value {
            case 0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x85, 0x2028, 0x2029:
                lines.append(String(current))
                current = String.UnicodeScalarView()
                previousWasCR = scalar == "\r"
            default:
                current.append(scalar)
            }
        }
        if sawAny, !current.isEmpty { lines.append(String(current)) }
        return lines
    }

    /// Code-point prefix check (Python `str.startswith`), unlike `String.hasPrefix`
    /// which compares grapheme clusters.
    static func startsWith(_ text: String, _ prefix: String) -> Bool {
        text.utf8.starts(with: prefix.utf8)
    }

    static func startsWith(_ text: String, anyOf prefixes: [String]) -> Bool {
        prefixes.contains { startsWith(text, $0) }
    }

    static func endsWith(_ text: String, _ suffix: String) -> Bool {
        text.utf8.reversed().starts(with: suffix.utf8.reversed())
    }

    /// A UTF-8 byte search, which matches code points exactly for valid UTF-8.
    static func contains(_ text: String, _ needle: String) -> Bool {
        if needle.isEmpty { return true }
        var text = text
        var needle = needle
        return text.withUTF8 { haystack in
            needle.withUTF8 { pattern in
                guard haystack.count >= pattern.count, let h = haystack.baseAddress, let p = pattern.baseAddress else {
                    return false
                }
                return memmem(h, haystack.count, p, pattern.count) != nil
            }
        }
    }

    static func contains(_ text: String, anyOf needles: [String]) -> Bool {
        needles.contains { contains(text, $0) }
    }

    static func prefix(_ text: String, _ count: Int) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.prefix(max(0, count))))
    }

    static func truthy(_ value: JSONValue?) -> Bool {
        switch value {
        case nil, .null?: return false
        case .bool(let b)?: return b
        case .number(let n)?: return (Double(n) ?? 1) != 0
        case .string(let s)?: return !s.isEmpty
        case .array(let a)?: return !a.isEmpty
        case .object(let o)?: return !o.isEmpty
        }
    }

    /// Python `a or b or c`, so it returns the last value when none is truthy.
    static func firstTruthy(_ values: JSONValue?...) -> JSONValue? {
        for value in values where truthy(value) { return value }
        return values.last ?? nil
    }

    /// Python `str(raw.get(key, missing))`, so a JSON null becomes "None".
    static func str(_ value: JSONValue?, missing: String = "") -> String {
        value?.pythonString ?? missing
    }

    static func nonEmptyString(_ value: JSONValue?) -> String? {
        guard let s = value?.stringValue, !s.isEmpty else { return nil }
        return s
    }
}

/// `@unchecked Sendable` because `NSRegularExpression` is immutable and documented
/// as thread-safe.
struct TextRegex: @unchecked Sendable {
    let regex: NSRegularExpression

    init(_ pattern: String, options: NSRegularExpression.Options = []) {
        do {
            regex = try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            preconditionFailure("Invalid built-in regex \(pattern): \(error)")
        }
    }

    func matches(_ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    func firstGroup(_ group: Int, in text: String) -> String? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }

    func allGroups(_ group: Int, in text: String) -> [String] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: group), in: text).map { String(text[$0]) }
        }
    }

    func replacing(in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}

/// Python `re.sub(r"```.*?```", replacement, text, flags=re.DOTALL)` over UTF-8
/// bytes, which is safe because a backtick never occurs inside a multi-byte sequence.
func stripFencedCodeBlocks(_ text: String, replacement: String = "") -> String {
    let bytes = Array(text.utf8)
    func fence(from start: Int) -> Int? {
        var i = start
        while i + 2 < bytes.count {
            if bytes[i] == 0x60 && bytes[i + 1] == 0x60 && bytes[i + 2] == 0x60 { return i }
            i += 1
        }
        return nil
    }
    guard var open = fence(from: 0) else { return text }
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    var copied = 0
    while let close = fence(from: open + 3) {
        out.append(contentsOf: bytes[copied..<open])
        out.append(contentsOf: replacement.utf8)
        copied = close + 3
        guard let next = fence(from: copied) else { break }
        open = next
    }
    out.append(contentsOf: bytes[copied...])
    return String(decoding: out, as: UTF8.self)
}

func stripInlineCode(_ text: String) -> String {
    guard text.unicodeScalars.contains("`") else { return text }
    let scalars = Array(text.unicodeScalars)
    var out = String.UnicodeScalarView()
    var i = 0
    while i < scalars.count {
        if scalars[i] == "`" {
            var j = i + 1
            while j < scalars.count, scalars[j] != "`", scalars[j] != "\n" { j += 1 }
            if j < scalars.count, scalars[j] == "`" {
                i = j + 1
                continue
            }
        }
        out.append(scalars[i])
        i += 1
    }
    return String(out)
}
