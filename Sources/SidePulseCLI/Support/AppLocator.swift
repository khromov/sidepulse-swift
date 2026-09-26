import Foundation
import SidePulseCore

/// Finds the menu-bar app binary.
///
/// Bundle layout: `SidePulse.app/Contents/MacOS/SidePulse` is the app and
/// `SidePulse.app/Contents/Helpers/sidepulse` is this CLI (`~/.local/bin/sidepulse`
/// symlinks to it). Lookup order:
/// 1. `$SIDEPULSE_APP_PATH` (an `.app` bundle or the binary itself);
/// 2. the bundle this CLI lives in (`<X>.app/Contents/{Helpers,MacOS}/sidepulse`);
/// 3. `~/Applications/SidePulse.app`;
/// 4. `/Applications/SidePulse.app`.
///
/// A bundle whose Info.plist names another `CFBundleIdentifier` is skipped: the
/// Python install's `/Applications/SidePulse.app` (`io.sidepulse.cli`) has the same
/// layout.
public struct AppLocator {
    public static let bundleName = "SidePulse.app"
    public static let executableName = "SidePulse"

    /// Resolved path of the running CLI (symlinks already resolved).
    public var executablePath: String
    public var home: URL
    public var environment: [String: String]
    public var systemApplicationsDir: URL
    public var isExecutable: (String) -> Bool

    public init(executablePath: String, home: URL, environment: [String: String] = [:],
                systemApplicationsDir: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
                isExecutable: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) {
        self.executablePath = executablePath
        self.home = home
        self.environment = environment
        self.systemApplicationsDir = systemApplicationsDir
        self.isExecutable = isExecutable
    }

    /// `<bundle>/Contents/MacOS/SidePulse`.
    public static func appBinary(inBundle bundle: URL) -> URL {
        bundle.appendingPathComponent("Contents/MacOS", isDirectory: true).appendingPathComponent(executableName)
    }

    /// Every location checked, in order (for diagnostics).
    public var candidates: [String] {
        var result: [String] = []
        if let explicit = environment["SIDEPULSE_APP_PATH"], !explicit.isEmpty {
            let url = URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
            result.append(url.pathExtension == "app" ? Self.appBinary(inBundle: url).path : url.path)
        }
        if let bundle = HookCLIPath.enclosingBundle(of: executablePath) {
            result.append(Self.appBinary(inBundle: bundle).path)
        }
        result.append(Self.appBinary(inBundle: home.appendingPathComponent("Applications/\(Self.bundleName)")).path)
        result.append(Self.appBinary(inBundle: systemApplicationsDir.appendingPathComponent(Self.bundleName)).path)
        return result
    }

    /// First existing, executable candidate that is not another app's bundle.
    public func locate() -> String? {
        candidates.first { isExecutable($0) && !Self.isForeignBundle(ofBinary: $0) }
    }

    /// True when the binary's bundle Info.plist names a bundle identifier other
    /// than SidePulse's (a bundle without one, or a bare binary, is not foreign).
    static func isForeignBundle(ofBinary binary: String) -> Bool {
        guard let bundle = HookCLIPath.enclosingBundle(of: binary),
              let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
              let identifier = info["CFBundleIdentifier"] as? String else { return false }
        return identifier != SidePulseConstants.bundleIdentifier
    }

    /// Guidance printed when the app cannot be found.
    public var notFoundMessage: String {
        "SidePulse.app was not found (looked in ~/Applications and /Applications). "
            + "Build and install it with scripts/install.sh, then run this command again."
    }
}
