#if os(macOS)
import SwiftUI
import AppKit
import Observation
import LaunchpadCore

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case chats, bots, groups, hire, skills, connectors, routines, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chats: return "Chats"
        case .bots: return "Bots"
        case .groups: return "Groups"
        case .hire: return "Hire"
        case .skills: return "Skills"
        case .connectors: return "Connectors"
        case .routines: return "Routines"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .chats: return "bubble.left.and.bubble.right"
        case .bots: return "face.smiling"
        case .groups: return "person.3"
        case .hire: return "person.badge.plus"
        case .skills: return "sparkles"
        case .connectors: return "powerplug"
        case .routines: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }

    var blurb: String {
        switch self {
        case .chats: return "Your conversations with bots and groups."
        case .bots: return "Your AI teammates. Each one is a folder in ~/Launchpad/bots."
        case .groups: return "Put bots in a group with a lead. You post a task; the lead hands work out by @mention."
        case .hire: return "Ready-made teammates you can add in one click, or the whole Dev team at once."
        case .skills: return "Your skill library. Give skills to bots or whole groups; Claude Code and Codex find them automatically."
        case .connectors: return "MCP servers your bots can use. Tokens are kept in your Keychain, never in files."
        case .routines: return "Send a message to a bot or group on a schedule, or when a file appears. Runs while Launchpad is open."
        case .settings: return "Where Launchpad keeps things, and how it finds Claude Code and Codex."
        }
    }
}

enum ChatFilter: String, CaseIterable, Identifiable {
    case all, bots, groups
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// A reply that's streaming in right now.
struct LiveRun: Identifiable {
    let id: String
    let botId: String
    var builder: MessageBuilder
}

/// Drafting a SKILL.md from a chat.
struct TeachState {
    enum Phase: Equatable { case drafting, ready, failed(String) }
    var chatId: String
    var phase: Phase
    var draft: String
}

/// Which bots have an engine session in which chat. Read from the group runner's threads.
final class SessionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: Set<String>] = [:]

    func set(_ chat: ChatMeta) {
        lock.lock(); defer { lock.unlock() }
        sessions[chat.id] = Set(chat.sessions.keys)
    }

    func has(chat: String, bot: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sessions[chat]?.contains(bot) ?? false
    }
}

@MainActor
@Observable
final class AppModel {
    let paths: LaunchpadPaths
    let botStore: BotStore
    let chatStore: ChatStore
    let groupStore: GroupStore
    let skillStore: SkillStore
    let connectorStore: ConnectorStore
    let routineStore: RoutineStore
    let usageStore: UsageStore
    let secrets: SecretStore
    let grants: ApprovalGrants
    let runner: EngineRunner

    var bots: [Bot] = []
    var groups: [BotGroup] = []
    var skills: [Skill] = []
    var connectors: [Connector] = []
    var routines: [Routine] = []
    var chats: [ChatMeta] = []
    var usage = UsageSnapshot()
    private(set) var messages: [String: [ChatMessage]] = [:]
    private(set) var live: [String: [LiveRun]] = [:]
    private(set) var busyChats: Set<String> = []
    private(set) var engineLocations: [BotEngine: String]? = nil

    var section: SidebarSection = .chats
    var selectedChatId: String?
    var selectedBotId: String?
    var selectedGroupId: String?
    var selectedSkillId: String?
    var selectedConnectorId: String?
    var selectedRoutineId: String?
    var chatSearch = ""
    var chatFilter: ChatFilter = .all
    var showingNewBot = false
    var showingNewGroup = false
    var teach: TeachState?
    var summaryGroupId: String?
    var drafts: [String: String] = [:]
    var alertMessage: String?

    @ObservationIgnored private var handles: [String: RunHandle] = [:]
    @ObservationIgnored private var runChats: [String: String] = [:]
    @ObservationIgnored private var chatTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var teachHandle: RunHandle?
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var routineTimer: Timer?
    @ObservationIgnored private let fileWatch = NewFileWatch()
    @ObservationIgnored private let sessionRegistry = SessionRegistry()

    init(paths: LaunchpadPaths = .default) {
        self.paths = paths
        botStore = BotStore(paths: paths)
        chatStore = ChatStore(paths: paths)
        groupStore = GroupStore(paths: paths)
        skillStore = SkillStore(paths: paths)
        connectorStore = ConnectorStore(paths: paths)
        routineStore = RoutineStore(paths: paths)
        usageStore = UsageStore(paths: paths)
        secrets = KeychainSecretStore()
        grants = ApprovalGrants(paths: paths)
        runner = EngineRunner()
        do {
            try paths.ensureStructure()
        } catch {
            alertMessage = "Launchpad couldn't create its folder at \(paths.root.path). \(error.localizedDescription)"
        }
        skillStore.seedStarterSkillsIfNeeded()
        reloadAll()
        usage = usageStore.load()
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
        startRoutines()
        refreshEngines()
    }

    // MARK: - Loading

    private func handleFolderChanges(_ areas: Set<FolderWatcher.Area>) {
        if areas.contains(.bots) { reloadBots() }
        if areas.contains(.groups) { reloadGroups() }
        if areas.contains(.skills) { reloadSkills() }
        if areas.contains(.connectors) { reloadConnectors() }
        if areas.contains(.routines) { reloadRoutines() }
        if areas.contains(.chats) { reloadChats() }
        if !areas.isDisjoint(with: [.bots, .groups, .skills]) { relinkSkills() }
    }

    func reloadAll() {
        reloadBots()
        reloadGroups()
        reloadSkills()
        reloadConnectors()
        reloadRoutines()
        reloadChats()
        relinkSkills()
    }

    func reloadBots() {
        let loaded = botStore.loadAll()
        for bot in loaded { botStore.syncInstructions(for: bot.id) }
        if loaded != bots { bots = loaded }
        if let id = selectedBotId, bot(id) == nil { selectedBotId = nil }
    }

    func reloadGroups() {
        let loaded = groupStore.loadAll()
        if loaded != groups { groups = loaded }
        if let id = selectedGroupId, group(id) == nil { selectedGroupId = nil }
    }

    func reloadSkills() {
        let loaded = skillStore.loadAll()
        if loaded != skills { skills = loaded }
        if let id = selectedSkillId, !skills.contains(where: { $0.id == id }) { selectedSkillId = nil }
    }

    func reloadConnectors() {
        let loaded = connectorStore.loadAll()
        if loaded != connectors { connectors = loaded }
    }

    func reloadRoutines() {
        let loaded = routineStore.loadAll()
        if loaded != routines { routines = loaded }
    }

    func reloadChats() {
        let loaded = chatStore.loadAll()
        if loaded != chats { chats = loaded }
        for chat in loaded { sessionRegistry.set(chat) }
        if let id = selectedChatId, chat(id) == nil { selectedChatId = nil }
    }

    private func relinkSkills() {
        let linker = SkillLinker(paths: paths)
        for bot in bots {
            linker.link(botId: bot.id, skills: SkillLinker.effectiveSkills(for: bot, groups: groups))
        }
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

    /// The approval hook, shipped next to the app.
    var guardExecutable: URL? {
        guard let dir = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let url = dir.appendingPathComponent("launchpad-guard")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    // MARK: - Lookups

    func bot(_ id: String?) -> Bot? {
        guard let id else { return nil }
        return bots.first { $0.id == id }
    }

    func group(_ id: String?) -> BotGroup? {
        guard let id else { return nil }
        return groups.first { $0.id == id }
    }

    func chat(_ id: String?) -> ChatMeta? {
        guard let id else { return nil }
        return chats.first { $0.id == id }
    }

    func skill(_ id: String?) -> Skill? {
        guard let id else { return nil }
        return skills.first { $0.id == id }
    }

    func groups(containing botId: String) -> [BotGroup] {
        groups.filter { $0.members.contains(botId) || $0.lead == botId }
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
            let extra = chat.kind == .bot ? (bot(chat.botId)?.role ?? "") : (group(chat.groupId)?.rules ?? "")
            return [chat.title, chat.lastPreview ?? "", extra].joined(separator: " ").lowercased().contains(query)
        }
    }

    func messages(for chatId: String) -> [ChatMessage] { messages[chatId] ?? [] }
    func liveRuns(for chatId: String) -> [LiveRun] { live[chatId] ?? [] }

    func loadMessagesIfNeeded(_ chatId: String) {
        if messages[chatId] == nil { messages[chatId] = chatStore.messages(chatId: chatId) }
    }

    func isRunning(_ chatId: String) -> Bool { busyChats.contains(chatId) || !(live[chatId]?.isEmpty ?? true) }

    // MARK: - Bots

    @discardableResult
    func createBot(from draft: Bot, instructions: String? = nil) -> Bot? {
        do {
            var bot = try botStore.create(
                name: draft.name, emoji: draft.emoji, colour: draft.colour, role: draft.role,
                engine: draft.engine, model: draft.model, permission: draft.permission, instructions: instructions
            )
            if !draft.skills.isEmpty || !draft.connectors.isEmpty {
                bot.skills = draft.skills
                bot.connectors = draft.connectors
                try botStore.save(bot)
            }
            reloadBots()
            relinkSkills()
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
            relinkSkills()
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

    func toggle(skill: String, for botId: String) {
        guard var b = bot(botId) else { return }
        if let i = b.skills.firstIndex(of: skill) { b.skills.remove(at: i) } else { b.skills.append(skill) }
        saveBot(b, instructions: nil)
    }

    func toggle(connector: String, for botId: String) {
        guard var b = bot(botId) else { return }
        if let i = b.connectors.firstIndex(of: connector) { b.connectors.remove(at: i) } else { b.connectors.append(connector) }
        saveBot(b, instructions: nil)
    }

    // MARK: - Groups

    @discardableResult
    func createGroup(name: String, emoji: String, members: [String], lead: String?, rules: String, limit: Int) -> BotGroup? {
        do {
            let g = try groupStore.create(name: name, emoji: emoji, members: members, lead: lead, rules: rules, handoffLimit: limit)
            reloadGroups()
            relinkSkills()
            return g
        } catch {
            alertMessage = error.localizedDescription
            return nil
        }
    }

    func saveGroup(_ group: BotGroup) {
        do {
            try groupStore.save(group)
            reloadGroups()
            relinkSkills()
            for var chat in chats where chat.kind == .group && chat.groupId == group.id && chat.title != group.displayName {
                chat.title = group.displayName
                try? chatStore.save(chat)
            }
            reloadChats()
        } catch {
            alertMessage = "Couldn't save \(group.displayName): \(error.localizedDescription)"
        }
    }

    func deleteGroup(_ id: String) {
        for chat in chats where chat.groupId == id { stop(chat.id) }
        do { try groupStore.delete(id: id) } catch { alertMessage = "Couldn't move that group to the Trash: \(error.localizedDescription)" }
        reloadGroups()
        relinkSkills()
    }

    func toggle(skill: String, forGroup groupId: String) {
        guard var g = group(groupId) else { return }
        if let i = g.skills.firstIndex(of: skill) { g.skills.remove(at: i) } else { g.skills.append(skill) }
        saveGroup(g)
    }

    func toggle(connector: String, forGroup groupId: String) {
        guard var g = group(groupId) else { return }
        if let i = g.connectors.firstIndex(of: connector) { g.connectors.remove(at: i) } else { g.connectors.append(connector) }
        saveGroup(g)
    }

    // MARK: - Hire

    func hire(_ template: HireTemplate) {
        do {
            let bot = try Hiring(paths: paths).hire(template)
            reloadBots()
            relinkSkills()
            selectedBotId = bot.id
            section = .bots
        } catch {
            alertMessage = "Couldn't hire \(template.name): \(error.localizedDescription)"
        }
    }

    func hireDevTeam() {
        do {
            let (_, group) = try Hiring(paths: paths).hireDevTeam()
            reloadBots()
            reloadGroups()
            relinkSkills()
            openChat(with: group)
        } catch {
            alertMessage = "Couldn't add the Dev team: \(error.localizedDescription)"
        }
    }

    // MARK: - Skills

    func newSkill() {
        do {
            let s = try skillStore.create(name: "new-skill", description: "Use when …",
                                          body: "# New skill\n\n## When to use\n\n## Steps\n1. \n\n## Done when\n")
            reloadSkills()
            selectedSkillId = s.id
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func saveSkill(id: String, text: String) {
        do {
            try skillStore.save(id: id, text: text)
            reloadSkills()
        } catch {
            alertMessage = "Couldn't save the skill: \(error.localizedDescription)"
        }
    }

    func duplicateSkill(_ id: String) {
        do {
            let copy = try skillStore.duplicate(id: id)
            reloadSkills()
            selectedSkillId = copy.id
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func deleteSkill(_ id: String) {
        do { try skillStore.delete(id: id) } catch { alertMessage = error.localizedDescription }
        for var b in bots where b.skills.contains(id) {
            b.skills.removeAll { $0 == id }
            try? botStore.save(b)
        }
        for var g in groups where g.skills.contains(id) {
            g.skills.removeAll { $0 == id }
            try? groupStore.save(g)
        }
        reloadAll()
    }

    /// "Teach a skill from this chat": asks the chat's engine to write a SKILL.md draft.
    func teachSkill(from chatId: String) {
        loadMessagesIfNeeded(chatId)
        let msgs = messages(for: chatId)
        let teacher = bot(chat(chatId)?.botId) ?? bot(msgs.last { $0.role == .bot }?.botId) ?? bots.first
        guard let teacher else { alertMessage = "Add a bot first."; return }
        teach = TeachState(chatId: chatId, phase: .drafting, draft: "")
        let transcript = SkillTeacher.transcript(msgs) { [weak self] id in self?.bot(id)?.name ?? "Bot" }
        let scratch = paths.root.appendingPathComponent(".launchpad/scratch", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let inv = EngineCommand.oneShot(engine: teacher.engine, model: teacher.model,
                                        prompt: SkillTeacher.prompt(transcript: transcript), directory: scratch)
        let handle = runner.run(inv)
        teachHandle = handle
        Task { @MainActor [weak self] in
            var builder = MessageBuilder(botId: nil)
            for await event in handle.events {
                builder.apply(event)
                if self?.teach?.phase == .drafting { self?.teach?.draft = builder.message.text }
            }
            guard let self, self.teach != nil else { return }
            if builder.message.status == .done {
                self.teach?.draft = SkillTeacher.cleanDraft(builder.message.text)
                self.teach?.phase = .ready
            } else {
                self.teach?.phase = .failed(builder.message.failure?.message ?? "Couldn't write a draft this time.")
            }
        }
    }

    func cancelTeach() {
        teachHandle?.cancel()
        teachHandle = nil
        teach = nil
    }

    func saveTaughtSkill(_ text: String) {
        let parsed = SkillFile.parse(text)
        let taken = Set(skills.map(\.id))
        let id = Slug.unique(parsed.name ?? "new-skill", taken: taken)
        let final = SkillFile.compose(name: id, description: parsed.description ?? "", body: parsed.body)
        saveSkill(id: id, text: final)
        teach = nil
        selectedSkillId = id
        section = .skills
    }

    /// Imports Graphify's skill (installing Graphify first, in Terminal, if needed).
    func addGraphify() {
        let locator = runner.locator
        guard let exe = locator.locate(command: Graphify.command) else {
            perform(.openTerminal(command: "\(Graphify.installCommand) && echo && echo 'Graphify is installed. Go back to Launchpad and click Add Graphify again.'"))
            return
        }
        let paths = self.paths
        let env = locator.environment()
        Task.detached(priority: .userInitiated) {
            let result: String? = {
                do {
                    try Graphify.importSkill(executable: exe, paths: paths, environment: env)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }()
            await MainActor.run {
                if let result {
                    self.alertMessage = result
                } else {
                    self.reloadSkills()
                    self.relinkSkills()
                    self.selectedSkillId = Graphify.skillId
                    self.section = .skills
                }
            }
        }
    }

    // MARK: - Connectors

    func addConnector() {
        do {
            let c = try connectorStore.add(name: "New connector", kind: .http, url: "https://", command: nil, args: [])
            reloadConnectors()
            selectedConnectorId = c.id
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func saveConnector(_ c: Connector) {
        do {
            try connectorStore.update(c)
            reloadConnectors()
        } catch {
            alertMessage = "Couldn't save the connector: \(error.localizedDescription)"
        }
    }

    func removeConnector(_ id: String) {
        if let c = connectors.first(where: { $0.id == id }) {
            try? secrets.setSecret(nil, for: c.tokenAccount)
            for name in c.secretEnv { try? secrets.setSecret(nil, for: c.envAccount(name)) }
        }
        try? connectorStore.remove(id: id)
        for var b in bots where b.connectors.contains(id) {
            b.connectors.removeAll { $0 == id }
            try? botStore.save(b)
        }
        for var g in groups where g.connectors.contains(id) {
            g.connectors.removeAll { $0 == id }
            try? groupStore.save(g)
        }
        selectedConnectorId = nil
        reloadAll()
    }

    func hasSecret(_ account: String) -> Bool { secrets.secret(account) != nil }

    func setSecret(_ value: String?, for account: String) {
        do {
            try secrets.setSecret(value, for: account)
        } catch {
            alertMessage = "Couldn't save to your Keychain: \(error.localizedDescription)"
        }
    }

    // MARK: - Chats

    func openChat(with bot: Bot) {
        if let existing = chats.first(where: { $0.kind == .bot && $0.botId == bot.id }) {
            show(chat: existing.id)
        } else {
            newChat(with: bot)
        }
    }

    func openChat(with group: BotGroup) {
        if let existing = chats.first(where: { $0.kind == .group && $0.groupId == group.id }) {
            show(chat: existing.id)
        } else {
            do {
                let meta = try chatStore.createChat(with: group)
                reloadChats()
                show(chat: meta.id)
            } catch {
                alertMessage = "Couldn't start a chat: \(error.localizedDescription)"
            }
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

    func send(chatId: String, text override: String? = nil) {
        let text = (override ?? drafts[chatId] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning(chatId), let meta = chat(chatId) else { return }
        loadMessagesIfNeeded(chatId)
        if override == nil { drafts[chatId] = "" }
        append(ChatMessage(role: .user, text: text), to: chatId)
        if meta.kind == .group {
            startGroup(chatId) { await $0.runTask() }
        } else if let bot = bot(meta.botId) {
            startSolo(chatId, bot: bot, prompt: text)
        } else {
            append(ChatMessage(role: .notice, text: "This chat's bot isn't in your Launchpad folder any more."), to: chatId)
        }
    }

    /// "Ask everyone": every member gives a short view, then the lead sums up.
    func askEveryone(chatId: String) {
        let text = (drafts[chatId] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning(chatId) else { return }
        loadMessagesIfNeeded(chatId)
        drafts[chatId] = ""
        append(ChatMessage(role: .user, text: "🙋 Ask everyone: \(text)"), to: chatId)
        startGroup(chatId) { await $0.askEveryone() }
    }

    func stop(_ chatId: String) {
        chatTasks[chatId]?.cancel()
        for (runId, chat) in runChats where chat == chatId { handles[runId]?.cancel() }
    }

    func stopAll() {
        for task in chatTasks.values { task.cancel() }
        for handle in handles.values { handle.cancel() }
    }

    private func startSolo(_ chatId: String, bot: Bot, prompt: String) {
        busyChats.insert(chatId)
        chatTasks[chatId] = Task { @MainActor [weak self] in
            _ = await self?.runBotTurn(chatId: chatId, bot: bot, prompt: prompt)
            self?.chatTasks[chatId] = nil
            self?.busyChats.remove(chatId)
        }
    }

    private func startGroup(_ chatId: String, _ body: @escaping @Sendable (GroupOrchestrator) async -> GroupOutcome) {
        guard let meta = chat(chatId), let group = group(meta.groupId) else {
            append(ChatMessage(role: .notice, text: "This group isn't in your Launchpad folder any more."), to: chatId)
            return
        }
        let registry = sessionRegistry
        let orchestrator = GroupOrchestrator(
            group: group, bots: group.everyone.compactMap { bot($0) }, history: messages(for: chatId),
            summaryPath: groupStore.summary(group.id).path, workspacePath: groupStore.workspace(group.id).path,
            hasSession: { registry.has(chat: chatId, bot: $0) },
            runTurn: { [weak self] request in
                guard let self else { return ChatMessage(role: .bot, botId: request.bot.id, status: .stopped) }
                return await self.runBotTurn(chatId: chatId, bot: request.bot, prompt: request.prompt)
            }
        )
        busyChats.insert(chatId)
        chatTasks[chatId] = Task { @MainActor [weak self] in
            let outcome = await body(orchestrator)
            self?.groupFinished(chatId, group: group, outcome: outcome)
            self?.chatTasks[chatId] = nil
            self?.busyChats.remove(chatId)
        }
    }

    private func groupFinished(_ chatId: String, group: BotGroup, outcome: GroupOutcome) {
        switch outcome {
        case .done, .stopped, .awaitingApproval:
            break
        case let .handoffLimitReached(limit, waiting):
            let next = waiting.compactMap { bot($0)?.name }.joined(separator: ", ")
            append(ChatMessage(
                role: .notice,
                text: "The team has handed work on \(limit) time\(limit == 1 ? "" : "s"), so I've paused them\(next.isEmpty ? "" : " (next up: \(next))"). Keep going?",
                noticeAction: .continueGroup
            ), to: chatId)
        case .failed(let botId):
            append(ChatMessage(role: .notice, text: "\(bot(botId)?.name ?? "A bot") couldn't finish, so the group has stopped. Sort out the problem above, then send a message to carry on."), to: chatId)
        case .noLead:
            append(ChatMessage(role: .notice, text: "\(group.displayName) has no lead yet. Pick one in the group's settings."), to: chatId)
        }
    }

    func perform(_ action: NoticeAction, chatId: String) {
        switch action {
        case .continueGroup:
            send(chatId: chatId, text: "Keep going.")
        }
    }

    /// Approve / Decline on an approval card.
    func respond(to messageId: String, in chatId: String, approve: Bool) {
        guard var list = messages[chatId], let i = list.firstIndex(where: { $0.id == messageId }),
              var request = list[i].approval, request.status == .pending, !isRunning(chatId) else { return }
        let botId = list[i].botId
        request.status = approve ? .approved : .declined
        list[i].approval = request
        messages[chatId] = list
        try? chatStore.append(list[i], chatId: chatId)

        if approve, let botId, let session = chat(chatId)?.sessions[botId] {
            try? grants.grant(sessionId: session, action: request.action)
        }
        let prompt = approve ? request.approvedPrompt : request.declinedPrompt
        append(ChatMessage(role: .user, text: approve ? "✅ Approved: \(request.action)" : "✋ Declined: \(request.action)"), to: chatId)

        guard let meta = chat(chatId), let bot = bot(botId) else { return }
        if meta.kind == .group {
            startGroup(chatId) { await $0.resume(with: bot.id, note: prompt) }
        } else {
            startSolo(chatId, bot: bot, prompt: prompt)
        }
    }

    // MARK: - Running one bot

    private func runOptions(for bot: Bot, chat: ChatMeta) -> RunOptions {
        var o = RunOptions()
        let available = Set(skills.map(\.id))
        o.systemAppend = LaunchpadProtocol.text(skills: SkillLinker.effectiveSkills(for: bot, groups: groups).filter(available.contains))
        o.manageConnectors = true
        o.connectors = MCPConfig.effective(for: bot, groups: groups, all: connectors)
        o.environment = MCPConfig.environment(o.connectors, secrets: secrets, engine: bot.engine)
        if bot.engine == .claude, let guardURL = guardExecutable {
            o.guardCommand = "\"\(guardURL.path)\" --approvals \"\(grants.directory.path)\""
        }
        if chat.kind == .group, let gid = chat.groupId {
            try? FileManager.default.createDirectory(at: groupStore.workspace(gid), withIntermediateDirectories: true)
            o.addDirectories = [groupStore.dir(gid)]
        }
        return o
    }

    /// Runs one bot in a chat, streams its reply into the chat, saves it, and returns it.
    private func runBotTurn(chatId: String, bot: Bot, prompt: String, allowFreshRetry: Bool = true) async -> ChatMessage {
        guard let meta = chat(chatId) else { return ChatMessage(role: .bot, botId: bot.id, status: .stopped) }
        botStore.syncInstructions(for: bot.id)
        let invocation = EngineCommand.invocation(
            for: bot, prompt: prompt, botDirectory: paths.botDir(bot.id), sessionId: meta.sessions[bot.id],
            options: runOptions(for: bot, chat: meta)
        )
        let runId = UUID().uuidString
        let handle = runner.run(invocation)
        handles[runId] = handle
        runChats[runId] = chatId
        live[chatId, default: []].append(LiveRun(id: runId, botId: bot.id, builder: MessageBuilder(botId: bot.id)))
        if Task.isCancelled { handle.cancel() }

        for await event in handle.events {
            switch event {
            case .usage(let report): usage = usageStore.record(report)
            case .cost(let usd): usage = usageStore.recordCost(usd)
            default: break
            }
            if let i = live[chatId]?.firstIndex(where: { $0.id == runId }) {
                live[chatId]?[i].builder.apply(event)
            }
        }

        let builder = live[chatId]?.first { $0.id == runId }?.builder ?? MessageBuilder(botId: bot.id)
        live[chatId]?.removeAll { $0.id == runId }
        if live[chatId]?.isEmpty == true { live[chatId] = nil }
        handles[runId] = nil
        runChats[runId] = nil

        var message = builder.message
        if message.status == .streaming {
            message.status = .failed
            message.failure = RunFailure(kind: .unknown, message: "\(bot.name) stopped without replying.")
        }

        if message.failure?.kind == .sessionLost, allowFreshRetry, var fresh = chat(chatId) {
            fresh.sessions[bot.id] = nil
            save(fresh)
            append(ChatMessage(role: .notice, text: "Couldn't pick up the earlier conversation, so \(bot.name) is starting fresh."), to: chatId)
            return await runBotTurn(chatId: chatId, bot: bot, prompt: prompt, allowFreshRetry: false)
        }

        if message.status == .done || message.status == .stopped {
            let extracted = ApprovalRequest.extract(from: message.text)
            message.text = extracted.text
            if message.status == .done { message.approval = extracted.request }
        }
        append(message, to: chatId)

        if message.status == .done || message.status == .stopped,
           let sessionId = builder.sessionId, var meta = chat(chatId), meta.sessions[bot.id] != sessionId {
            meta.sessions[bot.id] = sessionId
            save(meta)
        }
        return message
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
            var preview = message.text.isEmpty ? (message.failure?.message ?? message.approval.map { "Asks to: \($0.action)" } ?? "") : message.text
            if let who = bot(message.botId)?.name, meta.kind == .group { preview = "\(who): \(preview)" }
            meta.lastPreview = String(preview.prefix(200))
        }
        save(meta)
    }

    private func save(_ meta: ChatMeta) {
        try? chatStore.save(meta)
        sessionRegistry.set(meta)
        if let i = chats.firstIndex(where: { $0.id == meta.id }) { chats[i] = meta } else { chats.append(meta) }
        chats.sort { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Routines

    private func startRoutines() {
        // Take a first look at watched folders so existing files don't count as new.
        for r in routines { if case .newFile(let folder) = r.trigger { _ = fileWatch.newFiles(in: folder) } }
        routineTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkRoutines() }
        }
    }

    func checkRoutines(now: Date = Date()) {
        for r in routines where r.enabled {
            switch r.trigger {
            case .newFile(let folder):
                let files = fileWatch.newFiles(in: folder)
                if !files.isEmpty {
                    fire(r, extra: "\n\nNew file\(files.count == 1 ? "" : "s"):\n" + files.map { "- \($0)" }.joined(separator: "\n"))
                }
            default:
                if RoutineSchedule.isDue(r, now: now) { fire(r, extra: "") }
            }
        }
    }

    func newRoutine() {
        guard let target: Routine.Target = bots.first.map({ .bot($0.id) }) ?? groups.first.map({ .group($0.id) }) else {
            alertMessage = "Add a bot or group first, so the routine has someone to message."
            return
        }
        let r = Routine(id: Slug.unique("routine", taken: Set(routines.map(\.id))), name: "New routine", target: target,
                        message: "Give me a short update on what you're working on.", trigger: .daily(hour: 9, minute: 0, weekdaysOnly: true),
                        enabled: false)
        saveRoutines(routines + [r])
        selectedRoutineId = r.id
    }

    func saveRoutine(_ r: Routine) {
        var all = routines
        if let i = all.firstIndex(where: { $0.id == r.id }) { all[i] = r } else { all.append(r) }
        if case .newFile(let folder) = r.trigger { _ = fileWatch.newFiles(in: folder) }
        saveRoutines(all)
    }

    func deleteRoutine(_ id: String) {
        saveRoutines(routines.filter { $0.id != id })
        if selectedRoutineId == id { selectedRoutineId = nil }
    }

    private func saveRoutines(_ all: [Routine]) {
        do {
            try routineStore.saveAll(all)
            routines = all
        } catch {
            alertMessage = "Couldn't save routines: \(error.localizedDescription)"
        }
    }

    func runRoutineNow(_ id: String) {
        guard let r = routines.first(where: { $0.id == id }) else { return }
        fire(r, extra: "")
    }

    private func fire(_ routine: Routine, extra: String) {
        var r = routine
        var chatId = r.chatId.flatMap { chat($0) != nil ? $0 : nil }
        if chatId == nil {
            do {
                var meta: ChatMeta
                switch r.target {
                case .bot(let id):
                    guard let b = bot(id) else { return }
                    meta = try chatStore.createChat(with: b)
                case .group(let id):
                    guard let g = group(id) else { return }
                    meta = try chatStore.createChat(with: g)
                }
                meta.title = "⏰ \(r.name)"
                try chatStore.save(meta)
                reloadChats()
                chatId = meta.id
            } catch {
                return
            }
        }
        guard let chatId, !isRunning(chatId) else { return }
        r.chatId = chatId
        r.lastRun = Date()
        saveRoutine(r)
        send(chatId: chatId, text: "⏰ \(r.message)\(extra)")
    }

    // MARK: - Error card actions

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
