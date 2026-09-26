import Darwin
import Foundation
import XCTest
@testable import SidePulseCore

/// Helpers shared by the HookRuntime / IPC / Power tests.
enum IPCTestSupport {
    /// A fresh directory under /tmp with a short name, so socket paths stay far
    /// below the 104-byte `sun_path` limit (the default temp dir is too long).
    static func makeShortTempDir(_ prefix: String = "spt") -> URL {
        var template = Array("/tmp/\(prefix).XXXXXX".utf8CString)
        let created = template.withUnsafeMutableBufferPointer { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            return mkdtemp(base) != nil
        }
        precondition(created, "mkdtemp failed")
        let path = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Polls `condition` until it is true or `timeout` passes.
    @discardableResult
    static func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            usleep(5_000)
        }
        return condition()
    }

    /// Leaves a socket file with nobody listening (a crashed server's leftover).
    static func makeStaleSocket(at path: String) {
        guard var address = UnixSocket.address(path) else { return XCTFail("bad socket path \(path)") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        let rc = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(rc, 0, "bind stale socket")
        close(fd)
    }

    /// A socket that listens but never accepts or reads (a hung server).
    static func makeSilentListener(at path: String) -> Int32 {
        guard var address = UnixSocket.address(path) else { XCTFail("bad socket path \(path)"); return -1 }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        let rc = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(rc, 0, "bind silent listener")
        XCTAssertEqual(listen(fd, 16), 0)
        return fd
    }

    static func inode(of path: String) -> ino_t? {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_ino : nil
    }

    /// Runs `body` with fds 1 and 2 redirected to a file; returns what was written.
    static func captureStandardStreams(in directory: URL, _ body: () -> Void) -> Data {
        let capture = directory.appendingPathComponent("captured-\(UUID().uuidString).out")
        fflush(stdout)
        fflush(stderr)
        let fd = open(capture.path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        precondition(fd >= 0)
        let savedOut = dup(STDOUT_FILENO)
        let savedErr = dup(STDERR_FILENO)
        dup2(fd, STDOUT_FILENO)
        dup2(fd, STDERR_FILENO)
        body()
        fflush(stdout)
        fflush(stderr)
        dup2(savedOut, STDOUT_FILENO)
        dup2(savedErr, STDERR_FILENO)
        close(savedOut)
        close(savedErr)
        close(fd)
        defer { try? FileManager.default.removeItem(at: capture) }
        return (try? Data(contentsOf: capture)) ?? Data()
    }

    /// Thread-safe collector for handler callbacks.
    final class Inbox<Element>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Element] = []

        func append(_ element: Element) {
            lock.lock(); storage.append(element); lock.unlock()
        }

        var items: [Element] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }

        var count: Int { items.count }
    }
}
