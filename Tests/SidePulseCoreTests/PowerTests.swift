import IOKit.ps
import IOKit.pwr_mgt
import XCTest
@testable import SidePulseCore

private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }

final class PowerKeepAwakePolicyTests: XCTestCase {
    /// Python test_keep_awake_holds_working_then_graces_done.
    func testWorkingHoldsThenDoneGraces() {
        var policy = KeepAwakePolicy(grace: 300)
        XCTAssertTrue(policy.agentsActive(mode: .working, now: at(100)))
        XCTAssertNil(policy.pendingGraceDeadline)
        XCTAssertTrue(policy.agentsActive(mode: .completed, now: at(110)))
        XCTAssertEqual(policy.pendingGraceDeadline, at(410))
        XCTAssertTrue(policy.agentsActive(mode: .idleReady, now: at(200)))
        XCTAssertFalse(policy.agentsActive(mode: .idleReady, now: at(411)))
    }

    /// Python test_keep_awake_ask_grace_expires_without_refresh_extension.
    func testAskGraceIsNotExtendedByRefreshes() {
        var policy = KeepAwakePolicy(grace: 300)
        XCTAssertTrue(policy.agentsActive(mode: .waitingForInput, now: at(100)))
        XCTAssertTrue(policy.agentsActive(mode: .waitingForInput, now: at(350)))
        XCTAssertFalse(policy.agentsActive(mode: .waitingForInput, now: at(401)))
        XCTAssertFalse(policy.agentsActive(mode: .waitingForInput, now: at(1000)))
    }

    func testDefaultGraceIsFiveMinutes() {
        var policy = KeepAwakePolicy()
        XCTAssertEqual(policy.grace, 300)
        XCTAssertTrue(policy.agentsActive(mode: .blockedError, now: at(0)))
        XCTAssertTrue(policy.agentsActive(mode: .blockedError, now: at(299.9)))
        XCTAssertFalse(policy.agentsActive(mode: .blockedError, now: at(300)))
    }

    func testEnteringAnotherGraceModeRestartsTheGrace() {
        var policy = KeepAwakePolicy(grace: 300)
        XCTAssertTrue(policy.agentsActive(mode: .completed, now: at(0)))
        XCTAssertTrue(policy.agentsActive(mode: .waitingForInput, now: at(200)))
        XCTAssertTrue(policy.agentsActive(mode: .waitingForInput, now: at(450)))
        XCTAssertFalse(policy.agentsActive(mode: .waitingForInput, now: at(501)))
        // Leaving and re-entering the same mode starts a new grace too.
        XCTAssertFalse(policy.agentsActive(mode: .idleReady, now: at(600)))
        XCTAssertTrue(policy.agentsActive(mode: .waitingForInput, now: at(700)))
        XCTAssertTrue(policy.agentsActive(mode: .waitingForInput, now: at(999)))
        XCTAssertFalse(policy.agentsActive(mode: .waitingForInput, now: at(1000)))
    }

    func testWorkingClearsGrace() {
        var policy = KeepAwakePolicy(grace: 300)
        XCTAssertTrue(policy.agentsActive(mode: .completed, now: at(0)))
        for mode in AgentMode.workingGroup {
            XCTAssertTrue(policy.agentsActive(mode: mode, now: at(10)))
            XCTAssertNil(policy.pendingGraceDeadline)
        }
        XCTAssertFalse(policy.agentsActive(mode: .idleReady, now: at(20)))
    }

    func testIdleAndUnknownWithoutGraceAreInactive() {
        var policy = KeepAwakePolicy()
        XCTAssertFalse(policy.agentsActive(mode: .idleReady, now: at(0)))
        XCTAssertFalse(policy.agentsActive(mode: .unknown, now: at(0)))
        XCTAssertTrue(policy.agentsActive(mode: .completed, now: at(1)))
        XCTAssertTrue(policy.agentsActive(mode: .unknown, now: at(2)))
    }

    func testCustomGrace() {
        var policy = KeepAwakePolicy(grace: 5)
        XCTAssertTrue(policy.agentsActive(mode: .completed, now: at(0)))
        XCTAssertFalse(policy.agentsActive(mode: .idleReady, now: at(5)))
    }

    // MARK: Battery safeguard

    private func battery(_ percent: Double?, plugged: Bool, present: Bool = true) -> BatteryState {
        BatteryState(present: present, percent: percent, onACPower: plugged, charging: false)
    }

    /// Python test_sleep_prevention_battery_safeguard_activates_only_on_battery.
    func testSafeguardActivatesOnlyOnBattery() {
        XCTAssertTrue(KeepAwakePolicy.safeguardActive(battery: battery(19, plugged: false), minBatteryPercent: 20))
        XCTAssertFalse(KeepAwakePolicy.safeguardActive(battery: battery(19, plugged: true), minBatteryPercent: 20))
        XCTAssertFalse(KeepAwakePolicy.safeguardActive(battery: battery(5, plugged: false), minBatteryPercent: 0))
    }

    func testSafeguardEdges() {
        XCTAssertFalse(KeepAwakePolicy.safeguardActive(battery: battery(20, plugged: false), minBatteryPercent: 20), "strictly below")
        XCTAssertTrue(KeepAwakePolicy.safeguardActive(battery: battery(19.9, plugged: false), minBatteryPercent: 20))
        XCTAssertFalse(KeepAwakePolicy.safeguardActive(battery: battery(5, plugged: false), minBatteryPercent: -10))
        XCTAssertTrue(KeepAwakePolicy.safeguardActive(battery: battery(99.5, plugged: false), minBatteryPercent: 150), "clamped to 100")
        XCTAssertFalse(KeepAwakePolicy.safeguardActive(battery: battery(100, plugged: false), minBatteryPercent: 150))
        XCTAssertFalse(KeepAwakePolicy.safeguardActive(battery: battery(nil, plugged: false), minBatteryPercent: 20), "unknown percent")
        XCTAssertFalse(KeepAwakePolicy.safeguardActive(battery: battery(5, plugged: false, present: false), minBatteryPercent: 20))
        XCTAssertFalse(KeepAwakePolicy.safeguardActive(battery: .unknown, minBatteryPercent: 20))
        XCTAssertFalse(KeepAwakePolicy.safeguardActive(battery: battery(5, plugged: false), minBatteryPercent: .nan))
    }

    func testShouldHoldMatrix() {
        let low = battery(10, plugged: false)
        let fine = battery(80, plugged: false)
        let cases: [(SleepPolicy, Bool, BatteryState, Bool)] = [
            (.never, false, fine, false), (.never, true, fine, false), (.never, true, low, false),
            (.agents, false, fine, false), (.agents, true, fine, true), (.agents, true, low, false), (.agents, false, low, false),
            (.always, false, fine, true), (.always, true, fine, true), (.always, false, low, false), (.always, true, low, false),
            (.always, false, battery(10, plugged: true), true), (.agents, true, .unknown, true),
        ]
        for (policy, active, state, expected) in cases {
            XCTAssertEqual(KeepAwakePolicy.shouldHold(policy: policy, agentsActive: active, battery: state, minBatteryPercent: 20),
                           expected, "\(policy) active=\(active) \(state)")
        }
        // Threshold 0 disables the safeguard entirely.
        XCTAssertTrue(KeepAwakePolicy.shouldHold(policy: .always, agentsActive: false, battery: low, minBatteryPercent: 0))
    }
}

final class PowerBatteryTests: XCTestCase {
    func testReadSmoke() {
        let state = BatteryState.read()
        print("Power battery: present=\(state.present) percent=\(state.percent.map { String($0) } ?? "nil") ac=\(state.onACPower) charging=\(state.charging)")
        if state.present {
            let percent = try? XCTUnwrap(state.percent)
            XCTAssertTrue(percent.map { (0...100).contains($0) } ?? false)
            if state.charging { XCTAssertTrue(state.onACPower, "charging implies external power") }
        } else {
            XCTAssertNil(state.percent)
        }
        // Stable across quick successive reads.
        XCTAssertEqual(BatteryState.read().present, state.present)
    }

    func testThisMacHasABattery() throws {
        let sources = (IOPSCopyPowerSourcesInfo()?.takeRetainedValue()).flatMap {
            IOPSCopyPowerSourcesList($0)?.takeRetainedValue() as? [CFTypeRef]
        } ?? []
        try XCTSkipIf(sources.isEmpty, "no power sources (desktop Mac)")
        XCTAssertTrue(BatteryState.read().present)
    }

    func testDescriptionParsing() {
        let base: [String: Any] = [
            kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSIsPresentKey: true,
            kIOPSCurrentCapacityKey: 57, kIOPSMaxCapacityKey: 100,
            kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue, kIOPSIsChargingKey: false,
        ]
        XCTAssertEqual(BatteryState.from(powerSourceDescription: base, providingAC: false),
                       BatteryState(present: true, percent: 57, onACPower: false, charging: false))

        var charging = base
        charging[kIOPSPowerSourceStateKey] = kIOPSACPowerValue
        charging[kIOPSIsChargingKey] = true
        charging[kIOPSCurrentCapacityKey] = 50
        charging[kIOPSMaxCapacityKey] = 200
        XCTAssertEqual(BatteryState.from(powerSourceDescription: charging, providingAC: false),
                       BatteryState(present: true, percent: 25, onACPower: true, charging: true))

        var noState = base
        noState.removeValue(forKey: kIOPSPowerSourceStateKey)
        noState[kIOPSMaxCapacityKey] = 0
        XCTAssertEqual(BatteryState.from(powerSourceDescription: noState, providingAC: true),
                       BatteryState(present: true, percent: nil, onACPower: true, charging: false))

        var over = base
        over[kIOPSCurrentCapacityKey] = 120
        XCTAssertEqual(BatteryState.from(powerSourceDescription: over, providingAC: false)?.percent, 100)

        var removed = base
        removed[kIOPSIsPresentKey] = false
        XCTAssertEqual(BatteryState.from(powerSourceDescription: removed, providingAC: true)?.percent, nil)
        XCTAssertEqual(BatteryState.from(powerSourceDescription: removed, providingAC: true)?.present, false)

        var ups = base
        ups[kIOPSTypeKey] = kIOPSUPSType
        XCTAssertNil(BatteryState.from(powerSourceDescription: ups, providingAC: true))
        XCTAssertNil(BatteryState.from(powerSourceDescription: [:], providingAC: true))
    }
}

final class PowerKeepAwakeAssertionTests: XCTestCase {
    /// Our process's power assertions of type PreventUserIdleSystemSleep, by name.
    private func heldAssertionNames() -> [String] {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let all = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        return (all[NSNumber(value: getpid())] ?? [])
            .filter { $0[kIOPMAssertionTypeKey] as? String == kIOPMAssertionTypePreventUserIdleSystemSleep }
            .compactMap { $0[kIOPMAssertionNameKey] as? String }
    }

    func testHoldAndReleaseTheAssertion() {
        let reason = "SidePulse test \(UUID().uuidString)"
        let assertion = KeepAwakeAssertion(reason: reason)
        XCTAssertFalse(assertion.isHeld)
        assertion.setHeld(false) // releasing when idle is a no-op

        assertion.setHeld(true)
        assertion.setHeld(true)
        XCTAssertTrue(assertion.isHeld)
        XCTAssertNil(assertion.lastError)
        XCTAssertEqual(heldAssertionNames().filter { $0 == reason }.count, 1, "holding again keeps one assertion")

        assertion.setHeld(false)
        XCTAssertFalse(assertion.isHeld)
        XCTAssertFalse(heldAssertionNames().contains(reason))
    }

    func testAssertionIsReleasedWhenTheHolderGoesAway() {
        let reason = "SidePulse test \(UUID().uuidString)"
        var assertion: KeepAwakeAssertion? = KeepAwakeAssertion(reason: reason)
        assertion?.setHeld(true)
        XCTAssertTrue(heldAssertionNames().contains(reason))
        assertion = nil
        XCTAssertFalse(heldAssertionNames().contains(reason))
    }

    func testConcurrentTogglingIsSafe() {
        let reason = "SidePulse test \(UUID().uuidString)"
        let assertion = KeepAwakeAssertion(reason: reason)
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            assertion.setHeld(index % 2 == 0)
            _ = assertion.isHeld
        }
        assertion.setHeld(false)
        XCTAssertFalse(heldAssertionNames().contains(reason))
    }
}
