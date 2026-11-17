import Foundation

/// Turns `claude -p --output-format stream-json --verbose --include-partial-messages` lines into RunEvents.
///
/// Verified against Claude Code 2.1.x output:
/// - `{"type":"system","subtype":"init","session_id":…}`
/// - `{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":…}}}`
/// - `{"type":"assistant","message":{"id":…,"content":[{"type":"tool_use","id","name","input"} | {"type":"text"}]}}`
/// - `{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id","content","is_error"}]}}`
/// - `{"type":"result","subtype":"success","is_error":false,"result":…,"session_id":…,"total_cost_usd":…}`
/// Events from sub-agents (non-null `parent_tool_use_id`) are skipped; their parent step covers them.
public final class ClaudeStreamParser: StreamParser {
    private var messagesWithDeltas = Set<String>()
    private var currentMessageId: String?
    private var announcedSession = false
    public private(set) var isComplete = false
    public private(set) var lastError: String?

    public init() {}

    public func parse(line: String) -> [RunEvent] {
        guard let obj = jsonObject(line), let type = obj["type"] as? String else { return [] }
        if let parent = obj["parent_tool_use_id"], !(parent is NSNull) { return [] }

        switch type {
        case "system":
            if obj["subtype"] as? String == "init", let sid = obj["session_id"] as? String, !announcedSession {
                announcedSession = true
                return [.sessionStarted(sid)]
            }
            return []

        case "stream_event":
            guard let event = obj["event"] as? [String: Any], let etype = event["type"] as? String else { return [] }
            if etype == "message_start" {
                currentMessageId = (event["message"] as? [String: Any])?["id"] as? String
                return []
            }
            if etype == "content_block_delta",
               let delta = event["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String, !text.isEmpty {
                if let id = (obj["api_message_id"] as? String) ?? currentMessageId {
                    messagesWithDeltas.insert(id)
                }
                return [.textDelta(text)]
            }
            return []

        case "assistant":
            guard let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return [] }
            let messageId = message["id"] as? String
            var events: [RunEvent] = []
            for block in content {
                switch block["type"] as? String {
                case "tool_use":
                    let id = block["id"] as? String ?? UUID().uuidString
                    let name = block["name"] as? String ?? "tool"
                    let input = block["input"] as? [String: Any] ?? [:]
                    events.append(.stepStarted(
                        id: id, tool: name,
                        title: ToolSummary.title(tool: name, input: input),
                        detail: ToolSummary.pretty(input)
                    ))
                case "text":
                    // Only used when the text wasn't already streamed as deltas.
                    if let text = block["text"] as? String, !text.isEmpty,
                       messageId.map({ !messagesWithDeltas.contains($0) }) ?? true {
                        events.append(.text(text))
                    }
                default:
                    break
                }
            }
            return events

        case "user":
            guard let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return [] }
            return content.compactMap { block in
                guard block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String else { return nil }
                let failed = block["is_error"] as? Bool ?? false
                return .stepFinished(id: id, output: ToolSummary.clip(Self.resultText(block["content"])), failed: failed)
            }

        case "result":
            isComplete = true
            var events: [RunEvent] = []
            if let cost = obj["total_cost_usd"] as? Double { events.append(.cost(cost)) }
            let isError = obj["is_error"] as? Bool ?? false
            let subtype = obj["subtype"] as? String ?? ""
            if !isError && subtype == "success" {
                events.append(.finished(resultText: obj["result"] as? String))
            } else {
                var message = (obj["result"] as? String) ?? ""
                if message.isEmpty, let errors = obj["errors"] as? [String] { message = errors.joined(separator: "\n") }
                if message.isEmpty { message = "Claude Code stopped (\(subtype.isEmpty ? "error" : subtype))." }
                lastError = message
                events.append(.engineError(message))
            }
            return events

        default:
            return []
        }
    }

    static func resultText(_ content: Any?) -> String? {
        if let s = content as? String { return s }
        if let blocks = content as? [[String: Any]] {
            let texts = blocks.compactMap { $0["text"] as? String }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        }
        return nil
    }
}

public protocol StreamParser: AnyObject {
    func parse(line: String) -> [RunEvent]
    /// True once the engine reported the end of its turn (success or failure).
    var isComplete: Bool { get }
    /// The last error text the engine reported, used if the process exits unexpectedly.
    var lastError: String? { get }
}
