import Foundation

// Chat features: reactions, pins, saved messages, edit, delete, forward, attachments, polls, GIFs, plan cards and
// question cards. The types live on `ChatMessage` (all optional); `ChatOps` holds the pure operations. The app saves a
// changed message by appending it to the chat's JSONL again (`ChatStore.update`): the latest line with an id wins.

// MARK: - Types

/// An earlier version of a message's text, kept when it's edited.
public struct MessageEdit: Codable, Hashable, Sendable {
    public var text: String
    /// When it was replaced.
    public var replacedAt: Date

    public init(text: String, replacedAt: Date) {
        self.text = text
        self.replacedAt = replacedAt
    }
}

/// A GIF (from GIPHY). `url` is the animated image; `preview` a smaller one for pickers.
public struct GifRef: Codable, Hashable, Sendable {
    public var url: String
    public var width: Double
    public var height: Double
    public var title: String?
    public var preview: String?

    public init(url: String, width: Double, height: Double, title: String? = nil, preview: String? = nil) {
        self.url = url
        self.width = width
        self.height = height
        self.title = title
        self.preview = preview
    }
}

public struct Poll: Codable, Hashable, Sendable {
    public static let maxOptions = 8

    public var question: String
    public var options: [String]
    /// Voter (`ChatOps.you` or a bot id) -> option index (from 0).
    public var votes: [String: Int]
    /// Short reasons bots gave with their vote.
    public var reasons: [String: String]?

    public init(question: String, options: [String], votes: [String: Int] = [:], reasons: [String: String]? = nil) {
        self.question = question
        self.options = options
        self.votes = votes
        self.reasons = reasons
    }

    /// Who voted for option `index`, sorted (you first).
    public func voters(_ index: Int) -> [String] {
        votes.filter { $0.value == index }.map(\.key).sorted { a, b in
            a == ChatOps.you ? true : b == ChatOps.you ? false : a < b
        }
    }

    public var counts: [Int] { options.indices.map { i in votes.values.filter { $0 == i }.count } }

    /// "Poll: Question\n1. A\n2. B"
    public var asText: String {
        "Poll: \(question)\n" + options.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }
}

/// A bot's plan for a long task: Start / Cancel. With a countdown (`autoStart` seconds) nobody answering means Start.
public struct PlanCard: Codable, Hashable, Sendable {
    public enum State: String, Codable, Sendable { case waiting, started, cancelled }

    public var message: String
    public var steps: [String]
    public var state: State
    public var shownAt: Date
    /// Seconds before it starts by itself (nil = it waits for your OK).
    public var autoStart: Int?

    public init(message: String, steps: [String], state: State = .waiting, shownAt: Date = Date(), autoStart: Int? = nil) {
        self.message = message
        self.steps = steps
        self.state = state
        self.shownAt = shownAt
        self.autoStart = autoStart
    }

    /// Whole seconds left on the countdown (nil when there's no countdown or it's been answered).
    public func secondsLeft(now: Date) -> Int? {
        guard state == .waiting, let auto = autoStart, auto > 0 else { return nil }
        return max(0, Int((shownAt.addingTimeInterval(TimeInterval(auto)).timeIntervalSince(now)).rounded(.up)))
    }

    /// The countdown has run out: show it as started (the chat tool starts by itself at the same moment).
    public func isDue(now: Date) -> Bool { secondsLeft(now: now) == 0 }
}

/// Questions a bot asked as tappable choices. Your answers go back to it as your next message.
public struct QuestionCard: Codable, Hashable, Sendable {
    public struct Item: Codable, Hashable, Sendable {
        public var text: String
        public var options: [String]
        public var multi: Bool

        public init(text: String, options: [String], multi: Bool = false) {
            self.text = text
            self.options = options
            self.multi = multi
        }

        enum CodingKeys: String, CodingKey { case text, options, multi }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decode(String.self, forKey: .text)
            options = try c.decodeIfPresent([String].self, forKey: .options) ?? []
            multi = try c.decodeIfPresent(Bool.self, forKey: .multi) ?? false
        }
    }

    public var items: [Item]
    public var answered: Bool
    /// What you sent, one per question.
    public var answers: [String]?

    public init(items: [Item], answered: Bool = false, answers: [String]? = nil) {
        self.items = items
        self.answered = answered
        self.answers = answers
    }
}

/// How long a plan card waits for Start before going ahead by itself (an app setting). 0 = wait for your OK.
public enum PlanWait {
    public static let options: [(title: String, seconds: Int)] = [
        ("Wait for my OK", 0), ("Start after 10 seconds", 10), ("Start after 30 seconds", 30), ("Start after 1 minute", 60),
    ]

    public static func title(_ seconds: Int) -> String {
        options.first { $0.seconds == seconds }?.title ?? "Start after \(seconds) seconds"
    }
}

public struct ReactionSummary: Equatable, Sendable {
    public var emoji: String
    public var who: [String]
}

// MARK: - Operations

public enum ChatOps {
    /// Who "you" are in reactions and votes. Bots are their ids.
    public static let you = "you"

    // Reactions

    /// Adds or removes `who`'s `emoji`.
    public static func toggleReaction(_ m: ChatMessage, emoji: String, by who: String = you) -> ChatMessage {
        let e = normalisedEmoji(emoji)
        guard !e.isEmpty, m.deleted != true else { return m }
        var out = m
        var r = m.reactions ?? [:]
        var list = r[e] ?? []
        if list.contains(who) { list.removeAll { $0 == who } } else { list.append(who) }
        r[e] = list.isEmpty ? nil : list
        out.reactions = r.isEmpty ? nil : r
        return out
    }

    /// Adds `who`'s `emoji` (never removes it): what a bot's `react` does.
    public static func react(_ m: ChatMessage, emoji: String, by who: String) -> ChatMessage {
        let e = normalisedEmoji(emoji)
        if m.reactions?[e]?.contains(who) == true { return m }
        return toggleReaction(m, emoji: e, by: who)
    }

    /// Most reacted first, then alphabetical (so the order is stable).
    public static func reactions(of m: ChatMessage) -> [ReactionSummary] {
        (m.reactions ?? [:]).filter { !$0.value.isEmpty }
            .map { ReactionSummary(emoji: $0.key, who: $0.value) }
            .sorted { $0.who.count != $1.who.count ? $0.who.count > $1.who.count : $0.emoji < $1.emoji }
    }

    /// One emoji: the first character, with whitespace trimmed ("🎉🎉" -> "🎉", "👍🏽" stays whole).
    public static func normalisedEmoji(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).first.map(String.init) ?? ""
    }

    // Pin and save

    public static func togglePin(_ m: ChatMessage) -> ChatMessage {
        var out = m
        out.pinned = m.pinned == true ? nil : true
        return out
    }

    public static func toggleSave(_ m: ChatMessage) -> ChatMessage {
        var out = m
        out.saved = m.saved == true ? nil : true
        return out
    }

    public static func pinned(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.filter { $0.pinned == true && $0.deleted != true }
    }

    public static func saved(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.filter { $0.saved == true && $0.deleted != true }
    }

    // Edit and delete

    /// The message with new text, the old text kept in `edits`. nil when nothing changes (empty, same, deleted).
    public static func edit(_ m: ChatMessage, to text: String, at now: Date = Date()) -> ChatMessage? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != m.text, m.deleted != true else { return nil }
        var out = m
        out.edits = (m.edits ?? []) + [MessageEdit(text: m.text, replacedAt: now)]
        out.text = t
        return out
    }

    public static func isEdited(_ m: ChatMessage) -> Bool { !(m.edits ?? []).isEmpty }

    /// A tombstone: same id and time, nothing left of what it said.
    public static func delete(_ m: ChatMessage) -> ChatMessage {
        var out = m
        out.deleted = true
        out.text = ""
        out.steps = []
        out.edits = nil
        out.gif = nil
        out.poll = nil
        out.plan = nil
        out.questions = nil
        out.attachments = nil
        out.reactions = nil
        out.pinned = nil
        out.saved = nil
        out.approval = nil
        out.failure = nil
        return out
    }

    // Forward

    /// A copy of `m` to send in another chat, from you, marked as forwarded from `fromName`.
    public static func forward(_ m: ChatMessage, fromName: String, at now: Date = Date(),
                               newId: String = UUID().uuidString.lowercased()) -> ChatMessage? {
        guard m.deleted != true else { return nil }
        var text = m.text
        if text.isEmpty, let p = m.poll { text = p.asText }
        if text.isEmpty, let g = m.gif { text = g.url }
        guard !text.isEmpty || !(m.attachments ?? []).isEmpty else { return nil }
        var out = ChatMessage(id: newId, role: .user, text: text, createdAt: now)
        out.forwardedFrom = fromName
        out.attachments = m.attachments
        return out
    }

    /// What the receiving bot is told for a forwarded message.
    public static func forwardPrompt(_ m: ChatMessage) -> String {
        var text = "Forwarded from \(m.forwardedFrom ?? "someone"):\n\(m.text)"
        text += Attachments.note(m.attachments ?? [])
        return text
    }

    // Short descriptions

    /// One line for a pinned bar, search result or notification.
    public static func summary(_ m: ChatMessage) -> String {
        if m.deleted == true { return "Deleted message" }
        let text = m.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { return text }
        if let p = m.poll { return "Poll: \(p.question)" }
        if let g = m.gif { return g.title.map { "GIF: \($0)" } ?? "GIF" }
        if let a = m.attachments, let first = a.first {
            return "📎 " + (first as NSString).lastPathComponent + (a.count > 1 ? " and \(a.count - 1) more" : "")
        }
        if let plan = m.plan { return plan.message }
        if let q = m.questions?.items.first { return q.text }
        return ""
    }

    /// What a bot should read for a message in its context: the text plus a word on any GIF, poll or files.
    public static func contextText(_ m: ChatMessage) -> String {
        if m.deleted == true { return "(deleted a message)" }
        var parts: [String] = []
        if let from = m.forwardedFrom { parts.append("(forwarded from \(from))") }
        if !m.text.isEmpty { parts.append(m.text) }
        if let g = m.gif { parts.append("(sent a GIF\(g.title.map { ": \($0)" } ?? ""))") }
        if let p = m.poll { parts.append("(" + p.asText + ")") }
        if let a = m.attachments, !a.isEmpty { parts.append("(attached: \(a.joined(separator: ", ")))") }
        return parts.joined(separator: "\n")
    }

    // Polls

    /// A poll from what you typed: needs a question and at least two options (empty ones dropped, at most 8).
    public static func makePoll(question: String, options: [String]) -> Poll? {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let opts = options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !q.isEmpty, opts.count >= 2 else { return nil }
        return Poll(question: q, options: Array(opts.prefix(Poll.maxOptions)))
    }

    /// `option` counts from 0. nil when it's out of range.
    public static func vote(_ poll: Poll, by who: String, option: Int, reason: String? = nil) -> Poll? {
        guard poll.options.indices.contains(option) else { return nil }
        var p = poll
        p.votes[who] = option
        if let r = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty {
            var reasons = p.reasons ?? [:]
            reasons[who] = String(r.prefix(140))
            p.reasons = reasons
        }
        return p
    }

    /// What the bots are told when you start a poll and ask them to vote.
    public static func askToVotePrompt(_ poll: Poll) -> String {
        "I started a poll: \(poll.question)\n"
            + poll.options.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            + "\n\nVote with your vote tool (or a line [vote: number]) and say why in one short sentence."
    }

    /// What a bot is told when you vote in its poll.
    public static func youVotedPrompt(_ poll: Poll, option: Int) -> String? {
        guard poll.options.indices.contains(option) else { return nil }
        return "(I voted “\(poll.options[option])” in your poll: \(poll.question).)"
    }

    // Plan cards

    /// Start or Cancel. nil when the card isn't waiting any more.
    public static func answerPlan(_ card: PlanCard, start: Bool) -> PlanCard? {
        guard card.state == .waiting else { return nil }
        var c = card
        c.state = start ? .started : .cancelled
        return c
    }

    // Question cards

    /// Your answers (one per question). Returns the answered card and the message to send to the bot, which quotes
    /// each question so it reads clearly. `mention`: in a group, the bot that asked ("@planner …").
    public static func answer(_ card: QuestionCard, with answers: [String], mention: String? = nil) -> (card: QuestionCard, prompt: String)? {
        let trimmed = answers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !card.answered, trimmed.count == card.items.count, trimmed.allSatisfy({ !$0.isEmpty }) else { return nil }
        var c = card
        c.answered = true
        c.answers = trimmed
        var text = zip(card.items, trimmed).map { "\($0.text) \($1)" }.joined(separator: "\n")
        if let mention, !mention.isEmpty { text = "@\(mention) " + text }
        return (c, text)
    }
}

// MARK: - Natural pacing (several short texts instead of one bubble)

public enum TextPacing {
    public static let maxTotal = 900
    public static let maxPart = 320

    /// A reply made of 2–4 short paragraphs, split the way a person texts. nil keeps it as one message: code, lists,
    /// headings, long replies, or a single paragraph.
    public static func split(_ text: String) -> [String]? {
        guard !text.contains("```"), text.count <= maxTotal else { return nil }
        let parts = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard (2...4).contains(parts.count), parts.allSatisfy({ $0.count <= maxPart }) else { return nil }
        for p in parts {
            if p.hasPrefix("#") || p.hasPrefix("|") || p.hasPrefix(">") { return nil }
            for line in p.split(separator: "\n") {
                let l = line.trimmingCharacters(in: .whitespaces)
                if l.hasPrefix("- ") || l.hasPrefix("* ") || l.hasPrefix("+ ") { return nil }
                if let dot = l.firstIndex(of: "."), dot > l.startIndex, l[l.startIndex..<dot].allSatisfy(\.isNumber) { return nil }
            }
        }
        return parts
    }

    /// How long "typing…" shows before part `text` appears.
    public static func typingDelay(for text: String) -> TimeInterval {
        min(1.6, 0.5 + Double(text.count) * 0.012)
    }

    /// A finished reply as several messages. The first keeps the reply's id (and its steps, cost and cards); the
    /// rest are new messages a moment apart; a GIF moves to the last. Returns `[m]` when it shouldn't be split
    /// (a poll, plan, questions, files, an approval, a failure, or text that doesn't split).
    public static func splitIntoTexts(_ m: ChatMessage, newId: () -> String = { UUID().uuidString.lowercased() }) -> [ChatMessage] {
        guard m.role == .bot, m.status == .done, m.poll == nil, m.plan == nil, m.questions == nil,
              (m.attachments ?? []).isEmpty, m.approval == nil, m.failure == nil,
              let parts = split(m.text) else { return [m] }
        var first = m
        first.text = parts[0]
        first.gif = nil
        var out = [first]
        var at = m.createdAt
        for (i, part) in parts.dropFirst().enumerated() {
            at = at.addingTimeInterval(typingDelay(for: part))
            var next = ChatMessage(id: newId(), role: .bot, botId: m.botId, text: part, status: .done, createdAt: at)
            if i == parts.count - 2 { next.gif = m.gif }
            out.append(next)
        }
        return out
    }
}

// MARK: - Saving changes

extension ChatStore {
    /// Changes one message and saves it by appending it again (the latest line wins). Returns the new message,
    /// or nil when there's no such message or `change` returns nil.
    @discardableResult
    public func update(messageId: String, chatId: String, _ change: (ChatMessage) -> ChatMessage?) throws -> ChatMessage? {
        guard let m = messages(chatId: chatId).first(where: { $0.id == messageId }), let changed = change(m) else { return nil }
        guard changed != m else { return m }
        try append(changed, chatId: chatId)
        return changed
    }

    /// Saved messages across chats, newest first.
    public func savedMessages(chatIds: [String]) -> [(chatId: String, message: ChatMessage)] {
        chatIds.flatMap { id in ChatOps.saved(messages(chatId: id)).map { (id, $0) } }
            .sorted { $0.message.createdAt > $1.message.createdAt }
    }
}
