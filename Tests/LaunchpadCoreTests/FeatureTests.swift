import XCTest
@testable import LaunchpadCore

final class SkillTests: XCTestCase {
    var paths: LaunchpadPaths!

    override func setUpWithError() throws {
        paths = LaunchpadPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("lp-sk-\(UUID().uuidString)"))
        try paths.ensureStructure()
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: paths.root) }

    func testFrontMatterRoundTrip() {
        let text = SkillFile.compose(name: "deploy", description: "Use when deploying.", body: "# Deploy\n\nSteps")
        let parsed = SkillFile.parse(text)
        XCTAssertEqual(parsed.name, "deploy")
        XCTAssertEqual(parsed.description, "Use when deploying.")
        XCTAssertEqual(parsed.body, "# Deploy\n\nSteps")
        XCTAssertEqual(SkillFile.parse("no front matter").body, "no front matter")
    }

    func testStarterSkillsSeedOnce() throws {
        let store = SkillStore(paths: paths)
        store.seedStarterSkillsIfNeeded()
        XCTAssertEqual(Set(store.loadAll().map(\.id)), ["new-project", "deploy", "code-review", "write-spec"])
        try store.delete(id: "deploy")
        store.seedStarterSkillsIfNeeded()
        XCTAssertNil(store.load(id: "deploy"), "deleted starters stay deleted")
    }

    func testCreateDuplicateEdit() throws {
        let store = SkillStore(paths: paths)
        let s = try store.create(name: "Release Notes", description: "Use when writing release notes.", body: "Steps")
        XCTAssertEqual(s.id, "release-notes")
        let copy = try store.duplicate(id: s.id)
        XCTAssertEqual(copy.id, "release-notes-copy")
        XCTAssertEqual(copy.description, "Use when writing release notes.")
        try store.save(id: s.id, text: SkillFile.compose(name: s.id, description: "changed", body: "x"))
        XCTAssertEqual(store.load(id: s.id)?.description, "changed")
    }

    func testLinkerAddsAndRemovesSymlinksOnly() throws {
        let skills = SkillStore(paths: paths)
        skills.seedStarterSkillsIfNeeded()
        let bot = try BotStore(paths: paths).create(name: "Dev")
        let linker = SkillLinker(paths: paths)
        linker.link(botId: bot.id, skills: ["deploy", "code-review", "missing"])
        for folder in SkillLinker.linkFolders {
            let dir = paths.botDir(bot.id).appendingPathComponent(folder)
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)), ["deploy", "code-review"])
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("deploy/SKILL.md").path))
        }
        // A real folder the bot made itself is left alone.
        let own = paths.botDir(bot.id).appendingPathComponent(".claude/skills/my-own")
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        linker.link(botId: bot.id, skills: ["deploy"])
        let dir = paths.botDir(bot.id).appendingPathComponent(".claude/skills")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)), ["deploy", "my-own"])
    }

    func testGroupSkillsReachMembers() {
        let bot = Bot(id: "a", name: "A", skills: ["x"])
        let groups = [BotGroup(id: "g", name: "g", members: ["a"], skills: ["y", "x"]), BotGroup(id: "h", name: "h", members: ["b"], skills: ["z"])]
        XCTAssertEqual(SkillLinker.effectiveSkills(for: bot, groups: groups), ["x", "y"])
    }

    func testTeachDraftCleanup() {
        XCTAssertEqual(SkillTeacher.cleanDraft("```markdown\n---\nname: a\n---\nbody\n```"), "---\nname: a\n---\nbody\n")
        XCTAssertEqual(SkillTeacher.cleanDraft("Sure! Here it is:\n---\nname: a\n---\nb"), "---\nname: a\n---\nb\n")
        let t = SkillTeacher.transcript([
            ChatMessage(role: .user, text: "deploy it"),
            ChatMessage(role: .bot, botId: "s", text: "Done", steps: [Step(id: "1", tool: "Bash", title: "Ran `vercel`", detail: "vercel --prod")]),
        ], botName: { _ in "Shipper" })
        XCTAssertTrue(t.contains("### Me\ndeploy it"))
        XCTAssertTrue(t.contains("- Ran `vercel`: vercel --prod"))
    }
}

final class ApprovalTests: XCTestCase {
    func testExtractApproval() {
        let (text, req) = ApprovalRequest.extract(from: "Plan ready.\n\n[[approve: deploy habit-tracker to production]]\n")
        XCTAssertEqual(text, "Plan ready.")
        XCTAssertEqual(req?.action, "deploy habit-tracker to production")
        XCTAssertNil(ApprovalRequest.extract(from: "nothing here").request)
    }

    func testRiskyCommands() {
        let risky: [(String, RiskKind)] = [
            ("vercel --prod --yes", .deploy), ("vercel deploy", .deploy), ("cd app && vercel", .deploy),
            ("git push origin main", .deploy), ("npx supabase db push", .deploy), ("npm publish", .deploy),
            ("rm -rf node_modules", .delete), ("rm old.txt", .delete), ("git reset --hard HEAD~1", .delete),
            ("psql -c 'DROP TABLE users'", .delete),
            ("curl -X POST https://api.example.com/x", .send), ("gh pr create --fill", .send),
            ("vercel domains buy habits.app", .spend),
        ]
        for (cmd, kind) in risky { XCTAssertEqual(RiskClassifier.classify(command: cmd), kind, cmd) }

        let safe = ["npm run build", "vercel env ls", "vercel login", "git status", "git commit -m x",
                    "curl https://example.com", "curl -X POST http://localhost:3000/api", "npx playwright test",
                    "ls -la", "echo rm", "npm install", "grep -r remove src"]
        for cmd in safe { XCTAssertNil(RiskClassifier.classify(command: cmd), cmd) }
    }

    func testRiskyMCPTools() {
        XCTAssertEqual(RiskClassifier.classify(mcpTool: "mcp__gmail__send_email"), .send)
        XCTAssertEqual(RiskClassifier.classify(mcpTool: "mcp__supabase__delete_branch"), .delete)
        XCTAssertEqual(RiskClassifier.classify(mcpTool: "mcp__vercel__deploy_project"), .deploy)
        XCTAssertNil(RiskClassifier.classify(mcpTool: "mcp__github__list_issues"))
    }

    func testGuardBlocksUntilApproved() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lp-ap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let grants = ApprovalGrants(directory: dir)
        let hook = Data(#"{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"vercel --prod"}}"#.utf8)
        guard case .block(let reason) = GuardDecision.evaluate(hookJSON: hook, grants: grants) else { return XCTFail() }
        XCTAssertTrue(reason.contains("[[approve:"))

        let now = Date()
        try grants.grant(sessionId: "s1", action: "deploy", now: now)
        XCTAssertEqual(GuardDecision.evaluate(hookJSON: hook, grants: grants, now: now), .allow)
        XCTAssertNotEqual(GuardDecision.evaluate(hookJSON: hook, grants: grants, now: now.addingTimeInterval(ApprovalGrants.validity + 1)), .allow, "approvals expire")
        let other = Data(#"{"session_id":"s2","tool_name":"Bash","tool_input":{"command":"vercel --prod"}}"#.utf8)
        XCTAssertNotEqual(GuardDecision.evaluate(hookJSON: other, grants: grants, now: now), .allow, "approvals are per session")
        let safe = Data(#"{"session_id":"s2","tool_name":"Bash","tool_input":{"command":"npm test"}}"#.utf8)
        XCTAssertEqual(GuardDecision.evaluate(hookJSON: safe, grants: grants), .allow)
    }
}

final class ConnectorTests: XCTestCase {
    let http = Connector(id: "linear-api", name: "Linear", kind: .http, url: "https://mcp.linear.app/mcp", usesToken: true)
    let stdio = Connector(id: "pg", name: "Postgres", kind: .stdio, command: "npx", args: ["-y", "pg-mcp"], secretEnv: ["DATABASE_URL"])

    func testClaudeConfigUsesPlaceholdersNotSecrets() throws {
        let json = MCPConfig.claudeJSON([http, stdio])
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let servers = obj["mcpServers"] as! [String: Any]
        let h = servers["linear_api"] as! [String: Any]
        XCTAssertEqual(h["type"] as? String, "http")
        XCTAssertEqual((h["headers"] as? [String: String])?["Authorization"], "Bearer ${LP_LINEAR_API_TOKEN}")
        let s = servers["pg"] as! [String: Any]
        XCTAssertEqual(s["command"] as? String, "npx")
        XCTAssertEqual((s["env"] as? [String: String])?["DATABASE_URL"], "${LP_PG_DATABASE_URL}")
    }

    func testCodexArgs() {
        XCTAssertEqual(MCPConfig.codexArgs([http, stdio]), [
            "-c", "mcp_servers.linear_api.url=\"https://mcp.linear.app/mcp\"",
            "-c", "mcp_servers.linear_api.bearer_token_env_var=\"LP_LINEAR_API_TOKEN\"",
            "-c", "mcp_servers.pg.command=\"npx\"",
            "-c", "mcp_servers.pg.args=[\"-y\",\"pg-mcp\"]",
            "-c", "mcp_servers.pg.env_vars=[\"DATABASE_URL\"]",
        ])
    }

    func testEnvironmentComesFromSecretStore() throws {
        let secrets = MemorySecretStore()
        try secrets.setSecret("tok", for: http.tokenAccount)
        try secrets.setSecret("postgres://x", for: stdio.envAccount("DATABASE_URL"))
        XCTAssertEqual(MCPConfig.environment([http, stdio], secrets: secrets, engine: .claude),
                       ["LP_LINEAR_API_TOKEN": "tok", "LP_PG_DATABASE_URL": "postgres://x"])
        XCTAssertEqual(MCPConfig.environment([http, stdio], secrets: secrets, engine: .codex),
                       ["LP_LINEAR_API_TOKEN": "tok", "DATABASE_URL": "postgres://x"])
    }

    func testConnectorsFileHasNoSecrets() throws {
        let paths = LaunchpadPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("lp-c-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = ConnectorStore(paths: paths)
        try store.saveAll([http, stdio])
        XCTAssertEqual(store.loadAll(), [http, stdio])
        let raw = try String(contentsOf: paths.connectorsFile, encoding: .utf8)
        XCTAssertFalse(raw.contains("tok"))
    }

    func testEffectiveConnectors() {
        let bot = Bot(id: "a", name: "A", connectors: ["pg"])
        let groups = [BotGroup(id: "g", name: "g", members: ["a"], connectors: ["linear-api"])]
        XCTAssertEqual(MCPConfig.effective(for: bot, groups: groups, all: [http, stdio]).map(\.id), ["linear-api", "pg"])
    }
}

final class RunOptionsTests: XCTestCase {
    let dir = URL(fileURLWithPath: "/b")

    func testClaudeOptions() {
        var o = RunOptions()
        o.addDirectories = [URL(fileURLWithPath: "/g/workspace")]
        o.systemAppend = "RULES"
        o.manageConnectors = true
        o.guardCommand = "/app/launchpad-guard --approvals /a"
        o.environment = ["LP_X": "secret"]
        let inv = EngineCommand.invocation(for: Bot(id: "b", name: "B"), prompt: "hi", botDirectory: dir, sessionId: "s", options: o)
        let a = inv.arguments
        XCTAssertEqual(a[a.firstIndex(of: "--add-dir")! + 1], "/g/workspace")
        XCTAssertEqual(a[a.firstIndex(of: "--append-system-prompt")! + 1], "RULES")
        XCTAssertTrue(a.contains("--strict-mcp-config"))
        XCTAssertEqual(a[a.firstIndex(of: "--mcp-config")! + 1], #"{"mcpServers":{}}"#)
        XCTAssertTrue(a[a.firstIndex(of: "--settings")! + 1].contains(#""matcher":"Bash|mcp__.*""#))
        XCTAssertFalse(a.joined().contains("secret"), "secrets never go on the command line")
        XCTAssertEqual(inv.environment, ["LP_X": "secret"])
    }

    func testCodexOptions() {
        var o = RunOptions()
        o.addDirectories = [URL(fileURLWithPath: "/g/workspace")]
        o.systemAppend = "RULES"
        let fresh = EngineCommand.invocation(for: Bot(id: "b", name: "B", engine: .codex), prompt: "hi", botDirectory: dir, sessionId: nil, options: o)
        XCTAssertTrue(fresh.arguments.contains("sandbox_workspace_write.writable_roots=[\"/g/workspace\"]"))
        XCTAssertEqual(fresh.stdin, "<launchpad-rules>\nRULES\n</launchpad-rules>\n\nhi")
        let resumed = EngineCommand.invocation(for: Bot(id: "b", name: "B", engine: .codex), prompt: "hi", botDirectory: dir, sessionId: "t", options: o)
        XCTAssertEqual(resumed.stdin, "hi", "rules only go with the first message")
    }

    func testOneShotKeepsNoSession() {
        let c = EngineCommand.oneShot(engine: .claude, model: nil, prompt: "x", directory: dir)
        XCTAssertTrue(c.arguments.contains("--no-session-persistence"))
        let x = EngineCommand.oneShot(engine: .codex, model: nil, prompt: "x", directory: dir)
        XCTAssertTrue(x.arguments.contains("--ephemeral"))
        XCTAssertTrue(x.arguments.contains("sandbox_mode=\"read-only\""))
    }
}

final class UsageAndRoutineTests: XCTestCase {
    func testClaudeRateLimitEvent() {
        let p = ClaudeStreamParser()
        let line = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":0.15,"resetsAt":1794924000,"status":"allowed"},"seven_day":{"utilization":0.03,"resetsAt":1795510800}}}}"#
        XCTAssertEqual(p.parse(line: line), [.usage(UsageReport(engine: .claude, windows: [
            UsageWindow(name: "five_hour", utilization: 0.15, resetsAt: Date(timeIntervalSince1970: 1794924000)),
            UsageWindow(name: "seven_day", utilization: 0.03, resetsAt: Date(timeIntervalSince1970: 1795510800)),
        ]))])
    }

    func testUsageStoreTotals() {
        let paths = LaunchpadPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("lp-u-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = UsageStore(paths: paths)
        let day1 = Date(timeIntervalSince1970: 1_800_000_000)
        store.record(UsageReport(engine: .codex, tokens: 100), now: day1)
        store.record(UsageReport(engine: .codex, tokens: 50), now: day1)
        XCTAssertEqual(store.load().codexTokensToday, 150)
        store.record(UsageReport(engine: .codex, tokens: 7), now: day1.addingTimeInterval(86_400))
        XCTAssertEqual(store.load().codexTokensToday, 7, "resets each day")
        store.record(UsageReport(engine: .claude, windows: [UsageWindow(name: "five_hour", utilization: 0.2, resetsAt: nil)]), now: day1)
        store.record(UsageReport(engine: .claude, windows: [UsageWindow(name: "seven_day", utilization: 0.1, resetsAt: nil)]), now: day1)
        XCTAssertEqual(store.load().claudeWindows.map(\.name), ["five_hour", "seven_day"])
    }

    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func date(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        return f.date(from: s)!
    }

    func testEveryNMinutes() {
        let r = Routine(id: "r", name: "r", target: .bot("a"), message: "hi", trigger: .every(minutes: 60),
                        lastRun: date("2026-11-17T10:00:00Z"))
        XCTAssertFalse(RoutineSchedule.isDue(r, now: date("2026-11-17T10:59:00Z"), calendar: calendar))
        XCTAssertTrue(RoutineSchedule.isDue(r, now: date("2026-11-17T11:00:00Z"), calendar: calendar))
        var off = r
        off.enabled = false
        XCTAssertFalse(RoutineSchedule.isDue(off, now: date("2026-11-18T11:00:00Z"), calendar: calendar))
    }

    func testDailyAndWeekdays() {
        // 2026-11-17 is a Tuesday; 2026-11-21 a Saturday.
        let r = Routine(id: "r", name: "r", target: .group("g"), message: "standup", trigger: .daily(hour: 9, minute: 30, weekdaysOnly: true),
                        lastRun: date("2026-11-16T09:30:00Z"))
        XCTAssertFalse(RoutineSchedule.isDue(r, now: date("2026-11-17T09:29:00Z"), calendar: calendar))
        XCTAssertTrue(RoutineSchedule.isDue(r, now: date("2026-11-17T09:30:00Z"), calendar: calendar))
        XCTAssertTrue(RoutineSchedule.isDue(r, now: date("2026-11-17T15:00:00Z"), calendar: calendar), "catches up later the same day")
        var ran = r
        ran.lastRun = date("2026-11-17T09:30:05Z")
        XCTAssertFalse(RoutineSchedule.isDue(ran, now: date("2026-11-17T15:00:00Z"), calendar: calendar))
        var weekend = r
        weekend.lastRun = date("2026-11-20T09:30:00Z")
        XCTAssertFalse(RoutineSchedule.isDue(weekend, now: date("2026-11-21T10:00:00Z"), calendar: calendar))
        XCTAssertFalse(RoutineSchedule.isDue(weekend, now: date("2026-11-23T09:00:00Z"), calendar: calendar))
        XCTAssertTrue(RoutineSchedule.isDue(weekend, now: date("2026-11-23T09:31:00Z"), calendar: calendar))
    }

    func testNewFileWatch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lp-nf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "x".write(to: dir.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        let w = NewFileWatch()
        XCTAssertEqual(w.newFiles(in: dir.path), [], "existing files don't count")
        try "y".write(to: dir.appendingPathComponent("new.pdf"), atomically: true, encoding: .utf8)
        XCTAssertEqual(w.newFiles(in: dir.path), [dir.appendingPathComponent("new.pdf").path])
        XCTAssertEqual(w.newFiles(in: dir.path), [])
    }

    func testRoutineCodableRoundTrip() throws {
        let r = Routine(id: "r", name: "Inbox", target: .group("g"), message: "Process it", trigger: .newFile(folder: "/x"),
                        createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let data = try JSONCoding.encoder().encode([r])
        XCTAssertEqual(try JSONCoding.decoder().decode([Routine].self, from: data), [r])
    }
}

final class HireTests: XCTestCase {
    func testDevTeamPreset() throws {
        let paths = LaunchpadPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("lp-h-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let (bots, group) = try Hiring(paths: paths).hireDevTeam()
        XCTAssertEqual(bots.map(\.id), ["lead", "planner", "designer", "frontend", "backend", "tester", "reviewer", "shipper"])
        XCTAssertEqual(group.id, "build-and-ship")
        XCTAssertEqual(group.displayName, "#build-and-ship")
        XCTAssertEqual(group.lead, "lead")
        XCTAssertEqual(group.members.count, 8)
        XCTAssertEqual(bots.first { $0.id == "reviewer" }?.engine, .codex)
        XCTAssertEqual(bots.first { $0.id == "shipper" }?.skills, ["deploy"])
        XCTAssertEqual(group.skills, ["graphify"])
        XCTAssertTrue(BotStore(paths: paths).instructions(for: "backend").contains("Row Level Security is always on"))

        // Running it again reuses everything.
        let again = try Hiring(paths: paths).hireDevTeam()
        XCTAssertEqual(again.bots.map(\.id), bots.map(\.id))
        XCTAssertEqual(BotStore(paths: paths).loadAll().count, 8)
        XCTAssertEqual(GroupStore(paths: paths).loadAll().count, 1)
    }
}

final class GraphifyTests: XCTestCase {
    func testImportCopiesOnlyTheSkill() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lp-gf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = LaunchpadPaths(root: root.appendingPathComponent("Launchpad"))
        // A fake `graphify` that writes what the real `install --project` does.
        let fake = root.appendingPathComponent("graphify")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        #!/bin/sh
        [ "$1" = "install" ] || exit 3
        mkdir -p .claude/skills/graphify/references
        printf -- '---\\nname: graphify\\ndescription: Use for codebase questions.\\n---\\n# /graphify\\n' > .claude/skills/graphify/SKILL.md
        echo ref > .claude/skills/graphify/references/query.md
        echo '{"hooks":{}}' > .claude/settings.json
        echo '## graphify' > CLAUDE.md
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        try Graphify.importSkill(executable: fake, paths: paths, environment: ProcessInfo.processInfo.environment)
        let skill = try XCTUnwrap(SkillStore(paths: paths).load(id: "graphify"))
        XCTAssertEqual(skill.description, "Use for codebase questions.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.skills.appendingPathComponent("graphify/references/query.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("CLAUDE.md").path))

        // Importing again refreshes it.
        try Graphify.importSkill(executable: fake, paths: paths, environment: ProcessInfo.processInfo.environment)
        XCTAssertNotNil(SkillStore(paths: paths).load(id: "graphify"))
    }

    func testFailedInstallIsExplained() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lp-gf2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = root.appendingPathComponent("graphify")
        try "#!/bin/sh\necho 'Python 3.11 required' >&2\nexit 1\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        XCTAssertThrowsError(try Graphify.importSkill(executable: fake, paths: LaunchpadPaths(root: root.appendingPathComponent("L")), environment: [:])) { error in
            XCTAssertTrue(error.localizedDescription.contains("Python 3.11 required"))
        }
    }
}
