import Foundation

/// What `~/.local/bin/sidepulse` is, seen from the running app.
public enum CLILinkState: Sendable, Equatable {
    case installed
    case missing
    /// A link into another SidePulse.app, such as an older copy or a build from source.
    case otherApp(target: String)
    case broken(target: String)
    /// Something SidePulse did not create, such as the Python CLI; `target` is nil when it is not a symlink.
    case foreign(target: String?)
    /// The running binary is not in a SidePulse.app that can be linked (a SwiftPM build, or a translocated app).
    case unavailable(reason: String)

    /// Only Install replaces a foreign CLI, because it may be one the user wants.
    public var relinksAtLaunch: Bool {
        switch self {
        case .missing, .otherApp, .broken: return true
        case .installed, .foreign, .unavailable: return false
        }
    }
}

public struct CLILinkChange: Sendable, Equatable {
    public var link: URL
    public var target: String
    public var previousTarget: String?
    /// Where a file that was not a symlink was moved.
    public var movedAside: URL?

    public init(link: URL, target: String, previousTarget: String? = nil, movedAside: URL? = nil) {
        self.link = link; self.target = target; self.previousTarget = previousTarget; self.movedAside = movedAside
    }
}

public struct CLILinkUnavailable: Error, LocalizedError, Equatable {
    public var reason: String
    public var errorDescription: String? { reason }
}

/// Keeps `~/.local/bin/sidepulse` pointed at the running app's CLI, so the command and the hooks that call
/// the link match the app's version.
public enum CLILink {
    public static let notInAppMessage = "The sidepulse command can only be installed by SidePulse.app."
    public static let relinkHint =
        "Install the command from Settings \u{203A} General in SidePulse, or run scripts/install.sh, to relink it."

    public static func bundledCLI(runningExecutable: String = SidePulsePaths.currentExecutablePath) -> URL? {
        guard !HookCLIPath.isTranslocated(runningExecutable),
              let bundle = HookCLIPath.enclosingBundle(of: runningExecutable) else { return nil }
        let cli = bundle.appendingPathComponent("Contents/Helpers/sidepulse")
        return FileManager.default.isExecutableFile(atPath: cli.path) ? cli : nil
    }

    public static func state(paths: SidePulsePaths,
                             runningExecutable: String = SidePulsePaths.currentExecutablePath) -> CLILinkState {
        guard let cli = bundledCLI(runningExecutable: runningExecutable) else {
            return .unavailable(reason: unavailableReason(runningExecutable))
        }
        return state(paths: paths, cli: cli)
    }

    static func state(paths: SidePulsePaths, cli: URL) -> CLILinkState {
        let link = paths.defaultCLILink
        var info = stat()
        guard lstat(link.path, &info) == 0 else { return .missing }
        guard info.st_mode & S_IFMT == S_IFLNK,
              let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else {
            return .foreign(target: nil)
        }
        let dir = URL(fileURLWithPath: link.deletingLastPathComponent().path, isDirectory: true)
        let target = URL(fileURLWithPath: destination, relativeTo: dir).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: link.path) else { return .broken(target: target) }
        if HookCLIPath.sameFile(link.path, cli.path) { return .installed }
        return HookCLIPath.isBundledCLI(link.path) ? .otherApp(target: target) : .foreign(target: target)
    }

    public static func install(paths: SidePulsePaths,
                               runningExecutable: String = SidePulsePaths.currentExecutablePath) throws -> CLILinkChange {
        guard let cli = bundledCLI(runningExecutable: runningExecutable) else {
            throw CLILinkUnavailable(reason: unavailableReason(runningExecutable))
        }
        return try install(paths: paths, cli: cli)
    }

    /// Returns nil when the link already points at this app, or at something only Install may replace.
    public static func installAtLaunch(paths: SidePulsePaths,
                                       runningExecutable: String = SidePulsePaths.currentExecutablePath) throws -> CLILinkChange? {
        guard let cli = bundledCLI(runningExecutable: runningExecutable),
              state(paths: paths, cli: cli).relinksAtLaunch else { return nil }
        return try install(paths: paths, cli: cli)
    }

    /// Swaps the link in with a rename, because an agent hook may run it at any moment.
    static func install(paths: SidePulsePaths, cli: URL) throws -> CLILinkChange {
        let fm = FileManager.default
        let link = paths.defaultCLILink
        let dir = link.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var change = CLILinkChange(link: link, target: cli.path)
        var info = stat()
        if lstat(link.path, &info) == 0 {
            if info.st_mode & S_IFMT == S_IFLNK {
                change.previousTarget = try? fm.destinationOfSymbolicLink(atPath: link.path)
            } else {
                let aside = dir.appendingPathComponent("sidepulse.previous")
                // A hard link keeps the old file in place until the rename below replaces it; directories need a move.
                unlink(aside.path)
                guard Darwin.link(link.path, aside.path) == 0 || rename(link.path, aside.path) == 0 else {
                    throw FileUtil.posixError("could not move \(link.path) to \(aside.path)")
                }
                change.movedAside = aside
            }
        }
        let temp = dir.appendingPathComponent(".sidepulse.\(getpid()).tmp")
        unlink(temp.path)
        guard symlink(cli.path, temp.path) == 0 else { throw FileUtil.posixError("could not create \(link.path)") }
        guard rename(temp.path, link.path) == 0 else {
            let error = FileUtil.posixError("could not create \(link.path)")
            unlink(temp.path)
            throw error
        }
        return change
    }

    static func unavailableReason(_ runningExecutable: String) -> String {
        HookCLIPath.isTranslocated(runningExecutable) ? HookCLIPath.translocatedMessage : notInAppMessage
    }
}

public enum CLIPathCheck: Sendable, Equatable {
    case found
    case notOnPath
    /// Another `sidepulse` comes first on PATH.
    case shadowed(by: String)
    /// The shell's PATH could not be read.
    case unknown
}

/// The PATH of the user's shell, which an app started by launchd does not inherit.
public enum ShellPATH {
    static let marker = "__SIDEPULSE_PATH__"

    public static func loginShell(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if path.hasPrefix("/") { return path }
        }
        if let shell = environment["SHELL"], shell.hasPrefix("/") { return shell }
        return "/bin/zsh"
    }

    /// Runs an interactive login shell, as Terminal does, because PATH is often set in ~/.zshrc. Blocks for up
    /// to `timeout`, so never call it on the main thread.
    public static func read(shell: String = loginShell(), timeout: TimeInterval = 5) -> [String]? {
        autoreleasepool {
            // A file rather than a pipe, so a background job started by the shell's startup files cannot hold it open.
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent("sidepulse-path-\(UUID().uuidString)")
            guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                  let handle = try? FileHandle(forWritingTo: output) else { return nil }
            defer {
                try? handle.close()
                try? FileManager.default.removeItem(at: output)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-i", "-l", "-c", "echo \(marker); /usr/bin/printenv PATH"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = handle
            process.standardError = FileHandle.nullDevice
            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            do { try process.run() } catch { return nil }
            guard exited.wait(timeout: .now() + timeout) == .success else {
                // Interactive shells ignore SIGTERM.
                kill(process.processIdentifier, SIGKILL)
                return nil
            }
            return FileUtil.readText(output).flatMap(parse)
        }
    }

    /// Startup files may print their own output, so the PATH is the line after the last marker.
    static func parse(_ output: String) -> [String]? {
        let lines = output.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let index = lines.lastIndex(of: marker), index + 1 < lines.count, !lines[index + 1].isEmpty else {
            return nil
        }
        return lines[index + 1].components(separatedBy: ":")
    }

    /// Looks `sidepulse` up the way a shell does, skipping relative entries.
    public static func check(searchPath: [String]?, link: URL, home: URL) -> CLIPathCheck {
        guard let searchPath else { return .unknown }
        for entry in searchPath {
            let dir = entry.hasPrefix("~/") ? home.appendingPathComponent(String(entry.dropFirst(2))).path : entry
            guard dir.hasPrefix("/") else { continue }
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent("sidepulse").standardizedFileURL.path
            if candidate == link.standardizedFileURL.path || HookCLIPath.sameFile(candidate, link.path) { return .found }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir), !isDir.boolValue,
               FileManager.default.isExecutableFile(atPath: candidate) {
                return .shadowed(by: candidate)
            }
        }
        return .notOnPath
    }
}

/// Adds `~/.local/bin` to PATH in the startup file a login shell reads.
public enum ShellProfile {
    public static let pathLine = #"export PATH="$HOME/.local/bin:$PATH""#
    static let comment = "# Added by SidePulse for the sidepulse command"

    /// Nil for shells other than zsh and bash, whose startup files SidePulse does not edit.
    public static func file(shell: String, paths: SidePulsePaths) -> URL? {
        switch URL(fileURLWithPath: shell).lastPathComponent {
        case "zsh":
            let zdotdir = paths.environment["ZDOTDIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            return (zdotdir ?? paths.home).appendingPathComponent(".zprofile")
        case "bash":
            // bash reads only the first of these that exists, so creating .bash_profile would hide a .profile.
            let candidates = [".bash_profile", ".bash_login", ".profile"].map { paths.home.appendingPathComponent($0) }
            return candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[0]
        default:
            return nil
        }
    }

    /// Returns false when the file already has the line.
    @discardableResult
    public static func addLocalBin(to file: URL) throws -> Bool {
        let text = FileUtil.readText(file) ?? ""
        if text.components(separatedBy: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == pathLine }) {
            return false
        }
        try FileUtil.ensureWritable(file)
        try FileUtil.backup(file)
        let separator = text.isEmpty ? "" : text.hasSuffix("\n") ? "\n" : "\n\n"
        try FileUtil.atomicWrite(text + separator + comment + "\n" + pathLine + "\n", to: file)
        return true
    }
}
