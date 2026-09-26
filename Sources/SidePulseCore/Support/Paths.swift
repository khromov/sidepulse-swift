import Foundation

public enum SidePulseConstants {
    public static let version = "0.1.0"
    public static let launchAgentLabel = "io.sidepulse.swift"
    /// `CFBundleIdentifier` of SidePulse.app (the Python app bundle uses another one).
    public static let bundleIdentifier = "io.sidepulse.swift"
    /// Max size of one socket message (hook event or command).
    public static let maxEventBytes = 1 << 20
    /// Connect/send timeout used by the hook process.
    public static let hookSendTimeout: TimeInterval = 0.2
    /// Provider logs are rotated (renamed to `<name>.1`) once they exceed this size.
    public static let logRotateBytes = 8 << 20
    /// Lines read from the tail of each provider log for recovery / offline status.
    public static let recoveryMaxLines = 2000
}

/// All filesystem locations used by SidePulse. Everything is derived from the
/// user's home directory (or `SIDEPULSE_HOME`), never from XDG variables, so the
/// hook process, CLI and LaunchAgent-started app always agree.
///
/// Layout (root = `~/Library/Application Support/SidePulse`):
/// ```
/// settings.json          user settings (SettingsStore)
/// latest.json            restart snapshot (LatestStore)
/// logs/claude.jsonl      trimmed hook records (HookRuntime)
/// logs/codex.jsonl
/// events.sock            Unix socket served by the app (EventSocketServer)
/// app.log                app diagnostics
/// ```
public struct SidePulsePaths: Sendable, Equatable {
    /// The user's home directory.
    public var home: URL
    /// Root data directory.
    public var root: URL
    /// Environment used for overrides (SIDEPULSE_CLI_PATH etc.).
    public var environment: [String: String]

    /// - Parameters:
    ///   - environment: `SIDEPULSE_HOME` overrides `root`; `HOME` overrides `home`.
    ///   - home: explicit home (tests). Takes precedence over `HOME`.
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

    /// Path of the app's Unix socket. macOS limits `sun_path` to 104 bytes; when the
    /// preferred path is longer than 100 UTF-8 bytes we fall back to
    /// `/tmp/sidepulse-<uid>/events.sock`.
    public var socketPath: String {
        let preferred = root.appendingPathComponent("events.sock").path
        if preferred.utf8.count <= 100 { return preferred }
        return "/tmp/sidepulse-\(getuid())/events.sock"
    }

    // Third-party agent configs.
    public var claudeDir: URL { home.appendingPathComponent(".claude", isDirectory: true) }
    public var claudeSettingsFile: URL { claudeDir.appendingPathComponent("settings.json") }
    /// `$CODEX_HOME` when set (Codex's own override), else `~/.codex`. Note the
    /// LaunchAgent-started app usually does not see a shell-exported CODEX_HOME.
    public var codexDir: URL {
        if let override = environment["CODEX_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        }
        return home.appendingPathComponent(".codex", isDirectory: true)
    }
    public var codexConfigFile: URL { codexDir.appendingPathComponent("config.toml") }

    // launchd
    public var launchAgentsDir: URL { home.appendingPathComponent("Library/LaunchAgents", isDirectory: true) }
    public func launchAgentPlist(label: String = SidePulseConstants.launchAgentLabel) -> URL {
        launchAgentsDir.appendingPathComponent("\(label).plist")
    }

    /// `~/.local/bin/sidepulse` — the stable CLI location created by scripts/install.sh.
    /// Hook commands prefer it (see `HookCLIPath`).
    public var defaultCLILink: URL { home.appendingPathComponent(".local/bin/sidepulse") }

    /// The running binary (symlinks resolved): the CLI in the CLI, the app binary in the app.
    public static var currentExecutablePath: String {
        let raw = CommandLine.arguments.first ?? "sidepulse"
        if let url = Bundle.main.executableURL { return url.resolvingSymlinksInPath().path }
        return URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
    }

    /// Creates `root` and `logs/` if needed.
    public func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
    }
}
