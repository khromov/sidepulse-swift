import Foundation
import SidePulseCore

/// A text sink (stdout, stderr, or a test buffer).
public struct TextOutput {
    private let sink: (String) -> Void

    public init(_ sink: @escaping (String) -> Void) { self.sink = sink }

    /// Writes `text` as-is.
    public func write(_ text: String) { sink(text) }

    /// Writes `text` followed by a newline (Python `print`).
    public func line(_ text: String = "") { sink(text + "\n") }

    /// The throwing `write(contentsOf:)`: the legacy `write(_:)` raises an uncatchable
    /// Objective-C exception on EPIPE or ENOSPC.
    public static let standardOutput = TextOutput { try? FileHandle.standardOutput.write(contentsOf: Data($0.utf8)) }
    public static let standardError = TextOutput { try? FileHandle.standardError.write(contentsOf: Data($0.utf8)) }
    /// Discards everything.
    public static let discard = TextOutput { _ in }
}

/// Standard input as the commands see it.
public struct StandardInput {
    /// True when stdin is a terminal (never read implicitly then).
    public var isTTY: Bool
    /// Reads everything until EOF (blocking).
    public var readAll: () -> Data
    /// True when data (or EOF) is ready within `timeout` seconds; used before an
    /// implicit read so a never-closing non-TTY stdin cannot hang `write`.
    public var hasPendingData: (_ timeout: TimeInterval) -> Bool

    public init(isTTY: Bool, readAll: @escaping () -> Data, hasPendingData: @escaping (TimeInterval) -> Bool) {
        self.isTTY = isTTY; self.readAll = readAll; self.hasPendingData = hasPendingData
    }

    /// A non-TTY stdin that yields `data` (tests).
    public static func data(_ data: Data) -> StandardInput {
        StandardInput(isTTY: false, readAll: { data }, hasPendingData: { _ in true })
    }

    /// An interactive terminal with nothing piped in.
    public static let terminal = StandardInput(isTTY: true, readAll: { Data() }, hasPendingData: { _ in false })

    /// The process's stdin. Reads until EOF like Python's `sys.stdin.read()`, but
    /// without `FileHandle`, which aborts on a non-blocking descriptor.
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

/// Everything a command needs from the outside world. `live()` wires the real
/// process; tests build one with temp paths, captured output and test doubles.
public struct CLIEnvironment {
    /// Process environment variables (`NO_COLOR`, `SIDEPULSE_MOUNT_ROOTS`, ...).
    public var variables: [String: String]
    public var paths: SidePulsePaths
    public var stdout: TextOutput
    public var stderr: TextOutput
    public var stdin: StandardInput
    public var stdoutIsTTY: Bool
    /// Terminal width in columns, nil when unknown.
    public var terminalColumns: () -> Int?
    /// Resolved path of the running CLI executable (symlinks resolved).
    public var executablePath: String
    public var now: () -> Date
    /// Time zone used for local timestamps (live dashboard).
    public var timeZone: TimeZone
    public var sleep: (TimeInterval) -> Void
    /// The running menu-bar app, reached over the event socket.
    public var app: AppConnection
    /// Where status snapshots come from.
    public var snapshots: SnapshotLoader
    public var hooks: HookOperations
    public var launchAgent: LaunchAgentOperations
    /// `/Applications` (overridable so app-binary lookup is testable).
    public var systemApplicationsDir: URL

    public init(variables: [String: String],
                paths: SidePulsePaths? = nil,
                stdout: TextOutput = .standardOutput,
                stderr: TextOutput = .standardError,
                stdin: StandardInput = .terminal,
                stdoutIsTTY: Bool = false,
                terminalColumns: @escaping () -> Int? = { nil },
                executablePath: String = SidePulsePaths.currentExecutablePath,
                now: @escaping () -> Date = Date.init,
                timeZone: TimeZone = .current,
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
        self.stdoutIsTTY = stdoutIsTTY
        self.terminalColumns = terminalColumns
        self.executablePath = executablePath
        self.now = now
        self.timeZone = timeZone
        self.sleep = sleep
        self.app = app ?? .socket(path: paths.socketPath)
        self.snapshots = snapshots
        self.hooks = hooks
        self.launchAgent = launchAgent ?? .launchd(paths: paths)
        self.systemApplicationsDir = systemApplicationsDir
    }

    /// The real process: stdio, `ProcessInfo` environment, `SidePulsePaths.current`.
    public static func live() -> CLIEnvironment {
        let variables = ProcessInfo.processInfo.environment
        return CLIEnvironment(
            variables: variables,
            paths: .current,
            stdin: .process,
            stdoutIsTTY: isatty(STDOUT_FILENO) == 1,
            terminalColumns: { Terminal.columns(environment: variables, ttyColumns: Terminal.stdoutColumns) }
        )
    }

    /// Mount roots for device discovery, honouring `SIDEPULSE_MOUNT_ROOTS` from
    /// `variables` (not the process environment, so tests can redirect it).
    public var mountRoots: [URL] { DeviceDiscovery.mountRoots(environment: variables) }

    /// App binary lookup for this environment.
    public var appLocator: AppLocator {
        AppLocator(executablePath: executablePath, home: paths.home, environment: variables,
                   systemApplicationsDir: systemApplicationsDir)
    }
}

enum Terminal {
    /// Terminal width like Python's `shutil.get_terminal_size`: a positive
    /// `$COLUMNS` wins, else the width of the terminal on stdout, else nil (the
    /// caller falls back to 120).
    static func columns(environment: [String: String], ttyColumns: () -> Int?) -> Int? {
        if let raw = environment["COLUMNS"], let value = Int(raw.trimmingCharacters(in: .whitespaces)), value > 0 {
            return value
        }
        return ttyColumns()
    }

    /// `TIOCGWINSZ` on stdout; nil when stdout is not a terminal.
    static func stdoutColumns() -> Int? {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else { return nil }
        return Int(size.ws_col)
    }
}

/// A command failure with a message for stderr and an exit code.
struct CommandFailure: Error, LocalizedError {
    var message: String
    var exitCode: Int32 = ExitCode.failure

    var errorDescription: String? { message }
}
