import Foundation
import SidePulseCore

public struct AppLocator {
    public static let bundleName = "SidePulse.app"
    public static let executableName = "SidePulse"

    /// Symlinks must already be resolved, since `~/.local/bin/sidepulse` links into the bundle.
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

    public static func appBinary(inBundle bundle: URL) -> URL {
        bundle.appendingPathComponent("Contents/MacOS", isDirectory: true).appendingPathComponent(executableName)
    }

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

    public func locate() -> String? {
        candidates.first { isExecutable($0) && !Self.isForeignBundle(ofBinary: $0) }
    }

    /// The Python install's `/Applications/SidePulse.app` (`io.sidepulse.cli`) has the same layout,
    /// so bundles are told apart by identifier.
    static func isForeignBundle(ofBinary binary: String) -> Bool {
        guard let bundle = HookCLIPath.enclosingBundle(of: binary),
              let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
              let identifier = info["CFBundleIdentifier"] as? String else { return false }
        return identifier != SidePulseConstants.bundleIdentifier
    }

    public var notFoundMessage: String {
        "SidePulse.app was not found (looked in ~/Applications and /Applications). "
            + "Build and install it with scripts/install.sh, then run this command again."
    }
}
