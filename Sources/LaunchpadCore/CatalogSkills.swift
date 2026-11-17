import Foundation

/// A skill you can add to the library from the marketplace. Installing writes
/// skills/<id>/SKILL.md through `SkillStore`.
public struct CatalogSkill: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// Short line for the marketplace card.
    public var blurb: String
    /// SKILL.md `description:`: says when to use it, which is what the engines read.
    public var description: String
    public var category: String
    /// SF Symbol for the card.
    public var symbol: String
    /// Markdown body, without front matter.
    public var body: String
    /// One of the four skills Launchpad seeds on first run.
    public var isStarter: Bool = false

    /// The SKILL.md this installs.
    public var fileText: String { SkillFile.compose(name: id, description: description, body: body) }
}

public enum SkillCatalog {
    public static let categories = ["Writing", "Research", "Marketing", "Sales", "Support", "Product", "Design",
                                    "Code", "Data", "Finance", "People", "Legal", "Operations", "Productivity"]

    private static func s(_ id: String, _ name: String, _ category: String, _ symbol: String,
                          blurb: String, use description: String, _ body: String) -> CatalogSkill {
        CatalogSkill(id: id, name: name, blurb: blurb, description: description, category: category, symbol: symbol,
                     body: "# \(name)\n\n\(body)")
    }

    /// The four starters, as catalog entries (same text as `StarterSkills`).
    public static let starters: [CatalogSkill] = StarterSkills.all.map { st in
        let meta: [String: (String, String, String, String)] = [
            "new-project": ("New project", "Code", "folder.badge.plus", "Start an app from scratch with a README and no secrets."),
            "deploy": ("Deploy to Vercel", "Code", "icloud.and.arrow.up", "Build, check env vars and deploy with your approval."),
            "code-review": ("Code review", "Code", "checkmark.seal", "Find bugs with location, trigger and fix."),
            "write-spec": ("Write a spec", "Product", "doc.text", "A one-page spec before anyone builds."),
        ]
        let m = meta[st.id] ?? (st.id, "Productivity", "doc", st.description)
        return CatalogSkill(id: st.id, name: m.0, blurb: m.3, description: st.description, category: m.1, symbol: m.2,
                            body: st.body, isStarter: true)
    }

    public static let extras: [CatalogSkill] = [
        // Writing
        s("plain-english", "Plain English", "Writing", "text.bubble",
          blurb: "Write short, clear sentences anyone can follow.",
          use: "Use when writing anything a non-expert will read: emails, docs, summaries, replies.", """
        - Lead with the answer. One idea per sentence; keep sentences under 20 words.
        - Use common words. Explain any term a newcomer wouldn't know, once.
        - Prefer verbs to nouns ("decide", not "make a decision"). Active voice.
        - Cut filler: "just", "really", "in order to", "it's important to note".
        - Use lists for steps and options; keep paragraphs to three sentences.
        """),
        s("brand-voice", "Brand voice", "Writing", "megaphone",
          blurb: "Match a brand's tone using its own examples.",
          use: "Use when writing copy that has to sound like a particular brand or person.", """
        1. Before writing, look for a voice guide or examples in the folder (VOICE.md, brand/, past copy). Quote 2–3 traits you'll follow.
        2. Draft, then check every line against those traits; rewrite lines that sound generic.
        3. Keep product names, capitalisation and legal wording exactly as the brand uses them.
        4. Offer two options when the tone could go either way, and say how they differ.
        """),
        s("email-drafts", "Email drafts", "Writing", "envelope",
          blurb: "Clear emails with a subject line, ask and next step.",
          use: "Use when drafting an email or reply.", """
        - Always give a subject line under 8 words.
        - First line says why you're writing; the ask is explicit and easy to find.
        - Keep to five short paragraphs or fewer; end with one concrete next step and date.
        - Never send. Hand the draft back; sending needs `[[approve: send email to …]]`.
        """),
        s("social-posts", "Social posts", "Writing", "bubble.left.and.bubble.right",
          blurb: "Platform-ready posts with hooks and variants.",
          use: "Use when writing posts for LinkedIn, X, Instagram, TikTok or similar.", """
        - Ask which platform if it isn't clear; respect its length and style (LinkedIn, X, Instagram, TikTok captions).
        - Open with a hook in the first 8 words. One idea per post.
        - Give three variants: safe, bold, playful. Add hashtags only where the platform rewards them.
        - Posting needs approval; hand drafts back.
        """),
        s("translate", "Translator", "Writing", "character.bubble",
          blurb: "Natural translations that keep tone and meaning.",
          use: "Use when translating or localising text into another language.", """
        Translate meaning, not words. Keep names, numbers and formatting. Flag idioms or legal terms that need a native reviewer.
        """),
        // Research
        s("research-sources", "Research with sources", "Research", "magnifyingglass.circle",
          blurb: "Answer with dated, linked sources and confidence.",
          use: "Use when answering a factual question that needs research or could have changed recently.", """
        - Search before answering anything factual that could have changed.
        - Every claim gets a source: title, publisher, date, link. Prefer primary sources.
        - Mark each claim Verified, Reported or Inference. Keep disagreements between sources visible.
        - End with "What I couldn't confirm".
        """),
        s("competitor-scan", "Competitor scan", "Research", "chart.bar.doc.horizontal",
          blurb: "Side-by-side comparison with sources and prices.",
          use: "Use when comparing competitors, products, tools or vendors.", """
        - Agree the criteria first (3–7). Build a table: options as columns, criteria as rows.
        - Each cell cites a source; prices carry the date checked; unknowns say "unknown".
        - Finish with a one-line recommendation and the trade-off it accepts.
        """),
        s("summarise", "Summarise anything", "Research", "text.quote",
          blurb: "TL;DR, key points and actions from long text.",
          use: "Use when summarising a long document, thread, transcript or report.", """
        Return three parts: **TL;DR** (one sentence), **Key points** (3–7 bullets), **Actions** (owner and date where known). Keep names and numbers exact. Quote, don't paraphrase, anything legal or contractual.
        """),
        // Code
        s("tdd", "Test first", "Code", "testtube.2",
          blurb: "Write a failing test, then the smallest fix.",
          use: "Use when fixing a bug or adding behaviour that can be tested.", """
        1. Reproduce the bug or behaviour with a failing test that calls the code the way users do.
        2. Make the smallest change that passes. Run the whole suite.
        3. Report the test name, before/after output and anything you couldn't test.
        """),
        s("git-hygiene", "Git hygiene", "Code", "arrow.triangle.branch",
          blurb: "Small commits, clear messages, safe branches.",
          use: "Use when committing, branching or preparing changes with git.", """
        - Never commit to main directly; branch first. Never force-push shared branches.
        - One logical change per commit; message = imperative summary (≤ 60 chars) + why.
        - Show `git status` and the diff summary before committing; never commit secrets or .env files.
        - Pushing needs `[[approve: push <branch>]]`.
        """),
        s("swiftui", "SwiftUI & Mac apps", "Code", "swift",
          blurb: "Native, modern SwiftUI patterns for macOS.",
          use: "Use when building or changing a SwiftUI or macOS app.", """
        - Target the latest stable macOS SwiftUI APIs; use @Observable, NavigationSplitView, .task, and SF Symbols.
        - Keep views small; move logic into models. Build with `swift build` and fix every warning.
        - Respect Mac conventions: menus, keyboard shortcuts, Settings scene, sandbox-friendly file access.
        """),
        s("web-frontend", "Front-end craft", "Code", "macwindow",
          blurb: "Accessible, responsive HTML/CSS/JS with taste.",
          use: "Use when building web pages, landing pages or UI components.", """
        - Semantic HTML first, CSS variables for tokens, no framework unless asked (or the project already has one).
        - Check mobile, dark mode, keyboard focus and contrast (WCAG AA) before saying done.
        - Open the page in a browser and look at it; fix layout issues you can see.
        """),
        s("bug-reports", "Bug reports", "Code", "ladybug",
          blurb: "Repro steps, expected vs actual, severity and evidence.",
          use: "Use when reporting a bug you found or were told about.", """
        - Title: what breaks, where. Then numbered steps to reproduce from a clean start.
        - Expected vs actual, environment (device, OS, browser, build) and a screenshot or log.
        - Severity: blocker, major, minor, cosmetic, with one line on user impact.
        - One bug per report. Check for duplicates first.
        """),
        s("release-notes", "Release notes", "Code", "shippingbox",
          blurb: "Changelogs users and the team can read in a minute.",
          use: "Use when writing release notes or a changelog.", """
        - Group changes as New, Improved, Fixed. Lead with the user benefit, not the ticket name.
        - Keep each line under 15 words; link the PR or issue.
        - Add a short "Heads-up" section for anything that changes behaviour or needs action.
        """),
        // Design
        s("ux-critique", "UX critique", "Design", "eye",
          blurb: "Ranked, concrete fixes for any screen.",
          use: "Use when reviewing a screen, mockup or page design.", """
        - Name the screen's one job. Check hierarchy, layout, type, colour/contrast, copy, states (empty, loading, error) and accessibility.
        - Return at most 7 fixes, ranked, each with the element, the problem and the change.
        """),
        s("accessibility", "Accessibility check", "Design", "figure.roll",
          blurb: "WCAG 2.2 AA review with fixes.",
          use: "Use when checking a design or page for accessibility.", """
        Check contrast (4.5:1 text, 3:1 large/UI), focus order, labels, target sizes (44pt), motion and alternatives for colour-only meaning. List each failure with the criterion and a fix.
        """),
        // Product
        s("prd", "Product spec", "Product", "doc.richtext",
          blurb: "One-page PRD: problem, scope, metrics, risks.",
          use: "Use when writing a product requirements document (PRD) for a feature.", """
        Sections: Problem · Who · Goals & non-goals · Scope (in/out) · User stories · Success metrics · Risks · Open questions. Keep it to one page; mark assumptions.
        """),
        s("user-stories", "User stories", "Product", "person.text.rectangle",
          blurb: "Stories with acceptance criteria devs can build.",
          use: "Use when breaking a feature into user stories or tickets.", """
        "As a … I want … so that …", each with Given/When/Then acceptance criteria and edge cases. Split anything bigger than a few days.
        """),
        s("user-interviews", "User interviews", "Product", "person.wave.2",
          blurb: "Plan interviews and turn notes into insights.",
          use: "Use when planning user interviews or making sense of interview notes.", """
        - Write a 30-minute guide: warm-up, past behaviour questions ("tell me about the last time…"), wrap-up. No leading questions.
        - After interviews, cluster quotes into themes; each insight needs at least two sources.
        - Report: top 3 insights, supporting quotes, how sure we are, and what to do next.
        """),
        // Productivity
        s("plan-first", "Plan before doing", "Productivity", "list.bullet.clipboard",
          blurb: "Short plan, then work in checked steps.",
          use: "Use for any task that will take more than a few minutes.", """
        For anything over a few minutes: write a 3–6 step plan, do one step at a time, check each result, and say what's done, what's left and what's blocked at the end.
        """),
        s("meeting-notes", "Meeting notes", "Productivity", "person.2.wave.2",
          blurb: "Decisions, actions and owners from a transcript.",
          use: "Use when turning a meeting transcript or rough notes into notes.", """
        Output: Summary (3 lines) · Decisions · Actions (owner, due) · Open questions. Never invent owners or dates; mark them "TBC".
        """),
        s("weekly-report", "Weekly update", "Productivity", "calendar",
          blurb: "Done, next, risks, in five lines.",
          use: "Use when writing a weekly status update.", """
        Five lines max: ✅ Done · ⏭ Next · ⚠️ Risks · 🙋 Needs · 📈 One number that moved. Link to evidence for each item.
        """),
        // Data
        s("data-analysis", "Data analysis", "Data", "chart.xyaxis.line",
          blurb: "Clean, explore and chart data with Python.",
          use: "Use when analysing a dataset, CSV, export or query result.", """
        - Load the data, show shape, columns and nulls first. State assumptions about units and time zones.
        - Compare against the previous period and explain what drove any change.
        - Save charts as PNG in `./workspace/` (or the group's shared folder) and describe them in one line each.
        """),
        s("spreadsheets", "Spreadsheet wizard", "Data", "tablecells.badge.ellipsis",
          blurb: "Formulas, pivots and clean tables.",
          use: "Use when working with spreadsheets, formulas or tables.", """
        Give formulas for Excel and Google Sheets, explain each in one line, and prefer XLOOKUP/FILTER over nested IFs. Produce CSV or .xlsx files in `./workspace/` when asked.
        """),
        // Operations
        s("sops", "Process & SOPs", "Operations", "checklist.checked",
          blurb: "Turn how work gets done into short, followable checklists.",
          use: "Use when documenting a process or writing a standard operating procedure.", """
        - Ask who does the task, how often, and what "done" looks like.
        - Write the SOP as numbered steps, each starting with a verb, with the owner and the tool used.
        - Add a "When things go wrong" section and a one-line purpose at the top.
        - Keep it to one page; link to detail instead of pasting it.
        """),
        s("okrs", "Goals & OKRs", "Operations", "target",
          blurb: "Set clear objectives with measurable key results.",
          use: "Use when setting goals or OKRs, or checking progress against them.", """
        - One objective per theme, written as an outcome, not a task.
        - Two to four key results each, with a number, a baseline and a date.
        - Flag any key result nobody can measure yet and say how to measure it.
        - In check-ins, score each key result 0–1 and name the one thing that would move it most.
        """),
        // Marketing
        s("seo", "SEO briefs", "Marketing", "chart.line.uptrend.xyaxis",
          blurb: "Keyword research and briefs that match search intent.",
          use: "Use when doing keyword research or writing an SEO brief or page audit.", """
        - Find the main keyword and 5–10 related ones; state the search intent for each.
        - Look at the top results: their angle, length and gaps we can fill.
        - Brief: title options, H2 outline, questions to answer, internal links, meta description under 155 characters.
        - Never invent search volumes; say where any number came from.
        """),
        s("press-release", "Press & announcements", "Marketing", "newspaper",
          blurb: "Press releases, launch posts and media lists.",
          use: "Use when writing a press release, announcement or media list.", """
        - Headline with the news in plain words, then a one-paragraph summary: who, what, when, why it matters.
        - One quote that says something a fact can't. Boilerplate at the end.
        - For media lists, include only journalists who cover the topic, with a link to a recent piece.
        - Never send or pitch; hand drafts to the user.
        """),
        // Sales
        s("sales-outreach", "Sales outreach", "Sales", "paperplane",
          blurb: "Lead research and short, personal outreach drafts.",
          use: "Use when researching leads or drafting sales outreach.", """
        - Research each lead from public business sources only; note one specific, recent reason to reach out.
        - Draft emails under 120 words: personal opener, the problem we solve, one proof point, one easy ask.
        - Give a 3-touch sequence with spacing. Never send; sending needs `[[approve: send … to …]]`.
        - Keep a table: company, person's role, reason, source link, status.
        """),
        s("proposals", "Proposals & quotes", "Sales", "doc.plaintext",
          blurb: "Clear proposals with scope, price and next steps.",
          use: "Use when writing a proposal, quote or statement of work.", """
        - Structure: their goal in their words, our approach, scope (in and out), timeline, price, next steps.
        - Prices only from what the user gives you; never invent a number or discount.
        - Keep it to two pages, with a one-paragraph summary at the top.
        """),
        // Support
        s("support-replies", "Support replies", "Support", "bubble.left.and.text.bubble.right",
          blurb: "Kind, fast answers that solve the problem first time.",
          use: "Use when drafting a reply to a customer question or complaint.", """
        - Acknowledge the problem in one line, then give the fix as numbered steps.
        - Use the help docs or past answers in the folder; never guess at policy, refunds or prices.
        - If you can't solve it, say what you need or who will follow up, and when.
        - Draft only; the user sends.
        """),
        s("customer-health", "Customer health", "Support", "heart.text.square",
          blurb: "Spot churn risk and plan the next touch.",
          use: "Use when reviewing accounts for churn risk or planning check-ins.", """
        - For each account, note usage trend, open issues, last contact and renewal date.
        - Score health green, amber or red with one line of reasons.
        - For amber and red, suggest the next action, an owner and a date.
        """),
        // Finance
        s("bookkeeping", "Bookkeeping", "Finance", "book.closed",
          blurb: "Tidy invoices, receipts and categorised spend.",
          use: "Use when categorising transactions, receipts or invoices.", """
        - Put each transaction in a table: date, supplier, amount, currency, VAT, category, receipt link.
        - Flag duplicates, missing receipts and anything unusual; never delete records.
        - Monthly summary: total in, total out, top categories and changes from last month.
        - You prepare; the user or their accountant approves and files.
        """),
        s("financial-model", "Budgets & forecasts", "Finance", "chart.pie",
          blurb: "Simple budgets, forecasts and runway you can audit.",
          use: "Use when building a budget, forecast or runway model.", """
        - Build in a spreadsheet with inputs on one tab and formulas on another; label every assumption.
        - Show base, low and high cases and the runway for each.
        - State where each input came from. Don't present a forecast as a fact.
        """),
        // People
        s("hiring", "Hiring", "People", "person.badge.plus",
          blurb: "Job ads, CV screening and structured interviews.",
          use: "Use when writing a job ad, screening applications or preparing interviews.", """
        - Job ad: the mission, what they'll do in 90 days, must-haves vs nice-to-haves, pay range if given, inclusive wording.
        - Screen CVs only against the written must-haves; give reasons, never judge on age, gender, ethnicity or other protected traits.
        - Interview kit: 5 structured questions per competency with what a strong answer looks like.
        """),
        s("onboarding", "Onboarding", "People", "hand.wave",
          blurb: "First-week plans, checklists and welcome notes.",
          use: "Use when planning a new starter's onboarding.", """
        - A day-by-day first week: accounts, intros, docs to read and one small win.
        - A 30-60-90 day plan with clear goals and check-ins.
        - A welcome note in the team's voice.
        """),
        // Legal
        s("contracts-review", "Contract review", "Legal", "doc.text.magnifyingglass",
          blurb: "Plain-English summaries and risky clauses flagged.",
          use: "Use when reviewing or summarising a contract, terms or agreement.", """
        - Summarise: parties, term, payment, renewal, termination, liability, IP and data.
        - Flag unusual or one-sided clauses with the exact quote and why it matters.
        - Always say this isn't legal advice and suggest a lawyer for anything high-stakes.
        """),
    ]

    /// Every skill in the marketplace: the starters, then the rest.
    public static let all: [CatalogSkill] = starters + extras

    public static func skill(_ id: String) -> CatalogSkill? { all.first { $0.id == id } }
}

extension SkillStore {
    /// Whether a skill with this id is in the library.
    public func isInstalled(_ id: String) -> Bool { load(id: id) != nil }

    /// Writes the catalog skill to skills/<id>/SKILL.md, replacing what's there.
    @discardableResult
    public func install(_ skill: CatalogSkill) throws -> Skill {
        try paths.ensureStructure()
        try save(id: skill.id, text: skill.fileText)
        guard let installed = load(id: skill.id) else { throw BotStoreError.notFound(skill.id) }
        return installed
    }

    /// Installs a catalog skill only if the library doesn't have one with that id (your edits are kept).
    /// Ids that aren't in the catalog (e.g. graphify, or your own) are left alone.
    public func installIfMissing(_ id: String) throws {
        guard !isInstalled(id), let skill = SkillCatalog.skill(id) else { return }
        try install(skill)
    }
}
