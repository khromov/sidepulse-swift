import Foundation

/// Keeps key order and number literals so rewriting a user's config (e.g.
/// ~/.claude/settings.json) never reorders or reformats it.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)
}

public struct JSONError: Error, CustomStringConvertible, Equatable {
    public var message: String
    public var offset: Int
    public init(_ message: String, offset: Int) { self.message = message; self.offset = offset }
    public var description: String { "Invalid JSON at byte \(offset): \(message)" }
}

public struct JSONObject: Equatable, Sendable, Sequence, ExpressibleByDictionaryLiteral {
    public private(set) var entries: [(key: String, value: JSONValue)] = []

    public init() {}

    /// Callers guarantee unique keys so building skips the per-key lookups.
    init(uniqueEntries: [(key: String, value: JSONValue)]) {
        self.entries = uniqueEntries
    }

    public init(_ entries: [(String, JSONValue)]) {
        for (k, v) in entries { self[k] = v }
    }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        for (k, v) in elements { self[k] = v }
    }

    public var keys: [String] { entries.map(\.key) }
    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }

    public subscript(key: String) -> JSONValue? {
        get { entries.first(where: { $0.key == key })?.value }
        set {
            if let idx = entries.firstIndex(where: { $0.key == key }) {
                if let newValue { entries[idx].value = newValue } else { entries.remove(at: idx) }
            } else if let newValue {
                entries.append((key, newValue))
            }
        }
    }

    @discardableResult
    public mutating func removeValue(forKey key: String) -> JSONValue? {
        guard let idx = entries.firstIndex(where: { $0.key == key }) else { return nil }
        return entries.remove(at: idx).value
    }

    public func makeIterator() -> IndexingIterator<[(key: String, value: JSONValue)]> { entries.makeIterator() }

    public static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
        guard lhs.entries.count == rhs.entries.count else { return false }
        for (a, b) in zip(lhs.entries, rhs.entries) where a.key != b.key || a.value != b.value { return false }
        return true
    }
}

extension JSONValue {
    // MARK: Parsing

    /// For duplicate keys the last value wins, at the first key's position.
    public static func parse(_ data: Data) throws -> JSONValue {
        var parser = JSONParser(bytes: [UInt8](data))
        return try parser.parseDocument()
    }

    public static func parse(_ string: String) throws -> JSONValue {
        try parse(Data(string.utf8))
    }

    // MARK: Serialization

    /// Pretty output matches Python `json.dumps(indent=2)`, and U+2028/U+2029 are
    /// escaped so JSONL lines never contain them.
    public func serialized(pretty: Bool = false) -> String {
        var out = ""
        JSONWriter.write(self, into: &out, pretty: pretty, level: 0)
        return out
    }

    public func sortedKeys() -> JSONValue {
        switch self {
        case .array(let items):
            return .array(items.map { $0.sortedKeys() })
        case .object(let obj):
            return .object(JSONObject(uniqueEntries: obj.entries
                .sorted(by: { $0.key < $1.key })
                .map { (key: $0.key, value: $0.value.sortedKeys()) }))
        default:
            return self
        }
    }

    // MARK: Convenience

    public init(_ string: String?) { self = string.map { .string($0) } ?? .null }
    public init(_ int: Int) { self = .number(String(int)) }
    public init(_ double: Double, integralAsInt: Bool = false) {
        if integralAsInt, double.rounded() == double, abs(double) < 1e15 {
            self = .number(String(Int(double)))
        } else {
            self = .number(String(double))
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var doubleValue: Double? { if case .number(let n) = self { return Double(n) }; return nil }
    public var intValue: Int? {
        guard case .number(let n) = self else { return nil }
        if let i = Int(n) { return i }
        if let d = Double(n), d.rounded() == d, abs(d) < 9e15 { return Int(d) }
        return nil
    }
    public var objectValue: JSONObject? { if case .object(let o) = self { return o }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }

    /// Python-like `str(value)`, the text the classifier matches against for parity.
    public var pythonString: String {
        switch self {
        case .null: return "None"
        case .bool(let b): return b ? "True" : "False"
        case .number(let n): return n
        case .string(let s): return s
        case .array, .object: return serialized()
        }
    }
}

// MARK: - Parser

struct JSONParser {
    let bytes: [UInt8]
    var i = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func parseDocument() throws -> JSONValue {
        // Skip a UTF-8 BOM.
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { i = 3 }
        skipWhitespace()
        let value = try parseValue(depth: 0)
        skipWhitespace()
        guard i == bytes.count else { throw JSONError("Unexpected trailing characters", offset: i) }
        return value
    }

    mutating func skipWhitespace() {
        while i < bytes.count {
            switch bytes[i] {
            case 0x20, 0x09, 0x0A, 0x0D: i += 1
            default: return
            }
        }
    }

    mutating func parseValue(depth: Int) throws -> JSONValue {
        guard depth < 512 else { throw JSONError("Nesting too deep", offset: i) }
        guard i < bytes.count else { throw JSONError("Unexpected end of input", offset: i) }
        switch bytes[i] {
        case UInt8(ascii: "{"): return try parseObject(depth: depth)
        case UInt8(ascii: "["): return try parseArray(depth: depth)
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expectLiteral("true"); return .bool(true)
        case UInt8(ascii: "f"): try expectLiteral("false"); return .bool(false)
        case UInt8(ascii: "n"): try expectLiteral("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try parseNumber())
        default: throw JSONError("Unexpected character", offset: i)
        }
    }

    mutating func expectLiteral(_ literal: StaticString) throws {
        let lit = literal.utf8Start
        let n = literal.utf8CodeUnitCount
        guard i + n <= bytes.count else { throw JSONError("Invalid literal", offset: i) }
        for k in 0..<n where bytes[i + k] != lit[k] { throw JSONError("Invalid literal", offset: i) }
        i += n
    }

    mutating func parseObject(depth: Int) throws -> JSONValue {
        i += 1
        // A key index keeps parsing linear because hook payloads can carry tool
        // responses with many thousands of keys.
        var entries: [(key: String, value: JSONValue)] = []
        var index: [String: Int] = [:]
        skipWhitespace()
        if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(JSONObject()) }
        while true {
            skipWhitespace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw JSONError("Expected object key", offset: i) }
            let key = try parseString()
            skipWhitespace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw JSONError("Expected ':'", offset: i) }
            i += 1
            skipWhitespace()
            let value = try parseValue(depth: depth + 1)
            if let existing = index[key] {
                entries[existing].value = value
            } else {
                index[key] = entries.count
                entries.append((key: key, value: value))
            }
            skipWhitespace()
            guard i < bytes.count else { throw JSONError("Unterminated object", offset: i) }
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
            if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(JSONObject(uniqueEntries: entries)) }
            throw JSONError("Expected ',' or '}'", offset: i)
        }
    }

    mutating func parseArray(depth: Int) throws -> JSONValue {
        i += 1
        var items: [JSONValue] = []
        skipWhitespace()
        if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
        while true {
            skipWhitespace()
            items.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            guard i < bytes.count else { throw JSONError("Unterminated array", offset: i) }
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
            if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            throw JSONError("Expected ',' or ']'", offset: i)
        }
    }

    mutating func parseNumber() throws -> String {
        let start = i
        if bytes[i] == UInt8(ascii: "-") { i += 1 }
        guard i < bytes.count else { throw JSONError("Invalid number", offset: start) }
        if bytes[i] == UInt8(ascii: "0") {
            i += 1
        } else if bytes[i] >= UInt8(ascii: "1") && bytes[i] <= UInt8(ascii: "9") {
            while i < bytes.count, bytes[i] >= UInt8(ascii: "0"), bytes[i] <= UInt8(ascii: "9") { i += 1 }
        } else {
            throw JSONError("Invalid number", offset: start)
        }
        if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
            i += 1
            let fracStart = i
            while i < bytes.count, bytes[i] >= UInt8(ascii: "0"), bytes[i] <= UInt8(ascii: "9") { i += 1 }
            guard i > fracStart else { throw JSONError("Invalid number fraction", offset: i) }
        }
        if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
            i += 1
            if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
            let expStart = i
            while i < bytes.count, bytes[i] >= UInt8(ascii: "0"), bytes[i] <= UInt8(ascii: "9") { i += 1 }
            guard i > expStart else { throw JSONError("Invalid number exponent", offset: i) }
        }
        return String(decoding: bytes[start..<i], as: UTF8.self)
    }

    mutating func parseString() throws -> String {
        i += 1
        var out: [UInt8] = []
        var runStart = i
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "\"") {
                out.append(contentsOf: bytes[runStart..<i])
                i += 1
                return String(decoding: out, as: UTF8.self)
            }
            if b == UInt8(ascii: "\\") {
                out.append(contentsOf: bytes[runStart..<i])
                i += 1
                guard i < bytes.count else { break }
                let e = bytes[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var scalarValue = try parseHex4()
                    if (0xD800...0xDBFF).contains(scalarValue) {
                        if i + 1 < bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                            let save = i
                            i += 2
                            let low = try parseHex4()
                            if (0xDC00...0xDFFF).contains(low) {
                                scalarValue = 0x10000 + ((scalarValue - 0xD800) << 10) + (low - 0xDC00)
                            } else {
                                i = save
                                scalarValue = 0xFFFD
                            }
                        } else {
                            scalarValue = 0xFFFD
                        }
                    } else if (0xDC00...0xDFFF).contains(scalarValue) {
                        scalarValue = 0xFFFD
                    }
                    let scalar = Unicode.Scalar(scalarValue) ?? "\u{FFFD}"
                    out.append(contentsOf: Array(String(Character(scalar)).utf8))
                default:
                    throw JSONError("Invalid escape", offset: i - 1)
                }
                runStart = i
                continue
            }
            // Raw control characters are tolerated (hook payloads are not always strict).
            i += 1
        }
        throw JSONError("Unterminated string", offset: i)
    }

    mutating func parseHex4() throws -> UInt32 {
        guard i + 4 <= bytes.count else { throw JSONError("Invalid \\u escape", offset: i) }
        var v: UInt32 = 0
        for _ in 0..<4 {
            let c = bytes[i]
            let d: UInt32
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): d = UInt32(c - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): d = UInt32(c - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): d = UInt32(c - UInt8(ascii: "A") + 10)
            default: throw JSONError("Invalid \\u escape", offset: i)
            }
            v = v * 16 + d
            i += 1
        }
        return v
    }
}

// MARK: - Writer

enum JSONWriter {
    static func write(_ value: JSONValue, into out: inout String, pretty: Bool, level: Int) {
        switch value {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += n
        case .string(let s): writeString(s, into: &out)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "["
            for (idx, item) in items.enumerated() {
                if idx > 0 { out += "," }
                if pretty { out += "\n"; indent(level + 1, &out) }
                write(item, into: &out, pretty: pretty, level: level + 1)
            }
            if pretty { out += "\n"; indent(level, &out) }
            out += "]"
        case .object(let obj):
            if obj.isEmpty { out += "{}"; return }
            out += "{"
            for (idx, entry) in obj.entries.enumerated() {
                if idx > 0 { out += "," }
                if pretty { out += "\n"; indent(level + 1, &out) }
                writeString(entry.key, into: &out)
                out += pretty ? ": " : ":"
                write(entry.value, into: &out, pretty: pretty, level: level + 1)
            }
            if pretty { out += "\n"; indent(level, &out) }
            out += "}"
        }
    }

    static func indent(_ level: Int, _ out: inout String) {
        out += String(repeating: "  ", count: level)
    }

    static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}
