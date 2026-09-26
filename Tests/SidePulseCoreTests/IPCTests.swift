import Darwin
import XCTest
@testable import SidePulseCore

final class IPCMessageTests: XCTestCase {
    func testParsesEvent() throws {
        let data = Data(#"{"provider":"codex","line":{"logged_at":"2026-06-20T06:00:00Z","event":{"hook_event_name":"Stop"}}}"#.utf8)
        guard case .event(let provider, let line)? = IPCMessage.parse(data) else { return XCTFail("not an event") }
        XCTAssertEqual(provider, "codex")
        XCTAssertEqual(line.keys, ["logged_at", "event"])
        XCTAssertEqual(line["event"]?["hook_event_name"], .string("Stop"))
    }

    func testParsesCommandWithArgs() {
        let data = Data(#"{"command":"preview","animation":"cyan-roll","seconds":3}"#.utf8)
        XCTAssertEqual(IPCMessage.parse(data),
                       .command(name: "preview", args: ["animation": .string("cyan-roll"), "seconds": .number("3")]))
        XCTAssertEqual(IPCMessage.parse(Data(#"{"command":"open-settings"}"#.utf8)),
                       .command(name: "open-settings", args: JSONObject()))
    }

    func testCommandKeyWinsOverEventShape() {
        let data = Data(#"{"provider":"claude","line":{},"command":"ping"}"#.utf8)
        XCTAssertEqual(IPCMessage.parse(data),
                       .command(name: "ping", args: ["provider": .string("claude"), "line": .object(JSONObject())]))
    }

    func testRejectsInvalidAndUnrecognizedShapes() {
        let bad = ["", "not json", "[]", "null", "\"x\"", "{}", #"{"provider":1,"line":{}}"#,
                   #"{"provider":"claude","line":"x"}"#, #"{"provider":"claude"}"#, #"{"line":{}}"#,
                   #"{"command":5}"#, #"{"command":null}"#, #"{"provider":"claude","line":{}"#]
        for text in bad {
            XCTAssertNil(IPCMessage.parse(Data(text.utf8)), text)
        }
        XCTAssertNil(IPCMessage.parse(Data([0xFF, 0xFE, 0x00, 0x7B])))
    }

    func testEncodedIsCompactAndOrdered() {
        let event = IPCMessage.event(provider: "claude", line: ["hook_event_name": .string("Stop"), "message": .string("é\nx")])
        XCTAssertEqual(String(decoding: event.encoded(), as: UTF8.self),
                       #"{"provider":"claude","line":{"hook_event_name":"Stop","message":"é\nx"}}"#)
        let command = IPCMessage.command(name: "preview", args: ["animation": .string("a"), "command": .string("ignored")])
        XCTAssertEqual(String(decoding: command.encoded(), as: UTF8.self), #"{"command":"preview","animation":"a"}"#)
    }

    func testRoundTrip() {
        let messages: [IPCMessage] = [
            .event(provider: "codex", line: ["logged_at": .string("x"), "n": .number("1.50"), "a": .array([.null, .bool(true)])]),
            .command(name: "status", args: JSONObject()),
            .command(name: "preview", args: ["animation": .string("ember"), "seconds": .number("3")]),
        ]
        for message in messages {
            XCTAssertEqual(IPCMessage.parse(message.encoded()), message)
        }
    }

    func testReplies() throws {
        let ping = try JSONValue.parse(IPCReply.ping(pid: 42, version: "9.9"))
        XCTAssertEqual(ping.serialized(), #"{"ok":true,"pid":42,"version":"9.9"}"#)
        XCTAssertEqual(String(decoding: IPCReply.unknownCommand, as: UTF8.self), #"{"ok":false,"error":"unknown command"}"#)
        XCTAssertEqual(IPCReply.ok, Data("ok".utf8))
    }
}

final class IPCSocketTests: XCTestCase {
    private var dir: URL!
    private var socketPath: String { dir.appendingPathComponent("events.sock").path }
    private var servers: [EventSocketServer] = []
    private var descriptors: [Int32] = []

    override func setUp() {
        super.setUp()
        dir = IPCTestSupport.makeShortTempDir("spipc")
    }

    override func tearDown() {
        servers.forEach { $0.stop() }
        servers.removeAll()
        descriptors.forEach { close($0) }
        descriptors.removeAll()
        IPCTestSupport.remove(dir)
        super.tearDown()
    }

    private func startServer(path: String? = nil, configure: (EventSocketServer) -> Void = { _ in },
                             inbox: IPCTestSupport.Inbox<IPCMessage> = .init(),
                             reply: @escaping @Sendable (IPCMessage) -> Data? = { message in
                                 if case .command(name: "status", _) = message { return Data(#"{"aggregate":{"mode":"working"}}"#.utf8) }
                                 return nil
                             }) throws -> EventSocketServer {
        let server = EventSocketServer(path: path ?? socketPath) { message in
            inbox.append(message)
            return reply(message)
        }
        configure(server)
        try server.start()
        servers.append(server)
        return server
    }

    // MARK: Round trips

    func testEventRoundTrip() throws {
        let inbox = IPCTestSupport.Inbox<IPCMessage>()
        _ = try startServer(inbox: inbox)
        let line: JSONObject = ["logged_at": .string("2026-06-20T06:00:00.000Z"), "hook_event_name": .string("Stop"),
                                "session_id": .string("codex-session"), "last_assistant_message": .string("Done.\u{2028}")]
        XCTAssertTrue(EventSocketClient.sendEvent(provider: "codex", line: line, socketPath: socketPath, timeout: 0.5))
        XCTAssertTrue(IPCTestSupport.waitUntil { inbox.count == 1 })
        XCTAssertEqual(inbox.items.first, .event(provider: "codex", line: line))
    }

    func testCommandRepliesFromHandler() throws {
        let inbox = IPCTestSupport.Inbox<IPCMessage>()
        _ = try startServer(inbox: inbox, reply: { message in
            switch message {
            case .command(name: "ping", _): return IPCReply.ping(pid: 4242, version: "test")
            case .command(name: "status", _): return Data(#"{"aggregate":{"mode":"working"}}"#.utf8)
            case .command(name: "open-settings", _): return IPCReply.ok
            case .command: return IPCReply.unknownCommand
            case .event: return nil
            }
        })
        let ping = try XCTUnwrap(EventSocketClient.request("ping", socketPath: socketPath))
        XCTAssertEqual(String(decoding: ping, as: UTF8.self), #"{"ok":true,"pid":4242,"version":"test"}"#)
        let status = try XCTUnwrap(EventSocketClient.request("status", socketPath: socketPath))
        XCTAssertEqual(try JSONValue.parse(status)["aggregate"]?["mode"], .string("working"))
        XCTAssertEqual(EventSocketClient.request("open-settings", socketPath: socketPath), IPCReply.ok)
        XCTAssertEqual(EventSocketClient.request("bogus", socketPath: socketPath), IPCReply.unknownCommand)
        XCTAssertTrue(EventSocketClient.isServerRunning(socketPath: socketPath))
        let preview = try XCTUnwrap(EventSocketClient.request("preview", args: ["animation": .string("x")], socketPath: socketPath))
        XCTAssertEqual(preview, IPCReply.unknownCommand)
        XCTAssertTrue(inbox.items.contains(.command(name: "preview", args: ["animation": .string("x")])))
    }

    func testServerAnswersPingItselfWhenHandlerDoesNot() throws {
        _ = try startServer(reply: { _ in nil })
        let reply = try XCTUnwrap(EventSocketClient.request("ping", socketPath: socketPath))
        let value = try JSONValue.parse(reply)
        XCTAssertEqual(value["ok"], .bool(true))
        XCTAssertEqual(value["pid"]?.intValue, Int(getpid()))
        XCTAssertEqual(value["version"], .string(SidePulseConstants.version))
        // Other commands without a reply: the server just closes.
        XCTAssertEqual(EventSocketClient.request("reload-settings", socketPath: socketPath), Data())
    }

    func testCommandsNeverReachEventPath() throws {
        let inbox = IPCTestSupport.Inbox<IPCMessage>()
        _ = try startServer(inbox: inbox)
        _ = EventSocketClient.request("open-settings", socketPath: socketPath)
        XCTAssertTrue(IPCTestSupport.waitUntil { inbox.count == 1 })
        guard case .command(name: "open-settings", _)? = inbox.items.first else { return XCTFail("\(inbox.items)") }
    }

    // MARK: Concurrency

    func testHundredConcurrentClients() throws {
        let inbox = IPCTestSupport.Inbox<IPCMessage>()
        _ = try startServer(inbox: inbox)
        let path = socketPath
        let sent = IPCTestSupport.Inbox<Bool>()
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            let line: JSONObject = ["hook_event_name": .string("PreToolUse"), "session_id": .string("s\(index)")]
            sent.append(EventSocketClient.sendEvent(provider: "claude", line: line, socketPath: path, timeout: 2))
        }
        XCTAssertEqual(sent.items.filter { $0 }.count, 100)
        XCTAssertTrue(IPCTestSupport.waitUntil(timeout: 5) { inbox.count == 100 }, "received \(inbox.count)")
        let sessions = Set(inbox.items.compactMap { message -> String? in
            if case .event(_, let line) = message { return line["session_id"]?.stringValue }
            return nil
        })
        XCTAssertEqual(sessions.count, 100)
    }

    func testHundredConcurrentRequests() throws {
        _ = try startServer()
        let path = socketPath
        let replies = IPCTestSupport.Inbox<Data?>()
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            replies.append(EventSocketClient.request("status", socketPath: path, timeout: 5))
        }
        XCTAssertEqual(replies.items.count, 100)
        XCTAssertTrue(replies.items.allSatisfy { $0 == Data(#"{"aggregate":{"mode":"working"}}"#.utf8) })
    }

    func testSlowClientDoesNotBlockOthers() throws {
        let inbox = IPCTestSupport.Inbox<IPCMessage>()
        _ = try startServer(configure: { $0.readTimeout = 0.5 }, inbox: inbox)
        let slow = try XCTUnwrap(UnixSocket.connect(path: socketPath, deadline: SocketDeadline(after: 1)))
        descriptors.append(slow)
        XCTAssertTrue(UnixSocket.writeAll(slow, Data(#"{"provider":"claude","li"#.utf8), deadline: SocketDeadline(after: 1)))

        let started = Date()
        XCTAssertTrue(EventSocketClient.sendEvent(provider: "claude", line: ["hook_event_name": .string("Stop")], socketPath: socketPath))
        XCTAssertTrue(IPCTestSupport.waitUntil { inbox.count == 1 })
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.4)

        // After readTimeout the server hangs up on the slow client without calling the handler.
        var byte: UInt8 = 0
        XCTAssertTrue(IPCTestSupport.waitUntil(timeout: 2) { read(slow, &byte, 1) == 0 })
        XCTAssertEqual(inbox.count, 1)
    }

    func testMessagesAreDeliveredInAcceptOrder() throws {
        let inbox = IPCTestSupport.Inbox<IPCMessage>()
        _ = try startServer(inbox: inbox)
        // A (e.g. PreToolUse) connects first but finishes writing after B (PostToolUse).
        let first = try XCTUnwrap(UnixSocket.connect(path: socketPath, deadline: SocketDeadline(after: 1)))
        descriptors.append(first)
        let firstMessage = IPCMessage.event(provider: "claude", line: ["hook_event_name": .string("PreToolUse")]).encoded()
        XCTAssertTrue(UnixSocket.writeAll(first, firstMessage.prefix(10), deadline: SocketDeadline(after: 1)))
        usleep(30_000) // let the server accept A before B connects
        XCTAssertTrue(EventSocketClient.sendEvent(provider: "claude", line: ["hook_event_name": .string("PostToolUse")], socketPath: socketPath))
        usleep(50_000)
        XCTAssertEqual(inbox.count, 0, "B must wait for A")
        XCTAssertTrue(UnixSocket.writeAll(first, firstMessage.dropFirst(10), deadline: SocketDeadline(after: 1)))
        shutdown(first, SHUT_WR)
        XCTAssertTrue(IPCTestSupport.waitUntil { inbox.count == 2 })
        let names = inbox.items.compactMap { message -> String? in
            if case .event(_, let line) = message { return line["hook_event_name"]?.stringValue }
            return nil
        }
        XCTAssertEqual(names, ["PreToolUse", "PostToolUse"])
    }

    func testStalledEarlierConnectionIsSkippedAfterGraceAndDeliveredLate() throws {
        let inbox = IPCTestSupport.Inbox<IPCMessage>()
        _ = try startServer(configure: { $0.readTimeout = 2; $0.reorderGrace = 0.1 }, inbox: inbox)
        let stalled = try XCTUnwrap(UnixSocket.connect(path: socketPath, deadline: SocketDeadline(after: 1)))
        descriptors.append(stalled)
        let late = IPCMessage.event(provider: "claude", line: ["hook_event_name": .string("Stop")]).encoded()
        XCTAssertTrue(UnixSocket.writeAll(stalled, late.prefix(5), deadline: SocketDeadline(after: 1)))
        usleep(30_000)
        XCTAssertTrue(EventSocketClient.sendEvent(provider: "claude", line: ["hook_event_name": .string("PreToolUse")], socketPath: socketPath))
        XCTAssertTrue(IPCTestSupport.waitUntil(timeout: 1) { inbox.count == 1 }, "released after the grace period")
        XCTAssertTrue(UnixSocket.writeAll(stalled, late.dropFirst(5), deadline: SocketDeadline(after: 1)))
        shutdown(stalled, SHUT_WR)
        XCTAssertTrue(IPCTestSupport.waitUntil { inbox.count == 2 }, "the stalled message still arrives, late")
    }

    // MARK: Size limits

    private func paddedEvent(size: Int) -> Data {
        let prefix = #"{"provider":"claude","line":{"hook_event_name":"Stop","pad":""#
        let suffix = #""}}"#
        let pad = String(repeating: "x", count: size - prefix.utf8.count - suffix.utf8.count)
        let data = Data((prefix + pad + suffix).utf8)
        precondition(data.count == size)
        return data
    }

    func testMessageAtLimitIsAccepted() throws {
        let inbox = IPCTestSupport.Inbox<IPCMessage>()
        _ = try startServer(inbox: inbox)
        XCTAssertTrue(EventSocketClient.send(paddedEvent(size: SidePulseConstants.maxEventBytes), socketPath: socketPath, timeout: 2))
        XCTAssertTrue(IPCTestSupport.waitUntil { inbox.count == 1 })
    }

    func testOversizeMessageIsDropped() throws {
        let inbox = IPCTestSupport.Inbox<IPCMessage>()
        _ = try startServer(inbox: inbox)
        let oversize = paddedEvent(size: SidePulseConstants.maxEventBytes + 1)

        XCTAssertFalse(EventSocketClient.send(oversize, socketPath: socketPath, timeout: 1))
        let bigLine: JSONObject = ["pad": .string(String(repeating: "y", count: SidePulseConstants.maxEventBytes))]
        XCTAssertFalse(EventSocketClient.sendEvent(provider: "claude", line: bigLine, socketPath: socketPath, timeout: 1))

        // Forced through a raw socket, the server drops it (and the writer gets EPIPE, not SIGPIPE).
        let fd = try XCTUnwrap(UnixSocket.connect(path: socketPath, deadline: SocketDeadline(after: 1)))
        _ = UnixSocket.writeAll(fd, oversize + oversize, deadline: SocketDeadline(after: 2))
        close(fd)
        usleep(200_000)
        XCTAssertEqual(inbox.count, 0)

        XCTAssertTrue(EventSocketClient.sendEvent(provider: "claude", line: ["hook_event_name": .string("Stop")], socketPath: socketPath))
        XCTAssertTrue(IPCTestSupport.waitUntil { inbox.count == 1 })
    }

    func testInvalidPayloadsAreIgnored() throws {
        let inbox = IPCTestSupport.Inbox<IPCMessage>()
        _ = try startServer(inbox: inbox)
        for payload in ["not json", "[1,2]", #"{"provider":"claude","line":"x"}"#, ""] {
            XCTAssertTrue(EventSocketClient.send(Data(payload.utf8), socketPath: socketPath, timeout: 1))
        }
        usleep(200_000)
        XCTAssertEqual(inbox.count, 0)
    }

    func testWritingToClosedPeerDoesNotRaiseSigpipe() throws {
        let listener = IPCTestSupport.makeSilentListener(at: socketPath)
        descriptors.append(listener)
        let client = try XCTUnwrap(UnixSocket.connect(path: socketPath, deadline: SocketDeadline(after: 1)))
        defer { close(client) }
        let accepted = accept(listener, nil, nil)
        XCTAssertGreaterThanOrEqual(accepted, 0)
        close(accepted)
        // Without SO_NOSIGPIPE this write would kill the test process.
        XCTAssertFalse(UnixSocket.writeAll(client, Data(count: 1 << 20), deadline: SocketDeadline(after: 1)))
    }

    // MARK: Lifecycle / single instance

    func testStartCreatesPrivateSocketAndDirectory() throws {
        let nested = dir.appendingPathComponent("a/b/events.sock").path
        _ = try startServer(path: nested)
        var info = stat()
        XCTAssertEqual(lstat(nested, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFSOCK)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(stat(dir.appendingPathComponent("a/b").path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
    }

    func testStaleSocketFileIsReplaced() throws {
        IPCTestSupport.makeStaleSocket(at: socketPath)
        let staleInode = IPCTestSupport.inode(of: socketPath)
        XCTAssertNotNil(staleInode)
        XCTAssertFalse(EventSocketClient.isServerRunning(socketPath: socketPath))

        let inbox = IPCTestSupport.Inbox<IPCMessage>()
        _ = try startServer(inbox: inbox)
        XCTAssertNotEqual(IPCTestSupport.inode(of: socketPath), staleInode)
        XCTAssertTrue(EventSocketClient.sendEvent(provider: "claude", line: ["hook_event_name": .string("Stop")], socketPath: socketPath))
        XCTAssertTrue(IPCTestSupport.waitUntil { inbox.count == 1 })
    }

    func testStaleRegularFileIsReplaced() throws {
        FileManager.default.createFile(atPath: socketPath, contents: Data("junk".utf8))
        _ = try startServer()
        XCTAssertTrue(EventSocketClient.isServerRunning(socketPath: socketPath))
    }

    func testSecondInstanceIsRefusedWithoutTouchingTheSocket() throws {
        let first = try startServer()
        let inode = IPCTestSupport.inode(of: socketPath)

        let second = EventSocketServer(path: socketPath) { _ in nil }
        XCTAssertThrowsError(try second.start()) { error in
            XCTAssertEqual(error as? EventSocketError, .alreadyRunning(socketPath))
        }
        XCTAssertFalse(second.isRunning)
        XCTAssertEqual(IPCTestSupport.inode(of: socketPath), inode)
        XCTAssertTrue(first.isRunning)
        XCTAssertTrue(EventSocketClient.isServerRunning(socketPath: socketPath))
        second.stop() // must not unlink the first server's socket
        XCTAssertEqual(IPCTestSupport.inode(of: socketPath), inode)
        XCTAssertTrue(EventSocketClient.isServerRunning(socketPath: socketPath))
    }

    /// Regression: a listener that never answered ping used to be treated as stale and displaced by a
    /// second instance.
    func testUnresponsiveListenerIsNotDisplaced() throws {
        descriptors.append(IPCTestSupport.makeSilentListener(at: socketPath))
        let inode = IPCTestSupport.inode(of: socketPath)
        let second = EventSocketServer(path: socketPath) { _ in nil }
        second.probeTimeout = 0.2
        XCTAssertThrowsError(try second.start()) { error in
            XCTAssertEqual(error as? EventSocketError, .alreadyRunning(socketPath))
        }
        XCTAssertEqual(IPCTestSupport.inode(of: socketPath), inode)
    }

    func testInstanceWithBusyHandlerIsNotDisplaced() throws {
        let release = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let first = try startServer(reply: { message in
            if case .event = message {
                entered.signal()
                _ = release.wait(timeout: .now() + 5)
            }
            return nil
        })
        defer { release.signal() }
        XCTAssertTrue(EventSocketClient.sendEvent(provider: "claude", line: ["hook_event_name": .string("Stop")], socketPath: socketPath))
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        // The handler queue is blocked, so ping cannot be answered in time.
        XCTAssertFalse(EventSocketClient.isServerRunning(socketPath: socketPath, timeout: 0.2))

        let inode = IPCTestSupport.inode(of: socketPath)
        let second = EventSocketServer(path: socketPath) { _ in nil }
        second.probeTimeout = 0.2
        XCTAssertThrowsError(try second.start()) { error in
            XCTAssertEqual(error as? EventSocketError, .alreadyRunning(socketPath))
        }
        XCTAssertEqual(IPCTestSupport.inode(of: socketPath), inode)
        XCTAssertTrue(first.isRunning)
    }

    /// The `/tmp/sidepulse-<uid>` fallback lives in a world-writable directory; a
    /// directory someone else owns must not be used.
    func testSocketDirectoryMustBelongToTheUser() {
        let path = "/tmp/sp-owner-\(getpid())-\(UUID().uuidString.prefix(8)).sock" // /tmp itself is root's
        let server = EventSocketServer(path: path) { _ in nil }
        defer { server.stop() } // only matters if start() wrongly succeeds
        XCTAssertThrowsError(try server.start()) { error in
            guard case .bindFailed(let message)? = error as? EventSocketError else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("not owned"), message)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    /// Clients never deliver records (which contain prompts) to a socket another
    /// user could have planted.
    func testClientOnlyConnectsToOwnSockets() throws {
        _ = try startServer()
        XCTAssertTrue(UnixSocket.isOwnSocket(socketPath))

        let regular = dir.appendingPathComponent("regular").path
        FileManager.default.createFile(atPath: regular, contents: Data())
        XCTAssertFalse(UnixSocket.isOwnSocket(regular))
        XCTAssertFalse(UnixSocket.isOwnSocket(dir.appendingPathComponent("missing").path))

        let foreign = "/var/run/mDNSResponder" // a root-owned stream socket on every Mac
        try XCTSkipUnless(FileManager.default.fileExists(atPath: foreign), "no root-owned socket to test against")
        XCTAssertFalse(UnixSocket.isOwnSocket(foreign))
        if let fd = UnixSocket.connect(path: foreign, deadline: SocketDeadline(after: 0.2)) {
            close(fd)
            XCTFail("connected to a socket owned by another user")
        }
    }

    /// Regression: after stop() + start(), messages dispatched in the earlier
    /// cycle were still delivered because the handler only checked `isRunning`.
    func testRestartDropsWorkFromThePreviousCycle() throws {
        let inbox = IPCTestSupport.Inbox<IPCMessage>()
        let release = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let server = try startServer(inbox: inbox, reply: { message in
            if case .event(_, let line) = message, line["session_id"] == .string("first") {
                entered.signal()
                _ = release.wait(timeout: .now() + 5)
            }
            return nil
        })
        func send(_ session: String) {
            XCTAssertTrue(EventSocketClient.sendEvent(provider: "claude", line: ["session_id": .string(session)], socketPath: socketPath))
        }
        send("first")
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        send("stale") // read and queued behind the blocked handler
        usleep(300_000)
        server.stop()
        try server.start()
        send("fresh")
        release.signal()

        XCTAssertTrue(IPCTestSupport.waitUntil { inbox.count == 2 })
        usleep(100_000)
        let sessions = inbox.items.compactMap { message -> String? in
            if case .event(_, let line) = message { return line["session_id"]?.stringValue }
            return nil
        }
        XCTAssertEqual(sessions, ["first", "fresh"])
    }

    func testStopFromInsideTheHandlerDoesNotDeadlock() throws {
        final class Box: @unchecked Sendable { var server: EventSocketServer? }
        let box = Box()
        let server = try startServer(reply: { message in
            if case .command(name: "quit", _) = message {
                box.server?.stop()
                return IPCReply.ok
            }
            return nil
        })
        box.server = server
        _ = EventSocketClient.request("quit", socketPath: socketPath, timeout: 2)
        XCTAssertTrue(IPCTestSupport.waitUntil { !server.isRunning })
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
        box.server = nil
    }

    func testStopDoesNotUnlinkForeignSocket() throws {
        let first = try startServer()
        // Another instance replaced our socket file, as after a crash-restart cycle.
        unlink(socketPath)
        let secondInbox = IPCTestSupport.Inbox<IPCMessage>()
        let second = try startServer(inbox: secondInbox)
        let foreignInode = IPCTestSupport.inode(of: socketPath)

        first.stop()
        XCTAssertEqual(IPCTestSupport.inode(of: socketPath), foreignInode)
        XCTAssertTrue(EventSocketClient.sendEvent(provider: "claude", line: ["hook_event_name": .string("Stop")], socketPath: socketPath))
        XCTAssertTrue(IPCTestSupport.waitUntil { secondInbox.count == 1 })

        second.stop()
        XCTAssertNil(IPCTestSupport.inode(of: socketPath), "a server removes its own socket on stop")
    }

    func testStopThenRestart() throws {
        let inbox = IPCTestSupport.Inbox<IPCMessage>()
        let server = try startServer(inbox: inbox)
        server.stop()
        XCTAssertFalse(server.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
        XCTAssertFalse(EventSocketClient.sendEvent(provider: "claude", line: [:], socketPath: socketPath))
        server.stop() // idempotent

        try server.start()
        try server.start() // no-op while running
        XCTAssertTrue(EventSocketClient.sendEvent(provider: "claude", line: ["hook_event_name": .string("Stop")], socketPath: socketPath))
        XCTAssertTrue(IPCTestSupport.waitUntil { inbox.count == 1 })
    }

    func testDirectoryAtSocketPathFailsToBind() {
        try? FileManager.default.createDirectory(atPath: socketPath, withIntermediateDirectories: true)
        let server = EventSocketServer(path: socketPath) { _ in nil }
        XCTAssertThrowsError(try server.start()) { error in
            guard case .bindFailed? = error as? EventSocketError else { return XCTFail("\(error)") }
        }
    }

    func testOverlongPathIsRejected() {
        let long = "/tmp/" + String(repeating: "p", count: 120) + "/events.sock"
        let server = EventSocketServer(path: long) { _ in nil }
        XCTAssertThrowsError(try server.start()) { error in
            guard case .bindFailed? = error as? EventSocketError else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: (long as NSString).deletingLastPathComponent))
        XCTAssertFalse(EventSocketClient.sendEvent(provider: "claude", line: [:], socketPath: long))
        XCTAssertNil(EventSocketClient.request("ping", socketPath: long))
        XCTAssertEqual(UnixSocket.maxPathBytes, 103)
    }

    // MARK: Client failure modes

    func testClientFailsFastWithoutServer() {
        let started = Date()
        XCTAssertFalse(EventSocketClient.sendEvent(provider: "claude", line: [:], socketPath: socketPath))
        XCTAssertNil(EventSocketClient.request("ping", socketPath: socketPath))
        XCTAssertFalse(EventSocketClient.isServerRunning(socketPath: socketPath))
        IPCTestSupport.makeStaleSocket(at: socketPath)
        XCTAssertFalse(EventSocketClient.sendEvent(provider: "claude", line: [:], socketPath: socketPath))
        XCTAssertNil(EventSocketClient.request("ping", socketPath: socketPath))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2)
    }

    func testRequestTimesOutWhenServerNeverReplies() {
        descriptors.append(IPCTestSupport.makeSilentListener(at: socketPath))
        let started = Date()
        XCTAssertNil(EventSocketClient.request("status", socketPath: socketPath, timeout: 0.3))
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 0.25)
        XCTAssertLessThan(elapsed, 1.0)
        XCTAssertFalse(EventSocketClient.isServerRunning(socketPath: socketPath, timeout: 0.2))
    }

    func testRequestTimesOutWhenHandlerIsSlow() throws {
        _ = try startServer(reply: { _ in
            usleep(600_000)
            return IPCReply.ok
        })
        XCTAssertNil(EventSocketClient.request("status", socketPath: socketPath, timeout: 0.2))
        XCTAssertEqual(EventSocketClient.request("status", socketPath: socketPath, timeout: 3), IPCReply.ok)
    }

    func testEventSendIsBoundedByTimeoutWhenServerIsHung() {
        descriptors.append(IPCTestSupport.makeSilentListener(at: socketPath))
        let big = paddedEvent(size: 900_000) // far larger than the socket buffers
        let started = Date()
        XCTAssertFalse(EventSocketClient.send(big, socketPath: socketPath, timeout: 0.2))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.6)
    }
}
