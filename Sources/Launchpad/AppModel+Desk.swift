#if os(macOS)
import SwiftUI
import AppKit
import LaunchpadCore

/// A bot's desk in the Office (and a row in the menu bar).
struct DeskInfo: Identifiable {
    var bot: Bot
    var state: DeskState
    /// What it's doing, or why it needs you.
    var line: String
    /// The chat it's working in (or waiting on you in).
    var chatId: String?
    /// When the current reply started.
    var since: Date?
    /// The Mac app it has claimed (computer use).
    var app: String?

    var id: String { bot.id }
}

/// A bot replying right now, and where.
struct WorkingRun: Identifiable {
    var chatId: String
    var run: LiveRun
    var id: String { run.id }
}

/// Where you are, for Back and Forward: the page and what's selected on it.
struct NavSpot: Equatable {
    var section: SidebarSection
    var item: String?
}

// MARK: - Who's working, the Office, the menu bar

extension AppModel {
    /// Bots replying right now (not side questions), with the chat and live reply. One row per bot.
    var workingRuns: [WorkingRun] {
        var seen = Set<String>()
        var out: [WorkingRun] = []
        for (chatId, runs) in live.sorted(by: { $0.key < $1.key }) {
            for run in runs where !run.isSide && !seen.contains(run.botId) {
                seen.insert(run.botId)
                out.append(WorkingRun(chatId: chatId, run: run))
            }
        }
        return out
    }

    /// Any bot is working (for keeping the Mac awake and the menu bar icon).
    var anyoneWorking: Bool { !busyChats.isEmpty || live.values.contains { !$0.isEmpty } }

    /// Every bot's desk, those that need you first.
    func desks(now: Date = Date()) -> [DeskInfo] {
        let working = Dictionary(workingRuns.map { ($0.run.botId, $0) }, uniquingKeysWith: { a, _ in a })
        // Waiting on you: a live reply with a card, or the latest message of a chat you've opened.
        var waiting: [String: (chatId: String, reason: String)] = [:]
        for (chatId, list) in messages where !isRunning(chatId) {
            if let w = Attention.waiting(in: list), waiting[w.botId] == nil { waiting[w.botId] = (chatId, w.reason) }
        }
        let claims = AppClaims.read(file: paths.appClaimsFile, now: now)
        return bots.map { bot -> DeskInfo in
            let run = working[bot.id]
            let liveReason = run.flatMap { Attention.reason($0.run.message) }
            let needs = liveReason.map { (run!.chatId, $0) } ?? waiting[bot.id].map { ($0.chatId, $0.reason) }
            let queued = queues.values.reduce(0) { $0 + $1.waiting(for: bot.id).count }
            let state = DeskState.of(working: run != nil, needsYou: needs != nil, queued: queued > 0)
            var info = DeskInfo(bot: bot, state: state, line: "", chatId: run?.chatId ?? needs?.0,
                                since: run?.run.builder.message.createdAt, app: claims.last { $0.botId == bot.id }?.app)
            switch state {
            case .needsYou:
                info.line = needs?.1 ?? "Needs you"
            case .working:
                if let run {
                    var line = WorkSummary.line(for: run.run.message, todos: run.run.builder.todos)
                    if let chat = chat(run.chatId), chat.kind == .group { line += " · \(chat.title)" }
                    info.line = line
                }
            case .waiting:
                info.line = "\(queued) message\(queued == 1 ? "" : "s") waiting to start."
            case .idle:
                if let last = activity.recent(1, bot: bot.id).first {
                    info.line = "Last active \(TimeLabel.short(last.date)): \(last.text)"
                } else {
                    info.line = bot.role.isEmpty ? "Ready for work." : bot.role
                }
            }
            return info
        }
        .sorted { ($0.state.order, $0.bot.name) < ($1.state.order, $1.bot.name) }
    }

    /// Loads the most recent chats' messages, so the Office can see who's waiting on you.
    func loadRecentMessages(limit: Int = 20) {
        for chat in chats.prefix(limit) { loadMessagesIfNeeded(chat.id) }
    }

    /// Stops every bot that's working.
    func stopEveryone() {
        let ids = Set(busyChats).union(live.keys)
        for id in ids { stop(id) }
    }

    /// The chat a working bot is in, so its Stop button stops the right thing.
    func stopBot(_ botId: String) {
        for (chatId, runs) in live where runs.contains(where: { $0.botId == botId && !$0.isSide }) { stop(chatId) }
    }

    /// The last thing said in a chat, for the menu bar.
    func lastLine(_ chatId: String) -> String {
        chat(chatId)?.lastPreview ?? ""
    }

    // MARK: Keeping awake and notifications

    /// Something started or stopped: hold the Mac awake while anyone works.
    func workingChanged() {
        Awake.update(working: anyoneWorking)
    }

    /// A chat's work has ended: tell you if Launchpad is in the background.
    func chatWentQuiet(_ chatId: String) {
        workingChanged()
        guard !isRunning(chatId), let meta = chat(chatId) else { return }
        let list = messages(for: chatId)
        guard let last = list.last(where: { $0.role != .notice && $0.isSide != true }), last.role == .bot,
              Date().timeIntervalSince(last.createdAt) < 600 else { return }
        let name = bot(last.botId)?.name ?? "A bot"
        if let notice = ReplyNotice.finished(last, botName: name, chatTitle: meta.title, isGroup: meta.kind == .group) {
            Notifier.shared.post(notice, chatId: chatId)
        }
    }

    /// A live reply now waits on you (approval card, question or plan).
    func notifyNeedsYou(_ notice: ReplyNotice, chatId: String) {
        Notifier.shared.post(notice, chatId: chatId)
    }

    /// The Reply field on a notification: goes to that chat like the composer (steering a busy bot).
    func replyFromNotification(_ text: String, chatId: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, chat(chatId) != nil else { return }
        submit(ChatMessage(role: .user, text: t), prompt: t, to: chatId)
    }

    // MARK: Quick Ask

    /// Everyone you can message: bots, then groups.
    var quickAskTargets: [Routine.Target] {
        bots.map { .bot($0.id) } + groups.map { .group($0.id) }
    }

    /// The target for the chat you last looked at (or the first bot).
    var defaultQuickAskTarget: Routine.Target? {
        if let meta = chat(selectedChatId) {
            if meta.kind == .group, let g = meta.groupId, group(g) != nil { return .group(g) }
            if let b = meta.botId, bot(b) != nil { return .bot(b) }
        }
        return quickAskTargets.first
    }

    /// The everyday chat with a bot or group (made if there isn't one), without switching to it.
    func everydayChat(for target: Routine.Target) -> String? {
        switch target {
        case .bot(let id):
            if let c = chats.first(where: { $0.kind == .bot && $0.botId == id }) { return c.id }
        case .group(let id):
            if let c = chats.first(where: { $0.kind == .group && $0.groupId == id }) { return c.id }
        }
        do {
            let meta: ChatMeta
            switch target {
            case .bot(let id):
                guard let b = bot(id) else { return nil }
                meta = try chatStore.createChat(with: b)
            case .group(let id):
                guard let g = group(id) else { return nil }
                meta = try chatStore.createChat(with: g)
            }
            reloadChats()
            return meta.id
        } catch {
            alertMessage = "Couldn't start a chat: \(error.localizedDescription)"
            return nil
        }
    }

    /// Quick Ask: sends to the target's everyday chat. Returns where it went, to show the reply.
    func quickAsk(_ text: String, to target: Routine.Target) -> (chatId: String, messageId: String)? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, targetExists(target), let chatId = everydayChat(for: target) else { return nil }
        let message = ChatMessage(role: .user, text: t)
        submit(message, prompt: t, to: chatId)
        return (chatId, message.id)
    }

    /// Replies after a message (saved, then live), for Quick Ask.
    func replies(after messageId: String, in chatId: String) -> [ChatMessage] {
        let list = messages(for: chatId)
        var out: [ChatMessage] = []
        if let i = list.firstIndex(where: { $0.id == messageId }) {
            out = list[(i + 1)...].filter { $0.role == .bot && $0.isSide != true }
        }
        out += liveRuns(for: chatId).filter { !$0.isSide }.map(\.message)
        return out
    }

    // MARK: Back and forward

    var navSpot: NavSpot {
        let item: String?
        switch section {
        case .chats: item = selectedChatId
        case .bots: item = selectedBotId
        case .groups: item = selectedGroupId
        case .skills: item = selectedSkillId
        case .connectors: item = selectedConnectorId
        case .routines: item = selectedRoutineId
        case .tasks: item = selectedTaskId
        case .workflows: item = selectedWorkflowId
        case .office, .hire, .settings: item = nil
        }
        return NavSpot(section: section, item: item)
    }

    /// Called when the page or selection changes (from RootView).
    func navigated(from old: NavSpot, to new: NavSpot) {
        if let expected = pendingTravel {
            pendingTravel = nil
            if expected == new { return }
        }
        nav.visit(from: old, to: new)
    }

    func goBack() {
        let here = navSpot
        guard let spot = nav.goBack(from: here) else { return }
        travel(to: spot, from: here)
    }

    func goForward() {
        let here = navSpot
        guard let spot = nav.goForward(from: here) else { return }
        travel(to: spot, from: here)
    }

    private func travel(to spot: NavSpot, from here: NavSpot) {
        guard spot != here else { return }
        pendingTravel = spot
        section = spot.section
        switch spot.section {
        case .chats: selectedChatId = spot.item
        case .bots: selectedBotId = spot.item
        case .groups: selectedGroupId = spot.item
        case .skills: selectedSkillId = spot.item
        case .connectors: selectedConnectorId = spot.item
        case .routines: selectedRoutineId = spot.item
        case .tasks: selectedTaskId = spot.item
        case .workflows: selectedWorkflowId = spot.item
        case .office, .hire, .settings: break
        }
    }

    // MARK: Computer use

    /// Adds the computer tools to a reply when the bot may use the Mac, or tells it why not.
    /// Returns the instructions to add and whether the tools were given.
    func computerSetup(for bot: Bot, guardActive: Bool, options: inout RunOptions) -> (note: String?, given: Bool) {
        guard bot.useComputer else { return (nil, false) }
        let cu = ComputerUseController.shared
        if let blocker = cu.blocker(for: bot, guardActive: guardActive) {
            return (ComputerUse.unavailableNote(blocker), false)
        }
        guard let driver = cu.driverPath, cu.ensureDaemon() else {
            return (ComputerUse.unavailableNote(.driverFailed), false)
        }
        options.connectors.append(ComputerUse.connector(driver: driver, socket: cu.socket))
        let others = bots.filter { $0.useComputer && $0.id != bot.id }.map(\.name)
        return (ComputerUse.instructions(handle: bot.name, others: others), true)
    }

    /// A reply has ended: the bot lets go of the apps it claimed, unless it's still working elsewhere.
    func releaseApps(of botId: String) {
        guard !live.values.contains(where: { $0.contains { $0.botId == botId } }) else { return }
        let file = paths.appClaimsFile
        Task.detached(priority: .utility) { AppClaims.release(botId: botId, file: file) }
    }

    // MARK: Start-up

    /// Quick Ask, notifications and computer use, once the app is up (from RootView).
    func startMacFeatures() {
        guard !macFeaturesStarted else { return }
        macFeaturesStarted = true
        QuickAsk.shared.install(model: self)
        Notifier.shared.install(model: self)
        ComputerUseController.shared.start(locator: runner.locator)
        Updater.shared.start()
        TicketCenter.shared.install(model: self)
    }
}
#endif
