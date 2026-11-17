#if os(macOS)
import SwiftUI
import LaunchpadCore

struct ConversationView: View {
    @Environment(AppModel.self) private var model
    let chatId: String
    /// Shown in its own window (no "Open in New Window" button).
    var poppedOut = false
    @State private var dropping = false

    var body: some View {
        VStack(spacing: 0) {
            ConversationHeader(chatId: chatId, poppedOut: poppedOut)
            Divider()
            PinnedBar(chatId: chatId)
            MessagesList(chatId: chatId)
            Composer(chatId: chatId)
        }
        .background(Theme.canvas)
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(Theme.accent.opacity(0.06))
                    .overlay(Label("Drop to attach", systemImage: "paperclip").font(.title3).foregroundStyle(Theme.accent))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            model.attach(files, to: chatId)
            return !files.isEmpty
        } isTargeted: { dropping = $0 }
        .navigationTitle(model.chat(chatId)?.title ?? "Chat")
        .task(id: chatId) { model.loadMessagesIfNeeded(chatId) }
    }
}

struct ConversationHeader: View {
    @Environment(AppModel.self) private var model
    let chatId: String
    var poppedOut = false

    var body: some View {
        let chat = model.chat(chatId)
        HStack(spacing: 12) {
            if chat?.kind == .group {
                groupInfo(model.group(chat?.groupId))
            } else {
                botInfo(model.bot(chat?.botId))
            }
            Spacer()
            if let usage = model.contextByChat[chatId] {
                HStack(spacing: 6) {
                    ContextRing(usage: usage)
                    if usage.isNearlyFull {
                        Button("Compact") { model.compact(chatId) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(model.isRunning(chatId))
                            .help("The bot's memory of this chat is nearly full. Compact keeps the messages and starts it from a recap.")
                    }
                }
            }
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
                    Pill(text: bot.model.map { "\(bot.engine.displayName) · \($0)" } ?? bot.engine.displayName,
                         symbol: EngineStyle.symbol(bot.engine))
                    if bot.engine.isAgent {
                        Pill(text: bot.permission.displayName, symbol: permissionSymbol(bot.permission))
                    }
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
            ThreadMenu(chatId: chatId)
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
            Button { model.exportChat(chatId) } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .help("Save this chat as a Markdown file")
                .disabled(model.messages(for: chatId).isEmpty)
            if !poppedOut {
                OpenInWindowButton(chatId: chatId)
            }
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

enum EngineStyle {
    static func symbol(_ engine: BotEngine) -> String {
        switch engine {
        case .claude: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .local: return "desktopcomputer"
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
    @State private var highlighted: String?

    var body: some View {
        let messages = model.messages(for: chatId)
        let live = model.liveRuns(for: chatId)
        let liveLength = live.reduce(0) { $0 + $1.builder.message.text.count + $1.builder.message.steps.count + $1.approvals.count + $1.builder.todos.count }
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if messages.isEmpty && live.isEmpty {
                        WelcomeCard(chatId: chatId)
                    }
                    ForEach(messages) { message in
                        MessageRow(message: message, chatId: chatId)
                            .id(message.id)
                            .background(highlighted == message.id ? Theme.accent.opacity(0.12) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 18))
                    }
                    ForEach(live) { run in
                        MessageRow(message: run.message, chatId: chatId, activeStep: run.builder.activeStep, isLive: true)
                            .id(run.id)
                    }
                    if let botId = model.typing[chatId] {
                        HStack(spacing: 10) {
                            AvatarView(bot: model.bot(botId), size: 30)
                            TypingIndicator(label: nil)
                        }
                    } else if model.isRunning(chatId) && !live.contains(where: { !$0.isSide }) {
                        TypingIndicator(label: "Passing it on…")
                            .padding(.leading, 40)
                    }
                    if let waiting = model.queues[chatId]?.waiting, !waiting.isEmpty {
                        Label(waiting.count == 1 ? "Your message is next." : "\(waiting.count) messages are next.",
                              systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
            .onAppear {
                if !jumpIfAsked(proxy) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: messages.count) { scrollDown(proxy) }
            .onChange(of: liveLength) { scrollDown(proxy) }
            .onChange(of: model.jump) { _ = jumpIfAsked(proxy) }
        }
    }

    /// Scrolls to the message asked for (pinned bar, saved messages, ⌘K) and highlights it for a moment.
    private func jumpIfAsked(_ proxy: ScrollViewProxy) -> Bool {
        guard let jump = model.jump, jump.chatId == chatId else { return false }
        model.jump = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation { proxy.scrollTo(jump.messageId, anchor: .center) }
            highlighted = jump.messageId
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { if highlighted == jump.messageId { highlighted = nil } }
        }
        return true
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
    @State private var showingGifs = false
    @State private var showingPoll = false
    @State private var asking = false
    @State private var sideText = ""

    var body: some View {
        let running = model.isRunning(chatId)
        let draft = model.drafts[chatId] ?? ""
        let files = model.pendingAttachments[chatId] ?? []
        let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty
        let chat = model.chat(chatId)
        let isGroup = chat?.kind == .group
        let bot = model.bot(chat?.botId)
        let name = isGroup ? (model.group(chat?.groupId)?.displayName ?? "the group") : (bot?.name ?? "bot")
        let canSide = !isGroup && bot != nil
        VStack(alignment: .leading, spacing: 6) {
            if asking && canSide {
                SideQuestionBar(chatId: chatId, name: name, text: $sideText) { asking = false }
            }
            if !files.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(files, id: \.self) { url in
                            HStack(spacing: 4) {
                                Image(systemName: FileMentions.icon(for: url))
                                Text(url.lastPathComponent).lineLimit(1)
                                Button { model.removeAttachment(url, from: chatId) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.callout)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Theme.raised, in: Capsule())
                        }
                    }
                }
                .padding(.leading, 14)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button("Attach Files…") { model.chooseAttachments(for: chatId) }
                    Button("Send a GIF…") { showingGifs = true }
                    Button("Start a Poll…") { showingPoll = true }
                    if !isGroup {
                        Button("Ask on the Side…") { asking = true }
                    }
                    Divider()
                    SavedPromptsMenu(chatId: chatId)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 34)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Attach files, send a GIF, start a poll, ask on the side, or use a saved prompt")
                .popover(isPresented: $showingGifs) { GifPicker(chatId: chatId) }
                .sheet(isPresented: $showingPoll) { NewPollSheet(chatId: chatId) }

                TextField(
                    running && !isGroup ? "Tell \(name) something new: it stops and carries on with it…"
                        : (isGroup ? "Post a task to \(name)…" : "Message \(name)…"),
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
                        Label("Huddle", systemImage: "person.3.sequence")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .background(Theme.raised, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("A huddle: every member gives a short view on your message, then the lead sums up")
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
                }
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
                .help(running ? (isGroup ? "Send: the group picks it up when it's free" : "Send: \(name) stops and carries on with your new message") : "Send (Return)")
            }
            Text(running
                 ? (isGroup ? "\(name) are working. You can still write; they pick it up next. Esc stops."
                            : "\(name) is working. Writing now steers it; Esc stops.")
                 : "Return to send · ⌥Return for a new line · drop files to attach")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.leading, 52)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .onAppear { focused = true }
    }
}

/// Saved prompts, one click from the composer.
struct SavedPromptsMenu: View {
    @Environment(AppModel.self) private var model
    let chatId: String

    var body: some View {
        let draft = (model.drafts[chatId] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        Menu("Saved Prompts") {
            ForEach(model.savedPrompts, id: \.self) { p in
                Button(SavedPromptsStore.label(p)) { model.drafts[chatId] = p }
            }
            if !model.savedPrompts.isEmpty { Divider() }
            Button("Save What I've Typed") { model.addSavedPrompt(draft) }
                .disabled(draft.isEmpty)
            if !model.savedPrompts.isEmpty {
                Menu("Remove") {
                    ForEach(model.savedPrompts, id: \.self) { p in
                        Button(SavedPromptsStore.label(p)) { model.removeSavedPrompt(p) }
                    }
                }
            }
        }
    }
}

/// A quick question for the bot that doesn't stop or steer what it's doing.
struct SideQuestionBar: View {
    @Environment(AppModel.self) private var model
    let chatId: String
    let name: String
    @Binding var text: String
    let close: () -> Void

    var body: some View {
        let busy = model.isAskingSide(chatId)
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right").foregroundStyle(Theme.accent)
            TextField("Ask \(name) on the side (it keeps working on the main task)…", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(ask)
                .disabled(busy)
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Button("Ask", action: ask)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Button { close() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Close")
        }
        .padding(.leading, 14)
    }

    private func ask() {
        model.askSide(text, in: chatId)
        text = ""
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
