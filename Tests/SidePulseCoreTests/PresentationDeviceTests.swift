import Foundation
import XCTest
@testable import SidePulseCore

/// How device problems reach the Devices submenu (`DeviceMenuModel`).
final class PresentationDeviceTests: XCTestCase {
    private func info(error: String?) -> DeviceInfo {
        DeviceInfo(id: "/Volumes/PulseDot", name: "SidePulse Dot", root: URL(fileURLWithPath: "/Volumes/PulseDot"),
                   target: URL(fileURLWithPath: "/Volumes/PulseDot/LEDS.LED"), connected: true, display: .agent,
                   brightness: 255, ledCount: 2, lastError: error)
    }

    /// Regression: a write stuck on the macOS permission prompt showed nothing,
    /// and a denial showed only a raw EPERM.
    func testPermissionProblemsShowInTheSubmenu() {
        let healthy = DeviceMenuModel(info(error: nil))
        XCTAssertNil(healthy.errorText)

        let waiting = DeviceMenuModel(info(error: LedSyncService.waitingForPermissionMessage))
        XCTAssertEqual(waiting.errorText, "Error: Waiting for macOS permission to access this device — check for a system prompt")
        XCTAssertNotEqual(waiting.shape, healthy.shape, "the item appears, so an open menu rebuilds the submenu")

        let denied = DeviceMenuModel(info(error: LedSyncService.accessDeniedMessage))
        XCTAssertEqual(denied.errorText, "Error: macOS denied access. Allow SidePulse in System Settings › Privacy & Security "
            + "› Files and Folders (Removable Volumes)")
        XCTAssertEqual(denied.shape, waiting.shape, "switching between the two updates the item in place")
    }
}
