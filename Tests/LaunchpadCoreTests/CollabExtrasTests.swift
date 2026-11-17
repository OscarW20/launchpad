import XCTest
@testable import LaunchpadCore

final class CollabExtrasTests: XCTestCase {
    var paths: LaunchpadPaths!
    let fm = FileManager.default

    override func setUpWithError() throws {
        paths = LaunchpadPaths(root: fm.temporaryDirectory.appendingPathComponent("lp-collab-\(UUID().uuidString)"))
        try paths.ensureStructure()
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: paths.root)
    }

    let planner = Bot(id: "planner", name: "Planner", role: "Plans the work")
    let researcher = Bot(id: "researcher", name: "Research Bot", role: "Finds sources")
    let designer = Bot(id: "designer", name: "Designer")

    // MARK: Collab

    func testActivityFeed() {
        var feed = ActivityFeed()
        feed.record(.started, bot: "planner", chat: "c", "**Working** on `x`\nnext line")
        XCTAssertEqual(feed.events.first?.text, "Working on x next line")
        for i in 0..<450 { feed.record(.step, bot: i % 2 == 0 ? "a" : "b", chat: "c", String(repeating: "y", count: 200)) }
        XCTAssertEqual(feed.events.count, ActivityFeed.limit)
        XCTAssertEqual(feed.events.last?.text.count, 161)
        XCTAssertEqual(feed.recent(3, bot: "b").count, 3)
        XCTAssertTrue(feed.recent(3, bot: "b").allSatisfy { $0.botId == "b" })
    }

    func testTeamNotes() throws {
        XCTAssertNil(TeamNotes.read(paths: paths))
        var line = TeamNotes.teamLine(for: planner, others: [planner, researcher], paths: paths)
        XCTAssertFalse(line.contains("TEAM.md"))
        XCTAssertTrue(line.contains("@researcher (Research Bot, Finds sources)"))
        XCTAssertFalse(line.contains("@planner"))
        try TeamNotes.ensure(paths: paths)
        XCTAssertTrue(paths.teamNotes.path.hasSuffix("Shared/TEAM.md"))
        XCTAssertEqual(TeamNotes.read(paths: paths), TeamNotes.template)
        try TeamNotes.save("# Mine", paths: paths)
        try TeamNotes.ensure(paths: paths)
        XCTAssertEqual(TeamNotes.read(paths: paths), "# Mine")
        line = TeamNotes.teamLine(for: planner, others: [], paths: paths)
        XCTAssertTrue(line.hasPrefix("Team notes everyone shares: \(paths.teamNotes.path)"))
    }

    func testHandOffAsks() {
        let text = """
        I'll draft it.
        @researcher: find three sources on solar
        **@Research Bot**: and a fourth
        @designer:
        @nobody: hello
        ```
        @designer: in code
        ```
        `@Designer: pick colours`
        """
        let asks = DirectHandOff.asks(in: text, among: [researcher, designer])
        XCTAssertEqual(asks.map(\.bot.id), ["researcher", "designer"])
        XCTAssertEqual(asks.map(\.request), ["find three sources on solar", "pick colours"])
    }

    func testHandOffFlow() throws {
        let team = [planner, researcher, designer]
        let reply = ChatMessage(role: .bot, botId: "planner", text: "On it.\n@researcher: find sources")
        let turns = DirectHandOff.next(after: reply, speaker: planner, kind: nil, owner: planner, team: team, hops: 0)
        XCTAssertEqual(turns.count, 1)
        let help = try XCTUnwrap(turns.first)
        XCTAssertEqual(help.botId, "researcher")
        XCTAssertEqual(help.kind, .helper(askedBy: "planner"))
        XCTAssertEqual(help.notice, "Planner asked Research Bot for help: find sources")
        XCTAssertTrue(help.prompt.contains("Answer Planner directly"))
        XCTAssertEqual(help.hops, 1)

        let answer = ChatMessage(role: .bot, botId: "researcher", text: "Here are 3 sources.\n@designer: also do this")
        let back = DirectHandOff.next(after: answer, speaker: researcher, kind: help.kind, owner: planner, team: team, hops: 1)
        XCTAssertEqual(back.map(\.botId), ["planner"], "a helper's answer goes back; helpers don't hand on")
        XCTAssertTrue(back[0].prompt.hasPrefix("Research Bot answered your question:\nHere are 3 sources."))

        // Limits: hops, failures, pending approvals, and replies from bots you asked yourself (reviews).
        XCTAssertTrue(DirectHandOff.next(after: reply, speaker: planner, kind: nil, owner: planner, team: team, hops: 4).isEmpty)
        var failed = reply
        failed.status = .failed
        XCTAssertTrue(DirectHandOff.next(after: failed, speaker: planner, kind: nil, owner: planner, team: team, hops: 0).isEmpty)
        var asking = reply
        asking.approval = ApprovalRequest(action: "deploy")
        XCTAssertTrue(DirectHandOff.next(after: asking, speaker: planner, kind: nil, owner: planner, team: team, hops: 0).isEmpty)
        XCTAssertTrue(DirectHandOff.next(after: answer, speaker: researcher, kind: nil, owner: planner, team: team, hops: 0).isEmpty)
        // The owner can't ask itself.
        let selfAsk = ChatMessage(role: .bot, botId: "planner", text: "@planner: do it")
        XCTAssertTrue(DirectHandOff.next(after: selfAsk, speaker: planner, kind: nil, owner: planner, team: team, hops: 0).isEmpty)
    }

    func testReviewAndHuddle() {
        XCTAssertTrue(ReviewRequest.prompt(authorName: "Planner", text: "The plan").hasSuffix("---\nThe plan"))
        XCTAssertEqual(ReviewRequest.notice(reviewerName: "Designer", authorName: "Planner"), "You asked Designer to review Planner's reply.")
        XCTAssertNil(Huddle.message("  "))
        XCTAssertEqual(Huddle.message(" Pricing? ")?.text, "Huddle: Pricing?")
        let group = BotGroup(id: "g", name: "team", members: ["planner", "researcher", "designer"], lead: "planner")
        let bots = Dictionary(uniqueKeysWithValues: [planner, researcher, designer].map { ($0.id, $0) })
        XCTAssertEqual(Huddle.startedNotice(group: group, bots: bots), "Huddle started. Research Bot, Designer each give a view, then Planner sums up.")
    }

    // MARK: Drafter

    func testDrafterParse() throws {
        let reply = """
        Sure! ```json
        {"name": "Scout", "role": "Finds sources", "instructions": "You find sources.\\nCite them.", "emoji": "🔍🔍", "colour": "#6c9bd2"}
        ```
        """
        let d = try XCTUnwrap(BotDrafter.parse(reply))
        XCTAssertEqual(d, BotDraft(name: "Scout", role: "Finds sources", instructions: "You find sources.\nCite them.", emoji: "🔍", colour: "#6C9BD2"))
        let odd = try XCTUnwrap(BotDrafter.parse(#"{"name":"Ada","instructions":"x","emoji":"A","color":"purple"}"#))
        XCTAssertTrue(BotPalette.colours.contains(odd.colour))
        XCTAssertEqual(odd.emoji, BotPalette.emojis[0])
        XCTAssertEqual(odd.role, "")
        XCTAssertNil(BotDrafter.parse(#"{"role":"x"}"#))
        XCTAssertNil(BotDrafter.parse("no json"))
        XCTAssertFalse(BotDrafter.prompt("a researcher").lowercased().contains("dog"))
        XCTAssertTrue(BotDrafter.prompt("a researcher").contains(BotPalette.colours[3]))
    }

    func testDrafterRun() async throws {
        let dir = paths.root.appendingPathComponent("scratch")
        let ok = await BotDrafter.draft("a researcher", engine: .claude, model: "haiku", directory: dir) { inv in
            XCTAssertTrue(inv.stdin.contains("a researcher"))
            XCTAssertTrue(inv.arguments.contains("--no-session-persistence"))
            XCTAssertEqual(inv.workingDirectory, dir)
            return .text(##"{"name":"Scout","role":"r","instructions":"i","emoji":"🦉","colour":"#E8735A"}"##)
        }
        XCTAssertEqual(try ok.get().name, "Scout")
        let bad = await BotDrafter.draft("x", engine: .codex, model: nil, directory: dir) { _ in .text("nope") }
        XCTAssertEqual(bad.failureValue, .unreadable)
        let failed = await BotDrafter.draft("x", engine: .claude, model: nil, directory: dir) { _ in .failed(RunFailure(kind: .signedOut, message: "Sign in")) }
        XCTAssertEqual(failed.failureValue, .engine("Sign in"))
        let empty = await BotDrafter.draft(" ", engine: .claude, model: nil, directory: dir) { _ in XCTFail(); return .text("") }
        XCTAssertEqual(empty.failureValue, .empty)
    }

    // MARK: File mentions and steps

    func testFileMentions() throws {
        let bot = paths.botDir("b"), ws = paths.workspace("b")
        try fm.createDirectory(at: ws.appendingPathComponent("site"), withIntermediateDirectories: true)
        try fm.createDirectory(at: ws.appendingPathComponent("folder.md"), withIntermediateDirectories: true)
        for f in ["site/index.html", "My Report.pdf", "chart.png"] { try Data().write(to: ws.appendingPathComponent(f)) }
        try Data().write(to: bot.appendingPathComponent("notes.md"))
        let home = paths.root.appendingPathComponent("home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try Data().write(to: home.appendingPathComponent("todo.txt"))

        let text = """
        I built site/index.html and `My Report.pdf`, plus workspace/chart.png and notes.md.
        Also ~/todo.txt, missing.png, folder.md, https://example.com/page.html and \(ws.path)/chart.png again.
        """
        let chat = ChatMeta(title: "B", kind: .bot, botId: "b")
        let roots = FileMentions.roots(for: chat, botId: nil, paths: paths)
        let found = FileMentions.find(in: text, roots: roots, home: home).map(\.lastPathComponent)
        XCTAssertEqual(found, ["My Report.pdf", "index.html", "chart.png", "notes.md", "todo.txt"])
        XCTAssertEqual(FileMentions.icon(for: URL(fileURLWithPath: "/a.HTML")), "globe")

        let groupChat = ChatMeta(title: "#g", kind: .group, groupId: "g")
        XCTAssertEqual(FileMentions.roots(for: groupChat, botId: "b", paths: paths).first?.path,
                       paths.groups.appendingPathComponent("g/workspace").path)
    }

    func testStepLabels() {
        func label(_ tool: String, _ detail: String?) -> String { StepLabel.describe(Step(id: "1", tool: tool, title: "", detail: detail)).text }
        XCTAssertEqual(label("Bash", #"{"command":"grep -rn foo ."}"#), "Looking through the files")
        XCTAssertEqual(label("Bash", "swift build -c release"), "Building")
        XCTAssertEqual(label("Bash", "git log -3"), "Checking the project history")
        XCTAssertEqual(label("Bash", "echo hi"), "Running a command")
        XCTAssertEqual(label("Read", #"{"file_path":"/a/b/Models.swift"}"#), "Reading Models.swift")
        XCTAssertEqual(label("Edit", nil), "Editing files")
        XCTAssertEqual(label("WebSearch", #"{"query":"swift 6"}"#), "Searching the web for “swift 6”")
        XCTAssertEqual(label("mcp__launchpad_chat__share_plan", nil), "Sharing the plan")
        XCTAssertEqual(label("mcp__my_design_cf26__get_tokens", nil), "Using Design")
        XCTAssertEqual(label("mcp__google_drive__search", nil), "Using Google Drive")
        XCTAssertEqual(StepLabel.describe(tool: "TodoWrite", input: [:]).icon, "checklist")
        XCTAssertEqual(label("Mystery", nil), "Mystery")
    }

    // MARK: Extras

    func testAttachments() throws {
        XCTAssertEqual(Attachments.uniqueName("a.pdf") { ["a.pdf", "a 2.pdf"].contains($0) }, "a 3.pdf")
        XCTAssertEqual(Attachments.uniqueName("Makefile") { $0 == "Makefile" }, "Makefile 2")
        XCTAssertEqual(Attachments.uniqueName("new.txt") { _ in false }, "new.txt")

        let src = paths.root.appendingPathComponent("src")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        let file = src.appendingPathComponent("photo.png")
        try Data("png".utf8).write(to: file)
        let chat = ChatMeta(title: "B", kind: .bot, botId: "b")
        let inbox = try XCTUnwrap(Attachments.inbox(for: chat, paths: paths))
        XCTAssertEqual(inbox, paths.workspace("b").appendingPathComponent("Inbox", isDirectory: true))
        let copied = Attachments.copy([file, file, src.appendingPathComponent("missing.txt")], into: inbox)
        XCTAssertEqual(copied.map(\.lastPathComponent), ["photo.png", "photo 2.png"])
        XCTAssertEqual(try Data(contentsOf: copied[1]), Data("png".utf8))
        XCTAssertTrue(Attachments.isImage(copied[0].path))
        XCTAssertEqual(Attachments.note(copied).components(separatedBy: "\n").filter { $0.hasPrefix("- ") }.count, 2)
        XCTAssertEqual(Attachments.note([String]()), "")
        XCTAssertTrue(Attachments.inbox(for: ChatMeta(title: "g", kind: .group, groupId: "g"), paths: paths)!.path.hasSuffix("groups/g/workspace/Inbox"))
    }

    func testSavedPrompts() throws {
        let store = SavedPromptsStore(paths: paths)
        XCTAssertEqual(store.load(), SavedPromptsStore.defaults)
        try store.add("  Daily standup notes ")
        try store.add(SavedPromptsStore.defaults[2])
        XCTAssertEqual(store.load().prefix(2), [SavedPromptsStore.defaults[2], "Daily standup notes"])
        XCTAssertEqual(store.load().count, 4)
        try store.remove("Daily standup notes")
        XCTAssertFalse(store.load().contains("Daily standup notes"))
        try store.add(" ")
        XCTAssertEqual(store.load().count, 3)
        XCTAssertEqual(SavedPromptsStore.label(String(repeating: "a", count: 70)).count, 61)
    }

    func testExportMarkdown() {
        let utc = TimeZone(identifier: "UTC")!
        let day1 = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 08:00 UTC
        var poll = ChatMessage(id: "p", role: .bot, botId: "b", text: "", createdAt: day1.addingTimeInterval(60))
        poll.poll = Poll(question: "Lunch?", options: ["Pizza", "Sushi"], votes: ["you": 1])
        var edited = ChatMessage(id: "e", role: .user, text: "Sushi it is", createdAt: day1.addingTimeInterval(86_400))
        edited.edits = [MessageEdit(text: "Sushi", replacedAt: day1)]
        edited.forwardedFrom = "Planner"
        let msgs = [
            ChatMessage(id: "u", role: .user, text: "Hi", createdAt: day1),
            poll,
            ChatOps.delete(ChatMessage(id: "d", role: .user, text: "secret", createdAt: day1)),
            ChatMessage(id: "n", role: .notice, text: "Memory updated", createdAt: day1.addingTimeInterval(120)),
            edited,
        ]
        let md = ChatExport.markdown(title: "Planner", messages: msgs, name: { $0.role == .user ? "You" : "Planner" },
                                     exportedAt: day1, locale: Locale(identifier: "en_US_POSIX"), timeZone: utc)
        XCTAssertTrue(md.hasPrefix("# Planner\n\nExported from Launchpad on "))
        XCTAssertEqual(md.components(separatedBy: "\n## ").count, 3, "two days")
        XCTAssertTrue(md.contains("**You** · 8:00 AM\n\nHi\n"), md)
        XCTAssertTrue(md.contains("**Poll: Lunch?**\n- Pizza (0 votes)\n- Sushi (1 vote)"))
        XCTAssertTrue(md.contains("**Note** · 8:02 AM\n\nMemory updated"))
        XCTAssertTrue(md.contains("· forwarded from Planner · edited\n\nSushi it is"))
        XCTAssertFalse(md.contains("secret"))
        XCTAssertEqual(ChatExport.fileName(for: "a/b: c"), "a-b- c chat.md")
    }

    func testQuickSearch() {
        let items = [
            SwitcherItem(id: "b:researcher", kind: .bot, title: "Research Bot", detail: "Finds sources"),
            SwitcherItem(id: "p:routines", kind: .page, title: "Routines", detail: "Page"),
            SwitcherItem(id: "b:scout", kind: .bot, title: "Scout", detail: "Researcher"),
            SwitcherItem(id: "b:resume", kind: .bot, title: "Résumé helper", detail: ""),
            SwitcherItem(id: "c:deep", kind: .chat, title: "Deep research", detail: ""),
        ]
        XCTAssertEqual(QuickSearch.search("", items: items), items)
        XCTAssertEqual(QuickSearch.search("res", items: items).map(\.id), ["b:researcher", "b:resume", "c:deep", "b:scout"])
        XCTAssertEqual(QuickSearch.search("ROUTINES", items: items).first?.id, "p:routines")
        XCTAssertEqual(QuickSearch.score("x", title: "abc", detail: "def"), nil)

        let chat = ChatMeta(id: "c1", title: "Planner", kind: .bot, botId: "planner")
        let t = Date(timeIntervalSince1970: 1_000)
        let msgs = [
            ChatMessage(id: "m1", role: .user, text: "Please research the solar market", createdAt: t),
            ChatMessage(id: "m2", role: .bot, botId: "planner", text: String(repeating: "word ", count: 20) + "Research done", createdAt: t.addingTimeInterval(10)),
            ChatMessage(id: "m3", role: .notice, text: "research notice", createdAt: t.addingTimeInterval(20)),
            ChatOps.delete(ChatMessage(id: "m4", role: .user, text: "research", createdAt: t.addingTimeInterval(30))),
        ]
        let hits = QuickSearch.search("research", items: items, chats: [(chat, msgs)], name: { $0.role == .user ? "You" : "Planner" })
        let messageHits = hits.filter { $0.kind == .message }
        XCTAssertEqual(messageHits.map(\.messageId), ["m2", "m1"], "newest first, no notices or deleted")
        XCTAssertEqual(messageHits[0].detail, "Planner in Planner")
        XCTAssertTrue(messageHits[0].title.hasPrefix("…"))
        XCTAssertTrue(messageHits[0].title.contains("Research done"))
        XCTAssertTrue(QuickSearch.search("r", items: [], chats: [(chat, msgs)]).isEmpty, "one letter: no message search")
    }
}

extension Result {
    var failureValue: Failure? {
        if case .failure(let e) = self { return e }
        return nil
    }
}
