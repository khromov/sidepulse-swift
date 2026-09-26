import Foundation

/// Reads a file descriptor to EOF without `FileHandle`, for `write -` and piped
/// programs. (The hook reads stdin with `HookRuntime.readStandardInput`.)
///
/// `FileHandle.readDataToEndOfFile()` raises an Objective-C exception (and the
/// process aborts) when the inherited descriptor is non-blocking and no data is
/// ready yet.
enum InputReader {
    /// Reads `fd` until EOF (blocking, like `cat -`).
    ///
    /// Waits with `poll` before every read, so `EAGAIN` from a non-blocking
    /// descriptor never loses data; `EINTR` is retried. Read errors and invalid
    /// descriptors end the read with the data so far.
    static func readAll(fd: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, -1) < 0 {
                if errno == EINTR { continue }
                return data
            }
            if descriptor.revents & Int16(POLLNVAL) != 0 { return data }
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                data.append(contentsOf: buffer[0..<count])
            } else if count == 0 {
                return data
            } else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
                return data
            }
        }
    }
}
