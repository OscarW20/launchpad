import XCTest
@testable import LaunchpadCore

/// Runs the real EngineRunner against small fake `claude` / `codex` scripts.
final class EngineRunnerTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lp-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Writes an executable script that prints `lines`, then exits with `exitCode`.
    private func fakeCLI(_ name: String, lines: [String], stderr: String = "", exitCode: Int = 0, sleepBefore: Double = 0) throws -> URL {
        let data = tmp.appendingPathComponent("\(name).out")
        try (lines.joined(separator: "\n") + "\n").write(to: data, atomically: true, encoding: .utf8)
        let script = """
        #!/bin/sh
        cat > "\(tmp.path)/\(name).stdin"
        printf '%s\\n' "$@" > "\(tmp.path)/\(name).args"
        pwd > "\(tmp.path)/\(name).cwd"
        \(sleepBefore > 0 ? "sleep \(sleepBefore)" : "")
        cat "\(data.path)"
        \(stderr.isEmpty ? "" : "echo '\(stderr)' >&2")
        exit \(exitCode)
        """
        let url = tmp.appendingPathComponent(name)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func collect(_ handle: RunHandle, timeout: TimeInterval = 10) async -> [RunEvent] {
        var events: [RunEvent] = []
        for await e in handle.events { events.append(e) }
        return events
    }

    private func invocation(_ engine: BotEngine, session: String? = nil) -> EngineInvocation {
        let bot = Bot(id: "b", name: "B", engine: engine)
        return EngineCommand.invocation(for: bot, prompt: "hello there", botDirectory: tmp, sessionId: session, newSessionId: { "sid-1" })
    }

    func testClaudeHappyPathStreamsAndFinishes() async throws {
        let cli = try fakeCLI("claude", lines: Fixtures.claudeToolRun)
        let runner = EngineRunner(locator: CLILocator(overrides: [.claude: cli.path]))
        let events = await collect(runner.run(invocation(.claude)))

        XCTAssertEqual(events.first, .sessionStarted("11111111-2222-4333-8444-555555555555"))
        XCTAssertEqual(events.last, .finished(resultText: "Done."))
        XCTAssertTrue(events.contains(.textDelta("Done")))

        let stdin = try String(contentsOf: tmp.appendingPathComponent("claude.stdin"), encoding: .utf8)
        XCTAssertEqual(stdin, "hello there")
        let args = try String(contentsOf: tmp.appendingPathComponent("claude.args"), encoding: .utf8)
        XCTAssertTrue(args.contains("--session-id\nsid-1"))
        let cwd = try String(contentsOf: tmp.appendingPathComponent("claude.cwd"), encoding: .utf8)
        XCTAssertEqual(URL(fileURLWithPath: cwd.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath().path,
                       tmp.resolvingSymlinksInPath().path)
    }

    func testMessageBuilderFromRealRun() async throws {
        let cli = try fakeCLI("claude", lines: Fixtures.claudeToolRun)
        let runner = EngineRunner(locator: CLILocator(overrides: [.claude: cli.path]))
        var builder = MessageBuilder(botId: "b")
        for await e in runner.run(invocation(.claude)).events { builder.apply(e) }
        XCTAssertEqual(builder.message.text, "Done.")
        XCTAssertEqual(builder.message.status, .done)
        XCTAssertEqual(builder.message.steps.map(\.status), [.succeeded])
        XCTAssertEqual(builder.sessionId, "11111111-2222-4333-8444-555555555555")
    }

    func testClaudeNotLoggedInIsPlainEnglish() async throws {
        let cli = try fakeCLI("claude", lines: Fixtures.claudeNotLoggedIn, exitCode: 1)
        let runner = EngineRunner(locator: CLILocator(overrides: [.claude: cli.path]))
        var builder = MessageBuilder(botId: "b")
        for await e in runner.run(invocation(.claude)).events { builder.apply(e) }
        XCTAssertEqual(builder.message.status, .failed)
        XCTAssertEqual(builder.message.failure?.kind, .signedOut)
        XCTAssertEqual(builder.message.text, "", "the raw error isn't shown twice")
    }

    func testClaudeMissingSessionIsDetected() async throws {
        let cli = try fakeCLI("claude", lines: Fixtures.claudeSessionMissing,
                              stderr: "No conversation found with session ID: 9999", exitCode: 1)
        let runner = EngineRunner(locator: CLILocator(overrides: [.claude: cli.path]))
        let events = await collect(runner.run(invocation(.claude, session: "9999")))
        guard case .failed(let f) = events.last else { return XCTFail("expected failure, got \(events)") }
        XCTAssertEqual(f.kind, .sessionLost)
    }

    func testCodexHappyPath() async throws {
        let cli = try fakeCLI("codex", lines: Fixtures.codexRun)
        let runner = EngineRunner(locator: CLILocator(overrides: [.codex: cli.path]))
        var builder = MessageBuilder(botId: "b")
        for await e in runner.run(invocation(.codex)).events { builder.apply(e) }
        XCTAssertEqual(builder.message.status, .done)
        XCTAssertEqual(builder.message.text, "I made **app.js**.")
        XCTAssertEqual(builder.message.steps.count, 2)
        XCTAssertEqual(builder.sessionId, "01a1e9bf-ef67-7781-9b14-fcea20acdfbd")
        let stdin = try String(contentsOf: tmp.appendingPathComponent("codex.stdin"), encoding: .utf8)
        XCTAssertEqual(stdin, "hello there")
    }

    func testCodexUnauthorized() async throws {
        let cli = try fakeCLI("codex", lines: Fixtures.codexUnauthorized, exitCode: 1)
        let runner = EngineRunner(locator: CLILocator(overrides: [.codex: cli.path]))
        let events = await collect(runner.run(invocation(.codex)))
        guard case .failed(let f) = events.last else { return XCTFail("expected failure") }
        XCTAssertEqual(f.kind, .signedOut)
        XCTAssertEqual(f.message, "Codex needs you to sign in. Click here to open Terminal.")
    }

    func testCrashWithoutResultUsesStderr() async throws {
        let cli = try fakeCLI("claude", lines: [], stderr: "Error: getaddrinfo ENOTFOUND api.anthropic.com", exitCode: 1)
        let runner = EngineRunner(locator: CLILocator(overrides: [.claude: cli.path]))
        let events = await collect(runner.run(invocation(.claude)))
        guard case .failed(let f) = events.last else { return XCTFail("expected failure") }
        XCTAssertEqual(f.kind, .network)
    }

    func testMissingCLI() async throws {
        let runner = EngineRunner(locator: CLILocator(overrides: [.claude: tmp.appendingPathComponent("nope").path]))
        let events = await collect(runner.run(invocation(.claude)))
        guard case .failed(let f) = events.last else { return XCTFail("expected failure") }
        XCTAssertEqual(f.kind, .cliMissing)
    }

    func testStopEndsTheRun() async throws {
        let cli = try fakeCLI("claude", lines: Fixtures.claudeToolRun, sleepBefore: 30)
        let runner = EngineRunner(locator: CLILocator(overrides: [.claude: cli.path]))
        let handle = runner.run(invocation(.claude))
        let started = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { handle.cancel() }
        let events = await collect(handle)
        XCTAssertEqual(events.last, .stopped)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }
}
