import Darwin
import Foundation

public struct AgentOrigin: Sendable, Equatable {
    public var label: String
    public var kind: String
    public var source: String
    public var confidence: String

    public init(label: String, kind: String, source: String, confidence: String) {
        self.label = label; self.kind = kind; self.source = source; self.confidence = confidence
    }
}

public enum OriginDetector {
    public static let maxAncestors = 10

    public enum Surface: String, Sendable, CaseIterable {
        case app, cli, vscode, cursor, windsurf
    }

    public static func detect(provider: HookProvider, environment: [String: String], parentPID: pid_t = getppid()) -> AgentOrigin {
        detect(provider: provider, environment: environment,
               ancestry: { ProcessSnapshot.ancestry(from: parentPID, limit: maxAncestors) })
    }

    /// `ancestry` is lazy so the common VS Code and app cases never touch sysctl.
    public static func detect(provider: HookProvider, environment: [String: String],
                              ancestry: () -> [ProcessSnapshot]) -> AgentOrigin {
        if let explicit = explicitOrigin(environment: environment) { return explicit }
        if let fromEnv = environmentOrigin(provider: provider, environment: environment) { return fromEnv }
        if let fromProcesses = processOrigin(provider: provider, processes: ancestry()) { return fromProcesses }
        if terminalEnvironment(environment) {
            return surfaceOrigin(provider: provider, surface: .cli, source: "env:TERM_PROGRAM")
        }
        return AgentOrigin(label: unknownLabel(provider), kind: "\(provider.rawValue)_unknown",
                           source: "fallback:provider", confidence: "unknown")
    }

    // MARK: Rules

    static func explicitOrigin(environment: [String: String]) -> AgentOrigin? {
        guard let label = cleanLabel(environment["SIDEPULSE_AGENT_ORIGIN"]) else { return nil }
        let kind = cleanLabel(environment["SIDEPULSE_AGENT_ORIGIN_KIND"]) ?? normalizeKind(label)
        return AgentOrigin(label: label, kind: kind, source: "env:SIDEPULSE_AGENT_ORIGIN", confidence: "explicit")
    }

    static func environmentOrigin(provider: HookProvider, environment: [String: String]) -> AgentOrigin? {
        let termProgram = (environment["TERM_PROGRAM"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if termProgram == "vscode" || environment.keys.contains(where: { $0.hasPrefix("VSCODE_") }) {
            return surfaceOrigin(provider: provider, surface: .vscode, source: "env:VSCODE")
        }
        let bundleID = (environment["__CFBundleIdentifier"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !bundleID.isEmpty else { return nil }
        switch provider {
        case .codex where ["openai", "chatgpt", "codex"].contains(where: bundleID.contains):
            return surfaceOrigin(provider: provider, surface: .app, source: "env:__CFBundleIdentifier")
        case .claude where bundleID.contains("anthropic"):
            return surfaceOrigin(provider: provider, surface: .app, source: "env:__CFBundleIdentifier")
        default:
            return nil
        }
    }

    static func processOrigin(provider: HookProvider, processes: [ProcessSnapshot]) -> AgentOrigin? {
        guard !processes.isEmpty else { return nil }
        let haystack = processes.map(\.searchText).joined(separator: "\n").lowercased()
        func has(_ tokens: String...) -> Bool { tokens.contains(where: haystack.contains) }

        if has("visual studio code.app", "code helper", "vscode") {
            return surfaceOrigin(provider: provider, surface: .vscode, source: "process:Visual Studio Code")
        }
        if has("cursor.app", "cursor helper") {
            return surfaceOrigin(provider: provider, surface: .cursor, source: "process:Cursor")
        }
        if has("windsurf.app", "windsurf helper") {
            return surfaceOrigin(provider: provider, surface: .windsurf, source: "process:Windsurf")
        }
        switch provider {
        case .codex where has("codex.app", "chatgpt.app"):
            return surfaceOrigin(provider: provider, surface: .app, source: "process:Codex.app")
        case .claude where has("claude.app"):
            return surfaceOrigin(provider: provider, surface: .app, source: "process:Claude.app")
        default:
            break
        }
        for process in processes {
            let name = process.basename
            switch provider {
            case .codex where name == "codex":
                return surfaceOrigin(provider: provider, surface: .cli, source: "process:codex")
            case .claude where name == "claude" || name == "claude-code":
                return surfaceOrigin(provider: provider, surface: .cli, source: "process:claude")
            default:
                continue
            }
        }
        return nil
    }

    static func terminalEnvironment(_ environment: [String: String]) -> Bool {
        let termProgram = (environment["TERM_PROGRAM"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !termProgram.isEmpty && termProgram.lowercased() != "vscode"
    }

    // MARK: Labels

    public static func surfaceOrigin(provider: HookProvider, surface: Surface, source: String) -> AgentOrigin {
        AgentOrigin(label: label(provider: provider, surface: surface),
                    kind: "\(provider.rawValue)_\(surface.rawValue)", source: source, confidence: "inferred")
    }

    public static func label(provider: HookProvider, surface: Surface) -> String {
        switch (provider, surface) {
        case (.claude, .app): return "Claude App"
        case (.claude, .cli): return "Claude Code CLI"
        case (.claude, .vscode): return "Claude in VS Code"
        case (.claude, .cursor): return "Claude in Cursor"
        case (.claude, .windsurf): return "Claude in Windsurf"
        case (.codex, .app): return "Codex UI"
        case (.codex, .cli): return "Codex CLI"
        case (.codex, .vscode): return "Codex in VS Code"
        case (.codex, .cursor): return "Codex in Cursor"
        case (.codex, .windsurf): return "Codex in Windsurf"
        }
    }

    public static func unknownLabel(_ provider: HookProvider) -> String {
        provider == .claude ? "Claude" : "Codex"
    }

    static func cleanLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let words = value.split(whereSeparator: { $0.isWhitespace })
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    static func normalizeKind(_ label: String) -> String {
        var out = ""
        var pendingSeparator = false
        for scalar in label.lowercased().unicodeScalars {
            let isAlnum = (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9")
            if isAlnum {
                if pendingSeparator && !out.isEmpty { out += "_" }
                pendingSeparator = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingSeparator = true
            }
        }
        return out.isEmpty ? "custom" : out
    }
}

/// Read with sysctl/libproc rather than by spawning `ps`, which would slow down every hook.
public struct ProcessSnapshot: Sendable, Equatable {
    public var pid: pid_t
    public var parentPID: pid_t
    public var comm: String
    public var executablePath: String
    public var arguments: [String]

    public init(pid: pid_t, parentPID: pid_t, comm: String, executablePath: String = "", arguments: [String] = []) {
        self.pid = pid; self.parentPID = parentPID; self.comm = comm
        self.executablePath = executablePath; self.arguments = arguments
    }

    var searchText: String {
        [comm, executablePath, arguments.joined(separator: " ")].joined(separator: "\n")
    }

    private static let ignoredBasenames: Set<String> = ["sh", "bash", "zsh", "python", "python3", "env"]

    /// argv[0] comes first because a symlinked binary such as `~/.local/bin/claude` resolves to a versioned
    /// file name in `comm`/`proc_pidpath`.
    public var basename: String {
        for candidate in [arguments.first ?? "", comm, executablePath] {
            let name = (candidate as NSString).lastPathComponent.trimmingCharacters(in: .whitespaces).lowercased()
            if !name.isEmpty && !Self.ignoredBasenames.contains(name) { return name }
        }
        return ""
    }

    public static func read(pid: pid_t) -> ProcessSnapshot? {
        var reader = ArgumentReader()
        defer { reader.deallocate() }
        return read(pid: pid, reader: &reader)
    }

    public static func ancestry(from pid: pid_t, limit: Int = OriginDetector.maxAncestors) -> [ProcessSnapshot] {
        var reader = ArgumentReader()
        defer { reader.deallocate() }
        var result: [ProcessSnapshot] = []
        var seen = Set<pid_t>()
        var current = pid
        while current > 1, !seen.contains(current), result.count < limit {
            seen.insert(current)
            guard let snapshot = read(pid: current, reader: &reader) else { break }
            result.append(snapshot)
            current = snapshot.parentPID
        }
        return result
    }

    private static func read(pid: pid_t, reader: inout ArgumentReader) -> ProcessSnapshot? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let comm = withUnsafeBytes(of: info.kp_proc.p_comm) { raw -> String in
            let bytes = raw.prefix(while: { $0 != 0 })
            return String(decoding: bytes, as: UTF8.self)
        }
        return ProcessSnapshot(pid: pid, parentPID: info.kp_eproc.e_ppid, comm: comm,
                               executablePath: executablePath(pid: pid), arguments: reader.arguments(pid: pid))
    }

    private static func executablePath(pid: pid_t) -> String {
        // PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN
        let capacity = 4 * Int(MAXPATHLEN)
        var buffer = [CChar](repeating: 0, count: capacity)
        let length = proc_pidpath(pid, &buffer, UInt32(capacity))
        guard length > 0 else { return "" }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// Reuses one `kern.argmax`-sized buffer for a whole ancestry walk.
private struct ArgumentReader {
    private var buffer: UnsafeMutableRawPointer?
    private var capacity = 0

    mutating func deallocate() {
        buffer?.deallocate()
        buffer = nil
    }

    mutating func arguments(pid: pid_t) -> [String] {
        if buffer == nil {
            var argmax: Int32 = 0
            var size = MemoryLayout<Int32>.size
            var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
            if sysctl(&mib, 2, &argmax, &size, nil, 0) != 0 || argmax <= 0 { argmax = 1 << 20 }
            capacity = Int(argmax)
            buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
        }
        guard let buffer else { return [] }
        var size = capacity
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        // Layout: int32 argc, exec path, NUL padding, argv[0..argc-1] (NUL-terminated), env...
        let bytes = UnsafeRawBufferPointer(start: buffer, count: size)
        let argc = Int(bytes.loadUnaligned(as: Int32.self))
        guard argc > 0 else { return [] }
        var index = MemoryLayout<Int32>.size
        while index < size, bytes[index] != 0 { index += 1 } // exec path
        while index < size, bytes[index] == 0 { index += 1 } // padding
        var result: [String] = []
        while index < size, result.count < argc {
            let start = index
            while index < size, bytes[index] != 0 { index += 1 }
            result.append(String(decoding: UnsafeRawBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self))
            index += 1
        }
        return result
    }
}
