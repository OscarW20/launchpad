#if os(macOS)
import SwiftUI
import AppKit
import LaunchpadCore

@main
struct LaunchpadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Launchpad") {
            RootView()
                .environment(model)
                .tint(Theme.accent)
                .frame(minWidth: 1000, minHeight: 620)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Bot…") { model.showingNewBot = true }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
            }
            CommandMenu("Go") {
                Button("Quick Switcher…") { model.showingQuickSwitcher = true }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Saved Messages") { model.showingSavedMessages = true }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched with `swift run` rather than from an .app bundle.
        NSApp.setActivationPolicy(.regular)
        // The bundled .app gets its icon from AppIcon.icns; `swift run` needs it set here.
        if Bundle.main.bundleURL.pathExtension != "app",
           let url = Bundle.module.url(forResource: "AppIcon-1024", withExtension: "png", subdirectory: "Brand"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#endif
