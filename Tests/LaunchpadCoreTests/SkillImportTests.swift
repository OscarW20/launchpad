import XCTest
@testable import LaunchpadCore

final class SkillImportTests: XCTestCase {
    var root: URL!
    var paths: LaunchpadPaths!
    var store: SkillStore!
    var home: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("lp-import-\(UUID().uuidString)", isDirectory: true)
        paths = LaunchpadPaths(root: root.appendingPathComponent("Launchpad", isDirectory: true))
        home = root.appendingPathComponent("home", isDirectory: true)
        try paths.ensureStructure()
        store = SkillStore(paths: paths)
    }

    override func tearDown() {
        try? fm.removeItem(at: root)
    }

    @discardableResult
    private func makeSkill(in parent: URL, _ id: String = "biscuit-jira-tickets", body: String = "# Tickets\n\n1. Write it plainly.", reference: String? = "Jira notes") throws -> URL {
        let dir = parent.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(SkillFile.compose(name: id, description: "Use when filing tickets.", body: body).utf8).write(to: dir.appendingPathComponent("SKILL.md"))
        if let reference {
            try fm.createDirectory(at: dir.appendingPathComponent("references"), withIntermediateDirectories: true)
            try Data(reference.utf8).write(to: dir.appendingPathComponent("references/jira.md"))
        }
        return dir
    }

    func testImportCopiesTheSkillAndItsReferences() throws {
        let source = try makeSkill(in: root.appendingPathComponent("elsewhere"))
        guard case .installed(let skill) = try store.importSkill(from: source) else { return XCTFail() }
        XCTAssertEqual(skill.id, "biscuit-jira-tickets")
        XCTAssertEqual(skill.description, "Use when filing tickets.")
        XCTAssertEqual(try String(contentsOf: paths.skills.appendingPathComponent("biscuit-jira-tickets/references/jira.md"), encoding: .utf8), "Jira notes")
        XCTAssertTrue(fm.fileExists(atPath: source.appendingPathComponent("SKILL.md").path), "the original is left where it was")
        let leftovers = (try fm.contentsOfDirectory(atPath: paths.skills.path)).filter { $0.hasPrefix(".import") }
        XCTAssertEqual(leftovers, [])
    }

    func testImportingAgainChangesNothing() throws {
        let source = try makeSkill(in: root.appendingPathComponent("elsewhere"))
        try store.importSkill(from: source)
        guard case .alreadyInstalled = try store.importSkill(from: source) else { return XCTFail() }
    }

    func testAnImportNeverReplacesADifferentSkill() throws {
        try store.capture(SkillDraft(name: "biscuit-jira-tickets", useWhen: "mine", steps: "my own steps"))
        let source = try makeSkill(in: root.appendingPathComponent("elsewhere"))
        XCTAssertThrowsError(try store.importSkill(from: source)) { XCTAssertEqual($0 as? SkillImportError, .taken("biscuit-jira-tickets")) }
        XCTAssertEqual(store.load(id: "biscuit-jira-tickets")?.body, "my own steps")
    }

    func testRefusals() throws {
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.importSkill(from: empty)) {
            if case SkillImportError.noSkillFile = $0 {} else { XCTFail("\($0)") }
        }
        let builtIn = try XCTUnwrap(SkillCatalog.all.first).id
        let clash = try makeSkill(in: root.appendingPathComponent("elsewhere"), builtIn)
        XCTAssertThrowsError(try store.importSkill(from: clash)) { XCTAssertEqual($0 as? SkillCaptureError, .builtIn(builtIn)) }
        let reserved = try makeSkill(in: root.appendingPathComponent("elsewhere"), "accept")
        XCTAssertThrowsError(try store.importSkill(from: reserved)) { XCTAssertEqual($0 as? SkillCaptureError, .reserved("accept")) }
    }

    func testALinkInsideTheSkillIsRefusedAndNothingIsLeftBehind() throws {
        let source = try makeSkill(in: root.appendingPathComponent("elsewhere"))
        try fm.createSymbolicLink(at: source.appendingPathComponent("references/secrets"), withDestinationURL: URL(fileURLWithPath: "/etc"))
        XCTAssertThrowsError(try store.importSkill(from: source)) {
            if case SkillImportError.unsafe = $0 {} else { XCTFail("\($0)") }
        }
        XCTAssertNil(store.load(id: "biscuit-jira-tickets"))
        XCTAssertEqual((try fm.contentsOfDirectory(atPath: paths.skills.path)).filter { $0.hasPrefix(".import") }, [])
    }

    func testAHugeSkillIsRefused() throws {
        let source = try makeSkill(in: root.appendingPathComponent("elsewhere"), reference: nil)
        for i in 0...SkillImport.maxFiles { try Data("x".utf8).write(to: source.appendingPathComponent("f\(i).md")) }
        XCTAssertThrowsError(try store.importSkill(from: source)) { XCTAssertEqual($0 as? SkillImportError, .tooLarge) }
        XCTAssertNil(store.load(id: "biscuit-jira-tickets"))
    }

    // MARK: Finding it on this Mac

    func testFindsTheSkillWhereClaudeKeepsIt() throws {
        let synced = home.appendingPathComponent(".claude/skills/synced/abc_def", isDirectory: true)
        let plugin = home.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions/skills-plugin/acct/org/skills", isDirectory: true)
        let old = try makeSkill(in: synced)
        let new = try makeSkill(in: plugin, body: "# Newer")
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: old.appendingPathComponent("SKILL.md").path)
        XCTAssertEqual(SkillSources.find(named: "biscuit-jira-tickets", home: home).map(\.path), [new.path, old.path], "newest first")
        XCTAssertEqual(SkillSources.find(named: "something-else", home: home), [])
        XCTAssertEqual(SkillSources.find(named: "../etc", home: home), [])
    }

    func testEnsureTicketSkill() throws {
        let settings = TicketSettings()
        XCTAssertThrowsError(try store.ensureTicketSkill(settings: settings, home: home)) {
            XCTAssertEqual($0 as? SkillImportError, .notFound("biscuit-jira-tickets"))
            XCTAssertTrue(($0 as? SkillImportError)?.errorDescription?.contains("~/Launchpad/skills") ?? false, "says exactly what to copy")
        }
        try makeSkill(in: home.appendingPathComponent(".claude/skills/synced/abc_def"))
        guard case .installed = try store.ensureTicketSkill(settings: settings, home: home) else { return XCTFail() }
        guard case .alreadyInstalled = try store.ensureTicketSkill(settings: settings, home: home) else { return XCTFail() }
        XCTAssertNotNil(store.load(id: "biscuit-jira-tickets"))
    }

    func testAChosenSkillIsUsed() throws {
        try makeSkill(in: home.appendingPathComponent(".claude/skills"), "support-tickets")
        let settings = TicketSettings(skillId: "support-tickets")
        guard case .installed(let skill) = try store.ensureTicketSkill(settings: settings, home: home) else { return XCTFail() }
        XCTAssertEqual(skill.id, "support-tickets")
        let draft = try TicketPrompt.build(request: TicketRequest(selectedText: "a bug"), settings: settings, skill: skill)
        XCTAssertTrue(draft.prompt.contains("\"support-tickets\" skill"))
    }
}
