import XCTest
@testable import LaunchpadCore

final class MentionPickerTests: XCTestCase {
    let members = [
        Bot(id: "chief-of-staff", name: "Chief of Staff", role: "Runs the weekly rhythm"),
        Bot(id: "frontend", name: "Frontend", role: "UI"),
        Bot(id: "backend", name: "Backend", role: "API"),
        Bot(id: "qa", name: "Tester", role: "QA"),
    ]

    private func ids(_ query: String) -> [String] {
        MentionPicker.candidates(for: query, among: members).map(\.id)
    }

    // MARK: What's being typed

    func testQueryOpensOnAnAtThatStartsAWord() {
        XCTAssertEqual(MentionPicker.query(in: "@"), "")
        XCTAssertEqual(MentionPicker.query(in: "@fro"), "fro")
        XCTAssertEqual(MentionPicker.query(in: "can you look, @Back"), "Back")
        XCTAssertEqual(MentionPicker.query(in: "first line\n@chief-of"), "chief-of")
        XCTAssertEqual(MentionPicker.query(in: "(@qa"), "qa")
    }

    func testNoQueryWithoutAnOpenHandleAtTheEnd() {
        XCTAssertNil(MentionPicker.query(in: ""))
        XCTAssertNil(MentionPicker.query(in: "hello"))
        XCTAssertNil(MentionPicker.query(in: "@frontend "))
        XCTAssertNil(MentionPicker.query(in: "@frontend please"))
        XCTAssertNil(MentionPicker.query(in: "@frontend:"))
    }

    func testNoQueryWhenTheAtIsInsideAWord() {
        XCTAssertNil(MentionPicker.query(in: "oscar@exam"))
        XCTAssertNil(MentionPicker.query(in: "@@fro"))
        XCTAssertNil(MentionPicker.query(in: "file.@fro"))
    }

    // MARK: Who matches

    func testEmptyQueryListsEveryoneInGroupOrder() {
        XCTAssertEqual(ids(""), ["chief-of-staff", "frontend", "backend", "qa"])
    }

    func testFiltersByIdOrNameIgnoringCase() {
        XCTAssertEqual(ids("FRO"), ["frontend"])
        XCTAssertEqual(ids("test"), ["qa"])
        XCTAssertEqual(ids("qa"), ["qa"])
        XCTAssertEqual(ids("chiefof"), ["chief-of-staff"])
        XCTAssertEqual(ids("chief-of"), ["chief-of-staff"])
        XCTAssertEqual(ids("zzz"), [])
    }

    func testPrefixMatchesComeBeforeContainsMatches() {
        XCTAssertEqual(ids("end"), ["frontend", "backend"])
        XCTAssertEqual(ids("b"), ["backend"])
        XCTAssertEqual(ids("st"), ["chief-of-staff", "qa"])
        XCTAssertEqual(ids("t"), ["qa", "chief-of-staff", "frontend"])
    }

    // MARK: Picking one

    func testInsertReplacesTheTypedHandle() {
        XCTAssertEqual(MentionPicker.insert("frontend", into: "@"), "@frontend ")
        XCTAssertEqual(MentionPicker.insert("frontend", into: "hey @Fro"), "hey @frontend ")
        XCTAssertEqual(MentionPicker.insert("qa", into: "@backend check this, then @tes"), "@backend check this, then @qa ")
        XCTAssertNil(MentionPicker.query(in: MentionPicker.insert("qa", into: "@tes")))
    }

    func testInsertLeavesTheDraftAloneWhenNothingIsBeingTyped() {
        XCTAssertEqual(MentionPicker.insert("qa", into: "hello there"), "hello there")
    }

    func testPickedIdIsUnderstoodByTheGroup() {
        let group = BotGroup(id: "g", name: "team", members: ["frontend", "backend", "qa"], lead: "chief-of-staff")
        let bots = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
        let text = MentionPicker.insert("qa", into: "@tes") + "run the tests"
        XCTAssertEqual(GroupPlan.mentions(in: text, group: group, bots: bots, speaker: nil), ["qa"])
    }
}
