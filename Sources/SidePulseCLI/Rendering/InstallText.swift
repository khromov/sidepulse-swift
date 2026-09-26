import Foundation
import SidePulseCore

public enum InstallText {
    public static func headline(_ result: InstallResult, action: HookAction) -> String {
        switch (action, result.changed, result.dryRun) {
        case (.install, true, true): return "would update"
        case (.install, true, false): return "updated"
        case (.install, false, _): return "already configured"
        case (.uninstall, true, true): return "would remove"
        case (.uninstall, true, false): return "removed"
        case (.uninstall, false, _): return "already uninstalled"
        }
    }

    public static func render(_ result: InstallResult, action: HookAction, logPath: URL? = nil) -> String {
        var lines = ["\(result.provider.rawValue): \(headline(result, action: action))",
                     "  config: \(result.configPath.path)"]
        if action == .install, let logPath { lines.append("  log: \(logPath.path)") }
        if let backup = result.backupPath { lines.append("  backup: \(backup.path)") }
        lines += result.notes.map { "  note: \($0)" }
        return lines.joined(separator: "\n")
    }

    public static func renderFailure(provider: HookProvider, configPath: URL, message: String, action: HookAction) -> String {
        ["\(provider.rawValue): \(action.rawValue) failed",
         "  config: \(configPath.path)",
         "  error: \(message)"].joined(separator: "\n")
    }
}
