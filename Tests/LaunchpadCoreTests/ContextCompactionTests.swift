import XCTest
@testable import LaunchpadCore

final class ContextCompactionTests: XCTestCase {
    var root: URL!
    var paths: LaunchpadPaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lp-ctx-\(UUID().uuidString)", isDirectory: true)
        paths = LaunchpadPaths(root: root)
        try paths.ensureStructure()
    }

    override func tearDown() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.guardRules.path)
        try? FileManager.default.removeItem(at: root)
    }

    /// A chat of `count` messages alternating you and a bot, ids m1, m2…
    private func chat(_ count: Int, textLength: Int = 40) -> [ChatMessage] {
        (1...count).map { i in
            ChatMessage(id: "m\(i)", role: i % 2 == 1 ? .user : .bot, botId: i % 2 == 1 ? nil : "scout",
                        text: "Message \(i): " + String(repeating: "x", count: textLength))
        }
    }

    // MARK: Settings

    func testDefaults() {
        let s = ContextSettings()
        XCTAssertTrue(s.autoCompact)
        XCTAssertEqual(s.threshold, 0.75)
        XCTAssertEqual(s.percent, 75)
        XCTAssertEqual(s.keepRecentMessages, 8)
        XCTAssertEqual(ContextSettingsStore(paths: paths).load(), s, "no file means the defaults")
    }

    func testSettingsAreClampedAndReadLeniently() throws {
        XCTAssertEqual(ContextSettings(threshold: 5).threshold, 0.95)
        XCTAssertEqual(ContextSettings(threshold: 0.01).threshold, 0.30)
        XCTAssertEqual(ContextSettings(threshold: .nan).threshold, 0.75)
        XCTAssertEqual(ContextSettings(keepRecentMessages: 0).keepRecentMessages, 2)
        let store = ContextSettingsStore(paths: paths)
        try FileManager.default.createDirectory(at: paths.launchpadData, withIntermediateDirectories: true)
        try Data(#"{"threshold":"lots","autoCompact":false,"keepRecentMessages":500}"#.utf8).write(to: store.file)
        let loaded = store.load()
        XCTAssertFalse(loaded.autoCompact)
        XCTAssertEqual(loaded.threshold, 0.75, "an unreadable value falls back")
        XCTAssertEqual(loaded.keepRecentMessages, 40, "an out-of-range one is clamped")
        try Data("{ nope".utf8).write(to: store.file)
        XCTAssertEqual(store.load(), ContextSettings())
        try store.save(ContextSettings(autoCompact: true, threshold: 0.6, keepRecentMessages: 5))
        XCTAssertEqual(store.load().percent, 60)
        XCTAssertTrue(store.file.path.hasPrefix(paths.launchpadData.path + "/"))
    }

    func testABotCannotChangeTheSetting() throws {
        let config = GuardRulesFile.config(for: Bot(id: "scout", name: "Scout"), paths: paths)
        let rules = try GuardRulesFile.write(config, botId: "scout", paths: paths).path
        let file = ContextSettingsStore(paths: paths).file
        let call: [String: Any] = ["session_id": "s", "tool_name": "Write", "tool_input": ["file_path": file.path], "cwd": paths.botDir("scout").path]
        let result = GuardHook.run(input: try JSONSerialization.data(withJSONObject: call), rulesPath: rules, askBase: nil, grants: nil)
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertEqual(result.stderr, GuardEngine.protectedReason)
    }

    // MARK: What each engine is told

    func testClaudeIsToldWhereToCompact() {
        XCTAssertEqual(EngineCompaction.environment([:], engine: .claude, settings: ContextSettings())["CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"], "75")
        XCTAssertEqual(EngineCompaction.environment([:], engine: .claude, settings: ContextSettings(threshold: 0.6))["CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"], "60")
        XCTAssertEqual(EngineCompaction.environment(["CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "50", "X": "1"], engine: .claude, settings: ContextSettings())["CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"],
                       "50", "a value set by hand wins")
        XCTAssertNil(EngineCompaction.environment([:], engine: .claude, settings: ContextSettings(autoCompact: false))["CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"], "off means off")
        XCTAssertNil(EngineCompaction.environment([:], engine: .claude, settings: nil)["CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"])
        XCTAssertEqual(EngineCompaction.environment(["A": "b"], engine: .codex, settings: ContextSettings()), ["A": "b"])
    }

    func testCodexIsToldInTokens() {
        XCTAssertEqual(EngineCompaction.codexTokenLimit(settings: ContextSettings(), window: nil), 204_000, "75% of its typical 272K")
        XCTAssertEqual(EngineCompaction.codexTokenLimit(settings: ContextSettings(), window: 400_000), 300_000)
        XCTAssertEqual(EngineCompaction.codexArguments(settings: ContextSettings(), window: 200_000), ["-c", "model_auto_compact_token_limit=150000"])
        XCTAssertEqual(EngineCompaction.codexArguments(settings: ContextSettings(autoCompact: false), window: 200_000), [])
        XCTAssertEqual(EngineCompaction.codexArguments(settings: nil, window: nil), [])
    }

    func testTheRunsCarryIt() throws {
        var options = RunOptions()
        options.autoCompact = ContextSettings()
        options.contextWindow = 200_000
        let dir = root
        let claude = EngineCommand.invocation(for: Bot(id: "b", name: "B", engine: .claude), prompt: "hi", botDirectory: dir!, sessionId: nil, options: options)
        XCTAssertEqual(claude.environment["CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"], "75")
        let codex = EngineCommand.invocation(for: Bot(id: "b", name: "B", engine: .codex), prompt: "hi", botDirectory: dir!, sessionId: nil, options: options)
        let args = codex.arguments
        let i = try XCTUnwrap(args.firstIndex(of: "model_auto_compact_token_limit=150000"))
        XCTAssertEqual(args[i - 1], "-c")
        let plain = EngineCommand.invocation(for: Bot(id: "b", name: "B", engine: .claude), prompt: "hi", botDirectory: dir!, sessionId: nil)
        XCTAssertNil(plain.environment["CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"], "without the option the engine keeps its own default")
        XCTAssertEqual(EngineCompaction.mechanism(for: .claude), .engineSetting)
        XCTAssertEqual(EngineCompaction.mechanism(for: .local), .appHistory)
    }

    // MARK: Seeing it happen

    func testClaudeCompactionsAreReported() {
        let parser = ClaudeStreamParser()
        let line = #"{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"auto","pre_tokens":750000,"post_tokens":18000}}"#
        XCTAssertEqual(parser.parse(line: line), [.compacted(ContextCompaction(engine: .claude, trigger: .auto, tokensBefore: 750_000, tokensAfter: 18_000))])
        let camel = #"{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"manual","preTokens":100}}"#
        XCTAssertEqual(parser.parse(line: camel), [.compacted(ContextCompaction(engine: .claude, trigger: .manual, tokensBefore: 100, tokensAfter: nil))])
        XCTAssertEqual(parser.parse(line: #"{"type":"system","subtype":"compact_boundary"}"#),
                       [.compacted(ContextCompaction(engine: .claude, trigger: .auto))], "even with no details")
    }

    func testTheSizeAfterACompactionIsReportedEvenIfItMatchesTheOne() {
        let parser = ClaudeStreamParser()
        let call = #"{"type":"assistant","message":{"id":"a","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":1000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#
        XCTAssertTrue(parser.parse(line: call).contains(.context(ContextUsage(engine: .claude, used: 1_000))))
        XCTAssertFalse(parser.parse(line: call.replacingOccurrences(of: "\"id\":\"a\"", with: "\"id\":\"b\"")).contains { if case .context = $0 { return true } else { return false } },
                       "the same size twice isn't reported twice")
        _ = parser.parse(line: #"{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"auto","pre_tokens":900000}}"#)
        XCTAssertTrue(parser.parse(line: call.replacingOccurrences(of: "\"id\":\"a\"", with: "\"id\":\"c\"")).contains(.context(ContextUsage(engine: .claude, used: 1_000))),
                      "after a compaction the next size is reported, whatever it was before")
    }

    func testTheMessageKeepsTheCompactionForANotice() {
        var builder = MessageBuilder(botId: "scout")
        builder.apply(.context(ContextUsage(engine: .claude, used: 190_000, window: 200_000)))
        builder.apply(.compacted(ContextCompaction(engine: .claude, trigger: .auto, tokensBefore: 190_000, tokensAfter: 12_000)))
        XCTAssertEqual(builder.compactions.count, 1)
        XCTAssertEqual(builder.context?.used, 12_000)
        XCTAssertEqual(builder.context?.window, 200_000)
        let notice = builder.compactions[0].notice(botName: "Scout")
        XCTAssertTrue(notice.contains("compacted Scout's memory automatically"))
        XCTAssertTrue(notice.contains("190.0K") && notice.contains("12.0K"))
        XCTAssertTrue(notice.contains("whole chat is still here"))
    }

    // MARK: Splitting a chat

    func testAShortChatIsNotWorthSummarising() {
        XCTAssertNil(ChatCompaction.plan(messages: chat(10), previous: nil, keepRecent: 8))
        XCTAssertNil(ChatCompaction.plan(messages: [], previous: nil, keepRecent: 8))
    }

    func testThePlanKeepsTheLatestAndSummarisesTheRest() throws {
        let plan = try XCTUnwrap(ChatCompaction.plan(messages: chat(30), previous: nil, keepRecent: 8))
        XCTAssertEqual(plan.older.count, 22)
        XCTAssertEqual(plan.recent.map(\.id), (23...30).map { "m\($0)" })
        XCTAssertEqual(plan.throughMessageId, "m22")
    }

    func testNoticesAndHalfWrittenRepliesAreNotCounted() throws {
        var messages = chat(30)
        messages.insert(ChatMessage(id: "n1", role: .notice, text: "Compacted before"), at: 5)
        messages.insert(ChatMessage(id: "s1", role: .bot, botId: "scout", text: "half…", status: .streaming), at: 6)
        let plan = try XCTUnwrap(ChatCompaction.plan(messages: messages, previous: nil, keepRecent: 8))
        XCTAssertEqual(plan.older.count, 22)
        XCTAssertFalse(plan.older.contains { $0.id == "n1" || $0.id == "s1" })
    }

    func testASecondCompactionOnlyLooksAtWhatCameAfterTheFirst() throws {
        let first = CompactionRecord(chatId: "c", trigger: .auto, throughMessageId: "m22", summarizedCount: 22, summary: "Earlier summary.")
        XCTAssertNil(ChatCompaction.plan(messages: chat(30), previous: first, keepRecent: 8), "only 8 are newer: nothing to summarise")
        let plan = try XCTUnwrap(ChatCompaction.plan(messages: chat(50), previous: first, keepRecent: 8))
        XCTAssertEqual(plan.older.first?.id, "m23")
        XCTAssertEqual(plan.older.count, 20)
        XCTAssertEqual(plan.previous?.summary, "Earlier summary.")
        XCTAssertTrue(ChatCompaction.prompt(for: plan).contains("The summary so far"))
        XCTAssertTrue(ChatCompaction.prompt(for: plan).contains("Earlier summary."))
    }

    // MARK: The summary

    func testThePromptAsksForAUsefulSummaryWithoutSecrets() throws {
        let plan = try XCTUnwrap(ChatCompaction.plan(messages: chat(30), previous: nil, keepRecent: 8))
        let prompt = ChatCompaction.prompt(for: plan, names: ["scout": "Scout"])
        XCTAssertTrue(prompt.contains("Never include passwords, keys, tokens"))
        XCTAssertTrue(prompt.contains("User: Message 1:"))
        XCTAssertTrue(prompt.contains("Scout: Message 2:"))
        XCTAssertFalse(prompt.contains("Message 25"), "the recent messages stay out: they're kept word for word")
        XCTAssertFalse(prompt.contains("The summary so far"))
    }

    func testAHugeChatIsFittedAndTheOmissionIsCounted() throws {
        let big = chat(900, textLength: 2_400)
        let plan = try XCTUnwrap(ChatCompaction.plan(messages: big, previous: nil, keepRecent: 8))
        let (lines, omitted) = ChatCompaction.transcript(for: plan)
        XCTAssertGreaterThan(omitted, 0)
        XCTAssertEqual(lines.count + omitted, plan.older.count)
        XCTAssertLessThanOrEqual(lines.reduce(0) { $0 + $1.count + 1 }, ChatCompaction.maxTranscriptCharacters)
        XCTAssertTrue(lines.last?.contains("Message 892") ?? false, "the newest of the older stretch are the ones kept")
        let record = try ChatCompaction.record(fromSummary: "- The team decided to ship the update on Friday.", plan: plan, chatId: "c", trigger: .auto)
        XCTAssertEqual(record.omittedCount, omitted)
        XCTAssertTrue(ChatCompaction.notice(record).contains("were too long to include in the summary"), "never silent about what the summary may miss")
    }

    func testTheSummaryIsCleanedBeforeItIsKept() throws {
        let plan = try XCTUnwrap(ChatCompaction.plan(messages: chat(30), previous: nil, keepRecent: 8))
        let raw = "```markdown\n- Goal: ship the update.\n- The key is sk-ant-abcdefghijklmnop12345678 and password: hunter2\u{200B}\n- Tags: \u{E0041}\u{E0042}done\n```"
        let record = try ChatCompaction.record(fromSummary: raw, plan: plan, chatId: "c", trigger: .manual, fractionBefore: 0.8, engine: .claude)
        XCTAssertFalse(record.summary.contains("sk-ant"))
        XCTAssertFalse(record.summary.contains("hunter2"))
        XCTAssertTrue(record.summary.contains("[redacted]"))
        XCTAssertTrue(record.summary.unicodeScalars.allSatisfy { !TicketPrompt.isHidden($0.value) }, "nothing hidden gets into a later prompt")
        XCTAssertFalse(record.summary.contains("```"))
        XCTAssertTrue(record.summary.contains("Goal: ship the update."))
        XCTAssertEqual(record.throughMessageId, "m22")
        XCTAssertEqual(record.summarizedCount, 22)
        XCTAssertEqual(record.trigger, .manual)
    }

    func testAnEmptyOrTooLongSummary() throws {
        let plan = try XCTUnwrap(ChatCompaction.plan(messages: chat(30), previous: nil, keepRecent: 8))
        for empty in ["", "   \n", "ok", "```\n```"] {
            XCTAssertThrowsError(try ChatCompaction.record(fromSummary: empty, plan: plan, chatId: "c", trigger: .auto)) {
                XCTAssertEqual($0 as? CompactionError, .emptySummary)
            }
        }
        let long = (1...2_000).map { "- point number \($0)" }.joined(separator: "\n")
        let record = try ChatCompaction.record(fromSummary: long, plan: plan, chatId: "c", trigger: .auto)
        XCTAssertLessThanOrEqual(record.summary.count, ChatCompaction.maxSummaryCharacters + 40)
        XCTAssertTrue(record.summary.hasSuffix("(summary cut to fit)"))
    }

    // MARK: Records

    func testRecordsAreKeptWhereBotsCantWriteAndAreNotChats() throws {
        let store = ChatStore(paths: paths)
        let meta = ChatMeta(id: "chat-1", title: "Build", kind: .bot, botId: "scout")
        try store.save(meta)
        let log = CompactionLog(paths: paths)
        let record = CompactionRecord(chatId: "chat-1", trigger: .auto, throughMessageId: "m22", summarizedCount: 22, summary: "Summary text here.")
        try log.append(record)
        try log.saveReading(ContextUsage(engine: .claude, used: 150_000, window: 200_000), chatId: "chat-1", botId: "scout")
        XCTAssertTrue(log.folder.path.hasPrefix(paths.launchpadData.path + "/"))
        XCTAssertEqual(store.loadAll().map(\.id), ["chat-1"], "records don't show up as phantom chats")
        XCTAssertEqual(log.latest("chat-1")?.summary, "Summary text here.")
        XCTAssertEqual(log.readings("chat-1")["scout"]?.used, 150_000, "readings survive a restart")
        try log.append(CompactionRecord(chatId: "chat-1", trigger: .manual, throughMessageId: "m40", summarizedCount: 18, summary: "Second."))
        XCTAssertEqual(log.records("chat-1").map(\.summary), ["Summary text here.", "Second."], "every compaction is kept")
        XCTAssertEqual(log.latest("chat-1")?.throughMessageId, "m40")
    }

    func testWhatASummaryCoversIsMarked() throws {
        let log = CompactionLog(paths: paths)
        XCTAssertEqual(log.summarizedIds("c", in: chat(30)), [])
        try log.append(CompactionRecord(chatId: "c", trigger: .auto, throughMessageId: "m22", summarizedCount: 22, summary: "Summary text here."))
        let ids = log.summarizedIds("c", in: chat(30))
        XCTAssertEqual(ids, Set((1...22).map { "m\($0)" }))
        XCTAssertEqual(log.summarizedIds("c", in: Array(chat(30).suffix(5))), [], "a record whose message isn't in the chat marks nothing")
    }

    // MARK: When it may run

    private func usage(_ engine: BotEngine, _ fraction: Double) -> ContextUsage {
        ContextUsage(engine: engine, used: Int(fraction * 100_000), window: 100_000)
    }

    func testNeverWhileABotIsReplying() {
        let full = ["scout": usage(.claude, 0.99)]
        XCTAssertEqual(ContextAdvisor.decide(readings: full, settings: ContextSettings(), isRunning: true), .skipped(.running))
        XCTAssertEqual(ContextAdvisor.decide(readings: full, settings: ContextSettings(), isRunning: true, manual: true), .skipped(.running),
                       "not even when you press Compact")
        XCTAssertEqual(ContextAdvisor.decide(readings: ["a": usage(.local, 0.99)], settings: ContextSettings(), isRunning: true), .skipped(.running))
    }

    func testDecisions() {
        let s = ContextSettings()
        XCTAssertEqual(ContextAdvisor.decide(readings: [:], settings: s, isRunning: false), .nothing)
        XCTAssertEqual(ContextAdvisor.decide(readings: ["a": usage(.claude, 0.5)], settings: s, isRunning: false), .nothing)
        XCTAssertEqual(ContextAdvisor.decide(readings: ["a": usage(.claude, 0.80)], settings: s, isRunning: false), .skipped(.engineHandles),
                       "past the threshold, but Claude compacts itself")
        XCTAssertEqual(ContextAdvisor.decide(readings: ["a": usage(.claude, 0.90)], settings: s, isRunning: false), .compact(botIds: ["a"]),
                       "10 points past it and still full: the engine didn't, so the app steps in")
        XCTAssertEqual(ContextAdvisor.decide(readings: ["a": usage(.codex, 0.90)], settings: s, isRunning: false), .compact(botIds: ["a"]))
        XCTAssertEqual(ContextAdvisor.decide(readings: ["a": usage(.local, 0.76)], settings: s, isRunning: false), .compact(botIds: ["a"]),
                       "a local model has no compaction of its own: the app does it at the threshold")
        XCTAssertEqual(ContextAdvisor.decide(readings: ["a": usage(.local, 0.60)], settings: s, isRunning: false), .nothing)
    }

    func testOnlyTheBotsThatAreTooFullAreCompactedInAGroup() {
        let readings = ["lead": usage(.claude, 0.95), "tester": usage(.claude, 0.30), "planner": usage(.claude, 0.97)]
        XCTAssertEqual(ContextAdvisor.decide(readings: readings, settings: ContextSettings(), isRunning: false), .compact(botIds: ["lead", "planner"]))
    }

    func testWhenAutoIsOffItOnlySuggests() {
        let off = ContextSettings(autoCompact: false)
        XCTAssertEqual(ContextAdvisor.decide(readings: ["a": usage(.claude, 0.99)], settings: off, isRunning: false), .suggest(0.99))
        XCTAssertEqual(ContextAdvisor.decide(readings: ["a": usage(.claude, 0.5)], settings: off, isRunning: false), .nothing)
        XCTAssertEqual(ContextAdvisor.decide(readings: ["a": usage(.claude, 0.5)], settings: off, isRunning: false, manual: true), .compact(botIds: ["a"]),
                       "the button still works")
    }

    func testAHigherThresholdIsRespected() {
        let s = ContextSettings(threshold: 0.9)
        XCTAssertEqual(ContextAdvisor.decide(readings: ["a": usage(.claude, 0.95)], settings: s, isRunning: false), .skipped(.engineHandles))
        XCTAssertEqual(ContextAdvisor.decide(readings: ["a": usage(.claude, 0.985)], settings: s, isRunning: false), .compact(botIds: ["a"]), "capped at 97%")
    }

    // MARK: Putting it in place

    func testApplyingKeepsEverythingAndRestartsOnlyTheFullBots() throws {
        let store = ChatStore(paths: paths)
        var meta = ChatMeta(id: "chat-1", title: "#build", kind: .group, groupId: "g")
        meta.sessions = ["lead": "s-lead", "tester": "s-tester", "planner": "s-planner"]
        try store.save(meta)
        for m in chat(30) { try store.append(m, chatId: "chat-1") }
        let log = CompactionLog(paths: paths)
        try log.saveReading(usage(.claude, 0.95), chatId: "chat-1", botId: "lead")
        try log.saveReading(usage(.claude, 0.30), chatId: "chat-1", botId: "tester")
        let record = CompactionRecord(chatId: "chat-1", trigger: .auto, throughMessageId: "m22", summarizedCount: 22, summary: "Summary text here.", fractionBefore: 0.95)

        let outcome = try ChatCompactor(paths: paths, chatStore: store).apply(record, to: meta, clearing: ["lead"], isRunning: { false })
        guard case .applied(let updated, let notice) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(updated.sessions, ["tester": "s-tester", "planner": "s-planner"], "only the full bot starts fresh")
        XCTAssertEqual(store.loadAll().first?.sessions, updated.sessions, "and it's saved")
        XCTAssertTrue(notice.contains("Compacted automatically at 95% full"))
        XCTAssertTrue(notice.contains("22 earlier messages"))
        XCTAssertEqual(store.messages(chatId: "chat-1").count, 30, "nothing is deleted from the chat")
        XCTAssertEqual(store.messages(chatId: "chat-1").map(\.text), chat(30).map(\.text), "word for word")
        XCTAssertEqual(log.records("chat-1").count, 1)
        XCTAssertNil(log.readings("chat-1")["lead"], "its old reading no longer applies")
        XCTAssertNotNil(log.readings("chat-1")["tester"])
    }

    func testTheCompactButtonRestartsEveryBot() throws {
        let store = ChatStore(paths: paths)
        var meta = ChatMeta(id: "chat-2", title: "Scout", kind: .bot, botId: "scout")
        meta.sessions = ["scout": "s1"]
        try store.save(meta)
        let record = CompactionRecord(chatId: "chat-2", trigger: .manual, throughMessageId: "m22", summarizedCount: 22, summary: "Summary text here.")
        guard case .applied(let updated, let notice) = try ChatCompactor(paths: paths, chatStore: store).apply(record, to: meta, isRunning: { false }) else { return XCTFail() }
        XCTAssertEqual(updated.sessions, [:])
        XCTAssertTrue(notice.hasPrefix("Compacted:"), "not marked as automatic")
    }

    func testNothingIsChangedIfABotIsReplying() throws {
        let store = ChatStore(paths: paths)
        var meta = ChatMeta(id: "chat-3", title: "Scout", kind: .bot, botId: "scout")
        meta.sessions = ["scout": "s1"]
        try store.save(meta)
        let record = CompactionRecord(chatId: "chat-3", trigger: .auto, throughMessageId: "m22", summarizedCount: 22, summary: "Summary text here.")
        let outcome = try ChatCompactor(paths: paths, chatStore: store).apply(record, to: meta, isRunning: { true })
        XCTAssertEqual(outcome, .skipped(.running))
        XCTAssertEqual(store.loadAll().first?.sessions, ["scout": "s1"], "the session is untouched")
        XCTAssertEqual(CompactionLog(paths: paths).records("chat-3"), [], "and no record is written")
    }

    // MARK: Starting again from the summary

    func testABotThatStartsFreshGetsTheSummaryThenTheNewerMessages() {
        let history = chat(30)
        let record = CompactionRecord(chatId: "c", trigger: .auto, throughMessageId: "m22", summarizedCount: 22, summary: "- Ship on Friday.")
        let text = ConversationRecap.compactedPrompt("What's next?", history: history, record: record, names: ["scout": "Scout"])
        XCTAssertTrue(text.hasPrefix("Summary of the earlier conversation"))
        XCTAssertTrue(text.contains("- Ship on Friday."))
        XCTAssertTrue(text.contains("Message 23"))
        XCTAssertTrue(text.contains("Message 30"))
        XCTAssertFalse(text.contains("Message 22"), "what the summary covers isn't repeated")
        XCTAssertTrue(text.hasSuffix("New message: What's next?"))
    }

    func testTheOldRecapIsUnchangedWithoutASummary() {
        let history = chat(30)
        XCTAssertEqual(ConversationRecap.prompt(for: "Hi", history: history, hasSession: false),
                       ConversationRecap.prompt(for: "Hi", history: history, hasSession: false, summary: nil, summarizedThrough: nil))
        XCTAssertEqual(ConversationRecap.prompt(for: "Hi", history: history, hasSession: true, summary: "ignored while a session exists"), "Hi")
    }

    // MARK: A local model's history

    func testALocalModelGetsTheSummaryAndWhatFits() {
        let record = CompactionRecord(chatId: "c", trigger: .auto, throughMessageId: "m22", summarizedCount: 22, summary: "- Ship on Friday.")
        let history = LocalContext.history(messages: chat(40, textLength: 400), record: record, window: 4_096, threshold: 0.75)
        XCTAssertEqual(history.first?.id, "summary-\(record.id)")
        XCTAssertTrue(history.first?.text.contains("- Ship on Friday.") ?? false)
        XCTAssertEqual(history.last?.id, "m40", "the newest message is always kept")
        XCTAssertFalse(history.contains { $0.id == "m22" }, "what the summary covers is left out")
        XCTAssertLessThanOrEqual(TokenEstimate.tokens(history), Int(4_096 * 0.75))
        XCTAssertLessThan(history.count, 19, "and older ones are dropped to fit")
    }

    func testTheNewestMessageSurvivesEvenIfItAloneIsTooBig() {
        let history = LocalContext.history(messages: chat(3, textLength: 50_000), record: nil, window: 2_048, threshold: 0.75)
        XCTAssertEqual(history.map(\.id), ["m3"])
    }

    func testNoticesAndHalfWrittenRepliesNeverGoToALocalModel() {
        let messages = chat(4) + [ChatMessage(id: "n", role: .notice, text: "Compacted"), ChatMessage(id: "s", role: .bot, text: "half", status: .streaming)]
        XCTAssertEqual(LocalContext.history(messages: messages, record: nil, window: 100_000, threshold: 0.75).map(\.id), ["m1", "m2", "m3", "m4"])
    }

    func testTokenEstimate() {
        XCTAssertEqual(TokenEstimate.tokens(""), 1)
        XCTAssertEqual(TokenEstimate.tokens(String(repeating: "a", count: 400)), 100)
        XCTAssertGreaterThan(TokenEstimate.tokens(chat(10)), 0)
    }

    // MARK: What the app wires

    func testTheSummaryIsWrittenByTheChatsBotOrTheGroupsLeadFirst() {
        let scout = Bot(id: "scout", name: "Scout"), lead = Bot(id: "lead", name: "Lead"), other = Bot(id: "other", name: "Other")
        let local = Bot(id: "loc", name: "Local", engine: .local)
        let solo = ChatMeta(title: "x", kind: .bot, botId: "scout")
        XCTAssertEqual(ChatCompaction.summariser(for: solo, bots: [scout, lead], groups: [])?.id, "scout")
        XCTAssertNil(ChatCompaction.summariser(for: ChatMeta(title: "x", kind: .bot, botId: "gone"), bots: [scout], groups: []))
        let group = BotGroup(id: "g", name: "team", members: ["other", "lead"], lead: "lead")
        let chat = ChatMeta(title: "x", kind: .group, groupId: "g")
        XCTAssertEqual(ChatCompaction.summariser(for: chat, bots: [other, lead], groups: [group])?.id, "lead")
        let localLead = BotGroup(id: "g", name: "team", members: ["other"], lead: "loc")
        XCTAssertEqual(ChatCompaction.summariser(for: chat, bots: [local, other], groups: [localLead])?.id, "other",
                       "an agent member is preferred to a local lead")
        XCTAssertNil(ChatCompaction.summariser(for: chat, bots: [lead], groups: []))
    }

    func testACompactionOnlyAppliesWhileItsMessageIsStillInTheChat() {
        let record = CompactionRecord(chatId: "c", trigger: .auto, throughMessageId: "m4", summarizedCount: 4, summary: "A summary that is long enough.")
        XCTAssertEqual(ChatCompaction.applicable(record, to: chat(10))?.id, record.id)
        XCTAssertNil(ChatCompaction.applicable(record, to: chat(3)), "a fresh thread doesn't get an old summary")
        XCTAssertNil(ChatCompaction.applicable(nil, to: chat(10)))
    }

    func testAGroupBotRestartsWithTheSummaryInFront() {
        let text = ConversationRecap.summaryPreface("Decided: ship Friday.") + "New in the group chat:\n…"
        XCTAssertTrue(text.hasPrefix("Summary of the earlier conversation"))
        XCTAssertTrue(text.contains("Decided: ship Friday."))
        XCTAssertTrue(text.contains("\n\n---\nNew in the group chat"))
    }
}
