import Foundation

/// Turns `codex exec --json` lines into RunEvents.
///
/// Verified against codex-cli 0.169:
/// - `{"type":"thread.started","thread_id":…}`
/// - `{"type":"item.started"|"item.completed","item":{"id","type":"agent_message"|"command_execution"|"file_change"|"mcp_tool_call"|"web_search"|"todo_list"|"reasoning"|"error",…}}`
/// - `{"type":"turn.completed","usage":{…}}`, `{"type":"turn.failed","error":{"message"}}`
/// - `{"type":"error","message":"Reconnecting… 2/5 (…)"}` (retries; not final on their own)
public final class CodexStreamParser: StreamParser {
    private var startedSteps = Set<String>()
    public private(set) var isComplete = false
    public private(set) var lastError: String?

    public init() {}

    public func parse(line: String) -> [RunEvent] {
        guard let obj = jsonObject(line), let type = obj["type"] as? String else { return [] }
        switch type {
        case "thread.started":
            if let id = obj["thread_id"] as? String { return [.sessionStarted(id)] }
            return []
        case "item.started":
            guard let item = obj["item"] as? [String: Any] else { return [] }
            return start(item).map { [$0] } ?? []
        case "item.completed":
            guard let item = obj["item"] as? [String: Any] else { return [] }
            return complete(item)
        case "turn.completed":
            isComplete = true
            var events: [RunEvent] = []
            if let usage = obj["usage"] as? [String: Any] {
                let tokens = ((usage["input_tokens"] as? Int) ?? 0) + ((usage["output_tokens"] as? Int) ?? 0)
                if tokens > 0 { events.append(.usage(UsageReport(engine: .codex, tokens: tokens))) }
            }
            events.append(.finished(resultText: nil))
            return events
        case "turn.failed":
            isComplete = true
            let message = ((obj["error"] as? [String: Any])?["message"] as? String) ?? lastError ?? "Codex couldn't finish this turn."
            lastError = message
            return [.engineError(message)]
        case "error":
            if let m = obj["message"] as? String { lastError = m }
            return []
        default:
            return []
        }
    }

    private func start(_ item: [String: Any]) -> RunEvent? {
        guard let id = item["id"] as? String, let itype = item["type"] as? String else { return nil }
        guard let (tool, title, detail) = describe(itype, item) else { return nil }
        startedSteps.insert(id)
        return .stepStarted(id: id, tool: tool, title: title, detail: detail)
    }

    private func complete(_ item: [String: Any]) -> [RunEvent] {
        guard let id = item["id"] as? String, let itype = item["type"] as? String else { return [] }
        switch itype {
        case "agent_message":
            if let text = item["text"] as? String, !text.isEmpty { return [.text(text)] }
            return []
        case "reasoning", "error":
            // Reasoning is private; item errors are recoverable warnings (e.g. transport fallback).
            return []
        default:
            var events: [RunEvent] = []
            if !startedSteps.contains(id), let started = start(item) { events.append(started) }
            guard startedSteps.contains(id) else { return events }
            let status = item["status"] as? String
            var failed = status == "failed" || status == "declined"
            var output: String?
            switch itype {
            case "command_execution":
                output = item["aggregated_output"] as? String
                if let code = item["exit_code"] as? Int, code != 0 { failed = true }
            case "mcp_tool_call":
                if let err = (item["error"] as? [String: Any])?["message"] as? String {
                    output = err
                    failed = true
                } else if let result = item["result"] {
                    output = Self.stringify(result)
                }
            default:
                break
            }
            events.append(.stepFinished(id: id, output: ToolSummary.clip(output), failed: failed))
            return events
        }
    }

    private func describe(_ itype: String, _ item: [String: Any]) -> (String, String, String?)? {
        switch itype {
        case "command_execution":
            let cmd = item["command"] as? String ?? "a command"
            return ("Bash", "Ran \(ToolSummary.code(Self.unwrapShell(cmd)))", cmd)
        case "file_change":
            let changes = item["changes"] as? [[String: Any]] ?? []
            let names = changes.compactMap { ($0["path"] as? String).map { ($0 as NSString).lastPathComponent } }
            let title = names.isEmpty ? "Edited files" : "Edited \(names.prefix(3).joined(separator: ", "))\(names.count > 3 ? " and \(names.count - 3) more" : "")"
            let detail = changes.map { "\($0["kind"] as? String ?? "update"): \($0["path"] as? String ?? "?")" }.joined(separator: "\n")
            return ("Edit", title, detail.isEmpty ? nil : detail)
        case "mcp_tool_call":
            let server = item["server"] as? String ?? "a connector"
            let tool = item["tool"] as? String ?? "a tool"
            return ("mcp__\(server)__\(tool)", "Used \(tool) on \(server)", item["arguments"].flatMap(Self.stringify))
        case "web_search":
            let q = item["query"] as? String ?? ""
            return ("WebSearch", "Searched the web for “\(ToolSummary.short(q))”", nil)
        case "todo_list":
            let items = item["items"] as? [[String: Any]] ?? []
            let detail = items.map { (($0["completed"] as? Bool) == true ? "✓ " : "○ ") + ($0["text"] as? String ?? "") }.joined(separator: "\n")
            return ("TodoWrite", "Updated the plan", detail.isEmpty ? nil : detail)
        default:
            return nil
        }
    }

    /// Codex reports commands like `/bin/zsh -lc 'npm test'`; show just `npm test`.
    static func unwrapShell(_ cmd: String) -> String {
        for prefix in ["/bin/zsh -lc ", "/bin/bash -lc ", "bash -lc ", "zsh -lc ", "/bin/sh -c "] where cmd.hasPrefix(prefix) {
            var rest = String(cmd.dropFirst(prefix.count))
            if rest.count >= 2, let f = rest.first, (f == "'" || f == "\""), rest.last == f {
                rest = String(rest.dropFirst().dropLast())
            }
            return rest
        }
        return cmd
    }

    static func stringify(_ value: Any) -> String? {
        if let s = value as? String { return s }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
