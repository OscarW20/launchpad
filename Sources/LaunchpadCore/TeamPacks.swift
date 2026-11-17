import Foundation

/// A ready-made team: several roles from `HireCatalog`, and a group with a lead and rules.
/// Hire one with `Hiring.hireTeam(_:)`.
public struct TeamPack: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var tagline: String
    public var emoji: String
    /// The group's id and name (shown as `#groupId`).
    public var groupId: String
    /// Role id (`HireCatalog`) of the group's lead.
    public var lead: String
    /// Role ids of the other members, in hand-off order.
    public var members: [String]
    public var rules: String
    /// Skills every member gets through the group.
    public var groupSkills: [String] = []
    public var handoffLimit: Int = 3

    /// Lead first, then the members, without duplicates.
    public var everyone: [String] {
        var out = [lead]
        for m in members where !out.contains(m) { out.append(m) }
        return out
    }

    public var templates: [HireTemplate] { everyone.compactMap(HireCatalog.template) }
}

public enum TeamPacks {
    public static let dev = TeamPack(
        id: "dev", name: "Dev team", tagline: "Plan, design, build, test, review and ship a web app.", emoji: "🛠️",
        groupId: HireCatalog.devTeamGroupName, lead: "lead",
        members: ["planner", "designer", "frontend", "backend", "tester", "reviewer", "shipper"],
        rules: HireCatalog.devTeamRules, groupSkills: [Graphify.skillId]
    )

    public static let launch = TeamPack(
        id: "launch", name: "Launch team", tagline: "Plan, build and announce a product launch.", emoji: "📣",
        groupId: "launch-crew", lead: "project-manager",
        members: ["planner", "frontend", "writer", "comms-lead"],
        rules: """
        - The project manager agrees the launch date, scope and owners with me before work starts.
        - Order of work: spec (planner) → landing page (frontend) → launch copy (writer) → announcement (comms lead).
        - One task per hand-off, with an owner and a date.
        - Drafts only: nothing is published, posted, pitched or deployed without my approval.
        - Keep replies short; put plans, copy and checklists in files in the shared folder.
        """
    )

    public static let content = TeamPack(
        id: "content", name: "Content team", tagline: "Research, write, edit and post every week.", emoji: "✍️",
        groupId: "content-studio", lead: "writer",
        members: ["researcher", "seo-specialist", "social-manager", "brand-designer"],
        rules: """
        - The writer agrees this week's topics with me first, then hands out research, SEO briefs, social posts and visuals.
        - Every fact has a dated source. Never invent numbers or quotes.
        - Everything follows the brand voice (VOICE.md or brand/ in the shared folder, if there is one).
        - Drafts only: nothing is posted or published without my approval.
        - Keep replies short; put drafts in files in the shared folder.
        """
    )

    public static let engineering = TeamPack(
        id: "engineering", name: "Engineering team", tagline: "Build features, review code and ship safely.", emoji: "⚙️",
        groupId: "engineering", lead: "engineer",
        members: ["reviewer", "tester", "shipper"],
        rules: """
        - The engineer plans the change and gets my approval before building anything big.
        - Small commits on a branch; never commit secrets. Tests first where it helps.
        - Every change gets a review (reviewer) and a test run (tester) before it ships.
        - Deploys, pushes and anything that costs money need my approval.
        - Keep replies short; put details in files.
        """
    )

    public static let backOffice = TeamPack(
        id: "back-office", name: "Back office", tagline: "Inbox, books, hiring and contracts handled.", emoji: "🗂️",
        groupId: "back-office", lead: "chief-of-staff",
        members: ["assistant", "bookkeeper", "recruiter", "contracts-reviewer"],
        rules: """
        - The chief of staff keeps a weekly list of priorities, owners and dates, and hands out the work.
        - Drafts only: no emails sent, payments made, offers made or contracts signed without my approval.
        - Keep personal and financial details inside the shared folder; never paste them anywhere else.
        - Contract summaries are not legal advice; say so, and suggest a lawyer for anything high-stakes.
        - Keep replies short; put details in files.
        """
    )

    public static let all: [TeamPack] = [dev, launch, content, engineering, backOffice]

    public static func pack(_ id: String) -> TeamPack? { all.first { $0.id == id } }
}
