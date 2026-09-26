import Foundation
import IOKit.ps
import IOKit.pwr_mgt

// MARK: - Battery

public struct BatteryState: Sendable, Equatable {
    public var present: Bool
    /// 0...100, nil when unknown.
    public var percent: Double?
    public var onACPower: Bool
    public var charging: Bool

    public init(present: Bool, percent: Double?, onACPower: Bool, charging: Bool) {
        self.present = present; self.percent = percent; self.onACPower = onACPower; self.charging = charging
    }

    public static let unknown = BatteryState(present: false, percent: nil, onACPower: true, charging: false)

    /// Reads the internal battery via IOKit power sources
    /// (IOPSCopyPowerSourcesInfo / IOPSCopyPowerSourcesList / IOPSGetPowerSourceDescription).
    ///
    /// Macs without a battery report `present == false` and the providing source
    /// (normally AC). `unknown` when IOKit returns nothing.
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
        return BatteryState(present: false, percent: nil, onACPower: providingAC, charging: false)
    }

    /// Interprets one IOPS description dictionary. nil unless it describes the
    /// internal battery. Percent = current / max capacity (IOPS reports both,
    /// normally already in percent), clamped to 0...100.
    static func from(powerSourceDescription description: [String: Any], providingAC: Bool) -> BatteryState? {
        guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { return nil }
        let present = (description[kIOPSIsPresentKey] as? Bool) ?? true
        var percent: Double?
        if let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue,
           let maximum = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue, maximum > 0 {
            percent = min(100, max(0, current * 100 / maximum))
        }
        let onAC = (description[kIOPSPowerSourceStateKey] as? String).map { $0 == kIOPSACPowerValue } ?? providingAC
        let charging = (description[kIOPSIsChargingKey] as? Bool) ?? false
        return BatteryState(present: present, percent: present ? percent : nil, onACPower: onAC, charging: charging)
    }
}

// MARK: - Keep awake

/// Pure policy logic for keep-awake (spec status-bar §9).
public struct KeepAwakePolicy: Sendable {
    /// Grace after an agent completes / asks, during which we keep holding.
    public var grace: TimeInterval = 300
    private var graceDeadline: Date?
    private var lastMode: AgentMode?

    public init(grace: TimeInterval = 300) { self.grace = grace }

    /// Pending grace deadline, if any (tests).
    var pendingGraceDeadline: Date? { graceDeadline }

    /// Working group → true (clears grace). Completed / waiting / blocked → sets a
    /// grace deadline when entering that mode (first time), true until it passes.
    /// Other modes → true while an earlier deadline is pending.
    ///
    /// "Entering" means the mode differs from the previous call's mode or no
    /// deadline is set, so repeated refreshes in the same mode never extend it.
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

    /// Battery present, not on AC, percent < threshold (threshold <= 0 disables).
    ///
    /// The threshold is clamped to 0...100; an unknown percent never triggers.
    public static func safeguardActive(battery: BatteryState, minBatteryPercent: Double) -> Bool {
        guard minBatteryPercent.isFinite else { return false }
        let threshold = min(100, max(0, minBatteryPercent))
        guard threshold > 0, battery.present, !battery.onACPower, let percent = battery.percent else { return false }
        return percent < threshold
    }

    /// (always || (agents && agentsActive)) && !safeguard.
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

/// Holds an IOKit power assertion (PreventUserIdleSystemSleep) while held: the
/// Mac does not idle-sleep, though the display may. Thread-safe. The system drops
/// the assertion when the process exits, so nothing outlives the app.
public final class KeepAwakeAssertion: @unchecked Sendable {
    /// The assertion's name, shown by `pmset -g assertions`.
    public let reason: String
    private let lock = NSLock()
    private var assertion: IOPMAssertionID?
    private var error: String?

    public init(reason: String = "SidePulse keep awake") {
        self.reason = reason
    }

    deinit {
        if let assertion { IOPMAssertionRelease(assertion) }
    }

    public var isHeld: Bool {
        lock.lock(); defer { lock.unlock() }
        return assertion != nil
    }

    /// Why the last attempt to hold failed, nil after a successful one.
    public var lastError: String? {
        lock.lock(); defer { lock.unlock() }
        return error
    }

    /// Creates or releases the assertion; does nothing when already in that state.
    public func setHeld(_ held: Bool) {
        lock.lock(); defer { lock.unlock() }
        if held {
            guard assertion == nil else { return }
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
            if result == kIOReturnSuccess {
                assertion = id
                error = nil
            } else {
                error = "IOPMAssertionCreateWithName failed (IOReturn \(result))"
            }
        } else if let id = assertion {
            assertion = nil
            IOPMAssertionRelease(id)
        }
    }
}
