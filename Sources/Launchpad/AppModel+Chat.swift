#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LaunchpadCore

/// The Keychain account for a local model server's API key (most don't need one).
enum LocalModelKey {
    static let account = "local-model-api-key"
}

// MARK: - Chat tools during a run

extension AppModel {
    /// New actions from the bot's chat tools, applied to its live reply. Also starts a plan whose countdown ran out.
    func pollChatActions(_ reader: ChatActionReader, chatId: String, runId: String, botId: String, messageId: String) {
        let actions = reader.readNew()
        guard let current = live[chatId]?.first(where: { $0.id == runId })?.extras else { return }
        var extras = actions.isEmpty ? current
            : applyChatActions(actions, extras: current, chatId: chatId, botId: botId, runId: runId, messageId: messageId)
        if let plan = extras.plan, plan.isDue(now: Date()) { extras.plan?.state = .started }
        if extras != current, let i = live[chatId]?.firstIndex(where: { $0.id == runId }) {
            live[chatId]?[i].extras = extras
        }
        // A question or a plan now waits on you: tell you if Launchpad is in the background.
        let name = bot(botId)?.name ?? "A bot"
        if let q = extras.questions, !q.answered, current.questions == nil {
            notifyNeedsYou(ReplyNotice(title: "\(name) needs you", body: q.items.first?.text ?? "Asked you a question", needsYou: true), chatId: chatId)
        }
        if let p = extras.plan, p.state == .waiting, current.plan == nil {
            notifyNeedsYou(ReplyNotice(title: "\(name) has a plan", body: p.message, needsYou: true), chatId: chatId)
        }
    }

    /// Applies chat actions: reactions and votes on earlier messages, GIF searches, routines. Returns the reply's
    /// cards and media.
    func applyChatActions(_ actions: [ChatAction], extras: ChatReplyExtras, chatId: String, botId: String,
                          runId: String, messageId: String) -> ChatReplyExtras {
        guard !actions.isEmpty else { return extras }
        let result = ChatActionApplier.apply(actions, extras: extras, history: messages(for: chatId), botId: botId,
                                             planWait: planWait)
        for m in result.changed { replace(m, in: chatId) }
        for query in result.gifSearches {
            let secrets = self.secrets
            Task { @MainActor [weak self] in
                guard let gif = await GiphySearch.search(query, secrets: secrets, limit: 1).first?.gif else { return }
                self?.attachGif(gif, chatId: chatId, runId: runId, messageId: messageId)
            }
        }
        for request in result.routines { saveBotRoutine(request, chatId: chatId) }
        if result.questionsShown { activity.record(.asked, bot: botId, chat: chatId, "Asked you a question") }
        return result.extras
    }

    private func attachGif(_ gif: GifRef, chatId: String, runId: String, messageId: String) {
        if let i = live[chatId]?.firstIndex(where: { $0.id == runId }) {
            live[chatId]?[i].extras.gif = gif
        } else {
            changeMessage(messageId, in: chatId) { m in
                var out = m
                out.gif = gif
                return out
            }
        }
    }

    /// A routine a bot set up with create_routine: saved for this chat's bot or group, with a notice.
    private func saveBotRoutine(_ request: RoutineRequest, chatId: String) {
        guard let meta = chat(chatId) else { return }
        switch ChatActionApplier.saveRoutine(request, chat: meta, store: routineStore, bots: Set(bots.map(\.id)),
                                             groups: Set(groups.map(\.id))) {
        case .success(let saved):
            reloadRoutines()
            if saved.routine.watchedFolder != nil { folderTriggers.prime([saved.routine]) }
            syncWebhookListener()
            append(ChatMessage(role: .notice, text: saved.notice), to: chatId)
        case .failure(let error):
            append(ChatMessage(role: .notice, text: "Couldn't set up that routine: \(error.localizedDescription)"), to: chatId)
        }
    }

    // MARK: Messages

    /// Puts a changed copy of a message in the chat and saves it (the latest line with an id wins).
    func replace(_ message: ChatMessage, in chatId: String) {
        loadMessagesIfNeeded(chatId)
        guard let i = messages[chatId]?.firstIndex(where: { $0.id == message.id }) else { return }
        messages[chatId]?[i] = message
        do {
            try chatStore.append(message, chatId: chatId)
        } catch {
            alertMessage = "Couldn't save the chat history: \(error.localizedDescription)"
        }
    }

    /// Changes one saved message. `change` returns nil for "no change".
    func changeMessage(_ id: String, in chatId: String, _ change: (ChatMessage) -> ChatMessage?) {
        loadMessagesIfNeeded(chatId)
        guard let m = messages[chatId]?.first(where: { $0.id == id }), let changed = change(m), changed != m else { return }
        replace(changed, in: chatId)
    }

    func message(_ id: String, in chatId: String) -> ChatMessage? {
        messages[chatId]?.first { $0.id == id }
    }

    /// "You" or the bot's name, for exports, forwards and reviews.
    func authorName(_ m: ChatMessage) -> String {
        switch m.role {
        case .user: return "You"
        case .notice: return "Note"
        case .bot: return bot(m.botId)?.name ?? "Bot"
        }
    }

    func toggleReaction(_ emoji: String, on id: String, in chatId: String) {
        changeMessage(id, in: chatId) { ChatOps.toggleReaction($0, emoji: emoji) }
    }

    func togglePin(_ id: String, in chatId: String) {
        changeMessage(id, in: chatId) { ChatOps.togglePin($0) }
    }

    func toggleSave(_ id: String, in chatId: String) {
        changeMessage(id, in: chatId) { ChatOps.toggleSave($0) }
    }

    func editMessage(_ id: String, in chatId: String, to text: String) {
        changeMessage(id, in: chatId) { ChatOps.edit($0, to: text) }
    }

    func deleteMessage(_ id: String, in chatId: String) {
        changeMessage(id, in: chatId) { ChatOps.delete($0) }
    }

    /// Sends a copy of a message to another chat, from you, and gets that chat's bot or group to look at it.
    func forward(_ id: String, from chatId: String, to target: String) {
        guard let m = message(id, in: chatId) else { return }
        let from = m.role == .user ? "me" : authorName(m)
        guard let copy = ChatOps.forward(m, fromName: from) else { return }
        submit(copy, prompt: ChatOps.forwardPrompt(copy), to: target)
        show(chat: target)
    }

    /// Ask another bot to review a reply, in the same chat. The answer stays with you.
    func askForReview(_ id: String, in chatId: String, reviewer reviewerId: String) {
        guard let m = message(id, in: chatId), let reviewer = bot(reviewerId) else { return }
        guard !isRunning(chatId) else {
            alertMessage = "Wait until this chat's reply has finished, then ask for a review."
            return
        }
        let author = authorName(m)
        append(ChatMessage(role: .notice, text: ReviewRequest.notice(reviewerName: reviewer.name, authorName: author)), to: chatId)
        startSolo(chatId, bot: reviewer, prompt: ReviewRequest.prompt(authorName: author, text: ChatOps.contextText(m)), handOffs: false)
    }

    /// Scrolls a chat to a message (opening the chat first).
    func jump(to messageId: String, in chatId: String) {
        show(chat: chatId)
        loadMessagesIfNeeded(chatId)
        jump = JumpRequest(chatId: chatId, messageId: messageId)
    }

    func savedMessages() -> [(chatId: String, message: ChatMessage)] {
        chatStore.savedMessages(chatIds: chats.map(\.id))
    }

    // MARK: Cards

    /// Start / Cancel on a plan card. A live plan is answered through the waiting chat tool; one whose reply has
    /// ended is marked, and Start asks the bot to go ahead.
    func answerPlan(_ messageId: String, in chatId: String, start: Bool) {
        if let i = live[chatId]?.firstIndex(where: { $0.builder.message.id == messageId }),
           let plan = live[chatId]?[i].extras.plan, let answered = ChatOps.answerPlan(plan, start: start) {
            live[chatId]?[i].extras.plan = answered
            do {
                try live[chatId]?[i].tools?.answerPlan(start ? "start" : "cancel")
            } catch {
                alertMessage = "Couldn't pass on your answer: \(error.localizedDescription)"
            }
            return
        }
        guard let plan = message(messageId, in: chatId)?.plan, let answered = ChatOps.answerPlan(plan, start: start) else { return }
        changeMessage(messageId, in: chatId) { m in
            var out = m
            out.plan = answered
            return out
        }
        if start {
            let text = "Go ahead with the plan."
            submit(ChatMessage(role: .user, text: text), prompt: text, to: chatId)
        }
    }

    /// Your answers to a question card go back to the bot as your next message.
    func answerQuestions(_ messageId: String, in chatId: String, answers: [String]) {
        let liveIndex = live[chatId]?.firstIndex { $0.builder.message.id == messageId }
        let card = liveIndex.flatMap { live[chatId]?[$0].extras.questions } ?? message(messageId, in: chatId)?.questions
        guard let card, let meta = chat(chatId) else { return }
        let asker = liveIndex.flatMap { live[chatId]?[$0].botId } ?? message(messageId, in: chatId)?.botId
        guard let result = ChatOps.answer(card, with: answers, mention: meta.kind == .group ? asker : nil) else { return }
        if let i = liveIndex {
            live[chatId]?[i].extras.questions = result.card
        } else {
            changeMessage(messageId, in: chatId) { m in
                var out = m
                out.questions = result.card
                return out
            }
        }
        submit(ChatMessage(role: .user, text: result.prompt), prompt: result.prompt, to: chatId)
    }

    /// Your vote in a poll. Voting in a bot's poll tells the bot (when it isn't busy).
    func vote(_ messageId: String, in chatId: String, option: Int) {
        guard let m = message(messageId, in: chatId), let poll = m.poll,
              let voted = ChatOps.vote(poll, by: ChatOps.you, option: option) else { return }
        changeMessage(messageId, in: chatId) { m in
            var out = m
            out.poll = voted
            return out
        }
        if m.role == .bot, !isRunning(chatId), let prompt = ChatOps.youVotedPrompt(voted, option: option) {
            submit(ChatMessage(role: .user, text: prompt), prompt: prompt, to: chatId)
        }
    }

    /// A poll you start: the bots are asked to vote.
    func startPoll(in chatId: String, question: String, options: [String]) {
        guard let poll = ChatOps.makePoll(question: question, options: options) else { return }
        var m = ChatMessage(role: .user, text: "")
        m.poll = poll
        submit(m, prompt: ChatOps.askToVotePrompt(poll), to: chatId)
    }

    func sendGif(_ gif: GifRef, in chatId: String) {
        var m = ChatMessage(role: .user, text: "")
        m.gif = gif
        submit(m, prompt: ChatOps.contextText(m), to: chatId)
    }

    var hasGiphyKey: Bool { GiphySearch.key(from: secrets) != nil }

    func searchGifs(_ query: String) async -> [GiphySearch.Result] {
        await GiphySearch.search(query, secrets: secrets)
    }

    // MARK: Attachments, export, saved prompts

    func attach(_ urls: [URL], to chatId: String) {
        let files = urls.filter { url in
            var dir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && !dir.boolValue
        }
        guard !files.isEmpty else { return }
        var list = pendingAttachments[chatId] ?? []
        for f in files where !list.contains(f) { list.append(f) }
        pendingAttachments[chatId] = list
    }

    func chooseAttachments(for chatId: String) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        attach(panel.urls, to: chatId)
    }

    func removeAttachment(_ url: URL, from chatId: String) {
        pendingAttachments[chatId]?.removeAll { $0 == url }
        if pendingAttachments[chatId]?.isEmpty == true { pendingAttachments[chatId] = nil }
    }

    /// Saves the chat as a Markdown file you pick.
    func exportChat(_ chatId: String) {
        guard let meta = chat(chatId) else { return }
        loadMessagesIfNeeded(chatId)
        let text = ChatExport.markdown(title: meta.title, messages: messages(for: chatId)) { [self] m in authorName(m) }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ChatExport.fileName(for: meta.title)
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            alertMessage = "Couldn't save the chat: \(error.localizedDescription)"
        }
    }

    func addSavedPrompt(_ text: String) {
        do { savedPrompts = try savedPromptsStore.add(text) } catch { alertMessage = "Couldn't save the prompt: \(error.localizedDescription)" }
    }

    func removeSavedPrompt(_ text: String) {
        do { savedPrompts = try savedPromptsStore.remove(text) } catch { alertMessage = "Couldn't remove the prompt: \(error.localizedDescription)" }
    }

    // MARK: Quick switcher (⌘K)

    func switcherItems() -> [SwitcherItem] {
        var items: [SwitcherItem] = chats.map {
            SwitcherItem(id: "chat:\($0.id)", kind: .chat, title: $0.title, detail: $0.lastPreview ?? "", chatId: $0.id, date: $0.updatedAt)
        }
        items += bots.map { SwitcherItem(id: "bot:\($0.id)", kind: .bot, title: $0.name, detail: $0.role) }
        items += groups.map { SwitcherItem(id: "group:\($0.id)", kind: .group, title: $0.displayName, detail: $0.rules) }
        items += SidebarSection.allCases.map { SwitcherItem(id: "page:\($0.rawValue)", kind: .page, title: $0.title, detail: $0.blurb) }
        items += [
            SwitcherItem(id: "action:newBot", kind: .action, title: "New bot", detail: "Create a bot"),
            SwitcherItem(id: "action:newGroup", kind: .action, title: "New group", detail: "Put bots together with a lead"),
            SwitcherItem(id: "action:saved", kind: .action, title: "Saved messages", detail: "Messages you saved for later"),
        ]
        return items
    }

    /// Every chat with its messages, for searching message text.
    func switcherChats() -> [(meta: ChatMeta, messages: [ChatMessage])] {
        chats.map { ($0, messages[$0.id] ?? chatStore.messages(chatId: $0.id)) }
    }

    func open(_ item: SwitcherItem) {
        let value = String(item.id.split(separator: ":", maxSplits: 1).last ?? "")
        switch item.kind {
        case .chat:
            if let id = item.chatId { show(chat: id) }
        case .message:
            if let chatId = item.chatId, let messageId = item.messageId { jump(to: messageId, in: chatId) }
        case .bot:
            if let b = bot(value) { openChat(with: b) }
        case .group:
            if let g = group(value) { openChat(with: g) }
        case .page:
            if let s = SidebarSection(rawValue: value) { section = s }
        case .action:
            switch value {
            case "newBot": showingNewBot = true
            case "newGroup": showingNewGroup = true
            case "saved": showingSavedMessages = true
            default: break
            }
        }
    }

    // MARK: Bot drafter and team notes

    /// "Describe your bot": a name, role, instructions, emoji and colour from one line.
    func draftBot(_ description: String, engine: BotEngine) async -> Result<BotDraft, DraftError> {
        // A local model can't be relied on for JSON, so drafting uses an agent engine you have.
        var use = engine
        if !use.isAgent {
            use = engineLocations?[.claude] != nil || engineLocations?[.codex] == nil ? .claude : .codex
        }
        let dir = paths.root.appendingPathComponent(".launchpad/scratch/drafter", isDirectory: true)
        return await BotDrafter.draft(description, engine: use, model: nil, directory: dir,
                                      run: MemoryReviewer.engine(using: runner))
    }

    func teamNotesText() -> String {
        TeamNotes.read(paths: paths) ?? TeamNotes.template
    }

    func saveTeamNotes(_ text: String) {
        do {
            try TeamNotes.save(text, paths: paths)
        } catch {
            alertMessage = "Couldn't save the team notes: \(error.localizedDescription)"
        }
    }
}

// MARK: - Threads, side questions, context and usage

extension AppModel {
    /// Puts the conversation aside and starts empty (the bot starts a fresh session).
    func newThread(_ chatId: String) {
        guard !isRunning(chatId), let meta = chat(chatId) else { return }
        do {
            try threads.newThread(meta)
        } catch {
            alertMessage = "Couldn't start a new thread: \(error.localizedDescription)"
        }
        threadsChanged(chatId)
    }

    /// Keeps the messages but clears the bots' sessions: the next reply starts from a recap.
    func compact(_ chatId: String) {
        guard !isRunning(chatId), let meta = chat(chatId) else { return }
        do {
            try threads.compact(meta)
        } catch {
            alertMessage = "Couldn't compact this chat: \(error.localizedDescription)"
            return
        }
        threadsChanged(chatId)
        append(ChatMessage(role: .notice, text: ThreadStore.compactNotice), to: chatId)
    }

    /// A new chat with the messages up to `messageId` (the original is unchanged).
    func branch(_ chatId: String, from messageId: String) {
        guard let meta = chat(chatId) else { return }
        do {
            guard let made = try threads.branch(meta, upTo: messageId) else { return }
            reloadChats()
            show(chat: made.id)
        } catch {
            alertMessage = "Couldn't branch this chat: \(error.localizedDescription)"
        }
    }

    func pastThreads(_ chatId: String) -> [PastThread] {
        _ = threadsRevision
        return threads.pastThreads(chatId)
    }

    func reopenThread(_ threadId: String, in chatId: String) {
        guard !isRunning(chatId), let meta = chat(chatId) else { return }
        do {
            _ = try threads.reopen(meta, thread: threadId)
        } catch {
            alertMessage = "Couldn't reopen that thread: \(error.localizedDescription)"
        }
        threadsChanged(chatId)
    }

    func deleteThread(_ threadId: String, in chatId: String) {
        do {
            try threads.delete(chatId, thread: threadId)
        } catch {
            alertMessage = "Couldn't delete that thread: \(error.localizedDescription)"
        }
        threadsRevision += 1
    }

    private func threadsChanged(_ chatId: String) {
        reloadChats()
        messages[chatId] = nil
        loadMessagesIfNeeded(chatId)
        contextByChat[chatId] = nil
        queues[chatId] = nil
        threadsRevision += 1
    }

    /// A quick question to a busy (or idle) bot, answered from a fork of its session without stopping its work.
    func askSide(_ question: String, in chatId: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isAskingSide(chatId), let meta = chat(chatId), meta.kind == .bot, let bot = bot(meta.botId) else { return }
        loadMessagesIfNeeded(chatId)
        let history = messages(for: chatId)
        var asked = ChatMessage(role: .user, text: q)
        asked.isSide = true
        append(asked, to: chatId)
        Task { @MainActor [weak self] in
            await self?.runSide(chatId: chatId, bot: bot, question: q, history: history)
        }
    }

    private func runSide(chatId: String, bot: Bot, question: String, history: [ChatMessage]) async {
        guard let meta = chat(chatId) else { return }
        let runId = UUID().uuidString.lowercased()
        let setup = prepareRun(for: bot, chat: meta, runId: runId, chatTools: false)
        if let refusal = setup.refusal {
            var m = ChatMessage(role: .bot, botId: bot.id, status: .failed, failure: RunFailure(kind: .unknown, message: refusal))
            m.isSide = true
            append(m, to: chatId)
            return
        }
        var options = setup.options
        // A local model gets the chat as history: as it was before the question, so it isn't sent twice.
        if !bot.engine.isAgent { options.history = history }
        let invocation = SideQuestion.invocation(for: bot, question: question, botDirectory: paths.botDir(bot.id),
                                                 sessionId: meta.sessions[bot.id], history: history, names: botNames,
                                                 options: options)
        let run = await streamRun(invocation, chatId: chatId, runId: runId, bot: bot, setup: setup, isSide: true)
        var m = run.builder.message
        let cards = run.approvals.map { card -> LiveApproval in
            var c = card
            if c.state == .pending { c.state = .expired }
            return c
        }
        m.liveApprovals = cards.isEmpty ? nil : cards
        if m.status == .streaming {
            m.status = .failed
            m.failure = RunFailure(kind: .unknown, message: "\(bot.name) stopped without answering.")
        }
        m.isSide = true
        // Never kept: a side question's session is a throwaway fork.
        append(m, to: chatId)
    }

    // MARK: Codex usage and context

    func startCodexUsage() {
        refreshCodexUsage()
        usageTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshCodexUsage() }
        }
    }

    /// ChatGPT plan usage from Codex's own session logs (off the main thread).
    func refreshCodexUsage() {
        Task.detached(priority: .utility) {
            guard let report = CodexSessionLogs.usageReport() else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.usage = self.usageStore.record(report)
            }
        }
    }

    /// After a Codex reply: its exact context from the session log, and fresh plan usage.
    func afterCodexTurn(chatId: String, sessionId: String?) {
        refreshCodexUsage()
        guard let sessionId else { return }
        Task.detached(priority: .utility) {
            guard let context = CodexSessionLogs.context(threadId: sessionId) else { return }
            await MainActor.run { [weak self] in self?.contextByChat[chatId] = context }
        }
    }
}
#endif
