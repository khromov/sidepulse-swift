import Foundation
import SidePulseCore

/// Line format follows Python `render_led_sync_result`.
public enum LedsText {
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
