import XCTest
@testable import LaunchpadCore

final class WorkspaceTests: XCTestCase {
    var paths: LaunchpadPaths!
    var bots: BotStore!
    var groups: GroupStore!
    var store: WorkspaceStore!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lp-ws-\(UUID().uuidString)")
        paths = LaunchpadPaths(root: root)
        try paths.ensureStructure()
        bots = BotStore(paths: paths)
        groups = GroupStore(paths: paths)
        store = WorkspaceStore(paths: paths)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: paths.root) }

    private func bot(_ name: String) throws -> Bot { try bots.create(name: name, role: "\(name) role") }
    private func group(_ name: String, _ members: [Bot]) throws -> BotGroup {
        try groups.create(name: name, members: members.map(\.id), lead: members.first?.id)
    }

    // MARK: Migration

    func testNoFileMeansEverythingIsInGeneralAndNothingIsWritten() throws {
        let a = try bot("Ava"), g = try group("Team", [a])
        XCTAssertEqual(store.workspaces.map(\.id), ["general"])
        XCTAssertEqual(store.workspaceId(forBot: a.id), "general")
        XCTAssertEqual(store.workspaceId(forGroup: g.id), "general")
        XCTAssertEqual(store.bots(in: "general").map(\.id), [a.id])
        XCTAssertEqual(store.groups(in: "general").map(\.id), [g.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file.path))
        XCTAssertTrue(store.problems().isEmpty)
    }

    func testCreatingAWorkspaceTouchesNoBotOrGroupFile() throws {
        let a = try bot("Ava"), g = try group("Team", [a])
        let botBefore = try Data(contentsOf: paths.botJSON(a.id)), groupBefore = try Data(contentsOf: groups.json(g.id))
        try store.create(name: "Biscuit")
        XCTAssertEqual(try Data(contentsOf: paths.botJSON(a.id)), botBefore)
        XCTAssertEqual(try Data(contentsOf: groups.json(g.id)), groupBefore)
        XCTAssertEqual(store.workspaceId(forBot: a.id), "general")
    }

    func testWorkspaceFileIsProtectedFromBots() {
        let c = GuardRulesFile.config(for: Bot(id: "x", name: "X"), paths: paths)
        XCTAssertTrue(c.protected.contains(store.file.path))
    }

    func testUnreadableFileIsReportedRefusedAndKeptUntilReset() throws {
        let a = try bot("Ava")
        try FileManager.default.createDirectory(at: store.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.file)
        XCTAssertTrue(store.isUnreadable)
        XCTAssertEqual(store.workspaces.map(\.id), ["general"])
        // Changes are refused and the file is untouched; no half-made copy is left behind.
        XCTAssertThrowsError(try store.create(name: "Biscuit")) { XCTAssertEqual($0 as? WorkspaceError, .unreadable) }
        XCTAssertThrowsError(try store.duplicate(bot: a.id, into: "general")) { XCTAssertEqual($0 as? WorkspaceError, .unreadable) }
        XCTAssertEqual(bots.loadAll().count, 1)
        XCTAssertEqual(try String(contentsOf: store.file, encoding: .utf8), "not json")

        let aside = try XCTUnwrap(try store.resetUnreadable())
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), "not json")
        XCTAssertFalse(store.isUnreadable)
        XCTAssertNil(try store.resetUnreadable())
        try store.create(name: "Biscuit")
        XCTAssertEqual(store.workspaces.map(\.name), ["General", "Biscuit"])
    }

    func testMissingFileIsNotUnreadable() { XCTAssertFalse(store.isUnreadable) }

    func testDanglingAssignmentFallsBackToGeneral() throws {
        let a = try bot("Ava")
        try FileManager.default.createDirectory(at: store.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"bots":{"\#(a.id)":"gone"},"workspaces":[]}"#.utf8).write(to: store.file)
        XCTAssertEqual(store.workspaceId(forBot: a.id), "general")
    }

    // MARK: Workspaces

    func testCreateRenameAndGeneralRules() throws {
        let w = try store.create(name: " Biscuit ", colour: "#FF0000", icon: "🍪")
        XCTAssertEqual(w.id, "biscuit")
        XCTAssertEqual(try store.create(name: "Biscuit!").id, "biscuit-2")   // different name, same slug
        XCTAssertThrowsError(try store.create(name: "  ")) { XCTAssertEqual($0 as? WorkspaceError, .emptyName) }
        var renamed = w; renamed.name = "Biscuit Pet Care"
        try store.update(renamed)
        XCTAssertEqual(store.workspaces[1].name, "Biscuit Pet Care")
        XCTAssertThrowsError(try store.delete(id: "general")) { XCTAssertEqual($0 as? WorkspaceError, .cantDeleteGeneral) }
        var general = store.workspaces[0]; general.name = "Everything"
        try store.update(general)
        XCTAssertEqual(store.workspaces.map(\.name), ["Everything", "Biscuit Pet Care", "Biscuit!"])
        try store.reorder(["biscuit-2"])
        XCTAssertEqual(store.workspaces.map(\.id), ["general", "biscuit-2", "biscuit"])
        XCTAssertEqual(store.workspaces[0].name, "Everything")
    }

    // MARK: Moving

    func testMovingAGroupMovesItsBots() throws {
        let a = try bot("Ava"), b = try bot("Ben"), c = try bot("Cy")
        let g = try group("Team", [a, b])
        try store.create(name: "Biscuit")
        let moved = try store.move(group: g.id, to: "biscuit")
        XCTAssertEqual(Set(moved.movedBots), [a.id, b.id])
        XCTAssertEqual(store.workspaceId(forGroup: g.id), "biscuit")
        XCTAssertEqual(Set(store.bots(in: "biscuit").map(\.id)), [a.id, b.id])
        XCTAssertEqual(store.bots(in: "general").map(\.id), [c.id])
        XCTAssertTrue(store.problems().isEmpty)
        try store.move(group: g.id, to: "general")
        XCTAssertEqual(store.bots(in: "general").count, 3)
        XCTAssertEqual(try String(contentsOf: store.file, encoding: .utf8).contains(a.id), false)   // back to General: no entry
    }

    func testABotInAGroupCannotMoveAlone() throws {
        let a = try bot("Ava"), loner = try bot("Lou")
        let g = try group("Team", [a])
        try store.create(name: "Biscuit")
        XCTAssertThrowsError(try store.move(bot: a.id, to: "biscuit")) { XCTAssertEqual($0 as? WorkspaceError, .botInGroups([g.name])) }
        XCTAssertEqual(store.workspaceId(forBot: a.id), "general")
        try store.move(bot: loner.id, to: "biscuit")
        XCTAssertEqual(store.workspaceId(forBot: loner.id), "biscuit")
        XCTAssertThrowsError(try store.move(bot: loner.id, to: "nope"))
    }

    func testSharedBotsAskDuplicateOrLeaveOut() throws {
        func setup() throws -> (Bot, Bot, BotGroup, BotGroup) {
            let a = try bot("Ava\(UUID().uuidString.prefix(3))"), b = try bot("Ben\(UUID().uuidString.prefix(3))")
            return (a, b, try group("Moves\(a.id)", [a, b]), try group("Stays\(a.id)", [a]))
        }
        try store.create(name: "Biscuit")

        var (a, _, moving, staying) = try setup()
        XCTAssertThrowsError(try store.move(group: moving.id, to: "biscuit")) {
            XCTAssertEqual($0 as? WorkspaceError, .sharedBots([SharedBot(botId: a.id, otherGroups: [staying.id])]))
        }
        XCTAssertEqual(store.workspaceId(forGroup: moving.id), "general")   // nothing changed

        let dup = try store.move(group: moving.id, to: "biscuit", shared: .duplicate)
        let copyId = try XCTUnwrap(dup.duplicates[a.id])
        XCTAssertEqual(store.workspaceId(forBot: copyId), "biscuit")
        XCTAssertEqual(store.workspaceId(forBot: a.id), "general")              // the original stays with its other group
        XCTAssertEqual(try groups.load(id: moving.id).everyone.contains(copyId), true)
        XCTAssertEqual(try groups.load(id: moving.id).everyone.contains(a.id), false)
        XCTAssertEqual(try groups.load(id: staying.id).members, [a.id])
        XCTAssertTrue(store.problems().isEmpty)

        (a, _, moving, staying) = try setup()
        let left = try store.move(group: moving.id, to: "biscuit", shared: .leaveOut)
        XCTAssertEqual(left.leftOut, [a.id])
        XCTAssertEqual(try groups.load(id: moving.id).everyone.contains(a.id), false)
        XCTAssertNotNil(try groups.load(id: moving.id).lead)
        XCTAssertEqual(store.workspaceId(forBot: a.id), "general")
        XCTAssertTrue(store.problems().isEmpty)
    }

    func testCanAddOnlyFromTheSameWorkspace() throws {
        let a = try bot("Ava"), b = try bot("Ben")
        let g = try group("Team", [a])
        try store.create(name: "Biscuit")
        XCTAssertTrue(store.canAdd(bot: b.id, toGroup: g.id))
        try store.move(bot: b.id, to: "biscuit")
        XCTAssertFalse(store.canAdd(bot: b.id, toGroup: g.id))
    }

    func testProblemsFindsAMemberInAnotherWorkspace() throws {
        let a = try bot("Ava"), b = try bot("Ben")
        let g = try group("Team", [a])
        try store.create(name: "Biscuit")
        try store.move(bot: b.id, to: "biscuit")
        var edited = try groups.load(id: g.id); edited.members.append(b.id); try groups.save(edited)
        XCTAssertEqual(store.problems(), [WorkspaceProblem(groupId: g.id, botId: b.id)])
    }

    // MARK: Duplicating

    func testDuplicateHasItsOwnEmptyMemoryAndSameSetup() throws {
        var a = try bot("Ava")
        a.connectors = ["jira"]; a.skills = ["x"]; a.engine = .codex
        try bots.save(a)
        try bots.setInstructions("Be Ava.", for: a.id)
        try Data("# memory\n- secret fact about Biscuit\n".utf8).write(to: paths.memoryMD(a.id))
        try store.create(name: "Launchpad")
        let copy = try store.duplicate(bot: a.id, into: "launchpad")

        XCTAssertNotEqual(copy.id, a.id)
        XCTAssertEqual(copy.name, "Ava")
        XCTAssertEqual(copy.connectors, ["jira"])
        XCTAssertEqual(copy.engine, .codex)
        XCTAssertEqual(bots.instructions(for: copy.id), "Be Ava.")
        let memory = try String(contentsOf: paths.memoryMD(copy.id), encoding: .utf8)
        XCTAssertFalse(memory.contains("secret fact"))
        XCTAssertEqual(try String(contentsOf: paths.memoryMD(a.id), encoding: .utf8).contains("secret fact"), true)
        XCTAssertNotEqual(paths.workspace(copy.id), paths.workspace(a.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.workspace(copy.id).path))
        XCTAssertEqual(store.workspaceId(forBot: copy.id), "launchpad")
        XCTAssertEqual(store.workspaceId(forBot: a.id), "general")
        XCTAssertEqual(store.origin(ofBot: copy.id), BotOrigin(botId: a.id, workspaceId: "general"))
        XCTAssertNil(store.origin(ofBot: a.id))
        XCTAssertThrowsError(try store.duplicate(bot: a.id, into: "nope"))
        XCTAssertThrowsError(try store.duplicate(bot: "ghost", into: "launchpad"))
    }

    // MARK: Chats and routines

    func testChatsAndRoutinesFollowTheirBotOrGroup() throws {
        let a = try bot("Ava"), g = try group("Team", [a]), loner = try bot("Lou")
        try store.create(name: "Biscuit")
        try store.move(group: g.id, to: "biscuit")
        try store.move(bot: loner.id, to: "biscuit")
        XCTAssertEqual(store.workspaceId(for: ChatMeta(title: "#Team", kind: .group, groupId: g.id)), "biscuit")
        XCTAssertEqual(store.workspaceId(for: ChatMeta(title: "Lou", kind: .bot, botId: loner.id)), "biscuit")
        XCTAssertEqual(store.workspaceId(for: ChatMeta(title: "x", kind: .bot, botId: "unknown")), "general")
        XCTAssertEqual(store.workspaceId(for: .group(g.id)), "biscuit")
        XCTAssertEqual(store.workspaceId(for: .bot(loner.id)), "biscuit")
    }

    // MARK: Deleting

    func testDeleteNeverLosesContents() throws {
        let a = try bot("Ava"), b = try bot("Ben")
        let g = try group("Team", [a])
        try store.create(name: "Biscuit"); try store.create(name: "Other")
        try store.move(group: g.id, to: "biscuit")
        try store.move(bot: b.id, to: "biscuit")
        let copy = try store.duplicate(bot: b.id, into: "other")
        _ = copy

        XCTAssertThrowsError(try store.delete(id: "biscuit")) { XCTAssertEqual($0 as? WorkspaceError, .notEmpty(bots: 2, groups: 1)) }
        XCTAssertEqual(store.workspaces.count, 3)
        XCTAssertThrowsError(try store.delete(id: "biscuit", movingContentsTo: "biscuit"))
        XCTAssertThrowsError(try store.delete(id: "biscuit", movingContentsTo: "nope"))

        try store.delete(id: "biscuit", movingContentsTo: "other")
        XCTAssertEqual(store.workspaces.map(\.id), ["general", "other"])
        XCTAssertEqual(store.workspaceId(forGroup: g.id), "other")
        XCTAssertEqual(store.workspaceId(forBot: a.id), "other")
        XCTAssertEqual(store.workspaceId(forBot: b.id), "other")
        XCTAssertEqual(bots.loadAll().count, 3)            // every bot is still there
        XCTAssertEqual(groups.loadAll().count, 1)
        XCTAssertTrue(store.problems().isEmpty)
        XCTAssertEqual(store.origin(ofBot: copy.id)?.workspaceId, "other")

        try store.create(name: "Empty")
        try store.delete(id: "empty")                      // empty ones need no destination
        XCTAssertEqual(store.workspaces.map(\.id), ["general", "other"])
        XCTAssertThrowsError(try store.delete(id: "empty")) { XCTAssertEqual($0 as? WorkspaceError, .notFound("empty")) }
    }

    // MARK: Names, empty groups and delete into itself

    func testNamesMustBeUniqueIgnoringCase() throws {
        try store.create(name: "Biscuit")
        XCTAssertThrowsError(try store.create(name: " biscuit ")) { XCTAssertEqual($0 as? WorkspaceError, .nameTaken("biscuit")) }
        XCTAssertThrowsError(try store.create(name: "GENERAL")) { XCTAssertEqual($0 as? WorkspaceError, .nameTaken("GENERAL")) }
        let other = try store.create(name: "Other")
        var clash = other; clash.name = "BISCUIT"
        XCTAssertThrowsError(try store.update(clash))
        var same = other; same.colour = "#00FF00"; same.name = "other"   // keeping your own name (new case) is fine
        try store.update(same)
        XCTAssertEqual(store.workspaces.last?.name, "other")
    }

    func testLeaveOutRefusesToEmptyAGroup() throws {
        let a = try bot("Ava")
        let moving = try group("Moves", [a]), staying = try group("Stays", [a])
        _ = staying
        try store.create(name: "Biscuit")
        XCTAssertThrowsError(try store.move(group: moving.id, to: "biscuit", shared: .leaveOut)) {
            XCTAssertEqual($0 as? WorkspaceError, .groupWouldBeEmpty(moving.name))
        }
        XCTAssertEqual(store.workspaceId(forGroup: moving.id), "general")
        XCTAssertEqual(try groups.load(id: moving.id).members, [a.id])
        // Copying instead still works.
        XCTAssertNoThrow(try store.move(group: moving.id, to: "biscuit", shared: .duplicate))
    }

    func testDeleteIntoItselfSaysSo() throws {
        let a = try bot("Ava")
        try store.create(name: "Biscuit")
        try store.move(bot: a.id, to: "biscuit")
        XCTAssertThrowsError(try store.delete(id: "biscuit", movingContentsTo: "biscuit")) { XCTAssertEqual($0 as? WorkspaceError, .sameWorkspace) }
    }

    // MARK: Wrong-typed fields and the backup

    func testAWrongTypedFieldIsUnreadableNotSilentlyDropped() throws {
        try FileManager.default.createDirectory(at: store.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        for bad in [#"{"groups":"oops"}"#, #"{"bots":{"a":5}}"#, #"{"workspaces":[{"id":"x"}]}"#, "[]"] {
            try Data(bad.utf8).write(to: store.file)
            XCTAssertTrue(store.isUnreadable, bad)
            XCTAssertThrowsError(try store.create(name: "Biscuit"), bad) { XCTAssertEqual($0 as? WorkspaceError, .unreadable) }
            XCTAssertEqual(try String(contentsOf: store.file, encoding: .utf8), bad)
        }
        // Keys that are simply missing are fine.
        try Data("{}".utf8).write(to: store.file)
        XCTAssertFalse(store.isUnreadable)
        XCTAssertNoThrow(try store.create(name: "Biscuit"))
    }

    func testEachWriteKeepsTheLastGoodFileAsBak() throws {
        try store.create(name: "Biscuit")
        let bak = store.file.deletingLastPathComponent().appendingPathComponent("workspaces.json.bak")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bak.path))   // nothing to keep the first time
        let before = try Data(contentsOf: store.file)
        try store.create(name: "Launchpad")
        XCTAssertEqual(try Data(contentsOf: bak), before)
        XCTAssertEqual(store.workspaces.map(\.name), ["General", "Biscuit", "Launchpad"])
    }

    // MARK: Duplicating a group

    private func team() throws -> (lead: Bot, a: Bot, b: Bot, group: BotGroup) {
        let lead = try bot("Lea"), a = try bot("Ava"), b = try bot("Ben")
        try bots.setInstructions("Be Ava.", for: a.id)
        try Data("# memory\n- Biscuit secret\n".utf8).write(to: paths.memoryMD(a.id))
        var g = try groups.create(name: "Dev Team", members: [a.id, b.id], lead: lead.id, rules: "Be kind.", handoffLimit: 5)
        g.skills = ["s1"]; g.connectors = ["jira"]
        try groups.save(g)
        try Data("shared notes".utf8).write(to: groups.workspace(g.id).appendingPathComponent("notes.txt"))
        try store.create(name: "Biscuit")
        return (lead, a, b, g)
    }

    func testDuplicateGroupCopiesEverythingAndSharesNothing() throws {
        let t = try team()
        let r = try store.duplicate(group: t.group.id, into: "biscuit")
        let copy = r.group

        XCTAssertNotEqual(copy.id, t.group.id)
        XCTAssertEqual(copy.name, "Dev Team")
        XCTAssertFalse(r.renamed)
        XCTAssertEqual(store.workspaceId(forGroup: copy.id), "biscuit")
        XCTAssertEqual(copy.rules, "Be kind.")
        XCTAssertEqual(copy.handoffLimit, 5)
        XCTAssertEqual(copy.skills, ["s1"]); XCTAssertEqual(copy.connectors, ["jira"])
        // Lead and member order kept, all new bots in the new workspace.
        XCTAssertEqual(copy.lead, r.bots[t.lead.id])
        XCTAssertEqual(copy.members, [t.a.id, t.b.id].map { r.bots[$0]! })
        XCTAssertEqual(Set(r.bots.values).intersection([t.lead.id, t.a.id, t.b.id]), [])
        for new in r.bots.values { XCTAssertEqual(store.workspaceId(forBot: new), "biscuit") }
        XCTAssertTrue(store.problems().isEmpty)
        // Nothing shared: own empty memory, own folders, empty project folder, fresh summary.
        let copyA = try XCTUnwrap(r.bots[t.a.id])
        XCTAssertFalse(try String(contentsOf: paths.memoryMD(copyA), encoding: .utf8).contains("Biscuit secret"))
        XCTAssertEqual(bots.instructions(for: copyA), "Be Ava.")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: groups.workspace(copy.id).path), [])
        XCTAssertEqual(try String(contentsOf: groups.summary(copy.id), encoding: .utf8).contains("Dev Team"), true)
        // The original is untouched.
        XCTAssertEqual(store.workspaceId(forGroup: t.group.id), "general")
        XCTAssertEqual(try groups.load(id: t.group.id).members, [t.a.id, t.b.id])
        XCTAssertTrue(try String(contentsOf: paths.memoryMD(t.a.id), encoding: .utf8).contains("Biscuit secret"))
        XCTAssertEqual(store.origin(ofGroup: copy.id), GroupOrigin(groupId: t.group.id, workspaceId: "general", rootId: t.group.id))
    }

    func testDuplicateGroupNamesStayUniqueInTheWorkspace() throws {
        let t = try team()
        let first = try store.duplicate(group: t.group.id, into: "biscuit")
        let second = try store.duplicate(group: t.group.id, into: "biscuit")
        XCTAssertEqual(second.group.name, "Dev Team (2)")
        XCTAssertTrue(second.renamed)
        XCTAssertEqual(try store.duplicate(group: t.group.id, into: "biscuit").group.name, "Dev Team (3)")
        // Bots in the same workspace don't end up with the same name either.
        let names = store.bots(in: "biscuit").map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertTrue(second.bots.values.contains { (try? bots.load(id: $0))?.name == "Ava (2)" })
        // An explicit name must be free; a free one is used as given.
        XCTAssertThrowsError(try store.duplicate(group: t.group.id, into: "biscuit", name: "dev team")) { XCTAssertEqual($0 as? WorkspaceError, .nameTaken("dev team")) }
        XCTAssertEqual(try store.duplicate(group: t.group.id, into: "biscuit", name: "Biscuit Crew").group.name, "Biscuit Crew")
        _ = first
    }

    func testDuplicateGroupSkipsDeletedMembersAndRefusesBadTargets() throws {
        let t = try team()
        try FileManager.default.removeItem(at: paths.botDir(t.b.id))
        let r = try store.duplicate(group: t.group.id, into: "biscuit")
        XCTAssertEqual(r.group.members.count, 1)
        XCTAssertNil(r.bots[t.b.id])
        XCTAssertThrowsError(try store.duplicate(group: t.group.id, into: "nope")) { XCTAssertEqual($0 as? WorkspaceError, .notFound("nope")) }
        XCTAssertThrowsError(try store.duplicate(group: "ghost", into: "biscuit"))
    }

    func testDuplicateGroupRefusesAnUnreadableFileAndLeavesNothingBehind() throws {
        let t = try team()
        try Data("not json".utf8).write(to: store.file)
        let botsBefore = bots.loadAll().count, groupsBefore = groups.loadAll().count
        XCTAssertThrowsError(try store.duplicate(group: t.group.id, into: "biscuit")) { XCTAssertEqual($0 as? WorkspaceError, .unreadable) }
        XCTAssertEqual(bots.loadAll().count, botsBefore)
        XCTAssertEqual(groups.loadAll().count, groupsBefore)
    }

    func testFamilyLookupFollowsCopiesOfCopies() throws {
        let t = try team()
        try store.create(name: "Launchpad")
        XCTAssertEqual(store.familyId(ofGroup: t.group.id), t.group.id)
        XCTAssertEqual(store.team(family: t.group.id, in: "general")?.id, t.group.id)
        XCTAssertNil(store.team(family: t.group.id, in: "biscuit"))
        XCTAssertEqual(store.workspaces(holding: t.group.id), ["general"])

        let inBiscuit = try store.duplicate(group: t.group.id, into: "biscuit").group
        let inLaunchpad = try store.duplicate(group: inBiscuit.id, into: "launchpad").group   // a copy of a copy
        XCTAssertEqual(store.familyId(ofGroup: inLaunchpad.id), t.group.id)
        XCTAssertEqual(store.origin(ofGroup: inLaunchpad.id)?.groupId, inBiscuit.id)
        XCTAssertEqual(store.team(family: t.group.id, in: "launchpad")?.id, inLaunchpad.id)
        XCTAssertEqual(store.workspaces(holding: t.group.id), ["general", "biscuit", "launchpad"])
        // A different team isn't matched.
        let other = try group("Other", [try bot("Zed")])
        XCTAssertNil(store.team(family: other.id, in: "biscuit"))
    }

    func testDeletingAWorkspaceKeepsGroupOriginsPointingAtARealPlace() throws {
        let t = try team()
        try store.create(name: "Launchpad")
        let copy = try store.duplicate(group: t.group.id, into: "biscuit").group
        try store.move(group: t.group.id, to: "launchpad")
        try store.delete(id: "launchpad", movingContentsTo: "general")
        XCTAssertEqual(store.origin(ofGroup: copy.id)?.workspaceId, "general")
    }

    func testAddTeamFromAPackInstallsCopiesAndNeverDoublesUp() throws {
        let pack = TeamPacks.dev
        // Nowhere yet: installed, and it lands in Biscuit with its bots.
        let first = try store.addTeam(pack, to: "general")
        XCTAssertEqual(first.how, .installed)
        try store.create(name: "Biscuit")
        try store.create(name: "Launchpad")
        try store.move(group: first.group.id, to: "launchpad")
        XCTAssertEqual(store.team(family: pack.groupId, in: "launchpad")?.id, pack.groupId)
        XCTAssertNil(store.team(family: pack.groupId, in: "biscuit"))

        // In Launchpad already: Open, no change.
        let again = try store.addTeam(pack, to: "launchpad")
        XCTAssertEqual(again.how, .alreadyThere)
        XCTAssertEqual(again.group.id, pack.groupId)
        let botCount = bots.loadAll().count

        // Not in Biscuit: its own copy, the Launchpad team untouched.
        let mine = try store.addTeam(pack, to: "biscuit")
        XCTAssertEqual(mine.how, .copied)
        XCTAssertNotEqual(mine.group.id, pack.groupId)
        XCTAssertEqual(store.workspaceId(forGroup: mine.group.id), "biscuit")
        XCTAssertEqual(store.workspaceId(forGroup: pack.groupId), "launchpad")
        XCTAssertEqual(bots.loadAll().count, botCount + pack.everyone.count)
        XCTAssertEqual(mine.group.lead.flatMap { try? bots.load(id: $0) }?.name, try bots.load(id: "lead").name)
        // And a second Add in Biscuit is just Open.
        XCTAssertEqual(try store.addTeam(pack, to: "biscuit").how, .alreadyThere)
        XCTAssertEqual(bots.loadAll().count, botCount + pack.everyone.count)
        XCTAssertTrue(store.problems().isEmpty)
    }
}
