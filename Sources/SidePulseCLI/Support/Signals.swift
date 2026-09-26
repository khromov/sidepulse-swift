import Foundation
import Synchronization

/// Replaces the default SIGINT/SIGTERM actions until `cancel()`, so Ctrl-C becomes an event the CLI
/// can react to.
final class SignalTrap: Sendable {
    private let signals: [Int32]
    private let state: Mutex<State>

    private struct State {
        var sources: [DispatchSourceSignal] = []
        var received: Int32?
        var handler: ((Int32) -> Void)?
    }

    /// `handler` runs on a background queue for every received signal.
    init(signals: [Int32] = [SIGINT, SIGTERM], handler: ((Int32) -> Void)? = nil) {
        self.signals = signals
        state = Mutex(State(handler: handler))
        for number in signals {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in self?.receive(number) }
            source.resume()
            state.withLock { $0.sources.append(source) }
        }
    }

    deinit { cancel() }

    var received: Int32? { state.withLock { $0.received } }

    private func receive(_ number: Int32) {
        let handler = state.withLock { state in
            if state.received == nil { state.received = number }
            return state.handler
        }
        handler?(number)
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
        let active = state.withLock { state in
            defer { state.sources = []; state.handler = nil }
            return state.sources
        }
        guard !active.isEmpty else { return }
        active.forEach { $0.cancel() }
        signals.forEach { signal($0, SIG_DFL) }
    }
}
