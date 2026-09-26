import Darwin
import Foundation
import XCTest
@testable import SidePulseCore

enum IPCTestSupport {
    /// The default temp dir is too long for the 104-byte `sun_path` limit.
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

    @discardableResult
    static func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            usleep(5_000)
        }
        return condition()
    }

    static func makeStaleSocket(at path: String) {
        guard var address = UnixSocket.address(path) else { return XCTFail("bad socket path \(path)") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        let rc = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(rc, 0, "bind stale socket")
        close(fd)
    }

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
