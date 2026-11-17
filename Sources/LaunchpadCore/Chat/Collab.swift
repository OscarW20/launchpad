import Foundation

// Working together: a live activity feed, shared team notes (Shared/TEAM.md), asking a teammate from a 1:1 chat,
// asking for a review, and huddles (a group's "Ask everyone").

// MARK: - Live activity

/// One thing a bot did, for a live feed.
public struct ActivityEvent: Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case started, step, asked, finished, failed }

    public var id: String
    public var date: Date
    public var kind: Kind
    public var botId: String
    public var chatId: String
    public var text: String

    public init(id: String = UUID().uuidString.lowercased(), date: Date = Date(), kind: Kind, botId: String, chatId: String, text: String) {
        self.id = id
        self.date = date
        self.kind = kind
        self.botId = botId
        self.chatId = chatId
        self.text = text
    }
}

/// The newest 400 events, text flattened to one short line.
public struct ActivityFeed: Equatable, Sendable {
    public static let limit = 400
    public private(set) var events: [ActivityEvent] = []

    public init() {}

    public mutating func record(_ kind: ActivityEvent.Kind, bot: String, chat: String, _ text: String, at date: Date = Date()) {
        events.append(ActivityEvent(date: date, kind: kind, botId: bot, chatId: chat, text: Self.clean(text)))
        if events.count > Self.limit { events.removeFirst(events.count - Self.limit) }
    }

    /// Newest first.
    public func recent(_ n: Int = 50, bot: String? = nil) -> [ActivityEvent] {
        Array(events.reversed().filter { bot == nil || $0.botId == bot }.prefix(n))
    }

    static func clean(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespaces)
        return flat.count > 160 ? String(flat.prefix(160)) + "…" : flat
    }
}

// MARK: - Team notes

/// One page every bot reads: who we are, how we work, decisions made. `~/Launchpad/Shared/TEAM.md`, shared by all
/// bots and groups (a group's own decisions stay in `groups/<id>/SUMMARY.md`).
public enum TeamNotes {
    public static let template = """
    # Team notes

    Every bot reads this before it starts. Keep it short.

    ## Who we are

    ## How we work

    ## Decisions
    <!-- One dated line each, newest last: 2026-11-17: We use British English in all copy. -->

    """

    public static func read(paths: LaunchpadPaths) -> String? {
        try? String(contentsOf: paths.teamNotes, encoding: .utf8)
    }

    /// Saves (from the editor). Makes `Shared/` if needed.
    public static func save(_ text: String, paths: LaunchpadPaths, fileManager fm: FileManager = .default) throws {
        try fm.createDirectory(at: paths.shared, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: paths.teamNotes, options: .atomic)
    }

    /// Creates TEAM.md from the template if it isn't there. Returns its URL.
    @discardableResult
    public static func ensure(paths: LaunchpadPaths, fileManager fm: FileManager = .default) throws -> URL {
        if !fm.fileExists(atPath: paths.teamNotes.path) { try save(template, paths: paths, fileManager: fm) }
        return paths.teamNotes
    }

    /// Added to a bot's instructions: where the team notes are, and who it can ask for help (`@id: …` lines).
    /// `others`: the other bots.
    public static func teamLine(for bot: Bot, others: [Bot], paths: LaunchpadPaths, fileManager fm: FileManager = .default) -> String {
        var lines: [String] = []
        if fm.fileExists(atPath: paths.teamNotes.path) {
            lines.append("Team notes everyone shares: \(paths.teamNotes.path). Read them before you start. When you make a decision the team should know, add one short dated line under Decisions.")
        }
        let team = others.filter { $0.id != bot.id }
        if !team.isEmpty {
            let roster = team.map { "@\($0.id) (\($0.name)\($0.role.isEmpty ? "" : ", \($0.role)"))" }.joined(separator: ", ")
            lines.append("Your teammates: \(roster). In a chat with the user, if one of them is better placed to help, end your reply with a line like `@id: exactly what you need`. Their answer comes back to you; then finish the job for the user. Only ask when it really helps.")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Asking a teammate from a 1:1 chat

/// A turn to run next in a 1:1 chat after a reply.
public struct HandOffTurn: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A teammate answering the chat's bot.
        case helper(askedBy: String)
        /// The answer going back to the chat's bot, which finishes the job.
        case backToOwner(helper: String)
    }

    public var botId: String
    public var kind: Kind
    public var prompt: String
    /// Shown in the chat before the turn ("Planner asked Researcher for help: …").
    public var notice: String?
    /// Hops so far, including this turn.
    public var hops: Int
}

public enum DirectHandOff {
    public static let defaultMaxHops = 4

    /// Lines like "@researcher: find three sources" (or "@Researcher Bot: …") at the start of a line.
    /// Matches a bot by id, name, or name without spaces. One ask per bot; code is ignored.
    public static func asks(in text: String, among bots: [Bot]) -> [(bot: Bot, request: String)] {
        var out: [(bot: Bot, request: String)] = []
        var inFence = false
        for raw in text.split(separator: "\n") {
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); continue }
            if inFence { continue }
            let line = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "`", with: "")
                .replacingOccurrences(of: "**", with: "")
            guard line.hasPrefix("@"), let colon = line.firstIndex(of: ":") else { continue }
            let handle = line[line.index(after: line.startIndex)..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let request = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !handle.isEmpty, !request.isEmpty,
                  let helper = bots.first(where: { GroupPlan.matches(handle, id: $0.id, bot: $0) || $0.name.lowercased() == handle }),
                  !out.contains(where: { $0.bot.id == helper.id }) else { continue }
            out.append((helper, request))
        }
        return out
    }

    /// What runs next after `reply` from `speaker` in the 1:1 chat that belongs to `owner`.
    /// - `kind`: why the speaker was answering (nil: its own turn with you).
    /// - Only the chat's bot hands work out; a helper's answer goes back to it. Nothing runs at `maxHops`.
    public static func next(after reply: ChatMessage, speaker: Bot, kind: HandOffTurn.Kind?, owner: Bot, team: [Bot],
                            hops: Int, maxHops: Int = defaultMaxHops) -> [HandOffTurn] {
        guard reply.status == .done, reply.approval?.status != .pending, hops < maxHops else { return [] }
        if case .helper(let askedBy)? = kind {
            guard askedBy == owner.id, speaker.id != owner.id else { return [] }
            let prompt = "\(speaker.name) answered your question:\n\(reply.text)\n\nUse it to finish the job for me. Don't ask \(speaker.name) again unless you must."
            return [HandOffTurn(botId: owner.id, kind: .backToOwner(helper: speaker.id), prompt: prompt, notice: nil, hops: hops + 1)]
        }
        guard speaker.id == owner.id else { return [] }   // e.g. a review you asked for stays with you
        return asks(in: reply.text, among: team.filter { $0.id != owner.id }).map { helper, request in
            HandOffTurn(
                botId: helper.id, kind: .helper(askedBy: owner.id),
                prompt: "\(owner.name) is working on something for me and needs your help:\n\(request)\n\nAnswer \(owner.name) directly and briefly. Do the work if it's needed.",
                notice: "\(owner.name) asked \(helper.name) for help: \(request)", hops: hops + 1)
        }
    }
}

// MARK: - Reviews and huddles

public enum ReviewRequest {
    /// What the reviewer is asked. Runs in the same chat; the answer stays with you (no hand-off back).
    public static func prompt(authorName: String, text: String) -> String {
        "Please review this reply from \(authorName). Say what's good, what's wrong or missing, and exactly what you'd change. Be brief and specific.\n\n---\n\(text)"
    }

    public static func notice(reviewerName: String, authorName: String) -> String {
        "You asked \(reviewerName) to review \(authorName)'s reply."
    }
}

/// A huddle in a group: your question as a message, then `GroupOrchestrator.askEveryone()` (each member's view, then
/// the lead's summary and recommendation).
public enum Huddle {
    public static func message(_ topic: String) -> ChatMessage? {
        let t = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return ChatMessage(role: .user, text: "Huddle: \(t)")
    }

    public static func startedNotice(group: BotGroup, bots: [String: Bot]) -> String {
        let lead = group.lead.flatMap { bots[$0]?.name } ?? "the lead"
        let speakers = group.everyone.filter { $0 != group.lead }.compactMap { bots[$0]?.name }
        if speakers.isEmpty { return "Huddle started. \(lead) will think it through and sum up." }
        let who = speakers.count == 1 ? "\(speakers[0]) gives a view" : "\(speakers.joined(separator: ", ")) each give a view"
        return "Huddle started. \(who), then \(lead) sums up."
    }
}
