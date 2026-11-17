import XCTest
@testable import LaunchpadCore

final class CatalogTests: XCTestCase {
    var paths: LaunchpadPaths!

    override func setUpWithError() throws {
        paths = LaunchpadPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("lp-cat-\(UUID().uuidString)"))
        try paths.ensureStructure()
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: paths.root) }

    private func assertUnique(_ ids: [String], _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let dupes = Dictionary(grouping: ids, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        XCTAssertEqual(dupes, [], "duplicate \(what) ids", file: file, line: line)
    }

    // MARK: Shape

    func testCountsAndUniqueIds() {
        XCTAssertEqual(HireCatalog.devTeam.map(\.id), ["lead", "planner", "designer", "frontend", "backend", "tester", "reviewer", "shipper"])
        XCTAssertEqual(HireCatalog.all.map(\.id), HireCatalog.devTeam.map(\.id), "the Hire page's list is unchanged")
        XCTAssertEqual(HireCatalog.catalogRoles.count, 27)
        XCTAssertEqual(HireCatalog.roles.count, 35)
        XCTAssertEqual(SkillCatalog.all.count, 41)
        XCTAssertEqual(SkillCatalog.starters.map(\.id), StarterSkills.all.map(\.id))
        XCTAssertEqual(ConnectorCatalog.all.count, 40)
        XCTAssertEqual(TeamPacks.all.count, 5)
        assertUnique(HireCatalog.roles.map(\.id), "role")
        assertUnique(HireCatalog.roles.map(\.name), "role name")
        assertUnique(SkillCatalog.all.map(\.id), "skill")
        assertUnique(ConnectorCatalog.all.map(\.id), "app")
        assertUnique(TeamPacks.all.map(\.id), "team")
        assertUnique(TeamPacks.all.map(\.groupId), "team group")
    }

    func testRolesAreWellFormed() {
        for t in HireCatalog.roles {
            XCTAssertEqual(Slug.make(t.name), t.id, "hiring makes the bot id from the name, so they must match: \(t.name)")
            XCTAssertTrue(BotPalette.colours.contains(t.colour), "\(t.id) colour")
            XCTAssertTrue(HireCatalog.categories.contains(t.category), "\(t.id) category \(t.category)")
            XCTAssertFalse(t.emoji.isEmpty)
            for s in t.skills { XCTAssertNotNil(SkillCatalog.skill(s), "\(t.id) uses unknown skill \(s)") }
            for a in t.suggestedApps { XCTAssertNotNil(ConnectorCatalog.preset(a), "\(t.id) uses unknown app \(a)") }
            let text = t.instructionsText
            XCTAssertTrue(text.contains("notes.md"), "\(t.id) memory")
            XCTAssertTrue(text.contains("[[approve:"), "\(t.id) approvals")
            XCTAssertTrue(text.contains("Never put passwords"), "\(t.id) secrets")
            XCTAssertTrue(text.contains("## Your job"), "\(t.id) job")
        }
        // Every department has at least one role.
        for c in HireCatalog.categories { XCTAssertTrue(HireCatalog.roles.contains { $0.category == c }, c) }
    }

    func testTeamPacksReferenceExistingRoles() {
        for pack in TeamPacks.all {
            XCTAssertNotNil(HireCatalog.template(pack.lead), "\(pack.id) lead")
            for m in pack.everyone { XCTAssertNotNil(HireCatalog.template(m), "\(pack.id) member \(m)") }
            XCTAssertEqual(pack.templates.count, pack.everyone.count)
            XCTAssertEqual(Slug.make(pack.groupId), pack.groupId)
            XCTAssertFalse(pack.rules.isEmpty)
        }
        XCTAssertEqual(TeamPacks.dev.everyone, HireCatalog.devTeam.map(\.id))
    }

    func testPresetsAreWellFormed() throws {
        for p in ConnectorCatalog.all {
            XCTAssertTrue(ConnectorCatalog.categories.contains(p.category), p.id)
            XCTAssertTrue(p.docsURL.hasPrefix("https://"), p.id)
            switch p.kind {
            case .http:
                XCTAssertNotNil(URL(string: p.url ?? ""), p.id)
                XCTAssertNil(p.command, p.id)
                XCTAssertTrue(p.secrets.isEmpty, "\(p.id): http servers get a token, not env vars")
            case .stdio:
                XCTAssertNil(p.url, p.id)
                XCTAssertTrue(["npx", "uvx", "sh"].contains(p.command ?? ""), p.id)
                XCTAssertNil(p.token, p.id)
            }
            // No secret ever goes into args.
            for s in p.secrets { XCTAssertFalse(p.args.joined().contains("${\(s.key)}"), p.id) }
            // Every setting placeholder is used, and nothing else is a placeholder.
            for f in p.settings { XCTAssertTrue(p.args.contains { $0.contains("${\(f.key)}") }, p.id) }
            let placeholders = p.args.filter { $0.contains("${") }
            XCTAssertEqual(placeholders.count, p.settings.count, p.id)
        }
        XCTAssertNil(ConnectorCatalog.preset("biscuit-illustrator"))
    }

    func testLogoFilesExist() throws {
        let logos = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Launchpad/Resources/Logos")
        let files = Set(try FileManager.default.contentsOfDirectory(atPath: logos.path))
        for logo in ConnectorCatalog.logoFiles { XCTAssertTrue(files.contains(logo), "missing logo \(logo)") }
        XCTAssertTrue(files.contains("README.md"))
        for f in files where f != "README.md" {
            XCTAssertTrue(f.hasSuffix(".svg") || f.hasSuffix(".png"), "only images: \(f)")
        }
    }

    // MARK: Wording

    func testNoOldBrandOrDogWording() {
        var texts: [(String, String)] = []
        for t in HireCatalog.roles {
            texts += [(t.id, t.name), (t.id, t.role), (t.id, t.blurb), (t.id, t.instructionsText), (t.id, t.emoji)]
        }
        for p in TeamPacks.all { texts += [(p.id, p.name), (p.id, p.tagline), (p.id, p.rules), (p.id, p.groupId), (p.id, p.emoji)] }
        for s in SkillCatalog.all { texts += [(s.id, s.name), (s.id, s.blurb), (s.id, s.fileText)] }
        for a in ConnectorCatalog.all {
            texts += [(a.id, a.name), (a.id, a.blurb), (a.id, a.category), (a.id, a.docsURL), (a.id, a.args.joined(separator: " "))]
            texts += a.secrets.map { (a.id, $0.label + $0.help) } + a.settings.map { (a.id, $0.label + $0.help) }
        }
        let banned = ["biscuit", "bark", "woof", "wag", "dog", "pup", "paw", "hound", "sniff", "kibble", "treat"]
        let bannedEmoji = ["🐶", "🐕", "🦮", "🐩", "🐾", "🦴"]
        for (id, text) in texts {
            let lower = text.lowercased()
            for word in banned { XCTAssertFalse(lower.contains(word), "\(id) contains \"\(word)\"") }
            for e in bannedEmoji { XCTAssertFalse(text.contains(e), "\(id) contains \(e)") }
        }
    }

    // MARK: Installing

    func testInstallingASkillWritesAParseableSkillFile() throws {
        let store = SkillStore(paths: paths)
        for skill in SkillCatalog.all {
            let installed = try store.install(skill)
            XCTAssertEqual(installed.id, skill.id)
            let parsed = SkillFile.parse(try String(contentsOf: store.file(skill.id), encoding: .utf8))
            XCTAssertEqual(parsed.name, skill.id)
            XCTAssertEqual(parsed.description, skill.description)
            XCTAssertTrue(parsed.body.hasPrefix("# "), skill.id)
            XCTAssertFalse(parsed.body.isEmpty)
        }
        XCTAssertEqual(store.loadAll().count, SkillCatalog.all.count)

        // installIfMissing keeps your edits and ignores ids it doesn't know.
        try store.save(id: "tdd", text: SkillFile.compose(name: "tdd", description: "mine", body: "x"))
        try store.installIfMissing("tdd")
        XCTAssertEqual(store.load(id: "tdd")?.description, "mine")
        try store.installIfMissing("not-a-catalog-skill")
        XCTAssertNil(store.load(id: "not-a-catalog-skill"))
    }

    func testStarterCatalogEntriesMatchSeededText() throws {
        let store = SkillStore(paths: paths)
        store.seedStarterSkillsIfNeeded()
        for s in SkillCatalog.starters {
            XCTAssertTrue(s.isStarter)
            XCTAssertEqual(store.load(id: s.id)?.text, s.fileText, s.id)
        }
    }

    func testInstallingAppsCreatesValidConnectors() throws {
        let store = ConnectorStore(paths: paths)
        let settings = ["DB_PATH": "/tmp/x.db", "FOLDER": "/tmp/shared"]
        for p in ConnectorCatalog.all {
            let c = try store.install(p, settings: settings)
            XCTAssertEqual(c.id, p.id)
            XCTAssertEqual(c.kind, p.kind)
            XCTAssertEqual(c.secretEnv, p.secrets.map(\.key))
            XCTAssertEqual(c.usesToken, p.token != nil)
            XCTAssertFalse(c.args.contains { $0.contains("${") }, "\(p.id) has unfilled placeholders")
            if c.kind == .http { XCTAssertNotNil(c.url) } else { XCTAssertNotNil(c.command) }
            XCTAssertNotNil(store.installed(p))
        }
        // Round-trips through connectors.json and builds valid engine config.
        let all = store.loadAll()
        XCTAssertEqual(all.map(\.id), ConnectorCatalog.all.map(\.id))
        let json = MCPConfig.claudeJSON(all)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual((obj["mcpServers"] as? [String: Any])?.count, all.count)
        XCTAssertFalse(MCPConfig.codexArgs(all).isEmpty)
        XCTAssertEqual(store.loadAll().first { $0.id == "sqlite" }?.args, ["mcp-server-sqlite", "--db-path", "/tmp/x.db"])

        // Installing again doesn't duplicate.
        try store.install(ConnectorCatalog.preset("slack")!)
        XCTAssertEqual(store.loadAll().count, ConnectorCatalog.all.count)

        // A missing setting is explained.
        XCTAssertThrowsError(try store.install(ConnectorCatalog.preset("filesystem")!)) { error in
            XCTAssertEqual(error as? ConnectorCatalog.InstallError, .missingSetting("Folder"))
        }
    }

    func testAppSecretsGoToTheSecretStoreOnly() throws {
        let store = ConnectorStore(paths: paths)
        let secrets = MemorySecretStore()
        let pg = ConnectorCatalog.preset("postgres")!
        let c = try store.install(pg)
        try ConnectorStore.storeSecrets(["DATABASE_URL": "postgresql://u:hunter2@h/db"], for: pg, connector: c, in: secrets)
        let gh = ConnectorCatalog.preset("github")!
        let ghc = try store.install(gh)
        try ConnectorStore.storeSecrets(["GITHUB_PERSONAL_ACCESS_TOKEN": "ghp_secret"], for: gh, connector: ghc, in: secrets)

        let onDisk = try String(contentsOf: paths.connectorsFile, encoding: .utf8)
        XCTAssertFalse(onDisk.contains("hunter2"))
        XCTAssertFalse(onDisk.contains("ghp_secret"))
        XCTAssertEqual(secrets.secret(c.envAccount("DATABASE_URL")), "postgresql://u:hunter2@h/db")
        XCTAssertEqual(secrets.secret(ghc.tokenAccount), "ghp_secret")
        let env = MCPConfig.environment([c, ghc], secrets: secrets, engine: .codex)
        XCTAssertEqual(env["DATABASE_URL"], "postgresql://u:hunter2@h/db")
        XCTAssertFalse(MCPConfig.claudeJSON([c, ghc]).contains("hunter2"))
    }

    // MARK: Hiring

    func testHiringARoleInstallsItsSkillsAndUsesInstalledApps() throws {
        try ConnectorStore(paths: paths).install(ConnectorCatalog.preset("notion")!)
        let bot = try Hiring(paths: paths).hire(HireCatalog.template("chief-of-staff")!)
        XCTAssertEqual(bot.id, "chief-of-staff")
        XCTAssertEqual(bot.connectors, ["notion"], "only suggested apps that are installed")
        let skills = SkillStore(paths: paths)
        for s in bot.skills { XCTAssertNotNil(skills.load(id: s), s) }
        XCTAssertTrue(BotStore(paths: paths).instructions(for: bot.id).contains("Chief of Staff"))
    }

    func testHiringEveryTeamPackIsIdempotent() throws {
        let hiring = Hiring(paths: paths)
        for pack in TeamPacks.all {
            let (bots, group) = try hiring.hireTeam(pack)
            XCTAssertEqual(bots.map(\.id), pack.everyone, pack.id)
            XCTAssertEqual(group.id, pack.groupId)
            XCTAssertEqual(group.lead, pack.lead)
            XCTAssertEqual(Set(group.everyone), Set(pack.everyone))
            XCTAssertEqual(group.rules, pack.rules)
            XCTAssertEqual(group.skills, pack.groupSkills)
        }
        let botCount = BotStore(paths: paths).loadAll().count
        let unique = Set(TeamPacks.all.flatMap(\.everyone))
        XCTAssertEqual(botCount, unique.count, "teams share bots instead of duplicating them")
        XCTAssertEqual(GroupStore(paths: paths).loadAll().count, TeamPacks.all.count)

        // Again: nothing new.
        for pack in TeamPacks.all {
            let (bots, _) = try hiring.hireTeam(pack)
            XCTAssertEqual(bots.map(\.id), pack.everyone)
        }
        XCTAssertEqual(BotStore(paths: paths).loadAll().count, botCount)
        XCTAssertEqual(GroupStore(paths: paths).loadAll().count, TeamPacks.all.count)

        // A deleted member is re-hired and put back in the group.
        try BotStore(paths: paths).delete(id: "bookkeeper")
        var g = try GroupStore(paths: paths).load(id: "back-office")
        g.members.removeAll { $0 == "bookkeeper" }
        try GroupStore(paths: paths).save(g)
        let (_, group) = try hiring.hireTeam(TeamPacks.backOffice)
        XCTAssertTrue(group.members.contains("bookkeeper"))
        XCTAssertEqual(BotStore(paths: paths).loadAll().count, botCount)
    }
}
