import XCTest
@testable import LaunchpadCore

final class TicketRunTests: XCTestCase {
    // MARK: Hotkey

    func testTheDefaultHotkeyIsControlOptionT() {
        XCTAssertEqual(TicketHotkey.label(for: nil), "⌃⌥T")
        XCTAssertEqual(TicketHotkey.keyCode(for: nil), 17)
    }

    func testAHotkeyLetterIsNormalisedAndUnknownOnesFallBack() {
        XCTAssertEqual(TicketHotkey.normalised("k"), "K")
        XCTAssertEqual(TicketHotkey.normalised(" j "), "J")
        XCTAssertEqual(TicketHotkey.normalised("1"), "T")
        XCTAssertEqual(TicketHotkey.normalised("TT"), "T")
        XCTAssertEqual(TicketHotkey.normalised(""), "T")
    }

    func testQuickAsksLetterIsNotOffered() {
        XCTAssertNil(TicketHotkey.keyCodes["B"])
        XCTAssertEqual(TicketHotkey.normalised("B"), "T", "a saved B can't take Quick Ask's key")
        XCTAssertEqual(Set(TicketHotkey.keyCodes.values).count, TicketHotkey.keyCodes.count, "no two letters share a key")
        XCTAssertFalse(TicketHotkey.keyCodes.values.contains(11), "11 is the B key")
    }

    // MARK: Which bot

    private func jira(id: String = "atlassian") -> Connector {
        Connector(id: id, name: "Jira & Confluence", kind: .http, url: "https://mcp.atlassian.com/v2/mcp")
    }

    func testJiraIsRecognisedByIdOrAddress() {
        XCTAssertTrue(TicketConnector.isJira(jira()))
        XCTAssertTrue(TicketConnector.isJira(jira(id: "my-jira")))
        XCTAssertTrue(TicketConnector.isJira(Connector(id: "atlassian", name: "x", kind: .stdio, command: "npx")))
        XCTAssertFalse(TicketConnector.isJira(Connector(id: "github", name: "GitHub", kind: .http, url: "https://api.githubcopilot.com/mcp/")))
        XCTAssertFalse(TicketConnector.isJira(Connector(id: "evil", name: "x", kind: .http, url: "https://atlassian.com.evil.example/mcp")))
        XCTAssertFalse(TicketConnector.isJira(Connector(id: "evil", name: "x", kind: .http, url: "https://notatlassian.com/mcp")))
    }

    func testOnlyClaudeBotsWithJiraCanFileTickets() {
        let withJira = Bot(id: "a", name: "A", connectors: ["atlassian"])
        let without = Bot(id: "b", name: "B")
        let codex = Bot(id: "c", name: "C", engine: .codex, connectors: ["atlassian"])
        let viaGroup = Bot(id: "d", name: "D")
        let group = BotGroup(id: "g", name: "team", members: ["d"], lead: nil, connectors: ["atlassian"])
        let found = TicketConnector.bots([withJira, without, codex, viaGroup], groups: [group], connectors: [jira()])
        XCTAssertEqual(found.map(\.id), ["a", "d"], "a group's connector counts; a Codex bot has no guard, so it's left out")
        XCTAssertTrue(TicketConnector.bots([withJira], groups: [], connectors: []).isEmpty)
    }

    func testThePickedBotWinsOnlyWhileItCanStillDoIt() {
        let a = Bot(id: "a", name: "A"), b = Bot(id: "b", name: "B")
        XCTAssertEqual(TicketConnector.choose(preferred: "b", from: [a, b])?.id, "b")
        XCTAssertEqual(TicketConnector.choose(preferred: "gone", from: [a, b])?.id, "a")
        XCTAssertEqual(TicketConnector.choose(preferred: nil, from: [a, b])?.id, "a")
        XCTAssertNil(TicketConnector.choose(preferred: "a", from: []))
    }

    // MARK: Chat text

    private func preview(selection: String = "", note: String = "", app: String? = nil, truncated: Bool = false, of total: Int? = nil) -> TicketPreview {
        TicketPreview(selection: selection, originalCharacters: total ?? selection.count, truncated: truncated, note: note,
                      sourceApp: app, sourceWindow: nil, warnings: [])
    }

    func testTheChatTitleStartsWithTheNoteThenTheSelection() {
        XCTAssertEqual(TicketPrompt.chatTitle(preview(selection: "Login fails\non Safari", note: "")), "Ticket: Login fails")
        XCTAssertEqual(TicketPrompt.chatTitle(preview(selection: "Login fails", note: "  Urgent   please ")), "Ticket: Urgent please")
        XCTAssertEqual(TicketPrompt.chatTitle(preview()), "Ticket")
        let long = TicketPrompt.chatTitle(preview(note: String(repeating: "word ", count: 40)))
        XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertLessThanOrEqual(long.count, "Ticket: ".count + 61)
    }

    func testTheChatTextIsShortEvenForALongSelection() {
        let text = TicketPrompt.chatText(preview(selection: String(repeating: "x", count: 5_000), note: "Check this", app: "Mail"),
                                         assignee: TicketAssignee(name: "Sardar", jira: "sardar@example.com"))
        XCTAssertTrue(text.hasPrefix("Create a Jira ticket from text selected in Mail."))
        XCTAssertTrue(text.contains("Assign to: Sardar"))
        XCTAssertTrue(text.contains("Note: Check this"))
        XCTAssertTrue(text.contains("(5000 characters)"))
        XCTAssertLessThan(text.count, 700)
    }

    func testTheChatTextSaysWhenTheSelectionWasCut() {
        let text = TicketPrompt.chatText(preview(selection: "abc", truncated: true, of: 99), assignee: nil)
        XCTAssertTrue(text.contains("3 of 99 characters"))
        XCTAssertFalse(text.contains("Assign to"))
        XCTAssertEqual(TicketPrompt.chatText(preview(note: "just a note"), assignee: nil),
                       "Create a Jira ticket.\nNote: just a note")
    }

    func testEveryLineOfAQuotedSelectionIsQuoted() {
        let text = TicketPrompt.chatText(preview(selection: "one\n\ntwo"), assignee: nil)
        XCTAssertTrue(text.hasSuffix("> one\n> \n> two"))
    }

    // MARK: The Service

    func testTheServicesMenuEntryMatchesTheHandlerInTheApp() throws {
        // macOS calls the app by the NSMessage name, so the plist and the Swift method must say the same thing.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("scripts/make-app.sh"), encoding: .utf8)
        let handler = try String(contentsOf: root.appendingPathComponent("Sources/Launchpad/TicketCenter.swift"), encoding: .utf8)
        XCTAssertTrue(script.contains("<key>NSMessage</key><string>createTicket</string>"))
        XCTAssertTrue(script.contains("<key>default</key><string>Create ticket with Claude</string>"))
        XCTAssertTrue(script.contains("<key>NSPortName</key><string>Launchpad</string>"))
        XCTAssertTrue(handler.contains("@objc func createTicket(_ pasteboard: NSPasteboard, userData: String"))
    }
}
