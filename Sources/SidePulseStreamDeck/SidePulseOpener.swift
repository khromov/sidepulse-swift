import Foundation
import SidePulseCore

/// What a key press does: show SidePulse Settings, starting the app first when it isn't running, like
/// `sidepulse settings`.
public struct SidePulseOpener {
    public enum Outcome: Equatable {
        case opened
        /// A headless `sidepulse run` owns the socket, and it has no settings window.
        case headless
        case appNotFound
        case timedOut
    }

    public var requestSettings: () -> Bool
    public var isRunning: () -> Bool
    public var launchApp: () -> Bool
    public var sleep: (TimeInterval) -> Void
    public var now: () -> Date

    public static let startupTimeout: TimeInterval = 5
    public static let retryInterval: TimeInterval = 0.1

    public init(requestSettings: @escaping () -> Bool, isRunning: @escaping () -> Bool,
                launchApp: @escaping () -> Bool, sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                now: @escaping () -> Date = Date.init) {
        self.requestSettings = requestSettings; self.isRunning = isRunning; self.launchApp = launchApp
        self.sleep = sleep; self.now = now
    }

    /// Blocks for up to `startupTimeout` while the app starts, so call it off the main queue.
    public func open() -> Outcome {
        if requestSettings() { return .opened }
        if isRunning() { return .headless }
        guard launchApp() else { return .appNotFound }
        let deadline = now().addingTimeInterval(Self.startupTimeout)
        repeat {
            sleep(Self.retryInterval)
            if requestSettings() { return .opened }
        } while now() < deadline
        return .timedOut
    }

    public static func live(paths: SidePulsePaths) -> SidePulseOpener {
        let socket = paths.socketPath
        let cli = paths.defaultCLILink.path
        return SidePulseOpener(
            requestSettings: {
                guard let reply = EventSocketClient.request("open-settings", socketPath: socket, timeout: 1) else { return false }
                return String(decoding: reply, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
            },
            isRunning: { EventSocketClient.isServerRunning(socketPath: socket) },
            launchApp: {
                // `sidepulse app start` uses the LaunchAgent when Launch at Login is on, so launchd keeps the app
                // alive; LaunchServices only covers a missing CLI link, and fails when no app has the identifier.
                if HookCLIPath.problem(with: cli) == nil, run(cli, ["app", "start"]) { return true }
                return run("/usr/bin/open", ["-g", "-b", SidePulseConstants.bundleIdentifier])
            })
    }

    static func run(_ executable: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
