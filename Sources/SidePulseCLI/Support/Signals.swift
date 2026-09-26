import Foundation

/// Replaces the default SIGINT/SIGTERM actions until `cancel()`, so Ctrl-C becomes an event the CLI
/// can wait for.
final class SignalTrap: @unchecked Sendable {
    private let signals: [Int32]
    private var sources: [DispatchSourceSignal] = []
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var receivedSignal: Int32?
    private var handler: ((Int32) -> Void)?

    /// `handler` runs on a background queue for every received signal.
    init(signals: [Int32] = [SIGINT, SIGTERM], handler: ((Int32) -> Void)? = nil) {
        self.signals = signals
        self.handler = handler
        for number in signals {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in self?.receive(number) }
            source.resume()
            sources.append(source)
        }
    }

    deinit { cancel() }

    var received: Int32? {
        lock.lock(); defer { lock.unlock() }
        return receivedSignal
    }

    private func receive(_ number: Int32) {
        lock.lock()
        let first = receivedSignal == nil
        if first { receivedSignal = number }
        let handler = self.handler
        lock.unlock()
        handler?(number)
        if first { semaphore.signal() }
    }

    func wait(timeout: TimeInterval) -> Bool {
        if received != nil { return true }
        if semaphore.wait(timeout: .now() + max(0, timeout)) == .success {
            semaphore.signal() // keep later waits returning immediately
            return true
        }
        return received != nil
    }

    /// Must be called on the main thread.
    func runMainLoopUntilSignal() {
        // A run loop without sources returns immediately; keep one timer attached.
        let keepAlive = Timer(timeInterval: 3600, repeats: true) { _ in }
        RunLoop.main.add(keepAlive, forMode: .default)
        defer { keepAlive.invalidate() }
        while received == nil {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.25))
        }
    }

    func cancel() {
        lock.lock()
        let active = sources
        sources = []
        handler = nil
        lock.unlock()
        guard !active.isEmpty else { return }
        active.forEach { $0.cancel() }
        signals.forEach { signal($0, SIG_DFL) }
    }
}
