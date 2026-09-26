import Foundation

/// Helpers shared by the LED test files (namespaced so other test files can use
/// the same names freely).
enum LEDTestSupport {
    /// The Python checkout used for differential checks: `$SIDEPULSE_PYTHON_REPO`,
    /// else `../sidepulse` next to this package. Nil when absent (those tests are
    /// skipped).
    static func pythonRepo() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["SIDEPULSE_PYTHON_REPO"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: env))
        }
        candidates.append(packageRoot().deletingLastPathComponent().appendingPathComponent("sidepulse"))
        return candidates.first {
            fm.fileExists(atPath: $0.appendingPathComponent("src/sidepulse/resources/animations").path)
        }
    }

    /// Root of this Swift package (the directory holding Package.swift).
    static func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// lid-open*, lid-closed*, ember-lid-open*, purple-lid-open* (dropped in the port).
    static func isLidAnimation(_ name: String) -> Bool {
        name.hasPrefix("lid-") || name.contains("-lid-")
    }
}
