import Foundation

public enum SidePulseConstants {
    public static let version = "0.1.0"
    public static let launchAgentLabel = "io.sidepulse.swift"
    /// Intentionally differs from the Python app bundle's identifier.
    public static let bundleIdentifier = "io.sidepulse.swift"
    public static let maxEventBytes = 1 << 20
    public static let hookSendTimeout: TimeInterval = 0.2
    public static let logRotateBytes = 8 << 20
    public static let recoveryMaxLines = 2000
}

/// Never reads XDG variables for SidePulse's own paths, so the hook process, CLI and
/// LaunchAgent-started app always agree on them.
public struct SidePulsePaths: Sendable, Equatable {
    public var home: URL
    public var root: URL
    public var environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment, home: URL? = nil) {
        self.environment = environment
        let resolvedHome: URL
        if let home {
            resolvedHome = home
        } else if let h = environment["HOME"], !h.isEmpty {
            resolvedHome = URL(fileURLWithPath: h, isDirectory: true)
        } else {
            resolvedHome = FileManager.default.homeDirectoryForCurrentUser
        }
        self.home = resolvedHome.standardizedFileURL
        if let override = environment["SIDEPULSE_HOME"], !override.isEmpty {
            self.root = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        } else {
            self.root = self.home
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("SidePulse", isDirectory: true)
        }
    }

    public static var current: SidePulsePaths { SidePulsePaths() }

    public var settingsFile: URL { root.appendingPathComponent("settings.json") }
    public var latestFile: URL { root.appendingPathComponent("latest.json") }
    public var logsDir: URL { root.appendingPathComponent("logs", isDirectory: true) }
    public func logFile(for provider: String) -> URL { logsDir.appendingPathComponent("\(provider).jsonl") }
    public var appLogFile: URL { root.appendingPathComponent("app.log") }

    /// macOS limits `sun_path` to 104 bytes, so a long data root falls back to /tmp.
    public var socketPath: String {
        let preferred = root.appendingPathComponent("events.sock").path
        if preferred.utf8.count <= 100 { return preferred }
        return "/tmp/sidepulse-\(getuid())/events.sock"
    }

    public var claudeDir: URL { home.appendingPathComponent(".claude", isDirectory: true) }
    public var claudeSettingsFile: URL { claudeDir.appendingPathComponent("settings.json") }
    /// Honors Codex's own `CODEX_HOME`, which the LaunchAgent-started app usually does
    /// not see when it is only exported from a shell.
    public var codexDir: URL {
        if let override = environment["CODEX_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        }
        return home.appendingPathComponent(".codex", isDirectory: true)
    }
    public var codexConfigFile: URL { codexDir.appendingPathComponent("config.toml") }

    /// Follows OpenCode's own lookup (`OPENCODE_CONFIG_DIR`, then `XDG_CONFIG_HOME`), with the same
    /// LaunchAgent caveat as `CODEX_HOME`.
    public var openCodeConfigDir: URL {
        func expanded(_ path: String) -> URL {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        }
        if let override = environment["OPENCODE_CONFIG_DIR"], !override.isEmpty { return expanded(override) }
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return expanded(xdg).appendingPathComponent("opencode", isDirectory: true)
        }
        return home.appendingPathComponent(".config/opencode", isDirectory: true)
    }
    /// OpenCode loads every `.js` file in `plugins/` without a config entry.
    public var openCodePluginFile: URL { openCodeConfigDir.appendingPathComponent("plugins/sidepulse.js") }

    public var launchAgentsDir: URL { home.appendingPathComponent("Library/LaunchAgents", isDirectory: true) }
    public func launchAgentPlist(label: String = SidePulseConstants.launchAgentLabel) -> URL {
        launchAgentsDir.appendingPathComponent("\(label).plist")
    }

    /// The stable link from scripts/install.sh that hook commands prefer (see `HookCLIPath`).
    public var defaultCLILink: URL { home.appendingPathComponent(".local/bin/sidepulse") }

    public static var currentExecutablePath: String {
        let raw = CommandLine.arguments.first ?? "sidepulse"
        if let url = Bundle.main.executableURL { return url.resolvingSymlinksInPath().path }
        return URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
    }

    public func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
    }
}
