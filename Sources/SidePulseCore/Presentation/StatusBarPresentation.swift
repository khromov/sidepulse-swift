import Foundation

/// Titles use three ASCII dots, never "…", because Python pins "Settings...".
public enum MenuText {
    public static let appName = "SidePulse"
    public static let agents = "Agents"
    public static let noRecentSessions = "No recent sessions"
    public static let devices = "Devices"
    public static let noDevices = "No devices"
    public static let notConnected = "Not connected"
    public static let remove = "Remove"
    public static let keepAwake = "Keep Awake"
    public static let keepingAwake = "Keeping Mac awake"
    public static let openLogsFolder = "Open Logs Folder"
    public static let settings = "Settings..."
    public static let checkForUpdates = "Check for Updates..."
    public static let launchAtLogin = "Launch at Login"
    public static let ejectPrevention = "SidePulse Pro Eject Prevention"
    public static let ejectPreventionHelp =
        "Keeps a card in the built-in SD reader attached when macOS ejects it after waking from hibernation on a "
        + "locked screen. While this is on, a card in that reader cannot be ejected from Finder."
    public static let quit = "Quit SidePulse"
    public static let alreadyRunning = "SidePulse is already running"
    public static let settingsWindowTitle = "SidePulse Settings"

    public static func updateAvailable(version: String) -> String {
        "Update Available: \(version)..."
    }
}

public enum StatusBarPresentation {
    /// The exact text is pinned by the Python tests.
    public static func tooltip(for state: DisplayState) -> String {
        "SidePulse Agent Monitor: \(state.label)"
    }

    public static func header(mode: AgentMode, activeCount: Int) -> String {
        let base = "\(MenuText.appName) \u{2014} \(mode.displayState.label)"
        return activeCount > 0 ? "\(base) (\(activeCount) active)" : base
    }

    public static func header(for snapshot: MonitorSnapshot) -> String {
        header(mode: snapshot.aggregate.mode, activeCount: snapshot.aggregate.activeCount)
    }

    public static func animates(_ state: DisplayState) -> Bool {
        state == .working || state == .ask
    }

    /// `paused` means the displays are asleep or the login session switched away, so nobody can see it.
    public static func shouldAnimate(iconState: DisplayState, iconVisible: Bool = true, reduceMotion: Bool,
                                     paused: Bool = false) -> Bool {
        guard !reduceMotion, !paused else { return false }
        return iconVisible && animates(iconState)
    }

    public static func shouldAnimateMenuRows(_ states: [DisplayState], reduceMotion: Bool, paused: Bool = false) -> Bool {
        guard !reduceMotion, !paused else { return false }
        return states.contains(where: animates)
    }
}

public struct IconFrame: Sendable, Equatable {
    /// Counter-clockwise positive, so Working's clockwise spin is negative.
    public var rotationDegrees: Double
    public var scale: Double
    public var opacity: Double

    public init(rotationDegrees: Double, scale: Double, opacity: Double) {
        self.rotationDegrees = rotationDegrees; self.scale = scale; self.opacity = opacity
    }

    public static let identity = IconFrame(rotationDegrees: 0, scale: 1, opacity: 1)
}

/// The status icon animates with Core Animation over `cycleSeconds`. Open menu rows swap images instead, two
/// frames a second apart, because every new image makes AppKit redraw the item.
public enum IconAnimation {
    public static let cycleSeconds: Double = 1.5
    public static let framesPerSecond: Double = 1
    public static let frameCount = 2
    public static let canvasSize: Double = 18
    public static let symbolSize: Double = 15

    public static func frame(for state: DisplayState, index: Int) -> IconFrame {
        let alternate = !index.isMultiple(of: frameCount)
        switch state {
        case .working:
            // A quarter turn, because the Working symbol looks the same after a half turn.
            return alternate ? IconFrame(rotationDegrees: -90, scale: 1, opacity: 1) : .identity
        case .ask:
            return alternate ? IconFrame(rotationDegrees: 0, scale: 0.82, opacity: 0.45) : .identity
        case .idle, .done:
            return .identity
        }
    }
}
