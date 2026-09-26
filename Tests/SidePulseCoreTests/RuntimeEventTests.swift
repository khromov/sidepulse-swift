import Foundation
import XCTest
@testable import SidePulseCore

/// Events and commands over the real event socket drive the runtime and the fake
/// devices' LEDS.LED.
final class RuntimeEventTests: XCTestCase {
    private var world: RuntimeWorld!

    override func setUp() {
        super.setUp()
        world = RuntimeWorld()
    }

    override func tearDown() {
        world.tearDown()
        super.tearDown()
    }

    private func waitForProgram(_ device: String, _ expected: String, timeout: TimeInterval = 3,
                                file: StaticString = #filePath, line: UInt = #line) {
        let reached = runtimeWait(timeout: timeout) { self.world.program(device) == expected }
        XCTAssertTrue(reached, "\(device) shows \(world.program(device) ?? "nil"), expected \(expected)", file: file, line: line)
    }

    // MARK: Events → LEDs

    func testSocketEventsDriveWorkingAskDoneOnDotAndPro() throws {
        world.addDevice("PulseDot")
        world.addDevice("SidePulsePro")
        world.updateSettings { $0.setBrightness(128, forDevice: world.deviceID("SidePulsePro")) }
        let runtime = try world.startRuntime()

        // Startup: nothing is going on, so both show Idle.
        waitForProgram("PulseDot", RuntimePrograms.expected(.idleReady, ledCount: 2))
        waitForProgram("SidePulsePro", RuntimePrograms.expected(.idleReady, ledCount: 8, brightness: 128))

        XCTAssertTrue(world.send(RuntimeRecords.prompt()))
        waitForProgram("PulseDot", RuntimePrograms.expected(.working, ledCount: 2))
        waitForProgram("SidePulsePro", RuntimePrograms.expected(.working, ledCount: 8, brightness: 128))
        XCTAssertEqual(runtime.snapshot().aggregate.mode, .working)

        XCTAssertTrue(world.send(RuntimeRecords.permission()))
        waitForProgram("PulseDot", RuntimePrograms.expected(.waitingForInput, ledCount: 2))
        waitForProgram("SidePulsePro", RuntimePrograms.expected(.waitingForInput, ledCount: 8, brightness: 128))
        XCTAssertEqual(runtime.snapshot().aggregate.mode, .waitingForInput)

        // A sticky permission prompt ignores unrelated tool activity.
        XCTAssertTrue(world.send(RuntimeRecords.tool(name: "Read")))
        XCTAssertTrue(runtimeWait { runtime.ingestedEventCount == 3 })
        XCTAssertEqual(runtime.snapshot().aggregate.mode, .waitingForInput)

        XCTAssertTrue(world.send(RuntimeRecords.stop()))
        waitForProgram("PulseDot", RuntimePrograms.expected(.completed, ledCount: 2))
        waitForProgram("SidePulsePro", RuntimePrograms.expected(.completed, ledCount: 8, brightness: 128))
        XCTAssertEqual(runtime.snapshot().aggregate.mode, .completed)
        XCTAssertEqual(runtime.snapshot().statuses.first?.agentID, "claude:session:s1")

        // Custom animations from settings apply per state.
        runtime.updateSettings { $0.setAnimation("kitt", for: .working) }
        XCTAssertTrue(world.send(RuntimeRecords.prompt("s2")))
        waitForProgram("PulseDot", RuntimePrograms.program("kitt", ledCount: 2))
        waitForProgram("SidePulsePro", RuntimePrograms.program("kitt", ledCount: 8, brightness: 128))
    }

    func testDroppedEventsChangeNothing() throws {
        world.addDevice("PulseDot")
        let runtime = try world.startRuntime()
        waitForProgram("PulseDot", RuntimePrograms.expected(.idleReady, ledCount: 2))
        runtime.ingest(provider: "claude", line: ["hook_event_name": .string("NotARealEvent"), "session_id": .string("x")])
        runtime.ingest(provider: "claude", line: ["no_event_name": .bool(true)])
        XCTAssertEqual(runtime.snapshot().statuses, [])
        XCTAssertEqual(runtime.handle(.event(provider: "claude", line: RuntimeRecords.prompt())), nil)
        XCTAssertEqual(runtime.snapshot().aggregate.mode, .working)
    }

    /// 200 events in a burst over the socket: LED syncs coalesce, and the device
    /// ends on the final state.
    func testBurstOf200SocketEventsEndsInTheFinalMode() throws {
        world.addDevice("PulseDot")
        world.addDevice("SidePulsePro")
        let runtime = try world.startRuntime()
        waitForProgram("PulseDot", RuntimePrograms.expected(.idleReady, ledCount: 2))
        let passesBefore = runtime.leds.syncPassCount

        let burst: [JSONObject] = (0..<199).map { index in
            switch index % 3 {
            case 0: return RuntimeRecords.prompt()
            case 1: return RuntimeRecords.tool(name: "Tool\(index)")
            default: return RuntimeRecords.event("PostToolUse", ["tool_name": .string("Tool\(index)")])
            }
        }
        for line in burst { XCTAssertTrue(world.send(line)) }
        // Hooks are separate connections, so their order is only guaranteed once
        // each was handled; the final Stop goes last.
        XCTAssertTrue(runtimeWait(timeout: 10) { runtime.ingestedEventCount == 199 })
        XCTAssertTrue(world.send(RuntimeRecords.stop()))
        waitForProgram("PulseDot", RuntimePrograms.expected(.completed, ledCount: 2), timeout: 5)
        waitForProgram("SidePulsePro", RuntimePrograms.expected(.completed, ledCount: 8), timeout: 5)
        runtime.waitUntilIdle()
        XCTAssertEqual(world.program("PulseDot"), RuntimePrograms.expected(.completed, ledCount: 2))
        XCTAssertEqual(runtime.snapshot().aggregate.mode, .completed)
        XCTAssertLessThanOrEqual(runtime.leds.syncPassCount - passesBefore, 201)
    }

    /// Ordered ingestion from another thread while LED writes are in flight: every
    /// request after the last write is honoured, so the final mode always lands.
    func testRapidIngestWhileSyncsAreInFlightEndsInTheFinalMode() throws {
        world.addDevice("PulseDot")
        let runtime = try world.startRuntime(world.options(serveSocket: false))
        waitForProgram("PulseDot", RuntimePrograms.expected(.idleReady, ledCount: 2))
        let lines: [JSONObject] = (0..<200).map { index in
            switch index % 4 {
            case 0: return RuntimeRecords.prompt()
            case 1: return RuntimeRecords.permission(command: "cmd \(index)")
            case 2: return RuntimeRecords.stop()
            default: return RuntimeRecords.tool()
            }
        } + [RuntimeRecords.stop()]
        let done = expectation(description: "ingested")
        DispatchQueue.global().async {
            for line in lines { runtime.ingest(provider: "claude", line: line) }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        runtime.waitUntilIdle()
        XCTAssertEqual(runtime.snapshot().aggregate.mode, .completed)
        XCTAssertEqual(world.program("PulseDot"), RuntimePrograms.expected(.completed, ledCount: 2))
    }

    // MARK: Commands

    func testPingStatusAndUnknownCommands() throws {
        let runtime = try world.startRuntime()
        runtime.ingest(provider: "claude", line: RuntimeRecords.prompt("alpha"))
        runtime.ingest(provider: "codex", line: RuntimeRecords.permission("beta"))

        let ping = try JSONValue.parse(XCTUnwrap(world.request("ping")))
        XCTAssertEqual(ping["ok"], .bool(true))
        XCTAssertEqual(ping["version"]?.stringValue, SidePulseConstants.version)
        XCTAssertEqual(ping["pid"]?.intValue, Int(getpid()))
        XCTAssertTrue(EventSocketClient.isServerRunning(socketPath: world.paths.socketPath))

        let reply = try XCTUnwrap(world.request("status"))
        let snapshot = try XCTUnwrap(MonitorSnapshot.fromJSON(JSONValue.parse(reply)))
        XCTAssertEqual(snapshot.aggregate.mode, .waitingForInput)
        XCTAssertEqual(snapshot.aggregate.activeCount, 2)
        XCTAssertEqual(Set(snapshot.statuses.map(\.agentID)), ["claude:session:alpha", "codex:session:beta"])
        XCTAssertEqual(snapshot.sources.map(\.provider), ["claude", "codex"])
        XCTAssertEqual(snapshot.sources.first?.path, world.paths.logFile(for: "claude").path)
        let local = runtime.snapshot(now: snapshot.collectedAt)
        XCTAssertEqual(snapshot.statuses.map(\.agentID), local.statuses.map(\.agentID))
        XCTAssertEqual(snapshot.statuses.map(\.mode), local.statuses.map(\.mode))
        XCTAssertEqual(snapshot.statuses.map(\.displayName), local.statuses.map(\.displayName))

        XCTAssertEqual(world.requestText("frobnicate"), #"{"ok":false,"error":"unknown command"}"#)
        XCTAssertEqual(runtime.handle(.command(name: "nope", args: [:])), IPCReply.unknownCommand)
    }

    func testOpenSettingsNeedsAHandlerAndRunsItOnMain() throws {
        let runtime = try world.startRuntime()
        // Headless: refused, so `sidepulse settings` can tell there is no window.
        let refused = try JSONValue.parse(XCTUnwrap(world.request("open-settings")))
        XCTAssertEqual(refused["ok"], .bool(false))

        let opened = expectation(description: "open-settings on main")
        runtime.onOpenSettings = {
            XCTAssertTrue(Thread.isMainThread)
            opened.fulfill()
        }
        let replies = RuntimeInbox<String?>()
        let world = self.world!
        DispatchQueue.global().async { replies.append(world.requestText("open-settings")) }
        wait(for: [opened], timeout: 3)
        XCTAssertTrue(runtimeWait { replies.count == 1 })
        XCTAssertEqual(replies.items.first, "ok")
    }

    func testPreviewPlaysThenRestores() throws {
        world.addDevice("PulseDot")
        let runtime = try world.startRuntime()
        runtime.ingest(provider: "claude", line: RuntimeRecords.prompt())
        waitForProgram("PulseDot", RuntimePrograms.expected(.working, ledCount: 2))

        runtime.preview(animationID: "night-rider", seconds: 0.6)
        waitForProgram("PulseDot", RuntimePrograms.program("night-rider", ledCount: 2))
        // Status changes during the preview show once it ends.
        runtime.ingest(provider: "claude", line: RuntimeRecords.stop())
        runtime.leds.waitUntilIdle()
        XCTAssertEqual(world.program("PulseDot"), RuntimePrograms.program("night-rider", ledCount: 2))
        waitForProgram("PulseDot", RuntimePrograms.expected(.completed, ledCount: 2))

        // The app calls preview directly; the socket has no such command.
        let reply = try JSONValue.parse(XCTUnwrap(world.request("preview", ["animation": .string("kitt")])))
        XCTAssertEqual(reply["error"]?.stringValue, "unknown command")
    }

    func testNewerPreviewCancelsTheOlderRestoreThroughTheRuntime() throws {
        world.addDevice("PulseDot")
        let runtime = try world.startRuntime()
        waitForProgram("PulseDot", RuntimePrograms.expected(.idleReady, ledCount: 2))
        let start = Date()
        runtime.preview(animationID: "kitt", seconds: 0.3)
        waitForProgram("PulseDot", RuntimePrograms.program("kitt", ledCount: 2))
        runtime.preview(animationID: "ember-tide", seconds: 1.2)
        waitForProgram("PulseDot", RuntimePrograms.program("ember-tide", ledCount: 2))
        runtimeSpin(max(0, 0.8 - Date().timeIntervalSince(start)))
        XCTAssertEqual(world.program("PulseDot"), RuntimePrograms.program("ember-tide", ledCount: 2))
        waitForProgram("PulseDot", RuntimePrograms.expected(.idleReady, ledCount: 2), timeout: 4)
    }
}
