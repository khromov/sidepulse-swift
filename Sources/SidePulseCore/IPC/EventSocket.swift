import Darwin
import Foundation

/// Socket protocol (Unix stream socket at `SidePulsePaths.socketPath`). One message
/// per connection: the client writes one compact UTF-8 JSON object (≤1 MiB), then
/// shuts down its write side (or closes). The server reads to EOF and optionally
/// replies with bytes, then closes.
///
/// Messages:
/// - Event (from hooks, no reply): `{"provider":"claude","line":{…record…}}`
/// - Command: `{"command":"<name>", …args}` → reply
///   - `ping` → `{"ok":true,"pid":123,"version":"0.1.0"}`
///   - `status` → MonitorSnapshot JSON
///   - `open-settings` → `ok`
///   - `reload-settings` → `ok`, or `{"ok":false,"error":"LED write in progress"}`
///     when a write that started with the old settings is still running
///   - unknown → `{"ok":false,"error":"unknown command"}`
public enum IPCMessage: Sendable, Equatable {
    case event(provider: String, line: JSONObject)
    case command(name: String, args: JSONObject)

    /// nil for invalid JSON / unrecognized shapes.
    ///
    /// A string `command` key wins (its other keys become `args`); otherwise a
    /// string `provider` plus an object `line` is an event.
    public static func parse(_ data: Data) -> IPCMessage? {
        guard !data.isEmpty, let value = try? JSONValue.parse(data), case .object(let object) = value else { return nil }
        if case .string(let name)? = object["command"] {
            var args = object
            args.removeValue(forKey: "command")
            return .command(name: name, args: args)
        }
        if case .string(let provider)? = object["provider"], case .object(let line)? = object["line"] {
            return .event(provider: provider, line: line)
        }
        return nil
    }

    /// Compact JSON bytes.
    public func encoded() -> Data {
        var object = JSONObject()
        switch self {
        case .event(let provider, let line):
            object["provider"] = .string(provider)
            object["line"] = .object(line)
        case .command(let name, let args):
            object["command"] = .string(name)
            for (key, value) in args where key != "command" { object[key] = value }
        }
        return Data(JSONValue.object(object).serialized().utf8)
    }
}

/// Standard reply bodies shared by the server and its handlers.
public enum IPCReply {
    /// `ok` (open-settings, reload-settings).
    public static let ok = Data("ok".utf8)

    /// `{"ok":true,"pid":<pid>,"version":"<version>"}`.
    public static func ping(pid: pid_t = getpid(), version: String = SidePulseConstants.version) -> Data {
        let object: JSONObject = ["ok": .bool(true), "pid": JSONValue(Int(pid)), "version": .string(version)]
        return Data(JSONValue.object(object).serialized().utf8)
    }

    /// `{"ok":false,"error":"<message>"}`.
    public static func error(_ message: String) -> Data {
        let object: JSONObject = ["ok": .bool(false), "error": .string(message)]
        return Data(JSONValue.object(object).serialized().utf8)
    }

    public static let unknownCommand = error("unknown command")
}

public enum EventSocketClient {
    /// Largest reply `request` accepts.
    public static let maxReplyBytes = 8 << 20

    /// Fire-and-forget event send (tests; the hook sends pre-encoded bytes with
    /// `send`). Returns true if the whole message was written.
    @discardableResult
    static func sendEvent(provider: String, line: JSONObject, socketPath: String,
                                 timeout: TimeInterval = SidePulseConstants.hookSendTimeout) -> Bool {
        send(IPCMessage.event(provider: provider, line: line).encoded(), socketPath: socketPath, timeout: timeout)
    }

    /// Sends one pre-encoded message and closes, all within `timeout` (connect and
    /// write share one deadline). false if it is larger than `maxEventBytes`, no
    /// server listens, the socket file is not owned by the current user, or the
    /// deadline passes.
    @discardableResult
    public static func send(_ message: Data, socketPath: String,
                            timeout: TimeInterval = SidePulseConstants.hookSendTimeout) -> Bool {
        guard message.count <= SidePulseConstants.maxEventBytes else { return false }
        let deadline = SocketDeadline(after: timeout)
        guard let fd = UnixSocket.connect(path: socketPath, deadline: deadline) else { return false }
        defer { close(fd) }
        return UnixSocket.writeAll(fd, message, deadline: deadline)
    }

    /// Sends a command, shuts down the write side, reads the reply to EOF (≤ 8 MiB)
    /// within `timeout`. nil if no server / timeout.
    ///
    /// Also nil for replies over `maxReplyBytes`. A server that closes without
    /// replying yields empty data. `timeout` covers connect, send and reply.
    public static func request(_ command: String, args: JSONObject = JSONObject(), socketPath: String,
                               timeout: TimeInterval = 2) -> Data? {
        let message = IPCMessage.command(name: command, args: args).encoded()
        guard message.count <= SidePulseConstants.maxEventBytes else { return nil }
        let deadline = SocketDeadline(after: timeout)
        guard let fd = UnixSocket.connect(path: socketPath, deadline: deadline) else { return nil }
        defer { close(fd) }
        guard UnixSocket.writeAll(fd, message, deadline: deadline) else { return nil }
        shutdown(fd, SHUT_WR)
        if case .data(let reply) = UnixSocket.readAll(fd, limit: maxReplyBytes, deadline: deadline) {
            return reply
        }
        return nil
    }

    /// `ping` round-trip succeeded.
    public static func isServerRunning(socketPath: String, timeout: TimeInterval = 0.5) -> Bool {
        guard let reply = request("ping", socketPath: socketPath, timeout: timeout),
              let value = try? JSONValue.parse(reply) else { return false }
        return value["ok"] == .bool(true)
    }
}

public enum EventSocketError: Error, Equatable, LocalizedError {
    /// Another live server answered `ping` on this path.
    case alreadyRunning(String)
    case bindFailed(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning(let p): return "Another SidePulse instance is already serving \(p)."
        case .bindFailed(let m): return "Could not bind event socket: \(m)"
        }
    }
}

/// Accept loop on a background thread; each connection is read with a 2 s timeout
/// on a concurrent queue, so one slow client never blocks the accept loop. The
/// handler is called on an internal serial queue, in ACCEPT order (a reorder
/// buffer holds early finishers), and returns optional reply bytes. Ordering
/// matters: a hook's PreToolUse connection is accepted before its PostToolUse
/// connection, and applying them reversed would leave a row stuck on Tool Running.
/// A message is held behind an unfinished earlier connection for at most
/// `reorderGrace`, so a stalled client cannot delay everyone else.
///
/// If the handler returns nil for `ping`, the server answers with `IPCReply.ping()`
/// itself, so `EventSocketClient.isServerRunning` always works. Messages over
/// `maxMessageBytes`, invalid JSON and unknown shapes are dropped without calling
/// the handler. The accept thread keeps the server alive until `stop()`.
public final class EventSocketServer: @unchecked Sendable {
    public let path: String
    // Tunables (internal: tests shorten them before `start()`).
    /// Per-connection read deadline.
    var readTimeout: TimeInterval = 2
    /// Deadline for writing a reply.
    let writeTimeout: TimeInterval = 2
    /// Larger messages are dropped.
    let maxMessageBytes = SidePulseConstants.maxEventBytes
    /// How long `start()` waits to connect to an existing socket file.
    var probeTimeout: TimeInterval = 1
    /// Max time a finished message waits for an earlier, still-reading connection.
    var reorderGrace: TimeInterval = 0.25

    private let handler: @Sendable (IPCMessage) -> Data?
    private let lock = NSLock()
    private var listening: Listening?
    /// Bumped by every `start()`, so work left over from an earlier cycle never
    /// reaches the handler after a restart.
    private var generation = 0
    private let connectionQueue = DispatchQueue(label: "sidepulse.events.connections", attributes: .concurrent)
    private let handlerQueue = DispatchQueue(label: "sidepulse.events.handler")

    /// A connection whose read finished, waiting for its turn (handlerQueue only).
    private struct Completed {
        var message: IPCMessage?
        var fd: Int32
        var arrived: UInt64
    }
    // Reorder buffer state; touched only on handlerQueue.
    private var deliveryCycle = -1
    private var nextDelivery = 0
    private var pendingDelivery: [Int: Completed] = [:]
    /// Slots given up on after `reorderGrace`; delivered late when they finish.
    private var skippedDelivery = Set<Int>()
    private var releaseScheduled = false

    /// State of one `start()`…`stop()` cycle.
    private struct Listening {
        var fd: Int32
        var wakeRead: Int32
        var wakeWrite: Int32
        var device: dev_t
        var inode: ino_t
        var exited: DispatchSemaphore
    }

    public init(path: String, handler: @escaping @Sendable (IPCMessage) -> Data?) {
        self.path = path
        self.handler = handler
    }

    deinit { stop() }

    /// True between a successful `start()` and `stop()`.
    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return listening != nil
    }

    /// Creates the parent dir (0700). If a server already answers ping at `path`,
    /// throws `.alreadyRunning` WITHOUT touching the socket file. Otherwise unlinks a
    /// stale file, binds, chmod 0600, listens.
    ///
    /// "Answers" means accepts a connection within `probeTimeout`: a live instance
    /// whose handler is busy (or hung) still owns the socket and must not be
    /// displaced. Only a refused connection (nobody listening, e.g. after a crash)
    /// or a file that is not our socket counts as stale. The parent directory must
    /// belong to the current user (the `/tmp` fallback could be pre-created by
    /// someone else), otherwise `.bindFailed`. Paths longer than `sun_path` allows
    /// (103 bytes) throw `.bindFailed`. Calling `start()` on a running server does
    /// nothing.
    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard listening == nil else { return }
        guard path.utf8.count <= UnixSocket.maxPathBytes else {
            throw EventSocketError.bindFailed("path is longer than \(UnixSocket.maxPathBytes) bytes: \(path)")
        }
        let directory = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw EventSocketError.bindFailed("cannot create \(directory): \(error.localizedDescription)")
        }
        var directoryInfo = stat()
        guard stat(directory, &directoryInfo) == 0, directoryInfo.st_uid == geteuid() else {
            throw EventSocketError.bindFailed("\(directory) is not owned by the current user")
        }

        var existing = stat()
        if lstat(path, &existing) == 0 {
            if (existing.st_mode & S_IFMT) == S_IFDIR {
                throw EventSocketError.bindFailed("\(path) is a directory")
            }
            if anotherServerListens() { throw EventSocketError.alreadyRunning(path) }
            unlink(path)
        }

        guard var address = UnixSocket.address(path) else {
            throw EventSocketError.bindFailed("invalid path: \(path)")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw EventSocketError.bindFailed(UnixSocket.lastError("socket")) }
        UnixSocket.configure(fd)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let failure = UnixSocket.lastError("bind")
            let inUse = errno == EADDRINUSE
            close(fd)
            // Lost a race with another instance that bound between our unlink and bind.
            if inUse && anotherServerListens() { throw EventSocketError.alreadyRunning(path) }
            throw EventSocketError.bindFailed(failure)
        }
        chmod(path, 0o600)
        var info = stat()
        guard stat(path, &info) == 0, listen(fd, SOMAXCONN) == 0 else {
            let failure = UnixSocket.lastError("listen")
            close(fd)
            unlink(path)
            throw EventSocketError.bindFailed(failure)
        }

        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else {
            let failure = UnixSocket.lastError("pipe")
            close(fd)
            unlink(path)
            throw EventSocketError.bindFailed(failure)
        }
        for end in pipeFDs { UnixSocket.configure(end) }

        let state = Listening(fd: fd, wakeRead: pipeFDs[0], wakeWrite: pipeFDs[1],
                              device: info.st_dev, inode: info.st_ino, exited: DispatchSemaphore(value: 0))
        listening = state
        generation += 1
        let cycle = generation
        let thread = Thread { [self] in
            acceptLoop(listenFD: state.fd, wakeFD: state.wakeRead, cycle: cycle)
            state.exited.signal()
        }
        thread.name = "sidepulse.events.accept"
        thread.start()
    }

    /// Stops accepting and unlinks the socket file only if it is still ours (same inode).
    ///
    /// Messages that arrive after `stop()` never reach the handler, and a later
    /// `start()` never receives work left over from this cycle. A message already
    /// being dispatched when `stop()` is called may still be delivered once:
    /// `stop()` does not wait for the handler, so calling it from inside the
    /// handler (or while the handler waits on the caller) cannot deadlock.
    public func stop() {
        lock.lock()
        guard let state = listening else { lock.unlock(); return }
        listening = nil
        lock.unlock()

        var byte: UInt8 = 1
        _ = write(state.wakeWrite, &byte, 1)
        _ = state.exited.wait(timeout: .now() + 2)
        close(state.fd)
        close(state.wakeRead)
        close(state.wakeWrite)

        var current = stat()
        if lstat(path, &current) == 0, current.st_dev == state.device, current.st_ino == state.inode {
            unlink(path)
        }
    }

    // MARK: Internals

    /// Some process accepts connections on `path`. A crashed server's leftover file
    /// refuses the connection; any listener is alive, even if it never replies.
    private func anotherServerListens() -> Bool {
        guard let fd = UnixSocket.connect(path: path, deadline: SocketDeadline(after: probeTimeout)) else { return false }
        close(fd)
        return true
    }

    /// The server is still in the `start()` cycle `cycle`.
    private func isServing(_ cycle: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return listening != nil && generation == cycle
    }

    private func acceptLoop(listenFD: Int32, wakeFD: Int32, cycle: Int) {
        // Per-cycle accept sequence numbers drive in-order delivery.
        var acceptedCount = 0
        var fds = [pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0),
                   pollfd(fd: wakeFD, events: Int16(POLLIN), revents: 0)]
        while true {
            fds[0].revents = 0
            fds[1].revents = 0
            let ready = poll(&fds, nfds_t(fds.count), -1)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if fds[1].revents != 0 { return }
            if fds[0].revents & Int16(POLLERR | POLLNVAL) != 0 { return }
            guard fds[0].revents & Int16(POLLIN) != 0 else { continue }
            // Drain every pending connection; the listening socket is non-blocking.
            while true {
                let connection = accept(listenFD, nil, nil)
                if connection < 0 {
                    if errno == EINTR { continue }
                    if errno == EMFILE || errno == ENFILE { usleep(10_000) }
                    break
                }
                UnixSocket.configure(connection)
                let sequence = acceptedCount
                acceptedCount += 1
                connectionQueue.async { [self] in serve(connection, cycle: cycle, sequence: sequence) }
            }
        }
    }

    private func serve(_ fd: Int32, cycle: Int, sequence: Int) {
        let deadline = SocketDeadline(after: readTimeout)
        var message: IPCMessage?
        if case .data(let data) = UnixSocket.readAll(fd, limit: maxMessageBytes, deadline: deadline) {
            message = IPCMessage.parse(data)
        }
        let item = Completed(message: message, fd: fd, arrived: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        handlerQueue.async { [self] in
            if cycle != deliveryCycle {
                // A newer start() cycle resets the buffer; leftovers of older cycles are dropped.
                guard cycle > deliveryCycle else { close(fd); return }
                for pending in pendingDelivery.values { close(pending.fd) }
                deliveryCycle = cycle
                nextDelivery = 0
                pendingDelivery = [:]
                skippedDelivery = []
            }
            if skippedDelivery.remove(sequence) != nil {
                // Its slot was released after the grace period: deliver late.
                dispatch(item, cycle: cycle)
                return
            }
            // Failed/invalid reads still take their slot so later messages are not held up.
            pendingDelivery[sequence] = item
            drainDeliveries(cycle: cycle)
            scheduleRelease(cycle: cycle)
        }
    }

    /// Delivers consecutive finished slots. handlerQueue only.
    private func drainDeliveries(cycle: Int) {
        while let next = pendingDelivery.removeValue(forKey: nextDelivery) {
            nextDelivery += 1
            dispatch(next, cycle: cycle)
        }
    }

    /// While messages wait behind an unfinished slot, re-check after the grace period.
    private func scheduleRelease(cycle: Int) {
        guard !pendingDelivery.isEmpty, !releaseScheduled else { return }
        releaseScheduled = true
        handlerQueue.asyncAfter(deadline: .now() + max(0.01, reorderGrace)) { [self] in
            releaseScheduled = false
            guard cycle == deliveryCycle else { return }
            releaseStale(cycle: cycle)
            scheduleRelease(cycle: cycle)
        }
    }

    /// Skips unfinished slots in front of messages that waited at least `reorderGrace`.
    private func releaseStale(cycle: Int) {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let grace = UInt64(max(0, reorderGrace) * 1_000_000_000)
        guard let target = pendingDelivery.filter({ now &- $0.value.arrived >= grace }).keys.max() else { return }
        while nextDelivery <= target {
            if let next = pendingDelivery.removeValue(forKey: nextDelivery) {
                dispatch(next, cycle: cycle)
            } else {
                skippedDelivery.insert(nextDelivery)
            }
            nextDelivery += 1
        }
        drainDeliveries(cycle: cycle)
    }

    /// Runs the handler for one message and sends its reply. handlerQueue only.
    private func dispatch(_ item: Completed, cycle: Int) {
        let fd = item.fd
        guard let message = item.message, isServing(cycle) else { close(fd); return }
        var reply = handler(message)
        if reply == nil, case .command(name: "ping", _) = message { reply = IPCReply.ping() }
        guard let reply, !reply.isEmpty else { close(fd); return }
        let timeout = writeTimeout
        connectionQueue.async {
            _ = UnixSocket.writeAll(fd, reply, deadline: SocketDeadline(after: timeout))
            close(fd)
        }
    }
}

// MARK: - POSIX helpers

/// Monotonic deadline for socket operations.
struct SocketDeadline {
    private let end: UInt64

    init(after seconds: TimeInterval) {
        let nanos = seconds.isFinite ? max(0, seconds) * 1_000_000_000 : 0
        end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &+ UInt64(min(nanos, 1e18))
    }

    /// Milliseconds left for `poll`, rounded up; 0 once passed.
    var remainingMilliseconds: Int32 {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        guard end > now else { return 0 }
        return Int32(min((end - now + 999_999) / 1_000_000, UInt64(Int32.max)))
    }
}

enum UnixSocket {
    /// `sun_path` is 104 bytes on macOS, including the terminating NUL.
    static let maxPathBytes = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    enum ReadResult {
        case data(Data)
        case tooLarge
        case failed
    }

    static func address(_ path: String) -> sockaddr_un? {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count <= maxPathBytes, !bytes.contains(0) else { return nil }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    /// Close-on-exec (child processes must not inherit sockets), no SIGPIPE, non-blocking.
    static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// `path` (after symlinks) is a socket owned by the effective user.
    static func isOwnSocket(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK && info.st_uid == geteuid()
    }

    static func lastError(_ call: String) -> String {
        "\(call): \(String(cString: strerror(errno)))"
    }

    /// Non-blocking connect bounded by `deadline`. Returns a configured fd.
    ///
    /// Refuses (nil, without connecting) unless `path` is a socket owned by the
    /// current user: records carry prompts, and the `/tmp` fallback directory
    /// could have been pre-created by another local user.
    static func connect(path: String, deadline: SocketDeadline) -> Int32? {
        guard isOwnSocket(path), var addr = address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        configure(fd)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc == 0 { return fd }
        if errno == EINPROGRESS || errno == EINTR || errno == EAGAIN, wait(fd, for: POLLOUT, deadline: deadline) {
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            if getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 { return fd }
        }
        close(fd)
        return nil
    }

    /// Waits until `fd` is ready for `event` (or has an error/hangup the next call
    /// will report). false on timeout.
    static func wait(_ fd: Int32, for event: Int32, deadline: SocketDeadline) -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(event), revents: 0)
        while true {
            let timeout = deadline.remainingMilliseconds
            guard timeout > 0 else { return false }
            let ready = poll(&descriptor, 1, timeout)
            if ready > 0 { return true }
            if ready < 0 && errno != EINTR { return false }
        }
    }

    static func writeAll(_ fd: Int32, _ data: Data, deadline: SocketDeadline) -> Bool {
        data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, base + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    guard wait(fd, for: POLLOUT, deadline: deadline) else { return false }
                } else {
                    return false
                }
            }
            return true
        }
    }

    /// Reads to EOF. `.tooLarge` as soon as more than `limit` bytes arrive.
    static func readAll(_ fd: Int32, limit: Int, deadline: SocketDeadline) -> ReadResult {
        var result = Data()
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                guard result.count + count <= limit else { return .tooLarge }
                result.append(contentsOf: chunk[0..<count])
            } else if count == 0 {
                return .data(result)
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                guard wait(fd, for: POLLIN, deadline: deadline) else { return .failed }
            } else {
                return .failed
            }
        }
    }
}
