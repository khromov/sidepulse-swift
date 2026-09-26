import Foundation
import Synchronization
@testable import SidePulseCore

/// Namespaced so other test files can use the same helper names freely.
enum LEDTestSupport {
    /// Lid animations were deliberately dropped in the port.
    static func isLidAnimation(_ name: String) -> Bool {
        name.hasPrefix("lid-") || name.contains("-lid-")
    }
}

/// While armed, holds LED writes where open() waits on the macOS permission prompt (`inOpen`) or
/// where a card stops answering after the settings check (`afterCheck`); LedWriter refuses the
/// FIFOs tests used for this before.
final class LedWriteGate: Sendable {
    enum Stall: Sendable { case inOpen, afterCheck }

    private struct State {
        var stall: Stall?
        var held = 0
    }

    private let state = Mutex(State())
    private let arrived = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)

    func arm(_ stall: Stall) {
        state.withLock { $0.stall = stall }
    }

    func waitForHeldWrite(timeout: TimeInterval = 3) -> Bool {
        arrived.wait(timeout: .now() + timeout) == .success
    }

    /// Lets every held write go on and holds no more.
    func release() {
        let held = state.withLock { state -> Int in
            defer { state = State() }
            return state.held
        }
        for _ in 0..<held { gate.signal() }
    }

    var writer: LedSyncService.FileWriter {
        { [self] program, target, expected, shouldWrite in
            hold(at: .inOpen)
            return try LedWriter.write(program, to: target, ifHolding: expected) {
                guard shouldWrite() else { return false }
                hold(at: .afterCheck)
                return true
            }
        }
    }

    private func hold(at point: Stall) {
        let holds = state.withLock { state -> Bool in
            guard state.stall == point else { return false }
            state.held += 1
            return true
        }
        guard holds else { return }
        arrived.signal()
        gate.wait()
    }
}
