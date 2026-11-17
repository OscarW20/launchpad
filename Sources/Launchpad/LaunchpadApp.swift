#if os(macOS)
import SwiftUI
import AppKit
import LaunchpadCore

@main
struct LaunchpadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @AppStorage(MacPrefs.menuBar) private var showMenuBar = true

    var body: some Scene {
        Window("Launchpad", id: "main") {
            RootView()
                .environment(model)
                .tint(Theme.accent)
                .frame(minWidth: 1000, minHeight: 620)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Bot…") { model.showingNewBot = true }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Quick Ask…") { QuickAsk.shared.show() }
            }
            CommandMenu("Go") {
                Button("Back") { model.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!model.nav.canGoBack)
                Button("Forward") { model.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!model.nav.canGoForward)
                Divider()
                Button("Office") { model.section = .office }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Quick Switcher…") { model.showingQuickSwitcher = true }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Saved Messages") { model.showingSavedMessages = true }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }

        // A chat in its own window, to keep next to your editor or to watch a bot work.
        WindowGroup("Chat", id: "chat", for: String.self) { $chatId in
            if let chatId {
                PopOutChat(chatId: chatId)
                    .environment(model)
                    .tint(Theme.accent)
            }
        }
        .defaultSize(width: 560, height: 760)

        // Who's working, recent chats, Quick Ask and Stop, from the menu bar.
        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarContent()
                .environment(model)
                .tint(Theme.accent)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched with `swift run` rather than from an .app bundle.
        NSApp.setActivationPolicy(.regular)
        // The bundled .app gets its icon from AppIcon.icns; `swift run` needs it set here.
        if Bundle.main.bundleURL.pathExtension != "app",
           let url = AppResources.url("AppIcon-1024", "png", in: "Brand"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// With the menu bar icon on, closing the window keeps Launchpad (and your bots) running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !MacPrefs.showsMenuBar }

    /// Clicking the Dock icon with no window open brings the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { MainWindow.bringForward() } }
        return true
    }
}
#endif
