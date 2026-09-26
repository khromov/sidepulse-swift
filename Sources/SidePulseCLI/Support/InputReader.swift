import Foundation

/// Avoids `FileHandle.readDataToEndOfFile()`, which aborts the process when the inherited
/// descriptor is non-blocking and no data is ready yet.
enum InputReader {
    /// Polls before every read so `EAGAIN` from a non-blocking descriptor never loses data.
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
