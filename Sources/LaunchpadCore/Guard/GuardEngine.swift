import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// Launchpad's permission guard. Claude Code's PreToolUse hook runs `launchpad-guard hook <rules.json> …` before
// every tool call. The call is sorted into categories (send or post, delete, spend, change, shell outside the bot's
// folder, computer use), and the bot's rule for each decides: allow (say nothing, Claude's own permissions apply),
// never (deny, with a reason the bot sees) or ask (show an approval card and wait for your answer).
// Locked skills and Launchpad's own files can never be changed, whatever the rules say.
// When it can't tell what a command does, it asks rather than letting it through; with no rules it says no.

/// What the guard knows about one bot. The app writes it as JSON (`GuardRulesFile`); the hook reads it.
public struct GuardConfig: Equatable, Sendable {
    public var bot = "The bot"
    /// The bot's own folder: deleting files here can be undone from the chat, so it never needs asking.
    public var folder = ""
    /// Folders the bot may work in freely (its own, its groups' shared folders).
    public var roots: [String] = []
    /// Category raw value -> "ask" / "allow" / "never". Missing = the category's default.
    public var rules: [String: String] = [:]
    /// "category:tool" pairs you chose "Always allow" for.
    public var alwaysAllowed: [String] = []
    /// Skill folders the bot may not change.
    public var locked: [String] = []
    /// Launchpad's own files and folders, which bots may never change.
    public var protected: [String] = []
    /// Where the app writes your answers to approval cards: a folder the bot can't write, so a bot can't approve
    /// its own request.
    public var answers = ""
    /// "Always allow" is off for writes (or the bot is locked down): writes always ask.
    public var noAlwaysForWrites = false
    /// Your own "change" commands (regular expressions).
    public var changePatterns: [String] = []
    /// MCP servers whose tools never need asking (the app's own).
    public var trustedServers: [String] = []
    /// MCP servers that click and type on your Mac.
    public var computerServers: [String] = ["computer", "computer-use", "computer_use"]
    /// The name of Launchpad's data folder, protected in any spelling.
    public var dataFolderName = ".launchpad"

    public init() {}

    public init(json: [String: Any]) {
        bot = json["bot"] as? String ?? bot
        folder = json["folder"] as? String ?? ""
        roots = json["roots"] as? [String] ?? []
        rules = json["rules"] as? [String: String] ?? [:]
        alwaysAllowed = json["alwaysAllowed"] as? [String] ?? []
        locked = json["locked"] as? [String] ?? []
        protected = json["protected"] as? [String] ?? []
        answers = json["answers"] as? String ?? ""
        noAlwaysForWrites = json["noAlwaysForWrites"] as? Bool ?? false
        changePatterns = json["changePatterns"] as? [String] ?? []
        trustedServers = json["trustedServers"] as? [String] ?? []
        computerServers = json["computerServers"] as? [String] ?? computerServers
        dataFolderName = json["dataFolderName"] as? String ?? dataFolderName
    }

    public var json: [String: Any] {
        ["bot": bot, "folder": folder, "roots": roots, "rules": rules, "alwaysAllowed": alwaysAllowed,
         "locked": locked, "protected": protected, "answers": answers, "noAlwaysForWrites": noAlwaysForWrites,
         "changePatterns": changePatterns, "trustedServers": trustedServers, "computerServers": computerServers,
         "dataFolderName": dataFolderName]
    }

    /// Never always wins. "Always allow" only loosens Ask, and never for the Terminal: one command says
    /// nothing about the next.
    public func rule(_ c: ApprovalCategory, tool: String) -> ApprovalRule {
        let r = rules[c.rawValue].flatMap(ApprovalRule.init(rawValue:)) ?? c.defaultRule
        if r == .never { return r }
        if noAlwaysForWrites, ApprovalCategory.writes.contains(c) { return r }
        if tool != "Bash", alwaysAllowed.contains(BotRules.key(c, tool: tool)) { return .allow }
        return r
    }
}

/// The guard's answer for one tool call.
public enum GuardVerdict: Equatable, Sendable {
    case pass
    case deny(String)
    /// Needs your OK: the category, and what the approval card shows.
    case ask(ApprovalCategory, String)
}

public enum GuardEngine {
    // MARK: Deciding

    public static func decide(tool: String, input: [String: Any], cwd: String, config: GuardConfig) -> GuardVerdict {
        if let reason = blocked(tool: tool, input: input, cwd: cwd, config: config) { return .deny(reason) }
        let found = findings(tool: tool, input: input, cwd: cwd, config: config)
        if let never = found.first(where: { config.rule($0.category, tool: tool) == .never }) {
            return .deny("\(config.bot) isn't allowed to do this (\(never.category.title.lowercased())): the user turned it off in this bot's permissions. Don't try another way to do the same thing. Tell the user what you wanted to do, so they can do it themselves or change the setting.")
        }
        if let ask = found.first(where: { config.rule($0.category, tool: tool) == .ask }) {
            return .ask(ask.category, describe(tool: tool, input: input, trigger: ask.trigger))
        }
        return .pass
    }

    static let fileTools: Set<String> = ["Write", "Edit", "MultiEdit", "NotebookEdit"]

    /// Locked skills and Launchpad's own files: always denied.
    public static func blocked(tool: String, input: [String: Any], cwd: String, config: GuardConfig) -> String? {
        if fileTools.contains(tool), let raw = (input["file_path"] as? String) ?? (input["notebook_path"] as? String) {
            let path = ShellPath.resolve(raw, cwd: cwd)
            if let skill = config.locked.first(where: { ShellPath.inside(path, $0) }) { return lockedReason(skill) }
            if config.protected.contains(where: { ShellPath.inside(path, $0) }) || namesDataFolder(path, config: config)
                || isSettingsFile(path) { return protectedReason }
        }
        if tool == "Bash", let command = input["command"] as? String {
            return blockedShell(command, cwd: cwd, config: config)
        }
        return nil
    }

    static let destructiveCommands: Set<String> = ["rm", "rmdir", "unlink", "shred", "srm", "trash", "mv", "chmod", "chflags", "chown", "rsync"]
    static let copyCommands: Set<String> = ["cp", "ditto", "rsync", "install", "ln", "patch"]
    static let writingCommands: Set<String> = ["tee", "truncate", "touch", "dd", "mkdir", "xattr", "setfile"]

    static func blockedShell(_ command: String, cwd: String, config: GuardConfig) -> String? {
        let text = normalized(command)
        if writes(command) {
            if namesDataFolder(command, config: config) { return protectedReason }
            for skill in config.locked where mentions(text, skill, cwd: cwd) { return lockedReason(skill) }
            for p in config.protected where mentions(text, p, cwd: cwd) { return protectedReason }
        }
        // Path by path, following cd: writing into a locked skill or a protected file, or removing a folder above one.
        let guarded = config.locked.map { ($0, lockedReason($0)) } + config.protected.map { ($0, protectedReason) }
        for (c, cur) in ShellParser.walk(command, cwd: cwd) {
            guard let head = c.head else { continue }
            if head == "find", let roots = deleteTargets(c, command: command) {
                // find … -delete: its folders, and whether its filters could pick out a locked skill's files.
                for (dir, reason) in guarded {
                    let name = (dir as NSString).lastPathComponent
                    for r in roots {
                        let path = ShellPath.resolve(r, cwd: cur ?? cwd)
                        if ShellPath.inside(path, dir) || (ShellPath.inside(dir, path) && findCouldMatch(c, name: name)) { return reason }
                    }
                }
                continue
            }
            let destructive = destructiveCommands.contains(head) || (head == "git" && c.args.first == "clean")
            let copies = copyCommands.contains(head)
            let edits = writingCommands.contains(head) || (head == "sed" && c.args.contains { $0.hasPrefix("-i") })
                || (head == "perl" && c.args.contains { $0.hasPrefix("-i") || $0.hasPrefix("-pi") })
            let options = { (w: String) -> Bool in w.hasPrefix("-") && !w.contains("/") }
            var targets = c.outputs
            if destructive || edits || head == "tar" || head == "unzip" {
                targets += c.args.filter { !options($0) }
            } else if copies, let dest = c.args.last(where: { !options($0) }) {
                targets.append(dest)   // cp's sources are only read
            }
            for t in targets {
                let raw = t.hasPrefix("-") ? t.firstIndex(of: "/").map { String(t[$0...]) } ?? t : t
                let path = ShellPath.resolve(raw, cwd: cur ?? cwd)
                if isSettingsFile(path) { return protectedReason }
                let globbed = raw.contains { "*?[".contains($0) }
                for (dir, reason) in guarded {
                    if ShellPath.inside(path, dir) { return reason }
                    if globbed, globCouldReach(path, dir) { return reason }
                    // Removing or moving a folder that holds it, or copying straight into its parent folder.
                    if destructive, ShellPath.inside(dir, path) { return reason }
                    if copies, ShellPath.inside(dir, path), ShellPath.inside(path, (dir as NSString).deletingLastPathComponent) { return reason }
                }
            }
        }
        return nil
    }

    /// Could find's -name / -path filters match a file in the skill folder `name` (its SKILL.md, or the folder)?
    /// With no filter, everything matches.
    static func findCouldMatch(_ c: ShellCommand, name: String) -> Bool {
        var patterns: [String] = []
        for (i, w) in c.words.enumerated() where ["-name", "-iname", "-path", "-ipath", "-wholename", "-regex", "-iregex"].contains(w) {
            guard i + 1 < c.words.count else { return true }
            if w.contains("regex") { return true }   // too hard to tell
            patterns.append(c.words[i + 1].lowercased())
        }
        if patterns.isEmpty { return true }
        let n = name.lowercased()
        let candidates = ["skill.md", n, "./.claude/skills/\(n)/skill.md", "./.claude/skills/\(n)", "./skills/\(n)/skill.md", "./\(n)/skill.md"]
        return patterns.contains { p in candidates.contains { fnmatch(p, $0, 0) == 0 } }
    }

    public static func lockedReason(_ skillDir: String) -> String {
        "The \((skillDir as NSString).lastPathComponent) skill is locked: the user locked it so bots can't change it. Don't edit it another way. If it needs changing, tell the user what you'd change."
    }

    public static let protectedReason = "That's one of Launchpad's own files (permissions, approvals or settings), which bots can't change. If a permission is in the way, tell the user; they can change it in the bot's permissions."

    public static let unreadableReason = "Launchpad couldn't read this bot's safety rules, so this can't run. Tell the user: try again, and if it keeps happening, reinstall the app."

    /// Launchpad's data folder in any spelling (escaped spaces, quotes, other case, globs), or one of its
    /// folders named through a variable we can't see ("$D/rules/x.json").
    static func namesDataFolder(_ command: String, config: GuardConfig) -> Bool {
        let text = normalized(command)
        let name = NSRegularExpression.escapedPattern(for: config.dataFolderName.lowercased())
        if text.range(of: #"(^|[/\s=])"# + name + #"(/|\s|$|\*|\?)"#, options: .regularExpression) != nil { return true }
        return text.range(of: #"\$\{?\w+\}?/(rules|answers|approvals|snapshots)(/[^/\s]*\.(json|answer)|/?(\s|$))"#,
                          options: .regularExpression) != nil
    }

    /// Any Claude Code settings file: a bot could otherwise switch its own hooks off.
    static func isSettingsFile(_ path: String) -> Bool {
        let p = path.lowercased()
        return p.range(of: #"/\.claude/settings(\.local)?\.json$"#, options: .regularExpression) != nil || p.hasSuffix("/managed-settings.json")
    }

    /// Lower case, escaped spaces as spaces, quotes removed: one spelling to search.
    static func normalized(_ command: String) -> String {
        command.lowercased().replacingOccurrences(of: "\\ ", with: " ")
            .replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
    }

    /// A glob like ".claude/skills/my*/SKILL.md" might match something in `dir`.
    static func globCouldReach(_ pattern: String, _ dir: String) -> Bool {
        let p = pattern.lowercased(), d = ShellPath.resolve(dir, cwd: "/").lowercased()
        guard let cut = p.firstIndex(where: { "*?[".contains($0) }) else { return false }
        let fixed = String(p[..<cut])
        return d.hasPrefix(fixed) || fixed.hasPrefix(d + "/") || fnmatch(p, d, 0) == 0 || fnmatch(p, d + "/skill.md", 0) == 0
    }

    // MARK: Categories

    public struct Finding: Equatable, Sendable {
        public var category: ApprovalCategory
        /// The part of a command that needs the OK.
        public var trigger: String?
    }

    public static func categories(tool: String, input: [String: Any], cwd: String, config: GuardConfig) -> [ApprovalCategory] {
        findings(tool: tool, input: input, cwd: cwd, config: config).map(\.category)
    }

    public static func findings(tool: String, input: [String: Any], cwd: String, config: GuardConfig) -> [Finding] {
        if tool.hasPrefix("mcp__") {
            let parts = tool.dropFirst(5).components(separatedBy: "__")
            let server = parts.first ?? "", name = parts.dropFirst().joined(separator: "_")
            if config.trustedServers.contains(server) { return [] }
            if config.computerServers.contains(server) { return [Finding(category: .computer, trigger: nil)] }
            return mcpCategories(server: server, tool: name).map { Finding(category: $0, trigger: nil) }
        }
        if tool == "Bash", let command = input["command"] as? String {
            return shellFindings(command, cwd: cwd, config: config)
        }
        return []
    }

    static let readVerbs: Set<String> = ["get", "list", "search", "read", "fetch", "find", "query", "describe", "view", "show",
                                          "lookup", "download", "check", "count", "preview", "inspect", "retrieve", "load", "whoami", "me"]
    static let sendWords: Set<String> = ["send", "post", "reply", "comment", "comments", "publish", "tweet", "forward", "share",
                                          "dm", "invite", "notify", "announce", "broadcast", "react", "reaction", "submit", "email", "mail"]
    static let sendNames = ["create_issue", "create_pull_request", "issue_write", "create_pr", "pull_request_review_write",
                            "create_pending_pull_request_review", "create_message", "create_draft_reply"]
    /// "<verb>_message", "<verb>_comment" (conversations_add_message, create_comment…) put something in front of people.
    static let sendNouns: Set<String> = ["message", "messages", "comment", "comments", "reply", "replies"]
    static let deleteWords: Set<String> = ["delete", "remove", "destroy", "drop", "purge", "erase", "wipe", "trash", "unlink", "truncate"]
    static let spendWords: Set<String> = ["pay", "payment", "payments", "charge", "charges", "purchase", "buy", "checkout", "order",
                                           "subscribe", "subscription", "invoice", "transfer", "payout", "refund", "donate", "tip", "billing", "capture"]
    static let changeWords: Set<String> = ["deploy", "release", "merge", "migrate", "migration", "rollback", "promote"]
    static let paymentServers: Set<String> = ["stripe", "paypal", "square", "squareup", "braintree", "adyen", "coinbase", "wise", "revolut", "shopify", "lemonsqueezy", "paddle"]

    /// Splits "chat_postMessage" or "send-email" into lower-case words.
    public static func words(_ s: String) -> [String] {
        var out: [String] = [], cur = ""
        var prevLower = false
        for ch in s {
            if ch == "_" || ch == "-" || ch == "." || ch == " " || ch == "/" {
                if !cur.isEmpty { out.append(cur.lowercased()); cur = "" }
                prevLower = false
                continue
            }
            if ch.isUppercase && prevLower && !cur.isEmpty { out.append(cur.lowercased()); cur = "" }
            cur.append(ch)
            prevLower = ch.isLowercase || ch.isNumber
        }
        if !cur.isEmpty { out.append(cur.lowercased()) }
        return out
    }

    /// Sorts an MCP tool by the verbs in its name. Reads (get, list, search…) need nothing.
    public static func mcpCategories(server: String, tool: String) -> [ApprovalCategory] {
        var w = words(tool)
        // "slack_get_users" on the slack server: the verb is "get", not "slack".
        let serverWords = Set(words(server))
        while w.count > 1, let f = w.first, serverWords.contains(f) { w.removeFirst() }
        guard let first = w.first, !readVerbs.contains(first) else { return [] }
        let set = Set(w), lower = tool.lowercased()
        var found: [ApprovalCategory] = []
        if !set.isDisjoint(with: deleteWords) { found.append(.delete) }
        if !set.isDisjoint(with: spendWords) || !serverWords.isDisjoint(with: paymentServers) { found.append(.spend) }
        if !set.isDisjoint(with: sendWords) || sendNames.contains(where: { lower.contains($0) })
            || (w.count > 1 && sendNouns.contains(w.last ?? "")) { found.append(.send) }
        if !set.isDisjoint(with: changeWords) || lower.contains("apply_migration") { found.append(.change) }
        return found
    }

    // MARK: Shell commands

    public static func shellFindings(_ command: String, cwd: String, config: GuardConfig) -> [Finding] {
        let cmds = ShellParser.walk(command, cwd: cwd)
        var found: [Finding] = []
        func first(_ patterns: [String]) -> String? { cmds.first { matches($0.0.raw, patterns) }?.0.raw }
        if let t = deleteTrigger(command, cmds: cmds, folder: config.folder) { found.append(Finding(category: .delete, trigger: t)) }
        if matches(command, spendPatterns) { found.append(Finding(category: .spend, trigger: first(spendPatterns))) }
        if matches(command, sendPatterns) { found.append(Finding(category: .send, trigger: first(sendPatterns))) }
        let change = changePatterns + config.changePatterns
        if matches(command, change) { found.append(Finding(category: .change, trigger: first(change) ?? command)) }
        if let t = outsideTrigger(command, cmds: cmds, cwd: cwd, roots: config.roots) { found.append(Finding(category: .shell, trigger: t)) }
        return found
    }

    /// Sending or posting where other people see it.
    public static let sendPatterns = [
        #"\bgh\s+(pr|issue)\s+(comment|create|review|close|reopen|edit)\b"#, #"\bgh\s+release\s+create\b"#,
        #"\bgh\s+api\b.*(-x|--method)\s*(post|patch|put)\b"#, #"\bgh\s+api\b.*/comments\b.*\s-(f|F)\s"#,
        #"\bcurl\b.*(hooks\.slack\.com|slack\.com/api/chat\.|discord(app)?\.com/api/webhooks|webhook\.office\.com|outlook\.office\.com/webhook|api\.telegram\.org|api\.twilio\.com|api\.sendgrid\.com|api\.postmarkapp\.com|api\.mailgun\.net)"#,
        // Any request that sends data somewhere other than this computer.
        #"\bcurl\b(?=.*(\s-x\s*(post|put|patch|delete)\b|\s--request\s*(post|put|patch|delete)\b|\s((?-i:-d)|--data\S*|(?-i:-F)|--form|--json)(\s|=)))(?!.*\b(localhost|127\.0\.0\.1|0\.0\.0\.0)\b)"#,
        #"\bwget\b.*--(post|body)-(data|file)\b(?!.*\b(localhost|127\.0\.0\.1)\b)"#,
        #"\bsendmail\b"#, #"\bmailx?\s+-s\b"#, #"\bosascript\b.*\b(mail|messages|outlook)\b.*\bsend\b"#,
        #"\bjira\s+(issue\s+)?(comment|create)\b"#, #"\bslack\s+(chat\s+)?send\b"#,
    ]
    /// Changing code or shared systems: git push and reset --hard, deploys and publishing. Each bot can add its own.
    public static let changePatterns = [
        #"\bgit\b(\s+-[cC]\s+\S+)*\s+push\b"#, #"\bgit\b(\s+-[cC]\s+\S+)*\s+reset\b.*--hard\b"#,
        #"\bgh\s+pr\s+merge\b"#,
        #"\bvercel\b(?!\s+(login|logout|whoami|env\s+(ls|pull)|link|dev|ls|list|inspect|logs|help|--version|-v\b|project\s+ls|teams\s+ls|switch|build|domains\s+buy))"#,
        #"\b(netlify|fly|flyctl|firebase|railway|wrangler)\s+(deploy|publish|up)\b"#,
        #"\bgcloud\b.*\bdeploy\b"#, #"\bsupabase\s+(db\s+push|functions\s+deploy|db\s+reset|link)\b"#,
        #"\b(npm|pnpm|yarn)\s+publish\b"#, #"\bdocker\s+push\b"#, #"\bkubectl\s+(apply|rollout|scale|patch)\b"#,
    ]
    public static let spendPatterns = [
        #"\bstripe\s+\S+\s+(create|confirm|capture|pay)\b"#, #"\bcurl\b.*api\.stripe\.com.*(\s-d\s|--data|-x\s*post)"#,
        #"\bcurl\b.*(api\.paypal\.com|api-m\.paypal\.com|connect\.squareup\.com)"#,
        #"\bvercel\s+domains\s+buy\b"#, #"\baws\s+\S+\s+(run-instances|purchase)"#,
    ]
    public static let remoteDeletePatterns = [
        #"\b(drop\s+(table|database|schema|collection)|delete\s+from|truncate\s+table)\b"#, #"\bdropdb\b"#,
        #"\bgit\s+push\b.*(--delete\b|\s:[\w./-]+)"#, #"\bgh\s+(repo|release|issue|pr)\s+delete\b"#,
        #"\bdiskutil\s+(erase|zero|secureerase)"#, #"\.trash\b"#, #"\bkubectl\s+delete\b"#, #"\baws\s+s3\s+(rm|rb)\b"#,
    ]
    static let deleteCommands: Set<String> = ["rm", "rmdir", "unlink", "shred", "srm", "trash"]
    static let interpreters: Set<String> = ["python", "python2", "python3", "node", "ruby", "perl", "php", "osascript", "swift",
                                            "deno", "bun", "lua", "pwsh", "tclsh"]
    static func isInterpreter(_ head: String) -> Bool { interpreters.contains(head) || head.hasPrefix("python3.") }
    /// Code that removes files (Python, Node, Ruby, Perl, AppleScript…).
    static let removeCode = #"(\b(remove|removedirs|unlink|unlinksync|rmtree|rmdir|rmdirsync|rmsync|rimraf|rm_rf|rm_r|removeitem|trashitem|delete|trash)\b|\brm\b|fs\.rm|fileutils\.rm)"#

    /// Deleting something the chat can't undo: files outside the bot's own folder, or data elsewhere.
    public static func deletes(_ command: String, cwd: String, folder: String) -> Bool {
        deleteTrigger(command, cmds: ShellParser.walk(command, cwd: cwd), folder: folder) != nil
    }

    /// The command that deletes something outside the bot's folder, if any.
    static func deleteTrigger(_ command: String, cmds: [(ShellCommand, String?)], folder: String) -> String? {
        if matches(command, remoteDeletePatterns) {
            return cmds.first { matches($0.0.raw, remoteDeletePatterns) }?.0.raw ?? command
        }
        for (c, cur) in cmds {
            guard let targets = deleteTargets(c, command: command) else { continue }
            if targets.isEmpty { return c.raw }   // rm with its paths piped in, or code that deletes: can't tell where
            // In the bot's own folder (and nowhere else), a delete can be undone from the chat.
            guard let here = cur, !folder.isEmpty else { return c.raw }
            for t in targets {
                if t.contains("$") || t.contains("`") { return c.raw }
                if !ShellPath.inside(ShellPath.resolve(t, cwd: here), folder) { return c.raw }
            }
        }
        return nil
    }

    /// What a command deletes: nil = it doesn't delete; [] = it does, but we can't tell what.
    static func deleteTargets(_ c: ShellCommand, command: String) -> [String]? {
        guard let head = c.head else { return nil }
        if deleteCommands.contains(head) {
            return c.args.filter { !$0.hasPrefix("-") }
        }
        if head == "find" {
            // find <roots> … -delete, or -exec / -execdir / -ok / -okdir with a command that deletes.
            var roots: [String] = []
            for w in c.args {
                if w.hasPrefix("-") || w == "!" || w == "(" { break }
                roots.append(w)
            }
            if roots.isEmpty { roots = ["."] }
            if c.words.contains("-delete") { return roots }
            var i = c.words.startIndex
            while i < c.words.endIndex {
                if ["-exec", "-execdir", "-ok", "-okdir"].contains(c.words[i]) {
                    var sub: [String] = []
                    var j = i + 1
                    while j < c.words.endIndex, c.words[j] != ";", c.words[j] != "+" { sub.append(c.words[j]); j += 1 }
                    let inner = ShellParser.expand(ShellCommand(words: sub, raw: sub.joined(separator: " ")), depth: 1)
                    if inner.contains(where: { deleteTargets($0, command: command) != nil }) { return roots }
                    i = j
                }
                i += 1
            }
            return nil
        }
        if head == "git", c.args.first == "clean" { return ["."] }
        if head == "rsync", c.args.contains(where: { $0.hasPrefix("--delete") || $0 == "--remove-source-files" }) {
            return c.args.filter { !$0.hasPrefix("-") }
        }
        if isInterpreter(head) {
            // python3 -c "…", node -e "…", osascript -e "…", or a here-document: look at the code itself.
            let inline = c.heredoc || c.args.contains { ["-c", "-e", "-E", "--eval", "-p", "--print", "-r", "-"].contains($0) }
            let code = (c.args.joined(separator: " ") + (c.heredoc ? " " + command : "")).lowercased()
            if inline, code.range(of: removeCode, options: .regularExpression) != nil { return [] }
        }
        return nil
    }

    /// System places that commands read from all the time (tools, temp files), as opposed to your own files.
    static let systemPrefixes = ["/usr", "/bin", "/sbin", "/opt", "/Library", "/System", "/Applications", "/dev", "/tmp",
                                 "/private/tmp", "/private/var/folders", "/var/folders", "/etc", "/private/etc", "/nix"]

    /// A command that names a place outside the folders the bot may work in.
    public static func outside(_ command: String, cwd: String, roots: [String]) -> Bool {
        outsideTrigger(command, cmds: ShellParser.walk(command, cwd: cwd), cwd: cwd, roots: roots) != nil
    }

    static func outsideTrigger(_ command: String, cmds: [(ShellCommand, String?)], cwd: String, roots: [String]) -> String? {
        if command.lowercased().range(of: #"(^|[;&|(\s])sudo\s"#, options: .regularExpression) != nil { return command }
        if !roots.isEmpty, !roots.contains(where: { ShellPath.inside(cwd, $0) }) { return command }
        func allowed(_ path: String) -> Bool {
            if ShellPath.resolve(path, cwd: "/") == "/" { return false }
            return roots.contains { ShellPath.inside(path, $0) } || systemPrefixes.contains { ShellPath.inside(path, $0) }
        }
        for (c, cur) in cmds {
            // Somewhere a cd went that we can't follow counts as outside.
            guard let base = cur else { return c.raw }
            if let head = c.head, ShellParser.changesDirectory.contains(head) {
                guard let to = ShellParser.cdTarget(c, from: base) else { return c.raw }
                if !allowed(to) { return c.raw }
                continue
            }
            for raw in c.words + c.outputs + c.inputs {
                for piece in raw.components(separatedBy: CharacterSet(charactersIn: "=:")) {
                    var t = piece
                    if t.hasPrefix("-") { guard let slash = t.firstIndex(of: "/") else { continue }; t = String(t[slash...]) }
                    guard !t.isEmpty, !raw.contains("://") else { continue }
                    let looksLikePath = t.hasPrefix("/") || t.hasPrefix("~") || ShellPath.homeForm(t) || t == ".."
                        || t.hasPrefix("../") || t.contains("/../") || t.hasSuffix("/..")
                    guard looksLikePath else { continue }
                    if !allowed(ShellPath.resolve(t, cwd: base)) { return c.raw }
                }
            }
        }
        return nil
    }

    // MARK: Text helpers

    /// Case-insensitive regex match against any pattern. Patterns that don't compile are skipped.
    public static func matches(_ text: String, _ patterns: [String]) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return patterns.contains { p in
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { return false }
            return re.firstMatch(in: text, range: range) != nil
        }
    }

    /// The patterns in `patterns` that aren't valid regular expressions (for the permissions editor).
    public static func invalidPatterns(_ patterns: [String]) -> [String] {
        patterns.filter { (try? NSRegularExpression(pattern: $0)) == nil }
    }

    static let writeMarkers = [#">"#, #"\btee\b"#, #"\bsed\b.*\s-i"#, #"\bperl\b.*\s-p?i"#,
                               #"\b(rm|mv|cp|ln|truncate|chmod|chflags|chown|install|dd|touch|rsync|ditto|unlink|patch|tar|unzip|xattr|defaults)\b"#,
                               #"\b(python3?|node|ruby|perl|swift|osascript|bash|zsh|sh|eval)\b"#]

    static func writes(_ command: String) -> Bool { matches(command, writeMarkers) }

    /// The command names this folder: by full path, from home (~ or $HOME), relative to where it runs, or by
    /// its last two parts ("skills/<name>"). Case-insensitive; `command` is best passed through `normalized` first.
    static func mentions(_ command: String, _ dir: String, cwd: String) -> Bool {
        let home = NSHomeDirectory()
        var forms = [dir, ShellPath.resolve(dir, cwd: "/")]
        if dir.hasPrefix(home + "/") {
            let rest = String(dir.dropFirst(home.count))
            forms += ["~" + rest, "$HOME" + rest, "${HOME}" + rest]
        }
        if dir.lowercased().hasPrefix(cwd.lowercased() + "/") { forms.append(String(dir.dropFirst(cwd.count + 1))) }
        // A folder by its last two parts ("skills/<name>") however the bot got there.
        let name = (dir as NSString).lastPathComponent, parent = ((dir as NSString).deletingLastPathComponent as NSString).lastPathComponent
        forms.append(parent + "/" + name)
        var text = command.lowercased()
        while text.contains("/./") { text = text.replacingOccurrences(of: "/./", with: "/") }
        while text.contains("//") { text = text.replacingOccurrences(of: "//", with: "/") }
        return forms.contains { !$0.isEmpty && text.contains($0.lowercased()) }
    }

    /// What the approval card shows: the whole command (the part that needs the OK first, when it's long or has
    /// several parts), or the main fields of a tool call.
    public static func describe(tool: String, input: [String: Any], trigger: String? = nil) -> String {
        if let command = input["command"] as? String {
            let limit = 4000
            let full = command.count > limit ? String(command.prefix(limit)) + "\n… (\(command.count - limit) more characters not shown)" : command
            let whole = command.trimmingCharacters(in: .whitespacesAndNewlines)
            let several = command.count > 120 || command.contains { "\n;&|`".contains($0) } || command.contains("$(")
            if let trigger, !trigger.isEmpty, trigger != whole, several {
                return "Needs your OK: \(trigger.prefix(400))\n\nFull command:\n\(full)"
            }
            return full
        }
        var lines: [String] = []
        for key in ["channel", "channel_id", "to", "recipient", "recipients", "owner", "repo", "issue_number", "pull_number", "subject", "title", "amount", "currency", "path", "file_path", "url", "action", "text", "body", "message", "comment", "content", "payload"] {
            guard let v = input[key] else { continue }
            let s = (v as? String) ?? "\(v)"
            let one = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            guard !one.isEmpty else { continue }
            lines.append("\(key.replacingOccurrences(of: "_", with: " ")): \(one.prefix(160))")
            if lines.count == 4 { break }
        }
        return lines.joined(separator: "\n")
    }
}
