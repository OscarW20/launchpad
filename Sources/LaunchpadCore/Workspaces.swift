import Foundation

/// A workspace keeps one area of work apart (Biscuit, Launchpad, a personal app). Each bot and each group belongs to
/// exactly one. Which one is kept by `WorkspaceStore`, not in group.json or bot.json, so nothing in a bot's own folder
/// changes and a bot can't move itself.
public struct Workspace: Codable, Identifiable, Hashable, Sendable {
    /// Where every bot and group is until you move it. Always exists and can't be deleted.
    public static let generalId = "general"

    public var id: String
    public var name: String
    public var colour: String
    public var icon: String
    public var createdAt: Date

    public init(id: String, name: String, colour: String = BotPalette.default, icon: String = "📁", createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.colour = colour
        self.icon = icon
        self.createdAt = createdAt
    }

    public static var general: Workspace {
        Workspace(id: generalId, name: "General", icon: "🗂️", createdAt: Date(timeIntervalSince1970: 0))
    }

    public var isGeneral: Bool { id == Self.generalId }
}

/// A bot made by "Duplicate into workspace": where it came from, so the bot's info can say "Copied from …".
public struct BotOrigin: Codable, Hashable, Sendable {
    public var botId: String
    public var workspaceId: String
}

/// `.launchpad/workspaces.json`.
public struct WorkspaceLayout: Codable, Equatable, Sendable {
    /// In the order they're shown. General is always first.
    public var workspaces: [Workspace]
    /// Only what was moved: anything missing (or pointing at a workspace that's gone) is in General.
    public var groups: [String: String]
    public var bots: [String: String]
    public var origins: [String: BotOrigin]

    public init(workspaces: [Workspace] = [.general], groups: [String: String] = [:], bots: [String: String] = [:],
                origins: [String: BotOrigin] = [:]) {
        self.workspaces = workspaces
        self.groups = groups
        self.bots = bots
        self.origins = origins
        normalise()
    }

    enum CodingKeys: String, CodingKey { case workspaces, groups, bots, origins }
    // Decoding is strict: a key that's missing is fine, one with the wrong type makes the file unreadable (never silently dropped).

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workspaces = (try c.decodeIfPresent([Workspace].self, forKey: .workspaces)) ?? []
        groups = (try c.decodeIfPresent([String: String].self, forKey: .groups)) ?? [:]
        bots = (try c.decodeIfPresent([String: String].self, forKey: .bots)) ?? [:]
        origins = (try c.decodeIfPresent([String: BotOrigin].self, forKey: .origins)) ?? [:]
        normalise()
    }

    /// General exists and comes first, ids are unique, and assignments to General or to a missing workspace are dropped.
    mutating func normalise() {
        var seen = Set<String>()
        var list = workspaces.filter { !$0.isGeneral && seen.insert($0.id).inserted }
        list.insert(.general, at: 0)
        if let saved = workspaces.first(where: { $0.isGeneral }) {
            list[0].name = saved.name.isEmpty ? "General" : saved.name
            list[0].colour = saved.colour
            list[0].icon = saved.icon
        }
        workspaces = list
        let ids = Set(list.map(\.id))
        groups = groups.filter { $0.value != Workspace.generalId && ids.contains($0.value) }
        bots = bots.filter { $0.value != Workspace.generalId && ids.contains($0.value) }
    }
}

public enum WorkspaceError: Error, LocalizedError, Equatable {
    case emptyName
    case notFound(String)
    case cantDeleteGeneral
    /// Deleting a workspace that still has things in it needs somewhere to put them.
    case notEmpty(bots: Int, groups: Int)
    /// A bot that's in a group can't move alone: move the group (its bots go with it).
    case botInGroups([String])
    /// Moving a group would pull a bot out of another group that stays behind. Say what to do with each.
    case sharedBots([SharedBot])
    case differentWorkspace(botId: String, groupId: String)
    /// Another workspace already has this name (ignoring case).
    case nameTaken(String)
    case sameWorkspace
    /// Taking the shared bots out would leave the group with nobody.
    case groupWouldBeEmpty(String)
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .emptyName: return "A workspace needs a name."
        case .notFound(let id): return "No workspace, bot or group called \(id)."
        case .cantDeleteGeneral: return "General can't be deleted."
        case .notEmpty(let b, let g): return "This workspace still has \(g) group\(g == 1 ? "" : "s") and \(b) bot\(b == 1 ? "" : "s"). Choose where they go first."
        case .botInGroups(let names): return "This bot is in \(names.joined(separator: ", ")). Move the group instead."
        case .sharedBots(let b): return "\(b.map(\.botId).joined(separator: ", ")) also belong to groups that aren't moving."
        case .differentWorkspace: return "That bot is in a different workspace. Duplicate it here instead."
        case .nameTaken(let n): return "There's already a workspace called \(n)."
        case .sameWorkspace: return "Choose a different workspace to move things into."
        case .groupWouldBeEmpty(let g): return "Taking those bots out would leave \(g) with no members. Copy them instead."
        case .unreadable: return "The workspaces file couldn't be read, so nothing was changed. Reset it from Manage Workspaces (the old file is kept) and everything shows in General."
        }
    }
}

/// A bot that moving a group would split from another group left behind.
public struct SharedBot: Hashable, Sendable {
    public var botId: String
    public var otherGroups: [String]
}

/// What to do with bots that are also in a group that isn't moving.
public enum SharedBotPolicy: Sendable {
    /// Stop and report them (`WorkspaceError.sharedBots`).
    case ask
    /// Put a copy in the new workspace for the moving group; the original stays with the other groups.
    case duplicate
    /// Take them out of the moving group; they stay where they are.
    case leaveOut
}

public struct MovedGroup: Sendable {
    public var group: BotGroup
    /// Bots that moved with it.
    public var movedBots: [String]
    /// Copies made for the group: original id to the new bot's id.
    public var duplicates: [String: String]
    /// Bots taken out of the group.
    public var leftOut: [String]
}

/// A mismatch the store found: a group with a member in another workspace (a hand edit, or a member added elsewhere).
public struct WorkspaceProblem: Hashable, Sendable {
    public var groupId: String
    public var botId: String
}

/// Where each bot and group lives. Saved as `workspaces.json` in Launchpad's data folder, which bots can't write.
/// Nothing is migrated on disk: with no file, or a file that doesn't mention a bot or group, it's in General.
public final class WorkspaceStore: @unchecked Sendable {
    public let file: URL
    private let paths: LaunchpadPaths
    private let botStore: BotStore
    private let groupStore: GroupStore
    private let fm: FileManager
    private let lock = NSLock()

    public init(paths: LaunchpadPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fm = fileManager
        file = paths.launchpadData.appendingPathComponent("workspaces.json")
        botStore = BotStore(paths: paths, fileManager: fileManager)
        groupStore = GroupStore(paths: paths, fileManager: fileManager)
    }

    // MARK: Reading

    /// Missing or unreadable means everything is in General.
    public func load() -> WorkspaceLayout {
        guard let data = try? Data(contentsOf: file) else { return WorkspaceLayout() }
        return (try? JSONCoding.decoder().decode(WorkspaceLayout.self, from: data)) ?? WorkspaceLayout()
    }

    public var workspaces: [Workspace] { load().workspaces }

    /// The file is there but can't be read. Until it's reset every bot and group shows in General, and changes are
    /// refused (`WorkspaceError.unreadable`) so the old file is never overwritten.
    public var isUnreadable: Bool {
        guard let data = try? Data(contentsOf: file) else { return false }
        return (try? JSONCoding.decoder().decode(WorkspaceLayout.self, from: data)) == nil
    }

    /// Sets an unreadable file aside (as `workspaces.unreadable-<time>.json`, kept for you) so everything starts in General.
    /// Returns where it went, or nil if the file was fine.
    @discardableResult
    public func resetUnreadable() throws -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard isUnreadable else { return nil }
        let stamp = Int(Date().timeIntervalSince1970)
        var aside = file.deletingLastPathComponent().appendingPathComponent("workspaces.unreadable-\(stamp).json")
        var n = 2
        while fm.fileExists(atPath: aside.path) {
            aside = file.deletingLastPathComponent().appendingPathComponent("workspaces.unreadable-\(stamp)-\(n).json"); n += 1
        }
        try fm.moveItem(at: file, to: aside)
        return aside
    }

    public func workspaceId(forBot id: String) -> String { load().bots[id] ?? Workspace.generalId }
    public func workspaceId(forGroup id: String) -> String { load().groups[id] ?? Workspace.generalId }

    /// A one-to-one chat is in its bot's workspace, a group chat in its group's.
    public func workspaceId(for chat: ChatMeta) -> String {
        let l = load()
        if chat.kind == .group, let g = chat.groupId { return l.groups[g] ?? Workspace.generalId }
        if let b = chat.botId { return l.bots[b] ?? Workspace.generalId }
        return Workspace.generalId
    }

    /// A routine runs in its target's workspace.
    public func workspaceId(for target: Routine.Target) -> String {
        switch target {
        case .bot(let id): return workspaceId(forBot: id)
        case .group(let id): return workspaceId(forGroup: id)
        }
    }

    public func bots(in workspaceId: String) -> [Bot] {
        let l = load()
        return botStore.loadAll().filter { (l.bots[$0.id] ?? Workspace.generalId) == workspaceId }
    }

    public func groups(in workspaceId: String) -> [BotGroup] {
        let l = load()
        return groupStore.loadAll().filter { (l.groups[$0.id] ?? Workspace.generalId) == workspaceId }
    }

    public func origin(ofBot id: String) -> BotOrigin? { load().origins[id] }

    /// Groups with a member that isn't in the group's workspace.
    public func problems() -> [WorkspaceProblem] {
        let l = load()
        var out: [WorkspaceProblem] = []
        for g in groupStore.loadAll() {
            let ws = l.groups[g.id] ?? Workspace.generalId
            for b in g.everyone where (l.bots[b] ?? Workspace.generalId) != ws { out.append(WorkspaceProblem(groupId: g.id, botId: b)) }
        }
        return out
    }

    /// Can this bot join this group? Only from the same workspace; otherwise offer "Duplicate it here".
    private func requireReadable() throws { if isUnreadable { throw WorkspaceError.unreadable } }

    public func canAdd(bot botId: String, toGroup groupId: String) -> Bool {
        workspaceId(forBot: botId) == workspaceId(forGroup: groupId)
    }

    // MARK: Workspaces

    @discardableResult
    public func create(name: String, colour: String = BotPalette.default, icon: String = "📁") throws -> Workspace {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw WorkspaceError.emptyName }
        return try mutate { l in
            if l.workspaces.contains(where: { Self.sameName($0.name, clean) }) { throw WorkspaceError.nameTaken(clean) }
            let id = Slug.unique(clean, taken: Set(l.workspaces.map(\.id)))
            let ws = Workspace(id: id, name: clean, colour: colour, icon: icon.isEmpty ? "📁" : icon)
            l.workspaces.append(ws)
            return ws
        }
    }

    /// Rename or restyle. General can be restyled and renamed, never deleted.
    public func update(_ workspace: Workspace) throws {
        let clean = workspace.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw WorkspaceError.emptyName }
        try mutate { l in
            guard let i = l.workspaces.firstIndex(where: { $0.id == workspace.id }) else { throw WorkspaceError.notFound(workspace.id) }
            if l.workspaces.contains(where: { $0.id != workspace.id && Self.sameName($0.name, clean) }) { throw WorkspaceError.nameTaken(clean) }
            l.workspaces[i].name = clean
            l.workspaces[i].colour = workspace.colour
            l.workspaces[i].icon = workspace.icon
        }
    }

    /// Reorder: ids not listed keep their place after the listed ones. General stays first.
    public func reorder(_ ids: [String]) throws {
        try mutate { l in
            let rest = l.workspaces.filter { !$0.isGeneral }
            let first = ids.compactMap { id in rest.first { $0.id == id } }
            let others = rest.filter { w in !first.contains { $0.id == w.id } }
            l.workspaces = [l.workspaces[0]] + first + others
        }
    }

    /// How many bots and groups a workspace holds (for the "still has things in it" prompt).
    public func counts(of workspaceId: String) -> (bots: Int, groups: Int) {
        let l = load()
        let b = botStore.loadAll().filter { (l.bots[$0.id] ?? Workspace.generalId) == workspaceId }.count
        let g = groupStore.loadAll().filter { (l.groups[$0.id] ?? Workspace.generalId) == workspaceId }.count
        return (b, g)
    }

    /// Deletes a workspace. If it still holds anything, `movingContentsTo` says where it all goes (whole, so groups keep
    /// their bots); without it that's an error and nothing changes. No bot, group, chat or memory is ever deleted.
    public func delete(id: String, movingContentsTo destination: String? = nil) throws {
        guard id != Workspace.generalId else { throw WorkspaceError.cantDeleteGeneral }
        let layout = load()
        guard layout.workspaces.contains(where: { $0.id == id }) else { throw WorkspaceError.notFound(id) }
        let held = counts(of: id)
        if held.bots + held.groups > 0 {
            guard let destination else { throw WorkspaceError.notEmpty(bots: held.bots, groups: held.groups) }
            guard destination != id else { throw WorkspaceError.sameWorkspace }
            guard layout.workspaces.contains(where: { $0.id == destination }) else { throw WorkspaceError.notFound(destination) }
        }
        try mutate { l in
            if let destination {
                for (k, v) in l.groups where v == id { l.groups[k] = destination }
                for (k, v) in l.bots where v == id { l.bots[k] = destination }
                for (k, o) in l.origins where o.workspaceId == id { l.origins[k]?.workspaceId = destination }
            }
            l.workspaces.removeAll { $0.id == id }
        }
    }

    // MARK: Moving

    /// Moves a bot that isn't in any group (a one-to-one bot). A bot in groups moves with its group.
    public func move(bot botId: String, to workspaceId: String) throws {
        let groups = groupStore.loadAll().filter { $0.everyone.contains(botId) }
        let current = workspaceId == self.workspaceId(forBot: botId)
        let blocking = groups.filter { self.workspaceId(forGroup: $0.id) == self.workspaceId(forBot: botId) }
        if !current, !blocking.isEmpty { throw WorkspaceError.botInGroups(blocking.map(\.name)) }
        guard (try? botStore.load(id: botId)) != nil else { throw WorkspaceError.notFound(botId) }
        try mutate { l in
            guard l.workspaces.contains(where: { $0.id == workspaceId }) else { throw WorkspaceError.notFound(workspaceId) }
            Self.assign(&l.bots, botId, workspaceId)
        }
    }

    /// Which bots moving this group would split from another group that stays behind.
    public func sharedBots(movingGroup groupId: String, to workspaceId: String) throws -> [SharedBot] {
        let group = try groupStore.load(id: groupId)
        let l = load()
        let from = l.groups[groupId] ?? Workspace.generalId
        guard from != workspaceId else { return [] }
        let others = groupStore.loadAll().filter { $0.id != groupId && (l.groups[$0.id] ?? Workspace.generalId) == from }
        return group.everyone.compactMap { b in
            guard (l.bots[b] ?? Workspace.generalId) == from else { return nil }
            let stay = others.filter { $0.everyone.contains(b) }.map(\.id)
            return stay.isEmpty ? nil : SharedBot(botId: b, otherGroups: stay)
        }
    }

    /// Moves a group and its bots together.
    @discardableResult
    public func move(group groupId: String, to workspaceId: String, shared policy: SharedBotPolicy = .ask) throws -> MovedGroup {
        try requireReadable()
        var group = try groupStore.load(id: groupId)
        guard load().workspaces.contains(where: { $0.id == workspaceId }) else { throw WorkspaceError.notFound(workspaceId) }
        let shared = try sharedBots(movingGroup: groupId, to: workspaceId)
        if !shared.isEmpty, policy == .ask { throw WorkspaceError.sharedBots(shared) }
        let sharedIds = Set(shared.map(\.botId))
        if policy == .leaveOut, !sharedIds.isEmpty, group.everyone.allSatisfy(sharedIds.contains) { throw WorkspaceError.groupWouldBeEmpty(group.name) }

        var duplicates: [String: String] = [:]
        var leftOut: [String] = []
        if policy == .duplicate {
            for id in sharedIds.sorted() { duplicates[id] = try duplicate(bot: id, into: workspaceId).id }
        } else if policy == .leaveOut {
            leftOut = sharedIds.sorted()
        }
        // Membership first: a copy replaces the original, a bot left out is dropped (the lead falls back to the first member).
        let swap = { (id: String) -> String? in sharedIds.contains(id) ? duplicates[id] : id }
        group.members = group.members.compactMap(swap)
        group.lead = group.lead.flatMap(swap) ?? group.members.first
        if let lead = group.lead, !group.members.contains(lead) { group.members.insert(lead, at: 0) }
        try groupStore.save(group)

        let moving = group.everyone
        try mutate { l in
            Self.assign(&l.groups, groupId, workspaceId)
            for b in moving { Self.assign(&l.bots, b, workspaceId) }
        }
        return MovedGroup(group: group, movedBots: moving.filter { !duplicates.values.contains($0) }, duplicates: duplicates, leftOut: leftOut)
    }

    // MARK: Duplicating

    /// A copy of a bot in `workspaceId`: same name, role, engine, rules, connectors, skills and instructions, but its own
    /// folder, its own memory (starting empty) and no sessions, so it knows nothing the original does.
    @discardableResult
    public func duplicate(bot botId: String, into workspaceId: String) throws -> Bot {
        try requireReadable()
        let source = try botStore.load(id: botId)
        guard load().workspaces.contains(where: { $0.id == workspaceId }) else { throw WorkspaceError.notFound(workspaceId) }
        try paths.ensureStructure(fileManager: fm)
        let taken = Set((try? fm.contentsOfDirectory(atPath: paths.bots.path)) ?? [])
        var copy = source
        copy.id = Slug.unique(source.name, taken: taken)
        copy.createdAt = Date()
        try fm.createDirectory(at: paths.workspace(copy.id), withIntermediateDirectories: true)
        try botStore.save(copy)
        try botStore.setInstructions(botStore.instructions(for: source.id), for: copy.id)
        try Data(Instructions.memoryTemplate(for: copy).utf8).write(to: paths.memoryMD(copy.id), options: .atomic)
        try mutate { l in
            Self.assign(&l.bots, copy.id, workspaceId)
            l.origins[copy.id] = BotOrigin(botId: source.id, workspaceId: l.bots[source.id] ?? Workspace.generalId)
        }
        return copy
    }

    // MARK: Internals

    private static func sameName(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(b) == .orderedSame
    }

    private static func assign(_ map: inout [String: String], _ id: String, _ workspaceId: String) {
        if workspaceId == Workspace.generalId { map.removeValue(forKey: id) } else { map[id] = workspaceId }
    }

    @discardableResult
    private func mutate<T>(_ change: (inout WorkspaceLayout) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        var layout: WorkspaceLayout
        if let data = try? Data(contentsOf: file) {
            guard let decoded = try? JSONCoding.decoder().decode(WorkspaceLayout.self, from: data) else { throw WorkspaceError.unreadable }
            layout = decoded
        } else {
            layout = WorkspaceLayout()
        }
        let result = try change(&layout)
        layout.normalise()
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Keep the last good file next to it, so a bad write can always be undone by hand.
        if fm.fileExists(atPath: file.path) {
            let backup = file.deletingLastPathComponent().appendingPathComponent("workspaces.json.bak")
            try? fm.removeItem(at: backup)
            try? fm.copyItem(at: file, to: backup)
        }
        try JSONCoding.encoder().encode(layout).write(to: file, options: .atomic)
        return result
    }
}
