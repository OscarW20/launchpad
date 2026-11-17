import XCTest
@testable import LaunchpadCore

final class StoreTests: XCTestCase {
    var paths: LaunchpadPaths!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lp-store-\(UUID().uuidString)")
        paths = LaunchpadPaths(root: root)
        try paths.ensureStructure()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: paths.root)
    }

    func testCreateBotMakesTheFolder() throws {
        let store = BotStore(paths: paths)
        let bot = try store.create(name: "Frontend Dev", emoji: "🎨", role: "Frontend engineer", engine: .claude)
        XCTAssertEqual(bot.id, "frontend-dev")
        let fm = FileManager.default
        for url in [paths.botJSON(bot.id), paths.claudeMD(bot.id), paths.agentsMD(bot.id), paths.memoryMD(bot.id)] {
            XCTAssertTrue(fm.fileExists(atPath: url.path), url.lastPathComponent)
        }
        var isDir: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: paths.workspace(bot.id).path, isDirectory: &isDir) && isDir.boolValue)
        XCTAssertEqual(try store.load(id: bot.id), bot.withRoundedDate())
        XCTAssertTrue(store.instructions(for: bot.id).contains("Frontend engineer"))
    }

    func testIdsAreUnique() throws {
        let store = BotStore(paths: paths)
        XCTAssertEqual(try store.create(name: "Lead").id, "lead")
        XCTAssertEqual(try store.create(name: "Lead").id, "lead-2")
        XCTAssertThrowsError(try store.create(name: "   "))
    }

    func testHandWrittenBotJSONLoads() throws {
        let dir = paths.botDir("scout")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"name":"Scout","engine":"codex","permission":"read-only"}"#.write(to: paths.botJSON("scout"), atomically: true, encoding: .utf8)
        let bots = BotStore(paths: paths).loadAll()
        XCTAssertEqual(bots.count, 1)
        XCTAssertEqual(bots[0].id, "scout")
        XCTAssertEqual(bots[0].engine, .codex)
        XCTAssertEqual(bots[0].permission, .readOnly)
        XCTAssertEqual(bots[0].emoji, "🤖")
    }

    func testInstructionsSyncNewestWins() throws {
        let store = BotStore(paths: paths)
        let bot = try store.create(name: "Sync")
        XCTAssertFalse(store.syncInstructions(for: bot.id), "fresh bots are already in sync")

        // Someone edits AGENTS.md by hand, later than CLAUDE.md.
        try "old".write(to: paths.claudeMD(bot.id), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: paths.claudeMD(bot.id).path)
        try "new from codex".write(to: paths.agentsMD(bot.id), atomically: true, encoding: .utf8)

        XCTAssertTrue(store.syncInstructions(for: bot.id))
        XCTAssertEqual(try String(contentsOf: paths.claudeMD(bot.id), encoding: .utf8), "new from codex")
        XCTAssertEqual(store.instructions(for: bot.id), "new from codex")
    }

    func testInstructionsSyncFillsMissingFile() throws {
        let store = BotStore(paths: paths)
        let bot = try store.create(name: "Half")
        try FileManager.default.removeItem(at: paths.agentsMD(bot.id))
        XCTAssertTrue(store.syncInstructions(for: bot.id))
        XCTAssertEqual(try String(contentsOf: paths.agentsMD(bot.id), encoding: .utf8),
                       try String(contentsOf: paths.claudeMD(bot.id), encoding: .utf8))
    }

    func testChatHistoryAppendsAndReplaces() throws {
        let bots = BotStore(paths: paths)
        let chats = ChatStore(paths: paths)
        let bot = try bots.create(name: "Ada")
        var meta = try chats.createChat(with: bot)
        meta.sessions[bot.id] = "session-1"
        try chats.save(meta)

        let user = ChatMessage(role: .user, text: "hi")
        var reply = ChatMessage(role: .bot, botId: bot.id, text: "hel", status: .streaming)
        try chats.append(user, chatId: meta.id)
        try chats.append(reply, chatId: meta.id)
        reply.text = "hello!"
        reply.status = .done
        try chats.append(reply, chatId: meta.id)
        // A corrupt line shouldn't lose the chat.
        let handle = try FileHandle(forWritingTo: paths.chatLog(meta.id))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{broken\n".utf8))
        try handle.close()

        let loaded = chats.messages(chatId: meta.id)
        XCTAssertEqual(loaded.map(\.text), ["hi", "hello!"])
        XCTAssertEqual(chats.loadAll().first?.sessions[bot.id], "session-1")
    }

    func testWatcherSeesNewBotsAndEdits() throws {
        let watcher = FolderWatcher(paths: paths) { _ in }
        XCTAssertEqual(watcher.checkNow(), [])
        let store = BotStore(paths: paths)
        let bot = try store.create(name: "Watcher Test")
        XCTAssertTrue(watcher.checkNow().contains(.bots))
        XCTAssertEqual(watcher.checkNow(), [])

        // Workspace churn is ignored.
        try "x".write(to: paths.workspace(bot.id).appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(watcher.checkNow(), [])

        try "# changed instructions, longer".write(to: paths.claudeMD(bot.id), atomically: true, encoding: .utf8)
        XCTAssertEqual(watcher.checkNow(), [.bots])

        try FileManager.default.createDirectory(at: paths.skills.appendingPathComponent("deploy"), withIntermediateDirectories: true)
        try "# Deploy".write(to: paths.skills.appendingPathComponent("deploy/SKILL.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(watcher.checkNow(), [.skills])
    }

    func testSlugs() {
        XCTAssertEqual(Slug.make("Frontend Dev!"), "frontend-dev")
        XCTAssertEqual(Slug.make("Café Bot"), "cafe-bot")
        XCTAssertEqual(Slug.make("🤖"), "bot")
        XCTAssertEqual(Slug.unique("Lead", taken: ["lead", "lead-2"]), "lead-3")
    }
}

private extension Bot {
    /// ISO8601 drops sub-second precision.
    func withRoundedDate() -> Bot {
        var b = self
        b.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
        return b
    }
}
