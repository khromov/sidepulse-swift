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
    public static func shouldAnimate(iconState: DisplayState, iconVisible: Bool = true,
                                     openMenuRowStates: [DisplayState] = [], reduceMotion: Bool,
                                     paused: Bool = false) -> Bool {
        guard !reduceMotion, !paused else { return false }
        return (iconVisible && animates(iconState)) || openMenuRowStates.contains(where: animates)
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

/// Python's 48 frames at 30 fps stepped down to 12 at 8 fps (same 1.5 s cycle), because every new image
/// makes AppKit redraw the status item on each display.
public enum IconAnimation {
    public static let framesPerSecond: Double = 8
    public static let frameCount = 12
    public static let canvasSize: Double = 18
    public static let symbolSize: Double = 15

    public static func frame(for state: DisplayState, index: Int) -> IconFrame {
        let wrapped = ((index % frameCount) + frameCount) % frameCount
        let phase = Double(wrapped) / Double(frameCount)
        switch state {
        case .working:
            return IconFrame(rotationDegrees: -360 * phase, scale: 1, opacity: 1)
        case .ask:
            let pulse = (1 + cos(2 * Double.pi * phase)) / 2
            return IconFrame(rotationDegrees: 0, scale: 0.82 + 0.18 * pulse, opacity: 0.45 + 0.55 * pulse)
        case .idle, .done:
            return .identity
        }
    }
}
