import Foundation

/// The single resolver for the hook CLI path; only a Swift CLI qualifies because hooks that call the
/// Python CLI or the menu-bar binary fail silently behind `; true`.
public enum HookCLIPath {
    /// Prefers the stable `~/.local/bin/sidepulse` link because Codex trust hashes bind to the exact command.
    public static func resolve(paths: SidePulsePaths,
                               runningExecutable: String = SidePulsePaths.currentExecutablePath) -> String? {
        if let override = paths.environment["SIDEPULSE_CLI_PATH"], !override.isEmpty { return override }
        let link = paths.defaultCLILink.path
        if problem(with: link, runningExecutable: runningExecutable) == nil { return link }
        // A translocated path is a read-only mount that is gone after a reboot.
        guard !isTranslocated(runningExecutable) else { return nil }
        if let bundle = enclosingBundle(of: runningExecutable) {
            let helper = bundle.appendingPathComponent("Contents/Helpers/sidepulse").path
            if problem(with: helper, runningExecutable: runningExecutable) == nil { return helper }
        }
        return isCLIBinary(runningExecutable) ? runningExecutable : nil
    }

    /// Gatekeeper runs a quarantined app opened in place (such as from ~/Downloads) from a random
    /// `/AppTranslocation/` mount.
    public static func isTranslocated(_ path: String) -> Bool {
        URL(fileURLWithPath: path).pathComponents.contains("AppTranslocation")
    }

    public static func unresolvedMessage(runningExecutable: String = SidePulsePaths.currentExecutablePath) -> String {
        isTranslocated(runningExecutable) ? translocatedMessage : notFoundMessage
    }

    public static func problem(with path: String,
                               runningExecutable: String = SidePulsePaths.currentExecutablePath) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return "missing" }
        if isBundledCLI(path) { return nil }
        if isCLIBinary(runningExecutable), sameFile(path, runningExecutable) { return nil }
        return "not the SidePulse CLI"
    }

    /// A `sidepulse` inside `<X>.app/Contents/Helpers/`, once symlinks are resolved.
    static func isBundledCLI(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let helpers = resolved.deletingLastPathComponent()
        let contents = helpers.deletingLastPathComponent()
        return resolved.lastPathComponent == "sidepulse" && helpers.lastPathComponent == "Helpers"
            && contents.lastPathComponent == "Contents" && contents.deletingLastPathComponent().pathExtension == "app"
    }

    public static func foreignLinkNote(paths: SidePulsePaths,
                                       runningExecutable: String = SidePulsePaths.currentExecutablePath) -> String? {
        if let override = paths.environment["SIDEPULSE_CLI_PATH"], !override.isEmpty { return nil }
        let link = paths.defaultCLILink.path
        var info = stat()
        guard lstat(link, &info) == 0, let problem = problem(with: link, runningExecutable: runningExecutable) else {
            return nil
        }
        let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) ?? link
        let reason = problem == "missing" ? "does not exist" : "is not the SidePulse CLI"
        let what = target == link ? "\(link) \(reason)" : "\(link) points at \(target), which \(reason)"
        return "\(what); hooks do not use it. \(CLILink.relinkHint)"
    }

    /// Case-insensitive because the app binary is `SidePulse`.
    public static func enclosingBundle(of executable: String) -> URL? {
        let file = URL(fileURLWithPath: executable).standardizedFileURL
        let folder = file.deletingLastPathComponent()
        let contents = folder.deletingLastPathComponent()
        let bundle = contents.deletingLastPathComponent()
        guard file.lastPathComponent.lowercased() == "sidepulse",
              ["Helpers", "MacOS"].contains(folder.lastPathComponent),
              contents.lastPathComponent == "Contents",
              bundle.pathExtension == "app" else { return nil }
        return bundle
    }

    /// Case-sensitive on purpose: the app binary is `SidePulse` (or `SidePulseApp`).
    static func isCLIBinary(_ path: String) -> Bool {
        URL(fileURLWithPath: path).lastPathComponent == "sidepulse"
    }

    public static func sameFile(_ lhs: String, _ rhs: String) -> Bool {
        var left = stat(), right = stat()
        guard stat(lhs, &left) == 0, stat(rhs, &right) == 0 else { return false }
        return left.st_dev == right.st_dev && left.st_ino == right.st_ino
    }

    public static let notFoundMessage =
        "The SidePulse command was not found ($SIDEPULSE_CLI_PATH, ~/.local/bin/sidepulse or "
        + "SidePulse.app/Contents/Helpers/sidepulse). Install SidePulse with scripts/install.sh."

    public static let translocatedMessage =
        "SidePulse is running from a temporary location; move SidePulse.app to Applications and reopen it."
}

public struct HookCLINotFound: Error, LocalizedError, Equatable {
    public init() {}
    public var errorDescription: String? { HookCLIPath.unresolvedMessage() }
}

/// Thrown instead of writing a translocated path into the LaunchAgent plist.
public struct AppTranslocated: Error, LocalizedError, Equatable {
    public init() {}
    public var errorDescription: String? { HookCLIPath.translocatedMessage }

    public static func check(_ executable: String) throws {
        if HookCLIPath.isTranslocated(executable) { throw AppTranslocated() }
    }
}
