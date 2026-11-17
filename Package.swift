// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Launchpad",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Launchpad", targets: ["Launchpad"]),
        .library(name: "LaunchpadCore", targets: ["LaunchpadCore"]),
        .executable(name: "launchpad-guard", targets: ["launchpad-guard"]),
        .executable(name: "launchpad-chat", targets: ["launchpad-chat"]),
    ],
    targets: [
        // Everything that isn't UI: bot folders, chat history, the engine runner,
        // stream parsers and error handling. Builds and tests on Linux too.
        .target(name: "LaunchpadCore"),
        // The approval hook Claude Code runs before shell commands and MCP tools.
        .executableTarget(name: "launchpad-guard", dependencies: ["LaunchpadCore"]),
        // The chat tools MCP server bots use to react, send GIFs, run polls, ask questions and share plans.
        .executableTarget(name: "launchpad-chat", dependencies: ["LaunchpadCore"]),
        // The SwiftUI app (macOS only).
        // Brand logos for the marketplace (see Resources/Logos/README.md).
        .executableTarget(name: "Launchpad", dependencies: ["LaunchpadCore"], resources: [.copy("Resources/Logos")]),
        .testTarget(name: "LaunchpadCoreTests", dependencies: ["LaunchpadCore"]),
    ]
)
