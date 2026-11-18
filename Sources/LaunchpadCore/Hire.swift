import Foundation

/// Ready-made bots you can add in one click.
public struct HireTemplate: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var emoji: String
    public var colour: String
    public var role: String
    public var engine: BotEngine
    public var permission: PermissionLevel
    public var skills: [String]
    public var blurb: String
    public var instructions: String
    /// Department, for grouping in the marketplace (see `HireCatalog.categories`).
    public var category: String = "Engineering"
    /// Connector preset ids (`ConnectorCatalog`) this role works well with. Hiring turns on the
    /// ones you've already installed; it never installs or signs in to anything by itself.
    public var suggestedApps: [String] = []

    public var bot: Bot {
        Bot(id: id, name: name, emoji: emoji, colour: colour, role: role, engine: engine, permission: permission, skills: skills)
    }

    /// Full CLAUDE.md / AGENTS.md text for this template.
    public var instructionsText: String {
        """
        # \(emoji) \(name)

        You are **\(name)**, \(role.prefix(1).lowercased() + role.dropFirst()), on my AI team in Launchpad.

        ## How you work
        - Group projects live in the group's shared project folder (you'll be told the path). Solo work goes in `./workspace/`.
        - `./MEMORY.md` is your memory. Read it at the start of a task. Add short facts (decisions, my preferences) as `- ` lines under its topic headings; Launchpad also files facts from our chats there.
        - Reply like a friendly colleague: what you did, what's next, anything you need from me. Short.
        - Never put passwords, API keys or tokens in files, logs or chat. Use `.env.local` (git-ignored) with values I add myself, and `.env.example` with names only.
        - Before deploying, pushing, sending, posting, publishing, paying, signing up or deleting anything: ask with `[[approve: …]]` and wait.
        - Confirm the goal when it's unclear, show your work, and say what you couldn't do.
        \(appsSection)
        \(instructions)
        """
    }

    private var appsSection: String {
        let names = suggestedApps.compactMap { ConnectorCatalog.preset($0)?.name }
        guard !names.isEmpty else { return "" }
        return "- Connectors that help with this job, if I've turned them on for you: \(names.joined(separator: ", ")). " +
            "If a task needs one you don't have, tell me which.\n"
    }
}

public enum HireCatalog {
    public static let lead = HireTemplate(
        id: "lead", name: "Lead", emoji: "🧭", colour: "#E8735A", role: "Team lead who plans and coordinates",
        engine: .claude, permission: .editWorkspace, skills: ["write-spec"],
        blurb: "Turns your request into a plan, hands work to the team, keeps the summary, and reports back.",
        instructions: """
        ## Your job
        You lead the team. You don't build things yourself; you plan, delegate, check and report.

        1. For a new project, write a short plan: goal, stack, steps, who does what. Ask me to approve it with
           `[[approve: start building <project> with this plan]]` and end your turn.
        2. Once approved, hand out work by @mention, one clear task per line. Usual order:
           @planner (spec) → @designer (screens) → @backend (data, auth) → @frontend (UI) → @tester (tests)
           → @reviewer (second opinion) → @shipper (deploy).
           Use `[parallel]` only when tasks don't depend on each other.
        3. After each round, check the replies. Fix gaps by handing out the next tasks.
        4. Keep the group summary file current: decisions, owners, open issues.
        5. When it's done, reply without @mentions: what was built, the live URL, and anything I need to do.
        """,
        category: "Engineering", suggestedApps: ["linear", "github"]
    )

    public static let planner = HireTemplate(
        id: "planner", name: "Planner", emoji: "📐", colour: "#F2A65A", role: "Product planner who writes specs",
        engine: .claude, permission: .editWorkspace, skills: ["write-spec", "new-project", "user-stories"],
        blurb: "Writes a one-page spec: must-haves, flows, data, and what 'done' means.",
        instructions: """
        ## Your job
        Turn requests into a clear, short SPEC.md in the project folder using the write-spec skill.
        Keep the first version small. List open questions instead of guessing about important things.
        Outside a build, act as product manager: user stories with acceptance criteria, priorities,
        success metrics and a simple roadmap.
        """,
        category: "Product", suggestedApps: ["linear", "notion"]
    )

    public static let designer = HireTemplate(
        id: "designer", name: "Designer", emoji: "🎨", colour: "#E07A9B", role: "Product designer for web apps",
        engine: .claude, permission: .editWorkspace, skills: ["ux-critique", "accessibility"],
        blurb: "Designs the screens, flows and visual style, and writes them down for Frontend.",
        instructions: """
        ## Your job
        Design the screens and flows. Write DESIGN.md in the project folder: pages, layout of each, components,
        states (empty, loading, error), colours, type and spacing as Tailwind tokens. Friendly, accessible, mobile-first.
        Hand Frontend something they can build without guessing.
        When asked to review a design, give ranked, concrete fixes (ux-critique skill). With Figma connected,
        read the frames directly.
        """,
        category: "Design", suggestedApps: ["figma-desktop", "figma"]
    )

    public static let frontend = HireTemplate(
        id: "frontend", name: "Frontend", emoji: "🖥️", colour: "#6C9BD2", role: "Frontend engineer (Next.js, React, Tailwind)",
        engine: .claude, permission: .fullAccess, skills: ["new-project", "web-frontend"],
        blurb: "Builds the UI in Next.js and Tailwind, wired to the backend. Also landing pages and prototypes.",
        instructions: """
        ## Your job
        Build the UI in the shared project folder: Next.js (App Router, TypeScript) and Tailwind, following DESIGN.md.
        Use the Supabase client set up by Backend. Run `npm run build` and fix errors before saying you're done.
        Accessible markup, responsive layouts, loading and error states.
        For landing pages and clickable prototypes, keep it fast and simple, and check it in a real browser.
        """,
        category: "Engineering", suggestedApps: ["playwright", "vercel", "context7"]
    )

    public static let backend = HireTemplate(
        id: "backend", name: "Backend", emoji: "🗄️", colour: "#4FA3A5", role: "Backend engineer (Supabase, RLS always on)",
        engine: .claude, permission: .fullAccess, skills: [],
        blurb: "Sets up Supabase: tables, auth, and Row Level Security on every table.",
        instructions: """
        ## Your job
        Own data and auth with Supabase.
        - Write schema changes as SQL migrations in `supabase/migrations/`.
        - **Row Level Security is always on.** Every table gets `alter table … enable row level security;` and
          policies so users only see and change their own rows. No table ships without RLS.
        - Auth: Supabase Auth (e.g. Google sign-in). Document the redirect URLs I need to set.
        - Never use the service role key in the browser. Keys go in env vars I add myself.
        - Pushing migrations to a live project needs approval.
        """,
        category: "Engineering", suggestedApps: ["supabase", "context7"]
    )

    public static let tester = HireTemplate(
        id: "tester", name: "Tester", emoji: "🧪", colour: "#8DB580", role: "QA engineer (Playwright)",
        engine: .claude, permission: .fullAccess, skills: ["bug-reports", "accessibility"],
        blurb: "Writes and runs Playwright tests for the main flows and reports what broke.",
        instructions: """
        ## Your job
        Write Playwright end-to-end tests in `tests/` for the main user flows in SPEC.md, run them
        (`npx playwright test`), and report clearly: what passed, what failed, with steps to reproduce.
        Check edge cases and accessibility too. File each bug with the bug-reports skill.
        Hand failures to the right teammate by @mention. Don't change app code yourself unless asked.
        """,
        category: "Engineering", suggestedApps: ["playwright", "linear"]
    )

    public static let reviewer = HireTemplate(
        id: "reviewer", name: "Reviewer", emoji: "🔍", colour: "#A38CD9", role: "Code reviewer giving a second opinion",
        engine: .codex, permission: .readOnly, skills: ["code-review", "git-hygiene"],
        blurb: "Runs on Codex for a genuine second opinion: bugs, security, RLS gaps.",
        instructions: """
        ## Your job
        Give a second-opinion review using the code-review skill. You're read-only: point out problems and
        suggest fixes, don't edit. Pay special attention to auth, RLS policies, secrets and data loss.
        Start with a one-line verdict.
        """,
        category: "Engineering", suggestedApps: ["github", "git"]
    )

    public static let shipper = HireTemplate(
        id: "shipper", name: "Shipper", emoji: "🚀", colour: "#E9C46A", role: "Release engineer (Vercel)",
        engine: .claude, permission: .fullAccess, skills: ["deploy"],
        blurb: "Deploys to Vercel with your approval and returns the live URL.",
        instructions: """
        ## Your job
        Ship to Vercel using the deploy skill. Always build first. Ask for approval before every deploy with
        `[[approve: deploy <app> to <preview/production>]]`. After deploying, check the live site works and
        reply with the URL and any setup I need to do (env vars, OAuth redirect URLs).
        Between releases, keep deploys healthy: watch errors and logs, write short release notes and runbooks,
        and propose fixes for flaky pipelines.
        """,
        category: "Engineering", suggestedApps: ["vercel", "sentry", "github"]
    )

    /// The eight dev-team templates (#build-and-ship). Kept as `all` because the Hire page uses it.
    public static let devTeam: [HireTemplate] = [lead, planner, designer, frontend, backend, tester, reviewer, shipper]
    public static var all: [HireTemplate] { devTeam }

    /// Every role in the marketplace: the dev team first, then the rest (CatalogRoles.swift).
    public static let roles: [HireTemplate] = devTeam + catalogRoles

    public static func template(_ id: String) -> HireTemplate? { roles.first { $0.id == id } }

    /// Departments in display order.
    public static let categories = ["Leadership", "Product", "Design", "Engineering", "Marketing", "Sales",
                                    "Customer", "Finance", "People", "Legal", "Research", "Admin"]

    public static let devTeamGroupName = "build-and-ship"
    public static let devTeamRules = """
    - The lead plans and gets my approval before the team builds anything new.
    - One task per hand-off, with a clear "done means".
    - Work in the group's shared project folder. Commit with git as you go.
    - Supabase Row Level Security is always on.
    - Deploys, pushes and anything that costs money need my approval.
    - Keep replies short; put details in files.
    - If you have the graphify skill, build the project's knowledge graph once (`graphify-out/`) and query it \
    instead of grepping through files. Rebuild it after big changes.
    """
}

/// Adds templates to your Launchpad folder.
public struct Hiring {
    let paths: LaunchpadPaths
    let bots: BotStore
    let groups: GroupStore
    let skills: SkillStore
    let connectors: ConnectorStore

    public init(paths: LaunchpadPaths) {
        self.paths = paths
        bots = BotStore(paths: paths)
        groups = GroupStore(paths: paths)
        skills = SkillStore(paths: paths)
        connectors = ConnectorStore(paths: paths)
    }

    /// Creates a bot from a template. If one with that id exists, a numbered copy is made.
    /// Catalog skills the role uses are added to the skill library if missing, and suggested
    /// connectors you've already installed are turned on for the bot.
    @discardableResult
    public func hire(_ t: HireTemplate) throws -> Bot {
        var bot = try bots.create(name: t.name, emoji: t.emoji, colour: t.colour, role: t.role, engine: t.engine,
                                  permission: t.permission, instructions: t.instructionsText)
        bot.skills = t.skills
        for id in t.skills { try skills.installIfMissing(id) }
        let installed = Set(connectors.loadAll().map(\.id))
        bot.connectors = t.suggestedApps.filter { installed.contains($0) }
        try bots.save(bot)
        return bot
    }

    /// Hires a team pack: each role (reusing bots you already have with the same id), then the
    /// pack's group with its lead, rules and group skills. Running it again changes nothing,
    /// except re-hiring a bot you deleted and putting it back in the group.
    @discardableResult
    public func hireTeam(_ pack: TeamPack) throws -> (bots: [Bot], group: BotGroup) {
        let workspaces = WorkspaceStore(paths: paths)
        let layout = workspaces.load()
        // The pack's group may already exist, in any workspace, and its members may be copies of the pack's bots (a team
        // moved to another workspace gets its own). Only roles it has neither the bot nor a copy for are added, and
        // anything added goes in the group's own workspace, so a group never ends up with a role twice.
        if var group = groups.loadAll().first(where: { $0.id == pack.groupId }) {
            let home = layout.groups[group.id] ?? Workspace.generalId
            let have = Set(group.everyone.map { layout.rootBot($0) })
            var added = false
            for id in pack.everyone where !have.contains(id) {
                let bot: Bot
                if let found = bots.loadAll().first(where: { $0.id == id && (layout.bots[$0.id] ?? Workspace.generalId) == home }) {
                    bot = found
                } else {
                    guard let t = HireCatalog.template(id) else { throw BotStoreError.notFound(id) }
                    bot = try hire(t)
                    try workspaces.place(bot: bot.id, in: home, role: id)
                }
                if !group.members.contains(bot.id), group.lead != bot.id { group.members.append(bot.id); added = true }
            }
            if added { try groups.save(group) }
            return (group.everyone.compactMap { try? bots.load(id: $0) }, group)
        }

        // A new group: reuse bots you already have with the same id, but only ones that are in General (where a new group
        // starts), so it never reaches into another workspace.
        var existing = bots.loadAll().filter { (layout.bots[$0.id] ?? Workspace.generalId) == Workspace.generalId }
        var team: [Bot] = []
        for id in pack.everyone {
            if let found = existing.first(where: { $0.id == id }) {
                team.append(found)
            } else {
                guard let t = HireCatalog.template(id) else { throw BotStoreError.notFound(id) }
                let bot = try hire(t)
                try workspaces.noteRole(bot: bot.id, role: id)
                existing.append(bot)
                team.append(bot)
            }
        }
        let ids = team.map(\.id)
        // `team` follows `pack.everyone`, so the lead is the bot made (or reused) for the lead's role, whatever its id.
        let leadId = pack.everyone.firstIndex(of: pack.lead).flatMap { $0 < ids.count ? ids[$0] : nil } ?? ids.first
        var group = try groups.create(name: pack.groupId, emoji: pack.emoji, members: ids, lead: leadId,
                                      rules: pack.rules, handoffLimit: pack.handoffLimit, id: pack.groupId)
        if !pack.groupSkills.isEmpty {
            for id in pack.groupSkills { try skills.installIfMissing(id) }
            group.skills = pack.groupSkills
            try groups.save(group)
        }
        return (team, group)
    }

    /// All eight dev-team bots plus #build-and-ship with Lead as lead. Reuses bots you already hired from these templates.
    @discardableResult
    public func hireDevTeam() throws -> (bots: [Bot], group: BotGroup) {
        try hireTeam(TeamPacks.dev)
    }
}
