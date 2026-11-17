import Foundation

/// Files a reply mentions that really exist ("workspace/site/index.html", "`~/Launchpad/Shared/plan.md`"), for
/// preview cards under the message. Looked up as absolute or ~ paths, then in each root (the bot's folder, its
/// workspace, a group's workspace). Only existing files, never folders; at most `limit`.
public enum FileMentions {
    public static let limit = 6
    static let extensions = "html?|png|jpe?g|gif|webp|heic|svg|pdf|mp4|mov|m4a|mp3|wav|md|csv|txt|json|zip|key|pages|numbers|docx|xlsx|pptx|fig|sketch|swift|py|js|ts|tsx|css"
    static let pattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_\-./~])(?:~|\.{1,2})?/?(?:[A-Za-z0-9_\-]+[./]+)*?[A-Za-z0-9_\-]+\.(?:"# + extensions + #")\b"#,
        options: [.caseInsensitive])
    static let quoted = try! NSRegularExpression(pattern: "`([^`\\n]+\\.[A-Za-z0-9]{2,5})`")

    /// The paths as written, in order: `quoted` ones first (they may contain spaces), then bare ones.
    public static func candidates(in text: String) -> [String] {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        var raws = quoted.matches(in: text, range: all).map { ns.substring(with: $0.range(at: 1)) }
        raws += pattern.matches(in: text, range: all).map { ns.substring(with: $0.range) }
        var seen = Set<String>()
        return raws.compactMap { c in
            let raw = c.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "`'\"()[]<>"))
            guard !raw.isEmpty, !raw.contains("://"), seen.insert(raw).inserted else { return nil }
            return raw
        }
    }

    public static func find(in text: String, roots: [URL], home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            fileManager fm: FileManager = .default) -> [URL] {
        var found: [URL] = []
        for raw in candidates(in: text) {
            var options: [URL] = []
            if raw == "~" || raw.hasPrefix("~/") {
                options.append(home.appendingPathComponent(String(raw.dropFirst(min(2, raw.count)))))
            } else if raw.hasPrefix("/") {
                options.append(URL(fileURLWithPath: raw))
            } else {
                for root in roots {
                    options.append(root.appendingPathComponent(raw))
                    // "workspace/x.png" when the root is already the workspace folder
                    if let first = raw.split(separator: "/").first, raw.contains("/"), root.lastPathComponent == first {
                        options.append(root.deletingLastPathComponent().appendingPathComponent(raw))
                    }
                }
            }
            let hit = options.first { url in
                var dir: ObjCBool = false
                return fm.fileExists(atPath: url.path, isDirectory: &dir) && !dir.boolValue
            }
            if let hit, !found.contains(hit.standardizedFileURL) { found.append(hit.standardizedFileURL) }
            if found.count >= limit { break }
        }
        return found
    }

    /// Where to look for a chat's files: the bot's folder and workspace, or the group's workspace and folder.
    public static func roots(for chat: ChatMeta, botId: String?, paths: LaunchpadPaths) -> [URL] {
        var roots: [URL] = []
        if chat.kind == .group, let g = chat.groupId {
            let dir = paths.groups.appendingPathComponent(g, isDirectory: true)
            roots += [dir.appendingPathComponent("workspace", isDirectory: true), dir]
        }
        if let b = botId ?? chat.botId { roots += [paths.workspace(b), paths.botDir(b)] }
        roots.append(paths.shared)
        return roots
    }

    /// The kind of preview to show (an SF Symbol name).
    public static func icon(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html", "htm": return "globe"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg": return "photo"
        case "pdf": return "doc.richtext"
        case "mp4", "mov": return "play.rectangle"
        case "m4a", "mp3", "wav": return "waveform"
        default: return "doc"
        }
    }
}

/// Turns a raw tool step into a short, human line with an icon (SF Symbol name).
public enum StepLabel {
    public static func describe(_ step: Step) -> (icon: String, text: String) {
        var input: [String: Any] = [:]
        if let d = step.detail, let obj = (try? JSONSerialization.jsonObject(with: Data(d.utf8))) as? [String: Any] { input = obj }
        // Codex keeps the raw command as the detail.
        if step.tool == "Bash", input["command"] == nil, let d = step.detail { input["command"] = d }
        return describe(tool: step.tool, input: input)
    }

    public static func describe(tool: String, input: [String: Any]) -> (icon: String, text: String) {
        func str(_ k: String) -> String { (input[k] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        func file(_ k: String) -> String { (str(k) as NSString).lastPathComponent }
        switch tool.lowercased() {
        case "bash", "run", "shell":
            let cmd = " " + str("command").lowercased()
            if cmd.contains(" grep ") || cmd.contains(" rg ") || cmd.contains(" find ") || cmd.contains(" ls") { return ("magnifyingglass", "Looking through the files") }
            if cmd.contains(" cat ") || cmd.contains(" sed -n") || cmd.contains(" head ") || cmd.contains(" tail ") { return ("doc.text", "Reading files") }
            if cmd.contains(" git ") { return ("arrow.triangle.branch", "Checking the project history") }
            if cmd.contains(" test") || cmd.contains("pytest") || cmd.contains("swift test") { return ("checkmark.seal", "Running the tests") }
            if cmd.contains("build") || cmd.contains("swiftc") || cmd.contains(" npm ") || cmd.contains(" make") || cmd.contains(" xcodebuild") { return ("hammer", "Building") }
            if cmd.contains(" curl ") || cmd.contains(" wget ") { return ("globe", "Fetching from the web") }
            if cmd.contains(" python") || cmd.contains(" node ") { return ("terminal", "Running a script") }
            return ("terminal", "Running a command")
        case "read": return ("doc.text", str("file_path").isEmpty ? "Reading a file" : "Reading \(file("file_path"))")
        case "edit", "multiedit": return ("pencil", str("file_path").isEmpty ? "Editing files" : "Editing \(file("file_path"))")
        case "write": return ("square.and.pencil", str("file_path").isEmpty ? "Writing a file" : "Writing \(file("file_path"))")
        case "notebookedit": return ("pencil", "Editing a notebook")
        case "glob", "grep": return ("magnifyingglass", "Looking through the files")
        case "websearch": return ("globe", str("query").isEmpty ? "Searching the web" : "Searching the web for “\(str("query"))”")
        case "webfetch": return ("safari", "Reading a web page")
        case "todowrite": return ("checklist", "Planning the next steps")
        case "task", "agent": return ("person.2", "Asking a helper")
        case "skill": return ("book", "Using a skill")
        case "toolsearch": return ("wrench.and.screwdriver", "Finding the right tool")
        default:
            if tool.hasPrefix("mcp__") { return mcp(tool) }
            return ("sparkle", tool)
        }
    }

    static func mcp(_ tool: String) -> (icon: String, text: String) {
        let parts = tool.components(separatedBy: "__")
        let server = parts.count > 1 ? parts[1] : tool
        let name = parts.count > 2 ? parts[2] : ""
        if server == ChatToolsSetup.serverKey {
            switch name {
            case "react": return ("face.smiling", "Reacting")
            case "send_gif": return ("photo.on.rectangle.angled", "Finding a GIF")
            case "start_poll": return ("chart.bar", "Starting a poll")
            case "vote": return ("checkmark.circle", "Voting")
            case "ask_user": return ("questionmark.bubble", "Asking you")
            case "share_plan": return ("list.bullet.clipboard", "Sharing the plan")
            case "create_routine", "list_routines": return ("clock", "Setting up a routine")
            case "use_app", "done_with_app": return ("macwindow", "Using an app")
            default: return ("bubble.left", "Using chat tools")
            }
        }
        return ("square.grid.2x2", "Using \(appName(server))")
    }

    /// "my_design_cf26" -> "Design"; "google_drive" -> "Google Drive".
    static func appName(_ server: String) -> String {
        var s = server
        if s.hasPrefix("my_") { s = String(s.dropFirst(3)) }
        let words = s.split(separator: "_")
        if words.count > 1, let last = words.last, last.count == 4, last.allSatisfy(\.isHexDigit) { s = words.dropLast().joined(separator: "_") }
        return s.split(whereSeparator: { $0 == "_" || $0 == "-" }).map { $0.capitalized }.joined(separator: " ")
    }
}
