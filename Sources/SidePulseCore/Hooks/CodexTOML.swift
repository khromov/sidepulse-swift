import Foundation

/// A line-oriented view of a TOML file, just smart enough to edit Codex's
/// `config.toml` as text without disturbing anything else in it.
///
/// It classifies each line as blank, comment, table header (with its parsed
/// dotted key path) or content. A small lexer tracks multi-line strings and
/// values that span lines (arrays, inline tables), so a line inside them is never
/// mistaken for a header or a comment. It is not a TOML parser: values are only
/// decoded where the installer needs them (hook commands, `hooks = true`).
struct TOMLLines {
    enum Kind: Equatable {
        case blank
        case comment
        /// `[a.b]` or `[[a.b]]` with the decoded key path.
        case header(path: [String], isArray: Bool)
        /// A line that starts a key/value pair (or anything else outside a value).
        case content
        /// A line that starts inside a multi-line string or a value spanning
        /// lines; it never holds a key of its own.
        case continuation
    }

    var lines: [String]
    private(set) var kinds: [Kind]

    init(_ text: String) {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        self.init(lines: lines)
    }

    init(lines: [String]) {
        self.lines = lines
        self.kinds = TOMLLines.classify(lines)
    }

    /// Lines joined with "\n", ending with a newline unless empty.
    var text: String { TOMLLines.join(lines) }

    static func join(_ lines: [String]) -> String {
        lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" }
    }

    func headerPath(at index: Int) -> (path: [String], isArray: Bool)? {
        if case .header(let path, let isArray) = kinds[index] { return (path, isArray) }
        return nil
    }

    /// Index of the next header after `index` (or `lines.count`).
    func nextHeader(after index: Int) -> Int {
        var i = index + 1
        while i < kinds.count {
            if case .header = kinds[i] { return i }
            i += 1
        }
        return kinds.count
    }

    /// The last non-blank, non-comment line in `start..<end` (at least `start`).
    /// Trailing comments and blank lines before the next header belong to what
    /// follows, not to the table being removed.
    func contentEnd(start: Int, end: Int) -> Int {
        var last = start
        var i = start
        while i < end {
            switch kinds[i] {
            case .content, .continuation, .header: last = i
            case .blank, .comment: break
            }
            i += 1
        }
        return last
    }

    /// Key path at the start of a content line (`a.b = ...` → ["a", "b"]).
    func keyPath(at index: Int) -> [String]? {
        guard kinds[index] == .content else { return nil }
        var scanner = TOMLScanner(lines[index])
        guard let path = scanner.keyPath(), scanner.consume("=") else { return nil }
        return path
    }

    /// The string value of the `key = <string>` pair starting at `index`, if any.
    /// Handles all four TOML string forms, including multi-line strings that
    /// continue on the following lines.
    func stringValue(at index: Int, key: String) -> String? {
        guard let path = keyPath(at: index), path == [key] else { return nil }
        var scanner = TOMLScanner(lines[index])
        _ = scanner.keyPath()
        _ = scanner.consume("=")
        return scanner.stringValue(continuation: lines[index...].dropFirst().joined(separator: "\n"))
    }

    /// The raw value text of a `key = value` line, without a trailing comment.
    func rawValue(at index: Int) -> String? {
        guard keyPath(at: index) != nil else { return nil }
        var scanner = TOMLScanner(lines[index])
        _ = scanner.keyPath()
        _ = scanner.consume("=")
        return scanner.restWithoutComment()
    }

    // MARK: - Classification

    private static func classify(_ lines: [String]) -> [Kind] {
        var kinds: [Kind] = []
        kinds.reserveCapacity(lines.count)
        var state = TOMLScanner.State()
        for line in lines {
            if state.multiline == nil && state.depth == 0 {
                let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
                if isBlank(line) {
                    kinds.append(.blank)
                    continue
                }
                if trimmed.hasPrefix("#") {
                    kinds.append(.comment)
                    continue
                }
                if trimmed.hasPrefix("[") {
                    var scanner = TOMLScanner(line)
                    if let header = scanner.header() {
                        kinds.append(.header(path: header.path, isArray: header.isArray))
                        continue
                    }
                }
                kinds.append(.content)
            } else {
                kinds.append(.continuation)
            }
            TOMLScanner.advance(&state, over: line)
        }
        return kinds
    }
}

/// Byte-level scanner for the few TOML constructs the installer reads.
struct TOMLScanner {
    /// Lexer state carried from one line to the next.
    struct State {
        /// `"""` or `'''` while inside a multi-line string.
        var multiline: String?
        /// Unclosed `[`/`{` in a value that spans lines.
        var depth = 0
    }

    private let bytes: [UInt8]
    private var i = 0

    init(_ line: String) { bytes = Array(line.utf8) }

    private static let quote = UInt8(ascii: "\"")
    private static let apostrophe = UInt8(ascii: "'")
    private static let backslash = UInt8(ascii: "\\")

    private func peek(_ offset: Int = 0) -> UInt8? {
        i + offset < bytes.count ? bytes[i + offset] : nil
    }

    private func starts(with s: String) -> Bool {
        let u = Array(s.utf8)
        guard i + u.count <= bytes.count else { return false }
        return Array(bytes[i..<(i + u.count)]) == u
    }

    private mutating func skipSpaces() {
        while let c = peek(), c == 0x20 || c == 0x09 || c == 0x0D { i += 1 }
    }

    mutating func consume(_ s: String) -> Bool {
        skipSpaces()
        guard starts(with: s) else { return false }
        i += s.utf8.count
        return true
    }

    /// Whatever follows on the line, minus a trailing comment and whitespace.
    mutating func restWithoutComment() -> String {
        skipSpaces()
        var end = i
        var j = i
        while j < bytes.count {
            let c = bytes[j]
            if c == UInt8(ascii: "#") { break }
            if c == Self.quote || c == Self.apostrophe {
                let q = c
                j += 1
                while j < bytes.count, bytes[j] != q {
                    if q == Self.quote, bytes[j] == Self.backslash { j += 1 }
                    j += 1
                }
            }
            j += 1
            end = min(j, bytes.count)
        }
        var s = String(decoding: bytes[i..<end], as: UTF8.self)
        while let last = s.last, last == " " || last == "\t" || last == "\r" { s.removeLast() }
        return s
    }

    // MARK: Keys and headers

    /// A dotted key: bare keys and quoted keys separated by dots.
    mutating func keyPath() -> [String]? {
        var path: [String] = []
        while true {
            skipSpaces()
            guard let part = simpleKey() else { return nil }
            path.append(part)
            skipSpaces()
            if peek() == UInt8(ascii: ".") { i += 1; continue }
            return path
        }
    }

    private mutating func simpleKey() -> String? {
        guard let c = peek() else { return nil }
        if c == Self.quote {
            if starts(with: "\"\"\"") { return nil }
            return basicString()
        }
        if c == Self.apostrophe {
            if starts(with: "'''") { return nil }
            return literalString()
        }
        let start = i
        while let c = peek(), Self.isBareKeyByte(c) { i += 1 }
        return i > start ? String(decoding: bytes[start..<i], as: UTF8.self) : nil
    }

    private static func isBareKeyByte(_ c: UInt8) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39)
            || c == UInt8(ascii: "_") || c == UInt8(ascii: "-")
    }

    /// `[path]` or `[[path]]`, optionally followed by a comment.
    mutating func header() -> (path: [String], isArray: Bool)? {
        skipSpaces()
        guard consume("[") else { return nil }
        let isArray = peek() == UInt8(ascii: "[")
        if isArray { i += 1 }
        guard let path = keyPath() else { return nil }
        skipSpaces()
        guard consume(isArray ? "]]" : "]") else { return nil }
        skipSpaces()
        if let c = peek(), c != UInt8(ascii: "#") { return nil }
        return (path, isArray)
    }

    // MARK: Strings

    /// Decodes `"..."` starting at the opening quote.
    private mutating func basicString() -> String? {
        i += 1
        var out: [UInt8] = []
        while let c = peek() {
            i += 1
            if c == Self.quote { return String(decoding: out, as: UTF8.self) }
            if c == Self.backslash {
                guard let e = peek() else { return nil }
                i += 1
                appendEscape(e, into: &out)
            } else {
                out.append(c)
            }
        }
        return nil
    }

    private mutating func literalString() -> String? {
        i += 1
        let start = i
        while let c = peek() {
            if c == Self.apostrophe {
                let s = String(decoding: bytes[start..<i], as: UTF8.self)
                i += 1
                return s
            }
            i += 1
        }
        return nil
    }

    private mutating func appendEscape(_ e: UInt8, into out: inout [UInt8]) {
        switch e {
        case UInt8(ascii: "n"): out.append(0x0A)
        case UInt8(ascii: "t"): out.append(0x09)
        case UInt8(ascii: "r"): out.append(0x0D)
        case UInt8(ascii: "b"): out.append(0x08)
        case UInt8(ascii: "f"): out.append(0x0C)
        case UInt8(ascii: "e"): out.append(0x1B)
        case UInt8(ascii: "u"), UInt8(ascii: "U"):
            let n = e == UInt8(ascii: "u") ? 4 : 8
            guard i + n <= bytes.count,
                  let v = UInt32(String(decoding: bytes[i..<(i + n)], as: UTF8.self), radix: 16),
                  let scalar = Unicode.Scalar(v) else { return }
            i += n
            out.append(contentsOf: Array(String(Character(scalar)).utf8))
        default: out.append(e)
        }
    }

    /// Decodes the string value at the current position (after `=`). A
    /// multi-line string may continue into `continuation` (the following lines).
    mutating func stringValue(continuation: @autoclosure () -> String) -> String? {
        skipSpaces()
        for delimiter in ["'''", "\"\"\""] where starts(with: delimiter) {
            i += 3
            var body = String(decoding: bytes[i...], as: UTF8.self)
            if Self.closingRange(of: delimiter, in: body) == nil {
                let rest = continuation()
                if !rest.isEmpty { body += "\n" + rest }
            }
            guard let close = Self.closingRange(of: delimiter, in: body) else { return nil }
            var content = String(body[..<close])
            // A newline right after the opening delimiter is trimmed.
            if content.hasPrefix("\n") { content.removeFirst() } else if content.hasPrefix("\r\n") { content.removeFirst(2) }
            if delimiter == "'''" { return content }
            var inner = TOMLScanner(content)
            return inner.decodeMultilineBasic()
        }
        guard let c = peek() else { return nil }
        if c == Self.quote { return basicString() }
        if c == Self.apostrophe { return literalString() }
        return nil
    }

    /// End of a multi-line string body: the first delimiter run, allowing up to
    /// two extra quotes that belong to the content (`''''` = `'` + close).
    private static func closingRange(of delimiter: String, in body: String) -> String.Index? {
        let q = delimiter.first!
        var idx = body.startIndex
        while idx < body.endIndex {
            let c = body[idx]
            if q == "\"", c == "\\" {
                idx = body.index(idx, offsetBy: 2, limitedBy: body.endIndex) ?? body.endIndex
                continue
            }
            if c == q {
                var run = 0
                var j = idx
                while j < body.endIndex, body[j] == q { run += 1; j = body.index(after: j) }
                if run >= 3 { return body.index(idx, offsetBy: min(run - 3, 2)) }
                idx = j
                continue
            }
            idx = body.index(after: idx)
        }
        return nil
    }

    private mutating func decodeMultilineBasic() -> String {
        var out: [UInt8] = []
        while let c = peek() {
            i += 1
            guard c == Self.backslash, let e = peek() else { out.append(c); continue }
            if e == 0x0A || e == 0x20 || e == 0x09 || e == 0x0D {
                // Line-ending backslash: drop it and the following whitespace.
                while let w = peek(), w == 0x0A || w == 0x20 || w == 0x09 || w == 0x0D { i += 1 }
                continue
            }
            i += 1
            appendEscape(e, into: &out)
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: Lexer state across lines

    /// Updates the multi-line string / open-bracket state after `line`.
    static func advance(_ state: inout State, over line: String) {
        let b = Array(line.utf8)
        var i = 0
        func starts(_ s: String) -> Bool {
            let u = Array(s.utf8)
            return i + u.count <= b.count && Array(b[i..<(i + u.count)]) == u
        }
        while i < b.count {
            if let delimiter = state.multiline {
                if delimiter == "\"\"\"", b[i] == backslash { i += 2; continue }
                if starts(delimiter) {
                    i += 3
                    while i < b.count, b[i] == delimiter.utf8.first! { i += 1 }
                    state.multiline = nil
                } else {
                    i += 1
                }
                continue
            }
            let c = b[i]
            if c == UInt8(ascii: "#") { return }
            if starts("\"\"\"") || starts("'''") {
                state.multiline = starts("'''") ? "'''" : "\"\"\""
                i += 3
                continue
            }
            if c == quote || c == apostrophe {
                i += 1
                while i < b.count, b[i] != c {
                    if c == quote, b[i] == backslash { i += 1 }
                    i += 1
                }
                i += 1
                continue
            }
            if c == UInt8(ascii: "[") || c == UInt8(ascii: "{") { state.depth += 1 }
            if c == UInt8(ascii: "]") || c == UInt8(ascii: "}") { state.depth = max(0, state.depth - 1) }
            i += 1
        }
    }
}

/// TOML string emission.
enum TOMLString {
    /// `"..."` with `\` and `"` (and control characters) escaped.
    static func basic(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// `'''...'''` (no escaping needed) unless the value cannot be written that
    /// way, in which case a basic string is used.
    static func literalPreferred(_ s: String) -> String {
        if s.contains("'''") || s.contains("\n") || s.contains("\r") || s.hasSuffix("'") { return basic(s) }
        return "'''\(s)'''"
    }
}
