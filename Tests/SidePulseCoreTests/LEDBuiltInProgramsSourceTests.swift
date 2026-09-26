import XCTest
@testable import SidePulseCore

/// Builds `BuiltInPrograms.swift` from the Python project alone, so no animation data is hand-typed.
enum LEDBuiltInProgramsGenerator {
    struct Entry: Equatable {
        var id: String
        var name: String
        var countSpecific: Bool
    }

    struct Profile: Equatable {
        var id: String
        var name: String
        var animations: [String: String]
    }

    struct Input {
        var catalog: [Entry]
        var files: [(name: String, program: String)]
        var profiles: [Profile]
        var modes: [String]
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    static let profileStems = ["cyan", "ember", "purple"]
    static let lidStates: Set<String> = ["lid_open", "lid_closed"]

    // MARK: Loading

    static func load(repo: URL) throws -> Input {
        let source = repo.appendingPathComponent("src/sidepulse")
        let settings = try String(contentsOf: source.appendingPathComponent("settings.py"), encoding: .utf8)
        let statusBar = try String(contentsOf: source.appendingPathComponent("status_bar.py"), encoding: .utf8)
        let ledStatus = try String(contentsOf: source.appendingPathComponent("led_status.py"), encoding: .utf8)
        let models = try String(contentsOf: source.appendingPathComponent("models.py"), encoding: .utf8)

        let constants = Dictionary(matches(#"(?m)^(AGENT_ANIMATION_[A-Z0-9_]+) = "([^"]*)"$"#, in: settings)
            .map { ($0[0], $0[1]) }, uniquingKeysWith: { first, _ in first })
        let order = try block(after: "AGENT_ANIMATION_BUILT_INS = (", in: settings)
        let ids = try matches(#"(AGENT_ANIMATION_[A-Z0-9_]+)"#, in: order).map(\.[0]).map { name -> String in
            guard let id = constants[name] else { throw Failure(description: "settings.py: no value for \(name)") }
            return id
        }
        let labelBlock = try block(after: "def agent_animation_label", in: statusBar, until: "}.get(animation_id)")
        let labels = try Dictionary(matches(#"(AGENT_ANIMATION_[A-Z0-9_]+): "([^"]*)""#, in: labelBlock).map { match in
            guard let id = constants[match[0]] else { throw Failure(description: "status_bar.py: unknown \(match[0])") }
            return (id, match[1])
        }, uniquingKeysWith: { first, _ in first })
        let countSpecific = Set(matches(#""([a-z0-9-]+)""#,
                                        in: try block(after: "COUNT_SPECIFIC_ANIMATIONS = frozenset(", in: ledStatus))
                                    .map { $0[0] })
        let modes = matches(#"(?m)^    [A-Z_]+ = "([a-z_]+)"$"#,
                            in: try block(after: "class AgentMode(str, Enum):", in: models, until: "\n\n"))
            .map { $0[0] }

        let animationDir = source.appendingPathComponent("resources/animations")
        let fileNames = try FileManager.default.contentsOfDirectory(atPath: animationDir.path)
            .filter { $0.hasSuffix(".LED") && !LEDTestSupport.isLidAnimation($0) }
            .sorted()
        let files = try fileNames.map { name in
            (name: name, program: try program(Data(contentsOf: animationDir.appendingPathComponent(name)), name: name))
        }
        let available = Set(fileNames)

        let catalog = try ids.filter { !LEDTestSupport.isLidAnimation($0) }.map { id -> Entry in
            guard let name = labels[id] else { throw Failure(description: "\(id): no UI label in status_bar.py") }
            let variants = countSpecific.contains(id)
            let expected = variants ? ["\(id)-2.LED", "\(id)-8.LED"] : ["\(id).LED"]
            guard expected.allSatisfy(available.contains) else {
                throw Failure(description: "\(id): expected \(expected.joined(separator: ", "))")
            }
            return Entry(id: id, name: name, countSpecific: variants)
        }
        let referenced = Set(catalog.flatMap { entry in
            entry.countSpecific ? ["\(entry.id)-2.LED", "\(entry.id)-8.LED"] : ["\(entry.id).LED"]
        })
        guard referenced == available else {
            throw Failure(description: "unreferenced or missing files: \(referenced.symmetricDifference(available).sorted())")
        }

        let known = Set(catalog.map(\.id))
        let profiles = try profileStems.map { stem -> Profile in
            let url = repo.appendingPathComponent("profiles/\(stem).json")
            let document = try JSONValue.parse(try Data(contentsOf: url))
            guard let name = document["name"]?.stringValue, let raw = document["animations"]?.objectValue else {
                throw Failure(description: "\(stem).json: missing name or animations")
            }
            var animations: [String: String] = [:]
            for (mode, value) in raw where !lidStates.contains(mode) {
                guard let id = value.stringValue, known.contains(id) else {
                    throw Failure(description: "\(stem).json: unknown animation for \(mode)")
                }
                animations[mode] = id
            }
            guard Set(animations.keys) == Set(modes) else {
                throw Failure(description: "\(stem).json: expected every agent mode")
            }
            return Profile(id: "profile:\(stem)", name: name, animations: animations)
        }
        return Input(catalog: catalog, files: files, profiles: profiles, modes: modes)
    }

    /// Rejects anything the Python loader (`normalize_led_text(text).strip()`) would change.
    private static func program(_ data: Data, name: String) throws -> String {
        guard let text = String(data: data, encoding: .utf8), text.hasSuffix("\n"), !text.hasSuffix("\n\n") else {
            throw Failure(description: "\(name): expected UTF-8 with exactly one trailing newline")
        }
        let program = String(text.dropLast())
        guard !program.isEmpty, !program.contains("\r"), !program.contains("\\"),
              !program.contains(String(repeating: "\"", count: 3)),
              program.unicodeScalars.allSatisfy({ (0x20..<0x7F).contains($0.value) || $0 == "\n" }),
              !program.split(separator: "\n").contains(where: { $0.hasSuffix(" ") }),
              program == program.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw Failure(description: "\(name): expected printable ASCII without trailing spaces")
        }
        return program
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (1..<match.numberOfRanges).map { String(text[Range(match.range(at: $0), in: text)!]) }
        }
    }

    /// `until` defaults to the end of a Python tuple (a line holding only ")").
    private static func block(after marker: String, in text: String, until end: String = "\n)") throws -> String {
        guard let start = text.range(of: marker),
              let stop = text.range(of: end, range: start.upperBound..<text.endIndex) else {
            throw Failure(description: "could not find \(marker)")
        }
        return String(text[start.upperBound..<stop.lowerBound])
    }

    // MARK: Rendering

    static func render(_ input: Input) -> String {
        var out = [
            "// GENERATED FILE. Do not edit by hand.",
            "// Regenerate: SIDEPULSE_REGENERATE_BUILTINS=1 SIDEPULSE_PYTHON_REPO=<repo> swift test --filter LEDBuiltInProgramsSourceTests",
            "",
            "/// Embedded so no resource bundle is needed at runtime.",
            "enum BuiltInPrograms {",
            "    static let catalog: [Animation] = [",
        ]
        for entry in input.catalog {
            out.append("        Animation(id: \"\(entry.id)\", name: \"\(entry.name)\", countSpecific: \(entry.countSpecific)),")
        }
        out += [
            "    ]",
            "",
            "    static let files: [String: String] = [",
        ]
        let indent = String(repeating: " ", count: 12)
        for file in input.files {
            let body = file.program.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.isEmpty ? "" : indent + $0 }
                .joined(separator: "\n")
            out.append("        \"\(file.name)\": #\"\"\"\n\(body)\n\(indent)\"\"\"#,")
        }
        out += [
            "    ]",
            "",
            "    static let profiles: [AnimationProfile] = [",
        ]
        for profile in input.profiles {
            out.append("        AnimationProfile(id: \"\(profile.id)\", name: \"\(profile.name)\", animations: [")
            for mode in input.modes {
                out.append("            .\(swiftCaseName(mode)): \"\(profile.animations[mode]!)\",")
            }
            out.append("        ]),")
        }
        out += ["    ]", "}", ""]
        return out.joined(separator: "\n")
    }

    static func swiftCaseName(_ rawValue: String) -> String {
        let parts = rawValue.split(separator: "_")
        return ([String(parts[0])] + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }).joined()
    }
}

final class LEDBuiltInProgramsSourceTests: XCTestCase {
    private var sourceURL: URL {
        LEDTestSupport.packageRoot().appendingPathComponent("Sources/SidePulseCore/LED/BuiltInPrograms.swift")
    }

    func testCheckedInSourceIsTheGeneratorOutput() throws {
        guard let repo = LEDTestSupport.pythonRepo() else { throw XCTSkip("Python sidepulse checkout not found") }
        let generated = LEDBuiltInProgramsGenerator.render(try LEDBuiltInProgramsGenerator.load(repo: repo))

        if ProcessInfo.processInfo.environment["SIDEPULSE_REGENERATE_BUILTINS"] == "1" {
            try Data(generated.utf8).write(to: sourceURL)
            return
        }
        let checkedIn = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertEqual(checkedIn, generated,
                       "BuiltInPrograms.swift is stale: rerun with SIDEPULSE_REGENERATE_BUILTINS=1")
    }

    func testEmbeddedTablesEqualThePythonData() throws {
        guard let repo = LEDTestSupport.pythonRepo() else { throw XCTSkip("Python sidepulse checkout not found") }
        let input = try LEDBuiltInProgramsGenerator.load(repo: repo)

        XCTAssertEqual(AnimationLibrary.all.map { LEDBuiltInProgramsGenerator.Entry(id: $0.id, name: $0.name,
                                                                                countSpecific: $0.countSpecific) },
                       input.catalog)
        XCTAssertEqual(BuiltInPrograms.files, Dictionary(uniqueKeysWithValues: input.files.map { ($0.name, $0.program) }))
        XCTAssertEqual(AnimationProfiles.builtIn.map(\.id), input.profiles.map(\.id))
        XCTAssertEqual(AnimationProfiles.builtIn.map(\.name), input.profiles.map(\.name))
        for (profile, expected) in zip(AnimationProfiles.builtIn, input.profiles) {
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: profile.animations.map { ($0.key.rawValue, $0.value) }),
                           expected.animations, profile.id)
        }
        XCTAssertEqual(Set(input.modes), Set(AgentMode.allCases.map(\.rawValue)))
    }

    func testSwiftCaseNames() {
        for mode in AgentMode.allCases {
            XCTAssertEqual(LEDBuiltInProgramsGenerator.swiftCaseName(mode.rawValue), "\(mode)")
        }
    }
}
