import XCTest
@testable import LaunchpadCore

/// The parts of the Mac features (computer use, Office, menu bar, notifications, back/forward) that aren't UI.
final class MacFeatureTests: XCTestCase {
    var paths: LaunchpadPaths!
    let fm = FileManager.default

    override func setUpWithError() throws {
        paths = LaunchpadPaths(root: fm.temporaryDirectory.appendingPathComponent("lp-mac-\(UUID().uuidString)"))
        try paths.ensureStructure()
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: paths.root)
    }

    // MARK: Computer use

    func testUseComputerDecodesAndRoundTrips() throws {
        let old = try JSONDecoder().decode(Bot.self, from: Data(#"{"id":"a","name":"A"}"#.utf8))
        XCTAssertFalse(old.useComputer, "older bot.json files load with it off")
        var bot = Bot(id: "b", name: "B")
        bot.useComputer = true
        let back = try JSONDecoder().decode(Bot.self, from: JSONEncoder().encode(bot))
        XCTAssertTrue(back.useComputer)
    }

    func testDriverLookup() throws {
        let home = paths.root.appendingPathComponent("home").path
        XCTAssertNil(ComputerUse.findDriver(home: home, pathDirectories: []))
        let bin = (home as NSString).appendingPathComponent(".local/bin")
        try fm.createDirectory(atPath: bin, withIntermediateDirectories: true)
        let exe = (bin as NSString).appendingPathComponent("cua-driver")
        fm.createFile(atPath: exe, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        XCTAssertEqual(ComputerUse.findDriver(home: home), exe)

        // Or anywhere on the PATH.
        let other = paths.root.appendingPathComponent("tools").path
        try fm.createDirectory(atPath: other, withIntermediateDirectories: true)
        let onPath = (other as NSString).appendingPathComponent("cua-driver")
        fm.createFile(atPath: onPath, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        try fm.removeItem(atPath: exe)
        XCTAssertEqual(ComputerUse.findDriver(home: home, pathDirectories: ["/nowhere", other]), onPath)
    }

    func testComputerConnectorAndSocket() throws {
        XCTAssertEqual(ComputerUse.socketPath(temporaryDirectory: "/tmp/x/"), "/tmp/x/launchpad-cua/driver.sock")
        XCTAssertEqual(ComputerUse.serveArguments(socket: "/s.sock"), ["serve", "--socket", "/s.sock"])
        let c = ComputerUse.connector(driver: "/Users/o'b/.local/bin/cua-driver", socket: "/tmp/launchpad-cua/driver.sock")
        XCTAssertEqual(c.id, "computer")
        XCTAssertEqual(c.serverKey, "computer")
        XCTAssertEqual(c.kind, .stdio)
        XCTAssertEqual(c.command, "/bin/sh")
        XCTAssertEqual(c.args.first, "-c")
        let script = try XCTUnwrap(c.args.last)
        XCTAssertTrue(script.hasSuffix("exec '/Users/o'\\''b/.local/bin/cua-driver' mcp --socket '/tmp/launchpad-cua/driver.sock'"), script)
        XCTAssertTrue(script.contains("[ -S '/tmp/launchpad-cua/driver.sock' ]"))
        // It goes into Claude's MCP config like any stdio server.
        XCTAssertTrue(MCPConfig.claudeJSON([c]).contains("\"computer\""))
    }

    func testEveryComputerCallIsAskedAbout() {
        let bot = Bot(id: "pablo", name: "Pablo")
        let cfg = GuardRulesFile.config(for: bot, paths: paths, trustedServers: [ChatToolsSetup.serverKey])
        for tool in ["mcp__computer__click", "mcp__computer__list_windows", "mcp__computer__get_window_state"] {
            guard case .ask(let category, _) = GuardEngine.decide(tool: tool, input: [:], cwd: paths.botDir("pablo").path, config: cfg) else {
                return XCTFail("\(tool) should ask")
            }
            XCTAssertEqual(category, .computer)
        }
        var never = bot
        never.rules.set(.never, for: .computer)
        let neverCfg = GuardRulesFile.config(for: never, paths: paths)
        guard case .deny = GuardEngine.decide(tool: "mcp__computer__click", input: [:], cwd: paths.botDir("pablo").path, config: neverCfg) else {
            return XCTFail("Never blocks it")
        }
    }

    func testAllowingComputerTools() {
        let bot = Bot(id: "p", name: "P", permission: .editWorkspace)
        let inv = EngineCommand.invocation(for: bot, prompt: "hi", botDirectory: paths.botDir("p"), sessionId: nil)
        let both = ComputerUse.allowingComputer(ChatToolsSetup.allowingChatTools(inv))
        let i = both.arguments.firstIndex(of: "--allowedTools")!
        XCTAssertEqual(both.arguments[i + 1], "mcp__launchpad_chat,mcp__computer")
        XCTAssertEqual(ComputerUse.allowingComputer(both), both, "added once")
        let codex = EngineCommand.invocation(for: Bot(id: "c", name: "C", engine: .codex), prompt: "hi",
                                             botDirectory: paths.botDir("c"), sessionId: nil)
        XCTAssertEqual(ComputerUse.allowingComputer(codex), codex)
    }

    func testComputerBlockers() {
        var bot = Bot(id: "p", name: "P")
        func check() -> ComputerUse.Blocker? {
            ComputerUse.blocker(for: bot, guardActive: true, driverInstalled: true, accessibility: true, screenRecording: true)
        }
        XCTAssertEqual(check(), .switchedOff)
        bot.useComputer = true
        XCTAssertNil(check())
        bot.engine = .codex
        XCTAssertEqual(check(), .notClaude)
        bot.engine = .claude
        bot.lockedDown = true
        XCTAssertEqual(check(), .lockedDown)
        bot.lockedDown = false
        bot.rules.set(.never, for: .computer)
        XCTAssertEqual(check(), .never)
        bot.rules.set(.allow, for: .computer)
        XCTAssertNil(check())
        XCTAssertEqual(ComputerUse.blocker(for: bot, guardActive: false, driverInstalled: true, accessibility: true, screenRecording: true), .noGuard)
        XCTAssertEqual(ComputerUse.blocker(for: bot, guardActive: true, driverInstalled: false, accessibility: false, screenRecording: false), .noDriver)
        XCTAssertEqual(ComputerUse.blocker(for: bot, guardActive: true, driverInstalled: true, accessibility: false, screenRecording: true), .noAccessibility)
        XCTAssertEqual(ComputerUse.blocker(for: bot, guardActive: true, driverInstalled: true, accessibility: true, screenRecording: false), .noScreenRecording)
        XCTAssertTrue(ComputerUse.unavailableNote(.noDriver).contains("Cua Driver isn't installed"))
        let text = ComputerUse.instructions(handle: "Pablo", others: ["Scout"])
        XCTAssertTrue(text.contains("use_app") && text.contains("\"Pablo\"") && text.contains("Scout"))
    }

    func testClaimsReadAndRelease() throws {
        var clock = Date(timeIntervalSince1970: 50_000)
        let a = ChatToolsServer(config: ChatToolsConfig(claimsFile: paths.appClaimsFile.path, botName: "Pablo", botId: "pablo"), now: { clock })
        let b = ChatToolsServer(config: ChatToolsConfig(claimsFile: paths.appClaimsFile.path, botName: "Scout", botId: "scout"), now: { clock })
        XCTAssertTrue(a.call("use_app", ["app": "Figma", "purpose": "logo"]).0.hasPrefix("ok"))
        XCTAssertTrue(b.call("use_app", ["app": "Safari"]).0.hasPrefix("ok"))
        let claims = AppClaims.read(file: paths.appClaimsFile, now: clock)
        XCTAssertEqual(Set(claims.map(\.app)), ["Figma", "Safari"])
        XCTAssertEqual(claims.first { $0.app == "Figma" }?.purpose, "logo")
        XCTAssertEqual(AppClaims.app(heldBy: "pablo", file: paths.appClaimsFile, now: clock), "Figma")

        AppClaims.release(botId: "pablo", file: paths.appClaimsFile)
        XCTAssertEqual(AppClaims.read(file: paths.appClaimsFile, now: clock).map(\.botId), ["scout"])
        // Stale claims don't count.
        clock = clock.addingTimeInterval(ChatToolsServer.claimLifetime + 1)
        XCTAssertTrue(AppClaims.read(file: paths.appClaimsFile, now: clock).isEmpty)
        // Releasing with no file is fine.
        AppClaims.release(botId: "x", file: paths.root.appendingPathComponent("none.json"))
    }

    // MARK: Office and attention

    func testWorkingMembersComeFirstInGroupOrder() {
        let members = ["lead", "planner", "frontend", "backend", "tester"]
        XCTAssertEqual(WorkSummary.workingFirst(members, working: ["tester", "planner"]),
                       ["planner", "tester", "lead", "frontend", "backend"])
        XCTAssertEqual(WorkSummary.workingFirst(members, working: []), members)
        XCTAssertEqual(WorkSummary.workingFirst(members, working: Set(members)), members)
        // A bot working elsewhere that isn't in the group doesn't appear.
        XCTAssertEqual(WorkSummary.workingFirst(["lead"], working: ["stranger"]), ["lead"])
    }

    func testElapsedSaysHowLongABotHasBeenGoing() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func after(_ seconds: TimeInterval) -> String {
            WorkSummary.elapsed(since: start, now: start.addingTimeInterval(seconds))
        }
        XCTAssertEqual(after(0), "Just started")
        XCTAssertEqual(after(59), "Just started")
        XCTAssertEqual(after(60), "1 min")
        XCTAssertEqual(after(59 * 60 + 59), "59 min")
        XCTAssertEqual(after(3600), "1 h")
        XCTAssertEqual(after(3900), "1 h 5 min")
        // A clock that moved backwards doesn't show a negative time.
        XCTAssertEqual(after(-120), "Just started")
    }

    func testAttention() {
        var m = ChatMessage(role: .bot, botId: "a", text: "Done")
        XCTAssertNil(Attention.reason(m))
        m.approval = ApprovalRequest(action: "deploy")
        XCTAssertEqual(Attention.reason(m), "Waiting for your OK")
        m.approval?.status = .approved
        m.questions = QuestionCard(items: [.init(text: "Which?", options: ["A", "B"])])
        XCTAssertEqual(Attention.reason(m), "Asked you a question")
        m.questions?.answered = true
        m.plan = PlanCard(message: "Fix it", steps: ["a"])
        XCTAssertEqual(Attention.reason(m), "Wants you to start a plan")
        m.plan?.state = .started
        m.liveApprovals = [LiveApproval(id: "x", category: "send", tool: "mcp__slack__post", detail: "", state: .pending)]
        XCTAssertEqual(Attention.reason(m), "Waiting for your OK")
        XCTAssertNil(Attention.reason(ChatMessage(role: .user, text: "?")))

        // Only the latest message counts; your reply answers it; notices are skipped.
        let asking = m
        XCTAssertEqual(Attention.waiting(in: [ChatMessage(role: .user, text: "go"), asking, ChatMessage(role: .notice, text: "n")])?.botId, "a")
        XCTAssertNil(Attention.waiting(in: [asking, ChatMessage(role: .user, text: "yes")]))
        XCTAssertNil(Attention.waiting(in: []))
    }

    func testDeskStateAndWorkLine() {
        XCTAssertEqual(DeskState.of(working: true, needsYou: true, queued: false), .needsYou)
        XCTAssertEqual(DeskState.of(working: true, needsYou: false, queued: true), .working)
        XCTAssertEqual(DeskState.of(working: false, needsYou: false, queued: true), .waiting)
        XCTAssertEqual(DeskState.of(working: false, needsYou: false, queued: false), .idle)
        XCTAssertEqual(DeskState.allCases.sorted { $0.order < $1.order }.first, .needsYou)

        XCTAssertEqual(WorkSummary.line(for: nil), "Starting…")
        var reply = ChatMessage(role: .bot, botId: "a", text: "", status: .streaming)
        XCTAssertEqual(WorkSummary.line(for: reply), "Thinking…")
        reply.text = "Hello"
        XCTAssertEqual(WorkSummary.line(for: reply), "Writing a reply…")
        XCTAssertEqual(WorkSummary.line(for: reply, todos: [TodoItem(id: "1", title: "Run tests", activeTitle: "Running tests", status: .inProgress)]),
                       "Running tests")
    }

    // MARK: Back and forward

    func testNavigationHistory() {
        var h = NavigationHistory<String>(limit: 3)
        XCTAssertFalse(h.canGoBack)
        h.visit(from: "a", to: "b")
        h.visit(from: "b", to: "b")
        h.visit(from: "b", to: "c")
        XCTAssertEqual(h.back, ["a", "b"])
        XCTAssertEqual(h.goBack(from: "c"), "b")
        XCTAssertEqual(h.forward, ["c"])
        XCTAssertEqual(h.goBack(from: "b"), "a")
        XCTAssertNil(h.goBack(from: "a"))
        XCTAssertEqual(h.goForward(from: "a"), "b")
        XCTAssertEqual(h.goForward(from: "b"), "c")
        XCTAssertNil(h.goForward(from: "c"))
        // A new visit clears forward; the limit drops the oldest.
        _ = h.goBack(from: "c")
        h.visit(from: "b", to: "d")
        XCTAssertFalse(h.canGoForward)
        h.visit(from: "d", to: "e")
        h.visit(from: "e", to: "f")
        XCTAssertEqual(h.back.count, 3)
        h.removeAll { $0 == "e" }
        XCTAssertFalse(h.back.contains("e"))
    }

    // MARK: Notifications

    func testReplyNotices() {
        var m = ChatMessage(role: .bot, botId: "a", text: "All **done**.\nShipped it.")
        let done = ReplyNotice.finished(m, botName: "Scout", chatTitle: "Scout", isGroup: false)
        XCTAssertEqual(done, ReplyNotice(title: "Scout replied", body: "All done. Shipped it.", needsYou: false))
        m.questions = QuestionCard(items: [.init(text: "Which?", options: ["A"])])
        let asks = ReplyNotice.finished(m, botName: "Scout", chatTitle: "#team", isGroup: true)
        XCTAssertEqual(asks?.title, "Scout needs you in #team")
        XCTAssertEqual(asks?.needsYou, true)
        XCTAssertNil(ReplyNotice.finished(ChatMessage(role: .bot, botId: "a", text: "", status: .stopped), botName: "S", chatTitle: "", isGroup: false))
        let failed = ReplyNotice.finished(ChatMessage(role: .bot, botId: "a", status: .failed, failure: RunFailure(kind: .unknown, message: "Out of credit")),
                                          botName: "S", chatTitle: "", isGroup: false)
        XCTAssertEqual(failed?.body, "Out of credit")
        let card = LiveApproval(id: "1", category: "computer", tool: "mcp__computer__click", detail: "")
        XCTAssertEqual(ReplyNotice.approval(card, botName: "Pablo").body, "Wants to use your Mac: Computer · click")
        let long = String(repeating: "x", count: 400)
        XCTAssertEqual(ReplyNotice.finished(ChatMessage(role: .bot, botId: "a", text: long), botName: "S", chatTitle: "", isGroup: false)?.body.count, 181)
    }
}
