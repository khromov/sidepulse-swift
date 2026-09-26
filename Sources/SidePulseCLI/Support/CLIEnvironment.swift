import Foundation
import SidePulseCore

public struct TextOutput {
    private let sink: (String) -> Void

    public init(_ sink: @escaping (String) -> Void) { self.sink = sink }

    public func write(_ text: String) { sink(text) }

    public func line(_ text: String = "") { sink(text + "\n") }

    /// Uses the throwing `write(contentsOf:)` because the legacy `write(_:)` raises an uncatchable
    /// Objective-C exception on EPIPE or ENOSPC.
    public static let standardOutput = TextOutput { try? FileHandle.standardOutput.write(contentsOf: Data($0.utf8)) }
    public static let standardError = TextOutput { try? FileHandle.standardError.write(contentsOf: Data($0.utf8)) }
    public static let discard = TextOutput { _ in }
}

public struct StandardInput {
    public var isTTY: Bool
    public var readAll: () -> Data
    /// Checked before an implicit read so a never-closing non-TTY stdin cannot hang `write`.
    public var hasPendingData: (_ timeout: TimeInterval) -> Bool

    public init(isTTY: Bool, readAll: @escaping () -> Data, hasPendingData: @escaping (TimeInterval) -> Bool) {
        self.isTTY = isTTY; self.readAll = readAll; self.hasPendingData = hasPendingData
    }

    public static func data(_ data: Data) -> StandardInput {
        StandardInput(isTTY: false, readAll: { data }, hasPendingData: { _ in true })
    }

    public static let terminal = StandardInput(isTTY: true, readAll: { Data() }, hasPendingData: { _ in false })

    public static let process = StandardInput(
        isTTY: isatty(STDIN_FILENO) == 1,
        readAll: { InputReader.readAll(fd: STDIN_FILENO) },
        hasPendingData: { timeout in
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let millis = Int32(max(0, min(timeout, 60)) * 1000)
            return poll(&descriptor, 1, millis) > 0
        }
    )
}

public struct CLIEnvironment {
    public var variables: [String: String]
    public var paths: SidePulsePaths
    public var stdout: TextOutput
    public var stderr: TextOutput
    public var stdin: StandardInput
    public var executablePath: String
    public var now: () -> Date
    public var sleep: (TimeInterval) -> Void
    public var app: AppConnection
    public var snapshots: SnapshotLoader
    public var hooks: HookOperations
    public var launchAgent: LaunchAgentOperations
    /// Overridable so app-binary lookup is testable.
    public var systemApplicationsDir: URL

    public init(variables: [String: String],
                paths: SidePulsePaths? = nil,
                stdout: TextOutput = .standardOutput,
                stderr: TextOutput = .standardError,
                stdin: StandardInput = .terminal,
                executablePath: String = SidePulsePaths.currentExecutablePath,
                now: @escaping () -> Date = Date.init,
                sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                app: AppConnection? = nil,
                snapshots: SnapshotLoader = .standard,
                hooks: HookOperations = .standard,
                launchAgent: LaunchAgentOperations? = nil,
                systemApplicationsDir: URL = URL(fileURLWithPath: "/Applications", isDirectory: true)) {
        let paths = paths ?? SidePulsePaths(environment: variables)
        self.variables = variables
        self.paths = paths
        self.stdout = stdout
        self.stderr = stderr
        self.stdin = stdin
        self.executablePath = executablePath
        self.now = now
        self.sleep = sleep
        self.app = app ?? .socket(path: paths.socketPath)
        self.snapshots = snapshots
        self.hooks = hooks
        self.launchAgent = launchAgent ?? .launchd(paths: paths)
        self.systemApplicationsDir = systemApplicationsDir
    }

    public static func live() -> CLIEnvironment {
        let variables = ProcessInfo.processInfo.environment
        return CLIEnvironment(
            variables: variables,
            paths: .current,
            stdin: .process
        )
    }

    /// Reads `SIDEPULSE_MOUNT_ROOTS` from `variables` rather than the process environment so tests
    /// can redirect it.
    public var mountRoots: [URL] { DeviceDiscovery.mountRoots(environment: variables) }

    public var appLocator: AppLocator {
        AppLocator(executablePath: executablePath, home: paths.home, environment: variables,
                   systemApplicationsDir: systemApplicationsDir)
    }
}

struct CommandFailure: Error, LocalizedError {
    var message: String
    var exitCode: Int32 = ExitCode.failure

    var errorDescription: String? { message }
}
