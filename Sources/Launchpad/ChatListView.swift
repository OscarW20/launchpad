#if os(macOS)
import SwiftUI
import LaunchpadCore

/// What your bots are doing, live.
struct ActivityButton: View {
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: { Label("Activity", systemImage: "waveform.path.ecg") }
            .help("What your bots are doing")
            .popover(isPresented: $showing) { ActivityFeedView() }
    }
}

struct ChatListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                SearchField(text: $model.chatSearch, prompt: "Search chats")
                NewChatMenu(circle: true)
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.top, Theme.Space.l)

            PillTabs(selection: $model.chatFilter, options: ChatFilter.allCases.map { ($0.title, $0) })
                .padding(.horizontal, Theme.Space.l)
                .padding(.top, Theme.Space.m)
                .padding(.bottom, Theme.Space.s)

            let chats = model.filteredChats
            if chats.isEmpty {
                emptyState
            } else {
                PanelList(selection: $model.selectedChatId) {
                    ForEach(chats) { chat in
                        ChatRow(chat: chat)
                            .selectableRow(chat.id)
                            .contextMenu {
                                if let bot = model.bot(chat.botId) {
                                    Button("New Chat with \(bot.name)") { model.newChat(with: bot) }
                                }
                                Button("Open in New Window") { openWindow(id: "chat", value: chat.id) }
                                Button("Save as Skill from This Chat") { model.teachSkill(from: chat.id) }
                                Divider()
                                ChatWorkspaceMenu(chat: chat)
                                Divider()
                                Button("Delete Chat", role: .destructive) { model.deleteChat(chat.id) }
                            }
                    }
                }
            }
        }
        .navigationTitle("Chats")
        .toolbar {
            ToolbarItem {
                NeedsYouButton()
            }
            ToolbarItem {
                ActivityButton()
            }
            ToolbarItem {
                Button { model.showingSavedMessages = true } label: { Label("Saved Messages", systemImage: "bookmark") }
                    .help("Messages you saved for later (⇧⌘S)")
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: Theme.Space.m) {
            Spacer()
            if model.chatFilter == .groups && model.chatSearch.isEmpty {
                Text("No group chats yet.")
                    .font(.system(size: 15, weight: .semibold))
                Button("New Group") { model.showingNewGroup = true }
                    .buttonStyle(PillButtonStyle())
                Button("Hire the Dev team") { model.section = .hire }
                    .buttonStyle(SoftButtonStyle())
            } else if !model.chatSearch.isEmpty {
                Text("No chats match “\(model.chatSearch)”.")
                    .foregroundStyle(Theme.secondary)
            } else if model.bots.isEmpty {
                Text("No chats yet.")
                    .font(.system(size: 15, weight: .semibold))
                Text("Create a bot to start your first chat.")
                    .foregroundStyle(Theme.secondary)
                Button("New Bot") { model.showingNewBot = true }
                    .buttonStyle(PillButtonStyle())
            } else {
                Text("No chats yet.")
                    .font(.system(size: 15, weight: .semibold))
                NewChatMenu()
                    .fixedSize()
            }
            Spacer()
        }
        .multilineTextAlignment(.center)
        .padding()
        .frame(maxWidth: .infinity)
    }
}

struct NewChatMenu: View {
    @Environment(AppModel.self) private var model
    /// Drawn as the round compose button next to the search field.
    var circle = false

    var body: some View {
        if circle {
            CircleMenu(symbol: "square.and.pencil", help: "Start a new chat", size: 36) { items }
        } else {
            Menu { items } label: {
                Label("New Chat", systemImage: "square.and.pencil")
            }
            .help("Start a new chat")
        }
    }

    @ViewBuilder private var items: some View {
        if !model.workspaceBots.isEmpty {
            Section("Chat with") {
                ForEach(model.workspaceBots) { bot in
                    Button("\(bot.emoji)  \(bot.name)") { model.newChat(with: bot) }
                }
            }
        }
        if !model.workspaceGroups.isEmpty {
            Section("Groups") {
                ForEach(model.workspaceGroups) { group in
                    Button("\(group.emoji)  \(group.displayName)") { model.openChat(with: group) }
                }
            }
        }
        Divider()
        Button("New Bot…") { model.showingNewBot = true }
        Button("New Group…") { model.showingNewGroup = true }
    }
}

struct ChatRow: View {
    @Environment(AppModel.self) private var model
    let chat: ChatMeta

    var body: some View {
        let bot = model.bot(chat.botId)
        HStack(alignment: .center, spacing: Theme.Space.m) {
            if chat.kind == .group {
                GroupAvatar(group: model.group(chat.groupId), size: 40)
            } else {
                AvatarView(bot: bot, size: 40)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(chat.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    if chat.kind == .group {
                        RoleTag(text: "Group")
                    } else if let role = bot?.role, !role.isEmpty {
                        RoleTag(text: role)
                            .layoutPriority(-1)
                    }
                    Spacer(minLength: 4)
                    Text(TimeLabel.short(chat.updatedAt))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                }
                if model.isRunning(chat.id) {
                    HStack(spacing: 5) {
                        Circle().fill(Theme.successFill).frame(width: 6, height: 6)
                        Text("working…")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.success)
                } else {
                    Text(previewText)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var previewText: String {
        let p = (chat.lastPreview ?? "").replacingOccurrences(of: "\n", with: " ")
        if !p.isEmpty { return p }
        if let group = model.group(chat.groupId) { return "\(group.everyone.count) members" }
        return "Say hello"
    }
}
#endif
