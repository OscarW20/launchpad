import XCTest
@testable import LaunchpadCore

final class TeamProposalTests: XCTestCase {
    var paths: LaunchpadPaths!
    var bots: BotStore!
    var groups: GroupStore!
    var store: WorkspaceStore!

    override func setUpWithError() throws {
        paths = LaunchpadPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("lp-team-\(UUID().uuidString)"))
        try paths.ensureStructure()
        bots = BotStore(paths: paths); groups = GroupStore(paths: paths); store = WorkspaceStore(paths: paths)
        try store.create(name: "Biscuit")
    }

    override func tearDown() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.groups.path)
        try? FileManager.default.removeItem(at: paths.root)
    }

    private func block(_ json: String, around: String = "Here are some setups.") -> String {
        "\(around)\n\n```team-proposal\n\(json)\n```\n\nPick one."
    }

    private let good = """
    {"goal":"Auto-post story-led shorts","options":[
     {"label":"Lean","name":"Marketing","lead":"lead","members":[
       {"key":"lead","name":"Marketing Lead","role":"Plans the campaign"},
       {"key":"copy","name":"Copywriter","role":"Writes captions"}],
      "skills":["frontend-design"],"connectors":["tiktok"],"notes":"Two people."},
     {"label":"Recommended","name":"Marketing","emoji":"📣","lead":"lead","members":[
       {"key":"lead","name":"Marketing Lead","role":"Plans"},
       {"key":"copy","name":"Copywriter","role":"Captions"},
       {"key":"design","name":"Designer","role":"Visuals","template":"designer"},
       {"key":"ops","name":"Posting Ops","role":"Schedules posts"}]}]}
    """

    // MARK: Reading the block

    func testAProposalIsReadFromAMessage() throws {
        let p = try TeamProposalParser.parse(block(good))
        XCTAssertEqual(p.goal, "Auto-post story-led shorts")
        XCTAssertEqual(p.options.map(\.label), ["Lean", "Recommended"])
        let rec = p.options[1]
        XCTAssertEqual(rec.emoji, "📣"); XCTAssertEqual(rec.lead, "lead")
        XCTAssertEqual(rec.members.map(\.key), ["lead", "copy", "design", "ops"])
        XCTAssertEqual(rec.members[2].template, "designer")
        XCTAssertNil(rec.members[1].template)
        XCTAssertEqual(p.options[0].skills, ["frontend-design"]); XCTAssertEqual(p.options[0].connectors, ["tiktok"])
        XCTAssertEqual(p.options[0].emoji, "👥")                                                           // default
        XCTAssertEqual(TeamProposalParser.stripped(block(good)), "Here are some setups.\n\nPick one.")
    }

    func testNoBlockOrBadJSONOrTooBigIsRefused() {
        XCTAssertThrowsError(try TeamProposalParser.parse("just a reply")) { XCTAssertEqual($0 as? TeamProposalError, .noBlock) }
        XCTAssertThrowsError(try TeamProposalParser.parse("```json\n{}\n```")) { XCTAssertEqual($0 as? TeamProposalError, .noBlock) }
        XCTAssertThrowsError(try TeamProposalParser.parse(block("not json"))) { XCTAssertEqual($0 as? TeamProposalError, .notJSON) }
        XCTAssertThrowsError(try TeamProposalParser.parse(block("[1,2]"))) { XCTAssertEqual($0 as? TeamProposalError, .notJSON) }
        XCTAssertThrowsError(try TeamProposalParser.parse(block(String(repeating: " ", count: 13_000) + "{}"))) { XCTAssertEqual($0 as? TeamProposalError, .tooBig) }
        XCTAssertThrowsError(try TeamProposalParser.parse(block(#"{"options":[]}"#))) { guard case TeamProposalError.noValidOptions = $0 else { return XCTFail() } }
        XCTAssertEqual(TeamProposalParser.stripped("no block"), "no block")
    }

    func testTheLastBlockWins() throws {
        let first = block(#"{"options":[{"label":"Old","name":"Old","lead":"a","members":[{"key":"a","name":"A"}]}]}"#)
        let p = try TeamProposalParser.parse(first + "\n\n" + block(good))
        XCTAssertEqual(p.options.first?.label, "Lean")
    }

    func testInvalidOptionsAreDroppedWithAReasonAndGoodOnesKept() throws {
        let nine = (1...9).map { #"{"key":"k\#($0)","name":"B\#($0)"}"# }.joined(separator: ",")
        let json = """
        {"options":[
         {"label":"Big","name":"X","lead":"k1","members":[\(nine)]},
         {"label":"NoLead","name":"X","lead":"zzz","members":[{"key":"a","name":"A"}]},
         {"label":"NoName","name":"  ","lead":"a","members":[{"key":"a","name":"A"}]},
         {"label":"Dup","name":"X","lead":"a","members":[{"key":"a","name":"A"},{"key":"a","name":"B"}]},
         {"label":"Empty","name":"X","lead":"a","members":[]},
         {"label":"Fine","name":"X","lead":"a","members":[{"key":"a","name":"A"}]},
         {"label":"fine","name":"Y","lead":"a","members":[{"key":"a","name":"A"}]},
         {"label":"Third","name":"Z","lead":"a","members":[{"key":"a","name":"A"}]},
         {"label":"Fourth","name":"W","lead":"a","members":[{"key":"a","name":"A"}]}]}
        """
        let p = try TeamProposalParser.parse(block(json))
        XCTAssertEqual(p.options.map(\.label), ["Fine", "Third", "Fourth"])
        XCTAssertEqual(p.dropped.count, 6)
        XCTAssertTrue(p.dropped.contains { $0.contains("9 members") })
        XCTAssertTrue(p.dropped.contains { $0.contains("lead must be one of the members") })
        XCTAssertTrue(p.dropped.contains { $0.contains("used twice") })
    }

    func testOnlyThreeOptionsAreUsed() throws {
        let one = { (n: Int) in #"{"label":"O\#(n)","name":"N\#(n)","lead":"a","members":[{"key":"a","name":"A"}]}"# }
        let p = try TeamProposalParser.parse(block(#"{"options":["# + (1...5).map(one).joined(separator: ",") + "]}"))
        XCTAssertEqual(p.options.count, 3)
        XCTAssertEqual(p.dropped.count, 2)
    }

    func testEightMembersIsTheLimitAndTextIsCleaned() throws {
        let eight = (1...8).map { #"{"key":"k\#($0)","name":"B\#($0)"}"# }.joined(separator: ",")
        XCTAssertEqual(try TeamProposalParser.parse(block(#"{"options":[{"label":"L","name":"N","lead":"k1","members":[\#(eight)]}]}"#)).options.first?.members.count, 8)
        let json = ##"{"goal":"Do\n it\u200b","options":[{"label":"L","name":"#Mark@eting\n","lead":"a","members":[{"key":"A","name":"@oscar","role":"Line one\nline two \u200bhidden"}],"skills":["x","x","y"]}]}"##
        let p = try TeamProposalParser.parse(block(json))
        XCTAssertEqual(p.goal, "Do it")
        XCTAssertEqual(p.options[0].name, "Marketing")
        XCTAssertEqual(p.options[0].members[0].name, "oscar")                                              // no @ or #: a name can't tag anyone
        XCTAssertEqual(p.options[0].members[0].role, "Line one line two hidden")
        XCTAssertEqual(p.options[0].members[0].key, "a")
        XCTAssertEqual(p.options[0].skills, ["x", "y"])
        let long = String(repeating: "w", count: 500)
        let q = try TeamProposalParser.parse(block(#"{"options":[{"label":"L","name":"\#(long)","lead":"a","members":[{"key":"a","name":"A","role":"\#(long)"}],"notes":"\#(long)"}]}"#))
        XCTAssertEqual(q.options[0].name.count, 40); XCTAssertEqual(q.options[0].members[0].role.count, 160); XCTAssertEqual(q.options[0].notes.count, 400)
    }

    func testAnUnknownTemplateBecomesACustomBot() throws {
        let p = try TeamProposalParser.parse(block(#"{"options":[{"label":"L","name":"N","lead":"a","members":[{"key":"a","name":"A","template":"no-such-role"}]}]}"#))
        XCTAssertNil(p.options[0].members[0].template)
    }

    // MARK: Launching

    private func option(_ label: String = "Recommended", name: String = "Marketing", skills: [String] = [], connectors: [String] = []) throws -> TeamOption {
        var o = try TeamProposalParser.parse(block(good)).options[1]
        o.label = label; o.name = name; o.skills = skills; o.connectors = connectors
        return o
    }

    func testLaunchCreatesTheGroupAndNewBotsInTheWorkspace() throws {
        let existing = try bots.create(name: "Copywriter")                                                  // a bot that already exists here
        try store.move(bot: existing.id, to: "biscuit")
        let before = bots.loadAll().count
        let r = try store.launch(try option(), goal: "Auto-post story-led shorts", in: "biscuit")
        XCTAssertEqual(r.group.name, "Marketing"); XCTAssertEqual(r.group.emoji, "📣")
        XCTAssertEqual(store.workspaceId(forGroup: r.group.id), "biscuit")
        XCTAssertEqual(r.group.everyone.count, 4)
        XCTAssertEqual(r.group.lead, r.bots["lead"]?.id)
        XCTAssertEqual(bots.loadAll().count, before + 4)                                                    // all new: nothing reused
        for b in r.bots.values { XCTAssertEqual(store.workspaceId(forBot: b.id), "biscuit") }
        XCTAssertEqual(r.bots["copy"]?.name, "Copywriter (2)")                                              // names stay unique in the workspace
        XCTAssertEqual(r.bots["design"]?.role, HireCatalog.template("designer")?.role)                      // a catalog role keeps its setup
        XCTAssertTrue(bots.instructions(for: r.bots["ops"]!.id).contains("Schedules posts"))
        XCTAssertEqual(r.group.rules, WorkspaceStore.proposedTeamRules)
        XCTAssertTrue(r.group.rules.contains("Ask me before posting"))
        XCTAssertTrue(r.firstMessage.contains("Goal: Auto-post story-led shorts"))
        XCTAssertTrue(r.firstMessage.contains("@\(r.bots["ops"]!.id)"))
        XCTAssertTrue(store.problems().isEmpty)
        XCTAssertEqual(ApprovalModes(paths: paths).mode(groupId: r.group.id), .ask)                         // starts in Ask me
        for b in r.bots.values where b.id != r.bots["design"]?.id { XCTAssertEqual(b.permission, .editWorkspace) }
    }

    func testGroupNamesStayUniqueAndTwoLaunchesDontClash() throws {
        let a = try store.launch(try option(), goal: "g", in: "biscuit")
        let b = try store.launch(try option(), goal: "g", in: "biscuit")
        XCTAssertEqual(a.group.name, "Marketing"); XCTAssertEqual(b.group.name, "Marketing (2)"); XCTAssertTrue(b.renamedGroup)
        XCTAssertNotEqual(a.group.id, b.group.id)
        XCTAssertEqual(Set(store.bots(in: "biscuit").map(\.name)).count, store.bots(in: "biscuit").count)
        let other = try store.launch(try option(), goal: "g", in: "general")                                 // another workspace may reuse the name
        XCTAssertEqual(other.group.name, "Marketing")
    }

    func testSkillsAreSwitchedOnConnectorsReported() throws {
        try SkillStore(paths: paths).save(id: "frontend-design", text: SkillFile.compose(name: "frontend-design", description: "d", body: "b"))
        let r = try store.launch(try option(skills: ["frontend-design", "ghost"], connectors: ["tiktok"]), goal: "g", in: "biscuit")
        XCTAssertEqual(ActiveSkillsStore(paths: paths).ids(.group(r.group.id)), ["frontend-design"])
        XCTAssertEqual(r.unknownSkills, ["ghost"])
        XCTAssertEqual(r.missingConnectors, ["tiktok"])
        XCTAssertEqual(r.group.connectors, [])
    }

    func testLaunchRefusesBadOptionsTargetsAndAnUnreadableFile() throws {
        var noLead = try option(); noLead.lead = "zzz"
        XCTAssertThrowsError(try store.launch(noLead, goal: "g", in: "biscuit")) { XCTAssertEqual($0 as? TeamLaunchError, .invalid) }
        var tooMany = try option(); tooMany.members += (1...5).map { ProposedMember(key: "x\($0)", name: "X\($0)", role: "", template: nil) }
        XCTAssertThrowsError(try store.launch(tooMany, goal: "g", in: "biscuit"))
        XCTAssertThrowsError(try store.launch(try option(), goal: "g", in: "nope")) { XCTAssertEqual($0 as? WorkspaceError, .notFound("nope")) }
        XCTAssertEqual(bots.loadAll().count, 0); XCTAssertEqual(groups.loadAll().count, 0)                   // nothing was made
        try Data("not json".utf8).write(to: store.file)
        XCTAssertThrowsError(try store.launch(try option(), goal: "g", in: "biscuit")) { XCTAssertEqual($0 as? WorkspaceError, .unreadable) }
        XCTAssertEqual(bots.loadAll().count, 0)
    }

    func testAFailurePartWayRemovesWhatWasMade() throws {
        // With the groups folder read-only the launch fails after its bots exist.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: paths.groups.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.groups.path) }
        XCTAssertThrowsError(try store.launch(try option(), goal: "g", in: "biscuit"))
        XCTAssertEqual(bots.loadAll().count, 0)
        XCTAssertEqual(store.load().bots, [:])
        XCTAssertEqual(store.load().groups, [:])
    }

    func testNothingIsCreatedByParsing() throws {
        _ = try TeamProposalParser.parse(block(good))
        XCTAssertEqual(bots.loadAll().count, 0); XCTAssertEqual(groups.loadAll().count, 0)
    }
}
