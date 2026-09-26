// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SidePulse",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "sidepulse", targets: ["sidepulse"]),
        .executable(name: "SidePulseApp", targets: ["SidePulseApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        // Foundation/Darwin/IOKit/Synchronization only: every hook runs the CLI, so it must launch fast.
        .target(
            name: "SidePulseCore",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        // All CLI commands live in a library so they can be unit tested.
        .target(name: "SidePulseCLI", dependencies: ["SidePulseCore"]),
        .executableTarget(name: "sidepulse", dependencies: ["SidePulseCLI"]),
        .executableTarget(
            name: "SidePulseApp",
            dependencies: [
                "SidePulseCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                // build-app.sh copies Sparkle.framework into SidePulse.app/Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(name: "SidePulseCoreTests", dependencies: ["SidePulseCore"]),
        .testTarget(name: "SidePulseCLITests", dependencies: ["SidePulseCLI", "SidePulseCore"]),
    ],
    swiftLanguageModes: [.v5]
)
