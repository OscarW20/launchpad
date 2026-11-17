import Foundation

/// An earlier conversation in a chat, put aside by New thread (or by reopening another one).
public struct PastThread: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var startedAt: Date
    public var archivedAt: Date
    /// The engine session per bot, so reopening it brings the bots' memory of it back.
    public var sessions: [String: String]
    public var messageCount: Int
    public var lastPreview: String?

    public init(id: String = UUID().uuidString.lowercased(), title: String, startedAt: Date, archivedAt: Date = Date(),
                sessions: [String: String] = [:], messageCount: Int = 0, lastPreview: String? = nil) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.archivedAt = archivedAt
        self.sessions = sessions
        self.messageCount = messageCount
        self.lastPreview = lastPreview
    }
}

/// A chat's earlier threads, and which bots' sessions missed messages (e.g. while the backup brain answered).
public struct ChatThreadIndex: Codable, Hashable, Sendable {
    public var threads: [PastThread] = []
    /// bot id → id of the last message its session saw. The next turn recaps what came after
    /// (`ConversationRecap.prompt(for:history:hasSession:unseenAfter:)`), then the entry is cleared.
    public var unseenAfter: [String: String] = [:]

    public init(threads: [PastThread] = [], unseenAfter: [String: String] = [:]) {
        self.threads = threads
        self.unseenAfter = unseenAfter
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        threads = (try? c.decodeIfPresent([PastThread].self, forKey: .threads)) ?? []
        unseenAfter = (try? c.decodeIfPresent([String: String].self, forKey: .unseenAfter)) ?? [:]
    }

    enum CodingKeys: String, CodingKey { case threads, unseenAfter }
}

/// Threads in a chat. A chat shows its current conversation (chats/<id>.jsonl, sessions in chats/<id>.json);
/// earlier ones live in chats/threads/<chat id>/ (`index.json` and `<thread id>.jsonl`).
///
/// - **New thread**: the current messages and sessions are put aside; the chat starts empty with fresh sessions.
/// - **Compact**: messages stay on screen; sessions are cleared, so the next turn starts a fresh session seeded
///   with a recap (`ConversationRecap`), freeing the context window.
/// - **Branch from a message**: a new chat with the messages up to that one and no sessions (recap on first reply).
/// - **Reopen**: the current conversation is put aside and the earlier one comes back, sessions and all.
///
/// Call these only while no bot is replying in the chat (the message log is moved on disk).
public final class ThreadStore: @unchecked Sendable {
    public let paths: LaunchpadPaths
    private let chatStore: ChatStore
    private let fm: FileManager
    private let lock = NSLock()

    public static let compactNotice = "Compacted. The chat stays here; the bot's memory now holds a recap of the recent "
        + "conversation, so it has room again."

    public init(paths: LaunchpadPaths, chatStore: ChatStore, fileManager: FileManager = .default) {
        self.paths = paths
        self.chatStore = chatStore
        self.fm = fileManager
    }

    public var root: URL { paths.chats.appendingPathComponent("threads", isDirectory: true) }
    public func folder(_ chatId: String) -> URL { root.appendingPathComponent(chatId, isDirectory: true) }
    func indexURL(_ chatId: String) -> URL { folder(chatId).appendingPathComponent("index.json") }
    public func log(_ chatId: String, thread: String) -> URL { folder(chatId).appendingPathComponent("\(thread).jsonl") }

    public func index(_ chatId: String) -> ChatThreadIndex {
        guard let data = try? Data(contentsOf: indexURL(chatId)) else { return ChatThreadIndex() }
        return (try? JSONCoding.decoder().decode(ChatThreadIndex.self, from: data)) ?? ChatThreadIndex()
    }

    func save(_ index: ChatThreadIndex, chatId: String) throws {
        try fm.createDirectory(at: folder(chatId), withIntermediateDirectories: true)
        try JSONCoding.encoder().encode(index).write(to: indexURL(chatId), options: .atomic)
    }

    /// Earlier threads, newest first.
    public func pastThreads(_ chatId: String) -> [PastThread] {
        index(chatId).threads.sorted { $0.archivedAt > $1.archivedAt }
    }

    /// An earlier thread's messages (read-only view).
    public func messages(_ chatId: String, thread: String) -> [ChatMessage] {
        Self.decode(log(chatId, thread: thread))
    }

    // MARK: Unseen messages

    public func unseenAfter(_ chatId: String, botId: String) -> String? { index(chatId).unseenAfter[botId] }

    /// Records (or with nil, clears) the last message a bot's session saw.
    public func setUnseenAfter(_ messageId: String?, chatId: String, botId: String) throws {
        lock.lock(); defer { lock.unlock() }
        var idx = index(chatId)
        guard idx.unseenAfter[botId] != messageId else { return }
        idx.unseenAfter[botId] = messageId
        try save(idx, chatId: chatId)
    }

    // MARK: Actions

    /// New thread. Returns the chat with its sessions cleared (already saved) and the thread put aside, if any.
    @discardableResult
    public func newThread(_ meta: ChatMeta, now: Date = Date()) throws -> (chat: ChatMeta, archived: PastThread?) {
        lock.lock(); defer { lock.unlock() }
        let archived = try archiveCurrent(meta, now: now)
        var chat = meta
        chat.sessions = [:]
        chat.lastPreview = nil
        chat.updatedAt = now
        try chatStore.save(chat)
        return (chat, archived)
    }

    /// Compact: the same chat with no sessions (pure; save it and post `compactNotice`).
    public static func compacted(_ meta: ChatMeta) -> ChatMeta {
        var chat = meta
        chat.sessions = [:]
        return chat
    }

    /// Compact, saved: clears sessions and any unseen-message marks (the recap covers them).
    @discardableResult
    public func compact(_ meta: ChatMeta) throws -> ChatMeta {
        lock.lock(); defer { lock.unlock() }
        let chat = Self.compacted(meta)
        try chatStore.save(chat)
        var idx = index(meta.id)
        if !idx.unseenAfter.isEmpty { idx.unseenAfter = [:]; try save(idx, chatId: meta.id) }
        return chat
    }

    /// A new chat with the same bot or group and the messages up to and including `messageId`; no sessions, so the
    /// first reply gets a recap. Returns nil if the message isn't in the chat.
    public func branch(_ meta: ChatMeta, upTo messageId: String, now: Date = Date()) throws -> ChatMeta? {
        let list = chatStore.messages(chatId: meta.id)
        guard let i = list.firstIndex(where: { $0.id == messageId }) else { return nil }
        let kept = list[...i].filter { $0.status != .streaming }
        var chat = ChatMeta(title: Self.branchTitle(meta.title), kind: meta.kind, botId: meta.botId, groupId: meta.groupId,
                            createdAt: now, updatedAt: now,
                            lastPreview: kept.last { $0.role != .notice }.map { String($0.text.prefix(200)) })
        chat.sessions = [:]
        try chatStore.save(chat)
        for m in kept { try chatStore.append(m, chatId: chat.id) }
        try chatStore.append(ChatMessage(role: .notice, text: "Branched from “\(meta.title)”. The original chat is unchanged.",
                                         createdAt: now), chatId: chat.id)
        return chat
    }

    /// Brings an earlier thread back; the current conversation is put aside first. Returns the updated chat.
    public func reopen(_ meta: ChatMeta, thread threadId: String, now: Date = Date()) throws -> ChatMeta? {
        lock.lock(); defer { lock.unlock() }
        guard let past = index(meta.id).threads.first(where: { $0.id == threadId }) else { return nil }
        try archiveCurrent(meta, now: now)
        var idx = index(meta.id)
        idx.threads.removeAll { $0.id == threadId }
        idx.unseenAfter = [:]
        let from = log(meta.id, thread: threadId)
        let to = paths.chatLog(meta.id)
        if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
        if fm.fileExists(atPath: from.path) { try fm.moveItem(at: from, to: to) }
        try save(idx, chatId: meta.id)
        var chat = meta
        chat.sessions = past.sessions
        chat.lastPreview = past.lastPreview
        chat.updatedAt = now
        try chatStore.save(chat)
        return chat
    }

    public func delete(_ chatId: String, thread threadId: String) throws {
        lock.lock(); defer { lock.unlock() }
        var idx = index(chatId)
        idx.threads.removeAll { $0.id == threadId }
        let url = log(chatId, thread: threadId)
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try save(idx, chatId: chatId)
    }

    /// Everything for a deleted chat.
    public func deleteAll(_ chatId: String) {
        try? fm.removeItem(at: folder(chatId))
    }

    // MARK: Helpers

    /// Moves the current messages and sessions into a past thread (only if you wrote something), and empties the log.
    @discardableResult
    private func archiveCurrent(_ meta: ChatMeta, now: Date) throws -> PastThread? {
        let current = paths.chatLog(meta.id)
        let list = Self.decode(current)
        var idx = index(meta.id)
        idx.unseenAfter = [:]
        guard list.contains(where: { $0.role == .user }) else {
            if fm.fileExists(atPath: current.path) { try fm.removeItem(at: current) }
            try save(idx, chatId: meta.id)
            return nil
        }
        let past = PastThread(title: ConversationRecap.title(list, fallback: meta.title),
                              startedAt: list.first?.createdAt ?? meta.createdAt, archivedAt: now,
                              sessions: meta.sessions, messageCount: list.count,
                              lastPreview: list.last { $0.role != .notice && !$0.text.isEmpty }.map { String($0.text.prefix(200)) })
        try fm.createDirectory(at: folder(meta.id), withIntermediateDirectories: true)
        try fm.moveItem(at: current, to: log(meta.id, thread: past.id))
        idx.threads.append(past)
        try save(idx, chatId: meta.id)
        return past
    }

    static func branchTitle(_ title: String) -> String {
        title.hasSuffix(" (branch)") ? title : "\(title) (branch)"
    }

    static func decode(_ url: URL) -> [ChatMessage] {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONCoding.decoder()
        var order: [String] = []
        var byId: [String: ChatMessage] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let m = try? decoder.decode(ChatMessage.self, from: Data(line.utf8)) else { continue }
            if byId[m.id] == nil { order.append(m.id) }
            byId[m.id] = m
        }
        return order.compactMap { byId[$0] }
    }
}
