#if os(macOS)
import SwiftUI
import LaunchpadCore

/// "Browser open · 12 min" in the chat header while the shared browser the bots use is open (a bot opened it, perhaps for you to
/// sign in to something), with a Close button so you can see it's still there and shut it yourself. It's one browser shared by all
/// the bots, so it doesn't say which bot opened it. It stays open when a bot finishes, is steered, or another bot starts.
struct BrowserOpenIndicator: View {
    var body: some View {
        // Checked every few seconds: the host isn't observable, and it can close by itself if the app's helper stops.
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let host = SharedBrowserHost.shared
            if host.isOpen, let since = host.heldSince {
                let minutes = max(0, Int(context.date.timeIntervalSince(since) / 60))
                HStack(spacing: 6) {
                    Image(systemName: "safari.fill")
                    Text(minutes == 0 ? "Browser open" : "Browser open · \(minutes) min")
                        .font(.system(size: 11, weight: .semibold))
                    Button("Close") { Task { await host.closeBrowser() } }
                        .buttonStyle(SoftButtonStyle())
                        .controlSize(.mini)
                        .help("Closes the browser the bots are using. Anything you're signed in to there is lost, and the next bot that needs a browser opens a new one.")
                }
                .foregroundStyle(Theme.accentText)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Theme.accentSoft))
                .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.4), lineWidth: 1))
                .fixedSize()
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Browser open for \(minutes) minutes. Close button")
            }
        }
    }
}
#endif
