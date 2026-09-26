import Foundation

public struct ProviderDoctorInfo: Sendable, Equatable {
    public var provider: HookProvider
    public var configPath: URL
    public var configExists: Bool
    public var agentDetected: Bool
    /// Codex: false when `[features]` turns hooks off; Claude: false under `"disableAllHooks": true`
    /// or when the file does not parse; OpenCode: always true.
    public var hooksEnabled: Bool
    public var installedEvents: [String]
    public var missingEvents: [String]
    public var logPath: URL
    public var logExists: Bool
    public var error: String?
    public var hookCLIPaths: [String]
    public var hookCLIProblems: [String]
    /// Codex skips these hooks until they are approved; always empty for the other providers.
    public var untrustedEvents: [String]
    /// Codex hooks turned off with /hooks; always empty for the other providers.
    public var disabledEvents: [String]
    /// Harmless findings worth mentioning, such as Codex's warning about a second hook file.
    public var notes: [String]

    public var fullyInstalled: Bool {
        error == nil && missingEvents.isEmpty && !installedEvents.isEmpty && hooksEnabled
            && hookCLIProblems.isEmpty && untrustedEvents.isEmpty && disabledEvents.isEmpty
    }

    public init(provider: HookProvider, configPath: URL, configExists: Bool, agentDetected: Bool, hooksEnabled: Bool,
                installedEvents: [String], missingEvents: [String], logPath: URL, logExists: Bool,
                error: String? = nil, hookCLIPaths: [String] = [], hookCLIProblems: [String] = [],
                untrustedEvents: [String] = [], disabledEvents: [String] = [], notes: [String] = []) {
        self.provider = provider; self.configPath = configPath; self.configExists = configExists
        self.agentDetected = agentDetected; self.hooksEnabled = hooksEnabled; self.installedEvents = installedEvents
        self.missingEvents = missingEvents; self.logPath = logPath
        self.logExists = logExists; self.error = error; self.hookCLIPaths = hookCLIPaths
        self.hookCLIProblems = hookCLIProblems; self.untrustedEvents = untrustedEvents
        self.disabledEvents = disabledEvents; self.notes = notes
    }
}

public enum HookDoctor {
    /// `runningExecutable` lets a hook CLI outside an app bundle count as ours when it is this very CLI.
    /// `checkVersions` runs the agent binary, so the app's menu, which inspects on the main thread, leaves it off.
    public static func inspect(paths: SidePulsePaths, provider: HookProvider,
                               runningExecutable: String = SidePulsePaths.currentExecutablePath,
                               checkVersions: Bool = false) -> ProviderDoctorInfo {
        let fm = FileManager.default
        let config = provider.configFile(paths)
        let log = paths.logFile(for: provider.rawValue)
        var info = ProviderDoctorInfo(
            provider: provider, configPath: config, configExists: fm.fileExists(atPath: config.path),
            agentDetected: provider.isDetected(paths), hooksEnabled: provider != .codex, installedEvents: [],
            missingEvents: provider.events, logPath: log, logExists: fm.fileExists(atPath: log.path))
        guard info.configExists else { return info }
        guard let text = FileUtil.readText(config) else {
            info.error = "could not read \(config.path)"
            info.hooksEnabled = false
            return info
        }
        switch provider {
        case .claude:
            if !ClaudeHookInstaller.isBlank(text) {
                do {
                    guard case .object = try JSONValue.parse(text) else {
                        info.error = "the top level is not a JSON object"
                        info.hooksEnabled = false
                        return info
                    }
                } catch {
                    info.error = String(describing: error)
                    info.hooksEnabled = false
                    return info
                }
            }
            info.hooksEnabled = !ClaudeHookInstaller.allHooksDisabled(in: text)
            info.installedEvents = ClaudeHookInstaller.installedEvents(in: text)
            info.hookCLIPaths = ClaudeHookInstaller.hookCLIPaths(in: text)
        case .codex:
            info.hooksEnabled = CodexHookInstaller.hooksFeatureEnabled(in: text)
            info.installedEvents = CodexHookInstaller.installedEvents(in: text)
            info.hookCLIPaths = CodexHookInstaller.hookCLIPaths(in: text)
            info.untrustedEvents = CodexHookInstaller.untrustedEvents(in: text, configPath: config.path)
            info.disabledEvents = CodexHookInstaller.disabledEvents(in: text, configPath: config.path)
            if !info.installedEvents.isEmpty, let note = CodexHookInstaller.hooksJSONNote(paths: paths) { info.notes.append(note) }
        case .opencode:
            guard OpenCodePluginInstaller.isSidePulsePlugin(text) else {
                info.error = "not written by SidePulse; move it away, then run 'sidepulse install opencode'"
                return info
            }
            info.installedEvents = OpenCodePluginInstaller.installedEvents(in: text)
            let cli = OpenCodePluginInstaller.cliPath(in: text)
            info.hookCLIPaths = cli.map { [$0] } ?? []
            if checkVersions { info.error = OpenCodePluginInstaller.versionProblem(paths: paths) }
            if info.error == nil, cli.map({ text != OpenCodePluginInstaller.source(cliPath: $0) }) ?? true {
                info.error = OpenCodePluginInstaller.outdatedProblem
            }
        }
        info.missingEvents = provider.events.filter { !info.installedEvents.contains($0) }
        // `install` writes an explicit $SIDEPULSE_CLI_PATH as is, so only its existence is checked.
        let override = paths.environment["SIDEPULSE_CLI_PATH"].flatMap { $0.isEmpty ? nil : $0 }
        info.hookCLIProblems = info.hookCLIPaths.compactMap { path in
            let problem = path == override
                ? (fm.isExecutableFile(atPath: path) ? nil : "missing")
                : HookCLIPath.problem(with: path, runningExecutable: runningExecutable)
            return problem.map { "\(path) (\($0))" }
        }
        return info
    }

    public static func inspectAll(paths: SidePulsePaths,
                                  runningExecutable: String = SidePulsePaths.currentExecutablePath,
                                  checkVersions: Bool = false) -> [ProviderDoctorInfo] {
        HookProvider.allCases.map {
            inspect(paths: paths, provider: $0, runningExecutable: runningExecutable, checkVersions: checkVersions)
        }
    }

    public static func renderText(_ infos: [ProviderDoctorInfo]) -> String {
        var lines: [String] = []
        for info in infos {
            let total = info.provider.events.count
            let installed = info.provider.events.filter(info.installedEvents.contains).count
            lines.append("\(info.provider.rawValue):")
            lines.append("  config: \(info.configPath.path) (\(info.configExists ? "found" : "missing"))")
            if let error = info.error { lines.append("  error: \(error)") }
            if info.installedEvents.isEmpty {
                lines.append("  hooks: not installed")
            } else if info.missingEvents.isEmpty {
                lines.append("  hooks: installed (\(installed)/\(total) events)")
            } else {
                lines.append("  hooks: partial (\(installed)/\(total))")
                lines.append("  missing events: \(info.missingEvents.joined(separator: ", "))")
            }
            if !info.hookCLIPaths.isEmpty {
                lines.append(info.hookCLIProblems.isEmpty
                    ? "  hook cli: \(info.hookCLIPaths.joined(separator: ", ")) (ok)"
                    : "  hook cli: \(info.hookCLIProblems.joined(separator: ", ")); "
                        + "run 'sidepulse install \(info.provider.rawValue)' to repair")
            }
            if info.provider == .codex && !info.installedEvents.isEmpty {
                let trusted = info.installedEvents.filter { !info.untrustedEvents.contains($0) }.count
                let count = "\(trusted)/\(info.installedEvents.count) hooks trusted"
                // With the hooks feature off, Codex lists no hooks to approve and install skips trust.
                lines.append(info.untrustedEvents.isEmpty || !info.hooksEnabled ? "  trust: \(count)"
                    : "  trust: \(count); approve them with /hooks in Codex, or run 'sidepulse install codex'")
            }
            if !info.disabledEvents.isEmpty {
                lines.append("  disabled in /hooks: \(info.disabledEvents.joined(separator: ", ")); "
                    + "turn them back on with /hooks in Codex")
            }
            if info.configExists && info.error == nil && !info.hooksEnabled {
                switch info.provider {
                case .claude: lines.append("  hooks feature: disabled (\"disableAllHooks\": true, so Claude Code runs no hooks)")
                case .codex: lines.append("  hooks feature: disabled ([features] turns hooks off, so Codex runs no hooks)")
                case .opencode: break
                }
            }
            lines += info.notes.map { "  note: \($0)" }
            lines.append("  log: \(info.logPath.path) (\(info.logExists ? "found" : "missing"))")
        }
        return lines.joined(separator: "\n")
    }

    public static func renderJSON(_ infos: [ProviderDoctorInfo]) -> JSONValue {
        .object(["providers": .array(infos.map { info in
            .object([
                "provider": .string(info.provider.rawValue),
                "config_path": .string(info.configPath.path),
                "config_exists": .bool(info.configExists),
                "agent_detected": .bool(info.agentDetected),
                "hooks_enabled": .bool(info.hooksEnabled),
                "installed_events": .array(info.installedEvents.map(JSONValue.string)),
                "missing_events": .array(info.missingEvents.map(JSONValue.string)),
                "log_path": .string(info.logPath.path),
                "log_exists": .bool(info.logExists),
                "error": JSONValue(info.error),
                "hook_cli_paths": .array(info.hookCLIPaths.map(JSONValue.string)),
                "hook_cli_problems": .array(info.hookCLIProblems.map(JSONValue.string)),
                "untrusted_events": .array(info.untrustedEvents.map(JSONValue.string)),
                "disabled_events": .array(info.disabledEvents.map(JSONValue.string)),
                "notes": .array(info.notes.map(JSONValue.string)),
            ])
        })])
    }
}
