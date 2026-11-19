import Foundation

// Asks addressed to you. A long report from a bot can end with the one thing it needs from you; this finds it, so the app can
// lift it out of the message, count it, list it across chats, and say when it's been dealt with. No UI here.
//
// What counts as an ask (the team notes tell bots to write it this way):
//   - a "Needs you" heading (`**Needs you**`, `Needs you:`, `## Needs you`), and what follows it, or
//   - a line or paragraph that STARTS with `@oscar` (after any list or quote marks and bold).
// A mention in the middle of a sentence ("thanks @oscar for the review") is an ordinary mention, not an ask.
// Choices are the list lines under the ask: `-`, `*`, `•`, `1.`, `1)`, `a)`, `A.`.

/// One ask found in a message.
public struct ParsedAsk: Equatable, Sendable {
    /// What's needed, in plain words (no @oscar, no bold marks).
    public var text: String
    /// The options, one per list line, without their markers. Reply with a choice as it is.
    public var choices: [String]
}

public enum AskParser {
    /// Who the asks are for.
    public static let defaultHandles = ["oscar"]
    static let maxTextLength = 600
    static let maxChoiceLength = 200
    static let maxChoices = 8

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
            if !text.isEmpty || !choices.isEmpty {
                let ask = ParsedAsk(text: String(text.prefix(maxTextLength)),
                                    choices: choices.prefix(maxChoices).map { String($0.prefix(maxChoiceLength)) })
                last = Found(ask: ask, lines: first..<max(j, first + 1))
            }
            i = max(j, first + 1)
        }
        return last
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
            if let lastReply, let at = positions[a.messageId], lastReply > at { return false }
            return true
        }
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

    public func markDone(_ ask: UserAsk) throws { try store.markDone(ask.messageId) }
    public func markOpen(_ ask: UserAsk) throws { try store.markOpen(ask.messageId) }
}
