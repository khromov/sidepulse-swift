import Foundation
import XCTest
@testable import SidePulseCLI

/// Uses SIGUSR1/SIGUSR2 so a mistake cannot kill the test run with SIGINT.
final class CLISignalTrapTests: XCTestCase {
    func testSignalRunsTheHandlerAndIsRecorded() {
        let handled = expectation(description: "handler ran")
        let trap = SignalTrap(signals: [SIGUSR1]) { number in
            XCTAssertEqual(number, SIGUSR1)
            handled.fulfill()
        }
        defer { trap.cancel() }
        XCTAssertNil(trap.received)
        kill(getpid(), SIGUSR1)
        wait(for: [handled], timeout: 5)
        XCTAssertEqual(trap.received, SIGUSR1)
    }

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
