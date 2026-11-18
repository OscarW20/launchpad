import Foundation

// The app's own compaction step: summarise the older turns of a chat, keep the latest word for word, and start the
// bots that were too full from the summary. Claude and Codex also compact by themselves (`EngineCompaction`); this
// step is for a local model (the app builds its history), for the Compact button, and as a fallback when an engine's
// own setting hasn't brought a chat back down.
//
// Nothing is deleted. The messages stay in the chat's log; a record says which ones the summary covers so the app can
// mark them, and the summary itself is kept (in `.launchpad/compactions`, where bots can't write it, because it gets
// put in front of a bot later).

/// One compaction of one chat.
public struct CompactionRecord: Codable, Identifiable, Hashable, Sendable {
    public enum Trigger: String, Codable, Sendable { case auto, manual }

    public var id: String
    public var chatId: String
    public var at: Date
    public var trigger: Trigger
    /// The last message the summary covers. Messages after it are kept word for word.
    public var throughMessageId: String
    /// How many messages are behind the summary (this time, not counting earlier summaries).
    public var summarizedCount: Int
    /// Older messages that were too many to show the summariser, so the summary may not cover them.
    public var omittedCount: Int
    public var summary: String
    /// How full the fullest session was when this ran, 0 to 1.
    public var fractionBefore: Double?
    public var engine: BotEngine?

    public init(id: String = UUID().uuidString.lowercased(), chatId: String, at: Date = Date(), trigger: Trigger,
                throughMessageId: String, summarizedCount: Int, omittedCount: Int = 0, summary: String,
                fractionBefore: Double? = nil, engine: BotEngine? = nil) {
        self.id = id
        self.chatId = chatId
        self.at = at
        self.trigger = trigger
        self.throughMessageId = throughMessageId
        self.summarizedCount = summarizedCount
        self.omittedCount = omittedCount
        self.summary = summary
        self.fractionBefore = fractionBefore
        self.engine = engine
    }
}

public enum CompactionError: Error, LocalizedError, Equatable {
    case nothingToCompact
    case emptySummary

    public var errorDescription: String? {
        switch self {
        case .nothingToCompact: return "There isn't enough older conversation to summarise yet."
        case .emptySummary: return "The summary came back empty, so nothing was compacted and the chat is unchanged."
        }
    }
}

/// Where a chat's compaction records and last context readings are kept: `.launchpad/compactions/`.
public struct CompactionLog {
    public let paths: LaunchpadPaths

    public init(paths: LaunchpadPaths) {
        self.paths = paths
    }

    public var folder: URL { paths.launchpadData.appendingPathComponent("compactions", isDirectory: true) }
    func file(_ chatId: String) -> URL { folder.appendingPathComponent(Slug.make(chatId) + ".json") }
    func readingsFile(_ chatId: String) -> URL { folder.appendingPathComponent(Slug.make(chatId) + ".readings.json") }

    /// Every compaction of the chat, oldest first.
    public func records(_ chatId: String) -> [CompactionRecord] {
        guard let data = try? Data(contentsOf: file(chatId)) else { return [] }
        return (try? JSONCoding.decoder().decode([CompactionRecord].self, from: data)) ?? []
    }

    public func latest(_ chatId: String) -> CompactionRecord? { records(chatId).last }

    public func append(_ record: CompactionRecord) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONCoding.encoder().encode(records(record.chatId) + [record]).write(to: file(record.chatId), options: .atomic)
    }

    /// The ids of the messages a summary stands in for, from the start of the chat up to the latest compaction.
    public func summarizedIds(_ chatId: String, in messages: [ChatMessage]) -> Set<String> {
        guard let through = latest(chatId)?.throughMessageId, let i = messages.firstIndex(where: { $0.id == through }) else { return [] }
        return Set(messages[...i].map(\.id))
    }

    // MARK: Readings

    /// The last context reading for each bot's session in a chat, so the meter and the auto-compact rule still have
    /// something to go on after Launchpad restarts.
    public func readings(_ chatId: String) -> [String: ContextUsage] {
        guard let data = try? Data(contentsOf: readingsFile(chatId)) else { return [:] }
        return (try? JSONCoding.decoder().decode([String: ContextUsage].self, from: data)) ?? [:]
    }

    public func saveReading(_ usage: ContextUsage, chatId: String, botId: String) throws {
        var all = readings(chatId)
        guard all[botId] != usage else { return }
        all[botId] = usage
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONCoding.encoder().encode(all).write(to: readingsFile(chatId), options: .atomic)
    }

    /// After a bot's session is cleared its old reading no longer applies.
    public func clearReadings(_ chatId: String, botIds: [String]?) throws {
        guard let botIds else { try? FileManager.default.removeItem(at: readingsFile(chatId)); return }
        var all = readings(chatId)
        for id in botIds { all[id] = nil }
        try JSONCoding.encoder().encode(all).write(to: readingsFile(chatId), options: .atomic)
    }
}

public enum ChatCompaction {
    /// Fewer older messages than this aren't worth a summary.
    public static let minimumToSummarise = 4
    public static let maxSummaryCharacters = 8_000
    /// The most text shown to the summariser; the oldest messages beyond it are left out (and counted).
    public static let maxTranscriptCharacters = 200_000
    static let perMessageCeiling = 2_500
    static let perMessageFloor = 300
    static let transcriptBudget = 60_000

    /// What to summarise and what to keep.
    public struct Plan: Equatable, Sendable {
        public var older: [ChatMessage]
        public var recent: [ChatMessage]
        /// The summary so far, to be brought up to date rather than redone from the start.
        public var previous: CompactionRecord?
        public var throughMessageId: String { older.last?.id ?? "" }
    }

    /// Splits a chat into the older turns to summarise and the latest `keepRecent` to keep verbatim. Only messages
    /// that count (yours and finished replies; no notices or half-written ones). nil when there isn't enough to
    /// summarise. With an earlier summary only what came after it is considered.
    public static func plan(messages: [ChatMessage], previous: CompactionRecord?, keepRecent: Int) -> Plan? {
        var fresh = messages
        if let previous, let i = messages.firstIndex(where: { $0.id == previous.throughMessageId }) {
            fresh = Array(messages[messages.index(after: i)...])
        }
        let counting = fresh.filter(ConversationRecap.counts)
        let keep = max(2, keepRecent)
        guard counting.count - keep >= minimumToSummarise else { return nil }
        return Plan(older: Array(counting.dropLast(keep)), recent: Array(counting.suffix(keep)), previous: previous)
    }

    /// The older messages as lines for the summariser, each cut to share the budget, and how many of the oldest had to
    /// be left out because even then there was too much.
    static func transcript(for plan: Plan, names: [String: String] = [:]) -> (lines: [String], omitted: Int) {
        let perMessage = min(perMessageCeiling, max(perMessageFloor, transcriptBudget / max(1, plan.older.count)))
        var lines = ConversationRecap.lines(plan.older, names: names, limit: plan.older.count, perMessage: perMessage)
        var omitted = 0
        var total = lines.reduce(0) { $0 + $1.count + 1 }
        while total > maxTranscriptCharacters, !lines.isEmpty { total -= lines.removeFirst().count + 1; omitted += 1 }
        return (lines, omitted)
    }

    /// The prompt for the one-off run that writes the summary (any engine; no tools needed).
    public static func prompt(for plan: Plan, names: [String: String] = [:]) -> String {
        let (lines, omitted) = transcript(for: plan, names: names)

        var text = """
        You're compacting a long chat so the people in it can carry on with much less to read. Write a summary of the \
        conversation below that a teammate could pick the work up from.

        Keep: what the person wants and why, decisions made and the reasons, the current state of the work, names, \
        ids, paths, links and commands that matter, what's still open and who owns it, and the person's stated preferences. \
        Leave out greetings, chit-chat and tool noise.
        Never include passwords, keys, tokens, card numbers or other secrets: write [redacted] instead.
        Write plain text with short bullet points, no more than about 500 words, and output only the summary.

        """
        if let previous = plan.previous {
            text += "\nThe summary so far (bring it up to date with the newer messages below; keep what's still true and drop what isn't):\n\(previous.summary)\n"
        }
        if omitted > 0 { text += "\n(The \(omitted) oldest messages of this stretch were too long to include here.)\n" }
        text += "\nMessages to summarise:\n" + lines.joined(separator: "\n")
        return text
    }

    /// Turns what the summariser wrote into a record: tidied, secrets redacted, capped. Throws if it's empty.
    public static func record(fromSummary raw: String, plan: Plan, chatId: String, trigger: CompactionRecord.Trigger,
                              fractionBefore: Double? = nil, engine: BotEngine? = nil, now: Date = Date()) throws -> CompactionRecord {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
            if let close = text.range(of: "```", options: .backwards) { text = String(text[..<close.lowerBound]) }
        }
        // The summary is put in front of a bot later, so it gets the same cleaning as text captured from other apps:
        // secrets redacted, hidden characters removed.
        text = TicketPrompt.sanitize(MemoryBook.redact(text))
        guard text.count >= 20, !plan.throughMessageId.isEmpty else { throw CompactionError.emptySummary }
        if text.count > maxSummaryCharacters {
            var cut = String(text.prefix(maxSummaryCharacters))
            if let nl = cut.range(of: "\n", options: .backwards), cut.distance(from: nl.upperBound, to: cut.endIndex) < 400 { cut = String(cut[..<nl.lowerBound]) }
            text = cut + "\n…(summary cut to fit)"
        }
        return CompactionRecord(chatId: chatId, at: now, trigger: trigger, throughMessageId: plan.throughMessageId,
                                summarizedCount: plan.older.count, omittedCount: transcript(for: plan).omitted, summary: text,
                                fractionBefore: fractionBefore, engine: engine)
    }

    /// The line to post in the chat when a compaction happens.
    public static func notice(_ record: CompactionRecord) -> String {
        let how = record.trigger == .auto ? "Compacted automatically" : "Compacted"
        let at = record.fractionBefore.map { " at \(Int(($0 * 100).rounded()))% full" } ?? ""
        var text = "\(how)\(at): \(record.summarizedCount) earlier messages are now a summary for the bots, and the latest stay as they were. "
            + "The whole chat is still here, and the summarised messages are marked."
        if record.omittedCount > 0 {
            text += " \(record.omittedCount) of the oldest were too long to include in the summary, so it may not cover them."
        }
        return text
    }
}

// MARK: - When it may run

/// Whether a chat should be compacted now. The rule that matters: never while a bot is replying in it.
public enum ContextAdvisor {
    public enum SkipReason: Equatable, Sendable {
        /// A bot is replying. Compacting then would pull the session out from under it.
        case running
        /// The engine's own compaction setting is doing the job.
        case engineHandles
    }

    public enum Decision: Equatable, Sendable {
        case nothing
        /// Auto-compact is off: tell the person it's getting full.
        case suggest(Double)
        /// Summarise and restart these bots' sessions from the summary.
        case compact(botIds: [String])
        case skipped(SkipReason)
    }

    /// How far past the threshold an engine that compacts for itself may get before the app steps in as a fallback.
    public static let fallbackMargin = 0.10
    public static let suggestAt = 0.8

    /// - Parameters:
    ///   - readings: the last reading for each bot's session in the chat.
    ///   - isRunning: a bot is replying in this chat now.
    ///   - manual: you pressed Compact.
    public static func decide(readings: [String: ContextUsage], settings: ContextSettings, isRunning: Bool, manual: Bool = false) -> Decision {
        if isRunning { return .skipped(.running) }
        if manual { return .compact(botIds: readings.keys.sorted()) }
        let worst = readings.values.map(\.fraction).max() ?? 0
        guard settings.autoCompact else { return worst >= suggestAt ? .suggest(worst) : .nothing }

        let over = readings.filter { _, usage in
            let line = EngineCompaction.mechanism(for: usage.engine) == .appHistory
                ? settings.threshold : min(0.97, settings.threshold + fallbackMargin)
            return usage.fraction >= line
        }
        if !over.isEmpty { return .compact(botIds: over.keys.sorted()) }
        let engineOwned = readings.values.contains { EngineCompaction.mechanism(for: $0.engine) == .engineSetting && $0.fraction >= settings.threshold }
        return engineOwned ? .skipped(.engineHandles) : .nothing
    }
}

// MARK: - Putting it in place

/// Saves a compaction and starts the bots that were too full from the summary.
public final class ChatCompactor: @unchecked Sendable {
    public enum Outcome: Equatable, Sendable {
        case applied(ChatMeta, notice: String)
        case skipped(ContextAdvisor.SkipReason)
    }

    private let chatStore: ChatStore
    private let log: CompactionLog
    private let lock = NSLock()

    public init(paths: LaunchpadPaths, chatStore: ChatStore) {
        self.chatStore = chatStore
        self.log = CompactionLog(paths: paths)
    }

    /// - Parameters:
    ///   - botIds: whose sessions to clear: only the bots that were too full. nil clears every bot's (the Compact button).
    ///   - isRunning: asked again here, under a lock, right before anything is written. If a bot is replying, nothing
    ///     is changed and the outcome is `.skipped(.running)`.
    public func apply(_ record: CompactionRecord, to meta: ChatMeta, clearing botIds: [String]? = nil,
                      isRunning: () -> Bool) throws -> Outcome {
        lock.lock(); defer { lock.unlock() }
        if isRunning() { return .skipped(.running) }
        try log.append(record)
        var chat = meta
        if let botIds { for id in botIds { chat.sessions[id] = nil } } else { chat.sessions = [:] }
        try chatStore.save(chat)
        try? log.clearReadings(meta.id, botIds: botIds)
        return .applied(chat, notice: ChatCompaction.notice(record))
    }
}

// MARK: - Seeding the next turn, and the local model's history

extension ConversationRecap {
    /// A bot that starts fresh after a compaction: the summary first, then the messages that came after it.
    public static func compactedPrompt(_ prompt: String, history: [ChatMessage], record: CompactionRecord,
                                       names: [String: String] = [:], limit: Int = defaultLimit) -> String {
        Self.prompt(for: prompt, history: history, hasSession: false, names: names, limit: limit,
                    summary: record.summary, summarizedThrough: record.throughMessageId)
    }
}

/// A local model has no session, so the app sends it the chat each time. This keeps that within its window.
public enum LocalContext {
    /// The history to send: the summary of anything older (if there is one), then the latest messages that fit.
    /// The newest message is always kept.
    public static func history(messages: [ChatMessage], record: CompactionRecord?, window: Int, threshold: Double,
                               reserve: Int = 1_500) -> [ChatMessage] {
        var recent = messages.filter { $0.role != .notice && $0.status != .streaming }
        var out: [ChatMessage] = []
        if let record, let i = recent.firstIndex(where: { $0.id == record.throughMessageId }) {
            recent = Array(recent[recent.index(after: i)...])
            out.append(ChatMessage(id: "summary-\(record.id)", role: .user,
                                   text: "[Summary of the earlier conversation, which was compacted]\n\(record.summary)"))
        }
        let budget = max(512, Int(Double(max(window, 1)) * threshold) - reserve - TokenEstimate.tokens(out))
        var kept: [ChatMessage] = []
        var used = 0
        for message in recent.reversed() {
            let cost = TokenEstimate.tokens([message])
            if !kept.isEmpty, used + cost > budget { break }
            kept.append(message)
            used += cost
        }
        return out + kept.reversed()
    }
}
