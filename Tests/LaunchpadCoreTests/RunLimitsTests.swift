import XCTest
@testable import LaunchpadCore

final class RunLimitsTests: XCTestCase {
    let bots = [
        Bot(id: "lead", name: "Lead", role: "Lead"),
        Bot(id: "frontend", name: "Frontend", role: "UI"),
        Bot(id: "backend", name: "Backend", role: "Data"),
        Bot(id: "tester", name: "Tester", role: "QA"),
    ]

    /// A group whose own (old) hand-off limit is the old default of 3: it must no longer pause anything.
    func group() -> BotGroup {
        BotGroup(id: "ship", name: "ship", members: ["lead", "frontend", "backend", "tester"], lead: "lead", rules: "Be brief.", handoffLimit: 3)
    }

    func orchestrator(_ team: ScriptedTeam, limits: RunLimits = RunLimits()) -> GroupOrchestrator {
        GroupOrchestrator(group: group(), bots: bots, history: [ChatMessage(role: .user, text: "Build it")], summaryPath: "/g/SUMMARY.md",
                          workspacePath: "/g/workspace", limits: limits, runTurn: { await team.run($0) })
    }

    private let topics = ["schema", "login", "billing", "emails", "search", "uploads", "reports", "exports", "alerts", "themes",
                          "profiles", "invoices", "webhooks", "caching", "logging", "metrics", "backups", "imports", "teams", "audit"]

    // MARK: A long task just finishes

    func testALongTaskFinishesWithoutAnyPause() async {
        // Twenty rounds of real, different work: well past the old limit of 3, and nobody pauses.
        let lead = topics.map { "@frontend please build the \($0) part" } + ["All done, shipped."]
        let team = ScriptedTeam(["lead": lead, "frontend": topics.map { "Built the \($0) part." }])
        let outcome = await orchestrator(team).runTask()
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(team.order.filter { $0 == "frontend" }.count, topics.count)
        XCTAssertNil(outcome.stuckReason(names: { $0 }))
    }

    func testMembersHandingOnToEachOtherAlsoRunToTheEnd() async {
        let team = ScriptedTeam([
            "lead": ["@backend build the API", "Shipped."],
            "backend": ["API done. @frontend wire it up."],
            "frontend": ["Wired. @tester please test it."],
            "tester": ["All green."],
        ])
        let outcome = await orchestrator(team).runTask()
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(team.order, ["lead", "backend", "frontend", "tester", "lead"])
    }

    // MARK: A real loop stops, with a reason

    func testTheSameHandoffAgainAndAgainIsALoop() async {
        let team = ScriptedTeam(["lead": Array(repeating: "@frontend try the build again", count: 30), "frontend": Array(repeating: "Still failing.", count: 30)])
        let outcome = await orchestrator(team).runTask()
        XCTAssertEqual(outcome, .loopDetected(botId: "lead", times: 3))
        XCTAssertEqual(team.order, ["lead", "frontend", "lead", "frontend", "lead"])   // stopped on the third, before more work
        let reason = outcome.stuckReason(names: { $0 == "lead" ? "Lead" : $0 })
        XCTAssertTrue(reason?.contains("Lead has handed the same work on 3 times") ?? false)
    }

    func testTwoBotsBouncingTheSameWorkBackAndForthIsALoop() async {
        let team = ScriptedTeam([
            "lead": ["@frontend build the page"] + Array(repeating: "Not right yet. @frontend fix it", count: 30),
            "frontend": Array(repeating: "Fixed it. @backend can you check the API?", count: 30),
            "backend": Array(repeating: "API is fine. @frontend over to you.", count: 30),
        ])
        let outcome = await orchestrator(team).runTask()
        guard case .loopDetected(_, let times) = outcome else { return XCTFail("expected a loop, got \(outcome)") }
        XCTAssertEqual(times, 3)
        XCTAssertLessThan(team.order.count, 20)
    }

    func testRepeatsThatDifferOnlyInNumbersAndMentionsStillCount() async {
        let team = ScriptedTeam(["lead": (1...30).map { "@frontend retry number \($0) of the deploy" }, "frontend": Array(repeating: "Failed.", count: 30)])
        guard case .loopDetected = await orchestrator(team).runTask() else { return XCTFail("expected a loop") }
    }

    func testNewWorkOrAnotherPersonIsNeverALoop() {
        var d = LoopDetector()
        XCTAssertNil(d.observe(botId: "lead", text: "@frontend build the login screen", handedTo: ["frontend"]))
        XCTAssertNil(d.observe(botId: "lead", text: "@frontend build the billing screen", handedTo: ["frontend"]))
        XCTAssertNil(d.observe(botId: "lead", text: "@frontend build the emails screen", handedTo: ["frontend"]))
        XCTAssertNil(d.observe(botId: "lead", text: "@frontend build the search screen", handedTo: ["frontend"]))
        // The same words to different people, or a different bot saying them, are different hand-offs.
        var e = LoopDetector()
        for target in ["frontend", "backend", "tester", "frontend", "backend", "tester"] where target != "x" {
            XCTAssertNil(e.observe(botId: "lead", text: "Please take a look", handedTo: [target]), target)
        }
        var f = LoopDetector()
        XCTAssertNil(f.observe(botId: "a", text: "same words here", handedTo: ["z"]))
        XCTAssertNil(f.observe(botId: "b", text: "same words here", handedTo: ["z"]))
        XCTAssertNil(f.observe(botId: "c", text: "same words here", handedTo: ["z"]))
        // A reply that hands nothing on is never evidence of a loop.
        var g = LoopDetector()
        for _ in 0..<10 { XCTAssertNil(g.observe(botId: "a", text: "Done.", handedTo: [])) }
    }

    func testTheThirdIdenticalHandoffIsTheOneThatTrips() {
        var d = LoopDetector()
        XCTAssertNil(d.observe(botId: "a", text: "go again", handedTo: ["b"]))
        XCTAssertNil(d.observe(botId: "a", text: "go again", handedTo: ["b"]))
        XCTAssertEqual(d.observe(botId: "a", text: "go again", handedTo: ["b"]), 3)
        XCTAssertEqual(d.observe(botId: "a", text: "go again", handedTo: ["b"]), 4)
    }

    // MARK: The setting

    func testTheCapIsGenerousByDefaultAndTheGroupsOldLimitIsIgnored() {
        XCTAssertEqual(RunLimits().maxHandoffs, 60)
        XCTAssertGreaterThan(RunLimits().maxHandoffs, 20)           // more than the old top of the stepper
        XCTAssertEqual(group().handoffLimit, 3)                    // still stored, no longer used
    }

    func testTheCapIsClampedAndReadLeniently() throws {
        XCTAssertEqual(RunLimits(maxHandoffs: 0).maxHandoffs, 3)
        XCTAssertEqual(RunLimits(maxHandoffs: 1_000_000).maxHandoffs, 500)
        XCTAssertEqual(try JSONCoding.decoder().decode(RunLimits.self, from: Data("{}".utf8)).maxHandoffs, 60)
        XCTAssertEqual(try JSONCoding.decoder().decode(RunLimits.self, from: Data(#"{"maxHandoffs":"lots"}"#.utf8)).maxHandoffs, 60)
        XCTAssertEqual(try JSONCoding.decoder().decode(RunLimits.self, from: Data(#"{"maxHandoffs":9999}"#.utf8)).maxHandoffs, 500)
    }

    func testTheSettingIsSavedWhereBotsCannotWriteAndMissingMeansDefault() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lp-limits-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = LaunchpadPaths(root: root)
        let store = RunLimitsStore(paths: paths)
        XCTAssertEqual(store.load(), RunLimits())
        try store.save(RunLimits(maxHandoffs: 120))
        XCTAssertEqual(store.load().maxHandoffs, 120)
        try Data("not json".utf8).write(to: store.file)
        XCTAssertEqual(store.load(), RunLimits())
        XCTAssertTrue(store.file.path.hasPrefix(paths.launchpadData.path + "/"))
        let config = GuardRulesFile.config(for: Bot(id: "x", name: "X"), paths: paths)
        XCTAssertTrue(config.protected.contains(store.file.path))
    }

    func testTheSettingChangesWhenTheCapHits() async {
        let team = { ScriptedTeam(["lead": self.topics.map { "@frontend build the \($0) part" }, "frontend": Array(repeating: "ok", count: 20)]) }
        let low = await orchestrator(team(), limits: RunLimits(maxHandoffs: 5)).runTask()
        let high = await orchestrator(team(), limits: RunLimits(maxHandoffs: 100)).runTask()
        XCTAssertEqual(low, .handoffLimitReached(limit: 5, waiting: ["frontend"]))
        XCTAssertEqual(high, .done)
    }
}
