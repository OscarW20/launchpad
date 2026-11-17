import XCTest
@testable import LaunchpadCore

final class ClaudeStreamParserTests: XCTestCase {
    private func parseAll(_ lines: [String]) -> (ClaudeStreamParser, [RunEvent]) {
        let p = ClaudeStreamParser()
        return (p, lines.flatMap { p.parse(line: $0) })
    }

    func testToolRunProducesSessionStepsTextAndFinish() {
        let (parser, events) = parseAll(Fixtures.claudeToolRun)
        XCTAssertEqual(events, [
            .sessionStarted("11111111-2222-4333-8444-555555555555"),
            .stepStarted(id: "toolu_1", tool: "Bash", title: "Ran `echo hi`",
                         detail: "{\n  \"command\" : \"echo hi\",\n  \"description\" : \"Echo hi\"\n}"),
            .stepFinished(id: "toolu_1", output: "hi", failed: false),
            .textDelta("Done"),
            .textDelta("."),
            .cost(0.0044),
            .finished(resultText: "Done."),
        ])
        XCTAssertTrue(parser.isComplete)
    }

    func testFullTextIsUsedWhenNothingWasStreamed() {
        let p = ClaudeStreamParser()
        let events = p.parse(line: #"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Hello"}]},"parent_tool_use_id":null}"#)
        XCTAssertEqual(events, [.text("Hello")])
    }

    func testSubagentEventsAreSkipped() {
        let p = ClaudeStreamParser()
        let events = p.parse(line: #"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"inner"}]},"parent_tool_use_id":"toolu_parent"}"#)
        XCTAssertEqual(events, [])
    }

    func testErrorResultBecomesEngineError() {
        let (parser, events) = parseAll(Fixtures.claudeSessionMissing)
        XCTAssertEqual(events.last, .engineError("No conversation found with session ID: 99999999-2222-4333-8444-555555555555"))
        XCTAssertTrue(parser.isComplete)
    }

    func testFailedToolResult() {
        let p = ClaudeStreamParser()
        let events = p.parse(line: #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t9","content":[{"type":"text","text":"boom"}],"is_error":true}]},"parent_tool_use_id":null}"#)
        XCTAssertEqual(events, [.stepFinished(id: "t9", output: "boom", failed: true)])
    }

    func testGarbageLinesAreIgnored() {
        let p = ClaudeStreamParser()
        XCTAssertEqual(p.parse(line: "not json"), [])
        XCTAssertEqual(p.parse(line: "{}"), [])
    }

    func testToolTitles() {
        XCTAssertEqual(ToolSummary.title(tool: "Read", input: ["file_path": "/a/b/notes.md"]), "Read notes.md")
        XCTAssertEqual(ToolSummary.title(tool: "WebFetch", input: ["url": "https://example.com/x"]), "Opened example.com")
        XCTAssertEqual(ToolSummary.title(tool: "mcp__github__create_issue", input: [:]), "Used create_issue on github")
        XCTAssertEqual(ToolSummary.title(tool: "Mystery", input: [:]), "Used Mystery")
    }
}

final class CodexStreamParserTests: XCTestCase {
    func testRunProducesThreadStepsAndText() {
        let p = CodexStreamParser()
        let events = Fixtures.codexRun.flatMap { p.parse(line: $0) }
        XCTAssertEqual(events, [
            .sessionStarted("01a1e9bf-ef67-7781-9b14-fcea20acdfbd"),
            .stepStarted(id: "item_1", tool: "Bash", title: "Ran `ls -la`", detail: "/bin/zsh -lc 'ls -la'"),
            .stepFinished(id: "item_1", output: "total 0\nnotes.md\n", failed: false),
            .stepStarted(id: "item_2", tool: "Edit", title: "Edited app.js", detail: "add: /tmp/bot/workspace/app.js"),
            .stepFinished(id: "item_2", output: nil, failed: false),
            .text("I made **app.js**."),
            .usage(UsageReport(engine: .codex, tokens: 120)),
            .finished(resultText: nil),
        ])
        XCTAssertTrue(p.isComplete)
    }

    func testRetriesAreNotFinalButTurnFailedIs() {
        let p = CodexStreamParser()
        let events = Fixtures.codexUnauthorized.flatMap { p.parse(line: $0) }
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first, .sessionStarted("01a1e9bf-ef67-7781-9b14-fcea20acdfbd"))
        guard case .engineError(let message) = events.last else { return XCTFail("expected engineError") }
        XCTAssertTrue(message.contains("401"))
    }

    func testNonZeroExitMarksCommandFailed() {
        let p = CodexStreamParser()
        let events = p.parse(line: #"{"type":"item.completed","item":{"id":"c","type":"command_execution","command":"npm test","aggregated_output":"1 failing","exit_code":1,"status":"failed"}}"#)
        XCTAssertEqual(events, [
            .stepStarted(id: "c", tool: "Bash", title: "Ran `npm test`", detail: "npm test"),
            .stepFinished(id: "c", output: "1 failing", failed: true),
        ])
    }

    func testUnwrapShell() {
        XCTAssertEqual(CodexStreamParser.unwrapShell("bash -lc \"npm run build\""), "npm run build")
        XCTAssertEqual(CodexStreamParser.unwrapShell("git status"), "git status")
    }
}
