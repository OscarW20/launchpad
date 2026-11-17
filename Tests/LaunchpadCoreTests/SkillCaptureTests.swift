import XCTest
@testable import LaunchpadCore

final class SkillCaptureTests: XCTestCase {
    var root: URL!
    var paths: LaunchpadPaths!
    var store: SkillStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lp-capture-\(UUID().uuidString)", isDirectory: true)
        paths = LaunchpadPaths(root: root)
        try paths.ensureStructure()
        store = SkillStore(paths: paths)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func skill(_ id: String, _ description: String = "Use when testing.") -> Skill {
        Skill(id: id, name: id, description: description,
              text: SkillFile.compose(name: id, description: description, body: "# \(id)\n\n1. Do it."), updatedAt: Date())
    }

    // MARK: Names

    func testNamesBecomeIds() throws {
        XCTAssertEqual(try SkillCapture.skillId("Release Notes"), "release-notes")
        XCTAssertEqual(try SkillCapture.skillId("  ship-it  "), "ship-it")
        XCTAssertEqual(try SkillCapture.skillId("QA pass 2"), "qa-pass-2")
    }

    func testBadNames() {
        XCTAssertThrowsError(try SkillCapture.skillId("  ")) { XCTAssertEqual($0 as? SkillCaptureError, .emptyName) }
        XCTAssertThrowsError(try SkillCapture.skillId("!!!")) { XCTAssertEqual($0 as? SkillCaptureError, .badName("!!!")) }
        XCTAssertThrowsError(try SkillCapture.skillId("../deploy")) { XCTAssertEqual($0 as? SkillCaptureError, .badName("../deploy")) }
        XCTAssertThrowsError(try SkillCapture.skillId(".hidden")) { XCTAssertEqual($0 as? SkillCaptureError, .badName(".hidden")) }
        XCTAssertThrowsError(try SkillCapture.skillId(String(repeating: "a", count: 41)))
        XCTAssertThrowsError(try SkillCapture.skillId("Accept")) { XCTAssertEqual($0 as? SkillCaptureError, .reserved("accept")) }
        XCTAssertThrowsError(try SkillCapture.skillId("ask")) { XCTAssertEqual($0 as? SkillCaptureError, .reserved("ask")) }
    }

    func testReservedNamesCoverTheModeCommands() {
        for command in ApprovalMode.commands.keys where command.hasPrefix("/") {
            XCTAssertTrue(SkillCapture.reservedNames.contains(String(command.dropFirst())), command)
        }
    }

    // MARK: Saving

    func testCaptureWritesASkillFile() throws {
        let saved = try store.capture(SkillDraft(name: "Launch Recap", useWhen: "Use when writing\nrelease notes.", steps: "1. Read the log.\n2. Write it up."))
        XCTAssertEqual(saved.id, "launch-recap")
        XCTAssertEqual(saved.description, "Use when writing release notes.")
        XCTAssertEqual(saved.body, "1. Read the log.\n2. Write it up.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.skills.appendingPathComponent("launch-recap/SKILL.md").path))
        XCTAssertTrue(SkillCapture.isUserSkill(saved))
    }

    func testCaptureNeverOverwrites() throws {
        try store.capture(SkillDraft(name: "notes", useWhen: "a", steps: "first"))
        XCTAssertThrowsError(try store.capture(SkillDraft(name: "Notes", useWhen: "b", steps: "second"))) {
            XCTAssertEqual($0 as? SkillCaptureError, .taken("notes"))
        }
        XCTAssertEqual(store.load(id: "notes")?.body, "first")
    }

    func testCaptureCantTakeABuiltInName() throws {
        let builtIn = try XCTUnwrap(SkillCatalog.all.first).id
        XCTAssertThrowsError(try store.capture(SkillDraft(name: builtIn, useWhen: "a", steps: "mine"))) {
            XCTAssertEqual($0 as? SkillCaptureError, .builtIn(builtIn))
        }
        XCTAssertNil(store.load(id: builtIn), "even when it isn't installed")
    }

    func testCaptureNeedsSteps() {
        XCTAssertThrowsError(try store.capture(SkillDraft(name: "empty", useWhen: "a", steps: " \n"))) {
            XCTAssertEqual($0 as? SkillCaptureError, .emptySteps)
        }
    }

    func testUpdateChangesYourOwnSkill() throws {
        try store.capture(SkillDraft(name: "notes", useWhen: "a", steps: "first"))
        let updated = try store.update(id: "notes", with: SkillDraft(name: "ignored", useWhen: "b", steps: "second"), locked: [])
        XCTAssertEqual(updated.id, "notes")
        XCTAssertEqual(updated.description, "b")
        XCTAssertEqual(updated.body, "second")
        XCTAssertEqual(SkillFile.parse(updated.text).name, "notes", "the name stays: bots and groups refer to it")
    }

    func testUpdateRefusesLockedBuiltInAndMissing() throws {
        try store.capture(SkillDraft(name: "notes", useWhen: "a", steps: "first"))
        let draft = SkillDraft(name: "notes", useWhen: "b", steps: "second")
        XCTAssertThrowsError(try store.update(id: "notes", with: draft, locked: ["notes"])) {
            XCTAssertEqual($0 as? SkillCaptureError, .locked("notes"))
        }
        XCTAssertEqual(store.load(id: "notes")?.body, "first")

        let builtIn = try XCTUnwrap(SkillCatalog.all.first)
        try store.save(id: builtIn.id, text: builtIn.fileText)
        XCTAssertThrowsError(try store.update(id: builtIn.id, with: draft, locked: [])) {
            XCTAssertEqual($0 as? SkillCaptureError, .builtIn(builtIn.id))
        }
        XCTAssertEqual(store.load(id: builtIn.id)?.text, builtIn.fileText)

        XCTAssertThrowsError(try store.update(id: "gone", with: draft, locked: [])) {
            XCTAssertEqual($0 as? SkillCaptureError, .notFound("gone"))
        }
    }

    func testADraftFromWhatABotWrote() throws {
        let raw = "Here you go:\n---\nname: Release Notes\ndescription: Use when shipping.\n---\n\n# Release notes\n\n1. Read the log.\n"
        let draft = SkillDraft(text: SkillTeacher.cleanDraft(raw))
        XCTAssertEqual(draft, SkillDraft(name: "Release Notes", useWhen: "Use when shipping.", steps: "# Release notes\n\n1. Read the log."))
        XCTAssertTrue(try draft.fileText().hasPrefix("---\nname: release-notes\n"))
    }

    // MARK: Who gets it

    func testDefaultAudience() {
        XCTAssertEqual(SkillCapture.defaultAudience(for: ChatMeta(title: "#build", kind: .group, groupId: "build")), .group("build"))
        XCTAssertEqual(SkillCapture.defaultAudience(for: ChatMeta(title: "Scout", kind: .bot, botId: "scout")), .bots(["scout"]))
        XCTAssertEqual(SkillCapture.defaultAudience(for: ChatMeta(title: "?", kind: .group)), .nobody)
    }

    func testAssignToAGroupReachesEveryMember() throws {
        let bots = BotStore(paths: paths), groups = GroupStore(paths: paths)
        try bots.save(Bot(id: "lead", name: "Lead"))
        try bots.save(Bot(id: "scout", name: "Scout"))
        let group = try groups.create(name: "Build", members: ["scout"], lead: "lead")
        let given = try SkillCapture.assign("notes", to: .group(group.id), bots: bots, groups: groups)
        XCTAssertEqual(given, ["lead", "scout"])
        XCTAssertEqual(try groups.load(id: group.id).skills, ["notes"])
        try SkillCapture.assign("notes", to: .group(group.id), bots: bots, groups: groups)
        XCTAssertEqual(try groups.load(id: group.id).skills, ["notes"], "not added twice")
        let scout = try bots.load(id: "scout")
        XCTAssertEqual(SkillLinker.effectiveSkills(for: scout, groups: [try groups.load(id: group.id)]), ["notes"])
        XCTAssertEqual(scout.skills, [], "it's on the group, not on each bot")
    }

    func testAssignToChosenBots() throws {
        let bots = BotStore(paths: paths), groups = GroupStore(paths: paths)
        try bots.save(Bot(id: "lead", name: "Lead"))
        try bots.save(Bot(id: "scout", name: "Scout", skills: ["deploy"]))
        let given = try SkillCapture.assign("notes", to: .bots(["scout", "nobody-here"]), bots: bots, groups: groups)
        XCTAssertEqual(given, ["scout"])
        XCTAssertEqual(try bots.load(id: "scout").skills, ["deploy", "notes"])
        XCTAssertEqual(try bots.load(id: "lead").skills, [])
        XCTAssertEqual(try SkillCapture.assign("notes", to: .nobody, bots: bots, groups: groups), [])
    }

    // MARK: "/name …"

    func testQueryWhileTypingTheName() {
        XCTAssertEqual(SkillCommand.query(in: "/"), "")
        XCTAssertEqual(SkillCommand.query(in: "/rel"), "rel")
        XCTAssertEqual(SkillCommand.query(in: "/release-notes"), "release-notes")
        XCTAssertNil(SkillCommand.query(in: "/release-notes "), "the list closes once the name is done")
        XCTAssertNil(SkillCommand.query(in: "/usr/bin"))
        XCTAssertNil(SkillCommand.query(in: "hello /rel"), "only at the start")
        XCTAssertNil(SkillCommand.query(in: ""))
    }

    func testCandidatesByPrefixThenContains() {
        let skills = [skill("code-review"), skill("deploy"), skill("release-notes"), skill("write-spec")]
        XCTAssertEqual(SkillCommand.candidates(for: "", among: skills).map(\.id), ["code-review", "deploy", "release-notes", "write-spec"])
        XCTAssertEqual(SkillCommand.candidates(for: "re", among: skills).map(\.id), ["release-notes", "code-review"])
        XCTAssertEqual(SkillCommand.candidates(for: "DEP", among: skills).map(\.id), ["deploy"])
        XCTAssertEqual(SkillCommand.candidates(for: "zzz", among: skills).map(\.id), [])
    }

    func testInsert() {
        XCTAssertEqual(SkillCommand.insert("release-notes", into: "/rel"), "/release-notes ")
        XCTAssertEqual(SkillCommand.insert("release-notes", into: "hello"), "hello")
    }

    func testGroupHistoryGetsTheSkillOnlyForYourMessages() {
        let skills = [skill("deploy")]
        let history = [
            ChatMessage(id: "1", role: .user, text: "/deploy the site"),
            ChatMessage(id: "2", role: .bot, botId: "lead", text: "/deploy the site"),
            ChatMessage(id: "3", role: .notice, text: "/deploy"),
            ChatMessage(id: "4", role: .user, text: "/usr/bin/true is a path"),
            ChatMessage(id: "5", role: .user, text: "plain message"),
        ]
        let out = SkillCommand.expand(history, skills: skills)
        XCTAssertEqual(out.map(\.id), history.map(\.id))
        XCTAssertTrue(out[0].text.contains("Use the \"deploy\" skill"))
        XCTAssertTrue(out[0].text.contains("My request: the site"))
        // A bot writing "/deploy" can't pull a skill in, and nothing else changes.
        XCTAssertEqual(Array(out[1...]), Array(history[1...]))
    }

    func testParseASkillCommand() {
        let skills = [skill("deploy"), skill("release-notes")]
        let use = SkillCommand.parse("/release-notes for version 0.2.0\nplease", skills: skills)
        XCTAssertEqual(use?.skill.id, "release-notes")
        XCTAssertEqual(use?.request, "for version 0.2.0\nplease")
        XCTAssertEqual(SkillCommand.parse("  /Deploy  ", skills: skills)?.skill.id, "deploy")
        XCTAssertEqual(SkillCommand.parse("/deploy", skills: skills)?.request, "")
    }

    func testOrdinaryMessagesAreNotCommands() {
        let skills = [skill("deploy"), skill("usr")]
        XCTAssertNil(SkillCommand.parse("/unknown make it", skills: skills))
        XCTAssertNil(SkillCommand.parse("/usr/bin/swift is missing", skills: skills), "a path, even when a skill shares its first part")
        XCTAssertNil(SkillCommand.parse("please /deploy", skills: skills))
        XCTAssertNil(SkillCommand.parse("/ deploy", skills: skills))
        XCTAssertNil(SkillCommand.parse("/deployment now", skills: skills))
        XCTAssertNil(SkillCommand.parse("", skills: skills))
    }

    func testPromptCarriesTheSkillAndTheRequest() {
        let use = SkillCommand.Use(skill: skill("deploy", "Use when deploying."), request: "ship the landing page")
        let prompt = SkillCommand.prompt(for: use)
        XCTAssertTrue(prompt.contains("Use the \"deploy\" skill"))
        XCTAssertTrue(prompt.contains("My request: ship the landing page"))
        XCTAssertTrue(prompt.contains("1. Do it."), "the steps are included for bots that don't have the skill")
        XCTAssertTrue(SkillCommand.prompt(for: SkillCommand.Use(skill: skill("deploy"), request: "")).contains("Do what this skill is for"))
    }

    // MARK: Drafting

    private func chat() -> [ChatMessage] {
        [
            ChatMessage(id: "1", role: .user, text: "old request"),
            ChatMessage(id: "2", role: .bot, botId: "scout", text: "old answer"),
            ChatMessage(id: "3", role: .user, text: "make the release notes"),
            ChatMessage(id: "4", role: .user, text: "for 0.2.0"),
            ChatMessage(id: "5", role: .bot, botId: "lead", text: "handing to scout"),
            ChatMessage(id: "6", role: .notice, text: "Scout is working"),
            ChatMessage(id: "7", role: .bot, botId: "scout", text: "done, here they are"),
            ChatMessage(id: "8", role: .user, text: "thanks"),
        ]
    }

    func testStretchGoesBackToTheRequestThatStartedIt() {
        XCTAssertEqual(SkillTeacher.stretch(endingAt: "7", in: chat()).map(\.id), ["3", "4", "5", "7"])
        XCTAssertEqual(SkillTeacher.stretch(endingAt: "5", in: chat()).map(\.id), ["3", "4", "5"])
        XCTAssertEqual(SkillTeacher.stretch(endingAt: "2", in: chat()).map(\.id), ["1", "2"])
        XCTAssertEqual(SkillTeacher.stretch(endingAt: "4", in: chat()).map(\.id), ["3", "4"], "on one of your own messages: just the request")
        XCTAssertEqual(SkillTeacher.stretch(endingAt: "nope", in: chat()), [])
    }

    func testCapturePrompt() {
        let stretch = SkillTeacher.stretch(endingAt: "7", in: chat())
        let prompt = SkillTeacher.capturePrompt(stretch, name: "Release Notes") { $0 == "scout" ? "Scout" : "Lead" }
        XCTAssertTrue(prompt.contains("Call it exactly `release-notes`"))
        XCTAssertTrue(prompt.contains("### Me\nmake the release notes"))
        XCTAssertTrue(prompt.contains("### Scout\ndone, here they are"))
        XCTAssertFalse(prompt.contains("old request"))
        XCTAssertFalse(prompt.contains("Scout is working"), "notices are left out")
        let unnamed = SkillTeacher.capturePrompt(stretch, botName: { _ in "Bot" })
        XCTAssertFalse(unnamed.contains("Call it exactly"))
        XCTAssertFalse(SkillTeacher.capturePrompt(stretch, name: "!!!", botName: { _ in "Bot" }).contains("Call it exactly"), "a bad name is left for the save step to report")
    }
}
