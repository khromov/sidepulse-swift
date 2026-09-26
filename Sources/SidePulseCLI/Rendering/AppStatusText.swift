import Foundation
import SidePulseCore

/// `sidepulse app status` output.
public enum AppStatusText {
    /// ```
    /// app: running | not running
    ///   plist: <path> (installed|missing)
    ///   launchd: loaded (pid 123) | loaded, not running | not loaded
    ///   socket: <path> (responding, pid 123, version 0.1.0 | not responding)
    ///   binary: <path> | not found
    /// ```
    public static func render(state: LaunchAgentStatus, plistPath: URL, socketPath: String, ping: PingReply?,
                              appBinary: String?) -> String {
        let launchd: String
        switch (state.loaded, state.pid) {
        case (true, let pid?): launchd = "loaded (pid \(pid))"
        case (true, nil): launchd = "loaded, not running"
        case (false, _): launchd = "not loaded"
        }
        let socket = ping.map { $0.details.isEmpty ? "responding" : "responding, \($0.details)" } ?? "not responding"
        return [
            "app: \(ping != nil ? "running" : "not running")",
            "  plist: \(plistPath.path) (\(state.installed ? "installed" : "missing"))",
            "  launchd: \(launchd)",
            "  socket: \(socketPath) (\(socket))",
            "  binary: \(appBinary ?? "not found")",
        ].joined(separator: "\n")
    }
}
