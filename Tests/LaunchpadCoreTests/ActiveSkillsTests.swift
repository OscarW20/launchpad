import XCTest
@testable import LaunchpadCore

final class ActiveSkillsTests: XCTestCase {
    var paths: LaunchpadPaths!
    var skills: SkillStore!
    var store: ActiveSkillsStore!

    override func setUpWithError() throws {
        paths = LaunchpadPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("lp-act-\(UUID().uuidString)"))
        try paths.ensureStructure()
        skills = SkillStore(paths: paths)
        store = ActiveSkillsStore(paths: paths)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: paths.root) }

    @discardableResult
    private func skill(_ id: String, _ useWhen: String = "Use when building things.") throws -> Skill {
        try skills.save(id: id, text: SkillFile.compose(name: id, description: useWhen, body: "# \(id)\nLots of detail that must not be pasted."))
        return try XCTUnwrap(skills.load(id: id))
    }

    private func groupChat(_ gid: String) -> ChatMeta { ChatMeta(title: "#g", kind: .group, groupId: gid) }
    private func botChat() -> ChatMeta { ChatMeta(title: "b", kind: .bot, botId: "x") }

    // MARK: Switching

    func testSwitchingOnAndOffIsSavedPerChat() throws {
        try skill("a"); try skill("b")
        let chat = botChat(), other = botChat()
        XCTAssertEqual(try store.set("a", on: true, scope: .chat(chat.id), chat: chat), ["a"])
        XCTAssertEqual(try store.set("b", on: true, scope: .chat(chat.id), chat: chat), ["a", "b"])
        XCTAssertEqual(try store.set("a", on: true, scope: .chat(chat.id), chat: chat), ["b", "a"])    // no duplicate
        XCTAssertEqual(store.active(for: chat), ["b", "a"])
        XCTAssertEqual(store.active(for: other), [])
        XCTAssertEqual(try store.set("b", on: false, scope: .chat(chat.id), chat: chat), ["a"])
        XCTAssertEqual(try ActiveSkillsStore(paths: paths).ids(.chat(chat.id)), ["a"])                  // survives a reload
        try store.set("a", on: false, scope: .chat(chat.id))
        XCTAssertEqual(store.load(), ActiveSkillSet())
    }

    func testAGroupSetAppliesToItsGroupChatsAndTheChatCanAddToIt() throws {
        try skill("a"); try skill("b"); try skill("c")
        let chat = groupChat("g1"), same = groupChat("g1"), elsewhere = groupChat("g2")
        try store.set("a", on: true, scope: .group("g1"))
        try store.set("b", on: true, scope: .group("g1"))
        try store.set("c", on: true, scope: .chat(chat.id), chat: chat)
        XCTAssertEqual(store.active(for: chat), ["a", "b", "c"])
        XCTAssertEqual(store.active(for: same), ["a", "b"])
        XCTAssertEqual(store.active(for: elsewhere), [])
        // A one-to-one chat doesn't get a group's set.
        var oneToOne = botChat(); oneToOne.groupId = "g1"
        XCTAssertEqual(store.active(for: oneToOne), [])
        // The same skill at both levels counts once.
        try store.set("a", on: true, scope: .chat(chat.id), chat: chat)
        XCTAssertEqual(store.active(for: chat), ["a", "b", "c"])
    }

    func testUnknownSkillsAreRefusedAndSwitchingOffAlwaysWorks() throws {
        XCTAssertThrowsError(try store.set("ghost", on: true, scope: .chat("c"))) { XCTAssertEqual($0 as? ActiveSkillError, .unknownSkill("ghost")) }
        XCTAssertNoThrow(try store.set("ghost", on: false, scope: .chat("c")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file.path.replacingOccurrences(of: "active-skills", with: "nope")))
    }

    func testTheCapCountsTheGroupsSkillsAndTheChatsTogether() throws {
        let ids = (1...10).map { "s\($0)" }
        for id in ids { try skill(id) }
        let chat = groupChat("g")
        try ChatStore(paths: paths).save(chat)                                                              // a real, saved chat
        for id in ids.prefix(6) { try store.set(id, on: true, scope: .group("g")) }
        try store.set("s7", on: true, scope: .chat(chat.id), chat: chat)
        try store.set("s8", on: true, scope: .chat(chat.id), chat: chat)
        XCTAssertEqual(store.active(for: chat).count, ActiveSkillsStore.maxActive)
        XCTAssertThrowsError(try store.set("s9", on: true, scope: .chat(chat.id), chat: chat)) { XCTAssertEqual($0 as? ActiveSkillError, .tooMany(8)) }
        // Adding to the group would push this chat over too.
        XCTAssertThrowsError(try store.set("s9", on: true, scope: .group("g")))
        XCTAssertEqual(store.active(for: chat).count, 8)                                                  // nothing changed
        try store.set("s8", on: false, scope: .chat(chat.id))
        XCTAssertNoThrow(try store.set("s9", on: true, scope: .chat(chat.id), chat: chat))
    }

    func testTheFileIsKeptWhereBotsCannotWriteAndReadLeniently() throws {
        XCTAssertTrue(store.file.path.hasPrefix(paths.launchpadData.path + "/"))
        XCTAssertTrue(GuardRulesFile.config(for: Bot(id: "x", name: "X"), paths: paths).protected.contains(store.file.path))
        try FileManager.default.createDirectory(at: store.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.file)
        XCTAssertEqual(store.load(), ActiveSkillSet())
        try Data(#"{"chats":{"c":["a"]},"groups":"oops"}"#.utf8).write(to: store.file)
        XCTAssertEqual(store.load().chats["c"], ["a"])
        XCTAssertEqual(store.load().groups, [:])
    }

    // MARK: The prompt

    func testTheSectionListsSkillsWithoutTheirText() throws {
        let a = try skill("frontend-design", "Use when building any UI."), b = try skill("dataviz", "Use for charts.")
        let section = ActiveSkillsPrompt.section(ids: ["frontend-design", "dataviz", "gone", "dataviz"], library: [a, b], paths: paths)
        XCTAssertEqual(section.skillIds, ["frontend-design", "dataviz"])
        XCTAssertTrue(section.text.contains("Apply them to anything you build"))
        XCTAssertTrue(section.text.contains("- frontend-design: Use when building any UI. (\(paths.skills.path)/frontend-design/SKILL.md)"))
        XCTAssertTrue(section.text.contains("- dataviz: Use for charts."))
        XCTAssertFalse(section.text.contains("Lots of detail"))
        XCTAssertFalse(section.text.contains("gone"))
        XCTAssertEqual(section.estimatedTokens, TokenEstimate.tokens(section.text))
        XCTAssertGreaterThan(section.estimatedTokens, 0)
        XCTAssertTrue(ActiveSkillsPrompt.section(ids: [], library: [a], paths: paths).isEmpty)
        XCTAssertTrue(ActiveSkillsPrompt.section(ids: ["gone"], library: [a], paths: paths).isEmpty)
    }

    func testTheCostGrowsWithEachSkillAndLongDescriptionsAreClipped() throws {
        let one = try skill("a", String(repeating: "word ", count: 200)), two = try skill("b")
        let solo = ActiveSkillsPrompt.estimate(ids: ["a"], library: [one, two], paths: paths)
        let both = ActiveSkillsPrompt.estimate(ids: ["a", "b"], library: [one, two], paths: paths)
        XCTAssertGreaterThan(both, solo)
        XCTAssertLessThan(solo, 250)                                                                        // the description is clipped
        XCTAssertTrue(ActiveSkillsPrompt.section(ids: ["a"], library: [one], paths: paths).text.contains("…"))
    }

    func testTheSectionNeverNamesMoreThanTheCap() throws {
        let all = try (1...12).map { try skill("s\($0)") }
        XCTAssertEqual(ActiveSkillsPrompt.section(ids: all.map(\.id), library: all, paths: paths).skillIds.count, 8)
    }

    // MARK: Groups: moved and copied

    func testAMovedGroupKeepsItsSkillsAndACopyStartsWithTheSame() throws {
        try skill("a"); try skill("b")
        let bots = BotStore(paths: paths), groups = GroupStore(paths: paths), spaces = WorkspaceStore(paths: paths)
        let m = try bots.create(name: "Mia")
        let g = try groups.create(name: "Team", members: [m.id], lead: m.id)
        try store.set("a", on: true, scope: .group(g.id))
        try store.set("b", on: true, scope: .group(g.id))
        try spaces.create(name: "Biscuit")
        try spaces.move(group: g.id, to: "biscuit")
        XCTAssertEqual(store.ids(.group(g.id)), ["a", "b"])                                                // same id, same set
        let copy = try spaces.duplicate(group: g.id, into: "general").group
        XCTAssertEqual(store.ids(.group(copy.id)), ["a", "b"])
        // They are separate from then on.
        try store.set("a", on: false, scope: .group(copy.id))
        XCTAssertEqual(store.ids(.group(g.id)), ["a", "b"])
        XCTAssertEqual(store.ids(.group(copy.id)), ["b"])
        try store.forget(.group(copy.id))
        XCTAssertEqual(store.ids(.group(copy.id)), [])
    }

    // MARK: Design skills

    private func fakeHome(_ ids: [String]) throws -> URL {
        let home = paths.root.appendingPathComponent("home")
        for id in ids {
            let dir = home.appendingPathComponent(".claude/skills/\(id)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(SkillFile.compose(name: id, description: "Use for \(id).", body: "body of \(id)").utf8).write(to: dir.appendingPathComponent("SKILL.md"))
        }
        return home
    }

    func testOnlyTheDesignSkillsThatExistAreImportedAndTheReportSaysWhat() throws {
        let home = try fakeHome(["frontend-design", "ui-ux-pro-max", "morning", "pdf"])
        let report = DesignSkills.importAvailable(into: skills, home: home)
        XCTAssertEqual(report.installed, ["frontend-design", "ui-ux-pro-max"])
        XCTAssertEqual(report.missing, ["dataviz"])
        XCTAssertNotNil(skills.load(id: "frontend-design")); XCTAssertNotNil(skills.load(id: "ui-ux-pro-max"))
        XCTAssertNil(skills.load(id: "morning")); XCTAssertNil(skills.load(id: "pdf"))                      // nothing else is imported
        XCTAssertNil(skills.load(id: "dataviz"))
        XCTAssertEqual(report.summary, "Added frontend-design, ui-ux-pro-max; couldn't find dataviz on this Mac.")
        // Again: nothing changes.
        let again = DesignSkills.importAvailable(into: skills, home: home)
        XCTAssertEqual(again.installed, [])
        XCTAssertEqual(again.alreadyThere, ["frontend-design", "ui-ux-pro-max"])
        XCTAssertEqual(again.summary, "Already had frontend-design, ui-ux-pro-max; couldn't find dataviz on this Mac.")
    }

    func testADifferentSkillWithTheSameNameIsNeverReplaced() throws {
        try skill("frontend-design", "my own version")
        let home = try fakeHome(["frontend-design"])
        let report = DesignSkills.importAvailable(into: skills, home: home)
        XCTAssertEqual(report.alreadyThere, ["frontend-design"])
        XCTAssertTrue(skills.load(id: "frontend-design")!.text.contains("my own version"))
        XCTAssertEqual(DesignSkills.importAvailable(into: SkillStore(paths: paths), home: paths.root.appendingPathComponent("empty")).summary.hasPrefix("Already had frontend-design"), true)
    }

    func testDesignSkillsComeFirstInTheChecklist() throws {
        let list = try ["zebra", "dataviz", "apple", "frontend-design", "ui-ux-pro-max"].map { try skill($0) }
        XCTAssertEqual(DesignSkills.ordered(list).map(\.id), ["frontend-design", "ui-ux-pro-max", "dataviz", "apple", "zebra"])
    }
}
