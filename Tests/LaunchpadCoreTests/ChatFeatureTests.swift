import XCTest
@testable import LaunchpadCore

final class ChatFeatureTests: XCTestCase {
    var paths: LaunchpadPaths!
    let fm = FileManager.default
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        paths = LaunchpadPaths(root: fm.temporaryDirectory.appendingPathComponent("lp-feat-\(UUID().uuidString)"))
        try paths.ensureStructure()
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: paths.root)
    }

    // MARK: Message fields

    func testOldHistoryStillDecodesAndNewFieldsRoundTrip() throws {
        let old = #"{"createdAt":"2026-11-01T10:00:00Z","id":"m1","role":"user","status":"done","steps":[],"text":"hi"}"#
        let m = try JSONCoding.decoder().decode(ChatMessage.self, from: Data(old.utf8))
        XCTAssertNil(m.reactions)
        XCTAssertNil(m.poll)

        var full = ChatMessage(id: "m2", role: .bot, botId: "b", text: "x", createdAt: t0)
        full.reactions = ["👍": ["you", "b"]]
        full.pinned = true
        full.saved = true
        full.edits = [MessageEdit(text: "old", replacedAt: t0)]
        full.attachments = ["/tmp/a.png"]
        full.forwardedFrom = "Planner"
        full.gif = GifRef(url: "https://g/1.gif", width: 200, height: 100, title: "Yay")
        full.poll = Poll(question: "Q", options: ["A", "B"], votes: ["you": 1])
        full.plan = PlanCard(message: "On it", steps: ["a"], shownAt: t0, autoStart: 10)
        full.questions = QuestionCard(items: [.init(text: "Q?", options: ["y", "n"])])
        let back = try JSONCoding.decoder().decode(ChatMessage.self, from: JSONCoding.lineEncoder().encode(full))
        XCTAssertEqual(back, full)
    }

    func testStoreUpdateAppendsAndLatestWins() throws {
        let store = ChatStore(paths: paths)
        let m = ChatMessage(id: "m1", role: .user, text: "Ship it?", createdAt: t0)
        try store.append(m, chatId: "c")
        try store.append(ChatMessage(id: "m2", role: .bot, botId: "b", text: "Yes", createdAt: t0), chatId: "c")
        let reacted = try store.update(messageId: "m1", chatId: "c") { ChatOps.toggleReaction($0, emoji: "🚀") }
        XCTAssertEqual(reacted?.reactions, ["🚀": ["you"]])
        _ = try store.update(messageId: "m2", chatId: "c") { ChatOps.toggleSave($0) }
        XCTAssertNil(try store.update(messageId: "nope", chatId: "c") { $0 })
        XCTAssertNil(try store.update(messageId: "m1", chatId: "c") { ChatOps.edit($0, to: "Ship it?") })
        let all = store.messages(chatId: "c")
        XCTAssertEqual(all.map(\.id), ["m1", "m2"], "order kept")
        XCTAssertEqual(all[0].reactions, ["🚀": ["you"]])
        XCTAssertEqual(store.savedMessages(chatIds: ["c", "missing"]).map(\.message.id), ["m2"])
        let lines = try String(contentsOf: paths.chatLog("c"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 4)
    }

    // MARK: Ops

    func testReactions() {
        var m = ChatMessage(role: .user, text: "hi")
        m = ChatOps.toggleReaction(m, emoji: "👍🏽 ")
        m = ChatOps.toggleReaction(m, emoji: "❤️", by: "planner")
        m = ChatOps.react(m, emoji: "👍🏽", by: "planner")
        m = ChatOps.react(m, emoji: "👍🏽", by: "planner")
        XCTAssertEqual(m.reactions?["👍🏽"], ["you", "planner"])
        XCTAssertEqual(ChatOps.reactions(of: m).map(\.emoji), ["👍🏽", "❤️"])
        m = ChatOps.toggleReaction(m, emoji: "❤️", by: "planner")
        m = ChatOps.toggleReaction(m, emoji: "👍🏽")
        m = ChatOps.toggleReaction(m, emoji: "👍🏽", by: "planner")
        XCTAssertNil(m.reactions)
        XCTAssertEqual(ChatOps.toggleReaction(m, emoji: "  "), m)
    }

    func testPinSaveEditDelete() throws {
        var m = ChatMessage(id: "m", role: .user, text: "Draft one", createdAt: t0)
        m = ChatOps.togglePin(ChatOps.toggleSave(m))
        XCTAssertEqual(m.pinned, true)
        XCTAssertEqual(ChatOps.pinned([m]).count, 1)
        XCTAssertNil(ChatOps.togglePin(m).pinned)

        let e1 = try XCTUnwrap(ChatOps.edit(m, to: "  Draft two ", at: t0))
        let e2 = try XCTUnwrap(ChatOps.edit(e1, to: "Draft three", at: t0.addingTimeInterval(5)))
        XCTAssertEqual(e2.text, "Draft three")
        XCTAssertEqual(e2.edits?.map(\.text), ["Draft one", "Draft two"])
        XCTAssertTrue(ChatOps.isEdited(e2))
        XCTAssertNil(ChatOps.edit(e2, to: "Draft three"))
        XCTAssertNil(ChatOps.edit(e2, to: "  "))

        var rich = e2
        rich.poll = Poll(question: "Q", options: ["a", "b"])
        rich.reactions = ["👍": ["you"]]
        let gone = ChatOps.delete(rich)
        XCTAssertEqual(gone.id, "m")
        XCTAssertEqual(gone.deleted, true)
        XCTAssertEqual(gone.text, "")
        XCTAssertNil(gone.poll); XCTAssertNil(gone.edits); XCTAssertNil(gone.reactions); XCTAssertNil(gone.pinned)
        XCTAssertNil(ChatOps.edit(gone, to: "back"))
        XCTAssertEqual(ChatOps.toggleReaction(gone, emoji: "👍"), gone)
        XCTAssertTrue(ChatOps.pinned([gone]).isEmpty)
        XCTAssertEqual(ChatOps.summary(gone), "Deleted message")
    }

    func testForward() throws {
        var src = ChatMessage(role: .bot, botId: "planner", text: "Here's the plan", createdAt: t0)
        src.attachments = ["/x/plan.pdf"]
        src.reactions = ["👍": ["you"]]
        let f = try XCTUnwrap(ChatOps.forward(src, fromName: "Planner", at: t0, newId: "new"))
        XCTAssertEqual(f.id, "new")
        XCTAssertEqual(f.role, .user)
        XCTAssertEqual(f.forwardedFrom, "Planner")
        XCTAssertEqual(f.attachments, ["/x/plan.pdf"])
        XCTAssertNil(f.reactions)
        XCTAssertEqual(ChatOps.forwardPrompt(f), "Forwarded from Planner:\nHere's the plan\n\nAttached file (copied to your folder):\n- /x/plan.pdf")
        var poll = ChatMessage(role: .bot, text: "")
        poll.poll = Poll(question: "Lunch?", options: ["Pizza", "Sushi"])
        XCTAssertEqual(ChatOps.forward(poll, fromName: "B")?.text, "Poll: Lunch?\n1. Pizza\n2. Sushi")
        XCTAssertNil(ChatOps.forward(ChatOps.delete(src), fromName: "B"))
        XCTAssertNil(ChatOps.forward(ChatMessage(role: .bot, text: ""), fromName: "B"))
    }

    func testSummaryAndContext() {
        var m = ChatMessage(role: .bot, text: "")
        m.gif = GifRef(url: "u", width: 1, height: 1, title: "Party")
        XCTAssertEqual(ChatOps.summary(m), "GIF: Party")
        m.attachments = ["/a/b/report.pdf", "/a/c.png"]
        XCTAssertEqual(ChatOps.contextText(m), "(sent a GIF: Party)\n(attached: /a/b/report.pdf, /a/c.png)")
        m.gif = nil
        XCTAssertEqual(ChatOps.summary(m), "📎 report.pdf and 1 more")
    }

    func testPolls() throws {
        XCTAssertNil(ChatOps.makePoll(question: " ", options: ["a", "b"]))
        XCTAssertNil(ChatOps.makePoll(question: "Q", options: ["a", " "]))
        let p = try XCTUnwrap(ChatOps.makePoll(question: "Q", options: (1...10).map { "o\($0)" }))
        XCTAssertEqual(p.options.count, 8)
        var v = try XCTUnwrap(ChatOps.vote(p, by: "you", option: 1))
        v = try XCTUnwrap(ChatOps.vote(v, by: "b", option: 1, reason: String(repeating: "x", count: 200)))
        v = try XCTUnwrap(ChatOps.vote(v, by: "a", option: 0))
        XCTAssertNil(ChatOps.vote(v, by: "a", option: 8))
        XCTAssertEqual(v.counts.prefix(2), [1, 2])
        XCTAssertEqual(v.voters(1), ["you", "b"])
        XCTAssertEqual(v.reasons?["b"]?.count, 140)
        XCTAssertEqual(ChatOps.youVotedPrompt(v, option: 1), "(I voted “o2” in your poll: Q.)")
        XCTAssertTrue(ChatOps.askToVotePrompt(p).contains("1. o1\n2. o2"))
    }

    func testPlanCardCountdown() {
        let card = PlanCard(message: "m", steps: [], shownAt: t0, autoStart: 10)
        XCTAssertEqual(card.secondsLeft(now: t0.addingTimeInterval(3.2)), 7)
        XCTAssertFalse(card.isDue(now: t0.addingTimeInterval(9.5)))
        XCTAssertTrue(card.isDue(now: t0.addingTimeInterval(11)))
        XCTAssertNil(PlanCard(message: "m", steps: [], shownAt: t0).secondsLeft(now: t0))
        let started = ChatOps.answerPlan(card, start: true)
        XCTAssertEqual(started?.state, .started)
        XCTAssertNil(started?.secondsLeft(now: t0))
        XCTAssertNil(ChatOps.answerPlan(started!, start: false))
        XCTAssertEqual(ChatOps.answerPlan(card, start: false)?.state, .cancelled)
        XCTAssertEqual(PlanWait.title(30), "Start after 30 seconds")
        XCTAssertEqual(PlanWait.title(0), "Wait for my OK")
    }

    func testQuestionCards() throws {
        let card = QuestionCard(items: [.init(text: "Colour?", options: ["Blue", "Green"]), .init(text: "Size?", options: ["S", "M"])])
        XCTAssertNil(ChatOps.answer(card, with: ["Blue"]))
        XCTAssertNil(ChatOps.answer(card, with: ["Blue", " "]))
        let (done, prompt) = try XCTUnwrap(ChatOps.answer(card, with: ["Blue", "M, maybe L"], mention: "designer"))
        XCTAssertEqual(prompt, "@designer Colour? Blue\nSize? M, maybe L")
        XCTAssertTrue(done.answered)
        XCTAssertNil(ChatOps.answer(done, with: ["a", "b"]))
    }

    // MARK: Applying chat actions

    func testApplierReactsVotesAndCollectsCards() throws {
        var poll = ChatMessage(id: "p", role: .user, text: "", createdAt: t0)
        poll.poll = Poll(question: "Lunch?", options: ["Pizza", "Sushi"])
        let mine = ChatMessage(id: "u", role: .user, text: "Let's go", createdAt: t0)
        let history = [poll, ChatMessage(id: "b0", role: .bot, botId: "x", text: "hmm"), mine]
        let routine = RoutineRequest(name: "R", target: "bot:x", message: "m", trigger: .init(type: "hourly"))
        let actions: [ChatAction] = [
            .react("🎉"), .react("🎉"), .react("👍"), .vote(2, reason: "Fresh"), .vote(9), .gif("party"),
            .poll("Next?", ["A", "B"]), ChatAction(tool: .askUser, questions: [.init(text: "Q?", options: ["a", "b"])]),
            ChatAction(tool: .sharePlan, at: t0, message: "Building", steps: ["one"]),
            ChatAction(tool: .createRoutine, routine: routine),
        ]
        let r = ChatActionApplier.apply(actions, extras: ChatReplyExtras(), history: history, botId: "planner", planWait: 30)
        XCTAssertEqual(r.changed.map(\.id), ["u", "p"])
        XCTAssertEqual(r.changed[0].reactions, ["🎉": ["planner"], "👍": ["planner"]])
        XCTAssertEqual(r.changed[1].poll?.votes, ["planner": 1])
        XCTAssertEqual(r.changed[1].poll?.reasons, ["planner": "Fresh"])
        XCTAssertEqual(r.gifSearches, ["party"])
        XCTAssertEqual(r.extras.poll?.question, "Next?")
        XCTAssertEqual(r.extras.questions?.items.first?.text, "Q?")
        XCTAssertEqual(r.extras.plan, PlanCard(message: "Building", steps: ["one"], shownAt: t0, autoStart: 30))
        XCTAssertTrue(r.planShown && r.questionsShown)
        XCTAssertEqual(r.routines, [routine])

        var reply = ChatMessage(role: .bot, botId: "planner", text: "Done")
        r.extras.merge(into: &reply)
        XCTAssertNotNil(reply.plan)
        XCTAssertNotNil(reply.poll)

        // Nothing to react to or vote in: nothing changes.
        let none = ChatActionApplier.apply([.react("🎉"), .vote(1)], extras: ChatReplyExtras(), history: [], botId: "b", planWait: 0)
        XCTAssertTrue(none.changed.isEmpty)
        XCTAssertTrue(none.extras.isEmpty)
    }

    func testChatTokens() {
        let text = "Great idea!\n[react: 🎉]\n\nHere you go. [gif: high five]\n[poll: Lunch? | Pizza | Sushi]\n`[react: 👎]`"
        let (clean, actions) = ChatTokens.extract(from: text)
        XCTAssertEqual(actions.map(\.tool), [.react, .sendGif, .startPoll])
        XCTAssertEqual(actions[2].options, ["Pizza", "Sushi"])
        XCTAssertEqual(clean, "Great idea!\n\n\nHere you go. \n\n`[react: 👎]`".replacingOccurrences(of: "\n\n\n", with: "\n\n"))
        let vote = ChatTokens.extract(from: "Sushi is lighter.\n[vote: 2]")
        XCTAssertEqual(vote.actions.first?.option, 2)
        XCTAssertEqual(vote.actions.first?.reason, "Sushi is lighter.")
        XCTAssertEqual(vote.text, "Sushi is lighter.")
        XCTAssertEqual(ChatTokens.extract(from: "a [poll: only] b").actions, [])
        XCTAssertEqual(ChatTokens.extract(from: "plain").text, "plain")
    }

    // MARK: Giphy

    func testGiphyURLAndParsing() async throws {
        let url = try XCTUnwrap(GiphySearch.url(query: " high five ", key: "K", limit: 99))
        let c = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(c.host, "api.giphy.com")
        XCTAssertEqual(c.path, "/v1/gifs/search")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).map { ($0.name, $0.value ?? "") }),
                       ["api_key": "K", "q": "high five", "limit": "50", "rating": "g"])
        XCTAssertNil(GiphySearch.url(query: " ", key: "K"))
        XCTAssertNil(GiphySearch.url(query: "x", key: ""))

        let body = """
        {"data":[{"id":"abc","title":"High Five GIF","images":{"fixed_height":{"url":"https://media.giphy.com/abc/200.gif","width":"356","height":"200"},
          "fixed_width_small":{"url":"https://media.giphy.com/abc/100w.gif"}}},
          {"id":"broken","images":{}},
          {"id":"def","title":" ","images":{"fixed_height":{"url":"https://media.giphy.com/def/200.gif"}}}],"meta":{"status":200}}
        """
        let results = GiphySearch.parse(Data(body.utf8))
        XCTAssertEqual(results.map(\.id), ["abc", "def"])
        XCTAssertEqual(results[0].gif, GifRef(url: "https://media.giphy.com/abc/200.gif", width: 356, height: 200,
                                              title: "High Five GIF", preview: "https://media.giphy.com/abc/100w.gif"))
        XCTAssertNil(results[1].gif.title)
        XCTAssertEqual(results[1].gif.width, 200)
        XCTAssertEqual(GiphySearch.parse(Data("nope".utf8)), [])

        let secrets = MemorySecretStore()
        let noKey = await GiphySearch.search("x", secrets: secrets) { _ in XCTFail("no key, no request"); return Data() }
        XCTAssertEqual(noKey, [])
        try secrets.setSecret(" KEY \n", for: GiphySearch.keyAccount)
        let found = await GiphySearch.search("cats", secrets: secrets, limit: 1) { url in
            XCTAssertTrue(url.absoluteString.contains("api_key=KEY"))
            return Data(body.utf8)
        }
        XCTAssertEqual(found.first?.id, "abc")
        secrets.failing[GiphySearch.keyAccount] = "locked"
        XCTAssertNil(GiphySearch.key(from: secrets))
    }

    // MARK: Pacing

    func testSplitIntoTexts() {
        XCTAssertEqual(TextPacing.split("Hey!\n\nI looked at it.\n\nAll good."), ["Hey!", "I looked at it.", "All good."])
        XCTAssertNil(TextPacing.split("One paragraph only."))
        XCTAssertNil(TextPacing.split("a\n\nb\n\nc\n\nd\n\ne"))
        XCTAssertNil(TextPacing.split("Steps:\n\n- one\n- two"))
        XCTAssertNil(TextPacing.split("Steps:\n\n1. one\n2. two"))
        XCTAssertNil(TextPacing.split("# Title\n\nBody"))
        XCTAssertNil(TextPacing.split("Code:\n\n```\nx\n```"))
        XCTAssertNil(TextPacing.split("a\n\n" + String(repeating: "x", count: 400)))

        var m = ChatMessage(id: "r", role: .bot, botId: "b", text: "Hey!\n\nAll good.", createdAt: t0, costUSD: 0.1)
        m.gif = GifRef(url: "g", width: 1, height: 1)
        let parts = TextPacing.splitIntoTexts(m, newId: { "n" })
        XCTAssertEqual(parts.map(\.id), ["r", "n"])
        XCTAssertEqual(parts.map(\.text), ["Hey!", "All good."])
        XCTAssertNil(parts[0].gif)
        XCTAssertEqual(parts[1].gif?.url, "g")
        XCTAssertEqual(parts[0].costUSD, 0.1)
        XCTAssertGreaterThan(parts[1].createdAt, t0)
        var withPoll = m
        withPoll.poll = Poll(question: "q", options: ["a", "b"])
        XCTAssertEqual(TextPacing.splitIntoTexts(withPoll), [withPoll])
        var mine = m
        mine.role = .user
        XCTAssertEqual(TextPacing.splitIntoTexts(mine), [mine])
    }
}
