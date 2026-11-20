import Foundation

// Always-on skills. A skill normally runs when you type `/name`. These stay on for a chat or a whole group: every message
// that goes to a bot carries a short list (name, when to use it, where the file is) and a line telling it to apply them to
// anything it builds. The bot reads a skill's full file only when it builds something, so the cost per message stays small.
// No UI here.

/// Which skills are on. Saved in Launchpad's data folder, which bots can't write, so a bot can't switch its own skills on.
public struct ActiveSkillSet: Codable, Equatable, Sendable {
    /// Skill ids on for one chat, in the order they were switched on.
    public var chats: [String: [String]]
    /// Skill ids on for every chat of a group, and so for every bot in it.
    public var groups: [String: [String]]

    public init(chats: [String: [String]] = [:], groups: [String: [String]] = [:]) {
        self.chats = chats
        self.groups = groups
    }

    enum CodingKeys: String, CodingKey { case chats, groups }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chats = (try? c.decodeIfPresent([String: [String]].self, forKey: .chats)) ?? [:]
        groups = (try? c.decodeIfPresent([String: [String]].self, forKey: .groups)) ?? [:]
    }
}

/// Where a switch applies.
public enum ActiveSkillScope: Equatable, Sendable {
    /// Just this chat.
    case chat(String)
    /// Every chat of this group, so every bot in it.
    case group(String)
}

public enum ActiveSkillError: Error, LocalizedError, Equatable {
    case tooMany(Int)
    case unknownSkill(String)

    public var errorDescription: String? {
        switch self {
        case .tooMany(let n): return "Up to \(n) skills can be on at once, because each one adds to every message. Switch one off first."
        case .unknownSkill(let id): return "There's no skill called \(id) in your library."
        }
    }
}

public struct ActiveSkillsStore: @unchecked Sendable {
    /// More than this and every message carries a lot of extra instructions.
    public static let maxActive = 8

    public let file: URL
    private let paths: LaunchpadPaths
    private let fm = FileManager.default
    private static let lock = NSLock()

    public init(paths: LaunchpadPaths) {
        self.paths = paths
        file = paths.launchpadData.appendingPathComponent("active-skills.json")
    }

    /// Missing or unreadable means nothing is on.
    public func load() -> ActiveSkillSet {
        guard let data = try? Data(contentsOf: file), let set = try? JSONCoding.decoder().decode(ActiveSkillSet.self, from: data) else { return ActiveSkillSet() }
        return set
    }

    /// What's on for a chat: its group's skills first, then the chat's own, without repeats.
    public func active(for chat: ChatMeta, in set: ActiveSkillSet? = nil) -> [String] {
        let s = set ?? load()
        var out: [String] = []
        if chat.kind == .group, let g = chat.groupId { out += s.groups[g] ?? [] }
        out += s.chats[chat.id] ?? []
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// The ids switched on at one scope.
    public func ids(_ scope: ActiveSkillScope) -> [String] {
        let s = load()
        switch scope {
        case .chat(let id): return s.chats[id] ?? []
        case .group(let id): return s.groups[id] ?? []
        }
    }

    /// Switches a skill on or off at a scope. Turning one on checks the skill exists and that the chat stays within the
    /// cap (counting the group's skills and the chat's together, since a chat gets both). Turning one off always works.
    /// Returns what's now on at that scope.
    @discardableResult
    public func set(_ skillId: String, on: Bool, scope: ActiveSkillScope, chat: ChatMeta? = nil) throws -> [String] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var s = load()
        func edit(_ map: inout [String: [String]], _ key: String) {
            var list = map[key] ?? []
            list.removeAll { $0 == skillId }
            if on { list.append(skillId) }
            if list.isEmpty { map.removeValue(forKey: key) } else { map[key] = list }
        }
        if on {
            guard fm.fileExists(atPath: paths.skills.appendingPathComponent(skillId).appendingPathComponent("SKILL.md").path) else {
                throw ActiveSkillError.unknownSkill(skillId)
            }
            var trial = s
            switch scope {
            case .chat(let id): var m = trial.chats; edit(&m, id); trial.chats = m
            case .group(let id): var m = trial.groups; edit(&m, id); trial.groups = m
            }
            // A group-wide change must fit for every chat of that group; a chat change for that chat.
            let chats: [ChatMeta]
            switch scope {
            case .chat(let id): chats = chat.map { [$0] } ?? [ChatMeta(id: id, title: "", kind: .bot)]
            case .group(let gid):
                chats = ChatStore(paths: paths).loadAll().filter { $0.kind == .group && $0.groupId == gid }
                    + [ChatMeta(id: "", title: "", kind: .group, groupId: gid)]
            }
            for c in chats where active(for: c, in: trial).count > Self.maxActive { throw ActiveSkillError.tooMany(Self.maxActive) }
            s = trial
        } else {
            switch scope {
            case .chat(let id): edit(&s.chats, id)
            case .group(let id): edit(&s.groups, id)
            }
        }
        try save(s)
        return ids(scope)
    }

    /// A copy of a group starts with the same skills as the original.
    public func copyGroup(from original: String, to copy: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var s = load()
        guard let list = s.groups[original], !list.isEmpty else { return }
        s.groups[copy] = list
        try save(s)
    }

    /// Forgets a chat's or a group's skills (when it's deleted).
    public func forget(_ scope: ActiveSkillScope) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var s = load()
        switch scope {
        case .chat(let id): s.chats.removeValue(forKey: id)
        case .group(let id): s.groups.removeValue(forKey: id)
        }
        try save(s)
    }

    private func save(_ set: ActiveSkillSet) throws {
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.encoder().encode(set).write(to: file, options: .atomic)
    }
}

/// What a run is told about the skills that are on.
public enum ActiveSkillsPrompt {
    /// A rough size for a skill's entry in the list, in tokens (name, one line, path).
    public static func tokens(forEntry skill: Skill, path: String) -> Int {
        TokenEstimate.tokens("- \(skill.name): \(oneLine(skill.description)) (\(path))")
    }

    public struct Section: Equatable, Sendable {
        public var text: String
        /// The skills named in it (those that exist), in order.
        public var skillIds: [String]
        /// About how many tokens this adds to every message.
        public var estimatedTokens: Int
        public var isEmpty: Bool { skillIds.isEmpty }
    }

    /// The section for the skills that are on: a list, not the skills themselves. Skills no longer in the library are left out.
    public static func section(ids: [String], library: [Skill], paths: LaunchpadPaths) -> Section {
        let byId = Dictionary(library.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        let skills = ids.filter { seen.insert($0).inserted }.compactMap { byId[$0] }.prefix(ActiveSkillsStore.maxActive)
        guard !skills.isEmpty else { return Section(text: "", skillIds: [], estimatedTokens: 0) }
        var lines = ["The user has these skills switched on for this chat. Apply them to anything you build or design here (screens, copy, code, documents), without being asked each time. Read a skill's file in full when you start building something, not before; don't paste its text into the chat."]
        for s in skills {
            let path = paths.skills.appendingPathComponent(s.id).appendingPathComponent("SKILL.md").path
            lines.append("- \(s.name): \(oneLine(s.description)) (\(path))")
        }
        let text = lines.joined(separator: "\n")
        return Section(text: text, skillIds: skills.map(\.id), estimatedTokens: TokenEstimate.tokens(text))
    }

    /// The cost of switching one more skill on, for the "adds about N tokens to every message" line.
    public static func estimate(ids: [String], library: [Skill], paths: LaunchpadPaths) -> Int {
        section(ids: ids, library: library, paths: paths).estimatedTokens
    }

    static func oneLine(_ s: String) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > 220 ? String(flat.prefix(219)) + "…" : flat
    }
}

/// The design skills Launchpad looks for on this Mac, and nothing else.
public enum DesignSkills {
    public static let ids = ["frontend-design", "ui-ux-pro-max", "dataviz"]

    public struct Report: Equatable, Sendable {
        public var installed: [String] = []
        public var alreadyThere: [String] = []
        /// Not found on this Mac.
        public var missing: [String] = []
        /// Found but couldn't be imported (a different skill with the same name, too big, …), with why.
        public var failed: [String: String] = [:]

        /// One line for the user.
        public var summary: String {
            var parts: [String] = []
            if !installed.isEmpty { parts.append("Added \(installed.joined(separator: ", "))") }
            if !alreadyThere.isEmpty { parts.append("already had \(alreadyThere.joined(separator: ", "))") }
            if !missing.isEmpty { parts.append("couldn't find \(missing.joined(separator: ", ")) on this Mac") }
            for (id, why) in failed.sorted(by: { $0.key < $1.key }) { parts.append("\(id) wasn't added (\(why))") }
            guard let first = parts.first else { return "No design skills to add." }
            return ([first.prefix(1).uppercased() + first.dropFirst()] + parts.dropFirst()).joined(separator: "; ") + "."
        }
    }

    /// Imports whichever of `ids` exist on this Mac into the library, using the normal skill import (never replaces a skill).
    @discardableResult
    public static func importAvailable(into store: SkillStore, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Report {
        var report = Report()
        for id in ids {
            guard let source = SkillSources.find(named: id, home: home).first else {
                if store.load(id: id) != nil { report.alreadyThere.append(id) } else { report.missing.append(id) }
                continue
            }
            do {
                switch try store.importSkill(from: source, as: id) {
                case .installed: report.installed.append(id)
                case .alreadyInstalled: report.alreadyThere.append(id)
                }
            } catch {
                if store.load(id: id) != nil { report.alreadyThere.append(id) } else { report.failed[id] = error.localizedDescription }
            }
        }
        return report
    }

    /// Design skills first, then the rest alphabetically, for the checklist.
    public static func ordered(_ skills: [Skill]) -> [Skill] {
        func rank(_ s: Skill) -> Int { ids.firstIndex(of: s.id) ?? ids.count }
        return skills.sorted { rank($0) != rank($1) ? rank($0) < rank($1) : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
