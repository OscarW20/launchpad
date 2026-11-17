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

    public var bot: Bot {
        Bot(id: id, name: name, emoji: emoji, colour: colour, role: role, engine: engine, permission: permission, skills: skills)
    }

    /// Full CLAUDE.md / AGENTS.md text for this template.
    public var instructionsText: String {
        """
        # \(emoji) \(name)

        You are **\(name)**, \(role.prefix(1).lowercased() + role.dropFirst()), on my AI dev team in Launchpad.

        ## How you work
        - Group projects live in the group's shared project folder (you'll be told the path). Solo work goes in `./workspace/`.
        - `./notes.md` is your memory. Read it at the start of a task and add short notes about decisions and my preferences.
        - Reply like a friendly colleague: what you did, what's next, anything you need from me. Short.
        - Never put passwords, API keys or tokens in files, logs or chat. Use `.env.local` (git-ignored) with values I add myself, and `.env.example` with names only.
        - Before deploying, pushing, sending, spending or deleting anything: ask with `[[approve: …]]` and wait.

        \(instructions)
        """
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
        """
    )

    public static let planner = HireTemplate(
        id: "planner", name: "Planner", emoji: "📐", colour: "#F2A65A", role: "Product planner who writes specs",
        engine: .claude, permission: .editWorkspace, skills: ["write-spec", "new-project"],
        blurb: "Writes a one-page spec: must-haves, flows, data, and what 'done' means.",
        instructions: """
        ## Your job
        Turn requests into a clear, short SPEC.md in the project folder using the write-spec skill.
        Keep the first version small. List open questions instead of guessing about important things.
        """
    )

    public static let designer = HireTemplate(
        id: "designer", name: "Designer", emoji: "🎨", colour: "#E07A9B", role: "Product designer for web apps",
        engine: .claude, permission: .editWorkspace, skills: [],
        blurb: "Designs the screens, flows and visual style, and writes them down for Frontend.",
        instructions: """
        ## Your job
        Design the screens and flows. Write DESIGN.md in the project folder: pages, layout of each, components,
        states (empty, loading, error), colours, type and spacing as Tailwind tokens. Friendly, accessible, mobile-first.
        Hand Frontend something they can build without guessing.
        """
    )

    public static let frontend = HireTemplate(
        id: "frontend", name: "Frontend", emoji: "🖥️", colour: "#6C9BD2", role: "Frontend engineer (Next.js, React, Tailwind)",
        engine: .claude, permission: .fullAccess, skills: ["new-project"],
        blurb: "Builds the UI in Next.js and Tailwind, wired to the backend.",
        instructions: """
        ## Your job
        Build the UI in the shared project folder: Next.js (App Router, TypeScript) and Tailwind, following DESIGN.md.
        Use the Supabase client set up by Backend. Run `npm run build` and fix errors before saying you're done.
        Accessible markup, responsive layouts, loading and error states.
        """
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
        """
    )

    public static let tester = HireTemplate(
        id: "tester", name: "Tester", emoji: "🧪", colour: "#8DB580", role: "QA engineer (Playwright)",
        engine: .claude, permission: .fullAccess, skills: [],
        blurb: "Writes and runs Playwright tests for the main flows and reports what broke.",
        instructions: """
        ## Your job
        Write Playwright end-to-end tests in `tests/` for the main user flows in SPEC.md, run them
        (`npx playwright test`), and report clearly: what passed, what failed, with steps to reproduce.
        Hand failures to the right teammate by @mention. Don't change app code yourself unless asked.
        """
    )

    public static let reviewer = HireTemplate(
        id: "reviewer", name: "Reviewer", emoji: "🔍", colour: "#A38CD9", role: "Code reviewer giving a second opinion",
        engine: .codex, permission: .readOnly, skills: ["code-review"],
        blurb: "Runs on Codex for a genuine second opinion: bugs, security, RLS gaps.",
        instructions: """
        ## Your job
        Give a second-opinion review using the code-review skill. You're read-only: point out problems and
        suggest fixes, don't edit. Pay special attention to auth, RLS policies, secrets and data loss.
        Start with a one-line verdict.
        """
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
        """
    )

    public static let all: [HireTemplate] = [lead, planner, designer, frontend, backend, tester, reviewer, shipper]

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
    let bots: BotStore
    let groups: GroupStore

    public init(paths: LaunchpadPaths) {
        bots = BotStore(paths: paths)
        groups = GroupStore(paths: paths)
    }

    /// Creates a bot from a template. If one with that id exists, a numbered copy is made.
    @discardableResult
    public func hire(_ t: HireTemplate) throws -> Bot {
        var bot = try bots.create(name: t.name, emoji: t.emoji, colour: t.colour, role: t.role, engine: t.engine,
                                  permission: t.permission, instructions: t.instructionsText)
        bot.skills = t.skills
        try bots.save(bot)
        return bot
    }

    /// All eight bots plus #build-and-ship with Lead as lead. Reuses bots you already hired from these templates.
    @discardableResult
    public func hireDevTeam() throws -> (bots: [Bot], group: BotGroup) {
        let existing = bots.loadAll()
        var team: [Bot] = []
        for t in HireCatalog.all {
            if let found = existing.first(where: { $0.id == t.id }) {
                team.append(found)
            } else {
                team.append(try hire(t))
            }
        }
        let lead = team.first { $0.id == HireCatalog.lead.id }?.id ?? team.first?.id
        if let existingGroup = groups.loadAll().first(where: { $0.id == HireCatalog.devTeamGroupName }) {
            return (team, existingGroup)
        }
        var group = try groups.create(name: HireCatalog.devTeamGroupName, emoji: "🛠️", members: team.map(\.id), lead: lead,
                                      rules: HireCatalog.devTeamRules, handoffLimit: 3, id: HireCatalog.devTeamGroupName)
        // The whole team gets Graphify; it switches on once the skill is in the library.
        group.skills = [Graphify.skillId]
        try groups.save(group)
        return (team, group)
    }
}
