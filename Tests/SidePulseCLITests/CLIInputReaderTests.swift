import Foundation
import XCTest
@testable import SidePulseCLI

/// `InputReader` backs `write -`. It must never abort on a non-blocking
/// descriptor (FileHandle does).
final class CLIInputReaderTests: XCTestCase {
    private func makePipe() -> (read: Int32, write: Int32) {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&descriptors), 0)
        return (descriptors[0], descriptors[1])
    }

    private func send(_ text: String, to fd: Int32) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    func testReadsUntilEOF() {
        let pipe = makePipe()
        defer { close(pipe.read) }
        send("{\"hook_event_name\":\"Stop\"}", to: pipe.write)
        close(pipe.write)
        XCTAssertEqual(InputReader.readAll(fd: pipe.read), Data("{\"hook_event_name\":\"Stop\"}".utf8))
    }

    func testEmptyInputAndDevNull() {
        let pipe = makePipe()
        defer { close(pipe.read) }
        close(pipe.write)
        XCTAssertEqual(InputReader.readAll(fd: pipe.read), Data())

        let devNull = open("/dev/null", O_RDONLY)
        defer { close(devNull) }
        XCTAssertEqual(InputReader.readAll(fd: devNull), Data())
    }

    /// Regression: `FileHandle.readDataToEndOfFile()` raises
    /// NSFileHandleOperationException (the process aborts) on a non-blocking
    /// descriptor whose data has not arrived yet.
    func testNonBlockingDescriptorWaitsForLateData() {
        let pipe = makePipe()
        defer { close(pipe.read) }
        XCTAssertEqual(fcntl(pipe.read, F_SETFL, fcntl(pipe.read, F_GETFL) | O_NONBLOCK), 0)
        let writer = pipe.write
        let finished = expectation(description: "writer finished")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [self] in
            send("late ", to: writer)
            usleep(50_000)
            send("payload", to: writer)
            close(writer)
            finished.fulfill()
        }
        XCTAssertEqual(InputReader.readAll(fd: pipe.read), Data("late payload".utf8))
        wait(for: [finished], timeout: 5)
    }

    func testClosedDescriptorReturnsImmediately() {
        let pipe = makePipe()
        close(pipe.read)
        close(pipe.write)
        XCTAssertEqual(InputReader.readAll(fd: pipe.read), Data())
    }
}
