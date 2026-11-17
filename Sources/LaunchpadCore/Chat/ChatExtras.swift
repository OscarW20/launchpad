import Foundation

// MARK: - Attachments

/// Files you drop on a chat are copied into the bot's `workspace/Inbox` (a group's `workspace/Inbox`) and listed in
/// your message, so the bot can open them.
public enum Attachments {
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"]

    public static func inbox(for chat: ChatMeta, paths: LaunchpadPaths) -> URL? {
        if chat.kind == .group, let g = chat.groupId {
            return paths.groups.appendingPathComponent(g, isDirectory: true).appendingPathComponent("workspace/Inbox", isDirectory: true)
        }
        guard let b = chat.botId else { return nil }
        return paths.workspace(b).appendingPathComponent("Inbox", isDirectory: true)
    }

    /// "report.pdf", then "report 2.pdf", "report 3.pdf"… (names without an extension: "notes 2").
    public static func uniqueName(_ name: String, taken: (String) -> Bool) -> String {
        guard taken(name) else { return name }
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !taken(candidate) { return candidate }
            n += 1
        }
    }

    /// Copies files in and returns where they went. Clashing names get a number; files that can't be copied are skipped.
    public static func copy(_ urls: [URL], into folder: URL, fileManager fm: FileManager = .default) -> [URL] {
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return urls.compactMap { src in
            let name = uniqueName(src.lastPathComponent) { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
            let dest = folder.appendingPathComponent(name)
            return (try? fm.copyItem(at: src, to: dest)) != nil ? dest : nil
        }
    }

    /// Added to your message so the bot knows where the files are.
    public static func note(_ paths: [String]) -> String {
        guard !paths.isEmpty else { return "" }
        return "\n\nAttached file\(paths.count == 1 ? "" : "s") (copied to your folder):\n" + paths.map { "- \($0)" }.joined(separator: "\n")
    }

    public static func note(_ files: [URL]) -> String { note(files.map(\.path)) }

    public static func isImage(_ path: String) -> Bool { imageExtensions.contains((path as NSString).pathExtension.lowercased()) }
}

// MARK: - Saved prompts

/// Messages you send often, one click away in the composer. `.launchpad/saved-prompts.json`.
public final class SavedPromptsStore: @unchecked Sendable {
    public static let defaults = [
        "Summarise what you did today in three bullets.",
        "Remember this for next time:",
        "Make a step-by-step plan before you start.",
    ]
    public static let limit = 50

    public let url: URL
    private let fm: FileManager

    public init(paths: LaunchpadPaths, fileManager: FileManager = .default) {
        self.url = paths.savedPromptsFile
        self.fm = fileManager
    }

    /// The defaults until the file exists.
    public func load() -> [String] {
        guard let data = fm.contents(atPath: url.path) else { return Self.defaults }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? Self.defaults
    }

    /// Newest first; a prompt that's already there moves to the top.
    @discardableResult
    public func add(_ text: String) throws -> [String] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return load() }
        var list = load().filter { $0 != t }
        list.insert(t, at: 0)
        return try save(Array(list.prefix(Self.limit)))
    }

    @discardableResult
    public func remove(_ text: String) throws -> [String] {
        try save(load().filter { $0 != text })
    }

    @discardableResult
    public func save(_ list: [String]) throws -> [String] {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try e.encode(list).write(to: url, options: .atomic)
        return list
    }

    /// Short label for a menu.
    public static func label(_ prompt: String) -> String {
        let flat = prompt.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 60 ? String(flat.prefix(60)) + "…" : flat
    }
}

// MARK: - Export

public enum ChatExport {
    /// The chat as Markdown: a heading per day, then "**Who** · time" and the text. Deleted messages are left out;
    /// notices show as "Note"; polls, GIFs, files and edits are written out.
    public static func markdown(title: String, messages: [ChatMessage], name: (ChatMessage) -> String,
                                exportedAt: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        func fmt(_ date: DateFormatter.Style, _ time: DateFormatter.Style) -> DateFormatter {
            let f = DateFormatter()
            f.locale = locale
            f.timeZone = timeZone
            f.dateStyle = date
            f.timeStyle = time
            return f
        }
        let stampF = fmt(.medium, .short), dayF = fmt(.full, .none), clockF = fmt(.none, .short)
        // Newer ICU puts a narrow no-break space before AM/PM; plain spaces read better in a text file.
        func plain(_ f: DateFormatter) -> (Date) -> String { { f.string(from: $0).replacingOccurrences(of: "\u{202F}", with: " ") } }
        let stamp = plain(stampF), day = plain(dayF), clock = plain(clockF)
        var out = "# \(title)\n\nExported from Launchpad on \(stamp(exportedAt)).\n"
        var lastDay: Date?
        for m in messages where m.deleted != true {
            var body = m.text
            if let p = m.poll { body += (body.isEmpty ? "" : "\n\n") + p.options.enumerated().reduce("**Poll: \(p.question)**") { s, o in
                let n = p.votes.values.filter { $0 == o.offset }.count
                return s + "\n- \(o.element) (\(n) vote\(n == 1 ? "" : "s"))"
            } }
            if let g = m.gif { body += (body.isEmpty ? "" : "\n\n") + "![\(g.title ?? "GIF")](\(g.url))" }
            if let a = m.attachments, !a.isEmpty { body += (body.isEmpty ? "" : "\n\n") + a.map { "📎 \($0)" }.joined(separator: "\n") }
            if body.isEmpty, let f = m.failure { body = "_(couldn't reply: \(f.message))_" }
            guard !body.isEmpty else { continue }
            if lastDay.map({ !calendar.isDate($0, inSameDayAs: m.createdAt) }) ?? true {
                out += "\n## \(day(m.createdAt))\n"
                lastDay = m.createdAt
            }
            let who = m.role == .notice ? "Note" : name(m)
            var meta = "**\(who)** · \(clock(m.createdAt))"
            if let from = m.forwardedFrom { meta += " · forwarded from \(from)" }
            if ChatOps.isEdited(m) { meta += " · edited" }
            out += "\n\(meta)\n\n\(body)\n"
        }
        return out
    }

    /// "Planner chat.md", safe as a file name.
    public static func fileName(for title: String) -> String {
        let clean = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(clean.isEmpty ? "Chat" : clean) chat.md"
    }
}

// MARK: - Quick switcher (⌘K)

public struct SwitcherItem: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case chat, bot, group, page, action, message }

    public var id: String
    public var kind: Kind
    public var title: String
    public var detail: String
    /// For chats and messages.
    public var chatId: String?
    public var messageId: String?
    public var date: Date?

    public init(id: String, kind: Kind, title: String, detail: String = "", chatId: String? = nil, messageId: String? = nil, date: Date? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.chatId = chatId
        self.messageId = messageId
        self.date = date
    }
}

public enum QuickSearch {
    public static let messageLimit = 25

    /// How well an item matches (higher is better), or nil for no match.
    /// Title equal 100, title starts with 80, a word in the title starts with 60, title contains 40, detail 20.
    public static func score(_ query: String, title: String, detail: String) -> Int? {
        let q = query.trimmingCharacters(in: .whitespaces).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !q.isEmpty else { return 0 }
        let t = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if t == q { return 100 }
        if t.hasPrefix(q) { return 80 }
        let words = t.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.contains(where: { $0.hasPrefix(q) }) { return 60 }
        if t.contains(q) { return 40 }
        if detail.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(q) { return 20 }
        return nil
    }

    /// Chats, pages and actions ranked by `score` (ties keep their order); with 2+ characters, then messages that
    /// contain the words, newest first. An empty query returns `items` unchanged.
    public static func search(_ query: String, items: [SwitcherItem],
                              chats: [(meta: ChatMeta, messages: [ChatMessage])] = [],
                              name: (ChatMessage) -> String = { _ in "" }) -> [SwitcherItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        let ranked = items.enumerated().compactMap { i, item in score(q, title: item.title, detail: item.detail).map { (i, $0, item) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.map(\.2)
        guard q.count >= 2 else { return ranked }
        return ranked + messageHits(q, chats: chats, name: name)
    }

    public static func messageHits(_ query: String, chats: [(meta: ChatMeta, messages: [ChatMessage])],
                                   name: (ChatMessage) -> String) -> [SwitcherItem] {
        var found: [(ChatMeta, ChatMessage)] = []
        for (meta, messages) in chats {
            for m in messages where m.role != .notice && m.deleted != true && m.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                found.append((meta, m))
            }
        }
        return found.sorted { $0.1.createdAt > $1.1.createdAt }.prefix(messageLimit).map { meta, m in
            SwitcherItem(id: "m:\(meta.id):\(m.id)", kind: .message, title: snippet(m.text, query: query),
                         detail: "\(name(m)) in \(meta.title)", chatId: meta.id, messageId: m.id, date: m.createdAt)
        }
    }

    /// The matching words with a little of the text before them, on one line.
    public static func snippet(_ text: String, query: String, before: Int = 30, length: Int = 90) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let r = flat.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { return String(flat.prefix(length)) }
        let start = flat.index(r.lowerBound, offsetBy: -before, limitedBy: flat.startIndex) ?? flat.startIndex
        return (start == flat.startIndex ? "" : "…") + String(flat[start...].prefix(length))
    }
}
