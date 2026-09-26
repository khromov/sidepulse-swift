import Foundation

/// SidePulse Pro Eject Prevention, ported from the Python helper `sd_eject_guard.c`: loginwindow ejects a disk
/// that appears while the screen is locked, which is what the built-in SD slot does after a hibernate wake.
public enum SDEjectGuardRule {
    /// Any card in the built-in reader, not only a SidePulse Pro, matched case-sensitively like the Python helper.
    public static func isBuiltInSDReader(deviceProtocol: String?, model: String?) -> Bool {
        (deviceProtocol?.contains("Secure Digital") ?? false) || (model?.contains("SDXC") ?? false)
    }

    public static let dissentMessage = "SidePulse Pro Eject Prevention: keeping SD card attached"
    public static let mountRetryInterval: TimeInterval = 5
}
