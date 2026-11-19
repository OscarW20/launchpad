import Foundation

// Asks addressed to you. A long report from a bot can end with the one thing it needs from you; this finds it, so the app can
// lift it out of the message, count it, list it across chats, and say when it's been dealt with. No UI here.
//
// What counts as an ask (the team notes tell bots to write it this way):
//   - a "Needs you" heading (`**Needs you**`, `Needs you:`, `## Needs you`), and what follows it, or
//   - a line or paragraph that STARTS with `@oscar` (after any list or quote marks and bold), or
//   - a sentence in the LAST paragraph of a message that is addressed to you by name and asks for something:
//     "Oscar, please open the email", "Oscar: which one?", "Oscar can you approve this?".
// A mention in the middle of a sentence ("thanks @oscar for the review", "as Oscar said") is an ordinary mention, not an ask,
// and so are filler lines ("let me know if you have any questions"). A by-name ask only counts while it's the end of the
// message: if the bot kept writing after it, it was a status line, and if the same bot goes on talking in later messages it
// was answered or moved on.
// Choices are the list lines under the ask: `-`, `*`, `•`, `1.`, `1)`, `a)`, `A.`.

/// What an ask wants from you, so the card can label itself and offer the right buttons.
public enum AskKind: String, Sendable {
    /// Pick one of the listed options.
    case decision
    /// Answer something in words.
    case question
    /// Do something, then say it's done.
    case task
}

/// One ask found in a message.
public struct ParsedAsk: Equatable, Sendable {
    /// How the ask was written. An explicit one (`Needs you`, a line starting `@oscar`) stays open until you answer or mark it
    /// done. One found by name ("Oscar, please …") is only an ask while it's the end of the message and the bot goes quiet.
    public enum Source: String, Sendable { case explicit, byName }

    /// What's needed, in plain words (no @oscar, no bold marks).
    public var text: String
    /// The options, one per list line, without their markers. Reply with a choice as it is.
    public var choices: [String]
    public var source: Source = .explicit

    public init(text: String, choices: [String] = [], source: Source = .explicit) {
        self.text = text
        self.choices = choices
        self.source = source
    }

    /// The ask in one short line for the card: the first sentence, cut to 20 words.
    public var headline: String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return choices.isEmpty ? "" : "Pick one of the options" }
        let first = AskParser.firstSentence(of: body)
        let words = first.split(separator: " ")
        guard words.count > AskParser.headlineWords else { return first }
        return words.prefix(AskParser.headlineWords).joined(separator: " ") + "…"
    }

    /// Whatever the ask says beyond its headline, or nil.
    public var detail: String? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = AskParser.firstSentence(of: body)
        let rest = body.dropFirst(first.count).trimmingCharacters(in: .whitespacesAndNewlines)
        if first.split(separator: " ").count > AskParser.headlineWords { return body }
        return rest.isEmpty ? nil : String(rest)
    }

    /// Options, a question, or something to do.
    public var kind: AskKind {
        if choices.count >= 2 { return .decision }
        let t = text.lowercased()
        if t.range(of: AskParser.taskPattern, options: .regularExpression) != nil { return .task }
        if text.contains("?") { return .question }
        return .task
    }

    /// What a "Done" button sends: it says what was done, so a bot isn't left guessing. For a task.
    public var doneReply: String { "Done: \(headline)" }
    /// What a "Can't right now" button sends.
    public var declineReply: String { "I can't do this right now: \(headline)" }
}

public enum AskParser {
    /// Who the asks are for.
    public static let defaultHandles = ["oscar"]
    static let maxTextLength = 600
    static let maxChoiceLength = 200
    static let maxChoices = 8
    static let headlineWords = 20

    /// A request to do something (rather than to answer): "please open…", "can you click…", "approve the deploy".
    static let taskPattern = #"^(?:please\s+)?(?:(?:can|could|would|will)\s+you\s+(?:please\s+)?)?(?:open|click|sign|log|enter|paste|create|add|run|approve|check|send|grant|connect|install|restart|update|review|test|try|copy|download|upload|confirm|provide|set|turn|reply|forward|complete|finish|share|give)\b"#

    /// Lines that look like asks but ask for nothing.
    static let fillerPatterns = [
        #"let me know if you (?:have|need|want|would like|'d like)\b"#, #"let me know if there(?:'s| is| are)\b"#,
        #"let me know (?:what|how) you think"#, #"let me know when you(?:'re| are) ready"#, #"feel free to (?:ask|reach out|check|let)"#,
        #"(?:\bany |if you have (?:any )?|got any )(?:further |more |other )?(?:questions|concerns|feedback)\b"#, #"hope (?:this|that) helps"#,
        #"happy to help"#, #"just say the word"#, #"^thoughts\??$"#, #"anything else\b"#,
    ]

    static func isFiller(_ text: String) -> Bool {
        let t = text.lowercased()
        return fillerPatterns.contains { t.range(of: $0, options: .regularExpression) != nil }
    }

    /// The first sentence: up to the first `.`, `!` or `?` that is followed by a space (so "e.g." inside words and file names
    /// don't cut it short), or the whole text.
    static func firstSentence(of text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        if let r = flat.range(of: #"[.!?]+(?=\s+[A-Z@*_\"“(])"#, options: .regularExpression) {
            return String(flat[..<r.upperBound]).trimmingCharacters(in: .whitespaces)
        }
        return flat.trimmingCharacters(in: .whitespaces)
    }

    /// Your handles: "oscar", plus the first word of your full name when it's different ("Oscar Whelan" adds nothing new).
    public static func handles(forFullName name: String?) -> [String] {
        var out = defaultHandles
        if let first = name?.split(separator: " ").first.map({ String($0).lowercased() }), first.count >= 2, !out.contains(first) { out.append(first) }
        return out
    }

    /// The ask in `text`, if there is one. With several, the last (asks go at the end of a message).
    public static func parse(_ text: String, handles: [String] = defaultHandles) -> ParsedAsk? {
        find(text, handles: handles)?.ask
    }

    /// The message split in two: everything except the ask (the report), and the ask. No ask: the whole text and nil.
    public static func split(_ text: String, handles: [String] = defaultHandles) -> (report: String, ask: ParsedAsk?) {
        guard let found = find(text, handles: handles) else { return (text, nil) }
        var lines = lines(of: text)
        lines.removeSubrange(found.lines)
        let joined = lines.joined(separator: "\n").replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        let report = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        return (report, found.ask)
    }

    // MARK: Internals

    private static func lines(of text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    private struct Found { var ask: ParsedAsk; var lines: Range<Int> }

    /// Marks that can sit in front of "@oscar" or "Needs you": spaces, quotes, bullets, headings, bold and italics.
    private static let lead = CharacterSet(charactersIn: " \t>*_#-•")

    private static func stripLead(_ line: String) -> String {
        String(line.unicodeScalars.drop(while: { lead.contains($0) }))
    }

    /// The text after a leading mention of one of `handles`, or nil if the line doesn't start with one.
    private static func afterMention(_ line: String, handles: [String]) -> String? {
        let rest = stripLead(line)
        guard rest.hasPrefix("@") else { return nil }
        for h in handles {
            guard rest.lowercased().hasPrefix("@" + h.lowercased()) else { continue }
            let tail = rest.dropFirst(1 + h.count)
            if let c = tail.first, c.isLetter || c.isNumber || c == "_" || c == "-" { continue }   // "@oscars", "@oscar-2"
            return clean(String(tail))
        }
        return nil
    }

    /// The text after a "Needs you" heading, or nil if the line isn't one.
    private static func afterHeading(_ line: String) -> String? {
        let rest = stripLead(line)
        guard rest.lowercased().hasPrefix("needs you") else { return nil }
        let tail = rest.dropFirst("needs you".count)
        if let c = tail.first, c.isLetter || c.isNumber { return nil }                 // "needs your help with…" is a sentence
        return clean(String(tail))
    }

    /// Trims separators and bold marks left over after a mention or heading ("**", ":", ",", dashes).
    private static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        t = t.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":,;-–—*_")))
        return t
    }

    /// The text of a list line (`- x`, `* x`, `• x`, `1. x`, `2) x`, `a) x`, `(b) x`), or nil if it isn't one.
    private static func choice(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let r = t.range(of: #"^(?:[-*•]|\d{1,2}[.)]|\(?[A-Za-z][.)])\s+(\S.*)$"#, options: .regularExpression) else { return nil }
        let body = t[r].replacingOccurrences(of: #"^(?:[-*•]|\d{1,2}[.)]|\(?[A-Za-z][.)])\s+"#, with: "", options: .regularExpression)
        let text = clean(body)
        return text.isEmpty ? nil : text
    }

    private static func find(_ text: String, handles: [String]) -> Found? {
        let ls = lines(of: text)
        var inFence = false
        var fenced = [Bool](repeating: false, count: ls.count)
        for (i, l) in ls.enumerated() {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") { inFence.toggle(); fenced[i] = true } else { fenced[i] = inFence }
        }
        func blank(_ i: Int) -> Bool { ls[i].trimmingCharacters(in: .whitespaces).isEmpty }
        func start(_ i: Int) -> Bool { !fenced[i] && (afterMention(ls[i], handles: handles) != nil || afterHeading(ls[i]) != nil) }

        var last: Found?
        var i = 0
        while i < ls.count {
            guard !fenced[i], start(i) else { i += 1; continue }
            let first = i
            var head = afterMention(ls[i], handles: handles) ?? afterHeading(ls[i]) ?? ""
            var cursor = i + 1
            // A heading on its own line: the ask is the next non-blank line (which may itself start with the mention).
            if head.isEmpty, afterMention(ls[i], handles: handles) == nil {
                var j = cursor
                while j < ls.count, blank(j) { j += 1 }
                if j < ls.count, !fenced[j] {
                    head = afterMention(ls[j], handles: handles) ?? clean(ls[j])
                    if choice(ls[j]) != nil { head = ""; j -= 1 }                  // the list starts right away
                    cursor = j + 1
                }
            }
            var text = head
            var choices: [String] = []
            // The rest of the paragraph: list lines are choices, anything else carries on the ask.
            var j = cursor
            while j < ls.count, !blank(j), !fenced[j], !start(j) {
                if let c = choice(ls[j]) { choices.append(c) } else if choices.isEmpty { text += (text.isEmpty ? "" : " ") + clean(ls[j]) }
                j += 1
            }
            // A list set apart by a blank line still belongs to the ask.
            var k = j
            while k < ls.count, blank(k) { k += 1 }
            if k > j, k < ls.count, !fenced[k], !start(k), choice(ls[k]) != nil {
                while k < ls.count, !fenced[k], !start(k), blank(k) || choice(ls[k]) != nil {
                    if !blank(k), let c = choice(ls[k]) { choices.append(c) }
                    k += 1
                }
                while k > j, blank(k - 1) { k -= 1 }
                j = k
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let filler = choices.isEmpty && isFiller(text)
            if (!text.isEmpty || !choices.isEmpty) && !filler {
                let ask = ParsedAsk(text: String(text.prefix(maxTextLength)),
                                    choices: choices.prefix(maxChoices).map { String($0.prefix(maxChoiceLength)) })
                last = Found(ask: ask, lines: first..<max(j, first + 1))
            }
            i = max(j, first + 1)
        }
        if last == nil, let named = findByName(ls, fenced: fenced, handles: handles) {
            // The ask sits inside the report, so there's nothing to lift out of it: the report stays whole.
            return Found(ask: named, lines: 0..<0)
        }
        return last
    }

    // MARK: Asking by name

    /// The sentence in the message's last paragraph that asks you for something by name, or nil.
    private static func findByName(_ ls: [String], fenced: [Bool], handles: [String]) -> ParsedAsk? {
        func blank(_ i: Int) -> Bool { ls[i].trimmingCharacters(in: .whitespaces).isEmpty }
        guard let end = ls.indices.last(where: { !blank($0) && !fenced[$0] }) else { return nil }
        func paragraphStart(_ e: Int) -> Int { var s = e; while s > 0, !blank(s - 1), !fenced[s - 1] { s -= 1 }; return s }
        var start = paragraphStart(end)
        // A list on its own: the sentence that introduces it is in the paragraph before.
        if (start...end).allSatisfy({ choice(ls[$0]) != nil }) {
            var p = start - 1
            while p >= 0, blank(p) { p -= 1 }
            if p >= 0, !fenced[p] { start = paragraphStart(p) }
        }
        let used = (start...end).filter { !blank($0) && !fenced[$0] }
        let choices = used.compactMap { choice(ls[$0]) }
        let prose = used.filter { choice(ls[$0]) == nil }.map { ls[$0] }.joined(separator: " ")
            .replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        let sentences = prose.replacingOccurrences(of: #"(?<=[.!?])\s+(?=[A-Z@"“(])"#, with: "\u{1}", options: .regularExpression)
            .components(separatedBy: "\u{1}")
        for (i, sentence) in sentences.enumerated() {
            guard let request = addressed(sentence, handles: handles) else { continue }
            let text = ([request] + sentences[(i + 1)...].prefix(2).map { clean($0) }).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard choices.isEmpty ? !isFiller(text) : true else { return nil }
            return ParsedAsk(text: String(text.prefix(maxTextLength)), choices: choices.prefix(maxChoices).map { String($0.prefix(maxChoiceLength)) },
                             source: .byName)
        }
        return nil
    }

    /// The request in a sentence that starts with your name ("Oscar, please …", "@oscar: which …?", "Oscar can you …"), or nil
    /// if it doesn't start that way, is thanks or news rather than a request, or asks for nothing.
    private static func addressed(_ sentence: String, handles: [String]) -> String? {
        var s = stripLead(sentence)
        while let c = s.first, "\"“'‘(".contains(c) { s.removeFirst() }
        if s.hasPrefix("@") { s.removeFirst() }
        guard let handle = handles.first(where: { s.lowercased().hasPrefix($0.lowercased()) }) else { return nil }
        let tail = String(s.dropFirst(handle.count))
        guard let first = tail.first else { return nil }
        // "Oscar," "Oscar:" "Oscar -" are addressing him; "Oscar please" / "Oscar can you" too. "Oscar's", "oscar@x.com" are not.
        let addressing = tail.range(of: #"^(?:[,:;]|\s?[-–—]\s)"#, options: .regularExpression) != nil   // "Oscar-2" is not him
        let spaced = first == " " && tail.trimmingCharacters(in: .whitespaces).lowercased()
            .range(of: #"^(?:please|can you|could you|would you|will you|need)\b"#, options: .regularExpression) != nil
        guard addressing || spaced else { return nil }
        let request = clean(tail)
        guard !request.isEmpty,
              request.lowercased().range(of: #"^(?:thanks|thank you|cheers|fyi|note|sorry|welcome|congrats|great|nice|good|well done|here|has|have|said|asked|wrote|mentioned)\b"#, options: .regularExpression) == nil,
              request.range(of: #"(?i)\?|\b(?:please|can you|could you|would you|will you|need|needs|should|must|which|what|when|where|how|do you|did you|are you|approve|confirm|decide|choose|pick|open|click|check|review|sign|log in|enter|paste|send|share|provide|give|tell|let me know|go ahead|your call|up to you)\b"#, options: .regularExpression) != nil
        else { return nil }
        return request
    }
}

// MARK: - Tracking

/// An open or finished ask, with where it is.
public struct UserAsk: Equatable, Identifiable, Sendable {
    /// The message's id (a message holds at most one ask).
    public var id: String { messageId }
    public var chatId: String
    public var messageId: String
    public var botId: String?
    public var ask: ParsedAsk
    public var at: Date
}

/// Which asks you've marked done by hand. Saved in Launchpad's data folder, which bots can't write, so a bot can't close
/// its own ask (or yours). Asks you've answered in the chat need no entry here: a reply of yours after the ask closes it.
public struct AskStore {
    public let file: URL
    static let kept = 2000

    public init(paths: LaunchpadPaths) {
        file = paths.launchpadData.appendingPathComponent("asks-done.json")
    }

    private struct Saved: Codable { var done: [String] }

    /// Message ids marked done. Missing or unreadable means none.
    public func done() -> [String] {
        guard let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return [] }
        return saved.done
    }

    public func doneSet() -> Set<String> { Set(done()) }

    public func markDone(_ messageId: String) throws {
        var ids = done().filter { $0 != messageId }
        ids.append(messageId)
        try save(Array(ids.suffix(Self.kept)))
    }

    public func markOpen(_ messageId: String) throws {
        try save(done().filter { $0 != messageId })
    }

    private func save(_ ids: [String]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.encoder().encode(Saved(done: ids)).write(to: file, options: .atomic)
    }
}

public enum AskBook {
    /// Every ask in a chat's messages, oldest first, whether or not it's still open. Only finished bot replies count
    /// (a message still streaming may not have its ask yet).
    public static func asks(in messages: [ChatMessage], chatId: String, handles: [String] = AskParser.defaultHandles) -> [UserAsk] {
        messages.compactMap { m in
            guard m.role == .bot, m.status == .done, let ask = AskParser.parse(m.text, handles: handles) else { return nil }
            return UserAsk(chatId: chatId, messageId: m.id, botId: m.botId, ask: ask, at: m.createdAt)
        }
    }

    /// The asks still waiting on you: not marked done, and with no message of yours after them in the chat.
    public static func open(in messages: [ChatMessage], chatId: String, handles: [String] = AskParser.defaultHandles,
                            done: Set<String> = []) -> [UserAsk] {
        let lastReply = messages.lastIndex { $0.role == .user }
        let positions = Dictionary(uniqueKeysWithValues: messages.enumerated().map { ($1.id, $0) })
        return asks(in: messages, chatId: chatId, handles: handles).filter { a in
            guard !done.contains(a.messageId) else { return false }
            guard let at = positions[a.messageId] else { return true }
            if let lastReply, lastReply > at { return false }
            // An ask made by name sat inside the bot's message: if that bot went on talking afterwards, it moved on.
            if a.ask.source == .byName, messages[(at + 1)...].contains(where: { $0.role == .bot && $0.botId == a.botId }) { return false }
            return true
        }
    }

    /// What to pin above the composer for one chat: its open asks, newest last. (The same as `open`; named for what it's for.)
    public static func pinned(in messages: [ChatMessage], chatId: String, handles: [String] = AskParser.defaultHandles,
                              done: Set<String> = []) -> [UserAsk] {
        open(in: messages, chatId: chatId, handles: handles, done: done)
    }

    /// What a notification says for an ask: "Needs you: …".
    public static func notice(_ ask: ParsedAsk, limit: Int = 120) -> String {
        let body = ask.text.isEmpty ? (ask.choices.first ?? "") : ask.text
        let flat = body.replacingOccurrences(of: "\n", with: " ")
        return "Needs you: " + (flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat)
    }
}

extension WorkspaceLayout {
    /// A one-to-one chat is in its bot's workspace, a group chat in its group's.
    public func workspaceId(for chat: ChatMeta) -> String {
        if chat.kind == .group, let g = chat.groupId { return groups[g] ?? Workspace.generalId }
        if let b = chat.botId { return bots[b] ?? Workspace.generalId }
        return Workspace.generalId
    }
}

/// Open asks across every chat.
public struct AskInbox {
    private let paths: LaunchpadPaths
    private let chats: ChatStore
    private let store: AskStore

    public init(paths: LaunchpadPaths) {
        self.paths = paths
        chats = ChatStore(paths: paths)
        store = AskStore(paths: paths)
    }

    /// Open asks, newest first. `workspace` limits it to one workspace (nil: all). Chats that haven't changed for
    /// `maxAge` are skipped, which keeps this quick with a long history; an ask older than that is long forgotten.
    public func open(workspace: String? = nil, handles: [String] = AskParser.defaultHandles,
                     maxAge: TimeInterval = 14 * 24 * 3600, now: Date = Date()) -> [UserAsk] {
        let layout = WorkspaceStore(paths: paths).load()
        let done = store.doneSet()
        var out: [UserAsk] = []
        for chat in chats.loadAll() where now.timeIntervalSince(chat.updatedAt) <= maxAge {
            if let workspace, layout.workspaceId(for: chat) != workspace { continue }
            out += AskBook.open(in: chats.messages(chatId: chat.id), chatId: chat.id, handles: handles, done: done)
        }
        return out.sorted { $0.at > $1.at }
    }

    /// Open asks per workspace id, for the badge on each switcher entry.
    public func counts(handles: [String] = AskParser.defaultHandles, maxAge: TimeInterval = 14 * 24 * 3600, now: Date = Date()) -> [String: Int] {
        let layout = WorkspaceStore(paths: paths).load()
        let done = store.doneSet()
        var out: [String: Int] = [:]
        for chat in chats.loadAll() where now.timeIntervalSince(chat.updatedAt) <= maxAge {
            let n = AskBook.open(in: chats.messages(chatId: chat.id), chatId: chat.id, handles: handles, done: done).count
            if n > 0 { out[layout.workspaceId(for: chat), default: 0] += n }
        }
        return out
    }

    /// One chat's open asks, newest last, for the tray above its composer.
    public func pinned(chatId: String, handles: [String] = AskParser.defaultHandles) -> [UserAsk] {
        AskBook.pinned(in: chats.messages(chatId: chatId), chatId: chatId, handles: handles, done: store.doneSet())
    }

    public func markDone(_ ask: UserAsk) throws { try store.markDone(ask.messageId) }
    public func markOpen(_ ask: UserAsk) throws { try store.markOpen(ask.messageId) }
}
