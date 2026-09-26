import Darwin
import XCTest
@testable import SidePulseCore

/// Driven through pipes so the real stdin is never touched.
final class HookRuntimeInputTests: XCTestCase {
    private var pipes: [Int32] = []

    override func tearDown() {
        pipes.forEach { close($0) }
        pipes.removeAll()
        super.tearDown()
    }

    private func makePipe() -> (Int32, Int32) {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&fds), 0)
        _ = fcntl(fds[1], F_SETNOSIGPIPE, 1)
        pipes.append(contentsOf: fds)
        return (fds[0], fds[1])
    }

    private func closeTracked(_ fd: Int32) {
        close(fd)
        pipes.removeAll { $0 == fd }
    }

    /// If the reader gives up early, closing the read end fails the write with EPIPE, so a regression fails
    /// the test instead of hanging it.
    private func writeInBackground(_ fd: Int32, _ data: String, after delay: useconds_t = 0) -> DispatchSemaphore {
        pipes.removeAll { $0 == fd }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            if delay > 0 { usleep(delay) }
            let bytes = Array(data.utf8)
            var offset = 0
            while offset < bytes.count {
                let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, $0.count - offset) }
                if written <= 0 { break }
                offset += written
            }
            close(fd)
            done.signal()
        }
        return done
    }

    private func write(_ fd: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        XCTAssertEqual(bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }, bytes.count)
    }

    func testReadsToEndOfFile() {
        let (reader, writer) = makePipe()
        write(writer, #"{"hook_event_name":"Stop"}"#)
        closeTracked(writer)
        XCTAssertEqual(HookRuntime.readInput(fd: reader, maxBytes: 1 << 20, timeout: 2), Data(#"{"hook_event_name":"Stop"}"#.utf8))
    }

    /// Regression: a non-blocking stdin returned empty data (EAGAIN) before the agent wrote, logging the event
    /// as `{}`.
    func testNonBlockingDescriptorWaitsForTheWriter() {
        let (reader, writer) = makePipe()
        _ = fcntl(reader, F_SETFL, fcntl(reader, F_GETFL) | O_NONBLOCK)
        let payload = JSONValue.object(["hook_event_name": .string("PostToolUse"),
                                        "pad": .string(String(repeating: "p", count: 300_000))]).serialized()
        let done = writeInBackground(writer, payload, after: 150_000)
        let data = HookRuntime.readInput(fd: reader, maxBytes: 1 << 20, timeout: 3)
        closeTracked(reader)
        XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(data.count, payload.utf8.count)
        XCTAssertEqual(data, Data(payload.utf8))
    }

    /// Returns nil past `waitLimit` (the caller must then unblock the reader) so a regression fails the test
    /// instead of hanging the whole run.
    private func readInBackground(fd: Int32, maxBytes: Int, timeout: TimeInterval,
                                  waitLimit: TimeInterval) -> (data: Data, elapsed: TimeInterval)? {
        final class Result: @unchecked Sendable { var value: (Data, TimeInterval)? }
        let result = Result()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let started = Date()
            let data = HookRuntime.readInput(fd: fd, maxBytes: maxBytes, timeout: timeout)
            result.value = (data, Date().timeIntervalSince(started))
            finished.signal()
        }
        guard finished.wait(timeout: .now() + waitLimit) == .success else { return nil }
        return result.value
    }

    func testWriterThatNeverClosesIsBoundedByTheDeadline() throws {
        let (reader, writer) = makePipe()
        write(writer, #"{"hook_event_name":"Sto"#)
        guard let (data, elapsed) = readInBackground(fd: reader, maxBytes: 1 << 20, timeout: 0.3, waitLimit: 2) else {
            closeTracked(writer) // EOF unblocks the stuck reader
            return XCTFail("readInput waited past its deadline for a writer that never closes")
        }
        XCTAssertEqual(data, Data(#"{"hook_event_name":"Sto"#.utf8))
        XCTAssertGreaterThanOrEqual(elapsed, 0.25)
        XCTAssertLessThan(elapsed, 1.5)
    }

    func testExcessInputIsDrainedSoTheWriterNeverBlocks() {
        let (reader, writer) = makePipe()
        // Far more than the pipe buffer: the writer only finishes if the reader drains.
        let written = writeInBackground(writer, String(repeating: "x", count: 400_000))
        let data = HookRuntime.readInput(fd: reader, maxBytes: 1000, timeout: 3)
        XCTAssertEqual(written.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(data, Data(repeating: UInt8(ascii: "x"), count: 1000))
    }

    func testEndlessWriterIsBoundedByTheDeadline() {
        let (reader, writer) = makePipe()
        pipes.removeAll { $0 == writer } // closed by the writer thread
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var raised = false
            func raise() { lock.lock(); raised = true; lock.unlock() }
            var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return raised }
        }
        let stop = Flag()
        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let chunk = [UInt8](repeating: UInt8(ascii: "y"), count: 4096)
            while !stop.isRaised, chunk.withUnsafeBytes({ Darwin.write(writer, $0.baseAddress, $0.count) }) > 0 {}
            close(writer)
            stopped.signal()
        }
        let outcome = readInBackground(fd: reader, maxBytes: 100, timeout: 0.3, waitLimit: 2)
        stop.raise() // on a regression this ends the stream so the stuck reader sees EOF
        closeTracked(reader) // otherwise the writer gets EPIPE (no SIGPIPE) and stops
        XCTAssertEqual(stopped.wait(timeout: .now() + 3), .success)
        guard let (data, elapsed) = outcome else {
            return XCTFail("readInput kept draining an endless writer past its deadline")
        }
        XCTAssertLessThan(elapsed, 1.5)
        XCTAssertEqual(data.count, 100)
    }

    func testRegularFileAndInvalidDescriptor() throws {
        let dir = IPCTestSupport.makeShortTempDir("spin")
        defer { IPCTestSupport.remove(dir) }
        let file = dir.appendingPathComponent("payload.json")
        try Data(#"{"a":1}"#.utf8).write(to: file)
        let fd = open(file.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(HookRuntime.readInput(fd: fd, maxBytes: 100, timeout: 1), Data(#"{"a":1}"#.utf8))

        // A descriptor that is not open (stdin closed by the agent) returns at once.
        let started = Date()
        XCTAssertEqual(HookRuntime.readInput(fd: 9_999, maxBytes: 100, timeout: 2), Data())
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    func testDefaultBounds() {
        XCTAssertEqual(HookRuntime.standardInputTimeout, 3)
        XCTAssertEqual(HookRuntime.standardInputMaxBytes, 16 << 20)
    }
}
