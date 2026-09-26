/// Animations and profiles that exist only in the Swift port; BuiltInPrograms.swift stays a pure mirror of the Python data.
enum ExtraPrograms {
    static let catalog: [Animation] = [
        Animation(id: "solid-red", name: "Solid Red", countSpecific: false),
        Animation(id: "solid-blue", name: "Solid Blue", countSpecific: false),
    ]

    static let files: [String: String] = [
        "solid-red.LED": "#FF0000 320ms cosine",
        "solid-blue.LED": "#0000FF 320ms cosine",
    ]

    static let profiles: [AnimationProfile] = [
        AnimationProfile(id: "profile:signal", name: "Signal", animations: [
            .idleReady: "solid-blue",
            .working: "ember-tide",
            .toolRunning: "ember-tide",
            .waitingForInput: "ember-complete",
            .longTaskProgress: "ember-tide",
            .blockedError: "solid-red",
            .completed: "solid-green",
            .unknown: "solid-blue",
        ]),
    ]
}
