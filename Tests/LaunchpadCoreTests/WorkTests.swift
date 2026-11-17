import XCTest
@testable import LaunchpadCore

// MARK: - Models

final class WorkModelTests: XCTestCase {
    func testStepsAndRunsDecodeLeniently() throws {
        let step = try JSONCoding.decoder().decode(WorkflowStep.self, from: Data(#"{"kind":"agent","text":"Do it"}"#.utf8))
        XCTAssertNil(step.timeoutMinutes)
        XCTAssertEqual(step.timeout, 45)
        XCTAssertEqual(step.match, .contains)
        XCTAssertFalse(step.id.isEmpty)

        let run = try JSONCoding.decoder().decode(WorkflowRun.self, from: Data("""
        {"id":"r1","workflowId":"w","name":"Brief","trigger":"Run by hand","startedAt":"2026-11-17T09:00:00Z",
         "status":"running","current":1,"results":[{"step":0,"text":"Hi","ok":true}]}
        """.utf8))
        XCTAssertNil(run.carry)
        XCTAssertNil(run.resumeFrom)

        // A workflow file written by hand, with a schedule that uses routine timing.
        let wf = try JSONCoding.decoder().decode(Workflow.self, from: Data("""
        {"name":"Daily brief","schedule":{"daily":{"hour":9,"minute":0,"weekdaysOnly":true}},
         "steps":[{"kind":"prompt","text":"Hello"},{"kind":"agent","text":"Summarise","target":{"bot":{"_0":"planner"}}}]}
        """.utf8))
        XCTAssertEqual(wf.steps.count, 2)
        XCTAssertEqual(wf.steps[1].target, .bot("planner"))
        XCTAssertEqual(wf.scheduleSummary, "Weekdays at 09:00")
        XCTAssertTrue(wf.enabled)
    }

    func testARunCutShortByAQuitResumesFromTheUnfinishedStep() throws {
        var r = WorkflowRun(workflowId: "w", name: "Draft, review, send", trigger: "Run by hand")
        r.current = 2
        r.status = .waiting
        r.carry = "The draft"
        let after = r.interruptedByQuit(at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(after.status, .stopped)
        XCTAssertEqual(after.resumeFrom, 2)
        XCTAssertEqual(after.note, "Stopped when Launchpad quit.")
        let resumed = try XCTUnwrap(after.resumed())
        XCTAssertEqual(resumed.status, .running)
        XCTAssertEqual(resumed.current, 2)
        XCTAssertEqual(resumed.carry, "The draft", "the next step gets the input it had")
        XCTAssertNil(resumed.resumeFrom)
        XCTAssertNil(resumed.finishedAt)
        XCTAssertNil(resumed.resumed(), "can only resume once")
    }

    func testFinishedRunsAreLeftAlone() {
        var r = WorkflowRun(workflowId: "w", name: "Done one", trigger: "x")
        r.status = .done
        XCTAssertEqual(r.interruptedByQuit(), r)
        XCTAssertNil(r.interruptedByQuit().resumed())
    }

    func testASecondApprovalStepAsksAgain() {
        var run = WorkflowRun(workflowId: "w", name: "Draft, OK, send, OK, publish", trigger: "x")
        run.awaitApproval()
        XCTAssertEqual(run.status, .waiting)
        run.approved = true
        run.status = .running
        run.awaitApproval()
        XCTAssertNil(run.approved, "the second approval waits for its own answer")
    }

    func testStepTimeoutIsConfigurable() {
        var s = WorkflowStep(kind: .agent)
        XCTAssertEqual(s.timeout, WorkflowStep.defaultTimeout)
        s.timeoutMinutes = 120
        XCTAssertEqual(s.timeout, 120)
        XCTAssertEqual(WorkflowStep.timeoutTitle(120), "2 hr")
        XCTAssertEqual(WorkflowStep.timeoutTitle(90), "1 hr 30 min")
        XCTAssertEqual(WorkflowStep.timeoutTitle(15), "15 min")
    }

    func testTaskStatusComesFromTheReplies() {
        let ask = ChatMessage(id: "m1", role: .user, text: "Fix the bug")
        let working = ChatMessage(role: .bot, botId: "a", text: "On it", status: .streaming)
        let done = ChatMessage(role: .bot, botId: "a", text: "Fixed it.")
        let question = ChatMessage(role: .bot, botId: "a", text: "Which branch?")
        let failed = ChatMessage(role: .bot, botId: "a", status: .failed)
        let later = ChatMessage(role: .user, text: "Something else")
        let other = ChatMessage(role: .bot, botId: "a", text: "Reply to something else")

        XCTAssertEqual(TaskStatus.replies(after: "m1", in: [ask, done, later, other]), [done], "stops when you spoke again")
        XCTAssertEqual(TaskStatus.of(replies: [], busy: false), .queued)
        XCTAssertEqual(TaskStatus.of(replies: [], busy: true), .working)
        XCTAssertEqual(TaskStatus.of(replies: [working], busy: true), .working)
        XCTAssertEqual(TaskStatus.of(replies: [done], busy: false), .done)
        XCTAssertEqual(TaskStatus.of(replies: [done], busy: true), .working, "a group hand-off is still going")
        XCTAssertEqual(TaskStatus.of(replies: [question], busy: false), .needsYou)
        XCTAssertEqual(TaskStatus.of(replies: [failed], busy: false), .failed)
        var card = done
        card.approval = ApprovalRequest(action: "deploy")
        XCTAssertEqual(TaskStatus.of(replies: [card], busy: false), .needsYou, "an approval card waits for you")
    }
}

// MARK: - Store

final class WorkStoreTests: XCTestCase {
    func testWorkflowsAreOneFileEachAndRunsSurviveAQuit() throws {
        let paths = LaunchpadPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("lp-work-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = WorkStore(paths: paths)
        let wf = Workflow(id: "brief", name: "Brief", steps: [WorkflowStep(kind: .prompt, text: "Hi")], createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        try store.save(wf)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("workflows/brief.json").path))
        XCTAssertEqual(store.loadWorkflows(), [wf])

        // An agent drops in a new workflow file with no id: the file name is its id.
        try Data(#"{"name":"From an agent","steps":[{"kind":"prompt","text":"x"}]}"#.utf8)
            .write(to: paths.workflowFile("from-agent"))
        XCTAssertEqual(store.loadWorkflows().map(\.id).sorted(), ["brief", "from-agent"])
        XCTAssertEqual(store.newWorkflowId("Brief"), "brief-2")

        var run = WorkflowRun(id: "run1", workflowId: "brief", name: "Brief", trigger: "x")
        run.current = 1
        run.carry = "input"
        try store.save(run)
        let after = store.loadRuns(afterQuit: true)
        XCTAssertEqual(after.first?.status, .stopped)
        XCTAssertEqual(after.first?.resumeFrom, 1)
        XCTAssertEqual(store.loadRuns().first?.resumeFrom, 1, "saved as stopped")

        store.appendLog(RunLogEntry(kind: .workflow, name: "Brief", runId: "run1"))
        XCTAssertEqual(store.loadLog(afterQuit: true).first?.outcome, .stopped)
        let file = try store.writeOutput(workflow: "A/B", body: "Result", now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(file.lastPathComponent.hasPrefix("A-B "))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# A/B\n\nResult\n")
    }
}

// MARK: - Engine, with a fake app

@MainActor
final class FakeExecutor: WorkflowStepExecutor {
    var known: Set<WorkTarget> = [.bot("writer"), .bot("editor"), .group("team")]
    var replies: [String: AgentStepResult] = [:]
    var prompts: [(WorkTarget, String)] = []
    var posted: [(WorkTarget, String)] = []
    var approvalsAsked: [ApprovalStepRequest] = []
    var answer: Bool? = true
    var hang = false
    var cancelled = false
    var finished: [String: AgentStepResult] = [:]
    var sentIds = 0
    weak var engine: WorkflowEngine?

    func targetExists(_ target: WorkTarget) -> Bool { known.contains(target) }
    func targetName(_ target: WorkTarget) -> String { target.id.capitalized }

    func runAgentStep(_ request: AgentStepRequest, sent: @escaping @MainActor (String, String) -> Void) async -> AgentStepResult {
        prompts.append((request.target, request.prompt))
        sentIds += 1
        sent("chat-\(request.target.id)", "msg-\(sentIds)")
        if hang {
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
            cancelled = true
            return AgentStepResult(ok: false, text: "Stopped.")
        }
        return replies[request.target.id] ?? AgentStepResult(ok: true, text: "\(request.target.id) did it")
    }

    func finishedReply(chatId: String, messageId: String) -> AgentStepResult? { finished[messageId] }

    func askApproval(_ request: ApprovalStepRequest) async -> Bool? {
        approvalsAsked.append(request)
        guard let engine else { return answer }
        if let answer { Task { @MainActor in engine.answer(request.runId, approve: answer) } }
        return await engine.approvals.wait(request.runId)
    }

    func postOutput(_ text: String, workflowName: String, to target: WorkTarget) async {
        posted.append((target, text))
    }
}

@MainActor
final class WorkflowEngineTests: XCTestCase {
    var paths: LaunchpadPaths!
    var engine: WorkflowEngine!
    var fake: FakeExecutor!

    override func setUp() async throws {
        paths = LaunchpadPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("lp-wf-\(UUID().uuidString)"))
        fake = FakeExecutor()
        engine = WorkflowEngine(store: WorkStore(paths: paths), executor: fake)
        fake.engine = engine
        engine.load()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: paths.root)
    }

    private func make(_ steps: [WorkflowStep], schedule: Routine.Trigger? = nil) throws -> Workflow {
        var wf = try engine.newWorkflow(name: "Draft and send", steps: steps)
        wf.schedule = schedule
        try engine.save(wf)
        return wf
    }

    func testRoutineRunsRecordedThroughTheEngineSurviveItsOwnSaves() async throws {
        engine.record(RunLogEntry(kind: .routine, name: "Morning brief", target: .bot("writer"), sourceId: "brief", chatId: "c1"))
        let wf = try make([WorkflowStep(kind: .prompt, text: "Hi")])
        _ = await engine.runToEnd(wf.id)
        let saved = WorkStore(paths: paths).loadLog()
        XCTAssertEqual(saved.map(\.kind), [.routine, .workflow])
        XCTAssertEqual(engine.log.count, 2)
    }

    func testStepsPassWorkAlongAndTheOutputIsPostedAndSaved() async throws {
        fake.replies["editor"] = AgentStepResult(ok: true, text: "Polished draft, APPROVED")
        let wf = try make([
            WorkflowStep(kind: .prompt, text: "Launch notes"),
            WorkflowStep(kind: .agent, text: "Write a draft", target: .bot("writer")),
            WorkflowStep(kind: .agent, text: "Edit it", target: .bot("editor")),
            WorkflowStep(kind: .condition, text: "approved"),
            WorkflowStep(kind: .approval, text: "Send it?"),
            WorkflowStep(kind: .output, target: .group("team"), saveFile: true),
        ])
        let runResult = await engine.runToEnd(wf.id)
        let run = try XCTUnwrap(runResult)
        XCTAssertEqual(run.status, .done, run.note ?? "")
        XCTAssertEqual(run.current, 6)
        XCTAssertEqual(fake.prompts.map(\.0), [.bot("writer"), .bot("editor")])
        XCTAssertTrue(fake.prompts[0].1.hasPrefix("🔁 Draft and send · step 2 of 6\nWrite a draft"))
        XCTAssertTrue(fake.prompts[0].1.contains("Launch notes"))
        XCTAssertTrue(fake.prompts[1].1.contains("writer did it"), "each step gets the one before's result")
        XCTAssertEqual(fake.approvalsAsked.count, 1)
        XCTAssertTrue(fake.approvalsAsked[0].text.hasPrefix("Send it?\n\nPolished draft"))
        XCTAssertEqual(fake.posted.map(\.1), ["Polished draft, APPROVED"])
        XCTAssertEqual(run.results.map(\.ok), [true, true, true, true, true, true])
        XCTAssertTrue(run.results[5].text.contains("Posted in Team."))
        XCTAssertTrue(run.results[5].text.contains("Saved to"))
        // The approval shows in Tasks, finished.
        let task = try XCTUnwrap(engine.tasks.first)
        XCTAssertEqual(task.kind, .approval(run: run.id, step: 4))
        XCTAssertNotNil(task.finishedAt)
        XCTAssertEqual(engine.status(of: task, history: [], busy: false), .done)
        XCTAssertEqual(engine.log.last?.outcome, .done)
        // Saved after every step: the file on disk matches.
        XCTAssertEqual(WorkStore(paths: paths).loadRuns().first?.status, .done)
    }

    func testAConditionThatDoesntMatchStopsTheRun() async throws {
        let wf = try make([
            WorkflowStep(kind: .prompt, text: "All good"),
            WorkflowStep(kind: .condition, text: "error", match: .contains),
            WorkflowStep(kind: .output, target: .group("team")),
        ])
        let runResult = await engine.runToEnd(wf.id)
        let run = try XCTUnwrap(runResult)
        XCTAssertEqual(run.status, .stopped)
        XCTAssertEqual(run.note, "Condition at step 2 wasn’t met.")
        XCTAssertTrue(fake.posted.isEmpty)

        let notWf = try make([WorkflowStep(kind: .prompt, text: "All good"), WorkflowStep(kind: .condition, text: "error", match: .notContains)])
        let notRun = await engine.runToEnd(notWf.id)
        XCTAssertEqual(notRun?.status, .done)
    }

    func testDecliningAnApprovalStops() async throws {
        fake.answer = false
        let wf = try make([WorkflowStep(kind: .approval), WorkflowStep(kind: .output, target: .group("team"))])
        let runResult = await engine.runToEnd(wf.id)
        let run = try XCTUnwrap(runResult)
        XCTAssertEqual(run.status, .stopped)
        XCTAssertEqual(run.note, "You didn’t approve step 1.")
        XCTAssertEqual(fake.approvalsAsked.first?.text, "Carry on with Draft and send?")
        XCTAssertEqual(engine.status(of: engine.tasks[0], history: [], busy: false), .failed)
    }

    func testAFailedOrMissingBotFailsTheRun() async throws {
        fake.replies["writer"] = AgentStepResult(ok: false, text: "Couldn't")
        let wf = try make([WorkflowStep(kind: .agent, text: "x", target: .bot("writer"))])
        let runResult = await engine.runToEnd(wf.id)
        let run = try XCTUnwrap(runResult)
        XCTAssertEqual(run.status, .failed)
        XCTAssertEqual(run.note, "Writer didn’t finish step 1.")

        let missing = try make([WorkflowStep(kind: .agent, text: "x", target: .bot("deleted"))])
        let missingRun = await engine.runToEnd(missing.id)
        XCTAssertEqual(missingRun?.note, "Step 1 has no bot.")
    }

    func testAStepThatTakesTooLongTimesOutAndIsCancelled() async throws {
        fake.hang = true
        engine.secondsPerMinute = 0.05
        let wf = try make([WorkflowStep(kind: .agent, text: "x", target: .bot("writer"), timeoutMinutes: 2)])
        let runResult = await engine.runToEnd(wf.id)
        let run = try XCTUnwrap(runResult)
        XCTAssertEqual(run.status, .failed)
        XCTAssertEqual(run.results.first?.text, "Timed out after 2 min.")
        XCTAssertTrue(fake.cancelled, "the bot's turn is cancelled, so the app stops the chat")
    }

    func testStopEndsAWaitingRun() async throws {
        fake.answer = nil   // nobody answers
        let wf = try make([WorkflowStep(kind: .approval), WorkflowStep(kind: .output, target: .group("team"))])
        let id = try XCTUnwrap(engine.start(wf.id))
        for _ in 0..<100 where engine.run(id)?.status != .waiting { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(engine.run(id)?.status, .waiting)
        XCTAssertTrue(engine.isRunning(wf.id))
        XCTAssertNil(engine.start(wf.id), "one run of a workflow at a time")
        engine.stop(id)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(engine.run(id)?.status, .stopped)
        XCTAssertEqual(engine.run(id)?.note, "Stopped by you.")
        XCTAssertTrue(fake.posted.isEmpty)
        XCTAssertFalse(engine.isRunning(wf.id))
    }

    func testARunInterruptedByAQuitResumesWithItsInput() async throws {
        fake.hang = true
        let wf = try make([
            WorkflowStep(kind: .prompt, text: "Brief"),
            WorkflowStep(kind: .agent, text: "Write", target: .bot("writer")),
            WorkflowStep(kind: .output, target: .group("team")),
        ])
        let id = try XCTUnwrap(engine.start(wf.id))
        for _ in 0..<100 where engine.run(id)?.waitingOn == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(engine.run(id)?.waitingOn, "msg-1", "the step's message is remembered")

        // The app quits: a new engine loads from disk.
        let fake2 = FakeExecutor()
        let engine2 = WorkflowEngine(store: WorkStore(paths: paths), executor: fake2)
        fake2.engine = engine2
        engine2.load()
        let stopped = try XCTUnwrap(engine2.run(id))
        XCTAssertEqual(stopped.status, .stopped)
        XCTAssertEqual(stopped.resumeFrom, 1)
        XCTAssertEqual(engine2.resumableRuns.map(\.id), [id])
        engine.stop(id)   // the old one goes away

        // The reply had come in before the quit: it's used, not asked for again.
        fake2.finished["msg-1"] = AgentStepResult(ok: true, text: "Draft from before the quit")
        let doneResult = await engine2.resume(id, wait: true)
        let done = try XCTUnwrap(doneResult)
        XCTAssertEqual(done.status, .done)
        XCTAssertTrue(fake2.prompts.isEmpty)
        XCTAssertEqual(fake2.posted.map(\.1), ["Draft from before the quit"])
        XCTAssertNil(done.resumeFrom)
        let again = await engine2.resume(id)
        XCTAssertNil(again, "only once")
    }

    func testAResumedStepWithNoReplyIsSentAgainWithTheSameInput() async throws {
        var run = WorkflowRun(id: "r", workflowId: "w", name: "W", trigger: "x")
        run.status = .running
        run.current = 1
        run.carry = "Carried"
        run.waitingChat = "chat-writer"
        run.waitingOn = "old"
        let store = WorkStore(paths: paths)
        try store.save(Workflow(id: "w", name: "W", steps: [
            WorkflowStep(kind: .prompt, text: "Carried"), WorkflowStep(kind: .agent, text: "Write", target: .bot("writer")),
        ]))
        try store.save(run)
        engine.load()
        let doneResult = await engine.resume("r", wait: true)
        let done = try XCTUnwrap(doneResult)
        XCTAssertEqual(done.status, .done)
        XCTAssertEqual(fake.prompts.count, 1)
        XCTAssertTrue(fake.prompts[0].1.contains("Carried"))
    }

    func testScheduledWorkflowsUseRoutineTiming() throws {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        let created = ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z")!
        engine.clock = { created }
        fake.answer = nil
        let wf = try make([WorkflowStep(kind: .approval)], schedule: .daily(hour: 9, minute: 0, weekdaysOnly: false))
        _ = try make([WorkflowStep(kind: .approval)])   // by hand only
        let nine = ISO8601DateFormatter().date(from: "2026-11-17T09:05:00Z")!
        engine.clock = { nine }
        let started = engine.startDue(now: nine, calendar: c)
        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(engine.run(started[0])?.workflowId, wf.id)
        XCTAssertEqual(engine.run(started[0])?.trigger, "Every day at 09:00")
        XCTAssertTrue(engine.startDue(now: nine.addingTimeInterval(60), calendar: c).isEmpty, "already ran this slot")
        for id in started { engine.stop(id) }
    }

    func testTasksAreRecordedAndDismissed() throws {
        let task = engine.addTask("Fix the login bug", to: .bot("writer"), chatId: "c1", messageId: "m1")
        XCTAssertEqual(engine.status(of: task, history: [ChatMessage(id: "m1", role: .user, text: "Fix")], busy: false), .queued)
        engine.dismissTask(task.id)
        XCTAssertEqual(WorkStore(paths: paths).loadTasks().first?.dismissed, true)
        XCTAssertEqual(engine.log.last?.kind, .task)
    }

    func testDeletingAWorkflowStopsItsRun() async throws {
        fake.answer = nil
        let wf = try make([WorkflowStep(kind: .approval)])
        let id = try XCTUnwrap(engine.start(wf.id))
        for _ in 0..<100 where engine.run(id)?.status != .waiting { try await Task.sleep(nanoseconds: 5_000_000) }
        engine.deleteWorkflow(wf.id)
        XCTAssertEqual(engine.run(id)?.status, .stopped)
        XCTAssertEqual(engine.run(id)?.note, "The workflow was deleted.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.workflowFile(wf.id).path))
    }
}
