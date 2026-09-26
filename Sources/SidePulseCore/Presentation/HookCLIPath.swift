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
        if let bundle = enclosingBundle(of: runningExecutable) {
            let helper = bundle.appendingPathComponent("Contents/Helpers/sidepulse").path
            if problem(with: helper, runningExecutable: runningExecutable) == nil { return helper }
        }
        return isCLIBinary(runningExecutable) ? runningExecutable : nil
    }

    public static func problem(with path: String,
                               runningExecutable: String = SidePulsePaths.currentExecutablePath) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return "missing" }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let helpers = resolved.deletingLastPathComponent()
        let contents = helpers.deletingLastPathComponent()
        if resolved.lastPathComponent == "sidepulse", helpers.lastPathComponent == "Helpers",
           contents.lastPathComponent == "Contents", contents.deletingLastPathComponent().pathExtension == "app" {
            return nil
        }
        if isCLIBinary(runningExecutable), sameFile(path, runningExecutable) { return nil }
        return "not the SidePulse CLI"
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
        return "\(what); hooks do not use it. Run scripts/install.sh to relink it."
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
}

public struct HookCLINotFound: Error, LocalizedError, Equatable {
    public init() {}
    public var errorDescription: String? { HookCLIPath.notFoundMessage }
}
