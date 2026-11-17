import Foundation

// MARK: - To-do list

/// One line of a bot's live to-do list.
public struct TodoItem: Codable, Hashable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    public var id: String
    public var title: String
    /// What to show while it's being worked on ("Running the tests"), when the engine says.
    public var activeTitle: String?
    public var status: Status

    public init(id: String, title: String, activeTitle: String? = nil, status: Status = .pending) {
        self.id = id
        self.title = title
        self.activeTitle = activeTitle
        self.status = status
    }

    /// The line to show: the active wording while in progress.
    public var label: String { status == .inProgress ? (activeTitle ?? title) : title }

    static func status(_ raw: String?) -> Status {
        switch raw?.lowercased() {
        case "in_progress", "in-progress", "inprogress", "active", "doing": return .inProgress
        case "completed", "complete", "done": return .completed
        default: return .pending
        }
    }
}

/// Keeps a bot's to-do list from the tools it uses during one run.
///
/// Claude Code: `TodoWrite` (the whole list each time) or `TaskCreate` / `TaskUpdate` (one task at a time; a new
/// task's number arrives in its tool result: "Task #3 created successfully: …"). Codex: `todo_list` items.
public final class TodoTracker: @unchecked Sendable {
    public private(set) var items: [TodoItem] = []
    private var pendingCreates: [String: String] = [:]   // tool_use id -> provisional task id
    private var created = 0

    public init() {}

    /// Returns true when the list changed.
    @discardableResult
    public func toolUse(name: String, id: String?, input: [String: Any]) -> Bool {
        switch name {
        case "TodoWrite":
            guard let todos = input["todos"] as? [[String: Any]] else { return false }
            items = todos.enumerated().map { i, t in
                TodoItem(id: Self.string(t["id"]) ?? "\(i + 1)",
                         title: (t["content"] as? String) ?? (t["subject"] as? String) ?? "Step \(i + 1)",
                         activeTitle: t["activeForm"] as? String,
                         status: TodoItem.status(t["status"] as? String))
            }
            return true
        case "TaskCreate":
            created += 1
            let provisional = "new-\(created)"
            items.append(TodoItem(id: provisional, title: (input["subject"] as? String) ?? (input["description"] as? String) ?? "Task",
                                  activeTitle: input["activeForm"] as? String, status: .pending))
            if let id { pendingCreates[id] = provisional }
            return true
        case "TaskUpdate":
            guard let taskId = Self.string(input["taskId"]) ?? Self.string(input["id"]),
                  let i = items.firstIndex(where: { $0.id == taskId }) else { return false }
            if let s = input["status"] as? String {
                if s == "deleted" { items.remove(at: i); return true }
                items[i].status = TodoItem.status(s)
            }
            if let t = input["subject"] as? String { items[i].title = t }
            if let a = input["activeForm"] as? String { items[i].activeTitle = a }
            return true
        default:
            return false
        }
    }

    /// A tool result: gives a just-created task its real number so later updates find it. True when the list changed.
    @discardableResult
    public func toolResult(id: String, text: String?) -> Bool {
        guard let provisional = pendingCreates.removeValue(forKey: id), let text,
              let r = text.range(of: #"#(\d+)"#, options: .regularExpression),
              let i = items.firstIndex(where: { $0.id == provisional }) else { return false }
        items[i].id = String(text[r].dropFirst())
        return true
    }

    /// Codex: `{"type":"todo_list","items":[{"text":…,"completed":…}]}`. The first unfinished item counts as in progress.
    public func codexList(_ list: [[String: Any]]) {
        var seenActive = false
        items = list.enumerated().map { i, t in
            let done = t["completed"] as? Bool ?? false
            var status: TodoItem.Status = done ? .completed : .pending
            if !done && !seenActive { status = .inProgress; seenActive = true }
            return TodoItem(id: "\(i + 1)", title: (t["text"] as? String) ?? "Step \(i + 1)", status: status)
        }
    }

    static func string(_ value: Any?) -> String? {
        if let s = value as? String, !s.isEmpty { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }
}

// MARK: - Context meter

/// How much of the model's context window one chat is using, as the engine reported it.
public struct ContextUsage: Codable, Hashable, Sendable {
    public var engine: BotEngine
    /// Tokens in the context now (the last model call's input, including cached input).
    public var used: Int
    /// The model's window, when the engine says (Claude: `modelUsage.*.contextWindow`, Codex: `model_context_window`).
    public var window: Int?

    public init(engine: BotEngine, used: Int, window: Int? = nil) {
        self.engine = engine
        self.used = used
        self.window = window
    }

    /// The window, or a typical size for the engine when it didn't say (then `isEstimated`).
    public var size: Int {
        if let window, window > 0 { return window }
        switch engine {
        case .claude: return 200_000
        case .codex: return 272_000
        case .local: return 8_192
        }
    }

    public var isEstimated: Bool { (window ?? 0) <= 0 }
    /// 0…1, for the ring.
    public var fraction: Double { size > 0 ? min(1, max(0, Double(used) / Double(size))) : 0 }
    public var free: Int { max(0, size - used) }
    /// Time to suggest Compact or a new thread.
    public var isNearlyFull: Bool { fraction >= 0.8 }

    /// Combines a newer report with what's known: keeps a window learned earlier when the new report has none.
    public func merged(with newer: ContextUsage) -> ContextUsage {
        var out = newer
        if out.window == nil { out.window = window }
        if out.used == 0 { out.used = used }
        return out
    }

    /// "12.3K of 200K (6%)".
    public var summary: String {
        "\(Self.tokens(used)) of \(Self.tokens(size))\(isEstimated ? " (estimated)" : "") · \(Int((fraction * 100).rounded()))%"
    }

    public static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
