import Foundation

/// How a group works on a task:
/// 1. The lead replies first and hands work to members by @mention.
/// 2. Members reply one at a time, in the order mentioned, each seeing the group's history.
///    They run in parallel only if the lead adds a `[parallel]` line.
/// 3. A member can hand on to another member by @mention.
/// 4. When the members are done the lead reviews: hands off again, or wraps up with no mentions.
/// Every reply that hands work on counts towards the hand-off limit. When it's hit, the group stops and asks you.
public enum GroupPlan {
    public static let parallelMarker = "[parallel]"

    /// Bot ids @mentioned in `text`, in order of first mention. Ignores code blocks and the speaker.
    public static func mentions(in text: String, group: BotGroup, bots: [String: Bot], speaker: String?) -> [String] {
        let prose = stripCode(text)
        var result: [String] = []
        let members = group.everyone
        guard let regex = try? NSRegularExpression(pattern: #"(?<![\w@.])@([A-Za-z0-9][A-Za-z0-9_-]*)"#) else { return [] }
        let range = NSRange(prose.startIndex..., in: prose)
        for match in regex.matches(in: prose, range: range) {
            guard let r = Range(match.range(at: 1), in: prose) else { continue }
            let handle = String(prose[r]).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
            var ids: [String] = []
            if handle == "everyone" || handle == "all" || handle == "team" {
                ids = members.filter { $0 != group.lead }
            } else if let id = members.first(where: { matches(handle, id: $0, bot: bots[$0]) }) {
                ids = [id]
            }
            for id in ids where id != speaker && !result.contains(id) {
                result.append(id)
            }
        }
        return result
    }

    static func matches(_ handle: String, id: String, bot: Bot?) -> Bool {
        if handle == id.lowercased() { return true }
        guard let bot else { return false }
        let name = bot.name.lowercased()
        return handle == Slug.make(name) || handle == name.replacingOccurrences(of: " ", with: "")
    }

    public static func isParallel(_ text: String) -> Bool {
        stripCode(text).lowercased().contains(parallelMarker)
    }

    static func stripCode(_ text: String) -> String {
        var out: [Substring] = []
        var inFence = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); continue }
            if !inFence { out.append(line) }
        }
        // Drop inline code too.
        return out.joined(separator: "\n").replacingOccurrences(of: #"`[^`]*`"#, with: "", options: .regularExpression)
    }
}

/// What kind of turn a bot is taking, which decides its instructions.
public enum GroupTurnKind: Equatable, Sendable {
    case leadStart
    case leadReview
    case member(handedOnBy: String?)
    case view
    case summary
    case resume(note: String)
}

public struct GroupTurnRequest: Sendable {
    public var bot: Bot
    public var kind: GroupTurnKind
    public var prompt: String
}

public enum GroupOutcome: Equatable, Sendable {
    case done
    case handoffLimitReached(limit: Int, waiting: [String])
    case awaitingApproval(botId: String)
    case stopped
    case failed(botId: String)
    case noLead
}

/// Builds what each bot is told on its turn.
public struct GroupPrompts {
    public var group: BotGroup
    public var bots: [String: Bot]
    public var summaryPath: String
    public var workspacePath: String

    public init(group: BotGroup, bots: [String: Bot], summaryPath: String, workspacePath: String) {
        self.group = group
        self.bots = bots
        self.summaryPath = summaryPath
        self.workspacePath = workspacePath
    }

    func name(_ id: String?) -> String {
        guard let id else { return "Someone" }
        return bots[id]?.name ?? id
    }

    public func prompt(for bot: Bot, kind: GroupTurnKind, newMessages: [ChatMessage], firstTurn: Bool) -> String {
        var parts: [String] = []
        if firstTurn {
            var intro = "You're \(bot.name) in the Launchpad group \(group.displayName)."
            intro += bot.id == group.lead ? " You're the lead." : ""
            intro += "\n\nTeam (mention people by @id):"
            for id in group.everyone {
                let b = bots[id]
                let role = (b?.role.isEmpty ?? true) ? "" : ": \(b!.role)"
                intro += "\n- @\(id): \(b?.name ?? id)\(id == group.lead ? " (lead)" : "")\(role)\(id == bot.id ? " (you)" : "")"
            }
            if !group.rules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                intro += "\n\nGroup rules:\n\(group.rules.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
            intro += "\n\nShared project folder for the group: \(workspacePath)\nGroup summary file: \(summaryPath)"
            parts.append(intro)
        }

        if !newMessages.isEmpty {
            let lines = newMessages.compactMap { m -> String? in
                switch m.role {
                case .notice: return nil
                case .user: return "**Me (the user):** \(clip(m.text))"
                case .bot:
                    var text = clip(m.text)
                    if text.isEmpty, let f = m.failure { text = "(couldn't reply: \(f.message))" }
                    if let a = m.approval { text += "\n(asked for approval: \(a.action), \(a.status.rawValue))" }
                    return "**\(name(m.botId)) (@\(m.botId ?? "?")):** \(text)"
                }
            }
            parts.append("New in the group chat since your last turn:\n\n" + lines.joined(separator: "\n\n"))
        }

        parts.append(instruction(for: bot, kind: kind))
        return parts.joined(separator: "\n\n---\n\n")
    }

    func instruction(for bot: Bot, kind: GroupTurnKind) -> String {
        switch kind {
        case .leadStart:
            return """
            You're the lead, so you reply first. Work out the plan, then hand work to the team: start a line with \
            their @id and say exactly what they should do, e.g. `@\(group.members.first(where: { $0 != bot.id }) ?? "member") build the sign-in page`. \
            They reply one at a time, in the order you mention them, and see each other's replies. \
            If their tasks are independent and can safely run at the same time, add a line `\(GroupPlan.parallelMarker)`. \
            If you can answer yourself, just answer without mentioning anyone. Keep \(summaryPath) up to date \
            (decisions, owners, open issues).
            """
        case .leadReview:
            return """
            Your team has replied (above). Either hand out the next steps with @mentions, or, if the task is done, \
            reply WITHOUT any @mentions with a short final summary for me (what was done, links, anything I need to do). \
            Update \(summaryPath) before you finish.
            """
        case .member(let by):
            return """
            \(name(by)) handed you work above. Do your part now, in the shared project folder where it makes sense. \
            Then reply with what you did and anything others need to know. Only @mention a teammate if they need to act \
            next; don't @mention the lead just to report back.
            """
        case .view:
            return "I've asked everyone for a quick view on my message above. Give yours in 2–4 sentences. Don't do any work and don't @mention anyone."
        case .summary:
            return "Everyone has given their view (above). Sum it up for me in a few bullet points and give your recommendation. Don't @mention anyone. Note any decision in \(summaryPath)."
        case .resume(let note):
            return note
        }
    }

    private func clip(_ s: String, max: Int = 6000) -> String {
        s.count > max ? String(s.prefix(max)) + "\n… (cut)" : s
    }
}

/// Runs the group. `runTurn` does one bot's turn (streaming it into the chat) and returns its final message.
public final class GroupOrchestrator: @unchecked Sendable {
    public typealias TurnRunner = @Sendable (GroupTurnRequest) async -> ChatMessage

    public let group: BotGroup
    public let bots: [String: Bot]
    public private(set) var history: [ChatMessage]
    private let prompts: GroupPrompts
    private let runTurn: TurnRunner
    private let hasSession: @Sendable (String) -> Bool
    private let lock = NSLock()

    public init(group: BotGroup, bots: [Bot], history: [ChatMessage], summaryPath: String, workspacePath: String,
                hasSession: @escaping @Sendable (String) -> Bool = { _ in false },
                runTurn: @escaping TurnRunner) {
        self.group = group
        let byId = Dictionary(bots.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.bots = byId
        self.history = history
        self.prompts = GroupPrompts(group: group, bots: byId, summaryPath: summaryPath, workspacePath: workspacePath)
        self.hasSession = hasSession
        self.runTurn = runTurn
    }

    /// Add a message that arrived from elsewhere (e.g. what you typed).
    public func record(_ message: ChatMessage) {
        lock.lock(); defer { lock.unlock() }
        history.append(message)
    }

    private var lead: Bot? { group.lead.flatMap { bots[$0] } }

    /// You posted a task (already recorded). The lead goes first.
    public func runTask() async -> GroupOutcome {
        guard let lead else { return .noLead }
        return await drive(from: lead, kind: .leadStart)
    }

    /// Carry on with one bot after something like an approval.
    public func resume(with botId: String, note: String) async -> GroupOutcome {
        guard let bot = bots[botId] else { return .noLead }
        return await drive(from: bot, kind: .resume(note: note))
    }

    /// "Ask everyone": each member gives a short view (in parallel), then the lead sums up.
    public func askEveryone() async -> GroupOutcome {
        guard let lead else { return .noLead }
        let members = group.everyone.filter { $0 != lead.id }.compactMap { bots[$0] }
        let snapshot = currentHistory()
        let replies = await withTaskGroup(of: (Int, ChatMessage).self) { tg -> [ChatMessage] in
            for (i, bot) in members.enumerated() {
                let req = request(bot, .view, history: snapshot)
                tg.addTask { (i, await self.runTurn(req)) }
            }
            var out: [(Int, ChatMessage)] = []
            for await r in tg { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
        for r in replies { record(r) }
        if Task.isCancelled || replies.contains(where: { $0.status == .stopped }) { return .stopped }
        let summary = await runTurn(request(lead, .summary, history: currentHistory()))
        record(summary)
        return outcome(of: summary) ?? .done
    }

    // MARK: - The loop

    private func drive(from first: Bot, kind: GroupTurnKind) async -> GroupOutcome {
        var handoffs = 0
        var speaker = first
        var reply = await turn(first, kind)
        while true {
            if let stop = outcome(of: reply) { return stop }
            var next = GroupPlan.mentions(in: reply.text, group: group, bots: bots, speaker: speaker.id)
            let isLead = speaker.id == group.lead
            if isLead {
                next.removeAll { $0 == group.lead }
                if next.isEmpty { return .done }
            }

            // Members work through the hand-offs; their own mentions queue more work.
            var parallel = isLead && GroupPlan.isParallel(reply.text)
            var handedBy = speaker.id
            while !next.isEmpty {
                handoffs += 1
                if handoffs > group.handoffLimit {
                    return .handoffLimitReached(limit: group.handoffLimit, waiting: next)
                }
                let batch = next.compactMap { bots[$0] }
                next = []
                let replies: [ChatMessage]
                if parallel && batch.count > 1 {
                    let snapshot = currentHistory()
                    let by = handedBy
                    replies = await withTaskGroup(of: (Int, ChatMessage).self) { tg -> [ChatMessage] in
                        for (i, bot) in batch.enumerated() {
                            let req = request(bot, .member(handedOnBy: by), history: snapshot)
                            tg.addTask { (i, await self.runTurn(req)) }
                        }
                        var out: [(Int, ChatMessage)] = []
                        for await r in tg { out.append(r) }
                        return out.sorted { $0.0 < $1.0 }.map(\.1)
                    }
                    replies.forEach(record)
                } else {
                    var out: [ChatMessage] = []
                    for bot in batch {
                        let r = await turn(bot, .member(handedOnBy: handedBy))
                        out.append(r)
                        if outcome(of: r) != nil { break }
                    }
                    replies = out
                }
                for r in replies {
                    if let stop = outcome(of: r) { return stop }
                }
                // Member-to-member hand-offs (the lead reviews at the end anyway).
                for r in replies {
                    for id in GroupPlan.mentions(in: r.text, group: group, bots: bots, speaker: r.botId)
                    where id != group.lead && !next.contains(id) {
                        next.append(id)
                    }
                }
                handedBy = replies.last?.botId ?? handedBy
                parallel = false
            }

            guard let lead else { return .done }
            speaker = lead
            reply = await turn(lead, .leadReview)
        }
    }

    private func turn(_ bot: Bot, _ kind: GroupTurnKind) async -> ChatMessage {
        let r = await runTurn(request(bot, kind, history: currentHistory()))
        record(r)
        return r
    }

    private func outcome(of reply: ChatMessage) -> GroupOutcome? {
        if Task.isCancelled || reply.status == .stopped { return .stopped }
        if reply.status == .failed { return .failed(botId: reply.botId ?? "") }
        if reply.approval?.status == .pending { return .awaitingApproval(botId: reply.botId ?? "") }
        return nil
    }

    private func currentHistory() -> [ChatMessage] {
        lock.lock(); defer { lock.unlock() }
        return history
    }

    /// What's new for `bot`: everything after its last message (or the recent past, if it has no session).
    func request(_ bot: Bot, _ kind: GroupTurnKind, history: [ChatMessage]) -> GroupTurnRequest {
        let session = hasSession(bot.id)
        var start = 0
        if session, let last = history.lastIndex(where: { $0.role == .bot && $0.botId == bot.id }) {
            start = last + 1
        }
        let slice = Array(history[start...].suffix(40))
        let prompt = prompts.prompt(for: bot, kind: kind, newMessages: slice, firstTurn: !session)
        return GroupTurnRequest(bot: bot, kind: kind, prompt: prompt)
    }
}
