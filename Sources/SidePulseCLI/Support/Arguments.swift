import Foundation

/// Same values as the Python CLI.
public enum ExitCode {
    public static let ok: Int32 = 0
    public static let failure: Int32 = 1
    /// Also used for an invalid LED program or a device selection error.
    public static let usage: Int32 = 2
}

public struct OptionSpec: Sendable, Equatable {
    public var name: String
    public var short: Character?
    public var valueName: String?
    public var help: String

    public init(_ name: String, short: Character? = nil, value valueName: String? = nil, help: String) {
        self.name = name; self.short = short; self.valueName = valueName; self.help = help
    }

    public var takesValue: Bool { valueName != nil }

    var synopsis: String {
        var text = short.map { "-\($0), " } ?? ""
        text += "--\(name)"
        if let valueName { text += " \(valueName)" }
        return text
    }
}

public struct PositionalSpec: Sendable, Equatable {
    public var name: String
    public var maxCount: Int
    public var choices: [String]?

    public init(name: String, maxCount: Int = 1, choices: [String]? = nil) {
        self.name = name; self.maxCount = maxCount; self.choices = choices
    }

    public static let none = PositionalSpec(name: "", maxCount: 0)
}

public struct CommandSpec: Sendable {
    public var name: String
    public var synopsis: String
    public var summary: String
    public var details: String?
    public var positionals: PositionalSpec
    public var options: [OptionSpec]

    public init(name: String, synopsis: String, summary: String, details: String? = nil,
                positionals: PositionalSpec = .none, options: [OptionSpec] = []) {
        self.name = name; self.synopsis = synopsis; self.summary = summary; self.details = details
        self.positionals = positionals; self.options = options
    }

    public var usageLine: String {
        synopsis.isEmpty ? "usage: sidepulse \(name)" : "usage: sidepulse \(name) \(synopsis)"
    }

    /// Mimics argparse's layout.
    public var helpText: String {
        var lines = [usageLine, "", summary]
        if let details, !details.isEmpty { lines += ["", details] }
        let rows = options.map { ($0.synopsis, $0.help) } + [("-h, --help", "show this help message and exit")]
        let width = min(24, rows.map(\.0.count).max() ?? 0)
        lines += ["", "options:"]
        for (left, help) in rows {
            if left.count > width {
                lines.append("  \(left)")
                lines.append("  \(String(repeating: " ", count: width))  \(help)")
            } else {
                lines.append("  \(left.padding(toLength: width, withPad: " ", startingAt: 0))  \(help)")
            }
        }
        return lines.joined(separator: "\n")
    }

    func option(named name: String) -> OptionSpec? { options.first { $0.name == name } }
    func option(short: Character) -> OptionSpec? { options.first { $0.short == short } }
}

public struct UsageError: Error, Equatable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public struct ParsedArguments: Equatable, Sendable {
    public var flags: Set<String> = []
    /// The last occurrence wins, as in argparse.
    public var values: [String: String] = [:]
    public var positionals: [String] = []

    public init(flags: Set<String> = [], values: [String: String] = [:], positionals: [String] = []) {
        self.flags = flags; self.values = values; self.positionals = positionals
    }

    public func has(_ flag: String) -> Bool { flags.contains(flag) }
    public func value(_ name: String) -> String? { values[name] }

    public func double(_ name: String, default defaultValue: Double, minimum: Double? = nil,
                       exclusive: Bool = false) throws -> Double {
        guard let raw = values[name] else { return defaultValue }
        guard let value = Double(raw.trimmingCharacters(in: .whitespaces)), value.isFinite else {
            throw UsageError("argument --\(name): invalid float value: '\(raw)'")
        }
        if let minimum, exclusive ? value <= minimum : value < minimum {
            let bound = String(format: "%g", minimum)
            throw UsageError("argument --\(name): must be \(exclusive ? "greater than" : "at least") \(bound)")
        }
        return value
    }
}

public enum ParseOutcome: Equatable {
    case help
    case arguments(ParsedArguments)
}

/// Deliberately small, with argparse's error messages so usage errors read like the Python CLI's.
public enum ArgumentParser {
    public static func parse(_ arguments: [String], spec: CommandSpec) throws -> ParseOutcome {
        var result = ParsedArguments()
        var index = 0
        var onlyPositionals = false

        func store(_ option: OptionSpec, inlineValue: String?) throws {
            if option.takesValue {
                if let inlineValue {
                    result.values[option.name] = inlineValue
                } else {
                    guard index + 1 < arguments.count else {
                        throw UsageError("argument --\(option.name): expected one argument")
                    }
                    index += 1
                    result.values[option.name] = arguments[index]
                }
            } else {
                if let inlineValue {
                    throw UsageError("argument --\(option.name): ignored explicit argument '\(inlineValue)'")
                }
                result.flags.insert(option.name)
            }
        }

        while index < arguments.count {
            let argument = arguments[index]
            if onlyPositionals || argument == "-" || !argument.hasPrefix("-") {
                result.positionals.append(argument)
            } else if argument == "--" {
                onlyPositionals = true
            } else if argument == "-h" || argument == "--help" {
                return .help
            } else if argument.hasPrefix("--") {
                let body = argument.dropFirst(2)
                let name: String
                let inlineValue: String?
                if let equals = body.firstIndex(of: "=") {
                    name = String(body[..<equals])
                    inlineValue = String(body[body.index(after: equals)...])
                } else {
                    name = String(body)
                    inlineValue = nil
                }
                guard let option = spec.option(named: name) else {
                    throw UsageError("unrecognized arguments: \(argument)")
                }
                try store(option, inlineValue: inlineValue)
            } else {
                let letters = Array(argument.dropFirst())
                var position = 0
                while position < letters.count {
                    guard let option = spec.option(short: letters[position]) else {
                        throw UsageError("unrecognized arguments: \(argument)")
                    }
                    if option.takesValue {
                        let rest = String(letters[(position + 1)...])
                        try store(option, inlineValue: rest.isEmpty ? nil : rest)
                        break
                    }
                    try store(option, inlineValue: nil)
                    position += 1
                }
            }
            index += 1
        }

        let positional = spec.positionals
        if result.positionals.count > positional.maxCount {
            let extra = result.positionals.dropFirst(positional.maxCount)
            throw UsageError("unrecognized arguments: \(extra.joined(separator: " "))")
        }
        if let choices = positional.choices {
            for value in result.positionals where !choices.contains(value) {
                let list = choices.map { "'\($0)'" }.joined(separator: ", ")
                throw UsageError("argument \(positional.name): invalid choice: '\(value)' (choose from \(list))")
            }
        }
        return .arguments(result)
    }
}
