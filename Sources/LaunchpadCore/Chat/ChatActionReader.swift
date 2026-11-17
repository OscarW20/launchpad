import Foundation

/// Reads a run's actions file as it grows. Call `readNew()` on a timer during the run and once more when it ends.
public final class ChatActionReader: @unchecked Sendable {
    public let url: URL
    private var offset: UInt64 = 0
    private var partial = Data()
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    /// Complete lines added since the last call; bad lines are skipped, half-written ones wait for the next call.
    public func readNew() -> [ChatAction] {
        lock.lock(); defer { lock.unlock() }
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        guard (try? h.seek(toOffset: offset)) != nil, let data = try? h.readToEnd(), !data.isEmpty else { return [] }
        offset += UInt64(data.count)
        partial.append(data)
        var actions: [ChatAction] = []
        let decoder = JSONCoding.decoder()
        while let nl = partial.firstIndex(of: 0x0A) {
            let line = partial[partial.startIndex..<nl]
            partial = Data(partial[partial.index(after: nl)...])
            if let a = try? decoder.decode(ChatAction.self, from: Data(line)) { actions.append(a) }
        }
        return actions
    }
}

/// Cards and media on the bot's own reply, collected while it streams. The app shows them on the live message and
/// puts them on the final one with `merge(into:)`.
public struct ChatReplyExtras: Codable, Equatable, Sendable {
    public var gif: GifRef?
    public var poll: Poll?
    public var plan: PlanCard?
    public var questions: QuestionCard?

    public init(gif: GifRef? = nil, poll: Poll? = nil, plan: PlanCard? = nil, questions: QuestionCard? = nil) {
        self.gif = gif
        self.poll = poll
        self.plan = plan
        self.questions = questions
    }

    public var isEmpty: Bool { gif == nil && poll == nil && plan == nil && questions == nil }

    public func merge(into m: inout ChatMessage) {
        if let gif { m.gif = gif }
        if let poll { m.poll = poll }
        if let plan { m.plan = plan }
        if let questions { m.questions = questions }
    }
}

/// What applying a batch of actions means for the chat.
public struct ChatActionResult: Equatable, Sendable {
    /// The reply's cards and media, updated.
    public var extras: ChatReplyExtras
    /// Earlier messages that changed (a reaction on yours, a vote in a poll). Save each with `ChatStore.append`.
    public var changed: [ChatMessage] = []
    /// GIFs to look up (`GiphySearch.search`); put the first result in `extras.gif`.
    public var gifSearches: [String] = []
    /// Routines to save (`ChatActionApplier.saveRoutine`).
    public var routines: [RoutineRequest] = []
    /// A plan card just appeared (start its countdown if it has one).
    public var planShown = false
    /// A question card just appeared.
    public var questionsShown = false
}

/// Turns chat actions into chat changes. Pure: the app saves and shows the result.
public enum ChatActionApplier {
    /// - Parameters:
    ///   - history: the chat's messages before this reply (the reply itself isn't in it).
    ///   - botId: the bot that used the tools (its reactions and votes are under its id).
    ///   - planWait: the countdown for plan cards (0 = wait for your OK).
    public static func apply(_ actions: [ChatAction], extras: ChatReplyExtras, history: [ChatMessage], botId: String,
                             planWait: Int, now: Date = Date()) -> ChatActionResult {
        var result = ChatActionResult(extras: extras)
        var working: [String: ChatMessage] = [:]
        var order: [String] = []
        func current(_ m: ChatMessage) -> ChatMessage { working[m.id] ?? m }
        func put(_ m: ChatMessage) {
            if working[m.id] == nil { order.append(m.id) }
            working[m.id] = m
        }

        for a in actions {
            switch a.tool {
            case .react:
                guard let emoji = a.emoji, !ChatOps.normalisedEmoji(emoji).isEmpty,
                      let target = history.last(where: { $0.role == .user && $0.deleted != true }) else { continue }
                let updated = ChatOps.react(current(target), emoji: emoji, by: botId)
                if updated != current(target) { put(updated) }
            case .sendGif:
                if let q = a.search?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty { result.gifSearches.append(q) }
            case .startPoll:
                if let p = ChatOps.makePoll(question: a.question ?? "", options: a.options ?? []) { result.extras.poll = p }
            case .vote:
                // The latest poll before this reply (not one the bot just started itself).
                guard let n = a.option, let target = history.last(where: { $0.poll != nil && $0.deleted != true }),
                      let poll = current(target).poll,
                      let voted = ChatOps.vote(poll, by: botId, option: n - 1, reason: a.reason) else { continue }
                var m = current(target)
                m.poll = voted
                if m != current(target) { put(m) }
            case .askUser:
                guard let items = a.questions, !items.isEmpty else { continue }
                result.extras.questions = QuestionCard(items: items)
                result.questionsShown = true
            case .sharePlan:
                result.extras.plan = PlanCard(message: a.message ?? "On it.", steps: a.steps ?? [], shownAt: a.at,
                                              autoStart: planWait > 0 ? planWait : nil)
                result.planShown = true
            case .createRoutine:
                if let r = a.routine { result.routines.append(r) }
            }
        }
        result.changed = order.compactMap { working[$0] }
        return result
    }

    /// Saves a routine a bot set up in a chat: it goes to that chat's bot or group and runs in that chat.
    /// Returns the routine and a notice for the chat.
    public static func saveRoutine(_ request: RoutineRequest, chat: ChatMeta, store: RoutineStore, bots: Set<String>,
                                   groups: Set<String>, now: Date = Date(),
                                   fileManager fm: FileManager = .default) -> Result<(routine: Routine, notice: String), RoutineRequestError> {
        var req = request
        if chat.kind == .group, let g = chat.groupId { req.target = "group:\(g)" } else if let b = chat.botId { req.target = "bot:\(b)" }
        req.ownChat = false
        let existing = store.loadAll()
        switch RoutineRequests.routine(from: req, existing: existing, bots: bots, groups: groups, now: now, fileManager: fm) {
        case .failure(let e):
            return .failure(e)
        case .success(var routine):
            routine.chatId = chat.id
            do {
                try store.saveAll(existing + [routine])
            } catch {
                return .failure(.invalid("Couldn't save the routine: \(error.localizedDescription)"))
            }
            return .success((routine, "Routine saved: \(routine.name) · \(routine.summary). Change or turn it off in Routines."))
        }
    }
}

/// The text fallback for bots without the tools: `[react: 🎉]`, `[gif: words]`, `[poll: Q | A | B]`, `[vote: 2]`
/// on their own in a reply.
public enum ChatTokens {
    static let pattern = try! NSRegularExpression(pattern: #"\[(react|gif|poll|vote)\s*:\s*([^\]\n]+)\]"#, options: [.caseInsensitive])

    /// The reply without the commands, and the actions they ask for. Commands inside code are left alone.
    public static func extract(from text: String, now: Date = Date()) -> (text: String, actions: [ChatAction]) {
        guard text.contains("[") else { return (text, []) }
        let ns = text as NSString
        let codeRanges = codeSpans(in: text)
        var actions: [ChatAction] = []
        var cleaned = text
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            if codeRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) { continue }
            let kind = ns.substring(with: match.range(at: 1)).lowercased()
            let value = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            var action: ChatAction?
            switch kind {
            case "react": if !ChatOps.normalisedEmoji(value).isEmpty { action = .react(ChatOps.normalisedEmoji(value)) }
            case "gif": if !value.isEmpty { action = .gif(value) }
            case "poll":
                let parts = value.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if parts.count >= 3 { action = .poll(parts[0], Array(parts.dropFirst().prefix(Poll.maxOptions))) }
            case "vote":
                if let n = Int(value.prefix { $0.isNumber }) { action = .vote(n) }
            default: break
            }
            guard var a = action else { continue }
            a.at = now
            actions.insert(a, at: 0)
            if let r = Range(match.range, in: cleaned) { cleaned.removeSubrange(r) }
        }
        guard !actions.isEmpty else { return (text, []) }
        // The first line left is the reason for a vote.
        let tidy = cleaned.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = tidy.split(separator: "\n").first.map { String($0.prefix(140)) }
        actions = actions.map { a in
            var a = a
            if a.tool == .vote { a.reason = reason }
            return a
        }
        return (tidy, actions)
    }

    private static func codeSpans(in text: String) -> [NSRange] {
        guard let re = try? NSRegularExpression(pattern: "```[\\s\\S]*?```|`[^`\\n]*`") else { return [] }
        return re.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
    }
}
