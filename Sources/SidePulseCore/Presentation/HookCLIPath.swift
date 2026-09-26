import Foundation

/// The one place that decides which `sidepulse` runs agent hooks. Used by
/// `install`/`setup`, `doctor` and the app.
///
/// Only a SidePulse Swift CLI qualifies: a `sidepulse` inside
/// `<X>.app/Contents/Helpers/` (after resolving symlinks), or the running CLI
/// itself. The Python CLI (a venv script, or the Python app's
/// `Contents/MacOS/SidePulse`) and the menu-bar binary never do: hooks that call
/// them fail silently behind `; true`.
public enum HookCLIPath {
    /// The CLI path for new hook commands, or nil when none qualifies. Order:
    /// 1. `$SIDEPULSE_CLI_PATH`, taken as is;
    /// 2. `~/.local/bin/sidepulse` when it is a SidePulse CLI (the stable path
    ///    created by scripts/install.sh; Codex trust hashes bind to it);
    /// 3. `<bundle>/Contents/Helpers/sidepulse` of the bundle `runningExecutable`
    ///    lives in (the app's own helper, or the CLI itself);
    /// 4. `runningExecutable` when it is the CLI (a SwiftPM build), never the app.
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

    /// Why `path` cannot run a SidePulse hook, `"missing"` or
    /// `"not the SidePulse CLI"`, or nil when it can.
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

    /// A warning when `~/.local/bin/sidepulse` exists but is not a SidePulse CLI
    /// (for example the Python install's link), so hooks do not use it. nil
    /// otherwise, and when `$SIDEPULSE_CLI_PATH` decides.
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

    /// The `.app` of an executable at `<X>.app/Contents/{Helpers,MacOS}/sidepulse`
    /// (either case: the app binary is `SidePulse`), else nil.
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

    /// The CLI binary is `sidepulse`; the app binary is `SidePulse` (or `SidePulseApp`).
    static func isCLIBinary(_ path: String) -> Bool {
        URL(fileURLWithPath: path).lastPathComponent == "sidepulse"
    }

    /// True when both paths resolve to the same file (device and inode).
    public static func sameFile(_ lhs: String, _ rhs: String) -> Bool {
        var left = stat(), right = stat()
        guard stat(lhs, &left) == 0, stat(rhs, &right) == 0 else { return false }
        return left.st_dev == right.st_dev && left.st_ino == right.st_ino
    }

    /// Shown when `resolve` finds nothing.
    public static let notFoundMessage =
        "The SidePulse command was not found ($SIDEPULSE_CLI_PATH, ~/.local/bin/sidepulse or "
        + "SidePulse.app/Contents/Helpers/sidepulse). Install SidePulse with scripts/install.sh."
}

/// `HookInstaller.perform(.install, …)` without a CLI path.
public struct HookCLINotFound: Error, LocalizedError, Equatable {
    public init() {}
    public var errorDescription: String? { HookCLIPath.notFoundMessage }
}
