import Foundation
import XCTest
@testable import SidePulseCore

/// Everything lives under a short `/tmp` root so the socket path fits `sun_path`.
final class RuntimeWorld {
    let root: URL
    let home: URL
    let state: URL
    let mounts: URL
    let paths: SidePulsePaths
    private var runtimes: [SidePulseRuntime] = []

    init() {
        root = IPCTestSupport.makeShortTempDir("spr")
        home = root.appendingPathComponent("home", isDirectory: true)
        state = root.appendingPathComponent("s", isDirectory: true)
        mounts = root.appendingPathComponent("m", isDirectory: true)
        for directory in [home, state, mounts] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        paths = SidePulsePaths(environment: ["SIDEPULSE_HOME": state.path, "HOME": home.path], home: home)
        precondition(paths.socketPath.hasPrefix(root.path), "socket must live in the temp world")
    }

    func tearDown() {
        for runtime in runtimes { runtime.stop() }
        runtimes.removeAll()
        IPCTestSupport.remove(root)
    }

    // MARK: Devices

    @discardableResult
    func addDevice(_ name: String, content: String? = "boot") -> URL {
        let volume = mounts.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        if let content {
            try? content.write(to: volume.appendingPathComponent("LEDS.LED"), atomically: false, encoding: .utf8)
        }
        return volume
    }

    /// Retries because an asynchronous LED write can recreate a file inside the folder mid-removal.
    func removeDevice(_ name: String) {
        let volume = mounts.appendingPathComponent(name, isDirectory: true)
        for _ in 0..<50 where FileManager.default.fileExists(atPath: volume.path) {
            try? FileManager.default.removeItem(at: volume)
            if FileManager.default.fileExists(atPath: volume.path) { usleep(10_000) }
        }
    }

    func deviceID(_ name: String) -> String {
        mounts.appendingPathComponent(name, isDirectory: true).path
    }

    func target(_ name: String) -> URL {
        mounts.appendingPathComponent(name, isDirectory: true).appendingPathComponent("LEDS.LED")
    }

    func program(_ name: String) -> String? {
        try? String(contentsOf: target(name), encoding: .utf8)
    }

    func overwrite(_ name: String, with text: String) {
        try? text.write(to: target(name), atomically: false, encoding: .utf8)
    }

    // MARK: Runtime

    /// The refresh interval is long because tests call `refresh()` themselves.
    func options(serveSocket: Bool = true) -> RuntimeOptions {
        var options = RuntimeOptions()
        options.serveSocket = serveSocket
        options.keepAwake = false
        options.watchSleep = false
        options.mountRoots = [mounts]
        options.refreshInterval = 3600
        options.devicePollInterval = 0.1
        options.latestSaveDelay = 0.3
        return options
    }

    func makeRuntime(_ options: RuntimeOptions? = nil) -> SidePulseRuntime {
        let runtime = SidePulseRuntime(paths: paths, options: options ?? self.options())
        runtimes.append(runtime)
        return runtime
    }

    func startRuntime(_ options: RuntimeOptions? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> SidePulseRuntime {
        let runtime = makeRuntime(options)
        try runtime.start()
        return runtime
    }

    // MARK: Settings, logs, socket

    var settingsStore: SettingsStore { SettingsStore(url: paths.settingsFile) }

    func updateSettings(_ body: (inout SidePulseSettings) -> Void) {
        do { try settingsStore.update(body) } catch { XCTFail("settings update failed: \(error)") }
    }

    func writeLog(provider: String, records: [JSONObject]) throws {
        try paths.ensureDirectories()
        let text = records.map { JSONValue.object($0).serialized() + "\n" }.joined()
        try text.write(to: paths.logFile(for: provider), atomically: true, encoding: .utf8)
    }

    @discardableResult
    func send(_ line: JSONObject, provider: String = "claude") -> Bool {
        EventSocketClient.sendEvent(provider: provider, line: line, socketPath: paths.socketPath, timeout: 2)
    }

    func request(_ command: String, _ args: JSONObject = JSONObject()) -> Data? {
        EventSocketClient.request(command, args: args, socketPath: paths.socketPath, timeout: 3)
    }

    func requestText(_ command: String, _ args: JSONObject = JSONObject()) -> String? {
        request(command, args).map { String(decoding: $0, as: UTF8.self) }
    }
}

enum RuntimeRecords {
    static func event(_ name: String, session: String = "s1", secondsAgo: Double = 0,
                      _ extra: [String: JSONValue] = [:]) -> JSONObject {
        var line: JSONObject = [
            "logged_at": .string(TimeFormat.iso8601Millis(Date().addingTimeInterval(-secondsAgo))),
            "hook_event_name": .string(name),
            "session_id": .string(session),
            "cwd": .string("/tmp/project-\(session)"),
        ]
        for (key, value) in extra.sorted(by: { $0.key < $1.key }) { line[key] = value }
        return line
    }

    static func prompt(_ session: String = "s1", secondsAgo: Double = 0) -> JSONObject {
        event("UserPromptSubmit", session: session, secondsAgo: secondsAgo, ["prompt": .string("Fix the tests")])
    }

    static func tool(_ session: String = "s1", name: String = "Bash") -> JSONObject {
        event("PreToolUse", session: session, ["tool_name": .string(name)])
    }

    static func permission(_ session: String = "s1", command: String = "rm -rf build") -> JSONObject {
        event("PermissionRequest", session: session,
              ["tool_name": .string("Bash"), "tool_input": .object(["command": .string(command)])])
    }

    static func stop(_ session: String = "s1", secondsAgo: Double = 0) -> JSONObject {
        event("Stop", session: session, secondsAgo: secondsAgo, ["last_assistant_message": .string("All done.")])
    }
}

enum RuntimePrograms {
    static func expected(_ mode: AgentMode, ledCount: Int, brightness: Int = 255,
                         settings: SidePulseSettings = SidePulseSettings()) -> String {
        program(settings.animationID(for: mode), ledCount: ledCount, brightness: brightness)
    }

    static func program(_ animationID: String, ledCount: Int, brightness: Int = 255) -> String {
        do {
            return try LedProgram.program(animationID: animationID, ledCount: ledCount, brightness: brightness)
        } catch {
            XCTFail("no program for \(animationID): \(error)")
            return ""
        }
    }
}

/// Spins the main run loop instead of sleeping so main-queue `onUpdate` callbacks are delivered meanwhile.
@discardableResult
func runtimeWait(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.005))
    }
    return condition()
}

func runtimeSpin(_ seconds: TimeInterval) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.current.run(until: min(end, Date().addingTimeInterval(0.01))) }
}

final class FakeKeepAwake: KeepAwakeHolding, @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var requests: [Bool] = []
    var failToHold = false

    var isHeld: Bool { lock.lock(); defer { lock.unlock() }; return held }
    var calls: [Bool] { lock.lock(); defer { lock.unlock() }; return requests }

    func setHeld(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        requests.append(value)
        held = value && !failToHold
    }
}

final class FakeBattery: @unchecked Sendable {
    private let lock = NSLock()
    private var current: BatteryState
    private var readCount = 0

    init(_ state: BatteryState = BatteryState(present: true, percent: 80, onACPower: true)) {
        current = state
    }

    var state: BatteryState {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }

    var reads: Int { lock.lock(); defer { lock.unlock() }; return readCount }

    func read() -> BatteryState {
        lock.lock(); defer { lock.unlock() }
        readCount += 1
        return current
    }
}

final class RuntimeInbox<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []

    func append(_ element: Element) { lock.lock(); storage.append(element); lock.unlock() }
    var items: [Element] { lock.lock(); defer { lock.unlock() }; return storage }
    var count: Int { items.count }
}

final class FakeSleepWatcher: SleepWatching, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (SleepEvent) -> Void)?
    private var current = SleepState(lidClosed: false, lidClosedSleeps: true, graphics: true)
    var startSucceeds = true
    /// Widens the window between a stop() and the moment it lets go of the handler.
    var stopDelay: TimeInterval = 0

    var state: SleepState {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }

    var isWatching: Bool { lock.lock(); defer { lock.unlock() }; return handler != nil }

    func start(_ handler: @escaping @Sendable (SleepEvent) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard startSucceeds else { return false }
        self.handler = handler
        return true
    }

    func stop() {
        if stopDelay > 0 { Thread.sleep(forTimeInterval: stopDelay) }
        lock.lock(); handler = nil; lock.unlock()
    }

    /// Calls the handler on the caller's thread, which for `.willSleep` waits for the LED writes.
    func send(_ event: SleepEvent) {
        lock.lock(); let handler = handler; lock.unlock()
        handler?(event)
    }
}
