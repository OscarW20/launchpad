import XCTest
@testable import LaunchpadCore

private func tempDir(_ name: String) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("lp-\(name)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func unlock(_ url: URL) {
    // The rules folder is read-only between writes; make it removable again.
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

// MARK: - Permissions model

final class PermissionsTests: XCTestCase {
    func testDefaults() {
        let r = BotRules()
        XCTAssertEqual(r.rule(.send), .ask)
        XCTAssertEqual(r.rule(.delete), .ask)
        XCTAssertEqual(r.rule(.spend), .ask)
        XCTAssertEqual(r.rule(.change), .ask)
        XCTAssertEqual(r.rule(.shell), .allow, "commands outside its folder are allowed by default, as in Biscuit Bots")
        XCTAssertEqual(r.rule(.computer), .ask)
        XCTAssertFalse(r.hasCustomRules)
    }

    func testSettingADefaultClearsIt() {
        var r = BotRules()
        r.set(.never, for: .send)
        XCTAssertEqual(r.rules, ["send": "never"])
        XCTAssertTrue(r.hasCustomRules)
        r.set(.ask, for: .send)
        XCTAssertEqual(r.rules, [:])
    }

    func testAlwaysAllowNeverForTheTerminal() throws {
        var r = BotRules()
        r.alwaysAllow(.delete, tool: "Bash")
        r.alwaysAllow(.send, tool: "mcp__slack__post_message")
        r.alwaysAllow(.send, tool: "mcp__slack__post_message")
        XCTAssertEqual(r.alwaysAllowed, ["send:mcp__slack__post_message"])
        let json = Data(#"{"rules":{"delete":"never","bogus":"x"},"alwaysAllowed":["delete:Bash","send:mcp__a__b"]}"#.utf8)
        let decoded = try JSONDecoder().decode(BotRules.self, from: json)
        XCTAssertEqual(decoded.alwaysAllowed, ["send:mcp__a__b"], "a saved Terminal always-allow is dropped")
        XCTAssertEqual(decoded.rule(.delete), .never)
        XCTAssertEqual(decoded.changePatterns, [])
        XCTAssertFalse(BotRules.canAlwaysAllow(tool: "Bash"))
    }

    func testMergeKeepsAlwaysAllowsAddedMeanwhile() {
        let stored = BotRules(alwaysAllowed: ["send:a", "send:b", "send:c"])
        var edited = BotRules(alwaysAllowed: ["send:a"])
        edited.set(.never, for: .spend)
        let merged = BotRules.merged(stored: stored, edited: edited, removed: ["send:c"])
        XCTAssertEqual(merged.alwaysAllowed, ["send:a", "send:b"])
        XCTAssertEqual(merged.rule(.spend), .never)
    }

    func testBotDecodesOldFilesWithDefaultsAndRoundTrips() throws {
        let old = try JSONCoding.decoder().decode(Bot.self, from: Data(#"{"id":"a","name":"A"}"#.utf8))
        XCTAssertEqual(old.rules, BotRules())
        XCTAssertFalse(old.lockedDown)
        XCTAssertEqual(old.sites, [])
        XCTAssertEqual(old.permission, .editWorkspace, "permission levels stay")

        var bot = Bot(id: "b", name: "B", rules: BotRules(rules: ["delete": "never"], changePatterns: [#"\bterraform apply\b"#]),
                      lockedDown: true, sites: ["github.com"])
        bot.rules.alwaysAllow(.send, tool: "mcp__x__send")
        let back = try JSONCoding.decoder().decode(Bot.self, from: JSONCoding.encoder().encode(bot))
        XCTAssertEqual(back.rules, bot.rules)
        XCTAssertTrue(back.lockedDown)
        XCTAssertEqual(back.sites, ["github.com"])
    }

    func testCodexNote() {
        XCTAssertTrue(BotRules(rules: ["send": "allow", "delete": "allow", "spend": "allow", "change": "allow"]).codexNote().isEmpty)
        let note = BotRules(rules: ["spend": "never"], changePatterns: ["terraform apply"]).codexNote(lockedSkills: ["deploy"])
        XCTAssertTrue(note.contains("[[approve:"))
        XCTAssertTrue(note.contains("send or post"))
        XCTAssertTrue(note.contains("Never do these") && note.contains("spend money"))
        XCTAssertTrue(note.contains("terraform apply"))
        XCTAssertTrue(note.contains("locked") && note.contains("deploy"))
        XCTAssertFalse(note.contains("use your mac"), "computer use isn't something Codex can do")
    }

    func testToolNames() {
        XCTAssertEqual(ToolNames.readable("Bash"), "Terminal")
        XCTAssertEqual(ToolNames.readable("mcp__slack__slack_post_message"), "Slack · post message")
        XCTAssertEqual(ToolNames.readable("mcp__slack__chatPostMessage"), "Slack · chat post message")
        XCTAssertEqual(ToolNames.readable("Write"), "Write")
    }

    func testSkillLocks() throws {
        let root = tempDir("locks")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = LaunchpadPaths(root: root)
        let locks = SkillLocks(paths: paths)
        XCTAssertEqual(locks.load(), [])
        try locks.setLocked("deploy", true)
        try locks.setLocked("review", true)
        try locks.setLocked("review", false)
        XCTAssertEqual(locks.load(), ["deploy"])
        XCTAssertTrue(locks.file.path.hasPrefix(paths.launchpadData.path), "locks live where bots can't write")
        let dirs = SkillLocks.lockedDirs(skillIds: ["deploy", "notes"], locked: locks.load(), paths: paths, botId: "scout")
        XCTAssertEqual(dirs, [
            paths.skills.appendingPathComponent("deploy").path,
            paths.botDir("scout").appendingPathComponent(".claude/skills/deploy").path,
            paths.botDir("scout").appendingPathComponent(".agents/skills/deploy").path,
            paths.botDir("scout").appendingPathComponent(".codex/skills/deploy").path,
        ])
    }

    func testProtocolTextForLiveApprovals() {
        XCTAssertTrue(LaunchpadProtocol.text(skills: []).contains("[[approve:"))
        let live = LaunchpadProtocol.text(skills: [], liveApprovals: true)
        XCTAssertTrue(live.contains("approval card"))
        XCTAssertFalse(live.contains("[[approve:"))
    }
}

// MARK: - Rules file and hook settings

final class GuardSetupTests: XCTestCase {
    func testRulesFileIsWrittenOutsideTheBotFolderAndReadBack() throws {
        let root = tempDir("rules")
        let paths = LaunchpadPaths(root: root)
        defer { unlock(paths.guardRules); try? FileManager.default.removeItem(at: root) }
        var bot = Bot(id: "scout", name: "Scout", rules: BotRules(rules: ["delete": "never"], changePatterns: ["x"]))
        bot.rules.alwaysAllow(.send, tool: "mcp__slack__post")
        bot.rules.alwaysAllow(.computer, tool: "mcp__computer__click")
        let group = root.appendingPathComponent("groups/team")
        let config = GuardRulesFile.config(for: bot, paths: paths, extraRoots: [group], lockedSkillDirs: ["/s/deploy"],
                                           trustedServers: ["launchpad"], home: URL(fileURLWithPath: "/home/me"))
        let url = try GuardRulesFile.write(config, botId: bot.id, paths: paths)
        XCTAssertEqual(url, paths.rulesFile("scout"))
        XCTAssertFalse(url.path.hasPrefix(paths.botDir("scout").path))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let back = GuardConfig(json: json)
        XCTAssertEqual(back, config)
        XCTAssertEqual(back.rules["delete"], "never")
        XCTAssertEqual(back.rules["send"], "ask", "every category is spelled out")
        XCTAssertEqual(back.roots, [paths.botDir("scout").path, group.path])
        XCTAssertEqual(back.answers, paths.approvalAnswers.path)
        XCTAssertTrue(back.protected.contains(paths.guardRules.path))
        XCTAssertTrue(back.protected.contains("/home/me/.claude/settings.json"))
        XCTAssertEqual(back.alwaysAllowed.count, 2)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o444)

        // Writing again replaces it (the folder is read-only in between).
        _ = try GuardRulesFile.write(config, botId: bot.id, paths: paths)

        // Locked down: "Always allow" no longer applies to writes.
        bot.lockedDown = true
        let locked = GuardRulesFile.config(for: bot, paths: paths)
        XCTAssertTrue(locked.noAlwaysForWrites)
        XCTAssertEqual(locked.alwaysAllowed, ["computer:mcp__computer__click"])
    }

    func testClaudeSettings() throws {
        let hook = GuardHookSetup(helper: "/Apps/Launch pad.app/Contents/MacOS/launchpad-guard", rulesFile: "/r/it's.json",
                                  askBase: "/q/chat-run", approvalsDir: "/a")
        XCTAssertEqual(hook.command, #"'/Apps/Launch pad.app/Contents/MacOS/launchpad-guard' hook '/r/it'\''s.json' --ask '/q/chat-run' --approvals '/a'"#)
        let text = try XCTUnwrap(GuardHookSetup.claudeSettings(hook: hook, sandboxed: true))
        let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        let pre = ((obj["hooks"] as! [String: Any])["PreToolUse"] as! [[String: Any]])[0]
        XCTAssertEqual(pre["matcher"] as? String, "*")
        let h = (pre["hooks"] as! [[String: Any]])[0]
        XCTAssertEqual(h["timeout"] as? Int, 600)
        XCTAssertEqual(h["command"] as? String, hook.command)
        XCTAssertEqual(obj["disableAllHooks"] as? Bool, false)
        XCTAssertEqual((obj["sandbox"] as? [String: Bool])?["enabled"], false)

        XCTAssertNil(GuardHookSetup.claudeSettings(hook: nil, sandboxed: false))
        XCTAssertEqual(GuardHookSetup.claudeSettings(hook: nil, sandboxed: true), #"{"sandbox":{"enabled":false}}"#)
        XCTAssertTrue(GuardHookSetup.claudeSettings(hook: nil, legacyCommand: "g", sandboxed: false)!.contains(#""matcher":"Bash|mcp__.*""#))
    }

    func testRunOptionsWithGuardHookAndSandbox() {
        var o = RunOptions()
        o.guardCommand = "/old --approvals /a"
        o.guardHook = GuardHookSetup(helper: "/g", rulesFile: "/r.json")
        o.sandboxProfile = "(version 1)"
        let inv = EngineCommand.invocation(for: Bot(id: "b", name: "B"), prompt: "hi", botDirectory: URL(fileURLWithPath: "/b"), sessionId: "s", options: o)
        let settings = inv.arguments[inv.arguments.firstIndex(of: "--settings")! + 1]
        XCTAssertTrue(settings.contains(#""matcher":"*""#), "the new hook wins over the old command")
        XCTAssertTrue(settings.contains(#""sandbox":{"enabled":false}"#))
        XCTAssertEqual(inv.sandboxProfile, "(version 1)")
        let launch = inv.launch(executable: URL(fileURLWithPath: "/usr/local/bin/claude"))
        XCTAssertEqual(launch.executable.path, "/usr/bin/sandbox-exec")
        XCTAssertEqual(Array(launch.arguments.prefix(3)), ["-p", "(version 1)", "/usr/local/bin/claude"])
        XCTAssertEqual(Array(launch.arguments.dropFirst(3)), inv.arguments)

        let plain = EngineCommand.invocation(for: Bot(id: "b", name: "B"), prompt: "hi", botDirectory: URL(fileURLWithPath: "/b"), sessionId: "s")
        XCTAssertNil(plain.sandboxProfile)
        XCTAssertEqual(plain.launch(executable: URL(fileURLWithPath: "/x/claude")).executable.path, "/x/claude")
    }

    func testCodexMapsRulesOntoItsSandbox() {
        let dir = URL(fileURLWithPath: "/b")
        var o = RunOptions()
        o.sandboxProfile = "(version 1)"
        o.addDirectories = [URL(fileURLWithPath: "/g")]
        func args(_ bot: Bot) -> EngineInvocation {
            EngineCommand.invocation(for: bot, prompt: "x", botDirectory: dir, sessionId: nil, options: o)
        }
        let full = args(Bot(id: "c", name: "C", engine: .codex, permission: .fullAccess))
        XCTAssertTrue(full.arguments.contains("--dangerously-bypass-approvals-and-sandbox"))
        XCTAssertEqual(full.sandboxProfile, "(version 1)", "our sandbox goes around Codex only when it has none of its own")

        let fenced = args(Bot(id: "c", name: "C", engine: .codex, permission: .fullAccess, rules: BotRules(rules: ["delete": "never"])))
        XCTAssertTrue(fenced.arguments.contains("sandbox_mode=\"workspace-write\""))
        XCTAssertTrue(fenced.arguments.contains("sandbox_workspace_write.network_access=true"))
        XCTAssertTrue(fenced.arguments.contains("sandbox_workspace_write.writable_roots=[\"/g\"]"))
        XCTAssertNil(fenced.sandboxProfile)
        let shellAsk = args(Bot(id: "c", name: "C", engine: .codex, permission: .fullAccess, rules: BotRules(rules: ["shell": "ask"])))
        XCTAssertFalse(shellAsk.arguments.contains("--dangerously-bypass-approvals-and-sandbox"))

        let locked = args(Bot(id: "c", name: "C", engine: .codex, permission: .fullAccess, lockedDown: true))
        XCTAssertTrue(locked.arguments.contains("sandbox_workspace_write.network_access=false"))
        XCTAssertFalse(locked.arguments.contains("--dangerously-bypass-approvals-and-sandbox"))

        let readOnly = args(Bot(id: "c", name: "C", engine: .codex, permission: .readOnly, lockedDown: true))
        XCTAssertTrue(readOnly.arguments.contains("sandbox_mode=\"read-only\""))
    }
}

// MARK: - The hook and the approval handshake

private final class ResultBox: @unchecked Sendable {
    var value: HookResult?
}

final class GuardHookTests: XCTestCase {
    var root: URL!
    var paths: LaunchpadPaths!
    var rulesFile: String!
    var inbox: ApprovalInbox!

    override func setUpWithError() throws {
        root = tempDir("hook")
        paths = LaunchpadPaths(root: root)
        let bot = Bot(id: "scout", name: "Scout")
        try FileManager.default.createDirectory(at: paths.botDir("scout"), withIntermediateDirectories: true)
        rulesFile = try GuardRulesFile.write(GuardRulesFile.config(for: bot, paths: paths), botId: "scout", paths: paths).path
        inbox = ApprovalInbox(paths: paths)
    }

    override func tearDown() {
        unlock(paths.guardRules)
        try? FileManager.default.removeItem(at: root)
    }

    func call(_ command: String, session: String = "s1") -> Data {
        let obj: [String: Any] = ["session_id": session, "tool_name": "Bash", "tool_input": ["command": command], "cwd": paths.botDir("scout").path]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    func testFailsClosed() {
        XCTAssertEqual(GuardHook.run(input: Data("not json".utf8), rulesPath: rulesFile, askBase: nil, grants: nil).exitCode, 2)
        XCTAssertEqual(GuardHook.run(input: call("ls"), rulesPath: "/nope.json", askBase: nil, grants: nil).exitCode, 2, "no rules, no go")
        XCTAssertEqual(GuardHook.run(input: call("ls"), rulesPath: nil, askBase: nil, grants: nil).exitCode, 2)
        let read = Data(#"{"tool_name":"Read","tool_input":{"file_path":"/x"}}"#.utf8)
        XCTAssertEqual(GuardHook.run(input: read, rulesPath: "/nope.json", askBase: nil, grants: nil), .pass, "reads still work so the bot can explain")
    }

    func testPassAndDeny() {
        XCTAssertEqual(GuardHook.run(input: call("ls -la"), rulesPath: rulesFile, askBase: nil, grants: nil), .pass)
        let protected = GuardHook.run(input: call("echo x > \(paths.guardRules.path)/scout.json"), rulesPath: rulesFile, askBase: nil, grants: nil)
        XCTAssertEqual(protected.exitCode, 2)
        XCTAssertEqual(protected.stderr, GuardEngine.protectedReason)
    }

    func testAskWithoutCardsFallsBackToChatApprovalAndGrants() throws {
        let r = GuardHook.run(input: call("git push origin main"), rulesPath: rulesFile, askBase: nil, grants: nil)
        XCTAssertEqual(r.exitCode, 2)
        XCTAssertTrue(r.stderr!.contains("[[approve:"))
        let grants = ApprovalGrants(paths: paths)
        try grants.grant(sessionId: "s1", action: "push")
        XCTAssertEqual(GuardHook.run(input: call("git push origin main"), rulesPath: rulesFile, askBase: nil, grants: grants), .pass)
        XCTAssertEqual(GuardHook.run(input: call("git push origin main", session: "s2"), rulesPath: rulesFile, askBase: nil, grants: grants).exitCode, 2)
    }

    /// Runs the hook on a background thread, answers the card like the app would, and returns the hook's result.
    func ask(_ command: String, answer: ApprovalAnswer?, timeout: TimeInterval = 5) throws -> (HookResult, PendingApproval?) {
        let base = inbox.base(chatId: "chat-1", runId: "run-1")
        let input = call(command)
        let rules = rulesFile!
        let done = expectation(description: "hook")
        let box = ResultBox()
        DispatchQueue.global().async {
            box.value = GuardHook.run(input: input, rulesPath: rules, askBase: base.path, grants: nil, timeout: timeout, poll: 0.02)
            done.fulfill()
        }
        var card: PendingApproval?
        let deadline = Date().addingTimeInterval(3)
        while card == nil, Date() < deadline {
            card = inbox.collect(base: base).new.first
            if card == nil { Thread.sleep(forTimeInterval: 0.02) }
        }
        if let card, let answer { try inbox.answer(card.id, answer) }
        wait(for: [done], timeout: timeout + 5)
        return (try XCTUnwrap(box.value), card)
    }

    func testApproveDenyAndExpire() throws {
        let (approved, card) = try ask("rm ~/Desktop/report.pdf", answer: .approve)
        XCTAssertEqual(card?.kind, .delete)
        XCTAssertEqual(card?.tool, "Bash")
        XCTAssertEqual(card?.bot, "Scout")
        XCTAssertEqual(card?.detail, "rm ~/Desktop/report.pdf")
        XCTAssertFalse(card!.offersAlways, "no Always allow for the Terminal")
        XCTAssertEqual(approved.exitCode, 0)
        XCTAssertTrue(approved.stdout!.contains(#""permissionDecision":"allow""#))

        let (denied, _) = try ask("git push", answer: .deny)
        XCTAssertEqual(denied.exitCode, 2)
        XCTAssertTrue(denied.stderr!.contains("said no"))

        let (always, _) = try ask("git push", answer: .always)
        XCTAssertEqual(always.exitCode, 0)

        let (late, lateCard) = try ask("git push", answer: nil, timeout: 0.3)
        XCTAssertEqual(late.exitCode, 2)
        XCTAssertTrue(late.stderr!.contains("didn't answer in time"))
        let base = inbox.base(chatId: "chat-1", runId: "run-1")
        XCTAssertEqual(inbox.collect(base: base).expired, [lateCard!.id], "the app learns the card no longer does anything")
        XCTAssertTrue(inbox.collect(base: base).new.isEmpty)
    }

    func testStoppedBotStopsWaiting() {
        let base = inbox.base(chatId: "c", runId: "r")
        let start = Date()
        let r = GuardHook.run(input: call("git push"), rulesPath: rulesFile, askBase: base.path, grants: nil,
                              timeout: 30, poll: 0.01, stillWanted: { false })
        XCTAssertEqual(r.exitCode, 2)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testInboxRejectsOddIdsAndCleansUp() throws {
        XCTAssertThrowsError(try inbox.answer("../rules/scout", .approve))
        let base = inbox.base(chatId: "c", runId: "r")
        try FileManager.default.createDirectory(at: paths.approvalRequests, withIntermediateDirectories: true)
        let forged = PendingApproval(id: "../../x", category: "send", tool: "t", detail: "d")
        try JSONEncoder().encode(forged).write(to: URL(fileURLWithPath: base.path + ".approval-..%2Fx.json"))
        XCTAssertTrue(inbox.collect(base: base).new.isEmpty, "a card with an odd id is ignored")
        try inbox.answer("abc-123", .approve)
        inbox.close(base: base, ids: ["abc-123"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.approvalAnswers.appendingPathComponent("abc-123.answer").path))
    }
}

// MARK: - Sandbox

final class SandboxTests: XCTestCase {
    func testEveryBotsProfile() {
        let s = BotSandbox(lockedDown: false, launchpadRoot: "/nonexistent-lp/Launchpad", appBundle: "/Applications/Launchpad.app",
                           home: "/nonexistent-lp/home", extraProtected: ["/nonexistent-lp/secret"])
        let p = s.profile()
        XCTAssertTrue(p.hasPrefix("(version 1)\n(allow default)"))
        XCTAssertTrue(p.contains(#"(deny file-write* (subpath "/nonexistent-lp/Launchpad/.launchpad") (subpath "/nonexistent-lp/secret") (subpath "/Applications/Launchpad.app")"#))
        XCTAssertTrue(p.contains(#"(regex #"/\.claude/settings(\.local)?\.json$")"#))
        XCTAssertTrue(p.contains(#"(regex #"/managed-settings\.json$")"#))
        XCTAssertTrue(p.contains(#"(allow file-write* (subpath "/nonexistent-lp/Launchpad/.launchpad/requests") (subpath "/nonexistent-lp/Launchpad/.launchpad/scratch"))"#),
                      "the hook can still leave its approval cards")
        XCTAssertFalse(p.contains("network-outbound"))
        XCTAssertFalse(p.contains("lsopen"))
        // Later rules win, so the exception comes after the deny.
        XCTAssertLessThan(p.range(of: "(deny file-write*")!.lowerBound, p.range(of: "(allow file-write*")!.lowerBound)
        // Not a bundle (swift run): not protected as one.
        XCTAssertFalse(BotSandbox(launchpadRoot: "/x", appBundle: "/x/.build/debug", home: "/h").profile().contains(".build/debug"))
    }

    func testLockedDownProfile() {
        let p = BotSandbox(lockedDown: true, launchpadRoot: "/nonexistent-lp/L", home: "/nonexistent-lp/home").profile()
        XCTAssertTrue(p.contains("(deny network-outbound)"))
        XCTAssertTrue(p.contains(#"(allow network-outbound (remote ip "localhost:*"))"#))
        XCTAssertTrue(p.contains("(deny lsopen)"))
        XCTAssertTrue(p.contains("(deny appleevent-send)"))
        XCTAssertTrue(p.contains(#"(subpath "/nonexistent-lp/home/Library/LaunchAgents")"#))
        XCTAssertTrue(p.contains(#"(literal "/nonexistent-lp/home/.zshrc")"#))
        XCTAssertTrue(p.contains(#"(subpath "/usr/lib/cron")"#))
    }

    func testQuotingAndRealPaths() throws {
        XCTAssertEqual(BotSandbox.quote(#"a"b\c"#), #""a\"b\\c""#)
        let dir = tempDir("real")
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir.appendingPathComponent("target"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("target"), withIntermediateDirectories: true)
        XCTAssertEqual(BotSandbox.real(link.path + "/not/yet"), BotSandbox.real(dir.path) + "/target/not/yet")
    }

    func testWrapAndSites() {
        let s = BotSandbox(launchpadRoot: "/L", home: "/h")
        let w = s.wrap(executable: URL(fileURLWithPath: "/bin/claude"), arguments: ["-p"])
        XCTAssertEqual(w.executable.path, BotSandbox.tool)
        XCTAssertEqual(w.arguments, ["-p", s.profile(), "/bin/claude", "-p"])
        let bot = Bot(id: "b", name: "B", engine: .claude, sites: ["GitHub.com", " "])
        let mcp = [Connector(id: "n", name: "N", kind: .stdio, command: "npx"), Connector(id: "h", name: "H", kind: .http, url: "https://mcp.linear.app/sse")]
        XCTAssertEqual(BotSandbox.allowedSites(for: bot, connectors: mcp),
                       ["anthropic.com", "claude.ai", "claude.com", "github.com", "mcp.linear.app", "registry.npmjs.org"])
    }

    #if os(macOS)
    /// The kernel really enforces it (macOS only).
    func testKernelEnforcesTheProfile() throws {
        guard BotSandbox.available else { throw XCTSkip("sandbox-exec missing") }
        // macOS won't start a sandbox from inside one, which is where a bot runs the tests.
        let probe = Process()
        let refusal = Pipe()
        probe.executableURL = URL(fileURLWithPath: BotSandbox.tool)
        probe.arguments = ["-p", "(version 1)(allow default)", "/usr/bin/true"]
        probe.standardError = refusal
        try probe.run()
        let said = String(data: refusal.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        probe.waitUntilExit()
        if probe.terminationStatus != 0, said.contains("sandbox_apply: Operation not permitted") {
            throw XCTSkip("Already inside a sandbox (a bot is running the tests), so sandbox-exec can't start another. Run this test from Terminal or CI.")
        }
        let root = tempDir("kernel")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = LaunchpadPaths(root: root)
        try FileManager.default.createDirectory(at: paths.guardRules, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.approvalRequests, withIntermediateDirectories: true)
        let s = BotSandbox(launchpadRoot: root.path, home: NSHomeDirectory())
        func sh(_ script: String) -> Int32 {
            let w = s.wrap(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
            let p = Process()
            p.executableURL = w.executable
            p.arguments = w.arguments
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }
        XCTAssertNotEqual(sh("echo x > '\(paths.guardRules.path)/x.json'"), 0, "rules can't be written")
        XCTAssertEqual(sh("echo x > '\(paths.approvalRequests.path)/x.json'"), 0, "requests can")
        XCTAssertNotEqual(sh("echo x > '\(root.path)/bots/.claude/settings.json'"), 0, "no Claude settings files")
        XCTAssertEqual(sh("mkdir -p '\(root.path)/bots/b' && echo x > '\(root.path)/bots/b/ok.txt'"), 0)
    }
    #endif
}

// MARK: - Snapshots (real git)

final class SnapshotTests: XCTestCase {
    func testSnapshotChangesAndUndo() throws {
        let root = tempDir("snap")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = LaunchpadPaths(root: root)
        let snaps = Snapshots(paths: paths)
        guard snaps.available else { throw XCTSkip("git isn't installed") }
        let bot = paths.botDir("scout")
        let ws = bot.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        try "one".write(to: ws.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        try "two".write(to: ws.appendingPathComponent("gone.txt"), atomically: true, encoding: .utf8)
        try "memory".write(to: bot.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)

        let snap = try XCTUnwrap(snaps.take(botId: "scout", folder: bot))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.snapshotStore("scout").path), "the store is Launchpad's, not the bot's")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bot.appendingPathComponent(".git").path))

        // The reply edits, deletes and adds files (and updates its memory, which undo leaves alone).
        try "ONE".write(to: ws.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: ws.appendingPathComponent("gone.txt"))
        try FileManager.default.createDirectory(at: ws.appendingPathComponent("new"), withIntermediateDirectories: true)
        try "three".write(to: ws.appendingPathComponent("new/added.txt"), atomically: true, encoding: .utf8)
        try "memory 2".write(to: bot.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)

        XCTAssertEqual(Set(snaps.changes(botId: "scout", folder: bot, since: snap)),
                       ["workspace/keep.txt", "workspace/gone.txt", "workspace/new/added.txt"])
        XCTAssertTrue(snaps.undo(botId: "scout", folder: bot, to: snap))
        XCTAssertEqual(try String(contentsOf: ws.appendingPathComponent("keep.txt"), encoding: .utf8), "one")
        XCTAssertEqual(try String(contentsOf: ws.appendingPathComponent("gone.txt"), encoding: .utf8), "two")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ws.appendingPathComponent("new/added.txt").path))
        XCTAssertEqual(try String(contentsOf: bot.appendingPathComponent("notes.md"), encoding: .utf8), "memory 2")
        XCTAssertEqual(snaps.changes(botId: "scout", folder: bot, since: snap), [])

        // A second snapshot on the same store works, and bad ids are refused.
        XCTAssertNotNil(snaps.take(botId: "scout", folder: bot))
        XCTAssertFalse(snaps.undo(botId: "scout", folder: bot, to: "--help"))
        XCTAssertEqual(snaps.changes(botId: "scout", folder: bot, since: "HEAD; rm"), [])
    }

    func testMissingFolderOrGit() {
        let paths = LaunchpadPaths(root: URL(fileURLWithPath: "/nonexistent-lp"))
        XCTAssertNil(Snapshots(paths: paths).take(botId: "x", folder: URL(fileURLWithPath: "/nonexistent-lp/bots/x")))
        let noGit = Snapshots(paths: paths, git: nil)
        XCTAssertFalse(noGit.available)
        XCTAssertNil(noGit.take(botId: "x", folder: FileManager.default.temporaryDirectory))
    }
}

// MARK: - Secrets

final class SecretReadTests: XCTestCase {
    /// A store written before `read` existed still works, via the default.
    final class OldStore: SecretStore {
        var values: [String: String] = [:]
        func secret(_ account: String) -> String? { values[account] }
        func setSecret(_ value: String?, for account: String) throws { values[account] = value }
    }

    func testFoundMissingFailed() throws {
        let s = MemorySecretStore()
        try s.setSecret("tok", for: "a")
        XCTAssertEqual(s.read("a"), .found("tok"))
        XCTAssertEqual(s.read("b"), .missing)
        s.failing["a"] = "The Keychain is locked."
        XCTAssertEqual(s.read("a"), .failed("The Keychain is locked."))
        XCTAssertNil(s.secret("a"), "a failed read has no value")

        let old = OldStore()
        old.values = ["a": "x", "e": ""]
        let store: SecretStore = old
        XCTAssertEqual(store.read("a"), .found("x"))
        XCTAssertEqual(store.read("e"), .missing)
        XCTAssertEqual(store.read("z").value, nil)
    }
}

// MARK: - Site gateway

final class SiteGatewayTests: XCTestCase {
    func testSiteMatching() {
        XCTAssertTrue(SiteGateway.allows(host: "api.github.com", sites: ["github.com"]))
        XCTAssertTrue(SiteGateway.allows(host: "GitHub.com", sites: ["github.com"]))
        XCTAssertFalse(SiteGateway.allows(host: "evilgithub.com", sites: ["github.com"]))
        XCTAssertFalse(SiteGateway.allows(host: "github.com.evil.io", sites: ["github.com"]))
        XCTAssertFalse(SiteGateway.allows(host: "x.com", sites: [""]))
        let env = SiteGateway.proxyEnvironment(port: 8123, token: "t")
        XCTAssertEqual(env["HTTPS_PROXY"], "http://bot:t@127.0.0.1:8123")
        XCTAssertEqual(env["NO_PROXY"], "localhost,127.0.0.1,::1")
    }

    func testTunnelsOnlyListedSites() throws {
        // A tiny upstream server on this machine that answers "pong".
        let upstream = try EchoServer()
        defer { upstream.stop() }
        let gateway = SiteGateway()
        let port = gateway.start()
        XCTAssertNotEqual(port, 0)
        defer { gateway.stop() }
        let token = gateway.issue(sites: ["127.0.0.1"])
        let auth = Data("bot:\(token)".utf8).base64EncodedString()

        let ok = try TestSocket.exchange(port: port, "CONNECT 127.0.0.1:\(upstream.port) HTTP/1.1\r\nProxy-Authorization: Basic \(auth)\r\n\r\nping")
        XCTAssertTrue(ok.hasPrefix("HTTP/1.1 200"), ok)
        XCTAssertTrue(ok.hasSuffix("pong"), ok)

        let other = gateway.issue(sites: ["example.com"])
        let denied = try TestSocket.exchange(port: port, "CONNECT 127.0.0.1:\(upstream.port) HTTP/1.1\r\nProxy-Authorization: Basic \(Data("bot:\(other)".utf8).base64EncodedString())\r\n\r\n")
        XCTAssertTrue(denied.hasPrefix("HTTP/1.1 403"), denied)
        XCTAssertTrue(denied.contains("isn't on its list"))

        let noAuth = try TestSocket.exchange(port: port, "CONNECT 127.0.0.1:\(upstream.port) HTTP/1.1\r\n\r\n")
        XCTAssertTrue(noAuth.hasPrefix("HTTP/1.1 407"), noAuth)
        gateway.revoke(token)
        let revoked = try TestSocket.exchange(port: port, "CONNECT 127.0.0.1:\(upstream.port) HTTP/1.1\r\nProxy-Authorization: Basic \(auth)\r\n\r\n")
        XCTAssertTrue(revoked.hasPrefix("HTTP/1.1 407"), revoked)
    }
}
