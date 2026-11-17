import Foundation

/// groups/<id>/group.json, plus SUMMARY.md (kept by the lead) and workspace/ (shared project folder).
public struct BotGroup: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var emoji: String
    public var members: [String]
    public var lead: String?
    public var rules: String
    public var handoffLimit: Int
    public var skills: [String]
    public var connectors: [String]
    /// "Ask me" (the default) or "Full freedom": see `ApprovalMode`.
    public var approvals: ApprovalMode
    public var createdAt: Date

    public init(
        id: String, name: String, emoji: String = "👥", members: [String] = [], lead: String? = nil,
        rules: String = "", handoffLimit: Int = 3, skills: [String] = [], connectors: [String] = [],
        approvals: ApprovalMode = .ask, createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.members = members
        self.lead = lead
        self.rules = rules
        self.handoffLimit = handoffLimit
        self.skills = skills
        self.connectors = connectors
        self.approvals = approvals
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, emoji, members, lead, rules, handoffLimit, skills, connectors, approvals, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Group"
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji) ?? "👥"
        members = try c.decodeIfPresent([String].self, forKey: .members) ?? []
        let rawLead = try c.decodeIfPresent(String.self, forKey: .lead)
        lead = (rawLead?.isEmpty ?? true) ? nil : rawLead
        rules = try c.decodeIfPresent(String.self, forKey: .rules) ?? ""
        handoffLimit = max(1, (try? c.decodeIfPresent(Int.self, forKey: .handoffLimit)) ?? 3)
        skills = try c.decodeIfPresent([String].self, forKey: .skills) ?? []
        connectors = try c.decodeIfPresent([String].self, forKey: .connectors) ?? []
        // Anything unreadable means Ask me.
        approvals = (try? c.decodeIfPresent(ApprovalMode.self, forKey: .approvals)) ?? .ask
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
    }

    /// Lead first, then the other members, without duplicates.
    public var everyone: [String] {
        var out: [String] = []
        if let lead { out.append(lead) }
        for m in members where !out.contains(m) { out.append(m) }
        return out
    }

    public var displayName: String { "#\(name)" }
}

public final class GroupStore: @unchecked Sendable {
    public let paths: LaunchpadPaths
    private let fm: FileManager

    public init(paths: LaunchpadPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fm = fileManager
    }

    public func dir(_ id: String) -> URL { paths.groups.appendingPathComponent(id, isDirectory: true) }
    public func json(_ id: String) -> URL { dir(id).appendingPathComponent("group.json") }
    public func summary(_ id: String) -> URL { dir(id).appendingPathComponent("SUMMARY.md") }
    public func workspace(_ id: String) -> URL { dir(id).appendingPathComponent("workspace", isDirectory: true) }

    public func loadAll() -> [BotGroup] {
        guard let ids = try? fm.contentsOfDirectory(atPath: paths.groups.path) else { return [] }
        return ids.filter { !$0.hasPrefix(".") }.compactMap { try? load(id: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func load(id: String) throws -> BotGroup {
        let url = json(id)
        guard fm.fileExists(atPath: url.path) else { throw BotStoreError.notFound(id) }
        var group = try JSONCoding.decoder().decode(BotGroup.self, from: Data(contentsOf: url))
        group.id = id
        return group
    }

    @discardableResult
    public func create(
        name: String, emoji: String = "👥", members: [String], lead: String?, rules: String = "",
        handoffLimit: Int = 3, id preferredId: String? = nil
    ) throws -> BotGroup {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard !cleanName.isEmpty else { throw BotStoreError.emptyName }
        try paths.ensureStructure(fileManager: fm)
        let taken = Set((try? fm.contentsOfDirectory(atPath: paths.groups.path)) ?? [])
        let id = Slug.unique(preferredId ?? cleanName, taken: taken)
        let group = BotGroup(id: id, name: cleanName, emoji: emoji, members: members, lead: lead ?? members.first,
                             rules: rules, handoffLimit: max(1, handoffLimit))
        try fm.createDirectory(at: workspace(id), withIntermediateDirectories: true)
        try save(group)
        try Data(Self.summaryTemplate(group).utf8).write(to: summary(id), options: .atomic)
        return group
    }

    public func save(_ group: BotGroup) throws {
        try fm.createDirectory(at: dir(group.id), withIntermediateDirectories: true)
        try JSONCoding.encoder().encode(group).write(to: json(group.id), options: .atomic)
    }

    public func delete(id: String) throws {
        #if os(macOS)
        try fm.trashItem(at: dir(id), resultingItemURL: nil)
        #else
        try fm.removeItem(at: dir(id))
        #endif
    }

    public static func summaryTemplate(_ group: BotGroup) -> String {
        """
        # #\(group.name): summary

        Kept up to date by the lead.

        ## Decisions

        ## Owners

        ## Open issues

        """
    }
}

extension ChatStore {
    @discardableResult
    public func createChat(with group: BotGroup) throws -> ChatMeta {
        let meta = ChatMeta(title: group.displayName, kind: .group, groupId: group.id)
        try save(meta)
        return meta
    }
}
