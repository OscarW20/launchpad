import XCTest
@testable import LaunchpadCore

final class AskTests: XCTestCase {
    // MARK: Finding an ask

    func testNeedsYouBlockWithChoices() {
        let text = """
        Backend report: I added the tables, wrote the policies, ran the migrations on a branch and checked every query.
        Everything is in `supabase/migrations/`.

        **Needs you**
        @oscar which Google project should sign-in use?
        - story-led-shorts
        - a new project
        """
        let ask = AskParser.parse(text)
        XCTAssertEqual(ask, ParsedAsk(text: "which Google project should sign-in use?", choices: ["story-led-shorts", "a new project"]))
    }

    func testALineStartingWithTheMentionIsAnAsk() {
        XCTAssertEqual(AskParser.parse("All done.\n\n@oscar can I push to main?"), ParsedAsk(text: "can I push to main?", choices: []))
        XCTAssertEqual(AskParser.parse("@Oscar: please approve the deploy"), ParsedAsk(text: "please approve the deploy", choices: []))
        XCTAssertEqual(AskParser.parse("**@oscar** — add the Jira site"), ParsedAsk(text: "add the Jira site", choices: []))
        XCTAssertEqual(AskParser.parse("> @oscar quoted ask"), ParsedAsk(text: "quoted ask", choices: []))
        XCTAssertEqual(AskParser.parse("- @oscar listed ask"), ParsedAsk(text: "listed ask", choices: []))
    }

    func testChoiceStyles() {
        let numbered = AskParser.parse("@oscar pick one:\n1. red\n2) green\n3. blue")
        XCTAssertEqual(numbered?.choices, ["red", "green", "blue"])
        let lettered = AskParser.parse("@oscar pick one:\nA. fast\nb) cheap\n(c) good")
        XCTAssertEqual(lettered?.choices, ["fast", "cheap", "good"])
        let bullets = AskParser.parse("@oscar pick one:\n* one\n• two\n- three")
        XCTAssertEqual(bullets?.choices, ["one", "two", "three"])
        XCTAssertEqual(AskParser.parse("@oscar pick:\n- **bold** choice")?.choices, ["bold choice"])
    }

    func testAListSetApartByABlankLineStillBelongsToTheAsk() {
        let ask = AskParser.parse("Report text.\n\n@oscar which one?\n\n- first\n- second\n\nThanks!")
        XCTAssertEqual(ask, ParsedAsk(text: "which one?", choices: ["first", "second"]))
    }

    func testAnAskCanRunOverSeveralLines() {
        let ask = AskParser.parse("@oscar I need the Jira site\nand the assignee list\n- BIS\n- ENG")
        XCTAssertEqual(ask, ParsedAsk(text: "I need the Jira site and the assignee list", choices: ["BIS", "ENG"]))
    }

    func testHeadingWithoutAMentionStillCounts() {
        XCTAssertEqual(AskParser.parse("Done.\n\nNeeds you: approve the migration"), ParsedAsk(text: "approve the migration", choices: []))
        XCTAssertEqual(AskParser.parse("Done.\n\n## Needs you\n\nApprove the migration?\n- yes\n- no"),
                       ParsedAsk(text: "Approve the migration?", choices: ["yes", "no"]))
        XCTAssertEqual(AskParser.parse("Done.\n\n**Needs you**\n- Option A\n- Option B")?.choices, ["Option A", "Option B"])
    }

    // MARK: What isn't an ask

    func testAMentionInTheMiddleOfASentenceIsOnlyAMention() {
        XCTAssertNil(AskParser.parse("Thanks @oscar for the review, merged."))
        XCTAssertNil(AskParser.parse("cc @oscar"))
        XCTAssertNil(AskParser.parse("The report is above.\nAs @oscar asked, the cap is 60."))
        XCTAssertNil(AskParser.parse("I need your help with this"))
        XCTAssertNil(AskParser.parse("This needs your approval first"))
        XCTAssertNil(AskParser.parse("No ask here, just a long report.\n\n- point one\n- point two"))
        XCTAssertNil(AskParser.parse(""))
    }

    func testOtherPeopleAndLongerNamesAreNotYou() {
        XCTAssertNil(AskParser.parse("@oscars can you look?"))
        XCTAssertNil(AskParser.parse("@oscar-2 can you look?"))
        XCTAssertNil(AskParser.parse("@tester please run the suite"))
        XCTAssertNil(AskParser.parse("@oscar"))                      // nothing asked
    }

    func testCodeIsIgnored() {
        XCTAssertNil(AskParser.parse("Example:\n```\n@oscar do the thing\n```\nDone."))
        XCTAssertEqual(AskParser.parse("```\n@oscar not this\n```\n\n@oscar this one")?.text, "this one")
    }

    func testTheLastAskWinsAndBlankLinesEndIt() {
        let ask = AskParser.parse("@oscar first ask\n\nsome more report\n\n@oscar the real ask\n- yes\n- no\n\nTail text.")
        XCTAssertEqual(ask, ParsedAsk(text: "the real ask", choices: ["yes", "no"]))
    }

    func testOtherHandles() {
        XCTAssertNil(AskParser.parse("@ozzy ready?"))
        XCTAssertEqual(AskParser.parse("@ozzy ready?", handles: ["oscar", "ozzy"])?.text, "ready?")
        XCTAssertEqual(AskParser.handles(forFullName: "Oscar Whelan"), ["oscar"])
        XCTAssertEqual(AskParser.handles(forFullName: "Ozzy Whelan"), ["oscar", "ozzy"])
        XCTAssertEqual(AskParser.handles(forFullName: nil), ["oscar"])
    }

    func testLengthsAreCapped() {
        let long = String(repeating: "x", count: 5000)
        let ask = AskParser.parse("@oscar \(long)\n" + (1...20).map { "- choice \($0)" }.joined(separator: "\n"))
        XCTAssertEqual(ask?.text.count, 600)
        XCTAssertEqual(ask?.choices.count, 8)
    }

    // MARK: Splitting the report from the ask

    func testSplitSeparatesTheReportFromTheAsk() {
        let text = "Long report line one.\nLine two.\n\n**Needs you**\n@oscar approve the deploy?\n- yes\n- no"
        let (report, ask) = AskParser.split(text)
        XCTAssertEqual(report, "Long report line one.\nLine two.")
        XCTAssertEqual(ask, ParsedAsk(text: "approve the deploy?", choices: ["yes", "no"]))
        let plain = AskParser.split("Just a report, @oscar thanks.")
        XCTAssertEqual(plain.report, "Just a report, @oscar thanks.")
        XCTAssertNil(plain.ask)
        // Report text after the ask is kept too.
        XCTAssertEqual(AskParser.split("Top.\n\n@oscar question?\n\nBottom.").report, "Top.\n\nBottom.")
    }

    // MARK: Open and done

    private func bot(_ text: String, id: String = UUID().uuidString, at: TimeInterval = 0, status: MessageStatus = .done) -> ChatMessage {
        var m = ChatMessage(id: id, role: .bot, botId: "backend", text: text, status: status)
        m.createdAt = Date(timeIntervalSince1970: at)
        return m
    }

    private func user(_ text: String = "ok") -> ChatMessage { ChatMessage(role: .user, text: text) }

    func testAnAskIsOpenUntilYouReplyAfterIt() {
        let ask = bot("Done.\n\n@oscar pick one:\n- a\n- b", id: "m1")
        XCTAssertEqual(AskBook.open(in: [user("go"), ask], chatId: "c").map(\.messageId), ["m1"])
        XCTAssertEqual(AskBook.open(in: [user("go"), ask], chatId: "c").first?.ask.choices, ["a", "b"])
        XCTAssertEqual(AskBook.open(in: [user("go"), ask, user("a")], chatId: "c"), [])          // you answered
        XCTAssertEqual(AskBook.open(in: [user("go"), ask, bot("working on it")], chatId: "c").count, 1)   // a bot talking isn't you
    }

    func testOnlyTheLatestAskIsOpenOnceYouHaveReplied() {
        let first = bot("@oscar first?", id: "m1"), second = bot("@oscar second?", id: "m2")
        let open = AskBook.open(in: [first, user("yes"), second], chatId: "c")
        XCTAssertEqual(open.map(\.messageId), ["m2"])
        XCTAssertEqual(AskBook.open(in: [first, second], chatId: "c").map(\.messageId), ["m1", "m2"])
    }

    func testMarkedDoneAndUnfinishedAndNonBotMessagesAreNotOpen() {
        let ask = bot("@oscar approve?", id: "m1")
        XCTAssertEqual(AskBook.open(in: [ask], chatId: "c", done: ["m1"]), [])
        XCTAssertEqual(AskBook.open(in: [bot("@oscar approve?", status: .streaming)], chatId: "c"), [])
        XCTAssertEqual(AskBook.open(in: [bot("@oscar approve?", status: .failed)], chatId: "c"), [])
        // Your own message, or a notice, that happens to start with @oscar isn't an ask of you.
        XCTAssertEqual(AskBook.open(in: [ChatMessage(role: .user, text: "@oscar note to self")], chatId: "c"), [])
        XCTAssertEqual(AskBook.open(in: [ChatMessage(role: .notice, text: "@oscar notice")], chatId: "c"), [])
    }

    func testNoticeText() {
        XCTAssertEqual(AskBook.notice(ParsedAsk(text: "approve the deploy?", choices: [])), "Needs you: approve the deploy?")
        XCTAssertEqual(AskBook.notice(ParsedAsk(text: "", choices: ["yes", "no"])), "Needs you: yes")
        XCTAssertEqual(AskBook.notice(ParsedAsk(text: String(repeating: "a", count: 300), choices: [])).count, "Needs you: ".count + 120)
        XCTAssertTrue(AskBook.notice(ParsedAsk(text: String(repeating: "a", count: 300), choices: [])).hasSuffix("…"))
    }

    // MARK: Across chats

    var paths: LaunchpadPaths!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lp-asks-\(UUID().uuidString)")
        paths = LaunchpadPaths(root: root)
        try paths.ensureStructure()
    }

    override func tearDown() { try? FileManager.default.removeItem(at: paths.root) }

    private func chat(_ title: String, botId: String? = nil, groupId: String? = nil, ago: TimeInterval = 0, _ messages: [ChatMessage]) throws -> ChatMeta {
        let store = ChatStore(paths: paths)
        let meta = ChatMeta(title: title, kind: groupId == nil ? .bot : .group, botId: botId, groupId: groupId,
                            updatedAt: Date().addingTimeInterval(-ago))
        try store.save(meta)
        for m in messages { try store.append(m, chatId: meta.id) }
        return meta
    }

    func testTheInboxListsOpenAsksNewestFirstAcrossChats() throws {
        let a = try chat("A", botId: "backend", [user("go"), bot("@oscar older?", id: "a1", at: 100)])
        let b = try chat("B", botId: "tester", [user("go"), bot("@oscar newer?", id: "b1", at: 200)])
        _ = try chat("C", botId: "lead", [user("go"), bot("@oscar answered?", id: "c1", at: 300), user("yes")])
        _ = try chat("D", botId: "lead", [bot("No ask here, thanks @oscar", id: "d1", at: 400)])
        let inbox = AskInbox(paths: paths)
        let open = inbox.open()
        XCTAssertEqual(open.map(\.messageId), ["b1", "a1"])
        XCTAssertEqual(Set(open.map(\.chatId)), [a.id, b.id])
        XCTAssertEqual(open.first?.ask.text, "newer?")
        XCTAssertEqual(open.first?.botId, "backend")
    }

    func testMarkingDoneIsKeptWhereBotsCannotWriteAndCanBeUndone() throws {
        _ = try chat("A", botId: "backend", [bot("@oscar approve?", id: "a1")])
        let inbox = AskInbox(paths: paths)
        let ask = try XCTUnwrap(inbox.open().first)
        try inbox.markDone(ask)
        XCTAssertEqual(inbox.open(), [])
        XCTAssertEqual(AskStore(paths: paths).done(), ["a1"])
        let store = AskStore(paths: paths)
        XCTAssertTrue(store.file.path.hasPrefix(paths.launchpadData.path + "/"))
        XCTAssertTrue(GuardRulesFile.config(for: Bot(id: "x", name: "X"), paths: paths).protected.contains(store.file.path))
        try inbox.markOpen(ask)
        XCTAssertEqual(inbox.open().count, 1)
        try Data("not json".utf8).write(to: store.file)
        XCTAssertEqual(store.done(), [])                                   // unreadable means nothing is marked
    }

    func testTheInboxIsScopedToAWorkspaceAndCountsPerWorkspace() throws {
        let bots = BotStore(paths: paths), groups = GroupStore(paths: paths), spaces = WorkspaceStore(paths: paths)
        let loner = try bots.create(name: "Lou"), member = try bots.create(name: "Mia")
        let g = try groups.create(name: "Team", members: [member.id], lead: member.id)
        try spaces.create(name: "Biscuit")
        try spaces.move(group: g.id, to: "biscuit")                         // the group chat is now in Biscuit
        _ = try chat("Lou", botId: loner.id, [bot("@oscar in general?", id: "l1", at: 10)])
        _ = try chat("#Team", groupId: g.id, [bot("@oscar in biscuit?", id: "t1", at: 20)])
        _ = try chat("Mia", botId: member.id, [bot("@oscar also biscuit?", id: "m1", at: 30)])
        let inbox = AskInbox(paths: paths)
        XCTAssertEqual(inbox.open(workspace: "biscuit").map(\.messageId), ["m1", "t1"])
        XCTAssertEqual(inbox.open(workspace: "general").map(\.messageId), ["l1"])
        XCTAssertEqual(inbox.open(workspace: "nope"), [])
        XCTAssertEqual(inbox.open().count, 3)
        XCTAssertEqual(inbox.counts(), ["biscuit": 2, "general": 1])
        try inbox.markDone(try XCTUnwrap(inbox.open(workspace: "biscuit").first))
        XCTAssertEqual(inbox.counts(), ["biscuit": 1, "general": 1])
    }

    func testOldChatsAreSkippedAndASettledInboxIsEmpty() throws {
        _ = try chat("Old", botId: "backend", ago: 30 * 24 * 3600, [bot("@oscar ancient?", id: "o1")])
        _ = try chat("New", botId: "backend", ago: 3600, [bot("@oscar recent?", id: "n1")])
        let inbox = AskInbox(paths: paths)
        XCTAssertEqual(inbox.open().map(\.messageId), ["n1"])
        XCTAssertEqual(inbox.open(maxAge: 60 * 24 * 3600).count, 2)
        XCTAssertEqual(AskInbox(paths: LaunchpadPaths(root: paths.root.appendingPathComponent("empty"))).open(), [])
    }
}
