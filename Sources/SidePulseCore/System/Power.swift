import Foundation
import IOKit.ps
import Synchronization

// MARK: - Battery

public struct BatteryState: Sendable, Equatable {
    public var present: Bool
    public var percent: Double?
    public var onACPower: Bool

    public init(present: Bool, percent: Double?, onACPower: Bool) {
        self.present = present; self.percent = percent; self.onACPower = onACPower
    }

    public static let unknown = BatteryState(present: false, percent: nil, onACPower: true)

    public static func read() -> BatteryState {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return .unknown }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let providingAC = providing.map { $0 != kIOPSBatteryPowerValue } ?? true
        let sources = (IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]) ?? []
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let state = from(powerSourceDescription: description, providingAC: providingAC) else { continue }
            return state
        }
        return BatteryState(present: false, percent: nil, onACPower: providingAC)
    }

    /// IOPS capacities are normally already percentages, but dividing by the max keeps the value
    /// right when they are not.
    static func from(powerSourceDescription description: [String: Any], providingAC: Bool) -> BatteryState? {
        guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { return nil }
        let present = (description[kIOPSIsPresentKey] as? Bool) ?? true
        var percent: Double?
        if let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue,
           let maximum = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue, maximum > 0 {
            percent = min(100, max(0, current * 100 / maximum))
        }
        let onAC = (description[kIOPSPowerSourceStateKey] as? String).map { $0 == kIOPSACPowerValue } ?? providingAC
        return BatteryState(present: present, percent: present ? percent : nil, onACPower: onAC)
    }
}

// MARK: - Keep awake

public struct KeepAwakePolicy: Sendable {
    public var grace: TimeInterval = 300
    private var graceDeadline: Date?
    private var lastMode: AgentMode?

    public init(grace: TimeInterval = 300) { self.grace = grace }

    var pendingGraceDeadline: Date? { graceDeadline }

    /// The grace deadline is set only on entering a completed/waiting/blocked mode, so repeated
    /// refreshes never extend it.
    public mutating func agentsActive(mode: AgentMode, now: Date) -> Bool {
        defer { lastMode = mode }
        switch mode {
        case .working, .toolRunning, .longTaskProgress:
            graceDeadline = nil
            return true
        case .completed, .waitingForInput, .blockedError:
            let deadline: Date
            if let existing = graceDeadline, lastMode == mode {
                deadline = existing
            } else {
                deadline = now.addingTimeInterval(grace)
                graceDeadline = deadline
            }
            return now < deadline
        case .idleReady, .unknown:
            guard let deadline = graceDeadline else { return false }
            return now < deadline
        }
    }

    public static func safeguardActive(battery: BatteryState, minBatteryPercent: Double) -> Bool {
        guard minBatteryPercent.isFinite else { return false }
        let threshold = min(100, max(0, minBatteryPercent))
        guard threshold > 0, battery.present, !battery.onACPower, let percent = battery.percent else { return false }
        return percent < threshold
    }

    public static func shouldHold(policy: SleepPolicy, agentsActive: Bool, battery: BatteryState, minBatteryPercent: Double) -> Bool {
        let requested: Bool
        switch policy {
        case .always: requested = true
        case .agents: requested = agentsActive
        case .never: requested = false
        }
        return requested && !safeguardActive(battery: battery, minBatteryPercent: minBatteryPercent)
    }
}

/// PreventUserIdleSystemSleep still lets the display sleep, and the system drops it when the
/// process exits so nothing outlives the app.
public final class KeepAwakeAssertion: Sendable {
    public let reason: String
    private let activity = Mutex<NSObjectProtocol?>(nil)

    public init(reason: String = "SidePulse keep awake") {
        self.reason = reason
    }

    deinit {
        activity.withLock { if let current = $0 { ProcessInfo.processInfo.endActivity(current) } }
    }

    public var isHeld: Bool {
        activity.withLock { $0 != nil }
    }

    public func setHeld(_ held: Bool) {
        activity.withLock { activity in
            if held, activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled, reason: reason)
            } else if !held, let current = activity {
                activity = nil
                ProcessInfo.processInfo.endActivity(current)
            }
        }
    }
}
