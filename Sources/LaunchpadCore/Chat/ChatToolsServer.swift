import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The `launchpad-chat` MCP server (stdio, JSON-RPC 2.0, one message per line). Bots call these tools to react,
/// send GIFs, start polls and vote, ask you tappable questions, share a plan before a long task, set up routines,
/// and claim a Mac app so two bots don't drive the same one. See `ChatActions.swift` for the files it uses.
public final class ChatToolsServer {
    public static let name = "launchpad-chat"
    public static let version = "1.0"
    public static let defaultProtocolVersion = "2025-06-18"
    /// Longest a plan waits for your answer when there's no countdown (under the guard's 600 s tool timeout).
    public static let planTimeout: TimeInterval = 570
    /// App claims older than this are dropped.
    public static let claimLifetime: TimeInterval = 900

    public let config: ChatToolsConfig
    private let fm: FileManager
    private let now: () -> Date
    private let sleep: (TimeInterval) -> Void

    public init(config: ChatToolsConfig, fileManager: FileManager = .default, now: @escaping () -> Date = Date.init,
                sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.config = config
        self.fm = fileManager
        self.now = now
        self.sleep = sleep
    }

    // MARK: JSON-RPC

    /// Reads lines until the input ends.
    public func serve(readLine: () -> String?, write: (String) -> Void) {
        while let line = readLine() {
            if let out = handle(line: line) { write(out) }
        }
    }

    /// One request in, its response out (nil for notifications and blank lines).
    public func handle(line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let msg = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        let id = msg["id"]
        let method = msg["method"] as? String ?? ""
        let params = msg["params"] as? [String: Any] ?? [:]
        guard let id, !(id is NSNull) else { return nil }   // notifications (e.g. notifications/initialized)
        func result(_ r: [String: Any]) -> String? { encode(["jsonrpc": "2.0", "id": id, "result": r]) }
        switch method {
        case "initialize":
            return result([
                "protocolVersion": params["protocolVersion"] as? String ?? Self.defaultProtocolVersion,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": Self.name, "version": Self.version],
            ])
        case "ping":
            return result([:])
        case "tools/list":
            return result(["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            let (text, isError) = call(name, args)
            return result(["content": [["type": "text", "text": text]], "isError": isError])
        default:
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Unknown method \(method)"]])
        }
    }

    private func encode(_ obj: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Tools

    /// Runs a tool. Returns the text for the bot and whether it's an error.
    public func call(_ name: String, _ args: [String: Any]) -> (String, Bool) {
        switch name {
        case "react":
            let emoji = ChatOps.normalisedEmoji(str(args["emoji"]))
            guard !emoji.isEmpty else { return ("Give one emoji.", true) }
            return record(.react(emoji))
        case "send_gif":
            let search = str(args["search"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !search.isEmpty else { return ("Give a few search words.", true) }
            return record(.gif(String(search.prefix(100))))
        case "start_poll":
            guard let poll = ChatOps.makePoll(question: str(args["question"]), options: strings(args["options"])) else {
                return ("A poll needs a question and at least two options.", true)
            }
            return record(.poll(poll.question, poll.options))
        case "vote":
            guard let n = int(args["option"]), n >= 1 else { return ("Give the option number, starting at 1.", true) }
            let reason = str(args["reason"]).trimmingCharacters(in: .whitespacesAndNewlines)
            return record(.vote(n, reason: reason.isEmpty ? nil : String(reason.prefix(140))))
        case "ask_user":
            return askUser(args)
        case "share_plan":
            return sharePlan(args)
        case "create_routine":
            return createRoutine(args)
        case "list_routines":
            return (listRoutines(), false)
        case "use_app":
            return useApp(args)
        case "done_with_app":
            return doneWithApp(args)
        default:
            return ("Unknown tool \(name).", true)
        }
    }

    private func str(_ v: Any?) -> String { v as? String ?? (v.map { "\($0)" } ?? "") }
    private func strings(_ v: Any?) -> [String] { (v as? [Any])?.map { "\($0)" } ?? [] }
    private func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double, d == d.rounded() { return Int(d) }
        if let s = v as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// Appends one action line to the run's actions file.
    func append(_ action: ChatAction) -> Bool {
        guard let path = config.actionsFile, !path.isEmpty, var line = try? action.line() else { return false }
        line.append(0x0A)
        let url = URL(fileURLWithPath: path)
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: path) { return fm.createFile(atPath: path, contents: line) }
        guard let h = try? FileHandle(forWritingTo: url) else { return false }
        defer { try? h.close() }
        do {
            try h.seekToEnd()
            try h.write(contentsOf: line)
            return true
        } catch {
            return false
        }
    }

    private func record(_ action: ChatAction) -> (String, Bool) {
        var a = action
        a.at = now()
        return append(a) ? ("Done, it's in the chat.", false) : ("Couldn't do that right now.", true)
    }

    private func askUser(_ args: [String: Any]) -> (String, Bool) {
        let raw = (args["questions"] as? [[String: Any]]) ?? []
        let items: [QuestionCard.Item] = raw.prefix(3).compactMap { q in
            let text = str(q["question"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let opts = strings(q["options"]).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !text.isEmpty, opts.count >= 2 else { return nil }
            return QuestionCard.Item(text: text, options: Array(opts.prefix(6)), multi: q["multiple"] as? Bool ?? false)
        }
        guard !items.isEmpty, items.count == min(raw.count, 3) else {
            return ("Give one to three questions, each with at least two short options.", true)
        }
        var a = ChatAction(tool: .askUser, questions: items)
        a.at = now()
        guard append(a) else { return ("Ask in plain text instead.", true) }
        return ("Shown to the user as tappable choices. End your reply now with at most one short line; don't repeat the questions. Their answer arrives as their next message.", false)
    }

    /// Shows a plan card and waits for Start / Cancel. With a countdown, no answer means start.
    private func sharePlan(_ args: [String: Any]) -> (String, Bool) {
        let message = str(args["message"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let steps = strings(args["steps"]).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard let answerPath = config.planAnswerFile, !answerPath.isEmpty else { return (Self.planReply("start"), false) }
        try? fm.removeItem(atPath: answerPath)
        var a = ChatAction(tool: .sharePlan, message: message.isEmpty ? "On it." : message, steps: Array(steps.prefix(4)))
        a.at = now()
        guard append(a) else { return (Self.planReply("start"), false) }
        let wait = config.planWait
        let deadline = now().addingTimeInterval(wait > 0 ? Double(wait) + 2 : Self.planTimeout)
        while now() < deadline {
            if let data = fm.contents(atPath: answerPath) {
                try? fm.removeItem(atPath: answerPath)
                let answer = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !answer.isEmpty { return (Self.planReply(answer), false) }
            }
            sleep(0.25)
        }
        return (Self.planReply(wait > 0 ? "start" : ""), false)
    }

    static func planReply(_ answer: String) -> String {
        switch answer.lowercased() {
        case "start": return "start: the user is happy with the plan. Do it now."
        case "cancel": return "cancel: don't start. Ask in one short sentence what they want instead."
        case "": return "The user hasn't pressed Start yet. Don't start; end your reply in one line saying you'll begin when they say go."
        default: return "The user answered: \(answer). Follow that."
        }
    }

    // MARK: Routines

    private func loadRoutines() -> [Routine] {
        guard let path = config.routinesFile, let data = fm.contents(atPath: path) else { return [] }
        return (try? JSONCoding.decoder().decode([Routine].self, from: data)) ?? []
    }

    func listRoutines() -> String {
        let all = loadRoutines()
        guard !all.isEmpty else { return "No routines yet." }
        return all.map { r in
            "- \(r.name): \(r.summary)\(r.enabled ? "" : " (off)") — \(r.message.replacingOccurrences(of: "\n", with: " ").prefix(200))"
        }.joined(separator: "\n")
    }

    private func createRoutine(_ args: [String: Any]) -> (String, Bool) {
        guard let target = config.routineTarget, !target.isEmpty else { return ("Routines can't be set up from this chat.", true) }
        var obj = args
        if obj["message"] == nil, let p = obj["prompt"] { obj["message"] = p }
        obj["target"] = target
        if obj["catchUp"] == nil, let c = obj["catch_up"] { obj["catchUp"] = c }
        obj["ownChat"] = false
        obj["enabled"] = true
        guard JSONSerialization.isValidJSONObject(obj), let data = try? JSONSerialization.data(withJSONObject: obj) else {
            return ("The routine couldn't be read.", true)
        }
        let id = String(target.split(separator: ":", maxSplits: 1).last ?? "")
        let isGroup = target.hasPrefix("group:")
        let checked = RoutineRequests.add(json: data, to: loadRoutines(), bots: isGroup ? [] : [id], groups: isGroup ? [id] : [],
                                          now: now(), fileManager: fm)
        switch checked {
        case .failure(let e):
            return (e.localizedDescription, true)
        case .success(let made):
            guard let request = try? JSONDecoder().decode(RoutineRequest.self, from: data) else { return ("The routine couldn't be read.", true) }
            var a = ChatAction(tool: .createRoutine, routine: request)
            a.at = now()
            guard append(a) else { return ("Couldn't save a routine right now.", true) }
            return ("Saved: \(made.routine.name), \(made.routine.summary.lowercased()). It's added to the user's Routines as soon as your reply ends and runs in this chat. Tell them in one line what it does and when.", false)
        }
    }

    // MARK: App claims

    private func withClaims(_ change: (inout [[String: Any]]) -> String) -> String {
        guard let path = config.claimsFile, !path.isEmpty else { return "ok" }
        try? fm.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(path + ".lock", O_RDWR | O_CREAT, 0o644)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        var list = (fm.contents(atPath: path).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [[String: Any]]) ?? []
        let iso = ISO8601DateFormatter()
        let t = now()
        list = list.filter { c in
            (c["at"] as? String).flatMap(iso.date(from:)).map { t.timeIntervalSince($0) < Self.claimLifetime } ?? false
        }
        let answer = change(&list)
        if let data = try? JSONSerialization.data(withJSONObject: list, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        return answer
    }

    private var me: String { config.botId ?? config.botName }

    private func useApp(_ args: [String: Any]) -> (String, Bool) {
        let app = str(args["app"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !app.isEmpty else { return ("Say which app.", true) }
        let purpose = str(args["purpose"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let iso = ISO8601DateFormatter()
        let text = withClaims { list in
            if let other = list.first(where: { ($0["app"] as? String)?.lowercased() == app.lowercased() && $0["botId"] as? String != me }) {
                let who = other["bot"] as? String ?? "A teammate"
                let why = (other["purpose"] as? String).flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""
                return "\(who) is using \(app) right now\(why). Work in a different window of it, use another way, or try again in a few minutes."
            }
            list.removeAll { ($0["app"] as? String)?.lowercased() == app.lowercased() }
            var claim: [String: Any] = ["app": app, "bot": config.botName, "botId": me, "at": iso.string(from: now())]
            if !purpose.isEmpty { claim["purpose"] = purpose }
            list.append(claim)
            return "ok: \(app) is yours. Call done_with_app when you finish."
        }
        return (text, false)
    }

    private func doneWithApp(_ args: [String: Any]) -> (String, Bool) {
        let app = str(args["app"]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let text = withClaims { list in
            list.removeAll { $0["botId"] as? String == me && (app.isEmpty || ($0["app"] as? String)?.lowercased() == app) }
            return "ok"
        }
        return (text, false)
    }

    // MARK: Tool list

    public static let toolNames = ["create_routine", "list_routines", "ask_user", "share_plan", "react", "send_gif",
                                   "start_poll", "vote", "use_app", "done_with_app"]

    public static var tools: [[String: Any]] {
        let obj = "object", s = "string"
        return [
            ["name": "create_routine",
             "description": "Set up a routine: a message this chat gets on a schedule or when something happens (e.g. \"every weekday at 8:30, sum up my calendar\"). Use it when the user asks for something repeated or timed, or a reminder.",
             "inputSchema": ["type": obj, "properties": [
                "name": ["type": s, "description": "Short name, e.g. Morning briefing"],
                "message": ["type": s, "description": "What to do each time, written as the message you'll receive"],
                "trigger": ["type": obj, "description": "When it runs", "properties": [
                    "type": ["type": s, "enum": ["once", "hourly", "daily", "weekdays", "weekly", "every", "folder", "webhook"]],
                    "hour": ["type": "integer", "minimum": 0, "maximum": 23],
                    "minute": ["type": "integer", "minimum": 0, "maximum": 59],
                    "weekday": ["type": "integer", "minimum": 1, "maximum": 7, "description": "weekly: 1 = Sunday … 7 = Saturday"],
                    "minutes": ["type": "integer", "minimum": 5, "description": "every: how many minutes apart"],
                    "at": ["type": s, "description": "once: date and time, ISO 8601 with time zone, e.g. 2026-12-01T09:00:00Z"],
                    "folder": ["type": s, "description": "folder: an existing folder to watch for new files"]],
                    "required": ["type"]] as [String: Any],
                "catchUp": ["type": "boolean", "description": "Run once when the Mac wakes if a run was missed"]] as [String: Any],
                "required": ["name", "message", "trigger"]] as [String: Any]],
            ["name": "list_routines", "description": "List the user's routines (name, schedule, what they do).",
             "inputSchema": ["type": obj, "properties": [String: Any]()]],
            ["name": "ask_user",
             "description": "Ask the user one to three questions as tappable choices (they can also type their own answer). Use it instead of writing questions in text when you need a decision, a preference or missing details. Then end your reply; the answer arrives as the user's next message.",
             "inputSchema": ["type": obj, "properties": [
                "questions": ["type": "array", "minItems": 1, "maxItems": 3, "items": ["type": obj, "properties": [
                    "question": ["type": s],
                    "options": ["type": "array", "items": ["type": s], "minItems": 2, "maxItems": 6, "description": "Short answers to tap"],
                    "multiple": ["type": "boolean", "description": "True when more than one answer can be picked"]] as [String: Any],
                    "required": ["question", "options"]] as [String: Any]] as [String: Any]] as [String: Any],
                "required": ["questions"]] as [String: Any]],
            ["name": "share_plan",
             "description": "Before a long task (more than about a minute: a build, a fix, research, changes in many files), show the user your plan as a card with Start and Cancel, and wait for the answer. Returns \"start\" (go ahead), that the user hasn't answered yet (don't start), \"cancel\" (don't start; ask in one sentence what they want instead), or the user's own words to follow. Not for quick answers or small changes.",
             "inputSchema": ["type": obj, "properties": [
                "message": ["type": s, "description": "One short sentence: you're on it, and what the work is."],
                "steps": ["type": "array", "items": ["type": s], "minItems": 1, "maxItems": 4, "description": "Up to four short steps, one line each."]] as [String: Any],
                "required": ["message", "steps"]] as [String: Any]],
            ["name": "react", "description": "React to the user's latest message with an emoji, like a tapback in a chat app.",
             "inputSchema": ["type": obj, "properties": ["emoji": ["type": s, "description": "One emoji, e.g. 🎉"]], "required": ["emoji"]] as [String: Any]],
            ["name": "send_gif", "description": "Send a GIF that matches a few search words.",
             "inputSchema": ["type": obj, "properties": ["search": ["type": s]], "required": ["search"]] as [String: Any]],
            ["name": "start_poll", "description": "Start a poll in the chat that people can tap to vote in.",
             "inputSchema": ["type": obj, "properties": [
                "question": ["type": s],
                "options": ["type": "array", "items": ["type": s], "minItems": 2, "maxItems": 8]] as [String: Any],
                "required": ["question", "options"]] as [String: Any]],
            ["name": "vote", "description": "Vote in the latest poll in this chat.",
             "inputSchema": ["type": obj, "properties": [
                "option": ["type": "integer", "minimum": 1, "description": "Option number, starting at 1"],
                "reason": ["type": s, "description": "One short sentence on why"]] as [String: Any],
                "required": ["option"]] as [String: Any]],
            ["name": "use_app",
             "description": "Before using a Mac app with your computer tools, claim it so teammates don't use the same app at the same time. Returns ok, or who is using it.",
             "inputSchema": ["type": obj, "properties": [
                "app": ["type": s, "description": "App name, like Figma or Safari"],
                "purpose": ["type": s, "description": "A few words on what you're doing"]] as [String: Any],
                "required": ["app"]] as [String: Any]],
            ["name": "done_with_app", "description": "Let go of an app you claimed with use_app. Leave app out to let go of all of them.",
             "inputSchema": ["type": obj, "properties": ["app": ["type": s]]] as [String: Any]],
        ]
    }
}
