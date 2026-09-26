import Foundation
import XCTest
@testable import SidePulseCLI

/// `SignalTrap` turns Ctrl-C / SIGTERM into an event (`live`, `leds`/`run`,
/// `app --foreground`). Exercised with SIGUSR1/SIGUSR2 sent to this process so a
/// mistake cannot kill the test run with SIGINT.
final class CLISignalTrapTests: XCTestCase {
    func testWaitTimesOutWithoutASignal() {
        let trap = SignalTrap(signals: [SIGUSR1])
        defer { trap.cancel() }
        XCTAssertFalse(trap.wait(timeout: 0.05))
        XCTAssertNil(trap.received)
    }

    func testSignalEndsTheWaitRunsTheHandlerAndStaysLatched() {
        let handled = expectation(description: "handler ran")
        let trap = SignalTrap(signals: [SIGUSR1]) { number in
            XCTAssertEqual(number, SIGUSR1)
            handled.fulfill()
        }
        defer { trap.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { kill(getpid(), SIGUSR1) }
        XCTAssertTrue(trap.wait(timeout: 5))
        XCTAssertEqual(trap.received, SIGUSR1)
        wait(for: [handled], timeout: 5)
        // Later waits (the next redraw) return at once.
        XCTAssertTrue(trap.wait(timeout: 5))
    }

    /// The foreground runtime's loop: main-queue work keeps running until a signal.
    func testMainLoopServicesTheMainQueueUntilASignal() {
        XCTAssertTrue(Thread.isMainThread)
        let trap = SignalTrap(signals: [SIGUSR2])
        defer { trap.cancel() }
        var mainQueueRuns = 0
        DispatchQueue.main.async { mainQueueRuns += 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            mainQueueRuns += 1
            DispatchQueue.global().async { kill(getpid(), SIGUSR2) }
        }
        let start = ProcessInfo.processInfo.systemUptime
        trap.runMainLoopUntilSignal()
        XCTAssertEqual(trap.received, SIGUSR2)
        XCTAssertEqual(mainQueueRuns, 2)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 5)
    }
}
