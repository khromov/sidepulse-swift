/// Namespaced so other test files can use the same helper names freely.
enum LEDTestSupport {
    /// Lid animations were deliberately dropped in the port.
    static func isLidAnimation(_ name: String) -> Bool {
        name.hasPrefix("lid-") || name.contains("-lid-")
    }
}
