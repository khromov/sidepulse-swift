// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SidePulse",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "sidepulse", targets: ["sidepulse"]),
        .executable(name: "SidePulseApp", targets: ["SidePulseApp"]),
        .library(name: "SidePulseCore", targets: ["SidePulseCore"]),
    ],
    targets: [
        // Foundation/Darwin/IOKit only. No AppKit: the hook path must launch fast.
        .target(
            name: "SidePulseCore",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        // All CLI commands live in a library so they can be unit tested.
        .target(name: "SidePulseCLI", dependencies: ["SidePulseCore"]),
        .executableTarget(name: "sidepulse", dependencies: ["SidePulseCLI"]),
        // Menu-bar app (AppKit + SwiftUI). Bundled into SidePulse.app by scripts/build-app.sh.
        .executableTarget(
            name: "SidePulseApp",
            dependencies: ["SidePulseCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .testTarget(name: "SidePulseCoreTests", dependencies: ["SidePulseCore"]),
        .testTarget(name: "SidePulseCLITests", dependencies: ["SidePulseCLI", "SidePulseCore"]),
    ],
    swiftLanguageModes: [.v5]
)
