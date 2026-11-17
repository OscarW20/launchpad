import Foundation

/// A bot asking "can I do this?" before deploying, sending, spending or deleting.
public struct ApprovalRequest: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        case pending, approved, declined
    }

    public var action: String
    public var status: Status

    public init(action: String, status: Status = .pending) {
        self.action = action
        self.status = status
    }

    /// Finds `[[approve: …]]` in a reply. Returns the text without it, and the request.
    public static func extract(from text: String) -> (text: String, request: ApprovalRequest?) {
        guard let start = text.range(of: "[[approve:", options: .caseInsensitive),
              let end = text.range(of: "]]", range: start.upperBound..<text.endIndex) else {
            return (text, nil)
        }
        let action = text[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !action.isEmpty else { return (text, nil) }
        var cleaned = text
        cleaned.removeSubrange(start.lowerBound..<end.upperBound)
        cleaned = cleaned.replacingOccurrences(of: "\n\n\n", with: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned, ApprovalRequest(action: action))
    }

    public var approvedPrompt: String { "Approved: \(action). Go ahead." }
    public var declinedPrompt: String { "Declined: \(action). Don't do it. Tell me what you'd suggest instead." }
}

/// What the guard thinks of a tool call.
public enum RiskKind: String, Codable, Sendable {
    case deploy, send, spend, delete

    public var verb: String {
        switch self {
        case .deploy: return "deploying or publishing"
        case .send: return "sending or posting something"
        case .spend: return "spending money"
        case .delete: return "deleting something"
        }
    }
}

/// Spots tool calls that need your approval. Used by the `launchpad-guard` hook for Claude Code bots.
public enum RiskClassifier {
    struct Rule {
        let kind: RiskKind
        let regex: NSRegularExpression
    }

    private static func rule(_ kind: RiskKind, _ pattern: String) -> Rule {
        Rule(kind: kind, regex: try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))
    }

    // Order matters: the first match names the risk.
    private static let commandRules: [Rule] = [
        rule(.spend, #"\bstripe\s+(charges|payment_intents|subscriptions|invoices|checkout)\b.*\bcreate\b"#),
        rule(.spend, #"\bvercel\s+domains\s+buy\b"#),
        rule(.spend, #"\baws\s+\S+\s+(run-instances|create-|purchase)"#),
        rule(.deploy, #"\bvercel\b(?!\s+(login|logout|whoami|env\s+(ls|pull)|link|dev|ls|list|inspect|logs|help|--version|-v\b|project\s+ls|teams\s+ls|switch|build))"#),
        rule(.deploy, #"\b(netlify|fly|flyctl|firebase|railway|wrangler)\s+(deploy|publish|up)\b"#),
        rule(.deploy, #"\bgcloud\b.*\bdeploy\b"#),
        rule(.deploy, #"\bsupabase\s+(db\s+push|functions\s+deploy|db\s+reset|link)\b"#),
        rule(.deploy, #"\bgit\s+push\b"#),
        rule(.deploy, #"\b(npm|pnpm|yarn)\s+publish\b"#),
        rule(.deploy, #"\bdocker\s+push\b"#),
        rule(.deploy, #"\bkubectl\s+(apply|delete|rollout)\b"#),
        rule(.send, #"\bgh\s+(pr|issue|release|repo)\s+(create|comment|merge|close|delete|edit)\b"#),
        rule(.send, #"\b(sendmail|mail|mailx)\s"#),
        rule(.send, #"\bcurl\b(?=.*(\s-X\s*(POST|PUT|PATCH|DELETE)|\s(-d|--data\S*|-F|--form)\s))(?!.*\b(localhost|127\.0\.0\.1|0\.0\.0\.0)\b)"#),
        rule(.delete, #"(^|[;&|]\s*|\s)(sudo\s+)?(rm|rmdir|unlink|shred)\s"#),
        rule(.delete, #"\bgit\s+(clean\s+-\S*f|reset\s+--hard|branch\s+-D|push\s+.*--delete)"#),
        rule(.delete, #"\b(drop\s+(table|database|schema)|truncate\s+table|delete\s+from)\b"#),
        rule(.delete, #"\bfind\b.*\s-delete\b"#),
    ]

    private static let mcpWords: [(RiskKind, [String])] = [
        (.spend, ["pay", "purchase", "charge", "transfer", "buy", "checkout"]),
        (.deploy, ["deploy", "publish", "release", "apply_migration"]),
        (.delete, ["delete", "remove", "drop", "destroy", "archive"]),
        (.send, ["send", "post", "create_issue", "create_pull_request", "comment", "reply", "message", "email", "tweet", "merge", "execute_sql"]),
    ]

    public static func classify(command: String) -> RiskKind? {
        let range = NSRange(command.startIndex..., in: command)
        for r in commandRules where r.regex.firstMatch(in: command, range: range) != nil {
            return r.kind
        }
        return nil
    }

    public static func classify(mcpTool name: String) -> RiskKind? {
        // mcp__server__tool_name
        let tool = name.split(separator: "_", omittingEmptySubsequences: true).dropFirst(2).joined(separator: "_").lowercased()
        for (kind, words) in mcpWords where words.contains(where: { tool.contains($0) }) {
            return kind
        }
        return nil
    }

    /// Classifies a Claude Code PreToolUse hook payload.
    public static func classify(hookInput: [String: Any]) -> RiskKind? {
        let tool = hookInput["tool_name"] as? String ?? ""
        let input = hookInput["tool_input"] as? [String: Any] ?? [:]
        if tool == "Bash", let cmd = input["command"] as? String { return classify(command: cmd) }
        if tool.hasPrefix("mcp__") { return classify(mcpTool: tool) }
        return nil
    }
}

/// One-time permission you gave in chat. Stored per engine session, valid for a short while.
public struct ApprovalGrants {
    public static let validity: TimeInterval = 15 * 60

    let dir: URL
    let fm = FileManager.default

    public init(paths: LaunchpadPaths) {
        dir = paths.root.appendingPathComponent(".launchpad/approvals", isDirectory: true)
    }

    public init(directory: URL) {
        dir = directory
    }

    public var directory: URL { dir }

    struct Grant: Codable {
        var action: String
        var grantedAt: Date
    }

    private func file(_ sessionId: String) -> URL {
        dir.appendingPathComponent(Slug.make(sessionId) + ".json")
    }

    public func grant(sessionId: String, action: String, now: Date = Date()) throws {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var grants = load(sessionId).filter { now.timeIntervalSince($0.grantedAt) < Self.validity }
        grants.append(Grant(action: action, grantedAt: now))
        try JSONCoding.encoder().encode(grants).write(to: file(sessionId), options: .atomic)
    }

    public func isApproved(sessionId: String, now: Date = Date()) -> Bool {
        load(sessionId).contains { now.timeIntervalSince($0.grantedAt) < Self.validity && $0.grantedAt <= now.addingTimeInterval(1) }
    }

    private func load(_ sessionId: String) -> [Grant] {
        guard let data = try? Data(contentsOf: file(sessionId)) else { return [] }
        return (try? JSONCoding.decoder().decode([Grant].self, from: data)) ?? []
    }
}

/// The hook's decision for one tool call.
public enum GuardDecision: Equatable {
    case allow
    case block(String)

    public static func evaluate(hookJSON: Data, grants: ApprovalGrants, now: Date = Date()) -> GuardDecision {
        guard let obj = try? JSONSerialization.jsonObject(with: hookJSON) as? [String: Any] else { return .allow }
        guard let risk = RiskClassifier.classify(hookInput: obj) else { return .allow }
        if let session = obj["session_id"] as? String, grants.isApproved(sessionId: session, now: now) {
            return .allow
        }
        return .block("""
        Launchpad: this needs my approval first because it means \(risk.verb). \
        Ask with a line `[[approve: <what you want to do, in plain words>]]`, then end your turn and wait for "Approved".
        """)
    }
}

/// Rules every bot gets, on top of its own instructions.
public enum LaunchpadProtocol {
    public static func text(skills: [String]) -> String {
        var s = """
        You're running inside Launchpad, a chat app where I work with a team of AI bots.
        - Ask before risky actions. Before you deploy or publish, push code, send or post anything outside this computer, \
        spend money, or delete anything, ask first: write a line `[[approve: <what you'll do, in plain words>]]` and \
        end your turn. Only do it after I reply "Approved". Launchpad blocks these actions until then.
        - Never write passwords, API keys or tokens into files, logs or chat. If you need a secret, ask me to add it.
        - Keep replies friendly and short. Say what you did and what's next.
        """
        if !skills.isEmpty {
            s += "\n- Your skills are in ./.agents/skills/<name>/SKILL.md (also ./.claude/skills). When a task matches one (\(skills.joined(separator: ", "))), read it and follow it."
        }
        return s
    }
}
