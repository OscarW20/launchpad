import XCTest
@testable import LaunchpadCore

final class AskByNameTests: XCTestCase {
    // MARK: Addressed by name

    func testAskedByNameInTheLastParagraph() {
        let text = """
        Tester report: I ran the sign-up flow end to end and everything worked up to the confirmation step.

        **Oscar, please open the confirmation email at oscarwhelan1+test@gmail.com and click the link.** I'll carry on after.
        """
        let ask = AskParser.parse(text)
        XCTAssertEqual(ask?.source, .byName)
        XCTAssertEqual(ask?.kind, .task)
        XCTAssertEqual(ask?.headline, "please open the confirmation email at oscarwhelan1+test@gmail.com and click the link.")
        XCTAssertEqual(ask?.detail, "I'll carry on after.")
    }

    func testTheWaysToAddressYou() {
        XCTAssertEqual(AskParser.parse("Done.\n\nOscar: which Google project should it use?")?.kind, .question)
        XCTAssertEqual(AskParser.parse("Done.\n\nOscar, which one?")?.text, "which one?")
        XCTAssertEqual(AskParser.parse("Done.\n\nOscar can you approve the deploy?")?.text, "can you approve the deploy?")
        XCTAssertEqual(AskParser.parse("Done.\n\nOscar please check the Jira site")?.text, "please check the Jira site")
        XCTAssertEqual(AskParser.parse("Done.\n\nOscar - should I push to main?")?.text, "should I push to main?")
        XCTAssertEqual(AskParser.parse("Done.\n\n\"Oscar, could you paste the key?\"")?.source, .byName)
        XCTAssertEqual(AskParser.parse("Done. Everything is merged. Oscar, can you try it in the app?")?.text, "can you try it in the app?")
    }

    func testChoicesUnderANameAskMakeItADecision() {
        let ask = AskParser.parse("All built.\n\nOscar, which colour should the badge be?\n- amber\n- blue")
        XCTAssertEqual(ask?.choices, ["amber", "blue"])
        XCTAssertEqual(ask?.kind, .decision)
        XCTAssertEqual(ask?.headline, "which colour should the badge be?")
        XCTAssertEqual(AskParser.parse("All built.\n\nOscar, which colour?\n\n- amber\n- blue")?.choices, ["amber", "blue"])
    }

    // MARK: Not asks

    func testMentionsThatAskForNothingAreNotAsks() {
        for text in ["Thanks Oscar.", "Thanks Oscar, merged.", "As Oscar said, the cap is 60.", "Oscar's review is in.", "Oscar said the cap is 60.",
                     "Oscar, thanks for the review.", "Oscar, here is the report.", "Oscar: done.", "cc Oscar", "oscarwhelan1+test@gmail.com signed up.",
                     "Saved to /Users/oscar/projects/app.", "Use `Oscar, please` in the template.", "Oscar, great work on the build."] {
            XCTAssertNil(AskParser.parse("Report.\n\n" + text), text)
        }
    }

    func testAnAskThatIsNotTheEndOfTheMessageIsAStatusLine() {
        // The shape of the screenshot: the ask sits in the middle, and the message goes on to say it was done.
        let text = """
        Waiting on the email.

        **Oscar, please open the confirmation email and click the link.**

        Confirmed. The link worked and the account is active. Moving on to the dashboard checks, which all passed.
        """
        XCTAssertNil(AskParser.parse(text))
        // The same ask as the last paragraph is open.
        XCTAssertNotNil(AskParser.parse("Waiting on the email.\n\n**Oscar, please open the confirmation email and click the link.**"))
    }

    func testFillerIsNotAnAsk() {
        for text in ["Oscar, let me know if you have any questions.", "Oscar, feel free to ask if anything is unclear.", "Oscar, hope this helps.",
                     "Oscar, let me know if there's anything else.", "Oscar: any questions?", "@oscar let me know if you have questions",
                     "Needs you: let me know if you have any concerns", "@oscar happy to help with anything else"] {
            XCTAssertNil(AskParser.parse("Report.\n\n" + text), text)
        }
        // Filler with real options isn't filler.
        XCTAssertNotNil(AskParser.parse("@oscar let me know if you want:\n- A\n- B"))
        // A real request that mentions "let me know" is kept.
        XCTAssertNotNil(AskParser.parse("@oscar let me know which option you prefer"))
    }

    func testExplicitAsksStillWinAndKeepTheirBehaviour() {
        let ask = AskParser.parse("Oscar, please check this.\n\n@oscar approve the deploy?\n- yes\n- no\n\nTail.")
        XCTAssertEqual(ask?.source, .explicit)
        XCTAssertEqual(ask?.text, "approve the deploy?")
        XCTAssertEqual(ask?.kind, .decision)
    }

    // MARK: Headline, detail and kind

    func testHeadlineIsTheFirstSentenceCutToTwentyWords() {
        let long = (1...30).map { "word\($0)" }.joined(separator: " ")
        let ask = ParsedAsk(text: long + ".")
        XCTAssertEqual(ask.headline.split(separator: " ").count, 20)
        XCTAssertTrue(ask.headline.hasSuffix("…"))
        XCTAssertEqual(ask.detail, long + ".")                              // the full text is still there for "More"
        let two = ParsedAsk(text: "Which database should it use? The staging one is faster but smaller.")
        XCTAssertEqual(two.headline, "Which database should it use?")
        XCTAssertEqual(two.detail, "The staging one is faster but smaller.")
        XCTAssertNil(ParsedAsk(text: "Just this.").detail)
        XCTAssertEqual(ParsedAsk(text: "", choices: ["a", "b"]).headline, "Pick one of the options")
        XCTAssertEqual(ParsedAsk(text: "Edit app.swift. Then reload.").headline, "Edit app.swift.")
    }

    func testKinds() {
        XCTAssertEqual(ParsedAsk(text: "pick one", choices: ["a", "b"]).kind, .decision)
        XCTAssertEqual(ParsedAsk(text: "which project should it use?").kind, .question)
        XCTAssertEqual(ParsedAsk(text: "can I push to main?").kind, .question)
        XCTAssertEqual(ParsedAsk(text: "please open the email and click the link").kind, .task)
        XCTAssertEqual(ParsedAsk(text: "can you open the email and click the link?").kind, .task)
        XCTAssertEqual(ParsedAsk(text: "paste the API key").kind, .task)
        XCTAssertEqual(ParsedAsk(text: "approve the deploy").kind, .task)
        XCTAssertEqual(ParsedAsk(text: "one choice only", choices: ["a"]).kind, .task)
    }

    func testButtonRepliesSaySomethingARealBotCanActOn() {
        let ask = ParsedAsk(text: "please open the confirmation email and click the link.")
        XCTAssertEqual(ask.doneReply, "Done: please open the confirmation email and click the link.")
        XCTAssertTrue(ask.declineReply.hasPrefix("I can't do this right now: "))
    }

    func testSplitLeavesTheReportWholeForAnAskByName() {
        let text = "Report line.\n\nOscar, please check the Jira site."
        let (report, ask) = AskParser.split(text)
        XCTAssertEqual(report, text)
        XCTAssertEqual(ask?.source, .byName)
    }

    // MARK: Open, and pinned

    private func bot(_ text: String, id: String, by botId: String = "tester") -> ChatMessage {
        ChatMessage(id: id, role: .bot, botId: botId, text: text, status: .done)
    }

    func testAnAskByNameClosesWhenTheSameBotGoesOnTalking() {
        let ask = bot("Done.\n\nOscar, please check the Jira site.", id: "m1")
        XCTAssertEqual(AskBook.open(in: [ask], chatId: "c").map(\.messageId), ["m1"])
        XCTAssertEqual(AskBook.open(in: [ask, bot("Carrying on with the next step.", id: "m2", by: "backend")], chatId: "c").count, 1)   // someone else
        XCTAssertEqual(AskBook.open(in: [ask, bot("Carrying on with the next step.", id: "m2")], chatId: "c"), [])                         // the same bot
        // An explicit ask is not closed by the bot talking: it asked, and is still waiting.
        let explicit = bot("Done.\n\n@oscar please check the Jira site.", id: "m1")
        XCTAssertEqual(AskBook.open(in: [explicit, bot("Carrying on.", id: "m2")], chatId: "c").count, 1)
        // Your reply closes either kind.
        XCTAssertEqual(AskBook.open(in: [ask, ChatMessage(role: .user, text: "done")], chatId: "c"), [])
    }

    func testThePinnedListIsOneChatsOpenAsksNewestLast() throws {
        let first = bot("Part one.\n\n@oscar first?", id: "m1", by: "lead")
        let second = bot("Part two.\n\n@oscar second?", id: "m2", by: "tester")
        let third = bot("Part three.\n\nOscar, which one?\n- a\n- b", id: "m3", by: "backend")
        let pinned = AskBook.pinned(in: [first, second, third], chatId: "c")
        XCTAssertEqual(pinned.map(\.messageId), ["m1", "m2", "m3"])
        XCTAssertEqual(pinned.last?.ask.kind, .decision)
        XCTAssertEqual(AskBook.pinned(in: [first, second, third], chatId: "c", done: ["m2"]).map(\.messageId), ["m1", "m3"])

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lp-pin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = LaunchpadPaths(root: root)
        try paths.ensureStructure()
        let chats = ChatStore(paths: paths)
        let meta = ChatMeta(title: "A", kind: .bot, botId: "tester")
        try chats.save(meta)
        for m in [first, second, third] { try chats.append(m, chatId: meta.id) }
        let other = ChatMeta(title: "B", kind: .bot, botId: "lead")
        try chats.save(other)
        try chats.append(bot("@oscar elsewhere?", id: "x1"), chatId: other.id)
        let inbox = AskInbox(paths: paths)
        XCTAssertEqual(inbox.pinned(chatId: meta.id).map(\.messageId), ["m1", "m2", "m3"])
        try inbox.markDone(try XCTUnwrap(inbox.pinned(chatId: meta.id).first))
        XCTAssertEqual(inbox.pinned(chatId: meta.id).map(\.messageId), ["m2", "m3"])
        XCTAssertEqual(inbox.pinned(chatId: "missing"), [])
    }
}
