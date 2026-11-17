import XCTest
@testable import LaunchpadCore

/// To-do lists, context meter, backup brain, steering, threads, side questions, Codex home and session logs.
final class ConversationFeatureTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lp-conv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func parseAll(_ parser: StreamParser, _ lines: [String]) -> [RunEvent] {
        lines.flatMap { parser.parse(line: $0) }
    }

    // MARK: To-do list

    func testClaudeTaskToolsBuildTheTodoList() {
        let events = parseAll(ClaudeStreamParser(), Fixtures.claudeTaskRun)
        let lists = events.compactMap { e -> [TodoItem]? in if case .todos(let t) = e { return t }; return nil }
        XCTAssertEqual(lists.count, 6, "2 creates + 2 numbered + 2 updates")
        XCTAssertEqual(lists.last, [
            TodoItem(id: "1", title: "Write tests", activeTitle: "Writing tests", status: .completed),
            TodoItem(id: "2", title: "Ship it", activeTitle: "Shipping it", status: .pending),
        ])
        // The in-progress state was shown on the way.
        XCTAssertTrue(lists.contains { $0.first?.status == .inProgress && $0.first?.label == "Writing tests" })
        // Steps are still reported too.
        XCTAssertTrue(events.contains { if case .stepStarted(_, "TaskCreate", _, _) = $0 { return true }; return false })

        var builder = MessageBuilder(botId: "b")
        events.forEach { builder.apply($0) }
        XCTAssertEqual(builder.todos, lists.last)
        XCTAssertEqual(builder.message.text, "done")
    }

    func testTodoWriteReplacesTheList() {
        let t = TodoTracker()
        XCTAssertTrue(t.toolUse(name: "TodoWrite", id: "x", input: ["todos": [
            ["content": "Plan", "status": "completed", "activeForm": "Planning"],
            ["content": "Build", "status": "in_progress", "activeForm": "Building"],
            ["content": "Ship", "status": "pending"],
        ]]))
        XCTAssertEqual(t.items.map(\.label), ["Plan", "Building", "Ship"])
        XCTAssertEqual(t.items.map(\.status), [.completed, .inProgress, .pending])
        XCTAssertFalse(t.toolUse(name: "Bash", id: "y", input: [:]))
        XCTAssertFalse(t.toolUse(name: "TaskUpdate", id: "z", input: ["taskId": "99", "status": "completed"]))
        // TaskUpdate with a numeric id and a delete.
        _ = t.toolUse(name: "TodoWrite", id: nil, input: ["todos": [["id": "7", "content": "A", "status": "pending"]]])
        XCTAssertTrue(t.toolUse(name: "TaskUpdate", id: nil, input: ["taskId": 7, "status": "deleted"]))
        XCTAssertTrue(t.items.isEmpty)
    }

    func testCodexTodoList() {
        // codex exec --json todo_list items (shape as documented for codex-cli exec JSON events).
        let lines = [
            #"{"type":"item.started","item":{"id":"item_1","type":"todo_list","items":[{"text":"Read the code","completed":false},{"text":"Fix it","completed":false}]}}"#,
            #"{"type":"item.updated","item":{"id":"item_1","type":"todo_list","items":[{"text":"Read the code","completed":true},{"text":"Fix it","completed":false}]}}"#,
            #"{"type":"item.completed","item":{"id":"item_1","type":"todo_list","items":[{"text":"Read the code","completed":true},{"text":"Fix it","completed":false}]}}"#,
        ]
        let events = parseAll(CodexStreamParser(), lines)
        let lists = events.compactMap { e -> [TodoItem]? in if case .todos(let t) = e { return t }; return nil }
        XCTAssertEqual(lists.count, 2, "an unchanged list isn't sent again")
        XCTAssertEqual(lists[0].map(\.status), [.inProgress, .pending])
        XCTAssertEqual(lists[1].map(\.status), [.completed, .inProgress])
        XCTAssertEqual(lists[1].map(\.title), ["Read the code", "Fix it"])
    }

    // MARK: Context meter

    func testClaudeContextFromUsageAndModelUsage() {
        let events = parseAll(ClaudeStreamParser(), Fixtures.claudeTaskRun)
        let contexts = events.compactMap { e -> ContextUsage? in if case .context(let c) = e { return c }; return nil }
        XCTAssertFalse(contexts.isEmpty)
        let last = contexts.last!
        XCTAssertEqual(last.window, 1_000_000)
        XCTAssertEqual(last.used, 2 + 112 + 9733, "the last call's input, cached input included")
        var builder = MessageBuilder(botId: "b")
        events.forEach { builder.apply($0) }
        XCTAssertEqual(builder.context, last)
        XCTAssertFalse(builder.context!.isEstimated)
    }

    func testContextUsageMaths() {
        let c = ContextUsage(engine: .claude, used: 150_000)
        XCTAssertTrue(c.isEstimated)
        XCTAssertEqual(c.size, 200_000)
        XCTAssertEqual(c.fraction, 0.75, accuracy: 0.0001)
        XCTAssertFalse(c.isNearlyFull)
        XCTAssertEqual(c.free, 50_000)
        XCTAssertEqual(c.summary, "150.0K of 200.0K (estimated) · 75%")
        let over = ContextUsage(engine: .codex, used: 300_000, window: 272_000)
        XCTAssertEqual(over.fraction, 1)
        XCTAssertTrue(over.isNearlyFull)
        let merged = ContextUsage(engine: .claude, used: 10, window: 1_000_000).merged(with: ContextUsage(engine: .claude, used: 20))
        XCTAssertEqual(merged, ContextUsage(engine: .claude, used: 20, window: 1_000_000))
        XCTAssertEqual(ContextUsage.tokens(1_234_567), "1.2M")
        XCTAssertEqual(ContextUsage.tokens(999), "999")
    }

    // MARK: Codex session logs

    private func writeLog(_ relative: String, _ lines: [String], modified: Date) throws -> URL {
        let url = tmp.appendingPathComponent("sessions/\(relative)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    /// `token_count` events as Codex 0.169 writes them (RateLimitWindow: used_percent, window_minutes, resets_at).
    static func tokenCount(primary: Double, secondary: Double, used: Int, window: Int = 272_000, resets: Int = 1_795_000_000) -> String {
        #"{"timestamp":"2026-11-17T13:44:10.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":90000,"cached_input_tokens":80000,"output_tokens":900,"reasoning_output_tokens":100,"total_tokens":90900},"last_token_usage":{"input_tokens":\#(used - 100),"cached_input_tokens":20000,"output_tokens":100,"reasoning_output_tokens":0,"total_tokens":\#(used)},"model_context_window":\#(window)},"rate_limits":{"primary":{"used_percent":\#(primary),"window_minutes":300,"resets_at":\#(resets)},"secondary":{"used_percent":\#(secondary),"window_minutes":10080,"resets_at":\#(resets + 86400)}}}}"#
    }

    func testCodexUsageFromNewestSessionLog() throws {
        let root = tmp.appendingPathComponent("sessions")
        let now = Date()
        _ = try writeLog("2026/11/16/rollout-2026-11-16T10-00-00-aaaa.jsonl",
                         [Self.tokenCount(primary: 80, secondary: 40, used: 5000)], modified: now.addingTimeInterval(-3600))
        _ = try writeLog("2026/11/17/rollout-2026-11-17T13-43-52-bbbb.jsonl", [
            #"{"timestamp":"2026-11-17T13:43:52.847Z","type":"session_meta","payload":{"id":"bbbb"}}"#,
            Self.tokenCount(primary: 10, secondary: 5, used: 30_000),
            Self.tokenCount(primary: 12.5, secondary: 6, used: 41_000),
            #"{"timestamp":"2026-11-17T13:44:12.000Z","type":"event_msg","payload":{"type":"task_complete"}}"#,
        ], modified: now)
        // A newer log without rate limits is skipped over.
        _ = try writeLog("2026/11/17/rollout-2026-11-17T14-00-00-cccc.jsonl",
                         [#"{"type":"event_msg","payload":{"type":"turn_aborted"}}"#], modified: now.addingTimeInterval(60))

        let report = try XCTUnwrap(CodexSessionLogs.usageReport(root: root))
        XCTAssertEqual(report.engine, .codex)
        XCTAssertEqual(report.windows.map(\.name), ["five_hour", "seven_day"])
        XCTAssertEqual(report.windows[0].utilization, 0.125, accuracy: 0.0001)
        XCTAssertEqual(report.windows[0].resetsAt, Date(timeIntervalSince1970: 1_795_000_000))
        XCTAssertEqual(report.windows[1].label, "Week")

        let context = try XCTUnwrap(CodexSessionLogs.context(threadId: "bbbb", root: root))
        XCTAssertEqual(context, ContextUsage(engine: .codex, used: 41_000, window: 272_000))
        XCTAssertNil(CodexSessionLogs.context(threadId: "zzzz", root: root))
        XCTAssertNil(CodexSessionLogs.usageReport(root: tmp.appendingPathComponent("nothing")))
    }

    func testCodexRateWindowVariants() {
        let now = Date(timeIntervalSince1970: 1_000)
        let windows = CodexSessionLogs.rateWindows([
            "primary": ["used_percent": 150, "resets_in_seconds": 60],
            "secondary": ["used_percent": 1, "window_minutes": 1440],
        ], now: now)
        XCTAssertEqual(windows.map(\.name), ["five_hour", "1_day"])
        XCTAssertEqual(windows[0].utilization, 1)
        XCTAssertEqual(windows[0].resetsAt, Date(timeIntervalSince1970: 1_060))
    }

    func testUsageStoreKeepsCodexWindows() throws {
        let paths = LaunchpadPaths(root: tmp)
        let store = UsageStore(paths: paths)
        // An older usage.json without codexWindows still loads.
        let file = tmp.appendingPathComponent(".launchpad/usage.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"claudeWindows":[],"claudeCostToday":1.5,"codexTokensToday":7}"#.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.load().claudeCostToday, 1.5)
        let s = store.record(UsageReport(engine: .codex, windows: [UsageWindow(name: "five_hour", utilization: 0.2, resetsAt: nil)]))
        XCTAssertEqual(s.codexWindows?.first?.utilization, 0.2)
        XCTAssertEqual(s.codexTokensToday, 7)
        let s2 = store.record(UsageReport(engine: .codex, windows: [UsageWindow(name: "five_hour", utilization: 0.3, resetsAt: nil)]))
        XCTAssertEqual(s2.codexWindows?.count, 1)
        XCTAssertEqual(store.record(UsageReport(engine: .local, tokens: 5)).codexTokensToday, 7)
    }

    // MARK: Codex home

    func testCodexHomeLinksEverythingButConfig() throws {
        let fm = FileManager.default
        let real = tmp.appendingPathComponent("dot-codex"), own = tmp.appendingPathComponent("own")
        let home = CodexHome(real: real, own: own)
        XCTAssertEqual(home.environment(), [:], "not signed in: leave Codex alone")

        try fm.createDirectory(at: real.appendingPathComponent("skills"), withIntermediateDirectories: true)
        try "{\"token\":\"x\"}".write(to: real.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        try """
        model = "gpt-5"

        [mcp_servers.github]
        command = "npx"
        args = ["-y", "gh"]

        [mcp_servers.github.env]
        TOKEN = "t"

        [profiles.fast]
        model = "gpt-5-mini"
        """.write(to: real.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        XCTAssertEqual(home.environment(), ["CODEX_HOME": own.path])
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: own.appendingPathComponent("auth.json").path),
                       real.appendingPathComponent("auth.json").path)
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: own.appendingPathComponent("skills").path))
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: own.appendingPathComponent("sessions").path))
        XCTAssertTrue(fm.fileExists(atPath: real.appendingPathComponent("sessions").path))
        let config = try String(contentsOf: own.appendingPathComponent("config.toml"), encoding: .utf8)
        XCTAssertTrue(config.contains("model = \"gpt-5\""))
        XCTAssertTrue(config.contains("[profiles.fast]"))
        XCTAssertFalse(config.contains("mcp_servers"))
        XCTAssertFalse(config.contains("TOKEN"))
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: own.appendingPathComponent("config.toml").path))

        // Codex saved a newer sign-in over our link: it goes back to ~/.codex and the link returns.
        let link = own.appendingPathComponent("auth.json")
        try fm.removeItem(at: link)
        try "{\"token\":\"new\"}".write(to: link, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: link.path)
        XCTAssertTrue(home.prepare())
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: link.path))
        XCTAssertEqual(try String(contentsOf: real.appendingPathComponent("auth.json"), encoding: .utf8), "{\"token\":\"new\"}")
    }

    func testStrippingMCPServersFromToml() {
        let toml = "mcp_servers = { a = { command = \"x\" } }\nmodel = \"o3\"\n[mcp_servers]\nb.command = \"y\"\n[tui]\ntheme = \"dark\"\n"
        XCTAssertEqual(CodexHome.withoutMCPServers(toml), "model = \"o3\"\n[tui]\ntheme = \"dark\"\n")
        XCTAssertEqual(CodexHome.withoutMCPServers(""), "")
    }

    // MARK: Recap & backup brain

    private var sampleChat: [ChatMessage] {
        [
            ChatMessage(id: "1", role: .user, text: "Plan a trip to Rome"),
            ChatMessage(id: "2", role: .bot, botId: "b", text: "Sure: 3 days, Colosseum first."),
            ChatMessage(id: "3", role: .notice, text: "Memory updated"),
            ChatMessage(id: "4", role: .bot, botId: "b", text: "oops", status: .failed),
            ChatMessage(id: "5", role: .user, text: "Add a day trip"),
        ]
    }

    func testRecapPrompts() {
        let names = ["b": "Guide"]
        let fresh = ConversationRecap.prompt(for: "Add a day trip", history: sampleChat, hasSession: false, names: names)
        XCTAssertEqual(fresh, """
        Recent conversation so far (you don't have it in memory):
        User: Plan a trip to Rome
        Guide: Sure: 3 days, Colosseum first.

        ---
        New message: Add a day trip
        """)
        XCTAssertEqual(ConversationRecap.prompt(for: "Add a day trip", history: sampleChat, hasSession: true), "Add a day trip")
        let caught = ConversationRecap.prompt(for: "Add a day trip", history: sampleChat, hasSession: true, unseenAfter: "1", names: names)
        XCTAssertTrue(caught.hasPrefix("While you were away, this happened in the chat:\nGuide: Sure"))
        XCTAssertFalse(caught.contains("Plan a trip"))
        XCTAssertEqual(ConversationRecap.prompt(for: "hi", history: [], hasSession: false), "hi")
        XCTAssertEqual(ConversationRecap.title(sampleChat), "Plan a trip to Rome")
        XCTAssertEqual(ConversationRecap.title([ChatMessage(role: .user, text: String(repeating: "a", count: 80))]).count, 60)
        let long = ConversationRecap.lines([ChatMessage(role: .user, text: String(repeating: "z", count: 3000))])
        XCTAssertEqual(long.first?.count, "User: ".count + 1500 + 1)
    }

    func testBackupDecision() {
        let usage = RunFailure(kind: .usageLimit, message: "limit")
        var bot = Bot(id: "b", name: "B", engine: .claude, model: "opus")
        XCTAssertNil(BackupPolicy.retryBrain(after: usage, bot: bot, alreadyOnBackup: false), "no backup set")
        bot.backup = BotBrain(engine: .codex, model: "gpt-5")
        XCTAssertEqual(BackupPolicy.retryBrain(after: usage, bot: bot, alreadyOnBackup: false), bot.backup)
        XCTAssertNil(BackupPolicy.retryBrain(after: usage, bot: bot, alreadyOnBackup: true), "only once")
        XCTAssertNil(BackupPolicy.retryBrain(after: RunFailure(kind: .network, message: "x"), bot: bot, alreadyOnBackup: false))
        XCTAssertNil(BackupPolicy.retryBrain(after: nil, bot: bot, alreadyOnBackup: false))
        bot.backup = BotBrain(engine: .claude, model: "opus")
        XCTAssertNil(BackupPolicy.retryBrain(after: usage, bot: bot, alreadyOnBackup: false), "same brain")
        bot.backup = BotBrain(engine: .claude, model: "haiku")
        XCTAssertNotNil(BackupPolicy.retryBrain(after: usage, bot: bot, alreadyOnBackup: false), "a cheaper model counts")
    }

    func testRunningOnBackup() {
        var bot = Bot(id: "b", name: "B", engine: .claude, model: "opus", permission: .fullAccess, connectors: ["github"])
        bot.backup = BotBrain(engine: .local, model: "llama3.2")
        let b = bot.running(on: bot.backup!)
        XCTAssertEqual(b.engine, .local)
        XCTAssertEqual(b.model, "llama3.2")
        XCTAssertNil(b.backup)
        XCTAssertEqual(b.permission, .fullAccess)
        XCTAssertEqual(b.connectors, ["github"])
        XCTAssertEqual(bot.brain.label, "Claude Code · opus")

        let codexPrompt = BackupPolicy.prompt("Add a day trip", history: sampleChat, backup: BotBrain(engine: .codex))
        XCTAssertTrue(codexPrompt.contains("Plan a trip to Rome"))
        XCTAssertEqual(BackupPolicy.prompt("Add a day trip", history: sampleChat, backup: BotBrain(engine: .local)), "Add a day trip")
        XCTAssertEqual(BackupPolicy.notice(botName: "Ada", from: BotBrain(engine: .claude), to: BotBrain(engine: .codex, model: "gpt-5")),
                       "Claude Code hit your Claude plan's usage limit, so Ada answered on Codex · gpt-5 instead.")
    }

    // MARK: Steering & batching

    func testSteeringAndBatching() {
        var q = TurnQueue()
        XCTAssertEqual(q.submit(QueuedMessage(id: "m1", botId: "b", text: "Build the page"), runningBotId: nil), .startNow)
        let first = q.next(for: "b")!
        XCTAssertEqual(first.text, "Build the page")
        XCTAssertFalse(first.carriesOn)

        // You write while it works: steer.
        XCTAssertEqual(q.submit(QueuedMessage(id: "m2", botId: "b", text: "Make it blue"), runningBotId: "b"), .steer)
        XCTAssertTrue(q.isSteering("b"))
        // Another before the run has stopped joins the same next turn.
        XCTAssertEqual(q.submit(QueuedMessage(id: "m3", botId: "b", text: "And bigger"), runningBotId: "b"), .queue)
        q.runEnded(first, stoppedForSteering: true, hadSession: true)
        let next = q.next(for: "b")!
        XCTAssertTrue(next.carriesOn)
        XCTAssertTrue(next.text.hasPrefix(TurnQueue.carryOnNote))
        XCTAssertTrue(next.text.contains("From the user (in order, the last one is the latest):\nMake it blue\n\nAnd bigger"))
        XCTAssertEqual(next.messages.map(\.id), ["m2", "m3"])
        XCTAssertFalse(q.isSteering("b"))
        XCTAssertNil(q.next(for: "b"))
    }

    func testSteeringBeforeTheSessionStartedResendsTheFirstMessage() {
        var q = TurnQueue()
        _ = q.submit(QueuedMessage(id: "m1", botId: "b", text: "First"), runningBotId: nil)
        let first = q.next(for: "b")!
        XCTAssertEqual(q.submit(QueuedMessage(id: "m2", botId: "b", text: "Second"), runningBotId: "b"), .steer)
        q.runEnded(first, stoppedForSteering: true, hadSession: false)
        let next = q.next(for: "b")!
        XCTAssertFalse(next.carriesOn, "nothing to carry on from")
        XCTAssertEqual(next.messages.map(\.id), ["m1", "m2"])
        XCTAssertTrue(next.text.contains("First\n\nSecond"))
    }

    func testNoSteeringInGroupsOrForHandOffs() {
        var q = TurnQueue()
        XCTAssertEqual(q.submit(QueuedMessage(botId: "b", text: "x"), runningBotId: "b", allowSteering: false), .queue)
        XCTAssertEqual(q.submit(QueuedMessage(botId: "b", fromBotId: "lead", fromName: "Lead", text: "do y"), runningBotId: "b"), .queue)
        XCTAssertEqual(q.submit(QueuedMessage(botId: "c", text: "z"), runningBotId: "b"), .queue, "another bot is busy")
        let turn = q.next(for: "b")!
        XCTAssertTrue(turn.text.hasPrefix(TurnQueue.batchNote))
        XCTAssertTrue(turn.text.contains("From Lead:\ndo y"))
        XCTAssertTrue(turn.text.hasSuffix("From the user:\nx"))
        XCTAssertEqual(q.waiting(for: "c").count, 1)
        q.clear()
        XCTAssertTrue(q.isEmpty)
    }

    func testSettlingAnInterruptedReply() {
        XCTAssertNil(TurnQueue.settleInterrupted(ChatMessage(role: .bot, botId: "b", status: .stopped)))
        let partial = ChatMessage(role: .bot, botId: "b", text: "Half way", steps: [Step(id: "s", tool: "Bash", title: "Ran", status: .running)],
                                  status: .stopped)
        let settled = TurnQueue.settleInterrupted(partial)!
        XCTAssertEqual(settled.status, .done)
        XCTAssertEqual(settled.steps.first?.status, .stopped)
    }

    // MARK: Threads

    private func makeStores() -> (ChatStore, ThreadStore) {
        let paths = LaunchpadPaths(root: tmp)
        let chats = ChatStore(paths: paths)
        return (chats, ThreadStore(paths: paths, chatStore: chats))
    }

    func testNewThreadArchivesAndReopenRestores() throws {
        let (chats, threads) = makeStores()
        var meta = ChatMeta(id: "c1", title: "Guide", kind: .bot, botId: "b", sessions: ["b": "sess-1"])
        try chats.save(meta)
        for m in sampleChat { try chats.append(m, chatId: "c1") }

        let (fresh, archived) = try threads.newThread(meta)
        XCTAssertEqual(fresh.sessions, [:])
        XCTAssertTrue(chats.messages(chatId: "c1").isEmpty)
        let past = try XCTUnwrap(archived)
        XCTAssertEqual(past.title, "Plan a trip to Rome")
        XCTAssertEqual(past.sessions, ["b": "sess-1"])
        XCTAssertEqual(past.messageCount, 5)
        XCTAssertEqual(threads.pastThreads("c1").map(\.id), [past.id])
        XCTAssertEqual(threads.messages("c1", thread: past.id).count, 5)
        XCTAssertEqual(chats.loadAll().map(\.id), ["c1"], "the threads folder isn't mistaken for a chat")

        // Talk a bit in the new thread, then reopen the old one.
        meta = fresh
        meta.sessions = ["b": "sess-2"]
        try chats.save(meta)
        try chats.append(ChatMessage(id: "n1", role: .user, text: "Something else"), chatId: "c1")
        let reopened = try XCTUnwrap(try threads.reopen(meta, thread: past.id))
        XCTAssertEqual(reopened.sessions, ["b": "sess-1"])
        XCTAssertEqual(chats.messages(chatId: "c1").map(\.id), ["1", "2", "3", "4", "5"])
        let others = threads.pastThreads("c1")
        XCTAssertEqual(others.count, 1)
        XCTAssertEqual(others[0].title, "Something else")
        XCTAssertEqual(others[0].sessions, ["b": "sess-2"])
        XCTAssertEqual(chats.loadAll().first?.sessions, ["b": "sess-1"])

        try threads.delete("c1", thread: others[0].id)
        XCTAssertTrue(threads.pastThreads("c1").isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: threads.log("c1", thread: others[0].id).path))
        threads.deleteAll("c1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: threads.folder("c1").path))
    }

    func testNewThreadOnAnEmptyChatKeepsNothing() throws {
        let (chats, threads) = makeStores()
        let meta = ChatMeta(id: "c2", title: "T", kind: .bot, botId: "b", sessions: ["b": "s"])
        try chats.save(meta)
        try chats.append(ChatMessage(role: .notice, text: "hello"), chatId: "c2")
        let (fresh, archived) = try threads.newThread(meta)
        XCTAssertNil(archived)
        XCTAssertEqual(fresh.sessions, [:])
        XCTAssertTrue(chats.messages(chatId: "c2").isEmpty)
        XCTAssertNil(try threads.reopen(fresh, thread: "nope"))
    }

    func testCompactKeepsMessagesAndClearsSessions() throws {
        let (chats, threads) = makeStores()
        let meta = ChatMeta(id: "c3", title: "T", kind: .bot, botId: "b", sessions: ["b": "s"])
        try chats.save(meta)
        for m in sampleChat { try chats.append(m, chatId: "c3") }
        try threads.setUnseenAfter("2", chatId: "c3", botId: "b")
        XCTAssertEqual(threads.unseenAfter("c3", botId: "b"), "2")
        let compacted = try threads.compact(meta)
        XCTAssertEqual(compacted.sessions, [:])
        XCTAssertEqual(chats.messages(chatId: "c3").count, 5)
        XCTAssertNil(threads.unseenAfter("c3", botId: "b"))
        // The next turn gets a recap because there's no session.
        let prompt = ConversationRecap.prompt(for: "next", history: chats.messages(chatId: "c3"),
                                              hasSession: compacted.sessions["b"] != nil)
        XCTAssertTrue(prompt.contains("Plan a trip to Rome"))
    }

    func testBranchMakesANewChatUpToTheMessage() throws {
        let (chats, threads) = makeStores()
        let meta = ChatMeta(id: "c4", title: "Guide", kind: .bot, botId: "b", sessions: ["b": "s"])
        try chats.save(meta)
        for m in sampleChat { try chats.append(m, chatId: "c4") }
        let branch = try XCTUnwrap(try threads.branch(meta, upTo: "2"))
        XCTAssertNotEqual(branch.id, "c4")
        XCTAssertEqual(branch.title, "Guide (branch)")
        XCTAssertEqual(branch.sessions, [:])
        XCTAssertEqual(branch.botId, "b")
        let copied = chats.messages(chatId: branch.id)
        XCTAssertEqual(copied.map(\.id).prefix(2), ["1", "2"])
        XCTAssertEqual(copied.last?.role, .notice)
        XCTAssertEqual(chats.messages(chatId: "c4").count, 5, "the original is unchanged")
        XCTAssertNil(try threads.branch(meta, upTo: "missing"))
        XCTAssertEqual(ThreadStore.branchTitle("Guide (branch)"), "Guide (branch)")
    }

    // MARK: Side questions & forks

    func testClaudeSideQuestionForksTheSession() {
        var bot = Bot(id: "b", name: "B", engine: .claude, model: "sonnet", permission: .fullAccess)
        bot.backup = nil
        let inv = SideQuestion.invocation(for: bot, question: "What's the plan?", botDirectory: tmp, sessionId: "main-1",
                                          history: sampleChat, newSessionId: { "fork-1" })
        let a = inv.arguments
        XCTAssertTrue(a.joined(separator: " ").contains("--resume main-1 --fork-session --session-id fork-1"))
        XCTAssertTrue(a.contains("--no-session-persistence"))
        XCTAssertTrue(a.contains("default"), "read-only permission mode")
        XCTAssertFalse(a.contains("--dangerously-skip-permissions"))
        XCTAssertEqual(inv.plannedSessionId, "fork-1")
        XCTAssertTrue(inv.stdin.hasPrefix(SideQuestion.preface))
        XCTAssertFalse(inv.stdin.contains("Plan a trip"), "the fork already knows the chat")
        XCTAssertFalse(a.contains("What's the plan?"), "the prompt stays on stdin")
    }

    func testCodexSideQuestionUsesExecFork() {
        let bot = Bot(id: "b", name: "B", engine: .codex, model: "gpt-5", permission: .fullAccess)
        let inv = SideQuestion.invocation(for: bot, question: "Status?", botDirectory: tmp, sessionId: "thread-9", history: sampleChat)
        XCTAssertEqual(Array(inv.arguments.prefix(5)), ["exec", "fork", "--json", "--skip-git-repo-check", "--ephemeral"])
        XCTAssertTrue(inv.arguments.contains("sandbox_mode=\"read-only\""))
        XCTAssertEqual(Array(inv.arguments.suffix(2)), ["thread-9", "-"])
        XCTAssertNil(inv.plannedSessionId, "the fork's id arrives in thread.started")
        XCTAssertEqual(inv.stdin, SideQuestion.preface + "\n\nStatus?")
    }

    func testSideQuestionWithoutASessionGetsARecap() {
        let bot = Bot(id: "b", name: "B", engine: .codex)
        let inv = SideQuestion.invocation(for: bot, question: "Status?", botDirectory: tmp, sessionId: nil, history: sampleChat,
                                          names: ["b": "Guide"])
        XCTAssertEqual(Array(inv.arguments.prefix(2)), ["exec", "--json"])
        XCTAssertTrue(inv.arguments.contains("--ephemeral"))
        XCTAssertTrue(inv.stdin.hasPrefix("Recent conversation:\nUser: Plan a trip to Rome\nGuide: Sure"))
        XCTAssertTrue(inv.stdin.hasSuffix("Status?"))

        let local = Bot(id: "b", name: "B", engine: .local, model: "llama3.2")
        let li = SideQuestion.invocation(for: local, question: "Status?", botDirectory: tmp, sessionId: "ignored", history: sampleChat)
        XCTAssertEqual(li.engine, .local)
        XCTAssertTrue(li.local!.messages.contains { $0.content == "Plan a trip to Rome" })
        XCTAssertTrue(li.local!.messages.last!.content.hasSuffix("Status?"))
    }

    func testPlainResumesAreUnchanged() {
        let claude = EngineCommand.claude(prompt: "p", botDirectory: tmp, model: nil, permission: .editWorkspace, sessionId: "s1")
        XCTAssertFalse(claude.arguments.contains("--fork-session"))
        XCTAssertEqual(claude.plannedSessionId, "s1")
        var o = RunOptions()
        o.ephemeral = true
        let codex = EngineCommand.codex(prompt: "p", botDirectory: tmp, model: nil, permission: .editWorkspace, threadId: "t1", options: o)
        XCTAssertEqual(Array(codex.arguments.prefix(2)), ["exec", "resume"])
        XCTAssertFalse(codex.arguments.contains("--ephemeral"), "resume never runs ephemeral")
        XCTAssertEqual(codex.plannedSessionId, "t1")
    }
}
