import Foundation

/// Reads only the hook's environment: VS Code forks set `TERM_PROGRAM=vscode`, so walking the
/// process tree found nothing the environment does not already say.
public enum OriginDetector {
    public enum Surface: Sendable, CaseIterable {
        case app, cli, vscode
    }

    public static func detect(provider: HookProvider, environment: [String: String]) -> String {
        if let explicit = cleanLabel(environment["SIDEPULSE_AGENT_ORIGIN"]) { return explicit }
        guard let surface = surface(provider: provider, environment: environment) else { return unknownLabel(provider) }
        return label(provider: provider, surface: surface)
    }

    static func surface(provider: HookProvider, environment: [String: String]) -> Surface? {
        func value(_ key: String) -> String {
            (environment[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        if value("TERM_PROGRAM") == "vscode" || environment.keys.contains(where: { $0.hasPrefix("VSCODE_") }) {
            return .vscode
        }
        let bundleID = value("__CFBundleIdentifier")
        switch provider {
        case .codex where ["openai", "chatgpt", "codex"].contains(where: bundleID.contains): return .app
        case .claude where bundleID.contains("anthropic"): return .app
        default: break
        }
        return value("TERM_PROGRAM").isEmpty && value("TERM").isEmpty ? nil : .cli
    }

    public static func label(provider: HookProvider, surface: Surface) -> String {
        switch (provider, surface) {
        case (.claude, .app): return "Claude App"
        case (.claude, .cli): return "Claude Code CLI"
        case (.claude, .vscode): return "Claude in VS Code"
        case (.codex, .app): return "Codex UI"
        case (.codex, .cli): return "Codex CLI"
        case (.codex, .vscode): return "Codex in VS Code"
        // The OpenCode plugin always sends its own origin, so this only labels hand-run hooks.
        case (.opencode, _): return "OpenCode"
        }
    }

    public static func unknownLabel(_ provider: HookProvider) -> String {
        switch provider {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        }
    }

    static func cleanLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let words = value.split(whereSeparator: { $0.isWhitespace })
        return words.isEmpty ? nil : words.joined(separator: " ")
    }
}
