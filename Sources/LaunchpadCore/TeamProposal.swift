import Foundation

// "Spawn a group for me". You ask any bot for a team for a job; it replies with up to three setups in one fenced block
// (```team-proposal, JSON). The app turns that into a card; nothing is created until you press Launch. A bot can only propose:
// this file reads and checks the block, and `WorkspaceStore.launch` is the one call that creates anything. No UI here.
//
// The block:
//
//   ```team-proposal
//   {"goal": "Auto-post story-led shorts",
//    "options": [{
//      "label": "Recommended",                    // Lean, Recommended or Full (any short label is fine)
//      "name": "Marketing",                       // the group's name
//      "emoji": "📣",                             // optional
//      "lead": "lead",                            // the `key` of one member
//      "members": [
//        {"key": "lead", "name": "Marketing Lead", "role": "Plans the campaign and hands out work", "template": "marketing-lead"},
//        {"key": "copy", "name": "Copywriter", "role": "Writes the captions and hooks"}   // no template: a custom bot
//      ],
//      "skills": ["frontend-design"],             // skills to switch on for the group
//      "connectors": ["tiktok"],                  // apps the job needs (you add them yourself)
//      "notes": "Why this setup."                 // shown on the card only
//    }]}
//   ```

public struct ProposedMember: Equatable, Sendable {
    /// How the lead and the card refer to this member inside the option.
    public var key: String
    public var name: String
    /// One line: what this bot does. Goes into its instructions.
    public var role: String
    /// A catalog role to start from (`HireCatalog`); nil, or one that isn't in the catalog, makes a custom bot.
    public var template: String?
}

public struct TeamOption: Equatable, Sendable, Identifiable {
    public var id: String { label.lowercased() }
    public var label: String
    public var name: String
    public var emoji: String
    /// The `key` of the lead member.
    public var lead: String
    public var members: [ProposedMember]
    public var skills: [String]
    public var connectors: [String]
    public var notes: String
}

public struct TeamProposal: Equatable, Sendable {
    public var goal: String
    public var options: [TeamOption]
    /// Options that were left out as invalid, with why (for the bot's next reply or a note on the card).
    public var dropped: [String]
}

public enum TeamProposalError: Error, LocalizedError, Equatable {
    case noBlock
    case tooBig
    case notJSON
    case noValidOptions([String])

    public var errorDescription: String? {
        switch self {
        case .noBlock: return "There's no team proposal in that message."
        case .tooBig: return "That team proposal is too big to read."
        case .notJSON: return "The team proposal isn't in the expected format."
        case .noValidOptions(let why): return "None of the proposed teams could be used: " + why.joined(separator: "; ") + "."
        }
    }
}

public enum TeamProposalParser {
    public static let fence = "team-proposal"
    public static let maxBlockBytes = 12_000
    public static let maxOptions = 3
    /// Counting the lead.
    public static let maxMembers = 8
    public static let maxSkills = ActiveSkillsStore.maxActive
    public static let maxConnectors = 8
    public static let maxNameLength = 40
    public static let maxRoleLength = 160
    public static let maxNotesLength = 400
    public static let maxGoalLength = 2000

    /// The proposal in a bot's message. The last block wins.
    public static func parse(_ text: String) throws -> TeamProposal {
        guard let body = block(in: text) else { throw TeamProposalError.noBlock }
        guard body.utf8.count <= maxBlockBytes else { throw TeamProposalError.tooBig }
        guard let root = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else { throw TeamProposalError.notJSON }
        let rawOptions = (root["options"] as? [[String: Any]]) ?? []
        var options: [TeamOption] = []
        var dropped: [String] = []
        var labels = Set<String>()
        for (i, raw) in rawOptions.enumerated() {
            if options.count >= maxOptions { dropped.append("option \(i + 1): only \(maxOptions) options are used"); continue }
            switch option(from: raw, index: i) {
            case .success(let o):
                if labels.insert(o.label.lowercased()).inserted { options.append(o) } else { dropped.append("\(o.label): the label is used twice") }
            case .failure(let why): dropped.append(why.text)
            }
        }
        guard !options.isEmpty else { throw TeamProposalError.noValidOptions(dropped.isEmpty ? ["there were no options"] : dropped) }
        return TeamProposal(goal: cleanText(root["goal"] as? String ?? "", max: maxGoalLength), options: options, dropped: dropped)
    }

    /// The message with the block taken out, so the card replaces it in the chat. No block: the text as it is.
    public static func stripped(_ text: String) -> String {
        guard let range = blockRange(in: text) else { return text }
        var out = text
        out.removeSubrange(range)
        return out.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Internals

    struct Invalid: Error { var text: String }

    private static func blockRange(in text: String) -> Range<String.Index>? {
        guard let regex = try? NSRegularExpression(pattern: "```[ \\t]*" + fence + "[ \\t]*\\n(.*?)\\n?```", options: [.dotMatchesLineSeparators]) else { return nil }
        let ns = NSRange(text.startIndex..., in: text)
        guard let m = regex.matches(in: text, range: ns).last else { return nil }
        return Range(m.range, in: text)
    }

    private static func block(in text: String) -> String? {
        guard let range = blockRange(in: text) else { return nil }
        let whole = String(text[range])
        guard let first = whole.firstIndex(of: "\n"), let last = whole.range(of: "```", options: .backwards) else { return nil }
        return String(whole[whole.index(after: first)..<last.lowerBound])
    }

    /// One line, no hidden characters, no @ or # (a name must not mention or tag anyone), clipped.
    static func clean(_ s: String, max: Int) -> String {
        let plain = TicketPrompt.sanitize(s).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
        let squeezed = plain.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return String(squeezed.prefix(max)).trimmingCharacters(in: .whitespaces)
    }

    /// Free text (goal, role, notes): as `clean`, and `@` becomes "(at)" ("a(at)b.com" still reads as an email), so nothing in it can
    /// mention a bot, or everyone, when it's read back out in a chat or an instruction. (A look-alike `@` is not safe: the group's
    /// mention matcher folds it back.)
    static func cleanText(_ s: String, max: Int) -> String {
        clean(s.replacingOccurrences(of: "@", with: "(at)"), max: max)
    }

    static func cleanName(_ s: String) -> String {
        clean(s.replacingOccurrences(of: "@", with: "").replacingOccurrences(of: "#", with: ""), max: maxNameLength)
    }

    private static func isKey(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 30 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    private static func strings(_ any: Any?, limit: Int) -> [String] {
        var seen = Set<String>()
        return ((any as? [Any]) ?? []).compactMap { $0 as? String }.map { clean($0, max: 40) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(limit).map { $0 }
    }

    private static func option(from raw: [String: Any], index: Int) -> Result<TeamOption, Invalid> {
        let label = clean(raw["label"] as? String ?? "", max: 20)
        let tag = label.isEmpty ? "option \(index + 1)" : label
        let name = cleanName(raw["name"] as? String ?? "")
        guard !name.isEmpty else { return .failure(Invalid(text: "\(tag): the group has no name")) }
        guard let rawMembers = raw["members"] as? [[String: Any]], !rawMembers.isEmpty else { return .failure(Invalid(text: "\(tag): no members")) }
        guard rawMembers.count <= maxMembers else { return .failure(Invalid(text: "\(tag): \(rawMembers.count) members is more than the limit of \(maxMembers)")) }
        var members: [ProposedMember] = []
        var keys = Set<String>()
        for m in rawMembers {
            let key = (m["key"] as? String ?? "").lowercased()
            guard isKey(key), keys.insert(key).inserted else { return .failure(Invalid(text: "\(tag): a member's key is missing, invalid or used twice")) }
            let n = cleanName(m["name"] as? String ?? "")
            guard !n.isEmpty else { return .failure(Invalid(text: "\(tag): member \(key) has no name")) }
            let template = (m["template"] as? String).flatMap { HireCatalog.template($0.lowercased()) != nil ? $0.lowercased() : nil }
            members.append(ProposedMember(key: key, name: n, role: cleanText(m["role"] as? String ?? "", max: maxRoleLength), template: template))
        }
        let lead = (raw["lead"] as? String ?? "").lowercased()
        guard keys.contains(lead) else { return .failure(Invalid(text: "\(tag): the lead must be one of the members")) }
        let emoji = (raw["emoji"] as? String).map { String($0.trimmingCharacters(in: .whitespaces).prefix(1)) } ?? ""
        return .success(TeamOption(label: label.isEmpty ? "Option \(index + 1)" : label, name: name,
                                   emoji: emoji.isEmpty || emoji.unicodeScalars.allSatisfy(\.isASCII) ? "👥" : emoji,
                                   lead: lead, members: members, skills: strings(raw["skills"], limit: maxSkills),
                                   connectors: strings(raw["connectors"], limit: maxConnectors),
                                   notes: cleanText(raw["notes"] as? String ?? "", max: maxNotesLength)))
    }
}

// MARK: - Launch

/// What launching made, and what the app should tell you.
public struct LaunchedTeam: Sendable {
    public var group: BotGroup
    /// Member key to the new bot.
    public var bots: [String: Bot]
    /// What to send the lead as its first message: your goal, and what the team is.
    public var firstMessage: String
    /// Apps the job needs that aren't set up yet (you add them in Apps).
    public var missingConnectors: [String]
    /// Skills the proposal named that aren't in your library.
    public var unknownSkills: [String]
    /// The group name got a number because the workspace already had one.
    public var renamedGroup: Bool
    /// Bots whose catalog setup had Full access and were started at "edit its own workspace" instead; raise it on the bot if wanted.
    public var cappedAccess: [String] = []
}

extension WorkspaceStore {
    /// The standing rules every proposed team starts with, whatever the proposal says.
    public static let proposedTeamRules = """
    - The lead plans first, hands work out by @mention, and reports back to me.
    - Ask me before posting, sending, publishing, buying or deleting anything. Never do it on your own.
    - Keep replies short and say plainly what's done and what's blocked.
    """

    /// Creates the group and its bots in `workspaceId` from one proposed option, and switches on its skills. This is the only
    /// call that creates anything from a proposal. Every bot is new and in that workspace (nothing is reused or moved), custom
    /// bots can edit their own workspace folder only, and the group starts in Ask me. Refused while the workspaces file is
    /// unreadable; if anything fails part-way, what was made is removed.
    @discardableResult
    public func launch(_ proposed: TeamOption, goal: String, in workspaceId: String) throws -> LaunchedTeam {
        try requireReadable()
        // Clean again here: a tweaked or hand-built option never reaches a bot's instructions or the kickoff message as given.
        var option = proposed
        option.members = proposed.members.map { m in
            var m = m
            m.name = TeamProposalParser.cleanName(m.name)
            m.role = TeamProposalParser.cleanText(m.role, max: TeamProposalParser.maxRoleLength)
            return m
        }
        guard load().workspaces.contains(where: { $0.id == workspaceId }) else { throw WorkspaceError.notFound(workspaceId) }
        guard !option.members.isEmpty, option.members.count <= TeamProposalParser.maxMembers,
              option.members.contains(where: { $0.key == option.lead }) else { throw TeamLaunchError.invalid }
        let groupName = freeGroupName(TeamProposalParser.cleanName(option.name).isEmpty ? "Team" : TeamProposalParser.cleanName(option.name), in: workspaceId)
        let hiring = Hiring(paths: paths)
        var made: [String: Bot] = [:]
        var madeIds: [String] = []
        var groupId: String?
        var capped: [String] = []
        do {
            var used = Set<String>()
            for m in option.members {
                let name = freeBotName(TeamProposalParser.cleanName(m.name), in: workspaceId, also: used)
                used.insert(name.lowercased())
                var bot: Bot
                if let t = m.template.flatMap(HireCatalog.template) {
                    bot = try hiring.hire(t)
                } else {
                    bot = try botStore.create(name: name, role: TeamProposalParser.cleanText(m.role, max: TeamProposalParser.maxRoleLength))
                }
                madeIds.append(bot.id)
                // A proposal never hands out Full access: it starts at the safe level, and you can raise it on the bot.
                if bot.permission == .fullAccess { bot.permission = .editWorkspace; capped.append(name) }
                if bot.name != name { bot.name = name }
                try botStore.save(bot)
                try place(bot: bot.id, in: workspaceId)
                made[m.key] = bot
            }
            let ids = option.members.compactMap { made[$0.key]?.id }
            let leadId = made[option.lead]?.id ?? ids.first
            let takenIds = Set((try? fm.contentsOfDirectory(atPath: paths.groups.path)) ?? [])
            let id = Slug.unique(groupName, taken: takenIds)
            var group = try groupStore.create(name: groupName, emoji: option.emoji, members: ids, lead: leadId,
                                              rules: Self.proposedTeamRules, id: id)
            groupId = group.id
            // Apps that are already set up are turned on for the group; the rest are reported.
            let installed = Set(ConnectorStore(paths: paths).loadAll().map(\.id))
            let have = option.connectors.filter { installed.contains($0) }
            group.connectors = have
            try groupStore.save(group)
            try mutate { l in Self.assign(&l.groups, group.id, workspaceId) }
            var unknown: [String] = []
            for skill in option.skills {
                do { try ActiveSkillsStore(paths: paths).set(skill, on: true, scope: .group(group.id)) } catch { unknown.append(skill) }
            }
            let clean = TeamProposalParser.cleanText(goal, max: TeamProposalParser.maxGoalLength)
            return LaunchedTeam(group: group, bots: made, firstMessage: Self.firstMessage(goal: clean, group: group, option: option, bots: made),
                                missingConnectors: option.connectors.filter { !installed.contains($0) }, unknownSkills: unknown,
                                renamedGroup: groupName != TeamProposalParser.cleanName(option.name), cappedAccess: capped)
        } catch {
            for id in madeIds { try? fm.removeItem(at: paths.botDir(id)) }
            if let groupId { try? fm.removeItem(at: groupStore.dir(groupId)); try? ActiveSkillsStore(paths: paths).forget(.group(groupId)) }
            try? mutate { l in
                for id in madeIds { l.bots.removeValue(forKey: id) }
                if let groupId { l.groups.removeValue(forKey: groupId) }
            }
            throw error
        }
    }

    static func firstMessage(goal: String, group: BotGroup, option: TeamOption, bots: [String: Bot]) -> String {
        // Names only, no @: a message that @mentions people goes to each of them, and the lead should plan first. The lead is
        // told who the teammates are (with their handles) in its group instructions.
        let leadName = bots[option.lead]?.name ?? "the lead"
        let team = option.members.compactMap { m in bots[m.key].map { "\($0.name)\(m.role.isEmpty ? "" : " (\(m.role))")" } }.joined(separator: ", ")
        let goalLine = goal.isEmpty ? "Get set up and tell me what you need from me." : goal
        return "New team, \(group.displayName). Goal: \(goalLine)\nTeam: \(team).\n\(leadName), please plan it first, then hand the work out, and ask me before posting, sending or publishing anything."
    }
}

public enum TeamLaunchError: Error, LocalizedError, Equatable {
    case invalid
    public var errorDescription: String? { "That team setup isn't valid, so nothing was created." }
}
