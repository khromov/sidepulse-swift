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

    /// Only animations that end dark, so a sleeping Mac's LEDs never play all night.
    public static let sleepAnimationIDs = ["fade-off", "lid-closed", "off", "immediate-off"]
    public static let defaultSleepAnimationID = "fade-off"

    public static var sleepAnimations: [Animation] {
        sleepAnimationIDs.compactMap { animation(id: $0) }
    }

    /// The Signal profile.
    public static func defaultAnimationID(for mode: AgentMode) -> String {
        switch mode {
        case .working, .toolRunning, .longTaskProgress: return "ember-tide"
        case .waitingForInput: return "solid-red"
        case .blockedError: return "red-double-blink"
        case .completed: return "solid-green"
        case .idleReady: return "solid-blue"
        case .unknown: return "blue-double-blink"
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
    /// The default (Signal) comes first so the picker lists it first.
    public static var builtIn: [AnimationProfile] {
        ExtraPrograms.profiles + BuiltInPrograms.profiles
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

    /// Built-in animations never set their own brightness (a test checks), so dimming is one prepended line.
    public static func applyBrightness(_ program: String, _ brightness: Int) -> String {
        let value = clampBrightness(brightness)
        return value >= 255 ? program : "brightness \(value)\n\(program)"
    }

    public static func program(animationID: String, ledCount: Int, brightness: Int) throws -> String {
        applyBrightness(try AnimationLibrary.program(id: animationID, ledCount: ledCount), brightness)
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
