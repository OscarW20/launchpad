import Foundation

// MARK: - Engine & permissions

public enum BotEngine: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude
    case codex

    public var id: String { rawValue }
    public var displayName: String { self == .claude ? "Claude Code" : "Codex" }
    /// The subscription the engine runs on.
    public var planName: String { self == .claude ? "Claude" : "ChatGPT" }
    public var executableName: String { rawValue }
    /// The command a person runs in Terminal to sign in.
    public var signInCommand: String { self == .claude ? "claude auth login" : "codex login" }
    public var installURL: URL {
        self == .claude
            ? URL(string: "https://docs.claude.com/en/docs/claude-code/setup")!
            : URL(string: "https://github.com/openai/codex")!
    }
}

public enum PermissionLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case readOnly = "read-only"
    case editWorkspace = "edit-workspace"
    case fullAccess = "full-access"

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .readOnly: return "Read only"
        case .editWorkspace: return "Can edit its workspace"
        case .fullAccess: return "Full access"
        }
    }
    public var explanation: String {
        switch self {
        case .readOnly: return "Can look at files and search the web, but can't change anything."
        case .editWorkspace: return "Can create and edit files in its own folder. Can't run commands."
        case .fullAccess: return "Can run any command and edit any file. Only for bots you trust."
        }
    }
}

// MARK: - Bot

public struct Bot: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var emoji: String
    public var colour: String
    public var role: String
    public var engine: BotEngine
    public var model: String?
    public var permission: PermissionLevel
    public var connectors: [String]
    public var skills: [String]
    public var createdAt: Date
    /// What it must ask you about first, may always do, or may never do (send, delete, spend, change, shell, computer).
    public var rules: BotRules
    /// Locked down: no internet except through Launchpad's site gateway (only `sites`), no opening or scripting other
    /// apps, no startup files, and "Always allow" off for writes. Needs the sandbox (macOS).
    public var lockedDown: Bool
    /// Websites a locked-down bot may reach ("github.com" also allows its subdomains). Its engine's own sites are added for it.
    public var sites: [String]

    public init(
        id: String, name: String, emoji: String = "🤖", colour: String = BotPalette.default,
        role: String = "", engine: BotEngine = .claude, model: String? = nil,
        permission: PermissionLevel = .editWorkspace, connectors: [String] = [],
        skills: [String] = [], createdAt: Date = Date(), rules: BotRules = BotRules(),
        lockedDown: Bool = false, sites: [String] = []
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.colour = colour
        self.role = role
        self.engine = engine
        self.model = model
        self.permission = permission
        self.connectors = connectors
        self.skills = skills
        self.createdAt = createdAt
        self.rules = rules
        self.lockedDown = lockedDown
        self.sites = sites
    }

    enum CodingKeys: String, CodingKey {
        case id, name, emoji, colour, role, engine, model, permission, connectors, skills, createdAt
        case rules, lockedDown, sites
    }

    // bot.json may be written by hand or by another agent, so every field is optional on read.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Unnamed bot"
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji) ?? "🤖"
        colour = try c.decodeIfPresent(String.self, forKey: .colour) ?? BotPalette.default
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        engine = (try? c.decodeIfPresent(BotEngine.self, forKey: .engine)) ?? .claude
        let rawModel = try c.decodeIfPresent(String.self, forKey: .model)
        model = (rawModel?.isEmpty ?? true) ? nil : rawModel
        permission = (try? c.decodeIfPresent(PermissionLevel.self, forKey: .permission)) ?? .editWorkspace
        connectors = try c.decodeIfPresent([String].self, forKey: .connectors) ?? []
        skills = try c.decodeIfPresent([String].self, forKey: .skills) ?? []
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
        rules = (try? c.decodeIfPresent(BotRules.self, forKey: .rules)) ?? BotRules()
        lockedDown = (try? c.decodeIfPresent(Bool.self, forKey: .lockedDown)) ?? false
        sites = (try? c.decodeIfPresent([String].self, forKey: .sites)) ?? []
    }
}

public enum BotPalette {
    public static let colours: [String] = [
        "#E8735A", // coral
        "#F2A65A", // apricot
        "#E9C46A", // sunflower
        "#8DB580", // sage
        "#4FA3A5", // teal
        "#6C9BD2", // sky
        "#A38CD9", // lavender
        "#E07A9B", // rose
    ]
    public static let `default` = colours[0]
    public static let emojis: [String] = [
        "🤖", "🦊", "🐙", "🦉", "🐝", "🦄", "🐳", "🦁", "🐼", "🐢",
        "🌟", "🚀", "🎨", "🧪", "🛠️", "📐", "🔍", "📦", "🧭", "✍️",
    ]
}

// MARK: - Chats

public enum ChatKind: String, Codable, Sendable {
    case bot
    case group
}

public struct ChatMeta: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var kind: ChatKind
    public var botId: String?
    public var groupId: String?
    /// Engine session per bot, so each chat resumes its own conversation.
    public var sessions: [String: String]
    public var createdAt: Date
    public var updatedAt: Date
    public var lastPreview: String?

    public init(
        id: String = UUID().uuidString.lowercased(), title: String, kind: ChatKind,
        botId: String? = nil, groupId: String? = nil, sessions: [String: String] = [:],
        createdAt: Date = Date(), updatedAt: Date = Date(), lastPreview: String? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.botId = botId
        self.groupId = groupId
        self.sessions = sessions
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastPreview = lastPreview
    }
}

public enum MessageRole: String, Codable, Sendable {
    case user
    case bot
    case notice
}

public enum MessageStatus: String, Codable, Sendable {
    case streaming
    case done
    case stopped
    case failed
}

public struct Step: Codable, Identifiable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        case running, succeeded, failed, stopped
    }

    public var id: String
    public var tool: String
    public var title: String
    public var detail: String?
    public var output: String?
    public var status: Status

    public init(id: String, tool: String, title: String, detail: String? = nil, output: String? = nil, status: Status = .running) {
        self.id = id
        self.tool = tool
        self.title = title
        self.detail = detail
        self.output = output
        self.status = status
    }
}

public struct ChatMessage: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var role: MessageRole
    public var botId: String?
    public var text: String
    public var steps: [Step]
    public var status: MessageStatus
    public var failure: RunFailure?
    public var createdAt: Date
    public var costUSD: Double?
    /// An Approve / Decline card the bot asked for.
    public var approval: ApprovalRequest?
    /// For notices that offer a next step (e.g. "Keep going" after the hand-off limit).
    public var noticeAction: NoticeAction?

    // Chat features (see Chat/ChatFeatures.swift). All optional, so chat history written before they existed still
    // decodes, and a change is saved by appending the whole message again (the latest line with an id wins).

    /// Emoji -> who reacted: `ChatOps.you` or a bot id.
    public var reactions: [String: [String]]?
    public var pinned: Bool?
    /// Saved for later ("Saved messages").
    public var saved: Bool?
    /// Earlier versions of the text, oldest first. Non-empty means "edited".
    public var edits: [MessageEdit]?
    /// Deleted: shown as "This message was deleted"; text and extras are cleared.
    public var deleted: Bool?
    /// Files that came with the message (absolute paths, copied into the bot's or group's Inbox).
    public var attachments: [String]?
    /// Who wrote the original, for a forwarded message.
    public var forwardedFrom: String?
    public var gif: GifRef?
    public var poll: Poll?
    /// A plan the bot asked you to start (long tasks), with Start and Cancel and an optional countdown.
    public var plan: PlanCard?
    /// Questions the bot asked as tappable choices.
    public var questions: QuestionCard?

    public init(
        id: String = UUID().uuidString.lowercased(), role: MessageRole, botId: String? = nil,
        text: String = "", steps: [Step] = [], status: MessageStatus = .done,
        failure: RunFailure? = nil, createdAt: Date = Date(), costUSD: Double? = nil,
        approval: ApprovalRequest? = nil, noticeAction: NoticeAction? = nil
    ) {
        self.approval = approval
        self.noticeAction = noticeAction
        self.id = id
        self.role = role
        self.botId = botId
        self.text = text
        self.steps = steps
        self.status = status
        self.failure = failure
        self.createdAt = createdAt
        self.costUSD = costUSD
    }
}

public enum NoticeAction: String, Codable, Hashable, Sendable {
    /// The group hit its hand-off limit: let it carry on.
    case continueGroup
    /// "Memory updated": offer Undo. The notice's id is the memory update's id.
    case undoMemory
}

// MARK: - Failures (plain English)

public enum FailureKind: String, Codable, Sendable {
    case cliMissing
    case signedOut
    case usageLimit
    case network
    case overloaded
    case sessionLost
    case unknown
}

public enum FailureAction: Codable, Hashable, Sendable {
    case openTerminal(command: String)
    case openURL(URL)

    public var label: String {
        switch self {
        case .openTerminal: return "Open Terminal"
        case .openURL: return "Show me how"
        }
    }
}

public struct RunFailure: Codable, Hashable, Sendable {
    public var kind: FailureKind
    /// What the person sees.
    public var message: String
    /// The raw text from the engine, for "Show details".
    public var detail: String?
    public var action: FailureAction?

    public init(kind: FailureKind, message: String, detail: String? = nil, action: FailureAction? = nil) {
        self.kind = kind
        self.message = message
        self.detail = detail
        self.action = action
    }
}
