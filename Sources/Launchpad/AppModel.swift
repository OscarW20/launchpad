#if os(macOS)
import SwiftUI
import AppKit
import Observation
import LaunchpadCore

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case chats, bots, groups, skills, connectors, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chats: return "Chats"
        case .bots: return "Bots"
        case .groups: return "Groups"
        case .skills: return "Skills"
        case .connectors: return "Connectors"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .chats: return "bubble.left.and.bubble.right"
        case .bots: return "face.smiling"
        case .groups: return "person.3"
        case .skills: return "sparkles"
        case .connectors: return "powerplug"
        case .settings: return "gearshape"
        }
    }

    /// The build phase a section arrives in, if it isn't here yet.
    var comingInPhase: Int? {
        switch self {
        case .groups: return 3
        case .skills: return 2
        case .connectors: return 5
        default: return nil
        }
    }

    var blurb: String {
        switch self {
        case .chats: return "Your conversations with bots and groups."
        case .bots: return "Your AI teammates. Each one is a folder in ~/Launchpad/bots."
        case .groups: return "Put bots in a group, pick a lead, and let them work together."
        case .skills: return "A library of skills you can give to bots and groups."
        case .connectors: return "MCP servers your bots can use, with sign-in kept in your Keychain."
        case .settings: return "Where Launchpad keeps things, and how it finds Claude Code and Codex."
        }
    }
}

enum ChatFilter: String, CaseIterable, Identifiable {
    case all, bots, groups
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

@MainActor
@Observable
final class AppModel {
    let paths: LaunchpadPaths
    let botStore: BotStore
    let chatStore: ChatStore
    let runner: EngineRunner

    var bots: [Bot] = []
    var chats: [ChatMeta] = []
    private(set) var messages: [String: [ChatMessage]] = [:]
    /// Replies that are streaming in right now, by chat id.
    private(set) var live: [String: MessageBuilder] = [:]
    /// Which engines are installed: nil while checking.
    private(set) var engineLocations: [BotEngine: String]? = nil

    var section: SidebarSection = .chats
    var selectedChatId: String?
    var selectedBotId: String?
    var chatSearch = ""
    var chatFilter: ChatFilter = .all
    var showingNewBot = false
    var drafts: [String: String] = [:]
    var alertMessage: String?

    @ObservationIgnored private var handles: [String: RunHandle] = [:]
    @ObservationIgnored private var watcher: FolderWatcher?

    init(paths: LaunchpadPaths = .default) {
        self.paths = paths
        self.botStore = BotStore(paths: paths)
        self.chatStore = ChatStore(paths: paths)
        self.runner = EngineRunner()
        do {
            try paths.ensureStructure()
        } catch {
            alertMessage = "Launchpad couldn't create its folder at \(paths.root.path). \(error.localizedDescription)"
        }
        reloadBots()
        reloadChats()
        selectedChatId = chats.first?.id

        let watcher = FolderWatcher(paths: paths) { [weak self] areas in
            Task { @MainActor in self?.handleFolderChanges(areas) }
        }
        watcher.start()
        self.watcher = watcher

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAll() }
        }
        refreshEngines()
    }

    // MARK: - Loading

    private func handleFolderChanges(_ areas: Set<FolderWatcher.Area>) {
        if areas.contains(.bots) { reloadBots() }
        if areas.contains(.chats) { reloadChats() }
    }

    func reloadBots() {
        let loaded = botStore.loadAll()
        for bot in loaded { botStore.syncInstructions(for: bot.id) }
        if loaded != bots { bots = loaded }
        if let id = selectedBotId, bot(id) == nil { selectedBotId = nil }
    }

    func reloadChats() {
        let loaded = chatStore.loadAll()
        if loaded != chats { chats = loaded }
        if let id = selectedChatId, chat(id) == nil { selectedChatId = nil }
    }

    func refreshEngines() {
        engineLocations = nil
        let locator = runner.locator
        Task.detached(priority: .utility) {
            var found: [BotEngine: String] = [:]
            for engine in BotEngine.allCases {
                if let url = locator.locate(engine) { found[engine] = url.path }
            }
            await MainActor.run { [found] in self.engineLocations = found }
        }
    }

    func bot(_ id: String?) -> Bot? {
        guard let id else { return nil }
        return bots.first { $0.id == id }
    }

    func chat(_ id: String?) -> ChatMeta? {
        guard let id else { return nil }
        return chats.first { $0.id == id }
    }

    var filteredChats: [ChatMeta] {
        let query = chatSearch.trimmingCharacters(in: .whitespaces).lowercased()
        return chats.filter { chat in
            switch chatFilter {
            case .all: break
            case .bots: if chat.kind != .bot { return false }
            case .groups: if chat.kind != .group { return false }
            }
            guard !query.isEmpty else { return true }
            let haystack = [chat.title, chat.lastPreview ?? "", bot(chat.botId)?.role ?? ""].joined(separator: " ").lowercased()
            return haystack.contains(query)
        }
    }

    func messages(for chatId: String) -> [ChatMessage] {
        messages[chatId] ?? []
    }

    func loadMessagesIfNeeded(_ chatId: String) {
        if messages[chatId] == nil { messages[chatId] = chatStore.messages(chatId: chatId) }
    }

    // MARK: - Bots

    @discardableResult
    func createBot(from draft: Bot, instructions: String? = nil) -> Bot? {
        do {
            let bot = try botStore.create(
                name: draft.name, emoji: draft.emoji, colour: draft.colour, role: draft.role,
                engine: draft.engine, model: draft.model, permission: draft.permission,
                instructions: instructions
            )
            reloadBots()
            return bot
        } catch {
            alertMessage = error.localizedDescription
            return nil
        }
    }

    func saveBot(_ bot: Bot, instructions: String?) {
        do {
            try botStore.save(bot)
            if let instructions { try botStore.setInstructions(instructions, for: bot.id) }
            reloadBots()
            // Keep chat titles in step with the bot's name.
            for var chat in chats where chat.kind == .bot && chat.botId == bot.id && chat.title != bot.name {
                chat.title = bot.name
                try? chatStore.save(chat)
            }
            reloadChats()
        } catch {
            alertMessage = "Couldn't save \(bot.name): \(error.localizedDescription)"
        }
    }

    func deleteBot(_ id: String) {
        for chat in chats where chat.botId == id { stop(chat.id) }
        do {
            try botStore.delete(id: id)
        } catch {
            alertMessage = "Couldn't move that bot to the Trash: \(error.localizedDescription)"
        }
        reloadBots()
    }

    // MARK: - Chats

    /// Opens the most recent chat with this bot, or starts one.
    func openChat(with bot: Bot) {
        if let existing = chats.first(where: { $0.kind == .bot && $0.botId == bot.id }) {
            show(chat: existing.id)
        } else {
            newChat(with: bot)
        }
    }

    func newChat(with bot: Bot) {
        do {
            let meta = try chatStore.createChat(with: bot)
            reloadChats()
            show(chat: meta.id)
        } catch {
            alertMessage = "Couldn't start a chat: \(error.localizedDescription)"
        }
    }

    func show(chat id: String) {
        section = .chats
        chatFilter = .all
        chatSearch = ""
        selectedChatId = id
    }

    func deleteChat(_ id: String) {
        stop(id)
        try? chatStore.delete(chatId: id)
        messages[id] = nil
        drafts[id] = nil
        reloadChats()
    }

    func isRunning(_ chatId: String) -> Bool { live[chatId] != nil }

    func send(chatId: String, text override: String? = nil) {
        let text = (override ?? drafts[chatId] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning(chatId) else { return }
        loadMessagesIfNeeded(chatId)
        drafts[chatId] = ""
        append(ChatMessage(role: .user, text: text), to: chatId)
        startRun(chatId: chatId, prompt: text, allowFreshRetry: true)
    }

    func stop(_ chatId: String) {
        handles[chatId]?.cancel()
    }

    func stopAll() {
        for handle in handles.values { handle.cancel() }
    }

    private func startRun(chatId: String, prompt: String, allowFreshRetry: Bool) {
        guard let meta = chat(chatId), let bot = bot(meta.botId) else {
            append(ChatMessage(role: .notice, text: "This chat's bot isn't in your Launchpad folder any more."), to: chatId)
            return
        }
        botStore.syncInstructions(for: bot.id)
        let invocation = EngineCommand.invocation(
            for: bot, prompt: prompt, botDirectory: paths.botDir(bot.id), sessionId: meta.sessions[bot.id]
        )
        let handle = runner.run(invocation)
        handles[chatId] = handle
        live[chatId] = MessageBuilder(botId: bot.id)

        Task { @MainActor [weak self] in
            for await event in handle.events {
                self?.live[chatId]?.apply(event)
            }
            self?.finishRun(chatId: chatId, botId: bot.id, prompt: prompt, allowFreshRetry: allowFreshRetry)
        }
    }

    private func finishRun(chatId: String, botId: String, prompt: String, allowFreshRetry: Bool) {
        guard let builder = live[chatId] else { return }
        live[chatId] = nil
        handles[chatId] = nil

        var message = builder.message
        if message.status == .streaming {
            message.status = .failed
            message.failure = RunFailure(kind: .unknown, message: "The bot stopped without replying.")
        }

        // The engine lost this chat's session: forget it and quietly start fresh once.
        if message.failure?.kind == .sessionLost, allowFreshRetry, var meta = chat(chatId) {
            meta.sessions[botId] = nil
            save(meta)
            let name = bot(botId)?.name ?? "the bot"
            append(ChatMessage(role: .notice, text: "Couldn't pick up the earlier conversation, so \(name) is starting fresh."), to: chatId)
            startRun(chatId: chatId, prompt: prompt, allowFreshRetry: false)
            return
        }

        append(message, to: chatId)
        if message.status == .done || message.status == .stopped,
           let sessionId = builder.sessionId, var meta = chat(chatId), meta.sessions[botId] != sessionId {
            meta.sessions[botId] = sessionId
            save(meta)
        }
    }

    private func append(_ message: ChatMessage, to chatId: String) {
        loadMessagesIfNeeded(chatId)
        messages[chatId, default: []].append(message)
        do {
            try chatStore.append(message, chatId: chatId)
        } catch {
            alertMessage = "Couldn't save the chat history: \(error.localizedDescription)"
        }
        guard var meta = chat(chatId) else { return }
        meta.updatedAt = Date()
        if message.role != .notice {
            let preview = message.text.isEmpty ? (message.failure?.message ?? "") : message.text
            meta.lastPreview = String(preview.prefix(200))
        }
        save(meta)
    }

    private func save(_ meta: ChatMeta) {
        try? chatStore.save(meta)
        if let i = chats.firstIndex(where: { $0.id == meta.id }) { chats[i] = meta } else { chats.append(meta) }
        chats.sort { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Actions from error cards

    func perform(_ action: FailureAction) {
        switch action {
        case .openTerminal(let command):
            do {
                try SystemActions.openTerminal(running: command)
            } catch {
                alertMessage = "Couldn't open Terminal. Open it yourself and run: \(command)"
            }
        case .openURL(let url):
            NSWorkspace.shared.open(url)
        }
    }
}
#endif
