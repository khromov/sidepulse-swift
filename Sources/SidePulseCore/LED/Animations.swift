import Foundation

/// A built-in LED animation. Programs are embedded in the binary (no resource
/// bundle) — see BuiltInPrograms.swift.
public struct Animation: Sendable, Equatable, Identifiable {
    public var id: String
    /// UI label, e.g. "Cyan Roll".
    public var name: String
    /// True for animations that have `-2`/`-8` variants.
    public var countSpecific: Bool

    public init(id: String, name: String, countSpecific: Bool) {
        self.id = id; self.name = name; self.countSpecific = countSpecific
    }
}

public enum AnimationLibrary {
    /// Catalog order: off, immediate-off, idle-pulse, cyan-roll, cyan-complete,
    /// amber-pulse, solid-green, kitt, kitt-red, ember-idle, ember-tide,
    /// ember-attention, ember-complete, purple-idle, purple-tide, purple-attention,
    /// purple-complete, night-rider. (Lid animations are not included: dropped.)
    public static var all: [Animation] {
        BuiltInPrograms.catalog
    }

    public static func animation(id: String) -> Animation? {
        all.first { $0.id == id }
    }

    /// Embedded file name for `animation` at `ledCount`: `<id>-2.LED` for 2 LEDs,
    /// `<id>-8.LED` for any other count (count-specific animations), else `<id>.LED`.
    public static func fileName(for animation: Animation, ledCount: Int) -> String {
        guard animation.countSpecific else { return "\(animation.id).LED" }
        return "\(animation.id)-\(ledCount == 2 ? 2 : 8).LED"
    }

    /// Program text for `id` at the given LED count (2 → `-2` variant, anything
    /// else → `-8` for count-specific animations). Trailing newline stripped.
    /// Throws `.unknownAnimation`.
    public static func program(id: String, ledCount: Int) throws -> String {
        guard let animation = animation(id: id),
              let program = BuiltInPrograms.files[fileName(for: animation, ledCount: ledCount)] else {
            throw LedError.unknownAnimation(id)
        }
        return program
    }

    /// Cyan profile defaults: working group → cyan-roll; waiting/blocked →
    /// amber-pulse; completed → cyan-complete; idle/unknown → idle-pulse.
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
    /// `profile:cyan`, `profile:ember`, `profile:purple`.
    public var id: String
    public var name: String
    /// A selection for every AgentMode.
    public var animations: [AgentMode: String]

    public init(id: String, name: String, animations: [AgentMode: String]) {
        self.id = id; self.name = name; self.animations = animations
    }
}

public enum AnimationProfiles {
    /// Cyan (defaults), Ember, Purple — mappings from the Python profiles/*.json.
    public static var builtIn: [AnimationProfile] {
        BuiltInPrograms.profiles
    }

    public static func profile(id: String) -> AnimationProfile? {
        builtIn.first { $0.id == id }
    }

    /// First built-in profile whose full mode→animation map equals `selection`.
    public static func matching(_ selection: [AgentMode: String]) -> AnimationProfile? {
        builtIn.first { $0.animations == selection }
    }
}

/// Program generation (spec led-device §9-10).
public enum LedProgram {
    /// nil → 255; else clamp(0...255, round-half-even(value)).
    /// NaN counts as nil; infinities clamp.
    public static func normalizeBrightness(_ value: Double?) -> Int {
        guard let value, !value.isNaN else { return 255 }
        return Int(min(255, max(0, value.rounded(.toNearestOrEven))))
    }

    /// Clamps an integer brightness to 0...255.
    public static func clampBrightness(_ value: Int) -> Int {
        min(255, max(0, value))
    }

    /// round(b/255*100).
    public static func brightnessPercent(_ brightness: Int) -> Int {
        Int((Double(clampBrightness(brightness)) / 255 * 100).rounded(.toNearestOrEven))
    }

    /// Scales every whole-line `brightness N` (case-insensitive) to
    /// round(norm(N)*b/255) written as lowercase `brightness X`; if none and b < 255,
    /// prepends `brightness b\n`. Lines normalized to "\n".
    ///
    /// A `brightness` token that is not the whole line (e.g. in a `;` segment) is
    /// left alone, matching Python's `re.fullmatch`.
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

    /// `applyBrightness(AnimationLibrary.program(id:ledCount:), brightness)`.
    public static func program(animationID: String, ledCount: Int, brightness: Int) throws -> String {
        applyBrightness(try AnimationLibrary.program(id: animationID, ledCount: ledCount), brightness)
    }

    /// The clamped value of a line matching `^\s*brightness\s+(\d+)\s*$`
    /// (case-insensitive), else nil.
    ///
    /// Mirrors Python's `re.fullmatch(..., re.IGNORECASE)` on a `str`: `\s` is the
    /// Unicode White_Space set plus U+001C–U+001F, `\d` is any decimal digit
    /// (general category Nd, valued like `int()`), and case folding also lets
    /// U+0130/U+0131 match `i` and U+017F match `s`.
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
            // Anything above 255 clamps to 255, so stop growing early (no overflow).
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

    /// Python `\d` for one code point: the digit's value, else nil.
    private static func decimalDigitValue(_ scalar: Unicode.Scalar) -> Int? {
        guard scalar.properties.generalCategory == .decimalNumber,
              let value = scalar.properties.numericValue else { return nil }
        return Int(value)
    }

    /// `re.IGNORECASE` comparison of `scalar` against a lowercase ASCII letter of
    /// "brightness".
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

/// Per-device write gate (spec led-device §11): skips when display state,
/// brightness and animation id are unchanged, there was no error, and the file
/// still contains the last program (self-heals external overwrites). Retries
/// errors only after `errorRetry` seconds. Not thread-safe.
///
/// Every result carries `target`. A skipped sync returns `changed == false` with an
/// empty program; a sync held back by the error backoff also returns the last error.
public final class AgentLedController {
    public let target: URL
    public var brightness: Int
    public let dryRun: Bool
    public let errorRetry: TimeInterval
    private let clock: () -> TimeInterval

    /// Display state of the last attempt (successful or not).
    public private(set) var lastState: DisplayState?
    private var lastBrightness: Int?
    private var lastAnimationID: String?
    /// Program of the last successful write.
    public private(set) var lastProgram: String?
    /// Error of the last attempt, nil after a success.
    public private(set) var lastError: String?
    private var lastAttempt: TimeInterval = 0

    public init(target: URL, brightness: Int = 255, dryRun: Bool = false, errorRetry: TimeInterval = 10,
                clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.target = target; self.brightness = brightness; self.dryRun = dryRun
        self.errorRetry = errorRetry
        self.clock = clock
    }

    /// Writes `LedProgram.program(animationID:ledCount: DeviceDiscovery.ledCount(forTarget:), brightness:)`
    /// when needed.
    ///
    /// Dry-run controllers build and validate the program but never touch the file.
    /// `write` replaces `LedWriter.write` (the sync service re-checks the device once
    /// the file is open). When it returns false nothing was written: the result is
    /// unchanged and the next sync writes again.
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

    /// Forgets everything, so the next sync writes.
    func reset() {
        lastState = nil
        lastBrightness = nil
        lastAnimationID = nil
        lastProgram = nil
        lastError = nil
        lastAttempt = 0
    }

    /// True when the device file still holds the last program we wrote (always true
    /// for dry runs). A read failure counts as "changed" and forces a rewrite.
    private func lastProgramIsCurrent() -> Bool {
        if dryRun { return true }
        guard let lastProgram else { return false }
        return LedWriter.read(target) == lastProgram
    }
}
