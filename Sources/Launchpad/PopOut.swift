#if os(macOS)
import SwiftUI
import LaunchpadCore

/// One chat on its own, in its own window (to keep next to your editor, or to watch a bot work).
struct PopOutChat: View {
    @Environment(AppModel.self) private var model
    let chatId: String

    var body: some View {
        Group {
            if model.chat(chatId) != nil {
                ConversationView(chatId: chatId, poppedOut: true)
            } else {
                ContentUnavailableView("This chat was deleted", systemImage: "trash")
            }
        }
        .frame(minWidth: 460, minHeight: 520)
        .background(Theme.canvas)
        .navigationTitle(model.chat(chatId)?.title ?? "Chat")
    }
}

/// "Open in New Window" for a chat.
struct OpenInWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    let chatId: String

    var body: some View {
        Button { openWindow(id: "chat", value: chatId) } label: {
            Label("Open in New Window", systemImage: "macwindow.on.rectangle")
        }
        .help("Open this chat in its own window")
    }
}

/// Back and forward buttons for the toolbar (⌘[ and ⌘]).
struct HistoryButtons: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ControlGroup {
            Button { model.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(!model.nav.canGoBack)
                .help("Back (⌘[)")
            Button { model.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                .disabled(!model.nav.canGoForward)
                .help("Forward (⌘])")
        }
    }
}
#endif
