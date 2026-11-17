#if os(macOS)
import SwiftUI
import LaunchpadCore

struct ChatListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Picker("Show", selection: $model.chatFilter) {
                ForEach(ChatFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            let chats = model.filteredChats
            if chats.isEmpty {
                emptyState
            } else {
                List(selection: $model.selectedChatId) {
                    ForEach(chats) { chat in
                        ChatRow(chat: chat)
                            .tag(chat.id)
                            .contextMenu {
                                if let bot = model.bot(chat.botId) {
                                    Button("New Chat with \(bot.name)") { model.newChat(with: bot) }
                                }
                                Button("Teach a Skill from This Chat") { model.teachSkill(from: chat.id) }
                                Divider()
                                Button("Delete Chat", role: .destructive) { model.deleteChat(chat.id) }
                            }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Theme.canvas)
        .searchable(text: $model.chatSearch, prompt: "Search chats")
        .navigationTitle("Chats")
        .toolbar {
            ToolbarItem {
                NewChatMenu()
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            if model.chatFilter == .groups && model.chatSearch.isEmpty {
                Text("No group chats yet.")
                    .font(Theme.rounded(.headline))
                Button("New Group") { model.showingNewGroup = true }
                    .buttonStyle(.borderedProminent)
                Button("Hire the Dev team") { model.section = .hire }
            } else if !model.chatSearch.isEmpty {
                Text("No chats match “\(model.chatSearch)”.")
                    .foregroundStyle(.secondary)
            } else if model.bots.isEmpty {
                Text("No chats yet.")
                    .font(Theme.rounded(.headline))
                Text("Create a bot to start your first chat.")
                    .foregroundStyle(.secondary)
                Button("New Bot") { model.showingNewBot = true }
                    .buttonStyle(.borderedProminent)
            } else {
                Text("No chats yet.")
                    .font(Theme.rounded(.headline))
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

    var body: some View {
        Menu {
            if !model.bots.isEmpty {
                Section("Chat with") {
                    ForEach(model.bots) { bot in
                        Button("\(bot.emoji)  \(bot.name)") { model.newChat(with: bot) }
                    }
                }
            }
            if !model.groups.isEmpty {
                Section("Groups") {
                    ForEach(model.groups) { group in
                        Button("\(group.emoji)  \(group.displayName)") { model.openChat(with: group) }
                    }
                }
            }
            Divider()
            Button("New Bot…") { model.showingNewBot = true }
            Button("New Group…") { model.showingNewGroup = true }
        } label: {
            Label("New Chat", systemImage: "square.and.pencil")
        }
        .help("Start a new chat")
    }
}

struct ChatRow: View {
    @Environment(AppModel.self) private var model
    let chat: ChatMeta

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if chat.kind == .group {
                GroupAvatar(group: model.group(chat.groupId), size: 36)
            } else {
                AvatarView(bot: model.bot(chat.botId), size: 36)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(chat.title)
                        .font(Theme.rounded(.body, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(TimeLabel.short(chat.updatedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.isRunning(chat.id) {
                    Label("working…", systemImage: "ellipsis")
                        .font(.callout)
                        .foregroundStyle(Theme.accent)
                } else {
                    Text(previewText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var previewText: String {
        let p = (chat.lastPreview ?? "").replacingOccurrences(of: "\n", with: " ")
        if !p.isEmpty { return p }
        if let role = model.bot(chat.botId)?.role, !role.isEmpty { return role }
        if let group = model.group(chat.groupId) { return "\(group.everyone.count) members" }
        return "Say hello"
    }
}
#endif
