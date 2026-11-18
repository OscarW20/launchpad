import Foundation

// "Create ticket": select text in any Mac app, and a bot drafts and files a Jira ticket from it.
// This is the part with no UI: the settings, the request, the prompt (TicketPrompt) and the result.
// Nothing here holds a Jira token: sign-in lives in the Jira connector (Apps) and the Keychain.

/// Someone a ticket can be assigned to. `jira` is how Jira knows them (a display name or an email address): the bot
/// looks the account up and never guesses.
public struct TicketAssignee: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var jira: String

    public init(id: String? = nil, name: String, jira: String) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.jira = jira.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id ?? Slug.make(name)
    }

    public var isValid: Bool { !name.isEmpty && !jira.isEmpty && !id.isEmpty }

    enum CodingKeys: String, CodingKey { case id, name, jira }

    /// A missing id is made from the name, so a hand-edited or older file still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        let jira = try c.decodeIfPresent(String.self, forKey: .jira) ?? ""
        self.init(id: try c.decodeIfPresent(String.self, forKey: .id), name: name, jira: jira)
    }
}

/// Decodes what it can: one unreadable entry doesn't lose the others.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// Whether Launchpad shows an approval card before the ticket is created.
public enum TicketApproval: String, Codable, CaseIterable, Identifiable, Sendable {
    /// A card shows what will be filed; nothing is created until you approve it. The default.
    case ask
    /// The ticket is created as soon as the bot has drafted it. Only the Jira create call skips the card.
    case skip

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ask: return "Ask me first"
        case .skip: return "File without asking"
        }
    }

    public var detail: String {
        switch self {
        case .ask: return "You approve each ticket before it's created."
        case .skip: return "Tickets are created straight away. Text you select can come from anywhere, including emails and web pages, so check the draft in the panel before you send it."
        }
    }
}

/// The settings for Create ticket. Saved by `TicketSettingsStore` in Launchpad's data folder, which bots can't write:
/// the approval mode must not be something a bot can switch off for itself.
public struct TicketSettings: Codable, Equatable, Sendable {
    public static let defaultProjectKey = "BIS"
    public static let defaultSkillId = "biscuit-jira-tickets"
    public static let defaultSelectionLimit = 20_000
    public static let selectionLimits = 1_000...100_000

    /// The Jira project tickets go in. A setting, not hard-coded in the prompt.
    public var projectKey: String
    /// The skill that says how to write a ticket (a folder in the skills library).
    public var skillId: String
    public var approval: TicketApproval
    public var assignees: [TicketAssignee]
    /// Your Jira site, e.g. "biscuit-pet-care.atlassian.net". When set, only links on it count as a created ticket.
    public var siteHost: String?
    /// Selected text longer than this is cut (and the panel says so).
    public var maxSelectionCharacters: Int

    public init(
        projectKey: String = TicketSettings.defaultProjectKey, skillId: String = TicketSettings.defaultSkillId,
        approval: TicketApproval = .ask, assignees: [TicketAssignee] = [], siteHost: String? = nil,
        maxSelectionCharacters: Int = TicketSettings.defaultSelectionLimit
    ) {
        // Kept as typed (an empty one means the default): quietly swapping a wrong key for another project's would
        // file tickets in the wrong place. `TicketProblem.check` and `TicketPrompt.build` refuse an invalid one.
        let key = projectKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.projectKey = key.isEmpty ? Self.defaultProjectKey : key
        self.skillId = skillId.isEmpty ? Self.defaultSkillId : skillId
        self.approval = approval
        self.assignees = Self.cleaned(assignees)
        self.siteHost = Self.cleanHost(siteHost)
        self.maxSelectionCharacters = min(max(maxSelectionCharacters, Self.selectionLimits.lowerBound), Self.selectionLimits.upperBound)
    }

    enum CodingKeys: String, CodingKey { case projectKey, skillId, approval, assignees, siteHost, maxSelectionCharacters }

    /// Reads leniently: anything missing or unreadable falls back to its default, and an unknown approval means ask.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            projectKey: (try? c.decodeIfPresent(String.self, forKey: .projectKey)) ?? Self.defaultProjectKey,
            skillId: (try? c.decodeIfPresent(String.self, forKey: .skillId)) ?? Self.defaultSkillId,
            approval: (try? c.decodeIfPresent(TicketApproval.self, forKey: .approval)) ?? .ask,
            assignees: ((try? c.decodeIfPresent([Lossy<TicketAssignee>].self, forKey: .assignees)) ?? []).compactMap(\.value),
            siteHost: try? c.decodeIfPresent(String.self, forKey: .siteHost),
            maxSelectionCharacters: (try? c.decodeIfPresent(Int.self, forKey: .maxSelectionCharacters)) ?? Self.defaultSelectionLimit)
    }

    /// Jira project keys: capital letters, digits and underscores, starting with a letter, 2 to 10 characters.
    public static func validProjectKey(_ key: String) -> Bool {
        key.range(of: #"^[A-Z][A-Z0-9_]{1,9}$"#, options: .regularExpression) != nil
    }

    /// Shown while no Jira site is set. Not an error: tickets can still be filed, but their links aren't trusted yet.
    public var siteWarning: String? {
        siteHost == nil
            ? "Your Jira site isn't set, so Launchpad can't tell a ticket link is really yours. It won't copy or open one until you confirm the site."
            : nil
    }

    /// These settings with the Jira site taken from a result's link: what you do when you confirm "yes, that's my site".
    /// Does nothing if the result's link isn't on an atlassian.net site.
    public func confirmingSite(of result: TicketResult) -> TicketSettings {
        guard let host = result.site, host.hasSuffix(".atlassian.net") else { return self }
        var copy = self
        copy.siteHost = Self.cleanHost(host)
        return copy
    }

    public func assignee(id: String?) -> TicketAssignee? {
        id.flatMap { id in assignees.first { $0.id == id } }
    }

    /// Valid people only, one per id (the first wins).
    static func cleaned(_ list: [TicketAssignee]) -> [TicketAssignee] {
        var seen = Set<String>()
        return list.filter { $0.isValid && seen.insert($0.id).inserted }
    }

    public static func cleanHost(_ host: String?) -> String? {
        guard var h = host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !h.isEmpty else { return nil }
        for prefix in ["https://", "http://"] where h.hasPrefix(prefix) { h.removeFirst(prefix.count) }
        h = String(h.prefix { $0 != "/" })
        return h.isEmpty || !h.contains(".") ? nil : h
    }
}

/// Where the settings live: `.launchpad/ticket-settings.json`, next to the other files bots can't change.
public struct TicketSettingsStore {
    public let file: URL

    public init(paths: LaunchpadPaths) {
        file = paths.launchpadData.appendingPathComponent("ticket-settings.json")
    }

    /// The saved settings, or the defaults (Ask me first) when there are none or they can't be read.
    public func load() -> TicketSettings {
        guard let data = try? Data(contentsOf: file),
              let settings = try? JSONCoding.decoder().decode(TicketSettings.self, from: data) else { return TicketSettings() }
        return settings
    }

    public func save(_ settings: TicketSettings) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.encoder().encode(settings).write(to: file, options: .atomic)
    }
}

/// What was captured: the selection, where it came from, your note and who it's for.
public struct TicketRequest: Equatable, Sendable {
    public var selectedText: String
    /// The app the text was selected in (best effort).
    public var sourceApp: String?
    /// The window's title (best effort: reading it can need extra permission, so it's never required).
    public var sourceWindow: String?
    public var note: String
    public var assignee: TicketAssignee?
    public var capturedAt: Date

    public init(selectedText: String = "", sourceApp: String? = nil, sourceWindow: String? = nil, note: String = "",
                assignee: TicketAssignee? = nil, capturedAt: Date = Date()) {
        self.selectedText = selectedText
        self.sourceApp = sourceApp
        self.sourceWindow = sourceWindow
        self.note = note
        self.assignee = assignee
        self.capturedAt = capturedAt
    }
}

/// A ticket the bot says it filed, with a link that passed the checks below.
public struct TicketResult: Equatable, Sendable {
    public var key: String
    public var url: URL
    /// True when the link is on the Jira site set in Settings. False when no site is set: the link is on *some*
    /// atlassian.net site, and anyone can make one, so the app must not copy it, announce it or open it until you've
    /// confirmed the site (`TicketSettings.confirmingSite(of:)`).
    public var siteConfirmed: Bool

    public init(key: String, url: URL, siteConfirmed: Bool) {
        self.key = key
        self.url = url
        self.siteConfirmed = siteConfirmed
    }

    /// The host the link is on, e.g. "biscuit-pet-care.atlassian.net".
    public var site: String? { url.host?.lowercased() }

    /// The same result once you've confirmed the site.
    public func confirmed() -> TicketResult { TicketResult(key: key, url: url, siteConfirmed: true) }
}

/// How the bot's reply ended. Only a real key and link count as success.
public enum TicketOutcome: Equatable, Sendable {
    case created(TicketResult)
    /// The bot found a ticket for the same thing already and didn't create another.
    case duplicate(TicketResult)
    case failed(String)

    public var result: TicketResult? {
        switch self {
        case .created(let r), .duplicate(let r): return r
        case .failed: return nil
        }
    }

    /// The prompt asks the bot to end with one line: `TICKET: KEY URL`, `DUPLICATE: KEY URL` or `FAILED: why`.
    /// The last such line wins. A key that isn't in the project, or a link that isn't on your Jira site and
    /// pointing at that ticket, is a failure, so a bot can't claim a ticket it didn't make (or be talked into
    /// pointing at some other site).
    public static func parse(reply: String, settings: TicketSettings) -> TicketOutcome {
        for raw in reply.split(whereSeparator: \.isNewline).reversed() {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t*_`>-"))
            let lower = line.lowercased()
            if lower.hasPrefix("failed:") {
                let why = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
                return .failed(why.isEmpty ? "The ticket wasn't created." : why)
            }
            let created = lower.hasPrefix("ticket:"), duplicate = lower.hasPrefix("duplicate:")
            guard created || duplicate else { continue }
            let rest = line.dropFirst(created ? 7 : 10)
            guard let result = result(from: String(rest), settings: settings) else {
                return .failed("The reply named a ticket, but Launchpad couldn't confirm it is in \(settings.projectKey) on your Jira site, so it isn't counted as created. Check Jira.")
            }
            return created ? .created(result) : .duplicate(result)
        }
        return .failed("The reply didn't say whether the ticket was created. Check Jira before trying again, so you don't make a duplicate.")
    }

    static func result(from text: String, settings: TicketSettings) -> TicketResult? {
        let dressing = CharacterSet(charactersIn: "<>()[]\"'`,;.!?*_")
        let tokens = text.split(whereSeparator: \.isWhitespace).map { String($0).trimmingCharacters(in: dressing) }
        let keyPattern = "^" + NSRegularExpression.escapedPattern(for: settings.projectKey) + "-[0-9]{1,9}$"
        guard let key = tokens.first(where: { $0.range(of: keyPattern, options: .regularExpression) != nil }),
              let link = tokens.first(where: { $0.lowercased().hasPrefix("https://") }) else { return nil }
        guard let url = URL(string: link), url.scheme == "https", url.port == nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, let host = url.host?.lowercased() else { return nil }
        // With a site set, only that exact host counts. Without one, any atlassian.net site passes the shape check but
        // comes back unconfirmed: the app shows it and asks, and doesn't copy, announce or open it.
        let confirmed: Bool
        if let site = settings.siteHost {
            guard host == site else { return nil }
            confirmed = true
        } else {
            guard host.hasSuffix(".atlassian.net"), host.count > ".atlassian.net".count else { return nil }
            confirmed = false
        }
        let path = url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
        guard path == "/browse/\(key)" else { return nil }
        return TicketResult(key: key, url: url, siteConfirmed: confirmed)
    }
}

/// Things to fix before Create ticket can work, in words for the panel. The app supplies what it knows.
public enum TicketProblem: Equatable, Sendable {
    case jiraNotConnected
    case skillMissing(String)
    case badProjectKey(String)

    public var message: String {
        switch self {
        case .jiraNotConnected: return "Jira isn't connected yet. Open Apps, add Jira & Confluence and sign in. Your selection and note stay here."
        case .skillMissing(let id): return "The \"\(id)\" skill isn't in your skills library yet. Import it from Settings, or copy its folder into ~/Launchpad/skills."
        case .badProjectKey(let key): return "\"\(key)\" isn't a Jira project key. Use capital letters and digits, like BIS."
        }
    }

    public static func check(settings: TicketSettings, jiraConnected: Bool, skillInstalled: Bool) -> [TicketProblem] {
        var problems: [TicketProblem] = []
        if !TicketSettings.validProjectKey(settings.projectKey) { problems.append(.badProjectKey(settings.projectKey)) }
        if !jiraConnected { problems.append(.jiraNotConnected) }
        if !skillInstalled { problems.append(.skillMissing(settings.skillId)) }
        return problems
    }
}
