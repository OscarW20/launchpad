import Foundation

/// Chat history: chats/<id>.json (title, members, engine sessions) and chats/<id>.jsonl (messages).
public final class ChatStore: @unchecked Sendable {
    public let paths: LaunchpadPaths
    private let fm: FileManager
    private let lock = NSLock()

    public init(paths: LaunchpadPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fm = fileManager
    }

    public func loadAll() -> [ChatMeta] {
        guard let names = try? fm.contentsOfDirectory(atPath: paths.chats.path) else { return [] }
        let decoder = JSONCoding.decoder()
        return names
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            .compactMap { name -> ChatMeta? in
                let url = paths.chats.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(ChatMeta.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    public func createChat(with bot: Bot) throws -> ChatMeta {
        let meta = ChatMeta(title: bot.name, kind: .bot, botId: bot.id)
        try save(meta)
        return meta
    }

    public func save(_ meta: ChatMeta) throws {
        try fm.createDirectory(at: paths.chats, withIntermediateDirectories: true)
        try JSONCoding.encoder().encode(meta).write(to: paths.chatMeta(meta.id), options: .atomic)
    }

    public func delete(chatId: String) throws {
        for url in [paths.chatMeta(chatId), paths.chatLog(chatId)] where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    /// Messages in order. A later line with the same id replaces an earlier one; bad lines are skipped.
    public func messages(chatId: String) -> [ChatMessage] {
        guard let data = try? Data(contentsOf: paths.chatLog(chatId)),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONCoding.decoder()
        var order: [String] = []
        var byId: [String: ChatMessage] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let msg = try? decoder.decode(ChatMessage.self, from: Data(line.utf8)) else { continue }
            if byId[msg.id] == nil { order.append(msg.id) }
            byId[msg.id] = msg
        }
        return order.compactMap { byId[$0] }
    }

    public func append(_ message: ChatMessage, chatId: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try fm.createDirectory(at: paths.chats, withIntermediateDirectories: true)
        var line = try JSONCoding.lineEncoder().encode(message)
        line.append(0x0A)
        let url = paths.chatLog(chatId)
        if !fm.fileExists(atPath: url.path) {
            try line.write(to: url)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }
}
