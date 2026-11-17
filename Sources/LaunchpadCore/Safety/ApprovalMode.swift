import Foundation

/// How a group's bots treat actions that would normally show an approval card. Saved in group.json as `approvals`.
public enum ApprovalMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Bots' Ask rules show an approval card and wait for you.
    case ask
    /// Anything a bot's rules would ask about goes through without a card.
    case fullFreedom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ask: return "Ask me"
        case .fullFreedom: return "Full freedom"
        }
    }

    public var detail: String {
        switch self {
        case .ask: return "Bots ask before sending, deleting, spending, pushing or deploying."
        case .fullFreedom: return "Bots send, delete, spend, push and deploy without asking. Anything set to Never stays off, and locked-down bots still ask."
        }
    }

    /// The line the chat shows when the mode changes.
    public var notice: String {
        switch self {
        case .ask: return "Ask me is on: bots in this group ask before risky actions again."
        case .fullFreedom: return "Full freedom is on: bots in this group act without asking. Type \"ask mode\" to switch back."
        }
    }

    /// Whether this bot's Ask rules are skipped. Never rules, locked skills and Launchpad's own files are not
    /// affected, and a locked-down bot keeps asking: locking it down was a choice about that bot.
    public func skipsApprovals(for bot: Bot) -> Bool {
        self == .fullFreedom && !bot.lockedDown
    }

    static let commands: [String: ApprovalMode] = [
        "accept mode": .fullFreedom, "/accept": .fullFreedom, "full freedom": .fullFreedom, "full freedom mode": .fullFreedom,
        "ask mode": .ask, "/ask": .ask, "ask me": .ask, "ask me mode": .ask,
    ]

    /// "accept mode" or "ask mode" typed as a whole message (any case, a full stop or "!" allowed) switches the
    /// mode. A longer message that only mentions the words is an ordinary message.
    public static func command(in text: String) -> ApprovalMode? {
        let t = text.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!")))
        return commands[t.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")]
    }
}
