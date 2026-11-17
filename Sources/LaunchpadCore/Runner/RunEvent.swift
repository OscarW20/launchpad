import Foundation

/// What happens during one engine run, in a form shared by Claude Code and Codex.
public enum RunEvent: Equatable, Sendable {
    /// The engine's session/thread id. Save it to resume this chat next time.
    case sessionStarted(String)
    /// A piece of streamed reply text.
    case textDelta(String)
    /// A whole block of reply text (engines that don't stream token by token).
    case text(String)
    case stepStarted(id: String, tool: String, title: String, detail: String?)
    case stepFinished(id: String, output: String?, failed: Bool)
    case cost(Double)
    /// The run finished. `resultText` is the engine's final answer, if it reports one.
    case finished(resultText: String?)
    /// Raw error text reported by the engine. The runner turns this into `.failed`.
    case engineError(String)
    /// The run failed, explained in plain English.
    case failed(RunFailure)
    /// You pressed Stop.
    case stopped
}

/// Plain-English titles for tool calls, shared by both engines.
enum ToolSummary {
    static func title(tool: String, input: [String: Any]) -> String {
        func str(_ key: String) -> String? {
            (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        func file(_ key: String) -> String {
            guard let p = str(key) else { return "a file" }
            return (p as NSString).lastPathComponent
        }
        switch tool {
        case "Read": return "Read \(file("file_path"))"
        case "Write": return "Wrote \(file("file_path"))"
        case "Edit", "MultiEdit": return "Edited \(file("file_path"))"
        case "NotebookEdit": return "Edited \(file("notebook_path"))"
        case "Bash": return "Ran \(code(str("command") ?? "a command"))"
        case "Glob": return "Looked for \(code(str("pattern") ?? "files"))"
        case "Grep": return "Searched for \(code(str("pattern") ?? "text"))"
        case "WebSearch": return "Searched the web for “\(short(str("query") ?? ""))”"
        case "WebFetch": return "Opened \(host(str("url")))"
        case "TodoWrite": return "Updated the plan"
        case "Task", "Agent": return "Asked a helper: \(short(str("description") ?? "a task"))"
        case "Skill": return "Used the \(str("skill") ?? str("name") ?? "a") skill"
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.split(separator: "_", omittingEmptySubsequences: true)
                if parts.count >= 3 {
                    return "Used \(parts.dropFirst(2).joined(separator: "_")) on \(parts[1])"
                }
            }
            return "Used \(tool)"
        }
    }

    static func code(_ s: String) -> String {
        let firstLine = s.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? s
        return "`\(short(firstLine, max: 60))`"
    }

    static func short(_ s: String, max: Int = 60) -> String {
        s.count > max ? String(s.prefix(max - 1)) + "…" : s
    }

    static func host(_ url: String?) -> String {
        guard let url, let host = URL(string: url)?.host else { return "a web page" }
        return host
    }

    static func pretty(_ input: [String: Any]) -> String? {
        if input.isEmpty { return nil }
        if input.count == 1, let only = input.values.first as? String { return only }
        guard JSONSerialization.isValidJSONObject(input),
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Tool output can be huge; keep what's useful to glance at.
    static func clip(_ s: String?, max: Int = 4000) -> String? {
        guard let s, !s.isEmpty else { return nil }
        if s.count <= max { return s }
        return String(s.prefix(max)) + "\n… (\(s.count - max) more characters)"
    }
}

func jsonObject(_ line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return obj
}
