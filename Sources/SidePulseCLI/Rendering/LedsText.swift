import Foundation
import SidePulseCore

/// `leds --once` result lines (Python `render_led_sync_result`).
public enum LedsText {
    /// `LEDs: {would write|wrote} <state> to <target|-> (aggregate=<mode>, active=<n>)`
    /// plus the program on the following lines for dry runs, or
    /// `LEDs: <state> error=<message>`.
    public static func render(_ result: LedSyncResult, snapshot: MonitorSnapshot, dryRun: Bool) -> String {
        let state = snapshot.aggregate.mode.displayState.label
        if let error = result.error { return errorLine(state: state, message: error) }
        let action = dryRun ? "would write" : "wrote"
        let target = result.target?.path ?? "-"
        var text = "LEDs: \(action) \(state) to \(target) "
            + "(aggregate=\(snapshot.aggregate.mode.label), active=\(snapshot.aggregate.activeCount))"
        if dryRun, !result.program.isEmpty { text += "\n" + result.program }
        return text
    }

    public static func errorLine(state: String, message: String) -> String {
        "LEDs: \(state) error=\(message)"
    }
}
