import Foundation

// MARK: - launchd

public struct LaunchAgentStatus: Sendable, Equatable {
    public var installed: Bool
    public var loaded: Bool
    public var pid: Int?

    public init(installed: Bool, loaded: Bool, pid: Int? = nil) {
        self.installed = installed; self.loaded = loaded; self.pid = pid
    }
}

public struct LaunchAgentError: Error, Equatable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public struct LaunchAgentManager: Sendable {
    public typealias LaunchctlRunner = @Sendable ([String]) -> (status: Int32, output: String)

    public var paths: SidePulsePaths
    public var label: String
    public var runner: LaunchctlRunner
    public var unloadTimeout: TimeInterval = 3

    public init(paths: SidePulsePaths, label: String = SidePulseConstants.launchAgentLabel) {
        self.init(paths: paths, label: label, runner: LaunchAgentManager.systemRunner)
    }

    public init(paths: SidePulsePaths, label: String = SidePulseConstants.launchAgentLabel, runner: @escaping LaunchctlRunner) {
        self.paths = paths; self.label = label; self.runner = runner
    }

    public static let systemRunner: LaunchctlRunner = { args in LaunchAgentManager.launchctl(args) }

    public static var domain: String { "gui/\(getuid())" }
    public var serviceTarget: String { "\(Self.domain)/\(label)" }
    public var plistURL: URL { paths.launchAgentPlist(label: label) }

    /// launchd's default PATH is only /usr/bin:/bin:/usr/sbin:/sbin, so the tools the app runs
    /// (codex, and node for an npm-installed codex) would not resolve as they do in a terminal.
    public var launchPath: String {
        let own = (paths.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        let extra = [paths.home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"]
        return uniqued(own.filter { $0.hasPrefix("/") } + extra).joined(separator: ":")
    }

    /// KeepAlive with SuccessfulExit false restarts the app after a crash but lets it stay quit after Quit.
    public func plistContents(programArguments: [String]) throws -> Data {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": programArguments,
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "EnvironmentVariables": ["PATH": launchPath],
            "StandardOutPath": paths.root.appendingPathComponent("app.out.log").path,
            "StandardErrorPath": paths.root.appendingPathComponent("app.err.log").path,
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    @discardableResult
    public func install(programArguments: [String], start: Bool) throws -> Bool {
        let contents = try plistContents(programArguments: programArguments)
        let changed = (try? Data(contentsOf: plistURL)) != contents
        if changed { try FileUtil.atomicWrite(contents, to: plistURL) }
        // launchd opens the log files but does not create their directory.
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        if start {
            _ = runner(["bootout", serviceTarget])
            waitUntilUnloaded()
            // bootstrap() accepts a job that is already loaded, which here would be the old one.
            if isLoaded {
                throw LaunchAgentError("\(label) is still loaded after bootout; the new plist applies at next login")
            }
            try bootstrap()
            try kickstart(restart: false)
        }
        return changed
    }

    public func uninstall() throws {
        if isLoaded {
            _ = runner(["bootout", serviceTarget])
            waitUntilUnloaded()
        }
        do {
            try FileManager.default.removeItem(at: plistURL)
        } catch CocoaError.fileNoSuchFile {
            // Already gone.
        }
        if isLoaded { throw LaunchAgentError("\(label) is still loaded after bootout") }
    }

    /// launchd's 10 s ThrottleInterval makes a restart within 10 s of the previous launch block
    /// until it passes.
    public func start(restart: Bool = false) throws {
        if isLoaded {
            try kickstart(restart: restart)
        } else {
            try bootstrap()
            // A fresh bootstrap already launched it (RunAtLoad); no -k needed.
            try kickstart(restart: false)
        }
    }

    /// Keeps the plist, so the agent returns at next login.
    public func stop() throws {
        guard isLoaded else { return }
        let result = runner(["bootout", serviceTarget])
        waitUntilUnloaded()
        if isLoaded {
            throw LaunchAgentError("launchctl bootout \(serviceTarget) failed: \(Self.clean(result.output))")
        }
    }

    public func installedProgramArguments() -> [String]? {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return plist["ProgramArguments"] as? [String]
    }

    public func status() -> LaunchAgentStatus {
        let installed = FileManager.default.fileExists(atPath: plistURL.path)
        let result = runner(["print", serviceTarget])
        guard result.status == 0 else { return LaunchAgentStatus(installed: installed, loaded: false) }
        return LaunchAgentStatus(installed: installed, loaded: true, pid: Self.parsePID(result.output))
    }

    /// Safe on the main thread: it never spins the run loop, and the pipe's descriptors are closed
    /// before it returns.
    @discardableResult
    public static func launchctl(_ args: [String]) -> (status: Int32, output: String) {
        autoreleasepool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            // `waitUntilExit` would run the caller's run loop while waiting.
            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            do {
                try process.run()
            } catch {
                return (-1, "could not run launchctl: \(error.localizedDescription)")
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            exited.wait()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
    }

    // MARK: - Helpers

    var isLoaded: Bool { runner(["print", serviceTarget]).status == 0 }

    /// Retried briefly because right after a bootout launchd can still be tearing the old job down
    /// ("Input/output error").
    private func bootstrap() throws {
        guard FileManager.default.fileExists(atPath: plistURL.path) else {
            throw LaunchAgentError("\(plistURL.path) does not exist; install the launch agent first")
        }
        var last = (status: Int32(0), output: "")
        for attempt in 0..<4 {
            if attempt > 0 { usleep(250_000) }
            last = runner(["bootstrap", Self.domain, plistURL.path])
            if last.status == 0 || isLoaded { return }
        }
        throw LaunchAgentError("launchctl bootstrap \(Self.domain) \(plistURL.path) failed (\(last.status)): \(Self.clean(last.output))")
    }

    private func kickstart(restart: Bool) throws {
        let result = runner(["kickstart"] + (restart ? ["-k"] : []) + [serviceTarget])
        if result.status != 0 {
            throw LaunchAgentError("launchctl kickstart \(serviceTarget) failed (\(result.status)): \(Self.clean(result.output))")
        }
    }

    private func waitUntilUnloaded() {
        let deadline = Date().addingTimeInterval(unloadTimeout)
        while isLoaded && Date() < deadline { usleep(50_000) }
    }

    static func parsePID(_ output: String) -> Int? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("pid = ") else { continue }
            return Int(trimmed.dropFirst("pid = ".count))
        }
        return nil
    }

    static func clean(_ output: String) -> String {
        output.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
    }
}
