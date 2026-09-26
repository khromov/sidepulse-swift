/// Animations and profiles that exist only in the Swift port.
enum ExtraPrograms {
    static let catalog: [Animation] = [
        Animation(id: "solid-red", name: "Solid Red", countSpecific: false),
        Animation(id: "solid-blue", name: "Solid Blue", countSpecific: false),
        Animation(id: "red-double-blink", name: "Red Double Blink", countSpecific: false),
        Animation(id: "blue-double-blink", name: "Blue Double Blink", countSpecific: false),
    ]

    static let files: [String: String] = [
        "solid-red.LED": "#FF0000 320ms cosine",
        "solid-blue.LED": "#0000FF 320ms cosine",
        "red-double-blink.LED": doubleBlink("#FF0000"),
        "blue-double-blink.LED": doubleBlink("#0000FF"),
    ]

    /// Two short pulses from off, then a hold: a line that sets the color it already shows just keeps it lit.
    private static func doubleBlink(_ color: String) -> String {
        ["off 80ms cosine", "\(color) 300ms pulse", "\(color) 300ms pulse", "\(color) 120ms cosine",
         "\(color) 1.5s linear", "repeat"].joined(separator: "\n")
    }

    static let profiles: [AnimationProfile] = [
        AnimationProfile(id: "profile:signal", name: "Signal", animations: [
            .idleReady: "solid-blue",
            .working: "ember-tide",
            .toolRunning: "ember-tide",
            .waitingForInput: "solid-red",
            .longTaskProgress: "ember-tide",
            .blockedError: "red-double-blink",
            .completed: "solid-green",
            .unknown: "blue-double-blink",
        ]),
    ]
}
