import XCTest
@testable import LaunchpadCore

/// Talks to the real CLIs. Off by default (they use your plan); run with
/// `LAUNCHPAD_LIVE_TESTS=1 swift test --filter LiveEngineTests`.
final class LiveEngineTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LAUNCHPAD_LIVE_TESTS"] == "1", "live tests are opt-in")
    }

    func testClaudeRemembersAcrossResume() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lp-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = LaunchpadPaths(root: root)
        let bot = try BotStore(paths: paths).create(name: "Live", role: "a test bot", engine: .claude, model: "haiku")
        let runner = EngineRunner()
        try XCTSkipIf(runner.locator.locate(.claude) == nil, "claude isn't installed")

        func ask(_ prompt: String, session: String?) async -> MessageBuilder {
            var b = MessageBuilder(botId: bot.id)
            let inv = EngineCommand.invocation(for: bot, prompt: prompt, botDirectory: paths.botDir(bot.id), sessionId: session)
            for await e in runner.run(inv).events { b.apply(e) }
            return b
        }

        let first = await ask("Remember the word PINEAPPLE. Reply with just OK.", session: nil)
        XCTAssertEqual(first.message.status, .done, "\(String(describing: first.message.failure))")
        let session = try XCTUnwrap(first.sessionId)

        let second = await ask("What word did I ask you to remember? One word.", session: session)
        XCTAssertEqual(second.message.status, .done)
        XCTAssertTrue(second.message.text.uppercased().contains("PINEAPPLE"), second.message.text)
    }
}
