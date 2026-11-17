import XCTest
@testable import LaunchpadCore

final class ChatToolsTests: XCTestCase {
    var paths: LaunchpadPaths!
    let fm = FileManager.default

    override func setUpWithError() throws {
        paths = LaunchpadPaths(root: fm.temporaryDirectory.appendingPathComponent("lp-chat-\(UUID().uuidString)"))
        try paths.ensureStructure()
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: paths.root)
    }

    func makeRun(planWait: Int = 0, group: Bool = false) -> ChatToolsRun {
        let bot = Bot(id: "planner", name: "Planner")
        let chat = group ? ChatMeta(id: "c1", title: "#team", kind: .group, groupId: "team")
                         : ChatMeta(id: "c1", title: "Planner", kind: .bot, botId: "planner")
        return ChatToolsRun(runId: "RUN-1", chat: chat, bot: bot, planWait: planWait, paths: paths)
    }

    func server(_ run: ChatToolsRun, now: @escaping () -> Date = Date.init, sleep: @escaping (TimeInterval) -> Void = { _ in }) -> ChatToolsServer {
        try? run.prepare()
        return ChatToolsServer(config: run.config, now: now, sleep: sleep)
    }

    func json(_ line: String?) throws -> [String: Any] {
        let data = try XCTUnwrap(line).data(using: .utf8)!
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Calls a tool through JSON-RPC and returns (text, isError).
    func call(_ s: ChatToolsServer, _ name: String, _ args: [String: Any], id: Int = 7) throws -> (String, Bool) {
        let req: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": name, "arguments": args]]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: req), as: UTF8.self)
        let resp = try json(s.handle(line: line))
        XCTAssertEqual(resp["id"] as? Int, id)
        let result = try XCTUnwrap(resp["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return (content.first?["text"] as? String ?? "", result["isError"] as? Bool ?? false)
    }

    func actions(_ run: ChatToolsRun) -> [ChatAction] { ChatActionReader(url: run.actionsFile).readNew() }

    // MARK: Handshake

    func testHandshakeListAndErrors() throws {
        let s = server(makeRun())
        let ini = try json(s.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"claude-code","version":"2"}}}"#))
        let result = try XCTUnwrap(ini["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-03-26")
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "launchpad-chat")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
        XCTAssertNil(s.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        XCTAssertNil(s.handle(line: "   "))

        let list = try json(s.handle(line: #"{"jsonrpc":"2.0","id":"two","method":"tools/list"}"#))
        XCTAssertEqual(list["id"] as? String, "two")
        let tools = try XCTUnwrap((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }.sorted(), ChatToolsServer.toolNames.sorted())
        XCTAssertFalse(tools.contains { ($0["name"] as? String) == "send_sticker" })
        for t in tools { XCTAssertNotNil(t["inputSchema"] as? [String: Any], "\(t["name"] ?? "")") }

        XCTAssertNotNil(try json(s.handle(line: #"{"jsonrpc":"2.0","id":3,"method":"ping"}"#))["result"])
        let unknown = try json(s.handle(line: #"{"jsonrpc":"2.0","id":4,"method":"resources/list"}"#))
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32601)
        let bad = try json(s.handle(line: "{nope"))
        XCTAssertEqual((bad["error"] as? [String: Any])?["code"] as? Int, -32700)
        let (text, isError) = try call(s, "send_sticker", ["name": "happy"])
        XCTAssertTrue(isError)
        XCTAssertTrue(text.contains("Unknown tool"))
    }

    func testServeLoop() {
        let s = server(makeRun())
        var input = [#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
                     #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                     #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#]
        var out: [String] = []
        s.serve(readLine: { input.isEmpty ? nil : input.removeFirst() }, write: { out.append($0) })
        XCTAssertEqual(out.count, 2)
        XCTAssertTrue(out[0].contains("\"protocolVersion\":\"2025-06-18\""))
    }

    // MARK: Chat actions

    func testReactGifPollVote() throws {
        let run = makeRun()
        let s = server(run)
        XCTAssertEqual(try call(s, "react", ["emoji": " 🎉🎉"]).1, false)
        XCTAssertTrue(try call(s, "react", ["emoji": ""]).1)
        XCTAssertEqual(try call(s, "send_gif", ["search": "high five"]).0, "Done, it's in the chat.")
        XCTAssertTrue(try call(s, "send_gif", [:]).1)
        XCTAssertFalse(try call(s, "start_poll", ["question": "Lunch?", "options": ["Pizza", " ", "Sushi"]]).1)
        XCTAssertTrue(try call(s, "start_poll", ["question": "Lunch?", "options": ["Pizza"]]).1)
        XCTAssertFalse(try call(s, "vote", ["option": "2", "reason": "Fresh fish"]).1)
        XCTAssertTrue(try call(s, "vote", ["option": 0]).1)

        let a = actions(run)
        XCTAssertEqual(a.map(\.tool), [.react, .sendGif, .startPoll, .vote])
        XCTAssertEqual(a[0].emoji, "🎉")
        XCTAssertEqual(a[1].search, "high five")
        XCTAssertEqual(a[2].options, ["Pizza", "Sushi"])
        XCTAssertEqual(a[3].option, 2)
        XCTAssertEqual(a[3].reason, "Fresh fish")
    }

    func testNoActionsFileMeansError() throws {
        let s = ChatToolsServer(config: ChatToolsConfig())
        XCTAssertEqual(try call(s, "react", ["emoji": "👍"]).1, true)
        // A plan with nowhere to show it just starts.
        XCTAssertTrue(try call(s, "share_plan", ["message": "x", "steps": ["a"]]).0.hasPrefix("start"))
    }

    func testAskUser() throws {
        let run = makeRun()
        let s = server(run)
        let (text, err) = try call(s, "ask_user", ["questions": [
            ["question": "Which colour?", "options": ["Blue", "Green"], "multiple": true],
            ["question": "Size?", "options": ["S", "M", "L"]],
        ]])
        XCTAssertFalse(err)
        XCTAssertTrue(text.contains("tappable"))
        XCTAssertTrue(try call(s, "ask_user", ["questions": [["question": "One option?", "options": ["Only"]]]]).1)
        XCTAssertTrue(try call(s, "ask_user", [:]).1)
        let q = try XCTUnwrap(actions(run).first?.questions)
        XCTAssertEqual(q, [QuestionCard.Item(text: "Which colour?", options: ["Blue", "Green"], multi: true),
                           QuestionCard.Item(text: "Size?", options: ["S", "M", "L"])])
    }

    func testSharePlanWaitsForTheAnswer() throws {
        let run = makeRun()
        try run.prepare()
        // A stale answer from before is ignored.
        try run.answerPlan("cancel")
        var sleeps = 0
        let s = ChatToolsServer(config: run.config, sleep: { _ in
            sleeps += 1
            if sleeps == 3 { try? run.answerPlan("start\n") }
        })
        let (text, _) = try call(s, "share_plan", ["message": "Building the site", "steps": ["Plan", "Build", "Test", "Ship", "Extra"]])
        XCTAssertTrue(text.hasPrefix("start:"))
        XCTAssertEqual(sleeps, 3)
        XCTAssertFalse(fm.fileExists(atPath: run.planAnswerFile.path), "the answer is used once")
        let plan = try XCTUnwrap(actions(run).first)
        XCTAssertEqual(plan.tool, .sharePlan)
        XCTAssertEqual(plan.message, "Building the site")
        XCTAssertEqual(plan.steps, ["Plan", "Build", "Test", "Ship"])
    }

    func testSharePlanAnswers() throws {
        for (answer, prefix) in [("cancel", "cancel:"), ("Only do the first step", "The user answered: Only do the first step")] {
            let run = makeRun()
            try run.prepare()
            let s = ChatToolsServer(config: run.config, sleep: { _ in try? run.answerPlan(answer) })
            XCTAssertTrue(try call(s, "share_plan", ["message": "m", "steps": ["a"]]).0.hasPrefix(prefix), answer)
        }
    }

    func testSharePlanCountdownAndTimeout() throws {
        // Countdown: nobody answers, so it starts after planWait + 2 s.
        var clock = Date(timeIntervalSince1970: 1_000)
        let run = makeRun(planWait: 10)
        try run.prepare()
        var s = ChatToolsServer(config: run.config, now: { clock }, sleep: { clock = clock.addingTimeInterval($0) })
        XCTAssertTrue(try call(s, "share_plan", ["message": "m", "steps": ["a"]]).0.hasPrefix("start:"))
        XCTAssertEqual(clock.timeIntervalSince1970, 1_012, accuracy: 0.3)

        // No countdown: after the timeout it doesn't start.
        clock = Date(timeIntervalSince1970: 1_000)
        let wait = makeRun(planWait: 0)
        s = ChatToolsServer(config: wait.config, now: { clock }, sleep: { clock = clock.addingTimeInterval($0) })
        XCTAssertTrue(try call(s, "share_plan", ["message": "m", "steps": ["a"]]).0.contains("hasn't pressed Start"))
        XCTAssertEqual(clock.timeIntervalSince1970, 1_000 + ChatToolsServer.planTimeout, accuracy: 0.3)
    }

    // MARK: Routines

    func testCreateAndListRoutines() throws {
        let run = makeRun()
        let s = server(run)
        XCTAssertEqual(try call(s, "list_routines", [:]).0, "No routines yet.")
        let (text, err) = try call(s, "create_routine", [
            "name": "Morning brief", "message": "Brief me on today",
            "trigger": ["type": "weekdays", "hour": 8, "minute": 30], "target": "bot:someone-else",
        ])
        XCTAssertFalse(err, text)
        XCTAssertTrue(text.contains("Morning brief"))
        let routine = try XCTUnwrap(actions(run).first?.routine)
        XCTAssertEqual(routine.target, "bot:planner", "the target is always this chat's bot")
        XCTAssertEqual(routine.ownChat, false)

        // Bad requests are explained, and nothing is recorded.
        let (why, bad) = try call(s, "create_routine", ["name": "x", "message": "y", "trigger": ["type": "daily", "hour": 25]])
        XCTAssertTrue(bad)
        XCTAssertTrue(why.contains("hour"))
        XCTAssertTrue(try call(s, "create_routine", ["name": "x", "prompt": "y"]).1)
        XCTAssertEqual(actions(run).count, 1, "only the good one was recorded")

        // The app saves it (RoutineRequests again), then list_routines shows it.
        let chat = ChatMeta(id: "c1", title: "Planner", kind: .bot, botId: "planner")
        let saved = ChatActionApplier.saveRoutine(routine, chat: chat, store: RoutineStore(paths: paths), bots: ["planner"], groups: [])
        let (r, notice) = try saved.get()
        XCTAssertEqual(r.chatId, "c1")
        XCTAssertEqual(r.target, .bot("planner"))
        XCTAssertFalse(r.runsInOwnChat)
        XCTAssertTrue(notice.hasPrefix("Routine saved: Morning brief · Weekdays at 08:30"))
        let list = try call(s, "list_routines", [:]).0
        XCTAssertTrue(list.contains("- Morning brief: Weekdays at 08:30 — Brief me on today"), list)
    }

    func testRoutineInGroupChatAndNoTarget() throws {
        let run = makeRun(group: true)
        XCTAssertEqual(run.routineTarget, "group:team")
        let s = server(run)
        XCTAssertFalse(try call(s, "create_routine", ["name": "Standup", "message": "Standup", "trigger": ["type": "hourly"]]).1)
        let none = ChatToolsServer(config: ChatToolsConfig(actionsFile: run.actionsFile.path))
        XCTAssertTrue(try call(none, "create_routine", ["name": "a", "message": "b", "trigger": ["type": "hourly"]]).1)
    }

    // MARK: App claims

    func testAppClaims() throws {
        var clock = Date(timeIntervalSince1970: 10_000)
        let a = ChatToolsServer(config: ChatToolsConfig(claimsFile: paths.appClaimsFile.path, botName: "Planner", botId: "planner"), now: { clock })
        let b = ChatToolsServer(config: ChatToolsConfig(claimsFile: paths.appClaimsFile.path, botName: "Designer", botId: "designer"), now: { clock })
        XCTAssertTrue(try call(a, "use_app", ["app": "Figma", "purpose": "editing the logo"]).0.hasPrefix("ok"))
        XCTAssertTrue(try call(a, "use_app", ["app": "figma"]).0.hasPrefix("ok"), "claiming again is fine")
        let busy = try call(b, "use_app", ["app": "FIGMA"]).0
        XCTAssertTrue(busy.hasPrefix("Planner is using FIGMA"), busy)
        XCTAssertTrue(try call(b, "use_app", ["app": "Safari"]).0.hasPrefix("ok"))
        XCTAssertTrue(try call(b, "use_app", [:]).1)
        XCTAssertEqual(try call(a, "done_with_app", ["app": "Figma"]).0, "ok")
        XCTAssertTrue(try call(b, "use_app", ["app": "Figma"]).0.hasPrefix("ok"))
        // Claims expire after 15 minutes.
        clock = clock.addingTimeInterval(ChatToolsServer.claimLifetime + 1)
        XCTAssertTrue(try call(a, "use_app", ["app": "Figma"]).0.hasPrefix("ok"))
        // done_with_app with no app lets go of all of yours.
        _ = try call(a, "use_app", ["app": "Notes"])
        _ = try call(a, "done_with_app", [:])
        let list = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: paths.appClaimsFile)) as? [[String: Any]])
        XCTAssertFalse(list.contains { $0["botId"] as? String == "planner" })
    }

    // MARK: Config and setup

    func testConfigFlagsAndEnvironment() {
        let env = ["LP_ACTIONS_FILE": "/env/a.jsonl", "LP_PLAN_WAIT": "30", "LP_BOT_NAME": "Env Bot"]
        let c = ChatToolsConfig.from(arguments: ["--actions", "/flag/a.jsonl", "--bot-id", "x", "--stray"], environment: env)
        XCTAssertEqual(c.actionsFile, "/flag/a.jsonl")
        XCTAssertEqual(c.planWait, 30)
        XCTAssertEqual(c.botName, "Env Bot")
        XCTAssertEqual(c.botId, "x")
        let run = makeRun(planWait: 10)
        XCTAssertEqual(ChatToolsConfig.from(arguments: run.config.arguments, environment: [:]), run.config)
    }

    func testRunFilesAndConnector() throws {
        let run = makeRun()
        XCTAssertTrue(run.actionsFile.path.hasSuffix(".launchpad/requests/chat/run-1.actions.jsonl"))
        XCTAssertTrue(run.planAnswerFile.path.hasSuffix(".launchpad/answers/chat/run-1.plan"))
        let exe = URL(fileURLWithPath: "/Applications/Launchpad.app/Contents/MacOS/launchpad-chat")
        let c = run.connector(executable: exe)
        XCTAssertEqual(c.serverKey, ChatToolsSetup.serverKey)
        let claude = MCPConfig.claudeJSON([c])
        XCTAssertTrue(claude.contains("\"launchpad_chat\":{\"args\":[\"--actions\""), claude)
        XCTAssertTrue(claude.contains(exe.path))
        let codex = MCPConfig.codexArgs([c])
        XCTAssertTrue(codex.contains("mcp_servers.launchpad_chat.command=\"\(exe.path)\""))

        // In a run alongside the bot's connectors, with the chat tools allowed for Claude.
        var o = RunOptions()
        o.manageConnectors = true
        o.connectors = [Connector(id: "notion", name: "Notion", kind: .http, url: "https://mcp.notion.com/mcp"), c]
        let bot = Bot(id: "planner", name: "Planner", permission: .editWorkspace)
        let inv = ChatToolsSetup.allowingChatTools(EngineCommand.invocation(for: bot, prompt: "hi", botDirectory: paths.botDir("planner"), sessionId: nil, options: o))
        let i = try XCTUnwrap(inv.arguments.firstIndex(of: "--allowedTools"))
        XCTAssertEqual(inv.arguments[i + 1], "mcp__notion,mcp__launchpad_chat", "the bot's apps and the chat tools are pre-approved")
        let mcp = inv.arguments[try XCTUnwrap(inv.arguments.firstIndex(of: "--mcp-config")) + 1]
        XCTAssertTrue(mcp.contains("launchpad_chat") && mcp.contains("notion"))

        // A read-only bot's list gets it added once.
        let ro = Bot(id: "r", name: "R", permission: .readOnly)
        let roInv = ChatToolsSetup.allowingChatTools(ChatToolsSetup.allowingChatTools(
            EngineCommand.invocation(for: ro, prompt: "hi", botDirectory: paths.botDir("r"), sessionId: nil, options: o)))
        XCTAssertEqual(roInv.arguments.filter { $0 == "--allowedTools" }.count, 1)
        XCTAssertTrue(roInv.arguments[roInv.arguments.firstIndex(of: "--allowedTools")! + 1].hasSuffix(",TodoWrite,mcp__notion,mcp__launchpad_chat"))
        // Codex is untouched.
        let cx = Bot(id: "c", name: "C", engine: .codex)
        let cxInv = EngineCommand.invocation(for: cx, prompt: "hi", botDirectory: paths.botDir("c"), sessionId: nil, options: o)
        XCTAssertEqual(ChatToolsSetup.allowingChatTools(cxInv), cxInv)

        try run.prepare()
        try run.answerPlan("start")
        try Data("x\n".utf8).write(to: run.actionsFile)
        run.cleanUp()
        XCTAssertFalse(fm.fileExists(atPath: run.actionsFile.path))
        XCTAssertFalse(fm.fileExists(atPath: run.planAnswerFile.path))
    }

    func testGuardsLetChatToolsThrough() {
        XCTAssertNil(RiskClassifier.classify(mcpTool: "mcp__launchpad_chat__send_gif"))
        XCTAssertEqual(RiskClassifier.classify(mcpTool: "mcp__slack__send_message"), .send)
        // The permission guard trusts the server when the app lists it (GuardHookSetup.config(trustedServers:)).
        var config = GuardConfig()
        XCTAssertFalse(GuardEngine.categories(tool: "mcp__launchpad_chat__send_gif", input: [:], cwd: "/", config: config).isEmpty)
        config.trustedServers = [ChatToolsSetup.serverKey]
        XCTAssertTrue(GuardEngine.categories(tool: "mcp__launchpad_chat__send_gif", input: [:], cwd: "/", config: config).isEmpty)
    }

    // MARK: Reader

    func testReaderTailsTheFile() throws {
        let url = paths.root.appendingPathComponent("a.jsonl")
        let reader = ChatActionReader(url: url)
        XCTAssertEqual(reader.readNew(), [], "no file yet")
        let one = String(decoding: try ChatAction.react("👍").line(), as: UTF8.self)
        let two = String(decoding: try ChatAction.gif("cats").line(), as: UTF8.self)
        try Data((one + "\nnot json\n" + two.prefix(10)).utf8).write(to: url)
        XCTAssertEqual(reader.readNew().map(\.tool), [.react])
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data((two.dropFirst(10) + "\n").utf8))
        try h.close()
        XCTAssertEqual(reader.readNew().map(\.search), ["cats"])
        XCTAssertEqual(reader.readNew(), [])
    }

    // MARK: The built binary

    func testBinaryWithScriptedStdin() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [".build/debug/launchpad-chat", ".build/release/launchpad-chat"].map { root.appendingPathComponent($0) }
        guard let exe = candidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) else {
            throw XCTSkip("launchpad-chat isn't built (swift build --product launchpad-chat)")
        }
        let run = makeRun()
        try run.prepare()
        let p = Process()
        p.executableURL = exe
        p.arguments = run.config.arguments
        p.environment = ["LP_BOT_NAME": "Ignored, the flag wins"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        try p.run()
        let script = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"react","arguments":{"emoji":"🚀"}}}"#,
        ]
        input.fileHandleForWriting.write(Data((script.joined(separator: "\n") + "\n").utf8))
        try input.fileHandleForWriting.close()
        let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        let lines = out.split(separator: "\n")
        XCTAssertEqual(lines.count, 3, out)
        XCTAssertTrue(lines[0].contains("launchpad-chat"))
        XCTAssertTrue(lines[1].contains("share_plan"))
        XCTAssertTrue(lines[2].contains("\"isError\":false"))
        XCTAssertEqual(actions(run).map(\.emoji), ["🚀"])
    }
}
