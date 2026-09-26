import Foundation

public struct Animation: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var countSpecific: Bool

    public init(id: String, name: String, countSpecific: Bool) {
        self.id = id; self.name = name; self.countSpecific = countSpecific
    }
}

public enum AnimationLibrary {
    public static var all: [Animation] {
        BuiltInPrograms.catalog + ExtraPrograms.catalog
    }

    public static func animation(id: String) -> Animation? {
        all.first { $0.id == id }
    }

    public static func fileName(for animation: Animation, ledCount: Int) -> String {
        guard animation.countSpecific else { return "\(animation.id).LED" }
        return "\(animation.id)-\(ledCount == 2 ? 2 : 8).LED"
    }

    public static func program(id: String, ledCount: Int) throws -> String {
        guard let animation = animation(id: id),
              let program = BuiltInPrograms.files[fileName(for: animation, ledCount: ledCount)]
                ?? ExtraPrograms.files[fileName(for: animation, ledCount: ledCount)] else {
            throw LedError.unknownAnimation(id)
        }
        return program
    }

    public static func defaultAnimationID(for mode: AgentMode) -> String {
        switch mode {
        case .working, .toolRunning, .longTaskProgress: return "cyan-roll"
        case .waitingForInput, .blockedError: return "amber-pulse"
        case .completed: return "cyan-complete"
        case .idleReady, .unknown: return "idle-pulse"
        }
    }
}

public struct AnimationProfile: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var animations: [AgentMode: String]

    public init(id: String, name: String, animations: [AgentMode: String]) {
        self.id = id; self.name = name; self.animations = animations
    }
}

public enum AnimationProfiles {
    public static var builtIn: [AnimationProfile] {
        BuiltInPrograms.profiles + ExtraPrograms.profiles
    }

    public static func profile(id: String) -> AnimationProfile? {
        builtIn.first { $0.id == id }
    }

    public static func matching(_ selection: [AgentMode: String]) -> AnimationProfile? {
        builtIn.first { $0.animations == selection }
    }
}

public enum LedProgram {
    public static func normalizeBrightness(_ value: Double?) -> Int {
        guard let value, !value.isNaN else { return 255 }
        return Int(min(255, max(0, value.rounded(.toNearestOrEven))))
    }

    public static func clampBrightness(_ value: Int) -> Int {
        min(255, max(0, value))
    }

    public static func brightnessPercent(_ brightness: Int) -> Int {
        Int((Double(clampBrightness(brightness)) / 255 * 100).rounded(.toNearestOrEven))
    }

    /// A `brightness` token that is not the whole line (e.g. in a `;` segment) is left alone,
    /// matching Python's `re.fullmatch`.
    public static func applyBrightness(_ program: String, _ brightness: Int) -> String {
        let value = clampBrightness(brightness)
        var foundBrightness = false
        let lines = LedText.splitLines(program).map { line -> String in
            guard let authored = authoredBrightness(line) else { return line }
            foundBrightness = true
            let scaled = (Double(authored * value) / 255).rounded(.toNearestOrEven)
            return "brightness \(Int(scaled))"
        }
        let joined = lines.joined(separator: "\n")
        if foundBrightness || value >= 255 { return joined }
        return "brightness \(value)\n\(joined)"
    }

    public static func program(animationID: String, ledCount: Int, brightness: Int) throws -> String {
        applyBrightness(try AnimationLibrary.program(id: animationID, ledCount: ledCount), brightness)
    }

    /// Hand-rolled `^\s*brightness\s+(\d+)\s*$` so it matches exactly like Python's Unicode
    /// `re.fullmatch(..., re.IGNORECASE)`.
    static func authoredBrightness(_ line: String) -> Int? {
        let scalars = Array(line.unicodeScalars)
        var index = 0
        func skipWhitespace() -> Int {
            let start = index
            while index < scalars.count, isPythonWhitespace(scalars[index]) { index += 1 }
            return index - start
        }
        _ = skipWhitespace()
        for expected in "brightness".unicodeScalars {
            guard index < scalars.count, matchesIgnoringCase(scalars[index], expected) else { return nil }
            index += 1
        }
        guard skipWhitespace() > 0 else { return nil }
        var value = 0
        var digits = 0
        while index < scalars.count, let digit = decimalDigitValue(scalars[index]) {
            // Anything above 255 clamps anyway, so cap early to avoid overflow.
            value = min(value * 10 + digit, 1000)
            digits += 1
            index += 1
        }
        guard digits > 0 else { return nil }
        _ = skipWhitespace()
        guard index == scalars.count else { return nil }
        return clampBrightness(value)
    }

    /// Python `\s` / `str.isspace()` for one code point.
    private static func isPythonWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || (0x1C...0x1F).contains(scalar.value)
    }

    /// Python `\d` for one code point.
    private static func decimalDigitValue(_ scalar: Unicode.Scalar) -> Int? {
        guard scalar.properties.generalCategory == .decimalNumber,
              let value = scalar.properties.numericValue else { return nil }
        return Int(value)
    }

    /// Python's `re.IGNORECASE` also folds U+0130/U+0131 to `i` and U+017F to `s`.
    private static func matchesIgnoringCase(_ scalar: Unicode.Scalar, _ expected: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case expected.value, expected.value - 0x20: return true
        case 0x130, 0x131: return expected == "i"
        case 0x17F: return expected == "s"
        default: return false
        }
    }
}

public struct LedSyncResult: Sendable, Equatable {
    public var changed: Bool
    public var program: String
    public var target: URL?
    public var error: String?

    public init(changed: Bool, program: String = "", target: URL? = nil, error: String? = nil) {
        self.changed = changed; self.program = program; self.target = target; self.error = error
    }
}

/// Skips unchanged writes but re-reads the file so external overwrites self-heal; not thread-safe.
public final class AgentLedController {
    public let target: URL
    public var brightness: Int
    public let dryRun: Bool
    public let errorRetry: TimeInterval
    private let clock: () -> TimeInterval

    /// Set by every attempt, successful or not.
    public private(set) var lastState: DisplayState?
    private var lastBrightness: Int?
    private var lastAnimationID: String?
    /// Set only by a successful write.
    public private(set) var lastProgram: String?
    public private(set) var lastError: String?
    private var lastAttempt: TimeInterval = 0

    public init(target: URL, brightness: Int = 255, dryRun: Bool = false, errorRetry: TimeInterval = 10,
                clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.target = target; self.brightness = brightness; self.dryRun = dryRun
        self.errorRetry = errorRetry
        self.clock = clock
    }

    /// `write` lets the sync service re-check the device once the file is open; when it returns
    /// false nothing was written and the next sync tries again.
    public func sync(mode: AgentMode, animationID: String, write: ((String) throws -> Bool)? = nil) -> LedSyncResult {
        let state = mode.displayState
        let brightness = LedProgram.clampBrightness(self.brightness)
        let unchanged = state == lastState && brightness == lastBrightness && animationID == lastAnimationID
        let now = clock()

        if unchanged && lastError == nil && lastProgramIsCurrent() {
            return LedSyncResult(changed: false, target: target)
        }
        if unchanged, let lastError, now - lastAttempt < errorRetry {
            return LedSyncResult(changed: false, target: target, error: lastError)
        }

        lastAttempt = now
        lastState = state
        lastBrightness = brightness
        lastAnimationID = animationID
        do {
            let program = try LedProgram.program(animationID: animationID,
                                                 ledCount: DeviceDiscovery.ledCount(forTarget: target),
                                                 brightness: brightness)
            if dryRun {
                try LedText.validate(program)
            } else if !(try write?(program) ?? LedWriter.write(program, to: target)) {
                reset()
                return LedSyncResult(changed: false, target: target)
            }
            lastProgram = program
            lastError = nil
            return LedSyncResult(changed: true, program: program, target: target)
        } catch {
            lastError = error.localizedDescription
            return LedSyncResult(changed: false, target: target, error: lastError)
        }
    }

    func reset() {
        lastState = nil
        lastBrightness = nil
        lastAnimationID = nil
        lastProgram = nil
        lastError = nil
        lastAttempt = 0
    }

    private func lastProgramIsCurrent() -> Bool {
        if dryRun { return true }
        guard let lastProgram else { return false }
        return LedWriter.read(target) == lastProgram
    }
}
