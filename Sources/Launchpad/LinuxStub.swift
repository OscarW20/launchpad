#if !os(macOS)
// Launchpad is a macOS app. On other platforms this target only exists so the
// package (and LaunchpadCore's tests) can build in CI.
@main
enum LaunchpadUnsupported {
    static func main() {
        print("Launchpad runs on macOS 14 or later.")
    }
}
#endif
