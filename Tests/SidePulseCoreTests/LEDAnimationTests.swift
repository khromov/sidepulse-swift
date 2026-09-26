import XCTest
@testable import SidePulseCore

private func colors(in program: String) -> [String] {
    var found: [String] = []
    var rest = Substring(program)
    while let hash = rest.firstIndex(of: "#") {
        let candidate = rest[hash...].prefix(7)
        if candidate.count == 7, candidate.dropFirst().allSatisfy(\.isHexDigit) {
            found.append(String(candidate))
        }
        rest = rest[rest.index(after: hash)...]
    }
    return found
}

private func withoutColors(_ program: String) -> String {
    var result = program
    for color in Set(colors(in: program)) { result = result.replacingOccurrences(of: color, with: "#COLOR") }
    return result
}

final class LEDAnimationLibraryTests: XCTestCase {
    let expectedCatalog: [(String, String, Bool)] = [
        ("off", "Slow Off", false),
        ("immediate-off", "Immediate Off", false),
        ("idle-pulse", "Idle Pulse", true),
        ("cyan-roll", "Cyan Roll", true),
        ("cyan-complete", "Cyan Complete", false),
        ("amber-pulse", "Amber Pulse", false),
        ("solid-green", "Solid Green", false),
        ("kitt", "KITT Scanner", true),
        ("kitt-red", "KITT Scanner Red", true),
        ("ember-idle", "Ember Idle", true),
        ("ember-tide", "Ember Tide", true),
        ("ember-attention", "Ember Attention", false),
        ("ember-complete", "Ember Complete", false),
        ("purple-idle", "Purple Idle", true),
        ("purple-tide", "Purple Tide", true),
        ("purple-attention", "Purple Attention", false),
        ("purple-complete", "Purple Complete", false),
        ("night-rider", "Night Rider", true),
        ("solid-red", "Solid Red", false),
        ("solid-blue", "Solid Blue", false),
        ("red-double-blink", "Red Double Blink", false),
        ("blue-double-blink", "Blue Double Blink", false),
    ]

    func testCatalogOrderNamesAndVariants() {
        XCTAssertEqual(AnimationLibrary.all.map(\.id), expectedCatalog.map(\.0))
        XCTAssertEqual(AnimationLibrary.all.map(\.name), expectedCatalog.map(\.1))
        XCTAssertEqual(AnimationLibrary.all.map(\.countSpecific), expectedCatalog.map(\.2))
        XCTAssertFalse(AnimationLibrary.all.contains(where: { LEDTestSupport.isLidAnimation($0.id) }), "lid animations are dropped")
        XCTAssertEqual(AnimationLibrary.animation(id: "kitt")?.name, "KITT Scanner")
        XCTAssertNil(AnimationLibrary.animation(id: "lid-open"))
        XCTAssertNil(AnimationLibrary.animation(id: "default"))
    }

    func testEveryEmbeddedFileIsReachable() {
        var reachable = Set<String>()
        for animation in AnimationLibrary.all {
            for count in [2, 8] { reachable.insert(AnimationLibrary.fileName(for: animation, ledCount: count)) }
        }
        XCTAssertEqual(reachable, Set(BuiltInPrograms.files.keys).union(ExtraPrograms.files.keys))
        XCTAssertEqual(BuiltInPrograms.files.count, 27)
        XCTAssertTrue(Set(BuiltInPrograms.files.keys).isDisjoint(with: ExtraPrograms.files.keys))
    }

    func testFileNameVariants() throws {
        let idle = try XCTUnwrap(AnimationLibrary.animation(id: "idle-pulse"))
        let roll = try XCTUnwrap(AnimationLibrary.animation(id: "cyan-roll"))
        let off = try XCTUnwrap(AnimationLibrary.animation(id: "off"))
        XCTAssertEqual(AnimationLibrary.fileName(for: idle, ledCount: 2), "idle-pulse-2.LED")
        XCTAssertEqual(AnimationLibrary.fileName(for: idle, ledCount: 8), "idle-pulse-8.LED")
        XCTAssertEqual(AnimationLibrary.fileName(for: roll, ledCount: 5), "cyan-roll-8.LED")
        XCTAssertEqual(AnimationLibrary.fileName(for: roll, ledCount: 0), "cyan-roll-8.LED")
        XCTAssertEqual(AnimationLibrary.fileName(for: off, ledCount: 2), "off.LED")
    }

    func testProgramsMatchPythonVectors() throws {
        XCTAssertEqual(try AnimationLibrary.program(id: "off", ledCount: 2), "off 1s")
        XCTAssertEqual(try AnimationLibrary.program(id: "off", ledCount: 8), "off 1s")
        XCTAssertEqual(try AnimationLibrary.program(id: "immediate-off", ledCount: 2), "off")
        XCTAssertEqual(try AnimationLibrary.program(id: "immediate-off", ledCount: 8), "off")
        XCTAssertEqual(try AnimationLibrary.program(id: "idle-pulse", ledCount: 8),
                       "off 2s\n2:#006060 3:#00E5FF 4:#00E5FF 5:#006060 2s ease\nrepeat")
        XCTAssertEqual(try AnimationLibrary.program(id: "idle-pulse", ledCount: 2),
                       "off 2s\n0:#006060 1:#006060 2s ease\nrepeat")
        XCTAssertEqual(try AnimationLibrary.program(id: "cyan-roll", ledCount: 2),
                       "off 320ms cosine\n0:#00E5FF 760ms pulse 0ms; 1:#00E5FF 760ms pulse 260ms\nrepeat")
        XCTAssertEqual(try AnimationLibrary.program(id: "cyan-roll", ledCount: 5),
                       try AnimationLibrary.program(id: "cyan-roll", ledCount: 8))
        XCTAssertTrue(try AnimationLibrary.program(id: "cyan-roll", ledCount: 2).contains("1:#00E5FF"))
        XCTAssertFalse(try AnimationLibrary.program(id: "cyan-roll", ledCount: 2).contains("2:#00E5FF"))
        XCTAssertEqual(try AnimationLibrary.program(id: "solid-green", ledCount: 8), "#00FF66 320ms cosine")
        XCTAssertEqual(try AnimationLibrary.program(id: "cyan-complete", ledCount: 2), "#00E5FF 320ms cosine")
        XCTAssertTrue(try AnimationLibrary.program(id: "amber-pulse", ledCount: 8).contains("#FF3A00 1.6s pulse"))
        XCTAssertTrue(try AnimationLibrary.program(id: "kitt-red", ledCount: 8).contains("7:#FF1800"))
        XCTAssertTrue(try AnimationLibrary.program(id: "ember-tide", ledCount: 2).contains("1:#F23819 760ms pulse 260ms"))
        XCTAssertTrue(try AnimationLibrary.program(id: "ember-tide", ledCount: 8).contains("7:#F23819 760ms pulse 665ms"))
        XCTAssertTrue(try AnimationLibrary.program(id: "night-rider", ledCount: 8).contains("7:#FF1200 360ms pulse 630ms"))
        XCTAssertTrue(try AnimationLibrary.program(id: "purple-idle", ledCount: 8)
            .contains("2:#9F009F 3:#FF00FF 4:#FF00FF 5:#9F009F 2s ease"))
        XCTAssertTrue(try AnimationLibrary.program(id: "purple-tide", ledCount: 2).contains("1:#FF00FF 760ms pulse 260ms"))
        XCTAssertTrue(try AnimationLibrary.program(id: "purple-attention", ledCount: 8).contains("#FF00FF 1.6s pulse"))
        XCTAssertEqual(try AnimationLibrary.program(id: "purple-complete", ledCount: 8), "#FF00FF 320ms cosine")
        XCTAssertEqual(try AnimationLibrary.program(id: "purple-idle", ledCount: 2), "off 2s\n0:#FF00FF 1:#FF00FF 2s ease\nrepeat")
        XCTAssertEqual(try AnimationLibrary.program(id: "ember-idle", ledCount: 2), "off 2s\n0:#F23819 1:#F23819 2s ease\nrepeat")
        XCTAssertEqual(try AnimationLibrary.program(id: "ember-idle", ledCount: 8),
                       "off 2s\n2:#972310 3:#F23819 4:#F23819 5:#972310 2s ease\nrepeat")
    }

    func testUnknownAnimationThrows() {
        for id in ["nope", "lid-open", "default", ""] {
            XCTAssertThrowsError(try AnimationLibrary.program(id: id, ledCount: 8)) { error in
                XCTAssertEqual(error as? LedError, .unknownAnimation(id))
            }
        }
    }

    func testEveryProgramIsCleanAndValidWithRoomForBrightness() throws {
        for (name, program) in BuiltInPrograms.files {
            XCTAssertEqual(program, program.trimmingCharacters(in: .whitespacesAndNewlines), name)
            XCTAssertFalse(program.contains("\r"), name)
            XCTAssertFalse(program.contains("\\"), name)
            XCTAssertNoThrow(try LedText.validate(program), name)
            XCTAssertNoThrow(try LedText.validate(LedProgram.applyBrightness(program, 128)), name)
            XCTAssertNoThrow(try LedText.validate(LedProgram.applyBrightness(program, 1)), name)
        }
        let largest = BuiltInPrograms.files.values.map(\.utf8.count).max()
        XCTAssertEqual(largest, 449)
        XCTAssertEqual(Set(BuiltInPrograms.files.filter { $0.value.utf8.count == 449 }.keys), ["kitt-8.LED", "kitt-red-8.LED"])
    }

    func testColorFamiliesUseTheExactCyanShapes() throws {
        for count in [2, 8] {
            let families: [(String, String, String)] = [
                ("idle-pulse", "ember-idle", "purple-idle"),
                ("cyan-roll", "ember-tide", "purple-tide"),
                ("amber-pulse", "ember-attention", "purple-attention"),
                ("cyan-complete", "ember-complete", "purple-complete"),
            ]
            for (cyan, ember, purple) in families {
                let shape = withoutColors(try AnimationLibrary.program(id: cyan, ledCount: count))
                XCTAssertEqual(withoutColors(try AnimationLibrary.program(id: ember, ledCount: count)), shape, "\(ember) \(count)")
                XCTAssertEqual(withoutColors(try AnimationLibrary.program(id: purple, ledCount: count)), shape, "\(purple) \(count)")
            }
        }
    }

    func testIdleGradientsAreSymmetricAndBrighterInTheCenter() throws {
        for id in ["idle-pulse", "ember-idle", "purple-idle"] {
            let line = LedText.splitLines(try AnimationLibrary.program(id: id, ledCount: 8))[1]
            let found = colors(in: line)
            XCTAssertEqual(found.count, 4, id)
            XCTAssertEqual(found[0], found[3], id)
            XCTAssertEqual(found[1], found[2], id)
            func peak(_ color: String) -> UInt8 {
                let hex = Array(color.dropFirst())
                return stride(from: 0, to: 6, by: 2).map { UInt8(String(hex[$0...$0 + 1]), radix: 16)! }.max()!
            }
            XCTAssertLessThan(peak(found[0]), peak(found[1]), id)
        }
    }

    func testPurpleAndEmberUseTheirPrimaryColor() throws {
        for count in [2, 8] {
            for id in ["purple-tide", "purple-attention", "purple-complete"] {
                XCTAssertEqual(Set(colors(in: try AnimationLibrary.program(id: id, ledCount: count))), ["#FF00FF"], id)
            }
            for id in ["ember-tide", "ember-attention", "ember-complete"] {
                XCTAssertEqual(Set(colors(in: try AnimationLibrary.program(id: id, ledCount: count))), ["#F23819"], id)
            }
        }
    }

    func testDefaultAnimationPerMode() {
        let expected: [AgentMode: String] = [
            .working: "ember-tide", .toolRunning: "ember-tide", .longTaskProgress: "ember-tide",
            .waitingForInput: "solid-red", .blockedError: "red-double-blink",
            .completed: "solid-green", .idleReady: "solid-blue", .unknown: "blue-double-blink",
        ]
        for mode in AgentMode.allCases {
            XCTAssertEqual(AnimationLibrary.defaultAnimationID(for: mode), expected[mode], mode.rawValue)
        }
    }
}

final class LEDProfileTests: XCTestCase {
    func testBuiltInProfiles() throws {
        XCTAssertEqual(AnimationProfiles.builtIn.map(\.id), ["profile:signal", "profile:cyan", "profile:ember", "profile:purple"])
        XCTAssertEqual(AnimationProfiles.builtIn.map(\.name), ["Signal", "Cyan", "Ember", "Purple"])
        for profile in AnimationProfiles.builtIn {
            XCTAssertEqual(Set(profile.animations.keys), Set(AgentMode.allCases), profile.id)
            for id in profile.animations.values { XCTAssertNotNil(AnimationLibrary.animation(id: id), id) }
            let working = Set(AgentMode.workingGroup.map { profile.animations[$0] })
            XCTAssertEqual(working.count, 1, "working group shares one selection in \(profile.id)")
        }
        let defaultProfile = try XCTUnwrap(AnimationProfiles.profile(id: "profile:signal"))
        for mode in AgentMode.allCases {
            XCTAssertEqual(defaultProfile.animations[mode], AnimationLibrary.defaultAnimationID(for: mode))
        }
        let cyan = try XCTUnwrap(AnimationProfiles.profile(id: "profile:cyan"))
        XCTAssertEqual(cyan.animations, [
            .idleReady: "idle-pulse", .working: "cyan-roll", .toolRunning: "cyan-roll",
            .waitingForInput: "amber-pulse", .longTaskProgress: "cyan-roll",
            .blockedError: "amber-pulse", .completed: "cyan-complete", .unknown: "idle-pulse",
        ])
        let ember = try XCTUnwrap(AnimationProfiles.profile(id: "profile:ember"))
        XCTAssertEqual(ember.animations, [
            .idleReady: "ember-idle", .working: "ember-tide", .toolRunning: "ember-tide",
            .waitingForInput: "ember-attention", .longTaskProgress: "ember-tide",
            .blockedError: "ember-attention", .completed: "ember-complete", .unknown: "ember-idle",
        ])
        let purple = try XCTUnwrap(AnimationProfiles.profile(id: "profile:purple"))
        XCTAssertEqual(purple.animations, [
            .idleReady: "purple-idle", .working: "purple-tide", .toolRunning: "purple-tide",
            .waitingForInput: "purple-attention", .longTaskProgress: "purple-tide",
            .blockedError: "purple-attention", .completed: "purple-complete", .unknown: "purple-idle",
        ])
        let signal = try XCTUnwrap(AnimationProfiles.profile(id: "profile:signal"))
        XCTAssertEqual(signal.animations, [
            .idleReady: "solid-blue", .working: "ember-tide", .toolRunning: "ember-tide",
            .waitingForInput: "solid-red", .longTaskProgress: "ember-tide",
            .blockedError: "red-double-blink", .completed: "solid-green", .unknown: "blue-double-blink",
        ])
        XCTAssertNil(AnimationProfiles.profile(id: "profile:default"))
    }

    func testSignalPrograms() throws {
        XCTAssertEqual(try LedProgram.program(animationID: "solid-red", ledCount: 2, brightness: 255), "#FF0000 320ms cosine")
        XCTAssertEqual(try LedProgram.program(animationID: "solid-blue", ledCount: 8, brightness: 128),
                       "brightness 128\n#0000FF 320ms cosine")
        XCTAssertEqual(try LedProgram.program(animationID: "ember-complete", ledCount: 2, brightness: 255), "#F23819 320ms cosine")
        XCTAssertEqual(try LedProgram.program(animationID: "red-double-blink", ledCount: 2, brightness: 255), """
            off 120ms none
            #FF0000 120ms none
            off 120ms none
            #FF0000 120ms none
            off 120ms none
            #FF0000 1.5s none
            repeat
            """)
        XCTAssertEqual(try LedProgram.program(animationID: "blue-double-blink", ledCount: 8, brightness: 128), """
            brightness 128
            off 120ms none
            #0000FF 120ms none
            off 120ms none
            #0000FF 120ms none
            off 120ms none
            #0000FF 1.5s none
            repeat
            """)
    }

    func testMatching() throws {
        let defaults = Dictionary(uniqueKeysWithValues: AgentMode.allCases.map { ($0, AnimationLibrary.defaultAnimationID(for: $0)) })
        XCTAssertEqual(AnimationProfiles.matching(defaults)?.id, "profile:signal")
        let purple = try XCTUnwrap(AnimationProfiles.profile(id: "profile:purple"))
        XCTAssertEqual(AnimationProfiles.matching(purple.animations)?.id, "profile:purple")
        var custom = defaults
        custom[.completed] = "cyan-complete"
        XCTAssertNil(AnimationProfiles.matching(custom))
    }
}

final class LEDProgramTests: XCTestCase {
    func testNormalizeBrightnessRoundsHalfToEven() {
        let vectors: [(Double?, Int)] = [
            (nil, 255), (127.5, 128), (128.5, 128), (0.5, 0), (1.5, 2), (2.5, 2), (254.5, 254),
            (255.5, 255), (-3, 0), (300, 255), (25, 25), (0.49999, 0),
            (.nan, 255), (.infinity, 255), (-.infinity, 0),
        ]
        for (value, expected) in vectors {
            XCTAssertEqual(LedProgram.normalizeBrightness(value), expected, String(describing: value))
        }
    }

    func testBrightnessPercent() {
        let vectors: [(Int, Int)] = [
            (0, 0), (1, 0), (2, 1), (25, 10), (64, 25), (127, 50), (128, 50), (191, 75),
            (254, 100), (255, 100), (300, 100), (-5, 0),
        ]
        for (value, expected) in vectors {
            XCTAssertEqual(LedProgram.brightnessPercent(value), expected, "\(value)")
        }
    }

    func testApplyBrightnessPrependsALine() {
        let vectors: [(String, Int, String)] = [
            ("#00FF66 320ms cosine", 128, "brightness 128\n#00FF66 320ms cosine"),
            ("off\n#FF0000 pulse\nrepeat", 64, "brightness 64\noff\n#FF0000 pulse\nrepeat"),
            ("#FF0000", 0, "brightness 0\n#FF0000"),
            ("#fff", -4, "brightness 0\n#fff"),
            ("#fff", 255, "#fff"),
            ("#fff", 999, "#fff"),
        ]
        for (program, brightness, expected) in vectors {
            XCTAssertEqual(LedProgram.applyBrightness(program, brightness), expected, "\(program.debugDescription) @ \(brightness)")
        }
    }

    func testNoBuiltInProgramSetsItsOwnBrightness() {
        for (name, program) in BuiltInPrograms.files.merging(ExtraPrograms.files, uniquingKeysWith: { first, _ in first }) {
            XCTAssertFalse(program.lowercased().contains("brightness"), name)
        }
    }

    func testProgramCombinesAnimationAndBrightness() throws {
        XCTAssertEqual(try LedProgram.program(animationID: "solid-green", ledCount: 8, brightness: 128),
                       "brightness 128\n#00FF66 320ms cosine")
        XCTAssertEqual(try LedProgram.program(animationID: "cyan-roll", ledCount: 2, brightness: 255),
                       "off 320ms cosine\n0:#00E5FF 760ms pulse 0ms; 1:#00E5FF 760ms pulse 260ms\nrepeat")
        let kitt = try LedProgram.program(animationID: "kitt", ledCount: 8, brightness: 128)
        XCTAssertNoThrow(try LedText.validate(kitt))
        XCTAssertLessThanOrEqual(kitt.utf8.count, 512)
        XCTAssertTrue(kitt.hasPrefix("brightness 128\n"))
        XCTAssertTrue(kitt.contains("7:#00E5FF 320ms pulse 595ms"))
        XCTAssertTrue(kitt.contains("6:#00E5FF 320ms pulse 0ms"))
        XCTAssertTrue(try LedProgram.program(animationID: "kitt-red", ledCount: 8, brightness: 255)
            .contains("7:#FF1800 320ms pulse 595ms"))
        XCTAssertThrowsError(try LedProgram.program(animationID: "nope", ledCount: 8, brightness: 255))
    }

    func testEveryAnimationValidatesForEveryModeAndCount() throws {
        for animation in AnimationLibrary.all {
            for count in [2, 8] {
                for brightness in [0, 25, 128, 255] {
                    let program = try LedProgram.program(animationID: animation.id, ledCount: count, brightness: brightness)
                    XCTAssertNoThrow(try LedText.validate(program), "\(animation.id) \(count) \(brightness)")
                }
            }
        }
    }
}
