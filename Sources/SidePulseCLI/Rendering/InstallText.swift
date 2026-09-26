import Foundation
import SidePulseCore

/// Per-provider result blocks for `install`, `uninstall` and `setup`.
///
/// ```
/// claude: updated | would update | already configured        (install)
/// claude: removed | would remove | already uninstalled       (uninstall)
///   config: /Users/x/.claude/settings.json
///   log: /…/SidePulse/logs/claude.jsonl                      (install only)
///   backup: /Users/x/.claude/settings.json.bak.20260926T003149Z
///   note: removed 12 legacy Python hooks
/// ```
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

    /// Block for a provider whose installer threw (e.g. malformed JSON).
    public static func renderFailure(provider: HookProvider, configPath: URL, message: String, action: HookAction) -> String {
        ["\(provider.rawValue): \(action.rawValue) failed",
         "  config: \(configPath.path)",
         "  error: \(message)"].joined(separator: "\n")
    }
}
