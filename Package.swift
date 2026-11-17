// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Launchpad",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Launchpad", targets: ["Launchpad"]),
        .library(name: "LaunchpadCore", targets: ["LaunchpadCore"]),
    ],
    targets: [
        // Everything that isn't UI: bot folders, chat history, the engine runner,
        // stream parsers and error handling. Builds and tests on Linux too.
        .target(name: "LaunchpadCore"),
        // The SwiftUI app (macOS only).
        .executableTarget(name: "Launchpad", dependencies: ["LaunchpadCore"]),
        .testTarget(name: "LaunchpadCoreTests", dependencies: ["LaunchpadCore"]),
    ]
)
