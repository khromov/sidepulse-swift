import XCTest
@testable import SidePulseCore

final class SDEjectGuardRuleTests: XCTestCase {
    /// The same test as the Python helper's `is_builtin_sd`: a substring match, case-sensitive.
    func testMatchesTheBuiltInSDReader() {
        let matches: [(String?, String?)] = [
            ("Secure Digital", nil), (nil, "SDXC Reader"), ("Secure Digital", "APPLE SD Card Reader"),
            ("USB", "Built In SDXC Reader"),
        ]
        let others: [(String?, String?)] = [
            (nil, nil), ("USB", "Flash Disk"), ("secure digital", "sdxc reader"), ("Disk Image", "SidePulse Pro"),
            ("PCI-Express", "APPLE SSD AP1024Z"),
        ]
        for (deviceProtocol, model) in matches {
            XCTAssertTrue(SDEjectGuardRule.isBuiltInSDReader(deviceProtocol: deviceProtocol, model: model), "\(deviceProtocol ?? "nil") \(model ?? "nil")")
        }
        for (deviceProtocol, model) in others {
            XCTAssertFalse(SDEjectGuardRule.isBuiltInSDReader(deviceProtocol: deviceProtocol, model: model), "\(deviceProtocol ?? "nil") \(model ?? "nil")")
        }
    }
}
