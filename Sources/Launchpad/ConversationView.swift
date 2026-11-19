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
            Rectangle().fill(Theme.line).frame(height: 1)
            PinnedBar(chatId: chatId)
            MessagesList(chatId: chatId)
            NeedsYouTray(chatId: chatId)
            Composer(chatId: chatId)
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(Theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .overlay(Label("Drop to attach", systemImage: "paperclip").font(.title3.weight(.semibold)).foregroundStyle(Theme.accentText))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: AttachmentIngest.types, isTargeted: $dropping) { providers in
            guard AttachmentIngest.accepts(providers) else { return false }
            Task { model.attach(await AttachmentIngest.urls(from: providers), to: chatId) }
            return true
        }
        .navigationTitle(model.chat(chatId)?.title ?? "Chat")
        .task(id: chatId) { model.loadMessagesIfNeeded(chatId) }
    }
}

struct ConversationHeader: View {
    @Environment(AppModel.self) private var model
    @AppStorage("ui.sidebarHidden") private var sidebarHidden = false
    let chatId: String
    var poppedOut = false

    var body: some View {
        let chat = model.chat(chatId)
        HStack(spacing: Theme.Space.m) {
            if chat?.kind == .group {
                groupInfo(model.group(chat?.groupId))
            } else {
                botInfo(model.bot(chat?.botId))
            }
            Spacer(minLength: Theme.Space.s)
            if sidebarHidden || poppedOut { WorkspaceChip(chatId: chatId) }
            if let usage = model.contextByChat[chatId] {
                HStack(spacing: 6) {
                    ContextChip(usage: usage)
                    if CompactionCenter.shared.compacting.contains(chatId) {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.small)
                            Text("Compacting…").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                        }
                    } else if usage.isNearlyFull {
                        Button("Compact") { model.compactChat(chatId, manual: true) }
                            .buttonStyle(SoftButtonStyle())
                            .controlSize(.small)
                            .disabled(model.isRunning(chatId))
                            .help("The bot's memory of this chat is nearly full. Compact summarises the older messages and keeps the latest; all of them stay on screen.")
                    }
                }
            }
            actions(chat)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
    }

    @ViewBuilder private func botInfo(_ bot: Bot?) -> some View {
        AvatarView(bot: bot, size: 40)
        VStack(alignment: .leading, spacing: 4) {
            Text(bot?.name ?? model.chat(chatId)?.title ?? "Chat")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            HStack(spacing: 6) {
                if let bot {
                    if model.isRunning(chatId) {
                        WorkingButton(chatId: chatId)
                    } else if !bot.role.isEmpty {
                        Text(bot.role).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                    Pill(text: bot.model.map { "\(bot.engine.displayName) · \($0)" } ?? bot.engine.displayName,
                         symbol: EngineStyle.symbol(bot.engine))
                    if bot.engine.isAgent {
                        Pill(text: bot.permission.displayName, symbol: permissionSymbol(bot.permission))
                    }
                } else {
                    Text("This chat's bot was removed.").foregroundStyle(Theme.secondary)
                }
            }
            .font(.system(size: 12))
        }
    }

    @ViewBuilder private func groupInfo(_ group: BotGroup?) -> some View {
        GroupAvatar(group: group, size: 40)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Theme.Space.s) {
                Text(group?.displayName ?? "Group")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if let group, model.approvalMode(for: group.id) == .fullFreedom {
                    Button { model.setApprovalMode(.ask, for: group, chatId: chatId) } label: {
                        Label(ApprovalMode.fullFreedom.title, systemImage: "bolt.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.warning)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Theme.warning.opacity(0.15)))
                            .overlay(Capsule().strokeBorder(Theme.warning.opacity(0.4), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("Bots in this group act without asking. Click to go back to Ask me.")
                }
            }
            if let group {
                HStack(spacing: Theme.Space.m) {
                    MembersButton(group: group, chatId: chatId)
                    if model.isRunning(chatId) {
                        WorkingButton(chatId: chatId)
                    }
                }
                .font(.system(size: 12))
            } else {
                Text("This group was removed.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        }
    }

    @ViewBuilder private func actions(_ chat: ChatMeta?) -> some View {
        if let chat {
            HStack(spacing: Theme.Space.s) {
                ThreadMenu(chatId: chatId)
                if chat.kind == .group, let group = model.group(chat.groupId) {
                    Button { model.summaryGroupId = group.id } label: { Label("Group Summary", systemImage: "doc.text") }
                        .buttonStyle(CircleButtonStyle())
                        .help("Decisions, owners and open issues, kept by the lead")
                } else if let bot = model.bot(chat.botId) {
                    Button { model.newChat(with: bot) } label: { Label("New Chat", systemImage: "square.and.pencil") }
                        .buttonStyle(CircleButtonStyle())
                        .help("Start a fresh chat with \(bot.name)")
                }
                CircleMenu(symbol: "ellipsis", help: "More") {
                    if chat.kind == .group, let group = model.group(chat.groupId) {
                        Button { SystemActions.reveal(model.groupStore.workspace(group.id)) } label: { Label("Project Folder", systemImage: "folder") }
                            .help("Show the group's shared project folder")
                        Button {
                            model.selectedGroupId = group.id
                            model.section = .groups
                        } label: { Label("Edit Group", systemImage: "slider.horizontal.3") }
                            .help("Members, lead and rules")
                        let next: ApprovalMode = model.approvalMode(for: group.id) == .fullFreedom ? .ask : .fullFreedom
                        Button { model.setApprovalMode(next, for: group, chatId: chatId) } label: {
                            Label("Switch to \(next.title)", systemImage: next == .fullFreedom ? "bolt.fill" : "hand.raised")
                        }
                        .help(next.detail)
                    } else if let bot = model.bot(chat.botId) {
                        Button { SystemActions.reveal(model.paths.botDir(bot.id)) } label: { Label("Show Folder", systemImage: "folder") }
                            .help("Show \(bot.name)'s folder in Finder")
                        Button {
                            model.selectedBotId = bot.id
                            model.section = .bots
                        } label: { Label("Edit Bot", systemImage: "slider.horizontal.3") }
                            .help("Edit \(bot.name)")
                    }
                    Button { model.teachSkill(from: chatId) } label: { Label("Save as Skill", systemImage: "graduationcap") }
                        .help("Have a bot write up what happened in this chat as a skill you can use again with /name")
                        .disabled(model.messages(for: chatId).isEmpty || model.isRunning(chatId))
                    Button { model.exportChat(chatId) } label: { Label("Export", systemImage: "square.and.arrow.up") }
                        .help("Save this chat as a Markdown file")
                        .disabled(model.messages(for: chatId).isEmpty)
                    if !poppedOut {
                        OpenInWindowButton(chatId: chatId)
                    }
                }
                let canTeach = !(model.messages(for: chatId).isEmpty || model.isRunning(chatId))
                ViewThatFits(in: .horizontal) {
                    Button { model.teachSkill(from: chatId) } label: { Label("Save as Skill", systemImage: "graduationcap") }
                        .buttonStyle(PillButtonStyle())
                        .fixedSize()
                    Button { model.teachSkill(from: chatId) } label: { Label("Save as Skill", systemImage: "graduationcap") }
                        .buttonStyle(CircleButtonStyle(kind: .accent))
                }
                .help("Turn what happened in this chat into a skill you can edit")
                .disabled(!canTeach)
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

/// A small outlined chip, e.g. "Claude Code · sonnet".
struct Pill: View {
    let text: String
    let symbol: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            Text(text).lineLimit(1)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(Theme.field))
        .overlay(Capsule().strokeBorder(Theme.line))
        .fixedSize()
    }
}

/// "working" with a green dot.
struct WorkingStatus: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Theme.successFill).frame(width: 7, height: 7)
            Text("working").fontWeight(.medium)
        }
        .foregroundStyle(Theme.success)
        .fixedSize()
    }
}

/// The context ring with its percentage, as a chip.
struct ContextChip: View {
    let usage: ContextUsage

    var body: some View {
        HStack(spacing: 6) {
            ContextRing(usage: usage)
            Text("\(Int((usage.fraction * 100).rounded()))% context")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(usage.isNearlyFull ? Theme.warning : Theme.text)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Capsule().fill(Theme.field))
        .overlay(Capsule().strokeBorder(Theme.line))
        .fixedSize()
    }
}

/// How far the bottom of the chat is from the bottom of the window (lazy rows off screen report "far").
private struct ChatBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct MessagesList: View {
    @Environment(AppModel.self) private var model
    let chatId: String
    @State private var highlighted: String?
    /// Following new messages only while you're at (or near) the bottom; scrolled up, it stays put.
    @State private var atBottom = true
    @State private var viewport: CGFloat = 0
    @State private var unseen = false

    var body: some View {
        let messages = model.messages(for: chatId)
        let live = model.liveRuns(for: chatId)
        // Messages a compaction summarised stay on screen, dimmed, with a line after the last of them.
        let compaction = ChatCompaction.applicable(CompactionCenter.shared.records[chatId], to: messages)
        let summarized: Set<String> = compaction.flatMap { record in
            messages.firstIndex { $0.id == record.throughMessageId }.map { Set(messages[...$0].map(\.id)) }
        } ?? []
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
                            .opacity(summarized.contains(message.id) ? 0.62 : 1)
                            .background(highlighted == message.id ? Theme.accent.opacity(0.12) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
                        if let record = compaction, message.id == record.throughMessageId {
                            SummaryDivider(record: record)
                        }
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
                            .foregroundStyle(Theme.secondary)
                            .padding(.leading, 40)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                        .background(GeometryReader { g in
                            Color.clear.preference(key: ChatBottomKey.self, value: g.frame(in: .named("chatScroll")).maxY)
                        })
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .coordinateSpace(name: "chatScroll")
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { viewport = g.size.height }
                    .onChange(of: g.size.height) { viewport = g.size.height }
            })
            .onPreferenceChange(ChatBottomKey.self) { bottom in
                let near = bottom <= viewport + 120
                if near != atBottom { atBottom = near }
                if near { unseen = false }
            }
            .overlay(alignment: .bottom) {
                if unseen && !atBottom {
                    Button {
                        unseen = false
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    } label: {
                        Label("New messages", systemImage: "arrow.down")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(Capsule().fill(Theme.accentStrong))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onAppear {
                if !jumpIfAsked(proxy) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: messages.count) {
                // Your own message always takes you down; anything else only if you were already at the bottom.
                scrollDown(proxy, force: messages.last?.role == .user)
            }
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

    private func scrollDown(_ proxy: ScrollViewProxy, force: Bool = false) {
        guard atBottom || force else {
            unseen = true
            return
        }
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
                .foregroundStyle(Theme.text)
            Text(isGroup ? "\(model.bot(group?.lead)?.name ?? "The lead") replies first and hands work out by @mention." : (bot?.role ?? ""))
                .foregroundStyle(Theme.secondary)
            VStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        model.send(chatId: chatId, text: suggestion)
                    } label: {
                        Text(suggestion)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.text)
                            .frame(maxWidth: 400)
                            .padding(.horizontal, Theme.Space.l)
                            .padding(.vertical, 10)
                            .background(Theme.card, in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.line))
                            .contentShape(Capsule())
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
    @State private var mentionSelection = 0
    /// The draft as it was when Esc closed the mention list; the list stays closed until the draft changes.
    @State private var mentionDismissed: String?

    /// Group members that match the @handle being typed; empty when the mention list is closed.
    private var mentionMatches: [Bot] {
        let draft = model.drafts[chatId] ?? ""
        guard let chat = model.chat(chatId), chat.kind == .group, let group = model.group(chat.groupId),
              draft != mentionDismissed, let query = MentionPicker.query(in: draft) else { return [] }
        return MentionPicker.candidates(for: query, among: group.everyone.compactMap { model.bot($0) })
    }

    /// Skills that match the "/name" being typed; empty when the skill list is closed.
    private var skillMatches: [Skill] {
        let draft = model.drafts[chatId] ?? ""
        guard draft != mentionDismissed, let query = SkillCommand.query(in: draft) else { return [] }
        return SkillCommand.candidates(for: query, among: model.skills)
    }

    // The @ list and the / list are never open together, so they share the selection and the keys.
    private func moveMention(_ step: Int) -> KeyPress.Result {
        let count = mentionMatches.count + skillMatches.count
        guard count > 0 else { return .ignored }
        mentionSelection = (min(mentionSelection, count - 1) + step + count) % count
        return .handled
    }

    /// Writes the selected (or clicked) bot's tag into the draft. False when the list is closed.
    @discardableResult private func pickMention(_ bot: Bot? = nil) -> Bool {
        let skills = skillMatches
        if bot == nil, !skills.isEmpty { return pickSkill(skills[min(mentionSelection, skills.count - 1)]) }
        let matches = mentionMatches
        guard let bot = bot ?? (matches.isEmpty ? nil : matches[min(mentionSelection, matches.count - 1)]) else { return false }
        model.drafts[chatId] = MentionPicker.insert(bot.id, into: model.drafts[chatId] ?? "")
        focused = true
        return true
    }

    /// Writes "/name " into the draft, ready for the request.
    @discardableResult private func pickSkill(_ skill: Skill) -> Bool {
        model.drafts[chatId] = SkillCommand.insert(skill.id, into: model.drafts[chatId] ?? "")
        focused = true
        return true
    }

    private func closeMentions() -> KeyPress.Result {
        guard !mentionMatches.isEmpty || !skillMatches.isEmpty else { return .ignored }
        mentionDismissed = model.drafts[chatId] ?? ""
        return .handled
    }

    var body: some View {
        let running = model.isRunning(chatId)
        let draft = model.drafts[chatId] ?? ""
        let mentions = mentionMatches
        let skills = skillMatches
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
                                    .foregroundStyle(Theme.secondary)
                            }
                            .font(.callout)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Theme.field, in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.line))
                        }
                    }
                }
                .padding(.leading, 48)
            }
            if !mentions.isEmpty {
                MentionList(bots: mentions, selection: min(mentionSelection, mentions.count - 1)) { pickMention($0) }
                    .padding(.leading, 48)
            }
            if !skills.isEmpty {
                SkillCommandList(skills: skills, selection: min(mentionSelection, skills.count - 1)) { pickSkill($0) }
                    .padding(.leading, 48)
            }
            HStack(alignment: .bottom, spacing: Theme.Space.s) {
                CircleMenu(symbol: "plus", help: "Attach files, send a GIF, start a poll, ask on the side, or use a saved prompt", size: 40) {
                    Button("Attach Files…") { model.chooseAttachments(for: chatId) }
                    Button("Send a GIF…") { showingGifs = true }
                    Button("Start a Poll…") { showingPoll = true }
                    if !isGroup {
                        Button("Ask on the Side…") { asking = true }
                    }
                    Divider()
                    SavedPromptsMenu(chatId: chatId)
                }
                .popover(isPresented: $showingGifs) { GifPicker(chatId: chatId) }
                .sheet(isPresented: $showingPoll) { NewPollSheet(chatId: chatId) }

                GrowingScroll(maxHeight: 200) {
                    TextField(
                        running && !isGroup ? "Tell \(name) something new: it stops and carries on with it…"
                            : (running ? "Working… Return queues it · ⌘Return steers now"
                               : (isGroup ? "Post a task to \(name)…" : "Message \(name)…")),
                        text: Binding(get: { model.drafts[chatId] ?? "" }, set: { model.drafts[chatId] = $0 }),
                        axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { if !pickMention() { model.send(chatId: chatId) } }
                    .onKeyPress(.downArrow) { moveMention(1) }
                    .onKeyPress(.upArrow) { moveMention(-1) }
                    .onKeyPress(.return, phases: .down) { press in
                        // Shift+Return is a new line (at the cursor); plain Return picks a mention or sends.
                        if press.modifiers.contains(.command), isGroup, running, !empty {
                            model.send(chatId: chatId, steerNow: true)
                            return .handled
                        }
                        if press.modifiers.contains(.shift) {
                            if !NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil) {
                                model.drafts[chatId, default: ""] += "\n"
                            }
                            return .handled
                        }
                        return pickMention() ? .handled : .ignored
                    }
                    .onPasteCommand(of: AttachmentIngest.types) { providers in
                        let board = NSPasteboard.general
                        let hasFiles = board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
                        // Text that merely came with an image (copied from a web page) is still pasted as text.
                        if !hasFiles, let text = board.string(forType: .string), !text.isEmpty {
                            (NSApp.keyWindow?.firstResponder as? NSTextView)?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
                            return
                        }
                        Task { model.attach(await AttachmentIngest.urls(from: providers), to: chatId) }
                    }
                    .onKeyPress(.tab) { pickMention() ? .handled : .ignored }
                    .onKeyPress(.escape) { closeMentions() }
                }
                .onChange(of: draft) {
                    mentionSelection = 0
                    if draft != mentionDismissed { mentionDismissed = nil }
                }
                .font(.system(size: 14))
                .padding(.vertical, 11)
                .padding(.horizontal, Theme.Space.l)
                .frame(minHeight: 40)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(focused ? Theme.accent.opacity(0.6) : Theme.line, lineWidth: focused ? 1.5 : 1)
                )

                if isGroup && !running {
                    Button {
                        model.askEveryone(chatId: chatId)
                    } label: {
                        Label("Huddle", systemImage: "person.3.sequence")
                    }
                    .buttonStyle(SoftButtonStyle())
                    .controlSize(.large)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("A huddle: every member gives a short view on your message, then the lead sums up")
                }

                if running {
                    Button {
                        model.stop(chatId)
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(CircleButtonStyle(kind: .destructive, size: 40))
                    .keyboardShortcut(.cancelAction)
                    .help("Stop (Esc)")
                }
                Button {
                    model.send(chatId: chatId)
                } label: {
                    Label("Send", systemImage: "arrow.up")
                }
                .buttonStyle(CircleButtonStyle(kind: .accent, size: 40))
                .disabled(empty)
                .help(running ? (isGroup ? "Send: the group picks it up when it's free" : "Send: \(name) stops and carries on with your new message") : "Send (Return)")
            }
            if running && isGroup {
                Button { model.send(chatId: chatId, steerNow: true) } label: { Label("Steer now", systemImage: "arrow.turn.down.right") }
                    .buttonStyle(PillButtonStyle(kind: .soft))
                    .controlSize(.small)
                    .disabled(empty)
                    .help("Stops the step that's running (its work so far is kept) so the bot you @mention, or the lead, answers this straight away. Every engine is stopped the same way (the step is cancelled and the bot reads the chat again), so it works for Claude, Codex and local bots alike.")
                    .padding(.leading, 56)
            }
            Text(running
                 ? (isGroup ? "\(name) are working. Return queues your message for their next turn; Steer now (⌘Return) stops the current step and gets it answered straight away. Esc stops."
                            : "\(name) is working. Writing now steers it; Esc stops.")
                 : "Return to send · ⌥Return for a new line · / to use a skill · drop files to attach")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
                .padding(.leading, 56)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.s)
        .padding(.bottom, Theme.Space.m)
        .onAppear { focused = true }
    }
}

/// The group's bots that match the @handle being typed, shown above the composer.
struct MentionList: View {
    let bots: [Bot]
    let selection: Int
    let pick: (Bot) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(bots.enumerated()), id: \.element.id) { i, bot in
                Button { pick(bot) } label: {
                    HStack(spacing: Theme.Space.s) {
                        AvatarView(bot: bot, size: 24)
                        Text(bot.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        if !bot.role.isEmpty {
                            Text(bot.role).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                        }
                        Spacer(minLength: Theme.Space.s)
                        Text("@\(bot.id)").font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                    .padding(.horizontal, Theme.Space.s)
                    .padding(.vertical, 5)
                    .background(
                        i == selection ? Theme.accentSoft : Color.clear,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Mention \(bot.name)")
                .accessibilityAddTraits(i == selection ? .isSelected : [])
            }
        }
        .padding(6)
        .frame(maxWidth: 420)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
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
            Image(systemName: "bubble.left.and.text.bubble.right").foregroundStyle(Theme.accentText)
            TextField("Ask \(name) on the side (it keeps working on the main task)…", text: $text)
                .textFieldStyle(PillFieldStyle())
                .onSubmit(ask)
                .disabled(busy)
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Button("Ask", action: ask)
                    .buttonStyle(SoftButtonStyle())
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            CircleIconButton(symbol: "xmark", help: "Close", size: 28) { close() }
        }
        .padding(.leading, 48)
    }

    private func ask() {
        model.askSide(text, in: chatId)
        text = ""
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
        .padding(Theme.Space.xl)
        .frame(width: 620, height: 560)
        .sheetBackground()
    }
}
#endif
