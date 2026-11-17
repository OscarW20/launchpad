import Foundation

// Capturing a skill from a chat ("Save as skill") and using one by typing "/name …" in the composer.
// Nothing here is reachable from a bot's tools: the app calls it when you press Save or send a message.

public enum SkillCaptureError: Error, LocalizedError, Equatable {
    case emptyName
    case badName(String)
    case reserved(String)
    case emptySteps
    case taken(String)
    case builtIn(String)
    case locked(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .emptyName: return "Give the skill a name first."
        case .badName(let name): return "\"\(name)\" can't be a skill name. Use letters, numbers and dashes, like \"release-notes\"."
        case .reserved(let name): return "\"/\(name)\" already means something else in the chat. Pick another name."
        case .emptySteps: return "The skill has no steps yet. Write what to do first."
        case .taken(let name): return "There's already a skill called \"\(name)\". Pick another name, or edit that one."
        case .builtIn(let name): return "\"\(name)\" is one of Launchpad's own skills, so it can't be replaced. Duplicate it and change the copy."
        case .locked(let name): return "The \"\(name)\" skill is locked. Unlock it in Skills before changing it."
        case .notFound(let name): return "There's no skill called \"\(name)\" any more."
        }
    }
}

/// A skill being captured: a name, one line saying when to use it, and the steps (markdown).
public struct SkillDraft: Equatable, Sendable {
    public var name: String
    public var useWhen: String
    public var steps: String

    public init(name: String, useWhen: String, steps: String) {
        self.name = name
        self.useWhen = useWhen
        self.steps = steps
    }

    /// From a SKILL.md, e.g. the draft a bot wrote (`SkillTeacher.cleanDraft`).
    public init(text: String) {
        let parsed = SkillFile.parse(text)
        self.init(name: parsed.name ?? "", useWhen: parsed.description ?? "", steps: parsed.body)
    }

    /// The SKILL.md this saves as. Throws if the name isn't valid.
    public func fileText() throws -> String {
        SkillFile.compose(name: try SkillCapture.skillId(name), description: useWhen, body: steps)
    }
}

public enum SkillCapture {
    /// Words that already mean something after a "/" in the composer (`ApprovalMode.commands`).
    public static let reservedNames: Set<String> = ["accept", "ask"]
    public static let maxNameLength = 40

    /// The id a name saves under: "Release Notes" gives "release-notes". Throws for a name that is empty, has
    /// nothing usable in it, is too long or is reserved.
    public static func skillId(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SkillCaptureError.emptyName }
        guard trimmed.unicodeScalars.contains(where: { $0.isASCII && CharacterSet.alphanumerics.contains($0) }),
              !trimmed.contains("/"), !trimmed.contains("\\"), !trimmed.hasPrefix("."),
              trimmed.count <= maxNameLength else { throw SkillCaptureError.badName(trimmed) }
        let id = Slug.make(trimmed)
        guard !reservedNames.contains(id) else { throw SkillCaptureError.reserved(id) }
        return id
    }

    /// One of the skills Launchpad ships (the starters and the marketplace's).
    public static func isBuiltIn(_ id: String) -> Bool { SkillCatalog.skill(id) != nil }

    /// A skill you made (captured or written), as opposed to one Launchpad ships.
    public static func isUserSkill(_ skill: Skill) -> Bool { !isBuiltIn(skill.id) }

    /// Who gets a newly captured skill.
    public enum Audience: Equatable, Sendable {
        /// Everyone in a group, now and later (the skill goes on the group).
        case group(String)
        /// These bots only.
        case bots([String])
        /// Nobody yet: it's only in the library.
        case nobody
    }

    /// The default: every bot in the group the chat belongs to, or the one bot of a one-to-one chat.
    public static func defaultAudience(for chat: ChatMeta) -> Audience {
        switch chat.kind {
        case .group: return chat.groupId.map(Audience.group) ?? .nobody
        case .bot: return chat.botId.map { .bots([$0]) } ?? .nobody
        }
    }
}

extension SkillStore {
    /// Saves a new skill from a draft. Never overwrites: a name that's already in the library (yours, a built-in
    /// or a locked one) throws, so nothing is replaced by accident.
    @discardableResult
    public func capture(_ draft: SkillDraft) throws -> Skill {
        let id = try SkillCapture.skillId(draft.name)
        guard !draft.steps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SkillCaptureError.emptySteps }
        guard !SkillCapture.isBuiltIn(id) else { throw SkillCaptureError.builtIn(id) }
        guard load(id: id) == nil else { throw SkillCaptureError.taken(id) }
        try paths.ensureStructure()
        try save(id: id, text: SkillFile.compose(name: id, description: draft.useWhen, body: draft.steps))
        guard let saved = load(id: id) else { throw SkillCaptureError.notFound(id) }
        return saved
    }

    /// Updates one of your own skills in place (its "use when" line and steps; the name stays, because bots and
    /// groups refer to it). Refuses a built-in or locked skill.
    /// - Parameter locked: from `SkillLocks.load()`.
    @discardableResult
    public func update(id: String, with draft: SkillDraft, locked: Set<String>) throws -> Skill {
        guard load(id: id) != nil else { throw SkillCaptureError.notFound(id) }
        guard !SkillCapture.isBuiltIn(id) else { throw SkillCaptureError.builtIn(id) }
        guard !locked.contains(id) else { throw SkillCaptureError.locked(id) }
        guard !draft.steps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SkillCaptureError.emptySteps }
        try save(id: id, text: SkillFile.compose(name: id, description: draft.useWhen, body: draft.steps))
        guard let saved = load(id: id) else { throw SkillCaptureError.notFound(id) }
        return saved
    }
}

extension SkillCapture {
    /// Gives a skill to its audience by adding it to the group's or the bots' skill lists. Call
    /// `SkillLinker.link` (the app's `relinkSkills`) afterwards so it shows up in their folders.
    /// Returns the ids of the bots that have it now through this change.
    @discardableResult
    public static func assign(_ skillId: String, to audience: Audience, bots: BotStore, groups: GroupStore) throws -> [String] {
        switch audience {
        case .nobody:
            return []
        case .group(let id):
            var group = try groups.load(id: id)
            if !group.skills.contains(skillId) {
                group.skills.append(skillId)
                try groups.save(group)
            }
            return group.everyone
        case .bots(let ids):
            var given: [String] = []
            for id in ids {
                guard var bot = try? bots.load(id: id) else { continue }
                if !bot.skills.contains(skillId) {
                    bot.skills.append(skillId)
                    try bots.save(bot)
                }
                given.append(id)
            }
            return given
        }
    }
}

// MARK: - "/name …" in the composer

/// Using a skill by typing "/name what you want" as a message. The picker's view is in the app.
public enum SkillCommand {
    public struct Use: Equatable, Sendable {
        public var skill: Skill
        /// What you typed after the name ("" when you sent just "/name").
        public var request: String
    }

    /// The skill name being typed: the draft is a "/" followed by name characters and nothing else yet
    /// ("/" gives "", "/rel" gives "rel"). Nil once there's a space, or for a path like "/usr/bin".
    public static func query(in draft: String) -> String? {
        guard draft.hasPrefix("/") else { return nil }
        let typed = draft.dropFirst()
        guard typed.allSatisfy(isNameCharacter) else { return nil }
        return String(typed)
    }

    /// Skills whose id or name starts with what's typed, then those that contain it, each in library order.
    public static func candidates(for query: String, among skills: [Skill]) -> [Skill] {
        let q = query.lowercased()
        guard !q.isEmpty else { return skills }
        var starts: [Skill] = [], contains: [Skill] = []
        for skill in skills {
            let keys = [skill.id.lowercased(), skill.name.lowercased(), Slug.make(skill.name)]
            if keys.contains(where: { $0.hasPrefix(q) }) {
                starts.append(skill)
            } else if keys.contains(where: { $0.contains(q) }) {
                contains.append(skill)
            }
        }
        return starts + contains
    }

    /// The draft after picking a skill from the list: "/id ", ready for the request.
    public static func insert(_ id: String, into draft: String) -> String {
        guard query(in: draft) != nil else { return draft }
        return "/\(id) "
    }

    /// A message that starts "/name" where name is a skill in the library (by id, any case). Anything else,
    /// including "/usr/bin/x" or "/unknown please", is an ordinary message.
    public static func parse(_ text: String, skills: [Skill]) -> Use? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let rest = trimmed.dropFirst()
        let name = rest.prefix(while: isNameCharacter)
        guard !name.isEmpty else { return nil }
        let after = rest.dropFirst(name.count)
        // The name must end the message or be followed by a space: "/deploy/now" isn't a command.
        if let next = after.first, !next.isWhitespace { return nil }
        let wanted = name.lowercased()
        guard let skill = skills.first(where: { $0.id.lowercased() == wanted }) else { return nil }
        return Use(skill: skill, request: after.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// What the bot is sent instead of "/name request". The skill's steps are included, so it works for a bot
    /// that doesn't have the skill in its folder (and for local models, which have no folder at all).
    public static func prompt(for use: Use) -> String {
        let request = use.request.isEmpty ? "Do what this skill is for. If it needs something from me first, ask."
                                          : use.request
        return """
        Use the "\(use.skill.id)" skill for this. Follow its steps in order and tell me if one doesn't fit.

        My request: \(request)

        The skill (\(use.skill.id)/SKILL.md):

        \(use.skill.text.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }

    /// A group's bots read the chat's history, not a prompt, so there your "/name request" messages are handed to
    /// them with the skill's steps. Bots' messages and notices are never expanded.
    public static func expand(_ history: [ChatMessage], skills: [Skill]) -> [ChatMessage] {
        history.map { message in
            guard message.role == .user, message.deleted != true, let use = parse(message.text, skills: skills) else { return message }
            var out = message
            out.text = prompt(for: use)
            return out
        }
    }

    private static func isNameCharacter(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_")
    }
}

// MARK: - Drafting from a stretch of chat

extension SkillTeacher {
    /// The stretch of chat a "Save as skill" on one message is about: from the request of yours that started it
    /// (the nearest message from you before it, going back over the bots' replies) to that message. Notices are
    /// left out. Empty when the message isn't in the chat.
    public static func stretch(endingAt messageId: String, in messages: [ChatMessage]) -> [ChatMessage] {
        guard let end = messages.firstIndex(where: { $0.id == messageId }) else { return [] }
        var start = end
        if messages[end].role != .user {
            while start > messages.startIndex, messages[start].role != .user { start -= 1 }
        }
        // Several messages from you in a row are one request.
        while start > messages.startIndex, messages[start - 1].role == .user { start -= 1 }
        return messages[start...end].filter { $0.role != .notice }
    }

    /// The prompt for a bot to write up a stretch of chat as a skill.
    /// - Parameters:
    ///   - name: the name you gave it, if any; the draft uses it instead of inventing one.
    ///   - limit: at most this many messages, the latest ones.
    public static func capturePrompt(_ messages: [ChatMessage], name: String? = nil, botName: (String?) -> String, limit: Int = 30) -> String {
        var text = prompt(transcript: transcript(messages, botName: botName, limit: limit))
        if let id = name.flatMap({ try? SkillCapture.skillId($0) }) {
            text = text.replacingOccurrences(of: "\n\nChat:\n", with: "\n\nCall it exactly `\(id)` in `name:`.\n\nChat:\n")
        }
        return text
    }
}
