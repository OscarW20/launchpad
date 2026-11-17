import XCTest
@testable import LaunchpadCore

final class EngineCommandTests: XCTestCase {
    let dir = URL(fileURLWithPath: "/Users/me/Launchpad/bots/lead")

    func testClaudeNewSessionUsesPlannedId() {
        let bot = Bot(id: "lead", name: "Lead", engine: .claude)
        let inv = EngineCommand.invocation(for: bot, prompt: "--help me", botDirectory: dir, sessionId: nil, newSessionId: { "new-id" })
        XCTAssertEqual(inv.arguments, [
            "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--session-id", "new-id", "--permission-mode", "acceptEdits",
        ])
        XCTAssertEqual(inv.stdin, "--help me", "the prompt goes on stdin, never as an argument")
        XCTAssertEqual(inv.workingDirectory, dir)
        XCTAssertEqual(inv.plannedSessionId, "new-id")
    }

    func testClaudeResumeAndModel() {
        let bot = Bot(id: "lead", name: "Lead", engine: .claude, model: "opus", permission: .fullAccess)
        let inv = EngineCommand.invocation(for: bot, prompt: "hi", botDirectory: dir, sessionId: "abc")
        XCTAssertTrue(inv.arguments.contains("--resume"))
        XCTAssertEqual(inv.arguments[inv.arguments.firstIndex(of: "--resume")! + 1], "abc")
        XCTAssertFalse(inv.arguments.contains("--session-id"))
        XCTAssertEqual(inv.arguments[inv.arguments.firstIndex(of: "--model")! + 1], "opus")
        XCTAssertTrue(inv.arguments.contains("--dangerously-skip-permissions"))
    }

    func testClaudeReadOnlyBlocksWrites() {
        let bot = Bot(id: "r", name: "R", engine: .claude, permission: .readOnly)
        let args = EngineCommand.invocation(for: bot, prompt: "x", botDirectory: dir, sessionId: nil).arguments
        let disallowed = args[args.firstIndex(of: "--disallowedTools")! + 1]
        XCTAssertTrue(disallowed.contains("Write"))
        XCTAssertTrue(disallowed.contains("Bash"))
    }

    func testCodexNewAndResume() {
        let bot = Bot(id: "rev", name: "Reviewer", engine: .codex, model: "gpt-5-codex")
        let fresh = EngineCommand.invocation(for: bot, prompt: "review", botDirectory: dir, sessionId: nil)
        XCTAssertEqual(fresh.arguments, ["exec", "--json", "--skip-git-repo-check", "-c", "sandbox_mode=\"workspace-write\"", "-m", "gpt-5-codex", "-"])
        XCTAssertNil(fresh.plannedSessionId)

        let resumed = EngineCommand.invocation(for: bot, prompt: "again", botDirectory: dir, sessionId: "thread-1")
        XCTAssertEqual(resumed.arguments, ["exec", "resume", "--json", "--skip-git-repo-check", "-c", "sandbox_mode=\"workspace-write\"", "-m", "gpt-5-codex", "thread-1", "-"])
    }

    func testCodexPermissionLevels() {
        let ro = EngineCommand.codex(prompt: "", botDirectory: dir, model: nil, permission: .readOnly, threadId: nil)
        XCTAssertTrue(ro.arguments.contains("sandbox_mode=\"read-only\""))
        let full = EngineCommand.codex(prompt: "", botDirectory: dir, model: nil, permission: .fullAccess, threadId: nil)
        XCTAssertTrue(full.arguments.contains("--dangerously-bypass-approvals-and-sandbox"))
    }
}

final class ErrorClassifierTests: XCTestCase {
    func testSignedOut() {
        let f = ErrorClassifier.classify(engine: .claude, text: "Not logged in · Please run /login")
        XCTAssertEqual(f.kind, .signedOut)
        XCTAssertEqual(f.message, "Claude Code needs you to sign in. Click here to open Terminal.")
        XCTAssertEqual(f.action, .openTerminal(command: "claude auth login"))

        let c = ErrorClassifier.classify(engine: .codex, text: "unexpected status 401 Unauthorized: Missing bearer")
        XCTAssertEqual(c.kind, .signedOut)
        XCTAssertEqual(c.action, .openTerminal(command: "codex login"))
    }

    func testUsageLimit() {
        let f = ErrorClassifier.classify(engine: .codex, text: "You've hit your usage limit. Upgrade to Pro")
        XCTAssertEqual(f.kind, .usageLimit)
        XCTAssertTrue(f.message.contains("ChatGPT"))
    }

    func testSessionLost() {
        let f = ErrorClassifier.classify(engine: .claude, text: "No conversation found with session ID: x")
        XCTAssertEqual(f.kind, .sessionLost)
    }

    func testNetworkAndOverloaded() {
        XCTAssertEqual(ErrorClassifier.classify(engine: .claude, text: "getaddrinfo ENOTFOUND api.anthropic.com").kind, .network)
        XCTAssertEqual(ErrorClassifier.classify(engine: .claude, text: "API Error: 529 Overloaded").kind, .overloaded)
    }

    func testMissingCLI() {
        XCTAssertEqual(ErrorClassifier.classify(engine: .codex, text: "", exitCode: 127).kind, .cliMissing)
    }

    func testUnknownKeepsFirstLine() {
        let f = ErrorClassifier.classify(engine: .claude, text: "Weird thing\nstack trace", exitCode: 3)
        XCTAssertEqual(f.kind, .unknown)
        XCTAssertEqual(f.message, "Claude Code ran into a problem: Weird thing")
        XCTAssertEqual(f.detail, "Weird thing\nstack trace")
    }
}

final class AppToolPermissionTests: XCTestCase {
    let dir = URL(fileURLWithPath: "/b")
    let vercel = Connector(id: "vercel", name: "Vercel", kind: .http, url: "https://mcp.vercel.com")

    private func args(_ permission: PermissionLevel, connectors: [Connector], guardOn: Bool) -> [String] {
        var o = RunOptions()
        o.manageConnectors = true
        o.connectors = connectors
        if guardOn { o.guardHook = GuardHookSetup(helper: "/g", rulesFile: "/r", askBase: "/a", approvalsDir: "/d") }
        return EngineCommand.invocation(for: Bot(id: "b", name: "B", permission: permission), prompt: "x",
                                        botDirectory: dir, sessionId: "s", options: o).arguments
    }

    private func allowed(_ a: [String]) -> [String] {
        guard let i = a.firstIndex(of: "--allowedTools") else { return [] }
        return a[i + 1].split(separator: ",").map(String.init)
    }

    func testWorkspaceBotsCanUseTheirConnectedApps() {
        // Without this, a -p run silently refuses every MCP tool ("2 didn't work").
        XCTAssertTrue(allowed(args(.editWorkspace, connectors: [vercel], guardOn: false)).contains("mcp__vercel"))
        XCTAssertTrue(allowed(args(.readOnly, connectors: [vercel], guardOn: true)).contains("mcp__vercel"))
    }

    func testWorkspaceBotsRunCommandsOnlyWithTheLiveGuard() {
        XCTAssertTrue(allowed(args(.editWorkspace, connectors: [], guardOn: true)).contains("Bash"))
        XCTAssertFalse(allowed(args(.editWorkspace, connectors: [], guardOn: false)).contains("Bash"))
        XCTAssertFalse(allowed(args(.readOnly, connectors: [], guardOn: true)).contains("Bash"))
    }
}
