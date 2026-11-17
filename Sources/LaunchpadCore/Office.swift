import Foundation

// The Office page, the menu bar and notifications all ask the same questions: is a bot working, waiting on you, or
// free? These answers are worked out here so they can be tested without the app.

/// What a message is waiting for from you, if anything.
public enum Attention {
    /// "Waiting for your OK", "Asked you a question", "Wants you to start a plan", or nil.
    public static func reason(_ m: ChatMessage) -> String? {
        guard m.role == .bot, m.deleted != true else { return nil }
        if m.liveApprovals?.contains(where: { $0.state == .pending }) == true { return "Waiting for your OK" }
        if m.approval?.status == .pending { return "Waiting for your OK" }
        if let q = m.questions, !q.answered { return "Asked you a question" }
        if let p = m.plan, p.state == .waiting { return "Wants you to start a plan" }
        return nil
    }

    public static func waitsOnYou(_ m: ChatMessage) -> Bool { reason(m) != nil }

    /// The bot whose latest message in a chat waits on you (later messages from you mean it's been answered).
    /// Notices are skipped; side questions don't count.
    public static func waiting(in messages: [ChatMessage]) -> (botId: String, reason: String)? {
        for m in messages.reversed() where m.role != .notice && m.isSide != true {
            guard m.role == .bot, let botId = m.botId, let reason = reason(m) else { return nil }
            return (botId, reason)
        }
        return nil
    }
}

/// A bot's desk in the Office.
public enum DeskState: String, CaseIterable, Sendable {
    case needsYou, working, waiting, idle

    public var title: String {
        switch self {
        case .needsYou: return "Needs you"
        case .working: return "Working"
        case .waiting: return "Up next"
        case .idle: return "Free"
        }
    }

    /// Sort order: the desks that need you come first.
    public var order: Int {
        switch self {
        case .needsYou: return 0
        case .working: return 1
        case .waiting: return 2
        case .idle: return 3
        }
    }

    /// Needs you beats working (a bot waiting for your OK is still "running").
    public static func of(working: Bool, needsYou: Bool, queued: Bool) -> DeskState {
        if needsYou { return .needsYou }
        if working { return .working }
        if queued { return .waiting }
        return .idle
    }
}

/// What a bot is doing right now, in a few words, from its live reply.
public enum WorkSummary {
    public static func line(for reply: ChatMessage?, todos: [TodoItem] = []) -> String {
        guard let reply else { return "Starting…" }
        if let reason = Attention.reason(reply) { return reason }
        if let t = todos.first(where: { $0.status == .inProgress }) { return t.label }
        if let last = reply.steps.last { return StepLabel.describe(last).text }
        return reply.text.isEmpty ? "Thinking…" : "Writing a reply…"
    }
}

// MARK: - Back and forward

/// Back / forward history across pages and chats (⌘[ and ⌘]).
public struct NavigationHistory<Spot: Equatable>: Equatable {
    public private(set) var back: [Spot] = []
    public private(set) var forward: [Spot] = []
    public var limit: Int

    public init(limit: Int = 50) { self.limit = limit }

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }

    /// You moved somewhere new: the old spot goes on the back stack and forward is cleared.
    public mutating func visit(from old: Spot, to new: Spot) {
        guard old != new else { return }
        if back.last != old { back.append(old) }
        if back.count > limit { back.removeFirst(back.count - limit) }
        forward.removeAll()
    }

    /// Where Back goes (nil: nothing there). `current` moves to the forward stack.
    public mutating func goBack(from current: Spot) -> Spot? {
        guard let spot = back.popLast() else { return nil }
        forward.append(current)
        return spot
    }

    public mutating func goForward(from current: Spot) -> Spot? {
        guard let spot = forward.popLast() else { return nil }
        back.append(current)
        return spot
    }

    /// Drops spots that no longer exist (a deleted chat, say).
    public mutating func removeAll(where gone: (Spot) -> Bool) {
        back.removeAll(where: gone)
        forward.removeAll(where: gone)
    }
}

// MARK: - Notifications

/// The text of a "bot finished" or "bot needs you" notification.
public struct ReplyNotice: Equatable, Sendable {
    public var title: String
    public var body: String
    public var needsYou: Bool

    public init(title: String, body: String, needsYou: Bool) {
        self.title = title
        self.body = body
        self.needsYou = needsYou
    }

    /// For a reply that has ended. nil when there's nothing worth a notification (a stopped, empty reply).
    public static func finished(_ m: ChatMessage, botName: String, chatTitle: String, isGroup: Bool) -> ReplyNotice? {
        let place = isGroup ? " in \(chatTitle)" : ""
        if let reason = Attention.reason(m) {
            return ReplyNotice(title: "\(botName) needs you\(place)", body: summary(m, fallback: reason), needsYou: true)
        }
        switch m.status {
        case .failed:
            return ReplyNotice(title: "\(botName) got stuck\(place)", body: m.failure?.message ?? "Couldn't finish.", needsYou: false)
        case .stopped:
            return nil
        default:
            let text = summary(m, fallback: "")
            guard !text.isEmpty else { return nil }
            return ReplyNotice(title: "\(botName) replied\(place)", body: text, needsYou: false)
        }
    }

    /// For an approval card raised while the reply is still running.
    public static func approval(_ card: LiveApproval, botName: String) -> ReplyNotice {
        let wants = card.kind?.wants ?? "do something"
        return ReplyNotice(title: "\(botName) needs your OK", body: "Wants to \(wants): \(ToolNames.readable(card.tool))", needsYou: true)
    }

    static func summary(_ m: ChatMessage, fallback: String) -> String {
        let flat = m.text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespaces)
        let text = flat.isEmpty ? fallback : flat
        return text.count > 180 ? String(text.prefix(180)) + "…" : text
    }
}
