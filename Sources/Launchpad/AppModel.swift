#if os(macOS)
import SwiftUI
import AppKit
import Observation
import LaunchpadCore

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case chats, bots, groups, hire, skills, connectors, tasks, workflows, routines, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chats: return "Chats"
        case .bots: return "Bots"
        case .groups: return "Groups"
        case .hire: return "Marketplace"
        case .skills: return "Skills"
        case .connectors: return "Connectors"
        case .tasks: return "Tasks"
        case .workflows: return "Workflows"
        case .routines: return "Routines"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .chats: return "bubble.left.and.bubble.right"
        case .bots: return "face.smiling"
        case .groups: return "person.3"
        case .hire: return "bag"
        case .skills: return "sparkles"
        case .connectors: return "powerplug"
        case .tasks: return "checklist"
        case .workflows: return "flowchart"
        case .routines: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }

    var blurb: String {
        switch self {
        case .chats: return "Your conversations with bots and groups."
        case .bots: return "Your AI teammates. Each one is a folder in ~/Launchpad/bots."
        case .groups: return "Put bots in a group with a lead. You post a task; the lead hands work out by @mention."
        case .hire: return "Ready-made teams, roles, skills and apps you can add in one click."
        case .skills: return "Your skill library. Give skills to bots or whole groups; Claude Code and Codex find them automatically."
        case .connectors: return "MCP servers your bots can use. Tokens are kept in your Keychain, never in files."
        case .tasks: return "Hand a job to a bot or group and see how it's going. Workflow approvals wait here too."
        case .workflows: return "Steps that pass work from bot to bot, run by hand or on a schedule."
        case .routines: return "Send a message to a bot or group on a schedule, when a file appears, or when its web address is called. Runs while Launchpad is open."
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
    /// Approval cards the guard raised during this reply.
    var approvals: [LiveApproval] = []

    /// The reply so far, with its approval cards.
    var message: ChatMessage {
        var m = builder.message
        m.liveApprovals = approvals.isEmpty ? nil : approvals
        return m
    }
}

/// What a reply needs to start: its engine options, and what to tidy up when it ends.
struct RunSetup {
    var options = RunOptions()
    /// Where this reply's approval cards appear (nil: no live approvals).
    var askBase: URL?
    /// The site gateway token for a locked-down bot.
    var gatewayToken: String?
    /// Why the bot mustn't run (shown instead of a reply).
    var refusal: String?
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
    let memory: MemoryStore
    let reviewer: MemoryReviewer

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
    var selectedTaskId: String?
    var selectedWorkflowId: String?

    // Safety
    /// Skills locked so bots can't change them.
    var lockedSkills: Set<String> = []
    /// Settings: let "Always allow" cover sends, deletes, spending and changes.
    var alwaysForWrites: Bool = UserDefaults.standard.object(forKey: "alwaysForWrites") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(alwaysForWrites, forKey: "alwaysForWrites")
            rewriteAllGuardRules()
        }
    }
    let inbox: ApprovalInbox
    /// Undo snapshots (nil until git has been found, or if it isn't installed).
    var snapshots: Snapshots?

    // Routines & work
    /// Folder routines whose folder isn't there right now.
    var unavailableFolders: Set<String> = []
    /// A problem with the web address listener, shown on web address routines.
    var webhookStatus: String?
    /// Bumped whenever tasks, workflows or runs change, so views refresh.
    var workRevision = 0
    let workflowEngine: WorkflowEngine
    @ObservationIgnored let folderTriggers = FolderTriggers()
    @ObservationIgnored var webhookListener: LoopbackHTTPListener?
    @ObservationIgnored var webhookTokens: [String: String] = [:]
    @ObservationIgnored var webhookLimiter = WebhookLimiter()

    @ObservationIgnored private var handles: [String: RunHandle] = [:]
    @ObservationIgnored private var runChats: [String: String] = [:]
    @ObservationIgnored private var chatTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var teachHandle: RunHandle?
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var routineTimer: Timer?
    @ObservationIgnored private var folderTimer: Timer?
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
        memory = MemoryStore(paths: paths)
        reviewer = MemoryReviewer(paths: paths, store: memory, engine: MemoryReviewer.engine(using: runner))
        inbox = ApprovalInbox(paths: paths)
        workflowEngine = WorkflowEngine(store: WorkStore(paths: paths))
        do {
            try paths.ensureStructure()
        } catch {
            alertMessage = "Launchpad couldn't create its folder at \(paths.root.path). \(error.localizedDescription)"
        }
        skillStore.seedStarterSkillsIfNeeded()
        lockedSkills = SkillLocks(paths: paths).load()
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
        workflowEngine.executor = self
        workflowEngine.onChange = { [weak self] in self?.workRevision += 1 }
        workflowEngine.load()
        startRoutines()
        refreshEngines()
        rewriteAllGuardRules()
        // Finding git can take a moment (it may read your login shell's PATH), so it's done off the main thread.
        let p = paths
        Task.detached(priority: .utility) {
            let s = Snapshots(paths: p)
            await MainActor.run { [weak self] in self?.snapshots = s.available ? s : nil }
        }
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
        for bot in loaded {
            _ = memory.importNotesIfNeeded(bot)
            botStore.syncInstructions(for: bot.id)
        }
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

    func targetExists(_ target: Routine.Target) -> Bool {
        switch target {
        case .bot(let id): return bot(id) != nil
        case .group(let id): return group(id) != nil
        }
    }

    func targetName(_ target: Routine.Target) -> String {
        switch target {
        case .bot(let id): return bot(id)?.name ?? id
        case .group(let id): return group(id)?.displayName ?? id
        }
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
            writeGuardRules(for: self.bot(bot.id) ?? bot)
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

    func hireTeam(_ pack: TeamPack) {
        do {
            let (_, group) = try Hiring(paths: paths).hireTeam(pack)
            reloadAll()
            openChat(with: group)
        } catch {
            alertMessage = "Couldn't add \(pack.name): \(error.localizedDescription)"
        }
    }

    func installSkill(_ skill: CatalogSkill) {
        do {
            _ = try skillStore.install(skill)
            reloadSkills()
            relinkSkills()
        } catch {
            alertMessage = "Couldn't add \(skill.name): \(error.localizedDescription)"
        }
    }

    /// Adds an app from the marketplace. Returns an error message to show, or nil.
    func installApp(_ preset: ConnectorPreset, settings: [String: String], secrets values: [String: String]) -> String? {
        do {
            let c = try connectorStore.install(preset, settings: settings)
            try ConnectorStore.storeSecrets(values, for: preset, connector: c, in: secrets)
            reloadConnectors()
            return nil
        } catch {
            return error.localizedDescription
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
        reviewer.forget(chatId: id)
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

    @discardableResult
    func startSolo(_ chatId: String, bot: Bot, prompt: String) -> Task<Void, Never> {
        busyChats.insert(chatId)
        let task = Task { @MainActor [weak self] in
            _ = await self?.runBotTurn(chatId: chatId, bot: bot, prompt: prompt)
            self?.chatTasks[chatId] = nil
            self?.busyChats.remove(chatId)
        }
        chatTasks[chatId] = task
        return task
    }

    @discardableResult
    func startGroup(_ chatId: String, _ body: @escaping @Sendable (GroupOrchestrator) async -> GroupOutcome) -> Task<Void, Never>? {
        guard let meta = chat(chatId), let group = group(meta.groupId) else {
            append(ChatMessage(role: .notice, text: "This group isn't in your Launchpad folder any more."), to: chatId)
            return nil
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
        let task = Task { @MainActor [weak self] in
            let outcome = await body(orchestrator)
            self?.groupFinished(chatId, group: group, outcome: outcome)
            self?.chatTasks[chatId] = nil
            self?.busyChats.remove(chatId)
        }
        chatTasks[chatId] = task
        return task
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
        case .undoMemory:
            break
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

    /// Engine options for one reply, with the safety guard, sandbox and site gateway set up.
    private func prepareRun(for bot: Bot, chat: ChatMeta, runId: String) -> RunSetup {
        var setup = RunSetup()
        var o = RunOptions()
        let available = Set(skills.map(\.id))
        let botSkills = SkillLinker.effectiveSkills(for: bot, groups: groups).filter(available.contains)
        let lockedNames = botSkills.filter(lockedSkills.contains)
        o.manageConnectors = true
        o.connectors = MCPConfig.effective(for: bot, groups: groups, all: connectors)
        o.environment = MCPConfig.environment(o.connectors, secrets: secrets, engine: bot.engine)
        if chat.kind == .group, let gid = chat.groupId {
            try? FileManager.default.createDirectory(at: groupStore.workspace(gid), withIntermediateDirectories: true)
            o.addDirectories = [groupStore.dir(gid)]
        }

        var liveApprovals = false
        if bot.engine == .claude {
            if let guardURL = guardExecutable, let rules = writeGuardRules(for: bot) {
                let base = inbox.base(chatId: chat.id, runId: runId)
                o.guardHook = GuardHookSetup(helper: guardURL.path, rulesFile: rules.path, askBase: base.path,
                                             approvalsDir: grants.directory.path)
                setup.askBase = base
                liveApprovals = true
            } else if bot.rules.hasCustomRules || !lockedNames.isEmpty {
                setup.refusal = "Couldn't start the safety check, so \(bot.name) didn't run."
                return setup
            } else if let guardURL = guardExecutable {
                o.guardCommand = "\"\(guardURL.path)\" --approvals \"\(grants.directory.path)\""
            }
        }
        var system = LaunchpadProtocol.text(skills: botSkills, liveApprovals: liveApprovals)
        if bot.engine == .codex {
            let note = bot.rules.codexNote(lockedSkills: lockedNames)
            if !note.isEmpty { system += "\n" + note }
        }

        if bot.lockedDown && !BotSandbox.available {
            setup.refusal = "\(bot.name) is locked down, which needs macOS's sandbox, and it isn't available here, so \(bot.name) didn't run."
            return setup
        }
        if BotSandbox.available { o.sandboxProfile = BotSandbox(bot: bot, paths: paths).profile() }
        if bot.lockedDown {
            let port = SiteGateway.shared.start()
            guard port != 0 else {
                setup.refusal = "Couldn't start the site gateway a locked-down bot needs, so \(bot.name) didn't run."
                return setup
            }
            let sites = BotSandbox.allowedSites(for: bot, connectors: o.connectors)
            let token = SiteGateway.shared.issue(sites: sites)
            o.environment.merge(SiteGateway.proxyEnvironment(port: port, token: token)) { _, new in new }
            setup.gatewayToken = token
            system += "\n- You're locked down: you can reach only these websites: \(sites.joined(separator: ", ")). Anything else is blocked, so don't retry it; tell me instead."
        }
        o.systemAppend = system
        setup.options = o
        return setup
    }

    /// Runs one bot in a chat, streams its reply into the chat, saves it, and returns it.
    func runBotTurn(chatId: String, bot: Bot, prompt: String, allowFreshRetry: Bool = true) async -> ChatMessage {
        guard let meta = chat(chatId) else { return ChatMessage(role: .bot, botId: bot.id, status: .stopped) }
        botStore.syncInstructions(for: bot.id)
        let runId = UUID().uuidString.lowercased()
        let setup = prepareRun(for: bot, chat: meta, runId: runId)
        if let refusal = setup.refusal {
            let m = ChatMessage(role: .bot, botId: bot.id, status: .failed, failure: RunFailure(kind: .unknown, message: refusal))
            append(m, to: chatId)
            return m
        }

        // Undo: snapshot the bot's folder first (off the main thread; it's git).
        let folder = paths.botDir(bot.id)
        let snaps = snapshots
        let botId = bot.id
        var snapshot: String?
        if let snaps {
            snapshot = await Task.detached(priority: .userInitiated) {
                snaps.take(botId: botId, folder: folder)
            }.value
        }

        let invocation = EngineCommand.invocation(
            for: bot, prompt: prompt, botDirectory: folder, sessionId: meta.sessions[bot.id], options: setup.options
        )
        let handle = runner.run(invocation)
        handles[runId] = handle
        runChats[runId] = chatId
        live[chatId, default: []].append(LiveRun(id: runId, botId: bot.id, builder: MessageBuilder(botId: bot.id)))
        if Task.isCancelled { handle.cancel() }

        // Approval cards: look for new ones while the reply streams.
        var poller: Task<Void, Never>?
        if let base = setup.askBase {
            poller = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.collectApprovals(chatId: chatId, runId: runId, base: base, botId: botId)
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }

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

        poller?.cancel()
        if let base = setup.askBase {
            collectApprovals(chatId: chatId, runId: runId, base: base, botId: botId)
            let ids = live[chatId]?.first { $0.id == runId }?.approvals.map(\.id) ?? []
            inbox.close(base: base, ids: ids)
        }
        if let token = setup.gatewayToken { SiteGateway.shared.revoke(token) }

        var changed: [String] = []
        if let snapshot, let snaps {
            changed = await Task.detached(priority: .userInitiated) {
                snaps.changes(botId: botId, folder: folder, since: snapshot)
            }.value
        }

        let run = live[chatId]?.first { $0.id == runId }
        let builder = run?.builder ?? MessageBuilder(botId: bot.id)
        live[chatId]?.removeAll { $0.id == runId }
        if live[chatId]?.isEmpty == true { live[chatId] = nil }
        handles[runId] = nil
        runChats[runId] = nil

        var message = builder.message
        let cards = (run?.approvals ?? []).map { card -> LiveApproval in
            var c = card
            if c.state == .pending { c.state = .expired }
            return c
        }
        message.liveApprovals = cards.isEmpty ? nil : cards
        if !changed.isEmpty {
            message.snapshot = snapshot
            message.changedFiles = changed
        }
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
        noteMemoryActivity(chatId)

        if message.status == .done || message.status == .stopped,
           let sessionId = builder.sessionId, var meta = chat(chatId), meta.sessions[bot.id] != sessionId {
            meta.sessions[bot.id] = sessionId
            save(meta)
        }
        return message
    }

    /// Picks up the guard's new approval cards (and ones it gave up on) for a reply that's running.
    private func collectApprovals(chatId: String, runId: String, base: URL, botId: String) {
        let found = inbox.collect(base: base)
        guard !found.new.isEmpty || !found.expired.isEmpty,
              let i = live[chatId]?.firstIndex(where: { $0.id == runId }) else { return }
        let rules = bot(botId)?.rules ?? BotRules()
        for card in found.new {
            var item = LiveApproval(card)
            // "Always allow" given meanwhile (in another chat, say): answer it straight away.
            if canAlwaysAllow(item, botId: botId), rules.alwaysAllowed.contains(item.key),
               (try? inbox.answer(card.id, .always)) != nil {
                item.state = .always
            }
            live[chatId]?[i].approvals.append(item)
        }
        for id in found.expired {
            if let j = live[chatId]?[i].approvals.firstIndex(where: { $0.id == id && $0.state == .pending }) {
                live[chatId]?[i].approvals[j].state = .expired
            }
        }
    }

    /// Whether an approval card may offer "Always allow": never for the Terminal, and not for writes when that's
    /// switched off in Settings or the bot is locked down.
    func canAlwaysAllow(_ card: LiveApproval, botId: String?) -> Bool {
        guard card.offersAlways, let kind = card.kind else { return false }
        let locked = bot(botId)?.lockedDown ?? false
        return !ApprovalCategory.writes.contains(kind) || (alwaysForWrites && !locked)
    }

    /// Approve / Decline / Always allow on a live approval card.
    func answerApproval(_ cardId: String, in chatId: String, _ answer: ApprovalAnswer) {
        guard let runs = live[chatId],
              let i = runs.firstIndex(where: { $0.approvals.contains { $0.id == cardId } }),
              let j = runs[i].approvals.firstIndex(where: { $0.id == cardId }),
              runs[i].approvals[j].state == .pending else { return }
        let botId = runs[i].botId
        var card = runs[i].approvals[j]
        var answer = answer
        if answer == .always && !canAlwaysAllow(card, botId: botId) { answer = .approve }
        do {
            try inbox.answer(card.id, answer)
        } catch {
            alertMessage = "Couldn't pass on your answer: \(error.localizedDescription)"
            return
        }
        switch answer {
        case .approve: card.state = .approved
        case .deny: card.state = .denied
        case .always: card.state = .always
        }
        live[chatId]?[i].approvals[j] = card

        guard answer == .always, let kind = card.kind, var b = bot(botId) else { return }
        b.rules.alwaysAllow(kind, tool: card.tool)
        do {
            try botStore.save(b)
        } catch {
            alertMessage = "Couldn't save \(b.name)'s permissions: \(error.localizedDescription)"
        }
        reloadBots()
        writeGuardRules(for: b)
        // Other cards waiting on the same thing for this bot get the same answer.
        for (cid, list) in live {
            for (ri, run) in list.enumerated() where run.botId == botId {
                for (ci, other) in run.approvals.enumerated() where other.state == .pending && other.key == card.key {
                    if (try? inbox.answer(other.id, .always)) != nil { live[cid]?[ri].approvals[ci].state = .always }
                }
            }
        }
    }

    /// Writes the bot's rules file for the guard. nil if it couldn't be written.
    @discardableResult
    func writeGuardRules(for bot: Bot) -> URL? {
        let skillIds = SkillLinker.effectiveSkills(for: bot, groups: groups)
        let lockedDirs = SkillLocks.lockedDirs(skillIds: skillIds, locked: lockedSkills, paths: paths, botId: bot.id)
        // Every group folder it works in, so a rules file written for one chat suits the others too.
        let extra = groups(containing: bot.id).map { groupStore.dir($0.id) }
        let cfg = GuardRulesFile.config(for: bot, paths: paths, extraRoots: extra, lockedSkillDirs: lockedDirs,
                                        alwaysForWrites: alwaysForWrites, trustedServers: [])
        return try? GuardRulesFile.write(cfg, botId: bot.id, paths: paths)
    }

    func rewriteAllGuardRules() {
        for b in bots { writeGuardRules(for: b) }
    }

    func setSkillLocked(_ id: String, _ on: Bool) {
        do {
            try SkillLocks(paths: paths).setLocked(id, on)
        } catch {
            alertMessage = "Couldn't change the skill lock: \(error.localizedDescription)"
        }
        lockedSkills = SkillLocks(paths: paths).load()
        rewriteAllGuardRules()
    }

    /// Undo on a reply: puts the bot's folder back as it was before the reply.
    func undoReply(_ messageId: String, in chatId: String) {
        guard let list = messages[chatId], let i = list.firstIndex(where: { $0.id == messageId }),
              let snapshot = list[i].snapshot, let botId = list[i].botId, list[i].undone != true,
              let snaps = snapshots else { return }
        if live.values.contains(where: { runs in runs.contains { $0.botId == botId } }) {
            alertMessage = "\(bot(botId)?.name ?? "This bot") is working right now. Undo once it's finished."
            return
        }
        let folder = paths.botDir(botId)
        let count = list[i].changedFiles?.count ?? 0
        let name = bot(botId)?.name ?? "the bot"
        Task { @MainActor [weak self] in
            let ok = await Task.detached(priority: .userInitiated) {
                snaps.undo(botId: botId, folder: folder, to: snapshot)
            }.value
            guard let self else { return }
            guard ok else {
                self.alertMessage = "Couldn't undo those changes. Nothing was changed."
                return
            }
            if let j = self.messages[chatId]?.firstIndex(where: { $0.id == messageId }) {
                self.messages[chatId]?[j].undone = true
                if let m = self.messages[chatId]?[j] { try? self.chatStore.append(m, chatId: chatId) }
            }
            self.append(ChatMessage(role: .notice, text: "Undid \(count) file change\(count == 1 ? "" : "s") from \(name)'s reply."), to: chatId)
        }
    }

    func append(_ message: ChatMessage, to chatId: String) {
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

    func save(_ meta: ChatMeta) {
        try? chatStore.save(meta)
        sessionRegistry.set(meta)
        if let i = chats.firstIndex(where: { $0.id == meta.id }) { chats[i] = meta } else { chats.append(meta) }
        chats.sort { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Memory

    /// Whose memory a chat feeds: the chat's bot, or a group's lead.
    private func memoryOwner(_ chatId: String) -> String? {
        guard let meta = chat(chatId) else { return nil }
        return meta.kind == .bot ? meta.botId : group(meta.groupId)?.lead
    }

    private func noteMemoryActivity(_ chatId: String) {
        if let owner = memoryOwner(chatId) { reviewer.noteActivity(chatId: chatId, botId: owner) }
    }

    @ObservationIgnored private var memoryTask: Task<Void, Never>?

    /// Runs at most one memory pass when a chat has gone quiet.
    private func checkMemory() {
        guard memoryTask == nil else { return }
        let busy = Set(chats.map(\.id).filter { isRunning($0) })
        guard let ticket = reviewer.duePasses(busy: busy).first, let bot = bot(ticket.botId) else { return }
        loadMessagesIfNeeded(ticket.chatId)
        let msgs = messages(for: ticket.chatId)
        let names = Dictionary(bots.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let reviewer = self.reviewer
        memoryTask = Task { @MainActor [weak self] in
            let result = await reviewer.run(ticket, bot: bot, messages: msgs) { names[$0 ?? ""] ?? "Bot" }
            if case .updated(let update) = result {
                self?.append(ChatMessage(id: update.id, role: .notice, text: update.summary, noticeAction: .undoMemory), to: ticket.chatId)
            }
            self?.memoryTask = nil
        }
    }

    func undoMemoryUpdate(noticeId: String, chatId: String) {
        guard let update = memory.update(id: noticeId) else { return }
        let changed = memory.undo(update) ?? 0
        if let list = messages[chatId], let i = list.firstIndex(where: { $0.id == noticeId }) {
            var notice = list[i]
            notice.noticeAction = nil
            notice.text += changed > 0 ? " (undone)" : " (nothing left to undo)"
            messages[chatId]?[i] = notice
            try? chatStore.append(notice, chatId: chatId)
        }
    }

    // MARK: - Routines

    private func startRoutines() {
        // Take a first look at watched folders so files already there don't count as new.
        folderTriggers.prime(routines)
        routineTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkRoutines()
                self?.checkMemory()
            }
        }
        folderTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollFolders() }
        }
        syncWebhookListener()
    }

    func checkRoutines(now: Date = Date()) {
        let tick = RoutineSchedule.tick(routines, now: now) { [self] in targetExists($0) }
        if tick.routines != routines { saveRoutines(tick.routines) }
        for event in tick.events {
            switch event {
            case .due(let id):
                fire(id, payload: nil)
            case let .catchUp(id, missed, last):
                let name = routines.first { $0.id == id }?.name ?? "Routine"
                fire(id, payload: nil, notice: RoutineSchedule.missedNotice(name: name, missed: missed, last: last, caughtUp: true, now: now))
            case let .missed(id, missed, last):
                guard let r = routines.first(where: { $0.id == id }) else { continue }
                let text = RoutineSchedule.missedNotice(name: r.name, missed: missed, last: last, caughtUp: false, now: now)
                if let chatId = r.lastRunChat ?? r.chatId, chat(chatId) != nil {
                    append(ChatMessage(role: .notice, text: text), to: chatId)
                }
            }
        }
        workflowEngine.reloadWorkflows()
        workflowEngine.startDue(now: now)
        syncWebhookListener()
    }

    private func pollFolders() {
        let poll = folderTriggers.poll(routines, now: Date())
        if poll.unavailable != unavailableFolders { unavailableFolders = poll.unavailable }
        for (id, files) in poll.runs {
            guard let folder = routines.first(where: { $0.id == id })?.watchedFolder else { continue }
            fire(id, payload: RoutinePayload.files(files, folder: folder))
        }
    }

    func newRoutine() {
        guard let target: Routine.Target = bots.first.map({ .bot($0.id) }) ?? groups.first.map({ .group($0.id) }) else {
            alertMessage = "Add a bot or group first, so the routine has someone to message."
            return
        }
        let r = Routine(id: Slug.unique("routine", taken: Set(routines.map(\.id))), name: "New routine", target: target,
                        message: "Give me a short update on what you're working on.", trigger: .daily(hour: 9, minute: 0, weekdaysOnly: true),
                        enabled: false, catchUp: true, ownChat: false)
        saveRoutines(routines + [r.preparedForSave(stored: nil)])
        selectedRoutineId = r.id
    }

    /// Saves a routine from the editor: what running it changed meanwhile is kept.
    func saveEditedRoutine(_ edited: Routine) {
        let stored = routines.first { $0.id == edited.id }
        let r = edited.preparedForSave(stored: stored)
        saveRoutine(r)
        // A newly watched folder: files already in it don't count.
        if let folder = r.watchedFolder, r.enabled, stored?.watchedFolder != folder || stored?.enabled != true {
            folderTriggers.prime([r])
        }
        syncWebhookListener()
    }

    func saveRoutine(_ r: Routine) {
        var all = routines
        if let i = all.firstIndex(where: { $0.id == r.id }) { all[i] = r } else { all.append(r) }
        saveRoutines(all)
    }

    func deleteRoutine(_ id: String) {
        saveRoutines(routines.filter { $0.id != id })
        WebhookSecrets.forget(id, in: secrets)
        webhookTokens[id] = nil
        if selectedRoutineId == id { selectedRoutineId = nil }
        syncWebhookListener()
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
        fire(id, payload: nil)
    }

    /// Missed runs: don't catch up.
    func skipMissed(_ id: String) {
        guard var r = routines.first(where: { $0.id == id }) else { return }
        r.skipMissed()
        saveRoutine(r)
    }

    /// A new chat for a bot or group, without switching to it.
    func makeChat(for target: Routine.Target, title: String) -> String? {
        do {
            var meta: ChatMeta
            switch target {
            case .bot(let id):
                guard let b = bot(id) else { return nil }
                meta = try chatStore.createChat(with: b)
            case .group(let id):
                guard let g = group(id) else { return nil }
                meta = try chatStore.createChat(with: g)
            }
            meta.title = title
            try chatStore.save(meta)
            reloadChats()
            return meta.id
        } catch {
            alertMessage = "Couldn't start a chat: \(error.localizedDescription)"
            return nil
        }
    }

    /// Runs a routine: sends its message (with what set it off) to its bot or group.
    func fire(_ id: String, payload: String?, notice: String? = nil) {
        guard var r = routines.first(where: { $0.id == id }) else { return }
        let now = Date()
        let chatId: String
        if r.runsInOwnChat {
            guard let made = makeChat(for: r.target, title: r.runChatTitle(at: now)) else { return }
            chatId = made
        } else if let existing = r.chatId, chat(existing) != nil {
            chatId = existing
        } else {
            guard let made = makeChat(for: r.target, title: "⏰ \(r.name)") else { return }
            chatId = made
        }
        // Still busy with the last run: a clock routine tries again on the next tick.
        guard !isRunning(chatId) else { return }
        let text = r.runMessage(payload: payload)
        let drop = r.markRan(at: now, chatId: chatId) { [self] in isRunning($0) }
        for old in drop where old != chatId { deleteChat(old) }
        saveRoutine(r)
        if let notice { append(ChatMessage(role: .notice, text: notice), to: chatId) }
        send(chatId: chatId, text: text)
        workflowEngine.record(RunLogEntry(kind: .routine, name: r.name, target: r.target, sourceId: r.id, chatId: chatId, date: now))
    }

    // MARK: - Web address routines

    /// Listens on 127.0.0.1 only while a web address routine is switched on.
    func syncWebhookListener() {
        let hooks = routines.filter { $0.enabled && $0.isWebhook }
        for r in hooks where webhookTokens[r.id] == nil {
            if let t = WebhookSecrets.token(for: r.id, in: secrets) { webhookTokens[r.id] = t }
        }
        guard !hooks.isEmpty else {
            webhookListener?.stop()
            webhookListener = nil
            if webhookStatus != nil { webhookStatus = nil }
            return
        }
        guard webhookListener?.isListening != true else { return }
        let listener = LoopbackHTTPListener { [weak self] req in
            let out: HTTPResponse? = await MainActor.run { self?.handleWebhook(req) }
            return out ?? .error(503, "Launchpad is closing.")
        }
        do {
            _ = try listener.start(port: WebhookAuth.port)
            webhookListener = listener
            if webhookStatus != nil { webhookStatus = nil }
        } catch {
            webhookListener = nil
            webhookStatus = "Couldn't listen on port \(WebhookAuth.port): \(error.localizedDescription) Launchpad tries again every 20 seconds."
        }
    }

    func handleWebhook(_ req: HTTPRequest) -> HTTPResponse {
        let out = WebhookRouter.handle(req, routines: routines, secrets: webhookTokens, limiter: &webhookLimiter,
                                       now: Date()) { [self] in targetExists($0) }
        if let run = out.run { fire(run.id, payload: run.payload) }
        return out.response
    }

    /// The routine's web address secret (made the first time). nil: the Keychain didn't answer.
    func webhookToken(_ id: String) -> String? {
        if let t = webhookTokens[id] { return t }
        let t = WebhookSecrets.token(for: id, in: secrets)
        webhookTokens[id] = t
        return t
    }

    /// A new secret: the old one stops working.
    @discardableResult
    func newWebhookSecret(_ id: String) -> String? {
        guard let t = WebhookSecrets.reset(for: id, in: secrets) else {
            alertMessage = "Couldn't save a new secret to your Keychain. Try again."
            return nil
        }
        webhookTokens[id] = t
        return t
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
