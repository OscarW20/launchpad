import XCTest
@testable import LaunchpadCore

// Memory: MEMORY.md topics, merging, redaction, the size cap, versions and Undo, notes.md import,
// and the background review (schedule, budget, back-off, the engine call).

private func fact(_ topic: String, _ text: String) -> MemoryBook.Fact { .init(topic: topic, text: text) }

final class MemoryMergeTests: XCTestCase {
    func testMergeIntoEmptyFilesFactsUnderTopicsInOrder() {
        let r = MemoryBook.merge("", facts: [
            fact("Projects", "Building the Launchpad Mac app."),
            fact("preferences", "Prefers British spelling."),
            fact("person", "Sam is the iOS lead."),
        ])
        XCTAssertEqual(r.text, """
        ## Preferences
        - Prefers British spelling.

        ## People
        - Sam is the iOS lead.

        ## Projects
        - Building the Launchpad Mac app.

        """)
        XCTAssertEqual(r.added.count, 3)
        XCTAssertTrue(r.changed)
    }

    func testKeepsYourOwnTextAndSections() {
        let mine = """
        # Memory for Rex

        Written by hand, keep this.

        ## Shopping list
        - Dog food

        ## Preferences
        - Likes short answers.
        """
        let r = MemoryBook.merge(mine, facts: [fact("Preferences", "Wants replies in plain English.")])
        XCTAssertTrue(r.text.hasPrefix("# Memory for Rex\n\nWritten by hand, keep this.\n\n## Shopping list\n- Dog food\n"))
        XCTAssertTrue(r.text.contains("## Preferences\n- Likes short answers.\n- Wants replies in plain English.\n"))
    }

    func testSkipsDuplicatesAcrossCaseAndPunctuation() {
        let mine = "## Preferences\n- Prefers British spelling.\n"
        let r = MemoryBook.merge(mine, facts: [
            fact("Preferences", "prefers british spelling"),
            fact("How I work", "PREFERS BRITISH SPELLING!!"),
            fact("Preferences", "The user prefers British spelling"),
        ])
        XCTAssertEqual(r.added, [])
        XCTAssertFalse(r.changed)
        XCTAssertEqual(r.text, mine)
    }

    func testDuplicatesWithinOneBatchAreAddedOnce() {
        let r = MemoryBook.merge("", facts: [fact("Decisions", "Ship on Fridays only."), fact("Decisions", "Ship on Fridays only")])
        XCTAssertEqual(r.added, ["Ship on Fridays only."])
    }

    func testAFactThatExtendsAnOldOneReplacesItInPlace() {
        let r = MemoryBook.merge("## Preferences\n- Prefers British spelling\n- Likes tea\n",
                                 facts: [fact("Preferences", "Prefers British spelling in all documents")])
        XCTAssertEqual(r.text, "## Preferences\n- Prefers British spelling in all documents\n- Likes tea\n")
        XCTAssertEqual(r.added, ["Prefers British spelling in all documents"])
    }

    func testUnknownTopicGoesToNotes() {
        let r = MemoryBook.merge("", facts: [fact("Random stuff", "Has a dog called Rex.")])
        XCTAssertEqual(r.text, "## Notes\n- Has a dog called Rex.\n")
    }

    func testCleansBulletsHeadingsAndNewlines() {
        let r = MemoryBook.merge("", facts: [fact("Projects", "- ## Working on\nthe   rewards app")])
        XCTAssertEqual(r.added, ["Working on the rewards app"])
    }

    func testCondenseFoldsOldLines() {
        let mine = "## Projects\n- Old thing A\n- Old thing B\n- Keep me\n"
        let r = MemoryBook.merge(mine, facts: [], condense: [.init(topic: "Projects", replaces: ["Old thing A", "old thing b"], text: "Old things A and B")])
        XCTAssertEqual(r.text, "## Projects\n- Old things A and B\n- Keep me\n")
    }

    func testTidyingBlankLinesAloneIsNotAChange() {
        let messy = "\n\n## Preferences\n\n\n- Likes tea.\n\n\n"
        XCTAssertFalse(MemoryBook.merge(messy, facts: [fact("Preferences", "likes tea")]).changed)
    }

    func testCondenseNeedsTwoRealMatches() {
        let mine = "## Projects\n- Old thing A\n"
        let r = MemoryBook.merge(mine, facts: [], condense: [.init(topic: "Projects", replaces: ["Old thing A", "Not there"], text: "Summary")])
        XCTAssertEqual(r.text, mine)
    }

    func testParsesReviewWrappedInProse() {
        let reply = "Sure!\n```json\n{\"facts\":[{\"topic\":\"People\",\"text\":\"Ana runs QA.\"}]}\n```"
        XCTAssertEqual(MemoryBook.parseReview(reply)?.facts, [fact("People", "Ana runs QA.")])
        XCTAssertNil(MemoryBook.parseReview("no json here"))
    }

    func testByteOrderMarkDoesNotDuplicateHeadings() {
        let r = MemoryBook.merge("\u{FEFF}## Preferences\n- Likes tea\n", facts: [fact("Preferences", "Prefers dark mode in every app")])
        XCTAssertEqual(r.text, "## Preferences\n- Likes tea\n- Prefers dark mode in every app\n")
    }

    func testIntroIsNeverRewrittenOrCondensed() {
        let intro = "Ana works at Acme\nLikes tea\nLikes coffee\n\n## Preferences\n- Likes tea\n- Likes coffee\n"
        let extended = MemoryBook.merge(intro, facts: [fact("People", "Ana works at Acme as design lead")])
        XCTAssertTrue(extended.text.hasPrefix("Ana works at Acme\nLikes tea\nLikes coffee\n"))
        XCTAssertTrue(extended.text.contains("## People\n- Ana works at Acme as design lead"))
        let condensed = MemoryBook.merge(intro, facts: [], condense: [.init(topic: "Preferences", replaces: ["Likes tea", "Likes coffee"], text: "Likes hot drinks")])
        XCTAssertTrue(condensed.text.hasPrefix("Ana works at Acme\nLikes tea\nLikes coffee\n"))
        XCTAssertTrue(condensed.text.contains("## Preferences\n- Likes hot drinks\n"))
    }

    func testEditingAnotherLineFollowsTheClickedOne() throws {
        let text = "## Preferences\n- Likes tea\n- Likes jazz\n- Likes cats\n"
        let r = MemoryBook.editLine(text, at: .init(section: 1, line: 0), to: "", follow: .init(section: 1, line: 1))
        let d = MemoryBook.Doc(r.text)
        let f = try XCTUnwrap(r.followed)
        XCTAssertEqual(MemoryBook.entryText(d.sections[f.section].lines[f.line]), "Likes jazz")

        let spaced = "## Preferences\n\n- Likes tea\n- Likes jazz\n"
        let s = MemoryBook.editLine(spaced, at: .init(section: 1, line: 1), to: "Likes green tea", follow: .init(section: 1, line: 2))
        let ds = MemoryBook.Doc(s.text)
        let fs = try XCTUnwrap(s.followed)
        XCTAssertEqual(MemoryBook.entryText(ds.sections[fs.section].lines[fs.line]), "Likes jazz")
        XCTAssertTrue(s.text.contains("- Likes green tea\n"))
    }

    func testOutlineAndAddEntry() {
        let text = "# Rex's memory\n\nIntro.\n\n## Shopping list\n- Dog food\n\n## Preferences\n- Likes tea\n"
        let outline = MemoryBook.outline(text)
        XCTAssertEqual(outline.map(\.title), [nil, "Shopping list", "Preferences"])
        XCTAssertEqual(outline[2].entries.map(\.text), ["Likes tea"])
        XCTAssertTrue(outline[2].isReviewTopic)
        XCTAssertFalse(outline[1].isReviewTopic)

        XCTAssertEqual(MemoryBook.addEntry("Chew toys", topic: "Shopping list", to: text).text,
                       "# Rex's memory\n\nIntro.\n\n## Shopping list\n- Dog food\n- Chew toys\n\n## Preferences\n- Likes tea\n")
        XCTAssertTrue(MemoryBook.addEntry("Ana runs QA", topic: "people", to: text).text.contains("## People\n- Ana runs QA\n"))
        XCTAssertFalse(MemoryBook.addEntry("likes tea", topic: "Preferences", to: text).changed, "duplicate")
        XCTAssertFalse(MemoryBook.addEntry("My password is hunter2", topic: "Notes", to: text).changed, "secret")
    }
}

final class MemoryRedactionTests: XCTestCase {
    func testRedactsKnownSecretShapes() {
        let samples = [
            "my key is sk-ant-api03-AbCdEfGhIjKlMnOpQrStUv",
            "token ghp_1234567890abcdefghijABCDEFGHIJ",
            "AWS AKIAIOSFODNN7EXAMPLE here",
            "jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
            "-----BEGIN RSA PRIVATE KEY-----\nMIIEow\n-----END RSA PRIVATE KEY-----",
            "card 4242 4242 4242 4242 please",
            "xoxb-123456789012-abcdefghij",
            "Authorization: Bearer abcdef1234567890abcdef",
            "https://admin:hunter2@example.com/db",
        ]
        for s in samples {
            let out = MemoryBook.redact(s)
            XCTAssertTrue(out.contains("[redacted]"), "not redacted: \(s) → \(out)")
            XCTAssertTrue(MemoryBook.containsSecret(s), s)
        }
        XCTAssertFalse(MemoryBook.redact("sk-ant-api03-AbCdEfGhIjKlMnOpQrStUv").contains("AbCdEf"))
    }

    func testRedactsLabelledPasswordsButKeepsTheLabel() {
        XCTAssertEqual(MemoryBook.redact("My password is hunter2, thanks"), "My password is [redacted], thanks")
        XCTAssertEqual(MemoryBook.redact("api key: abc123"), "api key: [redacted]")
        XCTAssertEqual(MemoryBook.redact("PIN = 4821"), "PIN = [redacted]")
    }

    func testRedactsSecretsThatUsedToSlipThrough() {
        let expected: [(String, String)] = [
            ("my password is: hunter2", "my password is: [redacted]"),
            ("The wifi password for the office is hunter2", "The wifi password for the office is [redacted]"),
            ("pw: hunter2", "pw: [redacted]"),
            ("password - hunter2", "password - [redacted]"),
            ("Password = \"correct horse battery\"", "Password = [redacted]"),
            ("the passwords are hunter2 and swordfish", "the passwords are [redacted]"),
            ("Login: sam / Hunter2!", "Login: [redacted]"),
        ]
        for (input, output) in expected { XCTAssertEqual(MemoryBook.redact(input), output, input) }
        let leaks = [
            "aws secret wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            "gitlab glpat-abcdefghij0123456789",
            // Built at runtime so GitHub's secret scanner doesn't mistake the fake for a real webhook.
            "slack https://hooks.slack" + ".com/services/T00000000/B00000000/" + String(repeating: "X", count: 24),
            "google oauth ya29.a0AfH6SMBx3abcdefghiJKLMNOP",
        ]
        for s in leaks {
            XCTAssertTrue(MemoryBook.containsSecret(s), s)
            XCTAssertTrue(MemoryBook.redact(s).contains("[redacted]"), s)
        }
        XCTAssertFalse(MemoryBook.redact(leaks[0]).contains("EXAMPLEKEY"))
        XCTAssertFalse(MemoryBook.redact(leaks[2]).contains("XXXXXXXX"))
        let r = MemoryBook.merge("", facts: (expected.map(\.0) + leaks).map { fact("Notes", $0) })
        XCTAssertEqual(r.added, [])
    }

    func testOrdinaryTextStaysReadable() {
        let ordinary = [
            "Prefers British spelling and short replies.",
            "Works in /Users/sam/Documents/Launchpad/Sources/LaunchpadCore/Runner most days.",
            "Keeps designs in Figma/Acme/Onboarding/Screens2024/Final",
            "Their phone is +44 7700 900123.",
            "Uses https://launchpad-demo.vercel.app for releases.",
            "Wants the password reset screen redesigned.",
            "Prefers emoji 🙂 and naïve café names.",
        ]
        for s in ordinary { XCTAssertEqual(MemoryBook.redact(s), s) }
    }

    func testSecretFactsAreNeverStored() {
        let r = MemoryBook.merge("", facts: [
            fact("Preferences", "Their GitHub token is ghp_1234567890abcdefghijABCDEFGHIJ"),
            fact("How I work", "Wifi password: correcthorse"),
            fact("People", "Ana's key is [redacted]"),
            fact("Projects", "Ships the rewards app in March."),
        ])
        XCTAssertEqual(r.added, ["Ships the rewards app in March."])
        XCTAssertFalse(r.text.contains("ghp_"))
        XCTAssertFalse(r.text.contains("correcthorse"))
    }
}

final class MemorySizeCapTests: XCTestCase {
    func testStaysUnderCapAndFoldsOldestFirst() {
        var mine = "# Rex's memory\n\nIntro stays.\n\n## Projects\n"
        for i in 0..<300 { mine += "- Project note number \(i) about the rewards app redesign and its launch plan.\n" }
        XCTAssertGreaterThan(mine.utf8.count, MemoryBook.sizeCap)
        let r = MemoryBook.merge(mine, facts: [fact("Projects", "Newest decision: launch in spring.")])
        XCTAssertLessThanOrEqual(r.text.utf8.count, MemoryBook.Doc(mine).text.utf8.count)
        XCTAssertTrue(r.text.hasPrefix("# Rex's memory\n\nIntro stays.\n"))
        XCTAssertTrue(r.text.contains("Newest decision: launch in spring."), "newest fact kept")
        XCTAssertTrue(r.text.contains("number 299 "), "newest old line kept")
        XCTAssertFalse(r.text.contains("- Project note number 0 "), "oldest line folded or dropped")
    }

    func testCapAlwaysFinishesEvenWithOneHugeLine() {
        let huge = "## Notes\n- " + String(repeating: "x", count: 20_000) + "\n"
        XCTAssertLessThanOrEqual(MemoryBook.cap(huge, limit: 1024).utf8.count, 1024)
    }

    func testUnderCapIsUntouched() {
        let mine = "## Preferences\n- Likes tea.\n"
        XCTAssertEqual(MemoryBook.cap(mine), mine)
    }

    func testCapNeverTouchesYourOwnSectionsOrShrinksTheFile() {
        var mine = "# Notes for Rex\nIntro line\n\n## Rules\n"
        for i in 0..<200 { mine += "- Rule \(i): never deploy on Fridays without checking the release checklist and the pager\n" }
        mine += "\n## Preferences\n- Likes tea\n- Likes short replies\n"
        let before = MemoryBook.Doc(mine).text
        let r = MemoryBook.merge(mine, facts: [fact("Preferences", "Prefers dark mode in every app")])
        for i in 0..<200 {
            XCTAssertTrue(r.text.contains("- Rule \(i): never deploy on Fridays without checking the release checklist and the pager\n"), "rule \(i)")
        }
        XCTAssertTrue(r.text.hasPrefix("# Notes for Rex\nIntro line\n"))
        XCTAssertTrue(r.text.contains("Prefers dark mode in every app"))
        XCTAssertLessThanOrEqual(r.text.utf8.count, before.utf8.count, "growth is capped")
        XCTAssertGreaterThan(r.text.utf8.count, before.utf8.count - 64, "nothing beyond room for the new fact goes")
    }

    private func oneMegabyte() -> (String, Int) {
        var big = "## Projects\n"
        var i = 0
        while big.utf8.count < 1_024 * 1_024 { big += "- Project note \(i): some details about work in progress and what happened next\n"; i += 1 }
        return (big, i)
    }

    func testOneMegabyteMemoryMergesQuicklyAndKeepsItsSize() {
        let (big, _) = oneMegabyte()
        let start = Date()
        let r = MemoryBook.merge(big, facts: [fact("Preferences", "Prefers dark mode in every app")])
        XCTAssertLessThan(Date().timeIntervalSince(start), 3.0)   // 1s on a Mac; Linux CI is slower
        XCTAssertTrue(r.changed)
        XCTAssertTrue(r.text.contains("Prefers dark mode in every app"))
        XCTAssertLessThanOrEqual(r.text.utf8.count, big.utf8.count)
        XCTAssertGreaterThan(r.text.utf8.count, big.utf8.count - 512)
    }

    func testCapAloneOnOneMegabyteIsQuickAndFinishes() {
        let (big, i) = oneMegabyte()
        let start = Date()
        let out = MemoryBook.cap(big, limit: MemoryBook.sizeCap)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3.0)
        XCTAssertLessThanOrEqual(out.utf8.count, MemoryBook.sizeCap)
        XCTAssertTrue(out.contains("Project note \(i - 1):"), "newest line kept")
    }
}

final class MemoryHistoryTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lp-history-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testKeepsTheLastTenVersions() throws {
        var names: [String] = []
        for i in 0..<13 {
            names.append(try XCTUnwrap(MemoryHistory.save("v\(i)", in: dir, now: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)))))
        }
        let kept = MemoryHistory.versions(dir)
        XCTAssertEqual(kept.count, 10)
        XCTAssertEqual(kept.first?.id, names.last)
        XCTAssertEqual(MemoryHistory.read(names.last!, in: dir), "v12")
        XCTAssertNil(MemoryHistory.read(names[0], in: dir))
    }

    func testVersionNamesAreUTCAndASCII() {
        let name = MemoryHistory.name(for: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(name, "MEMORY-19700101-000000-000Z.md")
        XCTAssertTrue(name.unicodeScalars.allSatisfy(\.isASCII))
        XCTAssertEqual(MemoryHistory.date(ofName: name), Date(timeIntervalSince1970: 0))
    }

    func testPruneKeepsVersionsANoteStillUses() throws {
        let first = try XCTUnwrap(MemoryHistory.save("v0", in: dir, now: Date(timeIntervalSince1970: 1_700_000_000)))
        for i in 1..<15 {
            MemoryHistory.save("v\(i)", in: dir, now: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)), protecting: [first])
        }
        XCTAssertEqual(MemoryHistory.read(first, in: dir), "v0")
        XCTAssertEqual(MemoryHistory.versions(dir).count, MemoryHistory.keep + 1)
    }

    func testTwoSavesInTheSameMillisecondKeepBoth() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let a = try XCTUnwrap(MemoryHistory.save("a", in: dir, now: now))
        let b = try XCTUnwrap(MemoryHistory.save("b", in: dir, now: now))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(MemoryHistory.read(a, in: dir), "a")
    }
}

/// MEMORY.md on disk: encodings, Undo, the editor, and importing notes.md.
final class MemoryStoreTests: XCTestCase {
    private var root: URL!
    private var paths: LaunchpadPaths!
    private var store: MemoryStore!
    private let bot = "rex"
    private var file: URL { paths.memoryMD(bot) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lp-memory-\(UUID().uuidString)", isDirectory: true)
        paths = LaunchpadPaths(root: root)
        try FileManager.default.createDirectory(at: paths.botDir(bot), withIntermediateDirectories: true)
        store = MemoryStore(paths: paths)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func disk() -> String { store.read(bot).usable ?? "<unreadable>" }
    private func write(_ s: String) throws { try Data(s.utf8).write(to: file) }
    private func apply(_ facts: [MemoryBook.Fact], condense: [MemoryBook.Condense] = [], at t: Double = 1_800_000_000) -> MemoryUpdate? {
        store.applyReview(botId: bot, chatId: "c1", facts: facts, condense: condense, now: Date(timeIntervalSince1970: t))
    }

    func testLatin1MemoryIsNeverWrittenOver() throws {
        let bytes = try XCTUnwrap("## Preferences\n- Likes café au lait\n".data(using: .isoLatin1))
        try bytes.write(to: file)
        XCTAssertEqual(store.read(bot), .unreadable)
        XCTAssertNil(apply([fact("Preferences", "Prefers dark mode everywhere")]))
        XCTAssertEqual(store.save("- wiped", original: "", botId: bot), .unreadable)
        XCTAssertEqual(store.addEntry("Likes tea", topic: "Preferences", botId: bot), .unreadable)
        XCTAssertEqual(try Data(contentsOf: file), bytes, "file untouched")
        XCTAssertTrue(store.versions(bot).isEmpty, "no empty version saved in its place")
    }

    func testUTF16AndMissingFilesStillWork() throws {
        try XCTUnwrap("## Preferences\n- Likes tea\n".data(using: .utf16)).write(to: file)
        XCTAssertEqual(store.read(bot), .text("## Preferences\n- Likes tea\n"))
        XCTAssertNotNil(apply([fact("Preferences", "Prefers dark mode everywhere")]))
        XCTAssertEqual(disk(), "## Preferences\n- Likes tea\n- Prefers dark mode everywhere\n")

        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(store.read(bot), .missing)
        XCTAssertNotNil(apply([fact("People", "Sam is the iOS lead")]))
        XCTAssertEqual(disk(), "## People\n- Sam is the iOS lead\n")

        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("## Preferences\n- Likes tea\n".utf8))
        try data.write(to: file)
        XCTAssertEqual(store.read(bot), .text("## Preferences\n- Likes tea\n"))
    }

    func testUndoTakesBackOnlyItsOwnLines() throws {
        try write("## Preferences\n- Likes tea\n")
        let a = try XCTUnwrap(apply([fact("Preferences", "Prefers British spelling")]))
        // The bot writes its own note, then a later review adds another fact.
        try write(disk() + "\n## Projects\n- Rewards app ships in March\n")
        let b = try XCTUnwrap(apply([fact("People", "Ana runs QA")], at: 1_800_000_100))
        XCTAssertEqual(store.update(id: a.id), a)
        XCTAssertTrue(a.summary.hasPrefix("Memory updated: Prefers British spelling"))

        XCTAssertEqual(store.undoCount(a), 1)
        XCTAssertEqual(store.undo(a), 1)
        let afterUndo = disk()
        XCTAssertFalse(afterUndo.contains("British spelling"))
        XCTAssertTrue(afterUndo.contains("- Likes tea"))
        XCTAssertTrue(afterUndo.contains("- Rewards app ships in March"), "the bot's own note stays")
        XCTAssertTrue(afterUndo.contains("- Ana runs QA"), "the later update stays")
        XCTAssertEqual(store.update(id: a.id)?.undone, true)

        XCTAssertEqual(store.undo(b), 1)
        XCTAssertFalse(disk().contains("Ana runs QA"))
        XCTAssertFalse(disk().contains("British spelling"))
        XCTAssertFalse(disk().contains("## People"), "the heading the update added goes with it")

        XCTAssertEqual(store.undo(a), 0, "nothing left to take back")
    }

    func testUndoPutsBackLinesTheUpdateFoldedOrReplaced() throws {
        let original = "## Projects\n- Old thing A\n- Old thing B\n- Keep me\n\n## Preferences\n- Prefers British spelling\n"
        try write(original)
        let applied = try XCTUnwrap(apply([fact("Preferences", "Prefers British spelling in all documents")],
                                          condense: [.init(topic: "Projects", replaces: ["Old thing A", "Old thing B"], text: "Old things A and B")]))
        XCTAssertTrue(disk().contains("Old things A and B"))
        XCTAssertEqual(store.undo(applied), 5)
        XCTAssertEqual(disk(), original)
    }

    func testUndoWithoutSavedVersionsRemovesJustTheAddedLines() throws {
        try write("## Preferences\n- Likes tea\n- Prefers dark mode\n\n## People\n- Ana runs QA\n")
        let note = MemoryUpdate(botId: bot, chatId: nil, version: "MEMORY-gone.md", added: ["Prefers dark mode"], date: Date())
        XCTAssertEqual(store.undo(note), 1)
        XCTAssertEqual(disk(), "## Preferences\n- Likes tea\n\n## People\n- Ana runs QA\n")
        XCTAssertEqual(store.undoCount(note), 0)
    }

    func testEditorSaveKeepsABackgroundUpdate() throws {
        let opened = "## Preferences\n- Likes tea\n- Likes jazz\n"
        try write(opened)
        XCTAssertNotNil(apply([fact("People", "Ana runs QA")]))
        XCTAssertEqual(store.save("## Preferences\n- Likes green tea\n", original: opened, botId: bot), .saved)
        XCTAssertEqual(disk(), "## Preferences\n- Likes green tea\n\n## People\n- Ana runs QA\n")
        XCTAssertTrue(store.versions(bot).contains { store.version($0.id, botId: bot)?.contains("Ana runs QA") == true },
                      "what was on disk is kept as a version")
    }

    func testForgetEverythingStillClearsAll() throws {
        try write("## Preferences\n- Likes tea\n- Prefers dark mode\n")
        XCTAssertEqual(store.save("", original: "## Preferences\n- Likes tea\n", botId: bot, replaceAll: true), .saved)
        XCTAssertEqual(disk(), "")
    }

    func testAddEditDeleteAndUndoLastChange() throws {
        try write("## Preferences\n- Likes tea\n- Likes jazz\n")
        XCTAssertEqual(store.addEntry("Ana runs QA", topic: "People", botId: bot), .saved)
        XCTAssertEqual(store.addEntry("ghp_1234567890abcdefghijABCDEFGHIJ", topic: "Notes", botId: bot), .secret)
        XCTAssertEqual(store.addEntry("likes tea", topic: "Preferences", botId: bot), .unchanged)

        let outline = try XCTUnwrap(store.outline(bot))
        let jazz = try XCTUnwrap(outline.flatMap(\.entries).first { $0.text == "Likes jazz" })
        XCTAssertEqual(store.editEntry(at: jazz.position, expecting: jazz.text, to: "Likes jazz and blues", botId: bot), .saved)
        XCTAssertEqual(store.editEntry(at: jazz.position, expecting: "Not a line", to: "x", botId: bot), .notFound)
        XCTAssertEqual(store.editEntry(at: jazz.position, expecting: "Likes jazz and blues", to: "my password is hunter2", botId: bot), .secret)

        // The bot adds a line itself; positions shift, the line is still found by its text.
        try write("## Preferences\n- Wants short replies\n" + disk().dropFirst("## Preferences\n".count))
        let tea = try XCTUnwrap(store.outline(bot)?.flatMap(\.entries).first { $0.text == "Likes tea" })
        XCTAssertEqual(store.deleteEntry(at: MemoryBook.LinePosition(section: tea.position.section, line: 0), expecting: "Likes tea", botId: bot), .saved)
        XCTAssertEqual(disk(), "## Preferences\n- Wants short replies\n- Likes jazz and blues\n\n## People\n- Ana runs QA\n")

        // Undo last change walks back one app change at a time and keeps the bot's own line.
        XCTAssertEqual(store.undoLastChange(bot), 1)
        XCTAssertEqual(disk(), "## Preferences\n- Wants short replies\n- Likes tea\n- Likes jazz and blues\n\n## People\n- Ana runs QA\n")
        XCTAssertEqual(store.undoLastChange(bot), 2)   // the edit: one line out, one back
        XCTAssertTrue(disk().contains("- Likes jazz\n"))
        XCTAssertEqual(store.undoLastChange(bot), 1)
        XCTAssertFalse(disk().contains("Ana runs QA"))
        XCTAssertTrue(disk().contains("Wants short replies"))
        XCTAssertFalse(store.canUndoLastChange(bot))
        XCTAssertEqual(store.undoLastChange(bot), 0)
    }

    func testImportsNotesOnceAndPointsInstructionsAtMemory() throws {
        let botStore = BotStore(paths: paths)
        var rex = Bot(id: bot, name: "Rex")
        rex.role = "Designer"
        try botStore.save(rex)
        try botStore.setInstructions("- `./notes.md` is your memory. Read it when you start a task.\n", for: bot)
        try Data("# Rex's notes\n\nMy own memory. I keep it short and up to date.\n\n- Sam prefers Figma\n".utf8).write(to: paths.notesMD(bot))

        XCTAssertEqual(store.importNotesIfNeeded(rex), .imported)
        XCTAssertEqual(disk(), Instructions.memoryTemplate(for: rex) + "\n## From notes.md\n- Sam prefers Figma\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.notesMD(bot).path), "moved out of the bot's folder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.importedNotes(bot).path), "kept, not lost")
        XCTAssertTrue(botStore.instructions(for: bot).contains("`./MEMORY.md` is your memory"))
        XCTAssertEqual(try String(contentsOf: paths.agentsMD(bot), encoding: .utf8), botStore.instructions(for: bot))

        // Once only: a notes.md written later is left alone.
        try Data("- again\n".utf8).write(to: paths.notesMD(bot))
        XCTAssertEqual(store.importNotesIfNeeded(rex), .none)
        XCTAssertFalse(disk().contains("again"))
        XCTAssertEqual(store.undoLastChange(bot), 3, "the import itself can be undone")
        XCTAssertEqual(disk(), "")
    }

    func testStarterNotesAddNothingAndUnreadableNotesAreLeftAlone() throws {
        let rex = Bot(id: bot, name: "Rex")
        try write("## Preferences\n- Likes tea\n")
        try Data("# Rex's notes\n\nMy own memory. I keep it short and up to date.\n".utf8).write(to: paths.notesMD(bot))
        XCTAssertEqual(store.importNotesIfNeeded(rex), .imported)
        XCTAssertEqual(disk(), "## Preferences\n- Likes tea\n")

        let other = Bot(id: "pip", name: "Pip")
        try FileManager.default.createDirectory(at: paths.botDir("pip"), withIntermediateDirectories: true)
        let latin = try XCTUnwrap("- café\n".data(using: .isoLatin1))
        try latin.write(to: paths.notesMD("pip"))
        XCTAssertEqual(store.importNotesIfNeeded(other), .unreadable)
        XCTAssertEqual(try Data(contentsOf: paths.notesMD("pip")), latin)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.memoryMD("pip").path))
    }

    func testNewBotsGetMemoryNotNotes() throws {
        let b = try BotStore(paths: paths).create(name: "Pip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.memoryMD(b.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.notesMD(b.id).path))
        XCTAssertTrue(BotStore(paths: paths).instructions(for: b.id).contains("`./MEMORY.md`"))
        XCTAssertFalse(BotStore(paths: paths).instructions(for: b.id).contains("notes.md"))
        XCTAssertFalse(HireCatalog.lead.instructionsText.contains("notes.md"))
        XCTAssertTrue(LaunchpadProtocol.text(skills: []).contains("MEMORY.md"))
    }
}

/// When to review, the budget, back-off, the transcript and the engine call.
final class MemoryReviewTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let utc = TimeZone(identifier: "UTC")!

    private func msg(_ role: MessageRole, _ text: String, at t: Date, status: MessageStatus = .done, bot: String? = nil) -> ChatMessage {
        ChatMessage(role: role, botId: bot, text: text, status: status, createdAt: t)
    }

    func testUnreviewedStartsAfterTheMarkAndSkipsAppNotes() {
        let a = msg(.user, "first", at: t0)
        let b = msg(.notice, "Starting fresh.", at: t0)
        let c = msg(.user, "second", at: t0)
        let d = msg(.bot, "", at: t0, status: .streaming)
        let e = msg(.bot, "Oops", at: t0, status: .failed)
        XCTAssertEqual(MemoryReview.unreviewed([a, b, c, d, e], after: a.id).map(\.text), ["second"])
        XCTAssertEqual(MemoryReview.unreviewed([a, b, c], after: "gone").map(\.text), ["first", "second"])
        XCTAssertEqual(MemoryReview.unreviewed([a, c], after: nil).count, 2)
    }

    func testRestoredOlderMessagesAreNotReviewedAgain() {
        let old = [msg(.user, "I prefer British spelling in everything I write", at: t0.addingTimeInterval(-3600))]
        let newest = t0.addingTimeInterval(-60)
        XCTAssertTrue(MemoryReview.unreviewed(old, after: "gone", since: newest).isEmpty)
        let later = msg(.user, "new", at: t0)
        XCTAssertEqual(MemoryReview.unreviewed(old + [later], after: "gone", since: newest).map(\.text), ["new"])
    }

    func testTranscriptRedactsAndKeepsNewestWithinBudget() {
        var list: [ChatMessage] = []
        for i in 0..<100 { list.append(msg(.user, "message \(i) " + String(repeating: "word ", count: 60), at: t0)) }
        list.append(msg(.bot, "Noted.", at: t0, bot: "rex"))
        list.append(msg(.user, "my password is hunter2", at: t0))
        let t = MemoryReview.transcript(list) { $0 == "rex" ? "Rex" : "Bot" }
        XCTAssertLessThanOrEqual(t.count, MemoryReviewPolicy().transcriptBudget)
        XCTAssertTrue(t.hasSuffix("Rex: Noted.\nUser: my password is [redacted]"))
        XCTAssertFalse(t.contains("message 0 "))
    }

    func testTranscriptRedactsBeforeCuttingLongMessages() {
        let key = "sk-ant-api03-" + String(repeating: "AbCd1234", count: 6)
        let text = String(repeating: "a", count: MemoryReviewPolicy().perMessageLimit - 10) + " " + key
        let t = MemoryReview.transcript([msg(.user, text, at: t0)]) { _ in "Rex" }
        XCTAssertFalse(t.contains("sk-ant"), "no part of the key survives the cut")
    }

    func testUnparsableReplyMarksReviewed() {
        XCTAssertEqual(MemoryReview.outcome(of: "Nothing here is worth remembering.", failuresSoFar: 0), .skip)
        XCTAssertEqual(MemoryReview.outcome(of: "{\"facts\": [", failuresSoFar: 0), .retry)
        XCTAssertEqual(MemoryReview.outcome(of: "{\"facts\": [", failuresSoFar: 1), .skip)
        guard case .apply(let r) = MemoryReview.outcome(of: "{\"facts\": [{\"text\": \"Ana runs QA.\"}, {\"topic\": \"People\"}]} Hope that helps {:}",
                                                        failuresSoFar: 0) else { return XCTFail("usable reply") }
        XCTAssertEqual(r.facts, [fact("Notes", "Ana runs QA.")], "no topic goes to Notes; no text is dropped")
    }

    func testReviewUsesTheCheapestRunOnTheBotsOwnEngine() {
        let dir = URL(fileURLWithPath: "/tmp/scratch")
        let claude = MemoryReview.invocation(for: Bot(id: "rex", name: "Rex", engine: .claude, model: "opus", permission: .fullAccess),
                                             prompt: "p", directory: dir)
        XCTAssertEqual(claude.engine, .claude)
        let a = claude.arguments
        XCTAssertEqual(a[a.firstIndex(of: "--model")! + 1], "haiku")
        XCTAssertEqual(a[a.firstIndex(of: "--tools")! + 1], "", "no tools")
        XCTAssertTrue(a.contains("--no-session-persistence"))
        XCTAssertTrue(a.contains("--strict-mcp-config"), "no connectors")
        XCTAssertFalse(a.contains("--dangerously-skip-permissions"))
        XCTAssertFalse(a.contains("--resume"))
        XCTAssertEqual(claude.stdin, "p")
        XCTAssertEqual(claude.workingDirectory, dir)

        let codex = MemoryReview.invocation(for: Bot(id: "rex", name: "Rex", engine: .codex, model: "gpt-5", permission: .fullAccess),
                                            prompt: "p", directory: dir)
        let c = codex.arguments
        XCTAssertTrue(c.contains("model_reasoning_effort=\"low\""))
        XCTAssertEqual(c[c.firstIndex(of: "-m")! + 1], "gpt-5")
        XCTAssertTrue(c.contains("--ephemeral"))
        XCTAssertTrue(c.contains("sandbox_mode=\"read-only\""))
        XCTAssertFalse(c.contains("--dangerously-bypass-approvals-and-sandbox"))
    }

    func testRegularRunsAreUnchanged() {
        let bot = Bot(id: "rex", name: "Rex", engine: .claude)
        let a = EngineCommand.invocation(for: bot, prompt: "p", botDirectory: URL(fileURLWithPath: "/tmp"), sessionId: nil).arguments
        XCTAssertFalse(a.contains("--tools"))
        let c = EngineCommand.invocation(for: Bot(id: "rex", name: "Rex", engine: .codex), prompt: "p",
                                         botDirectory: URL(fileURLWithPath: "/tmp"), sessionId: nil).arguments
        XCTAssertFalse(c.contains { $0.contains("model_reasoning_effort") })
    }

    // MARK: Schedule

    func testDueAfterTenQuietMinutesOrWhenAsked() {
        var s = MemoryReviewSchedule(timeZone: utc)
        s.noteActivity(chatId: "c1", botId: "rex", at: t0)
        XCTAssertEqual(s.duePasses(now: t0.addingTimeInterval(9 * 60)), [])
        XCTAssertEqual(s.duePasses(now: t0.addingTimeInterval(10 * 60)), [MemoryPassTicket(chatId: "c1", botId: "rex", reason: .quiet)])
        XCTAssertEqual(s.duePasses(now: t0.addingTimeInterval(10 * 60), busy: ["c1"]), [], "a reply still running waits")

        s.noteActivity(chatId: "c1", botId: "rex", at: t0.addingTimeInterval(8 * 60))
        XCTAssertEqual(s.duePasses(now: t0.addingTimeInterval(10 * 60)), [], "new activity restarts the wait")

        s.requestPass(chatId: "c2", botId: "pip", at: t0.addingTimeInterval(9 * 60))
        XCTAssertEqual(s.duePasses(now: t0.addingTimeInterval(9 * 60)).map(\.reason), [.requested])
        XCTAssertEqual(s.duePasses(now: t0.addingTimeInterval(20 * 60)).map(\.chatId), ["c2", "c1"], "asked-for ones first")

        s.setLearning(false, botId: "pip")
        XCTAssertEqual(s.duePasses(now: t0.addingTimeInterval(20 * 60)).map(\.chatId), ["c1"])
    }

    func testOneAtATimeAndHandledActivityIsNotDueAgain() {
        var s = MemoryReviewSchedule(timeZone: utc)
        s.noteActivity(chatId: "c1", botId: "rex", at: t0)
        s.noteActivity(chatId: "c2", botId: "rex", at: t0)
        let now = t0.addingTimeInterval(3600)
        let ticket = s.duePasses(now: now)[0]
        XCTAssertTrue(s.begin(ticket, now: now))
        XCTAssertEqual(s.duePasses(now: now), [], "nothing else starts while a pass runs")
        XCTAssertFalse(s.begin(MemoryPassTicket(chatId: "c2", botId: "rex", reason: .quiet), now: now))
        s.finish(ticket, .reviewed, newest: msg(.user, "x", at: t0), activity: t0, now: now)
        XCTAssertEqual(s.duePasses(now: now).map(\.chatId), ["c2"])
        XCTAssertEqual(s.chats["c1"]?.reviewedUntil, t0)
    }

    func testDailyBudgetPerBotResetsTheNextDay() {
        var policy = MemoryReviewPolicy()
        policy.dailyLimit = 2
        var s = MemoryReviewSchedule(policy: policy, timeZone: utc)
        let morning = Date(timeIntervalSince1970: 1_800_000_000 - 1_800_000_000.truncatingRemainder(dividingBy: 86_400) + 9 * 3600)
        for i in 0..<2 {
            let t = MemoryPassTicket(chatId: "c\(i)", botId: "rex", reason: .requested)
            XCTAssertTrue(s.begin(t, now: morning))
            s.finish(t, .reviewed, newest: nil, activity: nil, now: morning)
        }
        XCTAssertEqual(s.budgetLeft("rex", now: morning), 0)
        s.requestPass(chatId: "c9", botId: "rex", at: morning)
        XCTAssertEqual(s.duePasses(now: morning), [], "allowance used up")
        XCTAssertFalse(s.begin(MemoryPassTicket(chatId: "c9", botId: "rex", reason: .requested), now: morning))
        XCTAssertEqual(s.budgetLeft("pip", now: morning), 2, "per bot")
        let tomorrow = morning.addingTimeInterval(86_400)
        XCTAssertEqual(s.duePasses(now: tomorrow).map(\.chatId), ["c9"])
        XCTAssertTrue(s.begin(MemoryPassTicket(chatId: "c9", botId: "rex", reason: .requested), now: tomorrow))
        XCTAssertEqual(s.budgetLeft("rex", now: tomorrow), 1)
    }

    func testBacksOffAfterFailuresAndRecovers() {
        var s = MemoryReviewSchedule(timeZone: utc)
        s.requestPass(chatId: "c1", botId: "rex", at: t0)
        let ticket = MemoryPassTicket(chatId: "c1", botId: "rex", reason: .requested)
        XCTAssertTrue(s.begin(ticket, now: t0))
        s.finish(ticket, .engineFailed, newest: nil, activity: t0, now: t0)
        XCTAssertEqual(s.duePasses(now: t0.addingTimeInterval(29 * 60)), [])
        XCTAssertEqual(s.duePasses(now: t0.addingTimeInterval(30 * 60)).count, 1, "still due once the wait is over")
        let t1 = t0.addingTimeInterval(30 * 60)
        XCTAssertTrue(s.begin(ticket, now: t1))
        s.finish(ticket, .engineFailed, newest: nil, activity: t0, now: t1)
        XCTAssertEqual(s.bots["rex"]?.retryAfter, t1.addingTimeInterval(60 * 60), "the wait doubles")
        let t2 = t1.addingTimeInterval(3600)
        XCTAssertTrue(s.begin(ticket, now: t2))
        s.finish(ticket, .reviewed, newest: nil, activity: t0, now: t2)
        XCTAssertEqual(s.bots["rex"]?.failures, 0)
        XCTAssertNil(s.bots["rex"]?.retryAfter)
        XCTAssertEqual(s.duePasses(now: t2), [])
        XCTAssertEqual(MemoryReviewPolicy().backoff(failures: 30), 8 * 3600, "capped")
    }

    func testBrokenRepliesRetryOnceThenCountAsReviewed() {
        var s = MemoryReviewSchedule(timeZone: utc)
        s.requestPass(chatId: "c1", botId: "rex", at: t0)
        let ticket = MemoryPassTicket(chatId: "c1", botId: "rex", reason: .requested)
        let newest = msg(.user, "x", at: t0)
        XCTAssertTrue(s.begin(ticket, now: t0))
        s.finish(ticket, .unusableReply, newest: newest, activity: t0, now: t0)
        XCTAssertEqual(s.chats["c1"]?.parseFailures, 1)
        XCTAssertEqual(s.duePasses(now: t0.addingTimeInterval(60)), [])
        let later = t0.addingTimeInterval(3600)
        XCTAssertTrue(s.begin(ticket, now: later))
        s.finish(ticket, .unusableReply, newest: newest, activity: t0, now: later)
        XCTAssertEqual(s.chats["c1"]?.reviewedId, newest.id, "second failure gives up on these messages")
        XCTAssertEqual(s.duePasses(now: later.addingTimeInterval(86_400)), [])
    }

    func testPrepareSkipsOldHistoryAndTooLittleWriting() {
        let old = msg(.user, "A long message about my preferences from a week ago, worth something", at: t0.addingTimeInterval(-7 * 86_400))
        guard case .nothingNew(let mark) = MemoryReview.prepare([old], state: nil, now: t0) else { return XCTFail() }
        XCTAssertEqual(mark?.id, old.id, "first time: old history is skipped and marked")

        let short = msg(.user, "thanks!", at: t0)
        XCTAssertEqual(MemoryReview.prepare([short], state: nil, now: t0), .tooLittle(newest: short))

        let long = msg(.user, "I always want the TypeScript strict mode on in every project we start", at: t0)
        let reply = msg(.bot, "Will do.", at: t0, bot: "rex")
        XCTAssertEqual(MemoryReview.prepare([long, reply], state: nil, now: t0), .review(fresh: [long, reply], newest: reply))
    }

    func testScheduleSurvivesJSONButNotTheRunningPass() throws {
        var s = MemoryReviewSchedule(timeZone: utc)
        s.requestPass(chatId: "c1", botId: "rex", at: t0)
        XCTAssertTrue(s.begin(MemoryPassTicket(chatId: "c1", botId: "rex", reason: .requested), now: t0))
        let data = try JSONCoding.encoder().encode(s)
        let back = try JSONCoding.decoder().decode(MemoryReviewSchedule.self, from: data)
        XCTAssertNil(back.running)
        XCTAssertEqual(back.chats, s.chats)
        XCTAssertEqual(back.bots, s.bots)
    }
}

/// The reviewer end to end, with a fake engine and a fake clock.
final class MemoryReviewerTests: XCTestCase {
    private var root: URL!
    private var paths: LaunchpadPaths!
    private let rex = Bot(id: "rex", name: "Rex", role: "Designer", engine: .claude)

    final class Fake: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var replies: [MemoryEngineReply] = []
        var calls: [EngineInvocation] = []
        func engine() -> MemoryReviewEngine {
            { inv in
                self.calls.append(inv)
                return self.replies.isEmpty ? .text("{\"facts\": []}") : self.replies.removeFirst()
            }
        }
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lp-reviewer-\(UUID().uuidString)", isDirectory: true)
        paths = LaunchpadPaths(root: root)
        try FileManager.default.createDirectory(at: paths.botDir("rex"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func reviewer(_ fake: Fake) -> MemoryReviewer {
        MemoryReviewer(paths: paths, timeZone: TimeZone(identifier: "UTC")!, clock: { fake.now }, engine: fake.engine())
    }

    private func chat(_ fake: Fake) -> [ChatMessage] {
        [ChatMessage(role: .user, text: "Please always use British spelling, and my api key: abc123secret", createdAt: fake.now),
         ChatMessage(role: .bot, botId: "rex", text: "Got it.", createdAt: fake.now)]
    }

    func testQuietChatIsReviewedAndMemoryUpdated() async throws {
        let fake = Fake()
        fake.replies = [.text("```json\n{\"facts\": [{\"topic\": \"Preferences\", \"text\": \"Prefers British spelling.\"}]}\n```")]
        let r = reviewer(fake)
        let messages = chat(fake)
        r.noteActivity(chatId: "c1", botId: "rex")
        XCTAssertEqual(r.duePasses(), [])
        fake.now = fake.now.addingTimeInterval(10 * 60)
        let ticket = try XCTUnwrap(r.duePasses().first)

        guard case .updated(let update) = await r.run(ticket, bot: rex, messages: messages) else { return XCTFail("expected an update") }
        XCTAssertEqual(update.added, ["Prefers British spelling."])
        XCTAssertEqual(update.chatId, "c1")
        XCTAssertEqual(r.store.read("rex"), .text("## Preferences\n- Prefers British spelling.\n"))
        XCTAssertEqual(r.store.update(id: update.id), update)

        let call = try XCTUnwrap(fake.calls.first)
        XCTAssertTrue(call.arguments.contains("haiku"))
        XCTAssertTrue(call.stdin.contains("api key: [redacted]"), "secrets never reach the model")
        XCTAssertFalse(call.stdin.contains("abc123secret"))
        XCTAssertTrue(call.workingDirectory.path.hasPrefix(paths.root.path), "runs in a scratch folder")
        XCTAssertNotEqual(call.workingDirectory, paths.botDir("rex"))

        XCTAssertEqual(r.duePasses(), [], "reviewed")
        // State is saved: a new reviewer (app restart) doesn't review the same messages again.
        let again = reviewer(fake)
        XCTAssertEqual(again.duePasses(), [])
        let result1 = await again.run(ticket, bot: rex, messages: messages)
        XCTAssertEqual(result1, .nothingNew)
        XCTAssertEqual(fake.calls.count, 1)
    }

    func testFailuresBackOffAndSmallTalkCostsNothing() async throws {
        let fake = Fake()
        let failure = RunFailure(kind: .signedOut, message: "Signed out")
        fake.replies = [.failed(failure)]
        let r = reviewer(fake)
        r.requestPass(chatId: "c1", botId: "rex")
        let ticket = try XCTUnwrap(r.duePasses().first)
        let result2 = await r.run(ticket, bot: rex, messages: chat(fake))
        XCTAssertEqual(result2, .failed(failure))
        XCTAssertEqual(r.duePasses(), [], "backing off")
        fake.now = fake.now.addingTimeInterval(31 * 60)
        XCTAssertEqual(r.duePasses().count, 1)
        let result3 = await r.run(ticket, bot: rex, messages: chat(fake))
        XCTAssertEqual(result3, .nothingToKeep)
        XCTAssertEqual(r.currentSchedule.budgetLeft("rex", now: fake.now), MemoryReviewPolicy().dailyLimit - 2)

        r.requestPass(chatId: "c2", botId: "rex")
        let small = [ChatMessage(role: .user, text: "thanks!", createdAt: fake.now)]
        let smallTicket = try XCTUnwrap(r.duePasses().first)
        let result4 = await r.run(smallTicket, bot: rex, messages: small)
        XCTAssertEqual(result4, .nothingNew)
        XCTAssertEqual(fake.calls.count, 2, "no model call for small talk")
        XCTAssertEqual(r.duePasses(), [])
    }

    func testUnreadableMemoryAndLearningOffSkipThePass() async throws {
        let fake = Fake()
        try XCTUnwrap("- café\n".data(using: .isoLatin1)).write(to: paths.memoryMD("rex"))
        let r = reviewer(fake)
        r.requestPass(chatId: "c1", botId: "rex")
        let ticket = try XCTUnwrap(r.duePasses().first)
        let result5 = await r.run(ticket, bot: rex, messages: chat(fake))
        XCTAssertEqual(result5, .unreadableMemory)
        XCTAssertTrue(fake.calls.isEmpty)

        r.setLearning(false, botId: "rex")
        XCTAssertEqual(r.duePasses(), [])
        let result6 = await r.run(ticket, bot: rex, messages: chat(fake))
        XCTAssertEqual(result6, .notStarted)
        r.setLearning(true, botId: "rex")
        r.enabled = false
        XCTAssertEqual(r.duePasses(), [])
    }

    func testSnapshotFromRequestPassIsUsed() async throws {
        let fake = Fake()
        fake.replies = [.text("{\"facts\": [{\"topic\": \"People\", \"text\": \"Ana runs QA.\"}]}")]
        let r = reviewer(fake)
        r.requestPass(chatId: "c1", botId: "rex", snapshot: [ChatMessage(role: .user, text: "Ana runs QA for us and signs off every release we ship", createdAt: fake.now)])
        let ticket = try XCTUnwrap(r.duePasses().first)
        guard case .updated = await r.run(ticket, bot: rex, messages: []) else { return XCTFail("snapshot not used") }
        XCTAssertTrue(fake.calls[0].stdin.contains("Ana runs QA for us"))
    }
}
