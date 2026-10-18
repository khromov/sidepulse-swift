import XCTest
@testable import SidePulseStreamDeck

final class SidePulseOpenerTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 0)
    private var launches = 0
    private var requests = 0

    private func opener(answersAfter: Int?, running: Bool = false, launches launchSucceeds: Bool = true) -> SidePulseOpener {
        SidePulseOpener(
            requestSettings: { [unowned self] in
                requests += 1
                return answersAfter.map { requests > $0 } ?? false
            },
            isRunning: { running },
            launchApp: { [unowned self] in launches += 1; return launchSucceeds },
            sleep: { [unowned self] in clock.addTimeInterval($0) },
            now: { [unowned self] in clock })
    }

    func testRunningAppOpensSettingsWithoutLaunching() {
        XCTAssertEqual(opener(answersAfter: 0).open(), .opened)
        XCTAssertEqual(launches, 0)
    }

    func testHeadlessRuntimeIsReported() {
        XCTAssertEqual(opener(answersAfter: nil, running: true).open(), .headless)
        XCTAssertEqual(launches, 0)
    }

    func testMissingAppIsReported() {
        XCTAssertEqual(opener(answersAfter: nil, launches: false).open(), .appNotFound)
        XCTAssertEqual(launches, 1)
    }

    func testLaunchesTheAppThenRetriesUntilItAnswers() {
        XCTAssertEqual(opener(answersAfter: 4).open(), .opened)
        XCTAssertEqual(launches, 1)
        XCTAssertEqual(requests, 5)
    }

    func testGivesUpAfterTheStartupTimeout() {
        XCTAssertEqual(opener(answersAfter: nil).open(), .timedOut)
        XCTAssertGreaterThanOrEqual(clock.timeIntervalSince1970, SidePulseOpener.startupTimeout)
        XCTAssertLessThan(clock.timeIntervalSince1970, SidePulseOpener.startupTimeout + 1)
    }

    func testFailureMessages() {
        XCTAssertNil(StatusPlugin.failureMessage(.opened))
        XCTAssertEqual(StatusPlugin.failureMessage(.appNotFound),
                       "SidePulse: SidePulse.app (io.sidepulse.swift) is not installed.")
        XCTAssertNotNil(StatusPlugin.failureMessage(.headless))
        XCTAssertNotNil(StatusPlugin.failureMessage(.timedOut))
    }
}
