#if os(macOS)
import SwiftUI
import LaunchpadCore

struct ConversationView: View {
    @Environment(AppModel.self) private var model
    let chatId: String

    var body: some View {
        VStack(spacing: 0) {
            ConversationHeader(chatId: chatId)
            Divider()
            MessagesList(chatId: chatId)
            Composer(chatId: chatId)
        }
        .background(Theme.canvas)
        .navigationTitle(model.chat(chatId)?.title ?? "Chat")
        .task(id: chatId) { model.loadMessagesIfNeeded(chatId) }
    }
}

struct ConversationHeader: View {
    @Environment(AppModel.self) private var model
    let chatId: String

    var body: some View {
        let chat = model.chat(chatId)
        HStack(spacing: 12) {
            if chat?.kind == .group {
                groupInfo(model.group(chat?.groupId))
            } else {
                botInfo(model.bot(chat?.botId))
            }
            Spacer()
            actions(chat)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Theme.surface.opacity(0.6))
    }

    @ViewBuilder private func botInfo(_ bot: Bot?) -> some View {
        AvatarView(bot: bot, size: 40)
        VStack(alignment: .leading, spacing: 2) {
            Text(bot?.name ?? model.chat(chatId)?.title ?? "Chat")
                .font(Theme.rounded(.title3, weight: .bold))
            HStack(spacing: 6) {
                if let bot {
                    if !bot.role.isEmpty {
                        Text(bot.role).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Pill(text: bot.engine.displayName, symbol: bot.engine == .claude ? "sparkle" : "chevron.left.forwardslash.chevron.right")
                    Pill(text: bot.permission.displayName, symbol: permissionSymbol(bot.permission))
                } else {
                    Text("This chat's bot was removed.").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
    }

    @ViewBuilder private func groupInfo(_ group: BotGroup?) -> some View {
        GroupAvatar(group: group, size: 40)
        VStack(alignment: .leading, spacing: 3) {
            Text(group?.displayName ?? "Group")
                .font(Theme.rounded(.title3, weight: .bold))
            if let group {
                HStack(spacing: -6) {
                    ForEach(group.everyone, id: \.self) { id in
                        AvatarView(bot: model.bot(id), size: 20)
                            .background(Circle().fill(Theme.surface))
                            .help(model.bot(id)?.name ?? id)
                    }
                    Text("\(group.everyone.count) members · lead: \(model.bot(group.lead)?.name ?? "none") · hand-off limit \(group.handoffLimit)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                }
            } else {
                Text("This group was removed.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func actions(_ chat: ChatMeta?) -> some View {
        if let chat {
            if chat.kind == .group, let group = model.group(chat.groupId) {
                Button { model.summaryGroupId = group.id } label: { Label("Group Summary", systemImage: "doc.text") }
                    .help("Decisions, owners and open issues, kept by the lead")
                Button { SystemActions.reveal(model.groupStore.workspace(group.id)) } label: { Label("Project Folder", systemImage: "folder") }
                    .help("Show the group's shared project folder")
                Button {
                    model.selectedGroupId = group.id
                    model.section = .groups
                } label: { Label("Edit Group", systemImage: "slider.horizontal.3") }
                    .help("Members, lead, rules and hand-off limit")
            } else if let bot = model.bot(chat.botId) {
                Button { model.newChat(with: bot) } label: { Label("New Chat", systemImage: "square.and.pencil") }
                    .help("Start a fresh chat with \(bot.name)")
                Button { SystemActions.reveal(model.paths.botDir(bot.id)) } label: { Label("Show Folder", systemImage: "folder") }
                    .help("Show \(bot.name)'s folder in Finder")
                Button {
                    model.selectedBotId = bot.id
                    model.section = .bots
                } label: { Label("Edit Bot", systemImage: "slider.horizontal.3") }
                    .help("Edit \(bot.name)")
            }
            Button { model.teachSkill(from: chatId) } label: { Label("Teach a Skill", systemImage: "graduationcap") }
                .help("Turn what happened in this chat into a skill you can edit")
                .disabled(model.messages(for: chatId).isEmpty || model.isRunning(chatId))
        }
    }

    private func permissionSymbol(_ p: PermissionLevel) -> String {
        switch p {
        case .readOnly: return "eye"
        case .editWorkspace: return "pencil"
        case .fullAccess: return "bolt"
        }
    }
}

struct Pill: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Theme.raised, in: Capsule())
            .foregroundStyle(.secondary)
    }
}

struct MessagesList: View {
    @Environment(AppModel.self) private var model
    let chatId: String

    var body: some View {
        let messages = model.messages(for: chatId)
        let live = model.liveRuns(for: chatId)
        let liveLength = live.reduce(0) { $0 + $1.builder.message.text.count + $1.builder.message.steps.count }
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if messages.isEmpty && live.isEmpty {
                        WelcomeCard(chatId: chatId)
                    }
                    ForEach(messages) { message in
                        MessageRow(message: message, chatId: chatId)
                            .id(message.id)
                    }
                    ForEach(live) { run in
                        MessageRow(message: run.builder.message, chatId: chatId, activeStep: run.builder.activeStep)
                            .id(run.id)
                    }
                    if model.isRunning(chatId) && live.isEmpty {
                        TypingIndicator(label: "Passing it on…")
                            .padding(.leading, 40)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: messages.count) { scrollDown(proxy) }
            .onChange(of: liveLength) { scrollDown(proxy) }
        }
    }

    private func scrollDown(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }
}

struct WelcomeCard: View {
    @Environment(AppModel.self) private var model
    let chatId: String

    var body: some View {
        let chat = model.chat(chatId)
        let isGroup = chat?.kind == .group
        let group = model.group(chat?.groupId)
        let bot = model.bot(chat?.botId)
        let suggestions = isGroup
            ? ["Introduce yourselves: who does what?",
               "Build a habit tracker with Google sign-in and deploy it.",
               "What should we build first? Give me three ideas."]
            : ["Introduce yourself. What can you help me with?",
               "Look around your workspace and tell me what's there.",
               "Help me plan a small project."]
        VStack(spacing: 12) {
            if isGroup {
                GroupAvatar(group: group, size: 72)
            } else {
                AvatarView(bot: bot, size: 72)
            }
            Text(isGroup ? "Post a task to \(group?.displayName ?? "the group")" : "Say hi to \(bot?.name ?? "your bot")")
                .font(Theme.rounded(.title2, weight: .bold))
            Text(isGroup ? "\(model.bot(group?.lead)?.name ?? "The lead") replies first and hands work out by @mention." : (bot?.role ?? ""))
                .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        model.send(chatId: chatId, text: suggestion)
                    } label: {
                        Text(suggestion)
                            .frame(maxWidth: 400)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Theme.surface, in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.border))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

struct Composer: View {
    @Environment(AppModel.self) private var model
    let chatId: String
    @FocusState private var focused: Bool

    var body: some View {
        let running = model.isRunning(chatId)
        let draft = model.drafts[chatId] ?? ""
        let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let chat = model.chat(chatId)
        let isGroup = chat?.kind == .group
        let name = isGroup ? (model.group(chat?.groupId)?.displayName ?? "the group") : (model.bot(chat?.botId)?.name ?? "bot")
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField(
                    isGroup ? "Post a task to \(name)…" : "Message \(name)…",
                    text: Binding(get: { model.drafts[chatId] ?? "" }, set: { model.drafts[chatId] = $0 }),
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .lineLimit(1...10)
                .focused($focused)
                .onSubmit { model.send(chatId: chatId) }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(focused ? Theme.accent.opacity(0.6) : Theme.border)
                )

                if isGroup && !running {
                    Button {
                        model.askEveryone(chatId: chatId)
                    } label: {
                        Label("Ask everyone", systemImage: "person.3.sequence")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .background(Theme.raised, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(empty)
                    .help("Every member gives a short view on your message, then the lead sums up")
                }

                if running {
                    Button {
                        model.stop(chatId)
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 34, height: 34)
                            .background(Theme.failure, in: Circle())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help("Stop (Esc)")
                } else {
                    Button {
                        model.send(chatId: chatId)
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 34, height: 34)
                            .background(empty ? Color.gray.opacity(0.35) : Theme.accent, in: Circle())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(empty)
                    .help("Send (Return)")
                }
            }
            Text(running ? "\(name) \(isGroup ? "are" : "is") working. Press Esc to stop." : "Return to send · ⌥Return for a new line")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.leading, 14)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .onAppear { focused = true }
    }
}

// MARK: - Teach a skill

struct TeachSkillSheet: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""

    var body: some View {
        let teach = model.teach
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "graduationcap.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Teach a skill from this chat")
                        .font(Theme.rounded(.title3, weight: .bold))
                    Text("A SKILL.md draft of what happened here. Edit it, then save it to your library.")
                        .foregroundStyle(.secondary)
                }
            }
            switch teach?.phase {
            case .drafting:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Writing a draft…").foregroundStyle(.secondary)
                }
                ScrollView {
                    Text(teach?.draft ?? "")
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.warning)
                Spacer()
            case .ready:
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            case nil:
                Spacer()
            }
            HStack {
                Spacer()
                Button("Cancel") { model.cancelTeach() }
                    .keyboardShortcut(.cancelAction)
                Button("Save Skill") { model.saveTaughtSkill(text) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(teach?.phase != .ready || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 680, height: 600)
        .onChange(of: model.teach?.phase) {
            if model.teach?.phase == .ready { text = model.teach?.draft ?? "" }
        }
    }
}

struct GroupSummarySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let groupId: String

    var body: some View {
        let url = model.groupStore.summary(groupId)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? "No summary yet."
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                MarkdownView(text: text)
                    .padding(4)
            }
            HStack {
                Button("Open in Editor") { SystemActions.open(url) }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 560)
    }
}
#endif
