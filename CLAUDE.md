# Launchpad

Native macOS (14+) SwiftUI app, Swift Package Manager. See README.md and BUILD_LOG.md.

- `Sources/LaunchpadCore` has no UI and must keep building on Linux (`swift build`, `swift test`).
- `Sources/Launchpad` is macOS only; every file is wrapped in `#if os(macOS)`.
- Keep BUILD_LOG.md up to date with each phase: what was built, decisions, tests.
- Secrets only ever go in the macOS Keychain: never in files, logs or chat.
- Parser fixtures in `Tests/LaunchpadCoreTests/Fixtures.swift` are trimmed real CLI output; re-capture
  them when the CLIs change.
