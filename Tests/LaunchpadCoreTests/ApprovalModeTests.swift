import XCTest
@testable import LaunchpadCore

final class ApprovalModeTests: XCTestCase {
    var root: URL!
    var paths: LaunchpadPaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lp-mode-\(UUID().uuidString)", isDirectory: true)
        paths = LaunchpadPaths(root: root)
        try FileManager.default.createDirectory(at: paths.botDir("scout"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        // The rules folder is read-only between writes; make it removable again.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.guardRules.path)
        try? FileManager.default.removeItem(at: root)
    }

    private func rules(_ bot: Bot, free: Bool) throws -> String {
        let config = GuardRulesFile.config(for: bot, paths: paths, fullFreedom: free)
        return try GuardRulesFile.write(config, botId: bot.id, paths: paths).path
    }

    private func call(_ tool: String, _ input: [String: Any]) -> Data {
        let obj: [String: Any] = ["session_id": "s1", "tool_name": tool, "tool_input": input, "cwd": paths.botDir("scout").path]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    private func run(_ command: String, rules: String) -> HookResult {
        GuardHook.run(input: call("Bash", ["command": command]), rulesPath: rules, askBase: nil, grants: nil)
    }

    // MARK: The group setting

    func testGroupsDefaultToAskMe() throws {
        XCTAssertEqual(BotGroup(id: "g", name: "G").approvals, .ask)
        let old = Data(#"{"id":"g","name":"G","members":["scout"]}"#.utf8)
        XCTAssertEqual(try JSONCoding.decoder().decode(BotGroup.self, from: old).approvals, .ask, "groups saved before the setting existed")
        let odd = Data(#"{"id":"g","name":"G","approvals":"yolo"}"#.utf8)
        XCTAssertEqual(try JSONCoding.decoder().decode(BotGroup.self, from: odd).approvals, .ask, "anything unreadable means Ask me")
    }

    func testTheSettingIsSavedWithTheGroup() throws {
        let store = GroupStore(paths: paths)
        var group = try store.create(name: "Build", members: ["scout"], lead: "scout")
        XCTAssertEqual(group.approvals, .ask)
        group.approvals = .fullFreedom
        try store.save(group)
        XCTAssertEqual(try store.load(id: group.id).approvals, .fullFreedom)
    }

    func testALockedDownBotKeepsAsking() {
        XCTAssertTrue(ApprovalMode.fullFreedom.skipsApprovals(for: Bot(id: "scout", name: "Scout")))
        XCTAssertFalse(ApprovalMode.fullFreedom.skipsApprovals(for: Bot(id: "scout", name: "Scout", lockedDown: true)))
        XCTAssertFalse(ApprovalMode.ask.skipsApprovals(for: Bot(id: "scout", name: "Scout")))
        let config = GuardRulesFile.config(for: Bot(id: "scout", name: "Scout", lockedDown: true), paths: paths, fullFreedom: true)
        XCTAssertFalse(config.fullFreedom)
    }

    // MARK: Typed in the chat

    func testChatCommands() {
        XCTAssertEqual(ApprovalMode.command(in: "accept mode"), .fullFreedom)
        XCTAssertEqual(ApprovalMode.command(in: "  Accept  Mode. "), .fullFreedom)
        XCTAssertEqual(ApprovalMode.command(in: "full freedom"), .fullFreedom)
        XCTAssertEqual(ApprovalMode.command(in: "/accept"), .fullFreedom)
        XCTAssertEqual(ApprovalMode.command(in: "ask mode"), .ask)
        XCTAssertEqual(ApprovalMode.command(in: "Ask mode!"), .ask)
        XCTAssertEqual(ApprovalMode.command(in: "/ask"), .ask)
    }

    func testAMessageThatOnlyMentionsTheWordsIsNotACommand() {
        XCTAssertNil(ApprovalMode.command(in: "can we add an accept mode?"))
        XCTAssertNil(ApprovalMode.command(in: "accept mode please, then push"))
        XCTAssertNil(ApprovalMode.command(in: "ask"))
        XCTAssertNil(ApprovalMode.command(in: ""))
    }

    // MARK: What the guard does

    func testFullFreedomLetsAskRulesThrough() throws {
        let bot = Bot(id: "scout", name: "Scout")
        let ask = try rules(bot, free: false), free = try rules(bot, free: true)
        XCTAssertNotEqual(ask, free, "a bot can be in both kinds of chat at once, so each mode has its own file")
        XCTAssertEqual(run("git push origin main", rules: ask).exitCode, 2, "Ask me, with nobody to ask: blocked")
        let r = run("git push origin main", rules: free)
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertTrue(r.stdout?.contains(#""permissionDecision":"allow""#) ?? false, "the same as approving the card")
        XCTAssertEqual(run("rm -rf ~/Documents/old", rules: free).exitCode, 0)
        let mcp = GuardHook.run(input: call("mcp__slack__post_message", ["text": "hi"]), rulesPath: free, askBase: nil, grants: nil)
        XCTAssertEqual(mcp.exitCode, 0)
        XCTAssertEqual(run("ls -la", rules: free), .pass, "harmless calls are untouched")
    }

    func testNeverStillMeansNever() throws {
        var bot = Bot(id: "scout", name: "Scout")
        bot.rules.set(.never, for: .spend)
        let free = try rules(bot, free: true)
        let r = run("vercel domains buy example.com", rules: free)
        XCTAssertEqual(r.exitCode, 2)
        XCTAssertTrue(r.stderr?.contains("isn't allowed") ?? false)
    }

    func testLaunchpadsOwnFilesStayProtected() throws {
        let free = try rules(Bot(id: "scout", name: "Scout"), free: true)
        XCTAssertEqual(run("echo x > \(paths.guardRules.path)/scout.json", rules: free).exitCode, 2)
        let edit = call("Edit", ["file_path": paths.botDir("scout").appendingPathComponent(".claude/settings.json").path])
        XCTAssertEqual(GuardHook.run(input: edit, rulesPath: free, askBase: nil, grants: nil).exitCode, 2)
    }

    func testALockedDownBotStillGetsACard() throws {
        let free = try rules(Bot(id: "scout", name: "Scout", lockedDown: true), free: true)
        XCTAssertEqual(run("git push origin main", rules: free).exitCode, 2)
    }

    // MARK: What the bot is told

    func testInstructions() {
        let free = LaunchpadProtocol.text(skills: [], liveApprovals: true, fullFreedom: true)
        XCTAssertTrue(free.contains("Full freedom is on"))
        XCTAssertFalse(free.contains("approval card"))
        XCTAssertFalse(free.contains("[[approve:"))
        XCTAssertTrue(free.contains("Never write passwords"), "the rule about secrets doesn't change")
        XCTAssertFalse(LaunchpadProtocol.text(skills: [], liveApprovals: true).contains("Full freedom"))
    }

    func testCodexNoteDropsAskButKeepsNever() {
        let rules = BotRules(rules: ["spend": "never"])
        XCTAssertTrue(rules.codexNote().contains("[[approve:"))
        let note = rules.codexNote(lockedSkills: ["deploy"], fullFreedom: true)
        XCTAssertFalse(note.contains("[[approve:"))
        XCTAssertTrue(note.contains("Never do these"))
        XCTAssertTrue(note.contains("deploy"))
        XCTAssertTrue(BotRules().codexNote(fullFreedom: true).isEmpty)
    }
}
