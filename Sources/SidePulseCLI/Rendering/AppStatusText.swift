import Foundation
import SidePulseCore

public enum AppStatusText {
    public static func render(state: LaunchAgentStatus, plistPath: URL, socketPath: String, ping: PingReply?,
                              appBinary: String?) -> String {
        let launchd: String
        switch (state.loaded, state.pid) {
        case (true, let pid?): launchd = "loaded (pid \(pid))"
        case (true, nil): launchd = "loaded, not running"
        case (false, _): launchd = "not loaded"
        }
        let socket = ping.map { $0.details.isEmpty ? "responding" : "responding, \($0.details)" } ?? "not responding"
        let app: String
        switch ping {
        case nil: app = "not running"
        case let ping? where ping.isHeadless: app = "not running (\(ping.headlessOwner) owns the socket)"
        default: app = "running"
        }
        return [
            "app: \(app)",
            "  plist: \(plistPath.path) (\(state.installed ? "installed" : "missing"))",
            "  launchd: \(launchd)",
            "  socket: \(socketPath) (\(socket))",
            "  binary: \(appBinary ?? "not found")",
        ].joined(separator: "\n")
    }
}
