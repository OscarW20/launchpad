import XCTest
@testable import LaunchpadCore

/// A scripted team: each bot replies with the next line from its script.
final class ScriptedTeam: @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [String: [String]]
    private(set) var calls: [(bot: String, kind: GroupTurnKind, prompt: String)] = []
    private(set) var active = 0
    private(set) var maxConcurrent = 0
    var delay: UInt64 = 0
    var approvalFrom: String?

    init(_ scripts: [String: [String]]) {
        self.scripts = scripts
    }

    func run(_ req: GroupTurnRequest) async -> ChatMessage {
        let text: String = lock.withLock {
            calls.append((req.bot.id, req.kind, req.prompt))
            active += 1
            maxConcurrent = max(maxConcurrent, active)
            var queue = scripts[req.bot.id] ?? []
            let t = queue.isEmpty ? "done" : queue.removeFirst()
            scripts[req.bot.id] = queue
            return t
        }
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        lock.withLock { active -= 1 }
        let extracted = ApprovalRequest.extract(from: text)
        return ChatMessage(role: .bot, botId: req.bot.id, text: extracted.text, approval: extracted.request)
    }

    var order: [String] { lock.withLock { calls.map(\.bot) } }
}

final class GroupTests: XCTestCase {
    let bots = [
        Bot(id: "lead", name: "Lead", role: "Team lead"),
        Bot(id: "frontend", name: "Frontend", role: "UI"),
        Bot(id: "backend", name: "Backend", role: "Data"),
        Bot(id: "tester", name: "Tester", role: "QA"),
    ]

    func group(limit: Int = 3) -> BotGroup {
        BotGroup(id: "ship", name: "ship", members: ["lead", "frontend", "backend", "tester"], lead: "lead",
                 rules: "Be brief.", handoffLimit: limit)
    }

    func orchestrator(_ team: ScriptedTeam, limit: Int = 3, history: [ChatMessage] = [ChatMessage(role: .user, text: "Build it")],
                      sessions: Set<String> = []) -> GroupOrchestrator {
        GroupOrchestrator(group: group(), bots: bots, history: history, summaryPath: "/g/SUMMARY.md",
                          workspacePath: "/g/workspace", limits: RunLimits(maxHandoffs: limit), hasSession: { sessions.contains($0) },
                          runTurn: { await team.run($0) })
    }

    // MARK: Mentions

    func testMentionsInOrderByIdOrName() {
        let byId = Dictionary(uniqueKeysWithValues: bots.map { ($0.id, $0) })
        let text = "@backend set up tables.\nThen @Frontend builds the UI. @backend again. Email me@example.com"
        XCTAssertEqual(GroupPlan.mentions(in: text, group: group(), bots: byId, speaker: "lead"), ["backend", "frontend"])
    }

    func testMentionsIgnoreCodeSpeakerAndStrangers() {
        let byId = Dictionary(uniqueKeysWithValues: bots.map { ($0.id, $0) })
        let text = "I'm @lead. `@tester` not this\n```\n@frontend nope\n```\n@nobody hi"
        XCTAssertEqual(GroupPlan.mentions(in: text, group: group(), bots: byId, speaker: "lead"), [])
    }

    func testEveryoneMeansAllMembersButLead() {
        let byId = Dictionary(uniqueKeysWithValues: bots.map { ($0.id, $0) })
        XCTAssertEqual(GroupPlan.mentions(in: "@everyone go", group: group(), bots: byId, speaker: "lead"),
                       ["frontend", "backend", "tester"])
    }

    func testParallelMarker() {
        XCTAssertTrue(GroupPlan.isParallel("@a x\n@b y\n[Parallel]"))
        XCTAssertFalse(GroupPlan.isParallel("```\n[parallel]\n```"))
    }

    // MARK: Flow

    func testLeadAnswersAloneWhenNoMentions() async {
        let team = ScriptedTeam(["lead": ["Here's the answer."]])
        let outcome = await orchestrator(team).runTask()
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(team.order, ["lead"])
    }

    func testMembersGoInMentionOrderThenLeadReviews() async {
        let team = ScriptedTeam([
            "lead": ["@backend make tables\n@frontend build UI", "All done: here's the summary."],
            "backend": ["Tables ready."],
            "frontend": ["UI built."],
        ])
        let o = orchestrator(team)
        let outcome = await o.runTask()
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(team.order, ["lead", "backend", "frontend", "lead"])
        XCTAssertEqual(team.calls[0].kind, .leadStart)
        XCTAssertEqual(team.calls[1].kind, .member(handedOnBy: "lead"))
        XCTAssertEqual(team.calls[3].kind, .leadReview)
        XCTAssertEqual(o.history.count, 5) // user + 4 replies
    }

    func testEachMemberSeesEarlierReplies() async {
        let team = ScriptedTeam([
            "lead": ["@backend first\n@frontend second", "wrap up"],
            "backend": ["SCHEMA-READY"],
        ])
        _ = await orchestrator(team).runTask()
        let frontendPrompt = team.calls.first { $0.bot == "frontend" }!.prompt
        XCTAssertTrue(frontendPrompt.contains("SCHEMA-READY"), "frontend sees backend's reply")
        XCTAssertTrue(frontendPrompt.contains("Build it"), "and the original task")
        XCTAssertTrue(frontendPrompt.contains("Be brief."), "and the group rules on its first turn")
    }

    func testOnlyNewMessagesWhenBotHasASession() async {
        let history = [
            ChatMessage(role: .user, text: "OLD-TASK"),
            ChatMessage(role: .bot, botId: "lead", text: "old reply"),
            ChatMessage(role: .user, text: "NEW-TASK"),
        ]
        let team = ScriptedTeam(["lead": ["ok"]])
        _ = await orchestrator(team, history: history, sessions: ["lead"]).runTask()
        let prompt = team.calls[0].prompt
        XCTAssertTrue(prompt.contains("NEW-TASK"))
        XCTAssertFalse(prompt.contains("OLD-TASK"))
        XCTAssertFalse(prompt.contains("Group rules"), "intro only on the first turn")
    }

    func testParallelOnlyWhenLeadSaysSo() async {
        let seq = ScriptedTeam(["lead": ["@frontend a\n@backend b\n@tester c", "done"]])
        seq.delay = 50_000_000
        _ = await orchestrator(seq).runTask()
        XCTAssertEqual(seq.maxConcurrent, 1)

        let par = ScriptedTeam(["lead": ["@frontend a\n@backend b\n@tester c\n[parallel]", "done"]])
        par.delay = 200_000_000
        let o = orchestrator(par)
        let outcome = await o.runTask()
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(par.maxConcurrent, 3)
        // Replies are recorded in the lead's order regardless of who finished first.
        XCTAssertEqual(o.history.compactMap(\.botId), ["lead", "frontend", "backend", "tester", "lead"])
    }

    func testMemberCanHandOnToAnotherMember() async {
        let team = ScriptedTeam([
            "lead": ["@backend build the API", "Shipped."],
            "backend": ["API done. @tester please test it."],
            "tester": ["All green."],
        ])
        let outcome = await orchestrator(team).runTask()
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(team.order, ["lead", "backend", "tester", "lead"])
        XCTAssertEqual(team.calls[2].kind, .member(handedOnBy: "backend"))
    }

    func testHandoffCapStopsWithAReasonWhenWorkKeepsChanging() async {
        // Lead keeps handing off, but each message is new work (so it isn't a loop): only the cap stops it.
        let words = ["schema", "login", "billing", "emails", "search", "uploads", "reports", "exports", "alerts", "themes"]
        let team = ScriptedTeam(["lead": words.map { "@frontend now build the \($0) screen" }, "frontend": Array(repeating: "ok", count: 10)])
        let outcome = await orchestrator(team, limit: 3).runTask()
        XCTAssertEqual(outcome, .handoffLimitReached(limit: 3, waiting: ["frontend"]))
        XCTAssertEqual(team.order, ["lead", "frontend", "lead", "frontend", "lead", "frontend", "lead"])
        XCTAssertNotNil(outcome.stuckReason(names: { $0 }))
    }

    func testDefaultLimitIsThree() {
        XCTAssertEqual(BotGroup(id: "g", name: "g").handoffLimit, 3)
        let decoded = try! JSONCoding.decoder().decode(BotGroup.self, from: Data(#"{"name":"x"}"#.utf8))
        XCTAssertEqual(decoded.handoffLimit, 3)
    }

    func testApprovalRequestPausesTheGroup() async {
        let team = ScriptedTeam(["lead": ["Plan: A then B.\n[[approve: start building with this plan]]"]])
        let outcome = await orchestrator(team).runTask()
        XCTAssertEqual(outcome, .awaitingApproval(botId: "lead"))
        XCTAssertEqual(team.order, ["lead"])
    }

    func testResumeAfterApprovalContinuesWithThatBot() async {
        let team = ScriptedTeam(["lead": ["@frontend build", "done"], "frontend": ["built"]])
        let outcome = await orchestrator(team).resume(with: "lead", note: "Approved: plan. Go ahead.")
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(team.order, ["lead", "frontend", "lead"])
        XCTAssertTrue(team.calls[0].prompt.contains("Approved: plan"))
    }

    func testFailureStopsTheGroup() async {
        let o = GroupOrchestrator(group: group(), bots: bots, history: [], summaryPath: "s", workspacePath: "w") { req in
            if req.bot.id == "lead" { return ChatMessage(role: .bot, botId: "lead", text: "@frontend go") }
            return ChatMessage(role: .bot, botId: req.bot.id, status: .failed, failure: RunFailure(kind: .network, message: "x"))
        }
        let outcome = await o.runTask()
        XCTAssertEqual(outcome, .failed(botId: "frontend"))
    }

    func testAskEveryoneThenLeadSumsUp() async {
        let team = ScriptedTeam([
            "frontend": ["Use React."], "backend": ["Use Supabase."], "tester": ["Test early."], "lead": ["Summary: …"],
        ])
        team.delay = 100_000_000
        let o = orchestrator(team, history: [ChatMessage(role: .user, text: "What stack?")])
        let outcome = await o.askEveryone()
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(team.maxConcurrent, 3, "views are gathered in parallel")
        XCTAssertEqual(team.order.last, "lead")
        XCTAssertEqual(team.calls.last?.kind, .summary)
        let summaryPrompt = team.calls.last!.prompt
        XCTAssertTrue(summaryPrompt.contains("Use React.") && summaryPrompt.contains("Use Supabase.") && summaryPrompt.contains("Test early."))
    }

    func testNoLead() async {
        let g = BotGroup(id: "g", name: "g", members: [], lead: nil)
        let o = GroupOrchestrator(group: g, bots: [], history: [], summaryPath: "", workspacePath: "") { _ in ChatMessage(role: .bot) }
        let outcome = await o.runTask()
        XCTAssertEqual(outcome, .noLead)
    }

    // MARK: Storage

    func testGroupStoreCreatesFolder() throws {
        let paths = LaunchpadPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("lp-g-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = GroupStore(paths: paths)
        let g = try store.create(name: "#Build and Ship", members: ["a", "b"], lead: nil)
        XCTAssertEqual(g.id, "build-and-ship")
        XCTAssertEqual(g.name, "Build and Ship")
        XCTAssertEqual(g.lead, "a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.summary(g.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.workspace(g.id).path))
        XCTAssertEqual(try store.load(id: g.id), g.roundedDate())
    }
}

private extension BotGroup {
    func roundedDate() -> BotGroup {
        var g = self
        g.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
        return g
    }
}

final class DirectMentionTests: XCTestCase {
    let bots = [Bot(id: "lead", name: "Lead"), Bot(id: "frontend", name: "Frontend"), Bot(id: "backend", name: "Backend")]
    var group: BotGroup { BotGroup(id: "g", name: "g", members: ["lead", "frontend", "backend"], lead: "lead") }

    func testMentionedBotAnswersFirstAndLeadStaysOut() async {
        let team = ScriptedTeam(["backend": ["Signed in, forwarding works."]])
        let o = GroupOrchestrator(group: group, bots: bots, history: [ChatMessage(role: .user, text: "@backend I've signed up, open the browser")],
                                  summaryPath: "s", workspacePath: "w", runTurn: { await team.run($0) })
        let outcome = await o.runTask()
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(team.order, ["backend"])
        XCTAssertEqual(team.calls.first?.kind, .fromYou)
    }

    func testNoMentionStillStartsWithTheLead() async {
        let team = ScriptedTeam(["lead": ["On it, no hand-off needed."]])
        let o = GroupOrchestrator(group: group, bots: bots, history: [ChatMessage(role: .user, text: "How's it going?")],
                                  summaryPath: "s", workspacePath: "w", runTurn: { await team.run($0) })
        _ = await o.runTask()
        XCTAssertEqual(team.order, ["lead"])
    }

    func testMessageSentMidRunIsAnsweredByTheBotYouTagged() async {
        final class Box: @unchecked Sendable { var o: GroupOrchestrator? }
        let box = Box()
        let team = ScriptedTeam([
            "lead": ["@frontend build the page", "All done."],
            "frontend": ["Page built."],
            "backend": ["Got it, signing in now."],
        ])
        let o = GroupOrchestrator(group: group, bots: bots, history: [ChatMessage(role: .user, text: "Build it")],
                                  summaryPath: "s", workspacePath: "w") { req in
            // While Frontend works, you tag Backend.
            if req.bot.id == "frontend" { box.o?.interject(ChatMessage(role: .user, text: "@backend I've signed up")) }
            return await team.run(req)
        }
        box.o = o
        let outcome = await o.runTask()
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(team.order, ["lead", "frontend", "backend", "lead"], "Backend answers right after Frontend's turn, then the team carries on")
        XCTAssertEqual(team.calls[2].kind, .fromYou)
        XCTAssertTrue(team.calls[2].prompt.contains("I've signed up"))
        XCTAssertTrue(o.history.contains { $0.text == "@backend I've signed up" })
    }

    func testUntaggedMidRunMessageGoesToTheLead() async {
        final class Box: @unchecked Sendable { var o: GroupOrchestrator? }
        let box = Box()
        let team = ScriptedTeam(["lead": ["@frontend go", "Noted, will do.", "Done."], "frontend": ["ok"]])
        let o = GroupOrchestrator(group: group, bots: bots, history: [ChatMessage(role: .user, text: "Build it")],
                                  summaryPath: "s", workspacePath: "w") { req in
            if req.bot.id == "frontend" { box.o?.interject(ChatMessage(role: .user, text: "Use blue buttons please")) }
            return await team.run(req)
        }
        box.o = o
        _ = await o.runTask()
        XCTAssertEqual(team.order, ["lead", "frontend", "lead", "lead"])
        XCTAssertEqual(team.calls[2].kind, .fromYou)
    }

    func testSteeringStopsTheRunningTurnAndAnswersYouStraightAway() async {
        final class Box: @unchecked Sendable { var o: GroupOrchestrator? }
        let box = Box()
        let team = ScriptedTeam([
            "lead": ["@frontend build the page", "Changing course as you asked.", "All done."],
            "frontend": ["Half-built page"],
        ])
        let o = GroupOrchestrator(group: group, bots: bots, history: [ChatMessage(role: .user, text: "Build it")],
                                  summaryPath: "s", workspacePath: "w") { req in
            var reply = await team.run(req)
            if req.bot.id == "frontend" {
                // You steer while Frontend works: its turn is stopped for your message.
                box.o?.steer(ChatMessage(role: .user, text: "Use blue buttons instead"))
                reply.status = .stopped
            }
            return reply
        }
        box.o = o
        let outcome = await o.runTask()
        XCTAssertEqual(outcome, .done, "a stop for steering is not the end of the run")
        XCTAssertEqual(team.order.prefix(3), ["lead", "frontend", "lead"], "the lead answers right after the stopped turn")
        XCTAssertEqual(team.calls[2].kind, .fromYou)
        XCTAssertTrue(team.calls[2].prompt.contains("Use blue buttons instead"))
    }

    func testAStoppedTurnWithoutSteeringStillEndsTheRun() async {
        let team = ScriptedTeam(["lead": ["@frontend go"], "frontend": ["partial"]])
        let o = GroupOrchestrator(group: group, bots: bots, history: [ChatMessage(role: .user, text: "Build it")],
                                  summaryPath: "s", workspacePath: "w") { req in
            var reply = await team.run(req)
            if req.bot.id == "frontend" { reply.status = .stopped }
            return reply
        }
        let outcome = await o.runTask()
        XCTAssertEqual(outcome, .stopped)
        XCTAssertEqual(team.order, ["lead", "frontend"])
    }

    func testSteeringAMentionedBotGoesToThatBot() async {
        final class Box: @unchecked Sendable { var o: GroupOrchestrator? }
        let box = Box()
        let team = ScriptedTeam(["lead": ["@frontend build it", "Done."], "frontend": ["working"], "backend": ["Switching to the API now."]])
        let o = GroupOrchestrator(group: group, bots: bots, history: [ChatMessage(role: .user, text: "Build it")],
                                  summaryPath: "s", workspacePath: "w") { req in
            var reply = await team.run(req)
            if req.bot.id == "frontend" {
                box.o?.steer(ChatMessage(role: .user, text: "@backend do the API first"))
                reply.status = .stopped
            }
            return reply
        }
        box.o = o
        let outcome = await o.runTask()
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(team.order[2], "backend")
        XCTAssertEqual(team.calls[2].kind, .fromYou)
    }
}
