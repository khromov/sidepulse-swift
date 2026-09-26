import Foundation

/// Namespaced so other test files can use the same helper names freely.
enum LEDTestSupport {
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

    static func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Lid animations were deliberately dropped in the port.
    static func isLidAnimation(_ name: String) -> Bool {
        name.hasPrefix("lid-") || name.contains("-lid-")
    }
}
