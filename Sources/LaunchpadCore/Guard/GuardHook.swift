import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - The approval handshake

/// An approval card the guard is waiting on. The hook writes it as `<base>.approval-<id>.json`.
public struct PendingApproval: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    /// An `ApprovalCategory` raw value.
    public var category: String
    /// The tool, e.g. "Bash" or "mcp__slack__post_message". Show it with `ToolNames.readable`.
    public var tool: String
    /// What it wants to do (the command, or the main fields of the tool call).
    public var detail: String
    public var bot: String?

    public init(id: String, category: String, tool: String, detail: String, bot: String? = nil) {
        self.id = id
        self.category = category
        self.tool = tool
        self.detail = detail
        self.bot = bot
    }

    public var kind: ApprovalCategory? { ApprovalCategory(rawValue: category) }
    /// Whether the card may offer "Always allow" (never for the Terminal).
    public var offersAlways: Bool { BotRules.canAlwaysAllow(tool: tool) && kind != nil }
}

/// Your answer to an approval card.
public enum ApprovalAnswer: String, Codable, Sendable {
    case approve, deny, always
}

/// The app's side of the handshake. The hook (inside the bot's sandbox) writes requests to `requests/`;
/// the app shows them as cards and writes your answer to `answers/`, which no bot can write.
public struct ApprovalInbox {
    public let requests: URL
    public let answers: URL

    public init(paths: LaunchpadPaths) {
        self.init(requests: paths.approvalRequests, answers: paths.approvalAnswers)
    }

    public init(requests: URL, answers: URL) {
        self.requests = requests
        self.answers = answers
    }

    /// The request prefix for one run (one reply). Pass it to `GuardHookSetup.askBase`.
    public func base(chatId: String, runId: String) -> URL {
        requests.appendingPathComponent("\(Slug.make(chatId))-\(Slug.make(runId))")
    }

    /// New cards for this run, and the ids of cards the hook gave up on (timed out or the bot stopped).
    /// Picked-up files are removed, so each card shows once.
    public func collect(base: URL) -> (new: [PendingApproval], expired: [String]) {
        let fm = FileManager.default
        let prefix = base.lastPathComponent + ".approval-"
        guard let names = try? fm.contentsOfDirectory(atPath: base.deletingLastPathComponent().path) else { return ([], []) }
        var new: [PendingApproval] = [], expired: [String] = []
        for name in names.sorted() where name.hasPrefix(prefix) {
            let url = base.deletingLastPathComponent().appendingPathComponent(name)
            let id = String(name.dropFirst(prefix.count)).components(separatedBy: ".").first ?? ""
            if name.hasSuffix(".expired") {
                try? fm.removeItem(at: url)
                if Self.isValidId(id) { expired.append(id) }
                continue
            }
            guard name.hasSuffix(".json"), let data = try? Data(contentsOf: url) else { continue }
            try? fm.removeItem(at: url)
            guard var card = try? JSONDecoder().decode(PendingApproval.self, from: data), Self.isValidId(card.id) else { continue }
            if card.id != id { card.id = id }   // the file name is what the hook waits on
            if Self.isValidId(id) { new.append(card) }
        }
        return (new, expired)
    }

    /// Records your answer; the waiting hook picks it up within a moment.
    public func answer(_ id: String, _ answer: ApprovalAnswer) throws {
        guard Self.isValidId(id) else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: answers, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(answer.rawValue.utf8).write(to: answers.appendingPathComponent("\(id).answer"), options: .atomic)
    }

    /// The reply ended: removes answers nobody read and anything left for this run.
    public func close(base: URL, ids: [String]) {
        let fm = FileManager.default
        for id in ids where Self.isValidId(id) { try? fm.removeItem(at: answers.appendingPathComponent("\(id).answer")) }
        let prefix = base.lastPathComponent + ".approval-"
        for name in (try? fm.contentsOfDirectory(atPath: base.deletingLastPathComponent().path)) ?? [] where name.hasPrefix(prefix) {
            try? fm.removeItem(at: base.deletingLastPathComponent().appendingPathComponent(name))
        }
    }

    /// Ids come from files a bot could write, so they must be plain: no slashes or dots.
    static func isValidId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// The hook's side: writes the card, then waits for the answer. Returns nil if nobody answered in time
    /// or the bot was stopped (whoever started the hook has gone).
    public static func waitForUser(
        base: String, answers: String, card: PendingApproval, timeout: TimeInterval,
        poll: TimeInterval = 0.25, stillWanted: () -> Bool = { true }
    ) -> ApprovalAnswer? {
        let fm = FileManager.default
        let request = URL(fileURLWithPath: "\(base).approval-\(card.id).json")
        // The answer comes back where the bot can't write, so only you can approve.
        let reply = answers.isEmpty ? URL(fileURLWithPath: "\(base).approval-\(card.id).answer")
                                    : URL(fileURLWithPath: answers).appendingPathComponent("\(card.id).answer")
        try? fm.createDirectory(at: request.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(card), (try? data.write(to: request, options: .atomic)) != nil else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, stillWanted() {
            if let text = try? String(contentsOf: reply, encoding: .utf8) {
                try? fm.removeItem(at: reply)
                return ApprovalAnswer(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .deny
            }
            Thread.sleep(forTimeInterval: poll)
        }
        // Tell the app the card no longer does anything.
        try? fm.removeItem(at: request)
        fm.createFile(atPath: "\(base).approval-\(card.id).expired", contents: nil)
        return nil
    }
}

// MARK: - The hook

/// What `launchpad-guard hook` tells Claude Code.
public struct HookResult: Equatable, Sendable {
    /// 0 lets the call go ahead (or carries a JSON decision on stdout); 2 blocks it with `stderr` as the reason.
    public var exitCode: Int32
    public var stdout: String?
    public var stderr: String?

    public static let pass = HookResult(exitCode: 0)
    public static func deny(_ reason: String) -> HookResult { HookResult(exitCode: 2, stderr: reason) }
    /// You approved it: also skips Claude Code's own permission prompt for this one call.
    public static func allow(_ reason: String) -> HookResult {
        let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "allow",
                                                         "permissionDecisionReason": reason]]
        let data = (try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])) ?? Data()
        return HookResult(exitCode: 0, stdout: String(decoding: data, as: UTF8.self))
    }

    public init(exitCode: Int32, stdout: String? = nil, stderr: String? = nil) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum GuardHook {
    /// Tools that only read or plan: still allowed when the rules can't be read, so the bot can say what happened.
    public static let harmless: Set<String> = ["Read", "Glob", "Grep", "LS", "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet"]
    /// A little under the hook's 600-second limit, so the bot gets a clear reason instead of a timeout.
    public static let waitTimeout: TimeInterval = 570

    /// What to do with one tool call.
    /// - Parameters:
    ///   - input: the PreToolUse JSON from stdin.
    ///   - rulesPath: the bot's rules file. Missing or unreadable means no (fail closed).
    ///   - askBase: where to leave approval cards for this reply; nil when nobody can be asked.
    ///   - grants: the older per-session approvals (`[[approve: …]]` in chat), still honoured for Ask.
    public static func run(
        input: Data, rulesPath: String?, askBase: String?, grants: ApprovalGrants?,
        timeout: TimeInterval = waitTimeout, poll: TimeInterval = 0.25,
        stillWanted: () -> Bool = { true }, now: Date = Date()
    ) -> HookResult {
        guard let call = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else {
            return .deny(GuardEngine.unreadableReason)
        }
        let tool = call["tool_name"] as? String ?? ""
        guard let rulesPath, !rulesPath.isEmpty, let data = FileManager.default.contents(atPath: rulesPath),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return harmless.contains(tool) ? .pass : .deny(GuardEngine.unreadableReason)
        }
        let config = GuardConfig(json: json)
        let toolInput = call["tool_input"] as? [String: Any] ?? [:]
        let cwd = (call["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? config.folder
        switch GuardEngine.decide(tool: tool, input: toolInput, cwd: cwd, config: config) {
        case .pass:
            return .pass
        case .deny(let reason):
            return .deny(reason)
        case .ask(let category, let detail):
            // Full freedom: the same as you approving the card.
            if config.fullFreedom { return .allow("Full freedom is on for this group.") }
            // You already approved something for this session in the chat (the older flow).
            if let grants, let session = call["session_id"] as? String, grants.isApproved(sessionId: session, now: now) {
                return .pass
            }
            guard let askBase, !askBase.isEmpty else {
                return .deny("""
                Launchpad: this needs my approval first because it means: \(category.wants). \
                Ask with a line `[[approve: <what you want to do, in plain words>]]`, then end your turn and wait for "Approved".
                """)
            }
            let card = PendingApproval(id: UUID().uuidString.lowercased(), category: category.rawValue, tool: tool,
                                       detail: detail, bot: config.bot)
            switch ApprovalInbox.waitForUser(base: askBase, answers: config.answers, card: card, timeout: timeout,
                                             poll: poll, stillWanted: stillWanted) {
            case .approve, .always:
                return .allow("The user approved this.")
            case .deny:
                return .deny("The user said no to this (\(category.title.lowercased())). Don't try it another way. Ask them in one short sentence what they'd like instead.")
            case nil:
                return .deny("The user didn't answer in time, so this didn't run. Tell them what you wanted to do; they can say go ahead in the chat.")
            }
        }
    }
}

// MARK: - Setting it up for a run

/// What a Claude Code run needs to use the guard.
public struct GuardHookSetup: Equatable, Sendable {
    /// The `launchpad-guard` executable (shipped next to the app's own binary).
    public var helper: String
    /// The bot's rules file (`GuardRulesFile.write`).
    public var rulesFile: String
    /// Where this reply's approval cards go (`ApprovalInbox.base`). nil: the bot is told to ask in chat instead.
    public var askBase: String?
    /// The older per-session approvals folder (`ApprovalGrants.directory`), also honoured.
    public var approvalsDir: String?

    public init(helper: String, rulesFile: String, askBase: String? = nil, approvalsDir: String? = nil) {
        self.helper = helper
        self.rulesFile = rulesFile
        self.askBase = askBase
        self.approvalsDir = approvalsDir
    }

    /// `'<helper>' hook '<rules>' [--ask '<base>'] [--approvals '<dir>']`, quoted for the shell.
    public var command: String {
        var c = "\(Self.quote(helper)) hook \(Self.quote(rulesFile))"
        if let askBase, !askBase.isEmpty { c += " --ask \(Self.quote(askBase))" }
        if let approvalsDir, !approvalsDir.isEmpty { c += " --approvals \(Self.quote(approvalsDir))" }
        return c
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Claude Code settings for `--settings`: one PreToolUse hook on every tool (matcher "*", 600 s so you have time to
    /// answer). These outrank the user's and the project's own settings, so a planted "disableAllHooks" can't turn the
    /// guard off. Inside Launchpad's sandbox, Claude Code's own sandbox is off (macOS can't nest them; ours is stricter).
    public static func claudeSettings(hook: GuardHookSetup?, legacyCommand: String? = nil, sandboxed: Bool) -> String? {
        var settings: [String: Any] = [:]
        if let hook {
            settings["hooks"] = ["PreToolUse": [["matcher": "*", "hooks": [["type": "command", "command": hook.command, "timeout": 600]]]]]
            settings["disableAllHooks"] = false
        } else if let legacyCommand {
            settings["hooks"] = ["PreToolUse": [["matcher": "Bash|mcp__.*", "hooks": [["type": "command", "command": legacyCommand, "timeout": 10]]]]]
        }
        if sandboxed { settings["sandbox"] = ["enabled": false] }
        guard !settings.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Writes each bot's rules where the hook reads them: outside the bot's folder, read-only on disk.
public enum GuardRulesFile {
    /// The guard's view of a bot.
    /// - Parameters:
    ///   - extraRoots: other folders it may work in (its groups' folders).
    ///   - lockedSkillDirs: from `SkillLocks.lockedDirs`.
    ///   - alwaysForWrites: false turns "Always allow" off for sends, deletes, spending and changes (always off when
    ///     the bot is locked down).
    ///   - trustedServers: MCP servers whose tools never need asking.
    ///   - fullFreedom: the run is in a group set to "Full freedom" (`ApprovalMode.skipsApprovals`).
    public static func config(
        for bot: Bot, paths: LaunchpadPaths, extraRoots: [URL] = [], lockedSkillDirs: [String] = [],
        alwaysForWrites: Bool = true, trustedServers: [String] = [], fullFreedom: Bool = false,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> GuardConfig {
        let folder = paths.botDir(bot.id)
        var c = GuardConfig()
        c.bot = bot.name
        c.folder = folder.path
        c.roots = [folder.path] + extraRoots.map(\.path)
        c.rules = Dictionary(uniqueKeysWithValues: ApprovalCategory.allCases.map { ($0.rawValue, bot.rules.rule($0).rawValue) })
        let writesOK = alwaysForWrites && !bot.lockedDown
        c.alwaysAllowed = bot.rules.alwaysAllowed.filter { key in
            !BotRules.isTerminalKey(key) && (writesOK || !["send", "delete", "spend", "change"].contains(key.components(separatedBy: ":").first ?? ""))
        }
        c.noAlwaysForWrites = !writesOK
        c.locked = lockedSkillDirs
        c.changePatterns = bot.rules.changePatterns
        c.trustedServers = trustedServers
        // A locked-down bot keeps asking, whatever its group says.
        c.fullFreedom = fullFreedom && !bot.lockedDown
        c.answers = paths.approvalAnswers.path
        c.dataFolderName = paths.launchpadData.lastPathComponent
        c.protected = [
            paths.guardRules.path, paths.approvalAnswers.path, paths.launchpadData.appendingPathComponent("approvals").path,
            paths.snapshots.path, paths.launchpadData.appendingPathComponent("locked-skills.json").path,
            folder.appendingPathComponent(".claude/settings.json").path,
            folder.appendingPathComponent(".claude/settings.local.json").path,
            home.appendingPathComponent(".claude/settings.json").path,
            home.appendingPathComponent(".claude/settings.local.json").path,
        ]
        return c
    }

    /// A bot can be answering in an "Ask me" chat and a "Full freedom" group at once, so each mode has its own file.
    public static func fileId(botId: String, fullFreedom: Bool) -> String { fullFreedom ? botId + ".free" : botId }

    /// Writes `paths.rulesFile(botId)` and returns its URL. The file is read-only (0444) and its folder 0555 between
    /// writes, on top of the guard's own check, so a bot can't replace or remove it.
    @discardableResult
    public static func write(_ config: GuardConfig, botId: String, paths: LaunchpadPaths) throws -> URL {
        let fm = FileManager.default
        let folder = paths.guardRules
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path) }
        let url = paths.rulesFile(fileId(botId: botId, fullFreedom: config.fullFreedom))
        let data = try JSONSerialization.data(withJSONObject: config.json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
        try data.write(to: url, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        return url
    }
}
