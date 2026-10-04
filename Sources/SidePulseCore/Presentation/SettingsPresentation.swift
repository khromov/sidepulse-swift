import Foundation

/// Python `ANIMATION_UI_STATES` minus the dropped lid states.
public enum AnimationStateRow: String, CaseIterable, Sendable, Identifiable {
    case idle, working, waiting, blocked, completed, unknown

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .idle: return AgentMode.idleReady.label
        case .working: return "Working / Tool / Long Task"
        case .waiting: return AgentMode.waitingForInput.label
        case .blocked: return AgentMode.blockedError.label
        case .completed: return AgentMode.completed.label
        case .unknown: return AgentMode.unknown.label
        }
    }

    public var mode: AgentMode {
        switch self {
        case .idle: return .idleReady
        case .working: return .working
        case .waiting: return .waitingForInput
        case .blocked: return .blockedError
        case .completed: return .completed
        case .unknown: return .unknown
        }
    }

    public var modes: [AgentMode] { self == .working ? AgentMode.workingGroup : [mode] }

    public init(mode: AgentMode) {
        switch mode {
        case .idleReady: self = .idle
        case .working, .toolRunning, .longTaskProgress: self = .working
        case .waitingForInput: self = .waiting
        case .blockedError: self = .blocked
        case .completed: self = .completed
        case .unknown: self = .unknown
        }
    }
}

public struct DurationChoice: Sendable, Hashable, Identifiable {
    public var seconds: TimeInterval
    public var label: String
    public var isCustom: Bool

    public init(seconds: TimeInterval, label: String, isCustom: Bool = false) {
        self.seconds = seconds; self.label = label; self.isCustom = isCustom
    }

    public var id: TimeInterval { seconds }
}

public enum SettingsChoices {
    public static let idleTimeoutPresets: [TimeInterval] = [900, 1800, 3600, 7200, 14_400]
    public static let retentionPresets: [TimeInterval] = [43_200, 86_400, 172_800, 604_800]
    public static let batteryPercentRange: ClosedRange<Double> = 0...100
    public static let batteryPercentStep: Double = 5

    public static func durationChoices(presets: [TimeInterval], current: TimeInterval) -> [DurationChoice] {
        var choices = presets.map { DurationChoice(seconds: $0, label: durationLabel($0)) }
        if current.isFinite, current > 0, !presets.contains(where: { abs($0 - current) < 0.5 }) {
            choices.append(DurationChoice(seconds: current, label: durationLabel(current), isCustom: true))
            choices.sort { $0.seconds < $1.seconds }
        }
        return choices
    }

    public static func selectedSeconds(in choices: [DurationChoice], current: TimeInterval) -> TimeInterval {
        choices.min(by: { abs($0.seconds - current) < abs($1.seconds - current) })?.seconds ?? current
    }

    public static func durationLabel(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0 min" }
        if seconds < 3600 { return "\(number(seconds / 60)) min" }
        let hours = seconds / 3600
        if hours <= 48 || seconds.truncatingRemainder(dividingBy: 86_400) != 0 {
            return plural(hours, "hour")
        }
        return plural(seconds / 86_400, "day")
    }

    /// 0 disables the low-battery safeguard.
    public static func batteryThresholdLabel(_ percent: Double) -> String {
        guard percent.isFinite, percent > 0 else { return "Off" }
        return "\(Int(percent.rounded()))%"
    }

    public static func snapBatteryPercent(_ value: Double) -> Double {
        guard value.isFinite else { return batteryPercentRange.lowerBound }
        let snapped = (value / batteryPercentStep).rounded() * batteryPercentStep
        return min(batteryPercentRange.upperBound, max(batteryPercentRange.lowerBound, snapped))
    }

    private static func plural(_ value: Double, _ unit: String) -> String {
        "\(number(value)) \(unit)\(value == 1 ? "" : "s")"
    }

    private static func number(_ value: Double) -> String { String(format: "%g", value) }
}

public enum DevicePresentation {
    /// No brightness lands on an exact .5, so the rounding mode doesn't matter.
    public static func brightnessPercent(_ brightness: Int) -> Int {
        Int((Double(min(255, max(0, brightness))) / 255 * 100).rounded())
    }

    public static func brightnessLabel(_ brightness: Int) -> String {
        "Brightness \(brightnessPercent(brightness))%"
    }

    public static func brightness(fromSlider value: Double) -> Int {
        guard value.isFinite else { return 255 }
        return Int(min(255, max(0, value.rounded())))
    }

    public static func ledCountLabel(_ count: Int) -> String {
        count == 1 ? "1 LED" : "\(count) LEDs"
    }

    public static func subtitle(_ device: DeviceInfo) -> String {
        var parts = device.connected ? ["Connected", ledCountLabel(device.ledCount)] : [MenuText.notConnected]
        if let firmware = device.firmware, firmware.version != FirmwareInfo.unknownVersion {
            parts.append("Firmware \(firmware.version)")
        }
        return (parts + [device.root.path]).joined(separator: " · ")
    }
}

public enum HookAction: String, Sendable {
    case install, uninstall

    public var label: String { self == .install ? "Install" : "Uninstall" }
}

public typealias HookState = ProviderDoctorInfo

extension ProviderDoctorInfo: Identifiable {
    public var id: String { provider.rawValue }

    public var expectedCount: Int { provider.events.count }

    public var statusText: String {
        if let error { return "Error: \(error)" }
        let installed = installedEvents.count
        if installed > 0 {
            if fullyInstalled { return "Installed (\(installed) \(installed == 1 ? "event" : "events"))" }
            if !hooksEnabled { return "Installed, but \(provider.label) hooks are disabled" }
            if !hookCLIProblems.isEmpty { return "Needs repair: the hooks call \(hookCLIProblems.joined(separator: ", "))" }
            if !missingEvents.isEmpty {
                return "Partial (\(max(0, expectedCount - missingEvents.count))/\(expectedCount) events)"
            }
            if !disabledEvents.isEmpty {
                return "Installed, but turned off with /hooks in Codex: \(disabledEvents.joined(separator: ", "))"
            }
            return "Installed, not trusted: approve the hooks with /hooks in Codex, or run 'sidepulse install codex'"
        }
        if !agentDetected { return "Not detected \u{2014} config created on install" }
        return configExists ? "Not installed" : "Not installed \u{2014} config created on install"
    }
}

public enum ErrorText {
    public static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription { return text }
        // Every Swift error bridges to NSError, so test the dynamic type instead of `is`.
        if type(of: error) is NSError.Type { return (error as NSError).localizedDescription }
        return String(describing: error)
    }
}

public enum HookPresentation {
    public static func resultMessage(provider: HookProvider, action: HookAction, changed: Bool) -> String {
        switch (action, changed) {
        case (.install, true): return "\(provider.label) hooks installed."
        case (.install, false): return "\(provider.label) hooks already installed."
        case (.uninstall, true): return "\(provider.label) hooks removed."
        case (.uninstall, false): return "\(provider.label) hooks already removed."
        }
    }

    public static func failureMessage(provider: HookProvider, error: String) -> String {
        "\(provider.label) hooks failed: \(error)"
    }

    public static func detailLines(notes: [String], backupPath: String?, configPath: String) -> [String] {
        var lines = notes.filter { !$0.isEmpty }
        if let backupPath { lines.append("Backup: \(backupPath)") }
        lines.append("Config: \(configPath)")
        return lines
    }
}
