import Foundation

/// A short recap of a chat, for a model that hasn't seen it: a fresh session after Compact or Branch, a lost
/// session, the backup brain, or a side question without a session to fork.
public enum ConversationRecap {
    public static let defaultLimit = 12
    public static let perMessage = 1500

    /// "User: …" / "<bot name>: …" lines for the newest `limit` messages that count (no notices, failures or
    /// half-written replies).
    public static func lines(_ messages: [ChatMessage], names: [String: String] = [:], limit: Int = defaultLimit,
                             perMessage: Int = perMessage) -> [String] {
        messages.filter(counts).suffix(limit).map { m in
            let text = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = text.count > perMessage ? String(text.prefix(perMessage)) + "…" : text
            return "\(speaker(m, names: names)): \(body)"
        }
    }

    public static func text(_ messages: [ChatMessage], names: [String: String] = [:], limit: Int = defaultLimit) -> String {
        lines(messages, names: names, limit: limit).joined(separator: "\n")
    }

    /// The prompt with a recap in front, or just the prompt when there's nothing to recap.
    public static func seed(prompt: String, recap: String,
                            header: String = "Recent conversation so far (you don't have it in memory):") -> String {
        guard !recap.isEmpty else { return prompt }
        return "\(header)\n\(recap)\n\n---\nNew message: \(prompt)"
    }

    /// What to send for this turn.
    ///
    /// - No session (Compact, Branch, a lost session, a backup engine): the recent chat goes in front.
    /// - A session that missed some messages (`unseenAfter`: the id of the last message it saw, e.g. after the
    ///   backup brain answered for it): those messages go in front.
    /// - Otherwise the prompt as it is.
    ///
    /// `history` is the chat; if it ends with the user's message being sent, that isn't recapped.
    ///
    /// With a `summary` (a compaction) and no session, the bot gets the summary and then only the messages after
    /// `summarizedThrough`, instead of the last few messages with nothing before them.
    public static func prompt(for prompt: String, history: [ChatMessage], hasSession: Bool, unseenAfter: String? = nil,
                              names: [String: String] = [:], limit: Int = defaultLimit,
                              summary: String? = nil, summarizedThrough: String? = nil) -> String {
        var earlier = history
        if let last = earlier.last, last.role == .user,
           last.text.trimmingCharacters(in: .whitespacesAndNewlines) == prompt.trimmingCharacters(in: .whitespacesAndNewlines) {
            earlier.removeLast()
        }
        if !hasSession, let summary, !summary.isEmpty {
            if let through = summarizedThrough, let i = earlier.firstIndex(where: { $0.id == through }) {
                earlier = Array(earlier[earlier.index(after: i)...])
            }
            let recent = text(earlier, names: names, limit: limit)
            var recap = "Summary of the earlier conversation (it was compacted to save space; the full chat is still on screen):\n\(summary)"
            if !recent.isEmpty { recap += "\n\nThe most recent messages:\n\(recent)" }
            return "\(recap)\n\n---\nNew message: \(prompt)"
        }
        if !hasSession {
            return seed(prompt: prompt, recap: text(earlier, names: names, limit: limit))
        }
        if let unseenAfter, let i = earlier.firstIndex(where: { $0.id == unseenAfter }) {
            let missed = Array(earlier[earlier.index(after: i)...])
            return seed(prompt: prompt, recap: text(missed, names: names, limit: limit),
                        header: "While you were away, this happened in the chat:")
        }
        return prompt
    }

    /// A title for a thread: its first message from you, on one line.
    public static func title(_ messages: [ChatMessage], fallback: String = "Conversation") -> String {
        let first = messages.first { $0.role == .user && !$0.text.isEmpty }?.text ?? fallback
        let line = first.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return line.count > 60 ? String(line.prefix(59)) + "…" : line
    }

    static func counts(_ m: ChatMessage) -> Bool {
        guard m.role != .notice, !m.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return m.role == .user || m.status == .done || m.status == .stopped
    }

    static func speaker(_ m: ChatMessage, names: [String: String]) -> String {
        if m.role == .user { return "User" }
        return m.botId.flatMap { names[$0] } ?? "Assistant"
    }
}

// MARK: - Backup brain

/// An engine and model a bot can run on.
public struct BotBrain: Codable, Hashable, Sendable {
    public var engine: BotEngine
    public var model: String?
    /// Local engine only (nil = Ollama's default address).
    public var localBaseURL: String?

    public init(engine: BotEngine, model: String? = nil, localBaseURL: String? = nil) {
        self.engine = engine
        self.model = (model?.isEmpty ?? true) ? nil : model
        self.localBaseURL = (localBaseURL?.isEmpty ?? true) ? nil : localBaseURL
    }

    enum CodingKeys: String, CodingKey { case engine, model, localBaseURL }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(engine: (try? c.decodeIfPresent(BotEngine.self, forKey: .engine)) ?? .claude,
                  model: try? c.decodeIfPresent(String.self, forKey: .model),
                  localBaseURL: try? c.decodeIfPresent(String.self, forKey: .localBaseURL))
    }

    /// "Codex · gpt-5" or "Claude Code".
    public var label: String { model.map { "\(engine.displayName) · \($0)" } ?? engine.displayName }
}

extension Bot {
    /// The engine and model this bot runs on.
    public var brain: BotBrain { BotBrain(engine: engine, model: model, localBaseURL: localBaseURL) }

    /// The same bot running on another engine and model (for one backup turn). Its permissions, rules, connectors
    /// and folder stay the same.
    public func running(on brain: BotBrain) -> Bot {
        var copy = self
        copy.engine = brain.engine
        copy.model = brain.model
        copy.localBaseURL = brain.localBaseURL ?? (brain.engine == .local ? localBaseURL : nil)
        copy.backup = nil
        return copy
    }
}

/// When a bot hits its plan's usage limit, it can answer once on its backup engine with a recap of the chat.
public enum BackupPolicy {
    /// The brain to retry on, or nil: only after a usage-limit failure, only once, and only to something different.
    public static func retryBrain(after failure: RunFailure?, bot: Bot, alreadyOnBackup: Bool) -> BotBrain? {
        guard !alreadyOnBackup, failure?.kind == .usageLimit, let backup = bot.backup else { return nil }
        if backup.engine == bot.engine && backup.model == bot.model
            && (backup.engine != .local || backup.localBaseURL == bot.localBaseURL) { return nil }
        return backup
    }

    /// The backup has no session of its own here, so it gets the recent chat (a local backup gets the whole chat as
    /// history instead: put `history` in `RunOptions.history` and send the prompt as it is).
    public static func prompt(_ prompt: String, history: [ChatMessage], names: [String: String] = [:], backup: BotBrain) -> String {
        if backup.engine == .local { return prompt }
        return ConversationRecap.prompt(for: prompt, history: history, hasSession: false, names: names)
    }

    /// The notice shown in the chat.
    public static func notice(botName: String, from: BotBrain, to: BotBrain) -> String {
        "\(from.engine.displayName) hit your \(from.engine.planName) plan's usage limit, so \(botName) answered on \(to.label) instead."
    }
}
