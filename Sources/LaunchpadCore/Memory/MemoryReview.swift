import Foundation

// Background memory review: when a chat goes quiet (10 minutes with nothing new), or when the app asks for one
// (compact, new thread), a cheap one-shot pass reads only the messages since the last review and files lasting
// facts into the bot's MEMORY.md under topic headings. It never uses tools, never resumes the chat's session and
// never sees secrets (they're redacted from the transcript first).

/// Knobs for the background review. The defaults are the ones the app uses.
public struct MemoryReviewPolicy: Equatable, Sendable {
    /// A chat counts as quiet after this long with nothing new.
    public var idle: TimeInterval = 10 * 60
    /// Passes per bot per day, so a busy day can't run up a bill.
    public var dailyLimit = 8
    /// Less than this much of your own writing since the last review isn't worth a pass.
    public var minUserChars = 40
    /// The new conversation sent to the model, newest kept first.
    public var transcriptBudget = 10_000
    public var perMessageLimit = 600
    public var maxFacts = 8
    /// Unusable replies in a row before the messages count as reviewed anyway.
    public var maxParseFailures = 2
    /// After a failed pass, wait this long before trying again; it doubles with each failure in a row, up to `maxRetryDelay`.
    public var retryDelay: TimeInterval = 30 * 60
    public var maxRetryDelay: TimeInterval = 8 * 3600
    /// A chat never reviewed before only has its last day reviewed, so turning this on doesn't mine months of history.
    public var firstReviewWindow: TimeInterval = 86_400

    public init() {}

    func backoff(failures: Int) -> TimeInterval {
        let n = max(failures, 1) - 1
        return min(retryDelay * pow(2, Double(min(n, 16))), maxRetryDelay)
    }
}

/// A chat whose memory pass is due.
public struct MemoryPassTicket: Equatable, Hashable, Sendable {
    public enum Reason: String, Codable, Sendable {
        /// Nothing new for `idle` minutes.
        case quiet
        /// The app asked (compact, new thread).
        case requested
    }

    public var chatId: String
    /// The bot whose memory the chat feeds (the bot itself, or a group's lead).
    public var botId: String
    public var reason: Reason
}

/// When to review, and how much. A plain value with the clock passed in, so it's fully testable.
/// Saved as JSON by `MemoryReviewer` (`.launchpad/memory/review.json`).
public struct MemoryReviewSchedule: Codable, Equatable, Sendable {
    public struct ChatState: Codable, Equatable, Sendable {
        public var botId: String
        /// Last time something happened in the chat (a message sent, a reply finished).
        public var lastActivity: Date?
        /// The `lastActivity` a pass (or a decision that nothing needed one) last covered.
        public var handledActivity: Date?
        /// The newest message already reviewed: by id, and by time (which still holds if that message is gone).
        public var reviewedId: String?
        public var reviewedUntil: Date?
        /// The app asked for a pass now (compact, new thread).
        public var requested = false
        /// Unusable replies in a row.
        public var parseFailures = 0
        public var retryAfter: Date?

        public init(botId: String) { self.botId = botId }
    }

    public struct BotState: Codable, Equatable, Sendable {
        /// "2026-11-17": the day `used` counts for (local time).
        public var day: String?
        public var used = 0
        /// Failed passes in a row (offline, signed out, usage limit…).
        public var failures = 0
        public var retryAfter: Date?
        /// Off: this bot never learns from chats.
        public var off = false

        public init() {}
    }

    public var chats: [String: ChatState] = [:]
    public var bots: [String: BotState] = [:]
    /// The chat whose pass is running. Not saved: a pass never outlives the app.
    public var running: String?
    public var policy = MemoryReviewPolicy()
    public var timeZone = TimeZone.current

    enum CodingKeys: String, CodingKey { case chats, bots }

    public init(policy: MemoryReviewPolicy = MemoryReviewPolicy(), timeZone: TimeZone = .current) {
        self.policy = policy
        self.timeZone = timeZone
    }

    // MARK: Activity

    public mutating func noteActivity(chatId: String, botId: String, at now: Date) {
        var c = chats[chatId] ?? ChatState(botId: botId)
        c.botId = botId
        c.lastActivity = max(c.lastActivity ?? now, now)
        chats[chatId] = c
    }

    /// Compact or new thread: review what's new without waiting for the chat to go quiet.
    public mutating func requestPass(chatId: String, botId: String, at now: Date) {
        noteActivity(chatId: chatId, botId: botId, at: now)
        chats[chatId]?.requested = true
    }

    public mutating func forget(chatId: String) {
        chats[chatId] = nil
        if running == chatId { running = nil }
    }

    public mutating func setLearning(_ on: Bool, botId: String) {
        bots[botId, default: BotState()].off = !on
    }

    public func learns(_ botId: String) -> Bool { !(bots[botId]?.off ?? false) }

    // MARK: Due

    /// Chats with something new that's ready for a pass, oldest first (asked-for ones before quiet ones).
    /// Empty while a pass runs: one at a time, so many quiet chats never mean many model calls at once.
    /// `busy`: chats with a reply still running, which wait.
    public func duePasses(now: Date, busy: Set<String> = []) -> [MemoryPassTicket] {
        guard running == nil else { return [] }
        return chats.compactMap { id, c -> (MemoryPassTicket, Date)? in
            guard let last = c.lastActivity, !busy.contains(id), learns(c.botId),
                  last > (c.handledActivity ?? .distantPast),
                  (c.retryAfter ?? .distantPast) <= now,
                  (bots[c.botId]?.retryAfter ?? .distantPast) <= now,
                  budgetLeft(c.botId, now: now) > 0 else { return nil }
            if c.requested { return (MemoryPassTicket(chatId: id, botId: c.botId, reason: .requested), .distantPast) }
            guard now.timeIntervalSince(last) >= policy.idle else { return nil }
            return (MemoryPassTicket(chatId: id, botId: c.botId, reason: .quiet), last)
        }
        .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.chatId < $1.0.chatId }
        .map(\.0)
    }

    // MARK: Budget

    func dayKey(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let d = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", d.year ?? 0, d.month ?? 0, d.day ?? 0)
    }

    public func budgetLeft(_ botId: String, now: Date) -> Int {
        guard let b = bots[botId], b.day == dayKey(now) else { return policy.dailyLimit }
        return max(policy.dailyLimit - b.used, 0)
    }

    // MARK: A pass

    /// Starts a pass: one at a time, and it counts against the bot's daily allowance. False if it can't start.
    public mutating func begin(_ ticket: MemoryPassTicket, now: Date) -> Bool {
        guard running == nil, learns(ticket.botId), budgetLeft(ticket.botId, now: now) > 0 else { return false }
        var b = bots[ticket.botId] ?? BotState()
        let today = dayKey(now)
        if b.day != today { b.day = today; b.used = 0 }
        b.used += 1
        bots[ticket.botId] = b
        running = ticket.chatId
        return true
    }

    /// The messages up to `newest` count as reviewed, and the chat's activity up to `activity` is handled.
    public mutating func markReviewed(chatId: String, newest: ChatMessage?, activity: Date?) {
        guard var c = chats[chatId] else { return }
        if let newest {
            c.reviewedId = newest.id
            // Never moves back (a late snapshot finishing after a newer pass).
            c.reviewedUntil = max(c.reviewedUntil ?? newest.createdAt, newest.createdAt)
        }
        if let activity { c.handledActivity = max(c.handledActivity ?? activity, activity) }
        c.requested = false
        chats[chatId] = c
    }

    public enum Finish: Equatable, Sendable {
        /// The reply was used (or held nothing worth keeping): the messages count as reviewed.
        case reviewed
        /// The reply had broken JSON: try again later.
        case unusableReply
        /// The engine failed (offline, signed out, limit): this bot backs off.
        case engineFailed
        /// Stopped (the app quit, learning was switched off): try again later, no penalty.
        case cancelled
    }

    public mutating func finish(_ ticket: MemoryPassTicket, _ how: Finish, newest: ChatMessage?, activity: Date?, now: Date) {
        if running == ticket.chatId { running = nil }
        switch how {
        case .reviewed:
            markReviewed(chatId: ticket.chatId, newest: newest, activity: activity)
            chats[ticket.chatId]?.parseFailures = 0
            chats[ticket.chatId]?.retryAfter = nil
            bots[ticket.botId]?.failures = 0
            bots[ticket.botId]?.retryAfter = nil
        case .unusableReply:
            guard var c = chats[ticket.chatId] else { return }
            c.parseFailures += 1
            if c.parseFailures >= policy.maxParseFailures {
                chats[ticket.chatId] = c
                finish(ticket, .reviewed, newest: newest, activity: activity, now: now)
                return
            }
            c.retryAfter = now.addingTimeInterval(policy.backoff(failures: c.parseFailures))
            chats[ticket.chatId] = c
        case .engineFailed:
            var b = bots[ticket.botId] ?? BotState()
            b.failures += 1
            b.retryAfter = now.addingTimeInterval(policy.backoff(failures: b.failures))
            bots[ticket.botId] = b
        case .cancelled:
            break
        }
    }
}

// MARK: - Pieces (pure, so they can be tested)

public enum MemoryReview {
    /// Messages after the last reviewed one (all of them if that one is gone) and newer than `since`
    /// (so an older conversation brought back isn't reviewed again). Notices, replies still streaming,
    /// failed or stopped replies and empty ones don't count.
    public static func unreviewed(_ list: [ChatMessage], after mark: String?, since: Date? = nil) -> [ChatMessage] {
        var slice = list[...]
        if let mark, let i = list.firstIndex(where: { $0.id == mark }) { slice = list[(i + 1)...] }
        return slice.filter { m in
            m.role != .notice && m.status == .done && !m.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (since.map { m.createdAt > $0 } ?? true)
        }
    }

    public enum Preparation: Equatable, Sendable {
        /// Nothing new. `mark` is where to start next time (when old history was skipped).
        case nothingNew(mark: ChatMessage?)
        /// Too little of your own writing to be worth a pass: these count as reviewed.
        case tooLittle(newest: ChatMessage)
        case review(fresh: [ChatMessage], newest: ChatMessage)
    }

    /// What a pass over `messages` would review, given the chat's marks.
    public static func prepare(_ messages: [ChatMessage], state: MemoryReviewSchedule.ChatState?, now: Date,
                               policy: MemoryReviewPolicy = MemoryReviewPolicy()) -> Preparation {
        let mark = state?.reviewedId, until = state?.reviewedUntil
        var fresh = unreviewed(messages, after: mark, since: until)
        let firstTime = mark == nil && until == nil
        if firstTime { fresh = fresh.filter { now.timeIntervalSince($0.createdAt) < policy.firstReviewWindow } }
        guard let newest = fresh.last else {
            let skipTo = firstTime ? messages.last { $0.role != .notice && $0.status == .done } : nil
            return .nothingNew(mark: skipTo)
        }
        let yours = fresh.filter { $0.role == .user }.map(\.text).joined(separator: " ")
        guard yours.count >= policy.minUserChars else { return .tooLittle(newest: newest) }
        return .review(fresh: fresh, newest: newest)
    }

    /// The new conversation as plain text, secrets redacted, newest kept when it's too long.
    public static func transcript(_ messages: [ChatMessage], policy: MemoryReviewPolicy = MemoryReviewPolicy(),
                                  botName: (String?) -> String) -> String {
        var lines: [String] = []
        var total = 0
        for m in messages.reversed() {
            // Redacted before it's cut short, so a key split at the cut can't slip through in part.
            var body = MemoryBook.redact(m.text.replacingOccurrences(of: "\n", with: " "))
            if body.count > policy.perMessageLimit { body = String(body.prefix(policy.perMessageLimit)) + "…" }
            let line = "\(m.role == .user ? "User" : botName(m.botId)): " + body
            guard total + line.count <= policy.transcriptBudget else { break }
            lines.append(line)
            total += line.count + 1
        }
        return lines.reversed().joined(separator: "\n")
    }

    public static func prompt(bot: Bot, memory: String, transcript: String, maxFacts: Int = MemoryReviewPolicy().maxFacts) -> String {
        let nearlyFull = memory.utf8.count > MemoryBook.sizeCap * 3 / 4
        return """
        You keep the long-term memory file for \(bot.name), an AI teammate (\(bot.role.isEmpty ? "general helper" : bot.role)).
        Read the new conversation below and pick out only lasting things worth knowing in future chats with this user.
        Don't use any tools. Output JSON only.

        Topics: Preferences, Decisions, People, Projects, How I work.
        - Preferences: tastes, tone, formats, tools they like or dislike.
        - Decisions: choices the user made that should stick.
        - People: who someone is and how they relate to the user (name and role only).
        - Projects: ongoing work, its goal and current state.
        - How I work: the user's habits, schedule and process.

        Rules:
        - Only durable facts. Skip one-off requests, small talk, anything temporary and what the bot itself did.
        - Never include passwords, API keys, tokens, codes, card or bank numbers, or text marked [redacted].
        - Skip anything the current memory already says.
        - One short plain sentence per fact, about the user ("Prefers British spelling.").
        - At most \(maxFacts) facts. If nothing is worth keeping, return an empty list.

        Current memory:
        <<<
        \(memory.isEmpty ? "(empty)" : MemoryBook.redact(memory))
        >>>

        New conversation:
        <<<
        \(transcript)
        >>>

        Reply with ONLY a JSON object, no prose, no code fences:
        {"facts": [{"topic": "Preferences", "text": "..."}]\(nearlyFull ? ", \"condense\": [{\"topic\": \"...\", \"replaces\": [\"exact old line\", \"exact old line\"], \"text\": \"one-line summary\"}]" : "")}
        \(nearlyFull ? "Memory is nearly full: also fold the oldest related lines into shorter one-line summaries under \"condense\" (copy the old lines exactly, without the leading \"- \")." : "")
        """
    }

    public enum Outcome: Equatable, Sendable {
        case apply(MemoryBook.Review)
        /// Mark the messages reviewed without changing memory.
        case skip
        /// Try again later (counts as one failure).
        case retry
    }

    /// What to do with a reply. A reply with no JSON at all ("nothing worth keeping") or a second unusable reply
    /// in a row counts as reviewed, so one chat can't use up the day's passes on the same messages.
    public static func outcome(of reply: String, failuresSoFar: Int, maxParseFailures: Int = MemoryReviewPolicy().maxParseFailures) -> Outcome {
        if let review = MemoryBook.parseReview(reply) { return .apply(review) }
        if !reply.contains("{") || failuresSoFar + 1 >= maxParseFailures { return .skip }
        return .retry
    }

    /// The cheapest run on the bot's own engine: Claude Haiku with no tools, or Codex (the bot's model) at low
    /// effort, read-only. No session is kept, no connectors are loaded and it runs in a scratch folder.
    public static func invocation(for bot: Bot, prompt: String, directory: URL) -> EngineInvocation {
        var options = RunOptions()
        options.ephemeral = true
        options.quiet = true
        options.manageConnectors = true   // Claude: --strict-mcp-config with no servers
        let model: String?
        switch bot.engine {
        case .claude: model = "haiku"
        case .codex:
            model = bot.model
            options.reasoningEffort = "low"
        }
        let scratch = Bot(id: "memory-review", name: "Memory review", engine: bot.engine, model: model, permission: .readOnly)
        return EngineCommand.invocation(for: scratch, prompt: prompt, botDirectory: directory, sessionId: nil, options: options)
    }
}

// MARK: - The reviewer

/// What a memory pass's engine call returned.
public enum MemoryEngineReply: Equatable, Sendable {
    case text(String)
    case failed(RunFailure)
}

/// Runs one engine call and returns its final text. Injectable, so tests use a fake.
public typealias MemoryReviewEngine = @Sendable (EngineInvocation) async -> MemoryEngineReply

public enum MemoryPassResult: Equatable, Sendable {
    /// Memory changed: post `update.summary` as a notice with id `update.id` (its Undo finds the update by that id).
    case updated(MemoryUpdate)
    /// The pass ran and found nothing new worth keeping.
    case nothingToKeep
    /// Nothing new in the chat, or too little of your own writing: no model call was made.
    case nothingNew
    /// Not started: another pass is running, the day's allowance is used up, learning is off, or it's backing off.
    case notStarted
    /// MEMORY.md can't be decoded, so it's left alone.
    case unreadableMemory
    /// The reply couldn't be used; it'll be tried again later.
    case willRetry
    case failed(RunFailure)
}

/// Owns the schedule (saved in `.launchpad/memory/review.json`), runs passes one at a time and applies them
/// through `MemoryStore`. The app calls `noteActivity` / `requestPass`, asks `duePasses` on a timer, and runs them.
public final class MemoryReviewer: @unchecked Sendable {
    public let paths: LaunchpadPaths
    public let store: MemoryStore
    private let engine: MemoryReviewEngine
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private var schedule: MemoryReviewSchedule
    /// Messages saved by `requestPass` before the chat was cleared, used instead of the chat's own.
    private var snapshots: [String: [ChatMessage]] = [:]
    /// Settings: "Learn from chats" for all bots.
    public var enabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _enabled }
        set { lock.lock(); _enabled = newValue; lock.unlock() }
    }
    private var _enabled = true

    public var stateFile: URL { paths.root.appendingPathComponent(".launchpad/memory/review.json") }
    var scratch: URL { paths.root.appendingPathComponent(".launchpad/scratch/memory", isDirectory: true) }

    public init(paths: LaunchpadPaths, store: MemoryStore? = nil, policy: MemoryReviewPolicy = MemoryReviewPolicy(),
                timeZone: TimeZone = .current, clock: @escaping @Sendable () -> Date = { Date() },
                engine: @escaping MemoryReviewEngine) {
        self.paths = paths
        self.store = store ?? MemoryStore(paths: paths)
        self.engine = engine
        self.clock = clock
        let file = paths.root.appendingPathComponent(".launchpad/memory/review.json")
        var loaded = (try? Data(contentsOf: file)).flatMap { try? JSONCoding.decoder().decode(MemoryReviewSchedule.self, from: $0) }
            ?? MemoryReviewSchedule()
        loaded.policy = policy
        loaded.timeZone = timeZone
        loaded.running = nil
        schedule = loaded
    }

    /// The real engine: runs the invocation with `EngineRunner` and collects the reply. Cancelling the task stops it.
    public static func engine(using runner: EngineRunner) -> MemoryReviewEngine {
        { invocation in
            let handle = runner.run(invocation)
            return await withTaskCancellationHandler {
                var builder = MessageBuilder(botId: nil)
                for await event in handle.events { builder.apply(event) }
                if builder.message.status == .done { return .text(builder.message.text) }
                return .failed(builder.message.failure ?? RunFailure(kind: .unknown, message: "The memory review stopped."))
            } onCancel: {
                handle.cancel()
            }
        }
    }

    private func mutate<T>(_ body: (inout MemoryReviewSchedule) -> T) -> T {
        lock.lock()
        let result = body(&schedule)
        let data = try? JSONCoding.encoder().encode(schedule)
        lock.unlock()
        if let data {
            try? FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: stateFile, options: .atomic)
        }
        return result
    }

    /// A copy of the schedule, for tests and the settings screen.
    public var currentSchedule: MemoryReviewSchedule { lock.lock(); defer { lock.unlock() }; return schedule }

    // MARK: What the app tells it

    /// After you send a message and after a reply finishes. `botId`: the bot whose memory the chat feeds.
    public func noteActivity(chatId: String, botId: String, now: Date? = nil) {
        let at = now ?? clock()
        mutate { $0.noteActivity(chatId: chatId, botId: botId, at: at) }
    }

    /// Compact / new thread: review now. Pass the messages if the chat is about to be cleared.
    public func requestPass(chatId: String, botId: String, snapshot: [ChatMessage]? = nil, now: Date? = nil) {
        let at = now ?? clock()
        lock.lock()
        if let snapshot { snapshots[chatId] = snapshot }
        lock.unlock()
        mutate { $0.requestPass(chatId: chatId, botId: botId, at: at) }
    }

    /// The chat was deleted.
    public func forget(chatId: String) {
        lock.lock(); snapshots[chatId] = nil; lock.unlock()
        mutate { $0.forget(chatId: chatId) }
    }

    /// Per-bot "Learn from chats" switch.
    public func setLearning(_ on: Bool, botId: String) { mutate { $0.setLearning(on, botId: botId) } }
    public func learns(_ botId: String) -> Bool { currentSchedule.learns(botId) }

    /// Chats ready for a pass. The app runs the first (only one runs at a time) on a timer tick.
    public func duePasses(now: Date? = nil, busy: Set<String> = []) -> [MemoryPassTicket] {
        guard enabled else { return [] }
        return currentSchedule.duePasses(now: now ?? clock(), busy: busy)
    }

    // MARK: Running a pass

    private func startingPoint(_ ticket: MemoryPassTicket, messages: [ChatMessage])
        -> ([ChatMessage], MemoryReviewSchedule.ChatState?, Bool) {
        lock.lock()
        defer { lock.unlock() }
        let list = snapshots.removeValue(forKey: ticket.chatId) ?? messages
        return (list, schedule.chats[ticket.chatId], schedule.running != nil)
    }

    /// Runs one pass for `ticket`. `messages`: the chat's messages (a snapshot from `requestPass` wins).
    /// `botName` names other bots in a group transcript.
    public func run(_ ticket: MemoryPassTicket, bot: Bot, messages: [ChatMessage],
                    botName: @escaping (String?) -> String = { _ in "Bot" }) async -> MemoryPassResult {
        let now = clock()
        guard enabled, bot.id == ticket.botId, learns(bot.id) else { return .notStarted }
        let (list, state, busy) = startingPoint(ticket, messages: messages)
        guard !busy else { return .notStarted }
        let activity = state?.lastActivity

        switch MemoryReview.prepare(list, state: state, now: now, policy: currentSchedule.policy) {
        case .nothingNew(let mark):
            mutate { $0.markReviewed(chatId: ticket.chatId, newest: mark, activity: activity) }
            return .nothingNew
        case .tooLittle(let newest):
            mutate { $0.markReviewed(chatId: ticket.chatId, newest: newest, activity: activity) }
            return .nothingNew
        case .review(let fresh, let newest):
            // A MEMORY.md we can't decode is left alone: no pass, so nothing can be written over it.
            guard let memory = store.read(bot.id).usable else { return .unreadableMemory }
            guard mutate({ $0.begin(ticket, now: now) }) else { return .notStarted }
            let policy = currentSchedule.policy
            let prompt = MemoryReview.prompt(bot: bot, memory: memory,
                                             transcript: MemoryReview.transcript(fresh, policy: policy, botName: botName),
                                             maxFacts: policy.maxFacts)
            let dir = scratch.appendingPathComponent(bot.id, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let reply = await engine(MemoryReview.invocation(for: bot, prompt: prompt, directory: dir))
            let done = clock()

            if Task.isCancelled || !enabled || !learns(bot.id) {
                mutate { $0.finish(ticket, .cancelled, newest: nil, activity: nil, now: done) }
                return .notStarted
            }
            switch reply {
            case .failed(let failure):
                mutate { $0.finish(ticket, .engineFailed, newest: newest, activity: activity, now: done) }
                return .failed(failure)
            case .text(let text):
                switch MemoryReview.outcome(of: text, failuresSoFar: state?.parseFailures ?? 0, maxParseFailures: policy.maxParseFailures) {
                case .retry:
                    mutate { $0.finish(ticket, .unusableReply, newest: newest, activity: activity, now: done) }
                    return .willRetry
                case .skip:
                    mutate { $0.finish(ticket, .reviewed, newest: newest, activity: activity, now: done) }
                    return .nothingToKeep
                case .apply(let review):
                    mutate { $0.finish(ticket, .reviewed, newest: newest, activity: activity, now: done) }
                    let facts = Array((review.facts ?? []).prefix(policy.maxFacts))
                    if let update = store.applyReview(botId: bot.id, chatId: ticket.chatId, facts: facts,
                                                      condense: review.condense ?? [], now: done) {
                        return .updated(update)
                    }
                    return store.read(bot.id).usable == nil ? .unreadableMemory : .nothingToKeep
                }
            }
        }
    }
}
