import XCTest
@testable import LaunchpadCore

final class MarkdownTests: XCTestCase {
    func testMixedBlocks() {
        let md = """
        # Plan

        Here's **the** idea:

        - first
        - second
          continued
        1. one
        2. two

        ```swift
        let x = 1
        ```

        > quoted

        | A | B |
        |---|---|
        | 1 | 2 |

        ---
        """
        XCTAssertEqual(MarkdownParser.blocks(md), [
            .heading(level: 1, text: "Plan"),
            .paragraph("Here's **the** idea:"),
            .list(ordered: false, items: [
                ListItem(indent: 0, marker: "•", text: "first"),
                ListItem(indent: 0, marker: "•", text: "second continued"),
            ]),
            .list(ordered: true, items: [
                ListItem(indent: 0, marker: "1.", text: "one"),
                ListItem(indent: 0, marker: "2.", text: "two"),
            ]),
            .code(language: "swift", code: "let x = 1"),
            .quote("quoted"),
            .table(header: ["A", "B"], rows: [["1", "2"]]),
            .rule,
        ])
    }

    func testUnclosedFenceWhileStreaming() {
        XCTAssertEqual(MarkdownParser.blocks("Look:\n```js\nconsole.log(1)"), [
            .paragraph("Look:"),
            .code(language: "js", code: "console.log(1)"),
        ])
    }

    func testTaskList() {
        XCTAssertEqual(MarkdownParser.blocks("- [x] done\n- [ ] todo"), [
            .list(ordered: false, items: [
                ListItem(indent: 0, marker: "•", text: "done", checked: true),
                ListItem(indent: 0, marker: "•", text: "todo", checked: false),
            ]),
        ])
    }

    func testHashtagIsNotHeading() {
        XCTAssertEqual(MarkdownParser.blocks("#build-and-ship is ready"), [.paragraph("#build-and-ship is ready")])
    }
}

final class MessageBuilderTests: XCTestCase {
    func testTextAfterStepStartsNewParagraph() {
        var b = MessageBuilder(botId: "x")
        b.apply(.textDelta("Let me look."))
        b.apply(.stepStarted(id: "1", tool: "Read", title: "Read a.md", detail: nil))
        XCTAssertEqual(b.activeStep?.id, "1")
        b.apply(.stepFinished(id: "1", output: "…", failed: false))
        b.apply(.textDelta("Found it"))
        b.apply(.textDelta("."))
        b.apply(.finished(resultText: "ignored because text exists"))
        XCTAssertEqual(b.message.text, "Let me look.\n\nFound it.")
        XCTAssertEqual(b.message.status, .done)
        XCTAssertNil(b.activeStep)
    }

    func testStopSettlesRunningSteps() {
        var b = MessageBuilder(botId: "x")
        b.apply(.stepStarted(id: "1", tool: "Bash", title: "Ran `sleep`", detail: nil))
        b.apply(.stopped)
        XCTAssertEqual(b.message.status, .stopped)
        XCTAssertEqual(b.message.steps.first?.status, .stopped)
        b.apply(.textDelta("late"))
        XCTAssertEqual(b.message.text, "", "nothing changes after the run ends")
    }

    func testResultTextUsedWhenNothingStreamed() {
        var b = MessageBuilder(botId: "x")
        b.apply(.finished(resultText: "All done"))
        XCTAssertEqual(b.message.text, "All done")
    }

    func testCodexBlocksAreSeparated() {
        var b = MessageBuilder(botId: "x")
        b.apply(.text("First."))
        b.apply(.text("Second."))
        XCTAssertEqual(b.message.text, "First.\n\nSecond.")
    }
}
