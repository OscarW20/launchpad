import Foundation

/// Exactly what to launch for one message: program, arguments, the prompt (sent on stdin) and folder.
public struct EngineInvocation: Equatable, Sendable {
    public var engine: BotEngine
    public var arguments: [String]
    public var stdin: String
    public var workingDirectory: URL
    /// The session id this run will use, when the app chooses it up front (Claude's --session-id).
    public var plannedSessionId: String?
    /// Extra environment (connector secrets). Never logged or written to disk.
    public var environment: [String: String]

    public init(engine: BotEngine, arguments: [String], stdin: String, workingDirectory: URL,
                plannedSessionId: String? = nil, environment: [String: String] = [:]) {
        self.engine = engine
        self.arguments = arguments
        self.stdin = stdin
        self.workingDirectory = workingDirectory
        self.plannedSessionId = plannedSessionId
        self.environment = environment
    }
}

/// Everything beyond the bot itself that shapes a run.
public struct RunOptions: Equatable, Sendable {
    /// Extra folders the bot may work in (e.g. its group's shared workspace).
    public var addDirectories: [URL] = []
    /// Launchpad's rules (approvals, secrets). Claude: system prompt. Codex: sent with the first message.
    public var systemAppend: String?
    /// When true, only `connectors` are available as MCP servers.
    public var manageConnectors = false
    public var connectors: [Connector] = []
    /// Claude Code PreToolUse hook command that blocks risky actions until approved.
    public var guardCommand: String?
    /// Secrets for connectors, passed via the process environment.
    public var environment: [String: String] = [:]
    /// Don't keep a session (e.g. drafting a skill).
    public var ephemeral = false

    public init() {}
}

public enum EngineCommand {
    /// Tools a read-only Claude bot may use without asking.
    static let claudeReadOnlyTools = ["Read", "Grep", "Glob", "WebSearch", "WebFetch", "TodoWrite"]
    static let claudeWriteTools = ["Edit", "MultiEdit", "Write", "NotebookEdit", "Bash"]

    /// Builds the command for a bot.
    /// - Parameter sessionId: the engine session stored for this chat, or nil for a fresh one.
    public static func invocation(
        for bot: Bot, prompt: String, botDirectory: URL, sessionId: String?,
        options: RunOptions = RunOptions(),
        newSessionId: () -> String = { UUID().uuidString.lowercased() }
    ) -> EngineInvocation {
        switch bot.engine {
        case .claude:
            return claude(prompt: prompt, botDirectory: botDirectory, model: bot.model,
                          permission: bot.permission, sessionId: sessionId, options: options, newSessionId: newSessionId)
        case .codex:
            return codex(prompt: prompt, botDirectory: botDirectory, model: bot.model,
                         permission: bot.permission, threadId: sessionId, options: options)
        }
    }

    /// `claude -p --output-format stream-json --verbose --include-partial-messages [--resume ID | --session-id NEW] …`
    /// The prompt goes on stdin, so text starting with "-" can't be mistaken for a flag.
    public static func claude(
        prompt: String, botDirectory: URL, model: String?, permission: PermissionLevel,
        sessionId: String?, options: RunOptions = RunOptions(),
        newSessionId: () -> String = { UUID().uuidString.lowercased() }
    ) -> EngineInvocation {
        var args = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages"]
        var planned: String?
        if let sessionId, !sessionId.isEmpty {
            args += ["--resume", sessionId]
            planned = sessionId
        } else {
            let id = newSessionId()
            args += ["--session-id", id]
            planned = id
        }
        if options.ephemeral { args.append("--no-session-persistence") }
        if let model, !model.isEmpty { args += ["--model", model] }
        switch permission {
        case .readOnly:
            args += ["--permission-mode", "default",
                     "--allowedTools", claudeReadOnlyTools.joined(separator: ","),
                     "--disallowedTools", claudeWriteTools.joined(separator: ",")]
        case .editWorkspace:
            args += ["--permission-mode", "acceptEdits"]
        case .fullAccess:
            args += ["--permission-mode", "bypassPermissions", "--dangerously-skip-permissions"]
        }
        if !options.addDirectories.isEmpty {
            args += ["--add-dir"] + options.addDirectories.map(\.path)
        }
        if let append = options.systemAppend, !append.isEmpty {
            args += ["--append-system-prompt", append]
        }
        if options.manageConnectors {
            args += ["--strict-mcp-config", "--mcp-config", MCPConfig.claudeJSON(options.connectors)]
        }
        if let guardCommand = options.guardCommand {
            args += ["--settings", guardSettings(command: guardCommand)]
        }
        return EngineInvocation(engine: .claude, arguments: args, stdin: prompt, workingDirectory: botDirectory,
                                plannedSessionId: planned, environment: options.environment)
    }

    /// `codex exec --json …  -` or `codex exec resume --json … THREAD -`, prompt on stdin.
    public static func codex(
        prompt: String, botDirectory: URL, model: String?, permission: PermissionLevel, threadId: String?,
        options: RunOptions = RunOptions()
    ) -> EngineInvocation {
        var args = ["exec"]
        let resuming = !(threadId ?? "").isEmpty
        if resuming { args.append("resume") }
        args += ["--json", "--skip-git-repo-check"]
        if options.ephemeral && !resuming { args.append("--ephemeral") }
        switch permission {
        case .readOnly: args += ["-c", "sandbox_mode=\"read-only\""]
        case .editWorkspace: args += ["-c", "sandbox_mode=\"workspace-write\""]
        case .fullAccess: args += ["--dangerously-bypass-approvals-and-sandbox"]
        }
        if permission == .editWorkspace, !options.addDirectories.isEmpty {
            let roots = options.addDirectories.map { MCPConfig.toml($0.path) }.joined(separator: ",")
            args += ["-c", "sandbox_workspace_write.writable_roots=[\(roots)]"]
        }
        args += MCPConfig.codexArgs(options.connectors)
        if let model, !model.isEmpty { args += ["-m", model] }
        if let threadId, resuming { args.append(threadId) }
        args.append("-")
        var input = prompt
        if !resuming, let append = options.systemAppend, !append.isEmpty {
            input = "<launchpad-rules>\n\(append)\n</launchpad-rules>\n\n\(prompt)"
        }
        return EngineInvocation(engine: .codex, arguments: args, stdin: input, workingDirectory: botDirectory,
                                plannedSessionId: threadId, environment: options.environment)
    }

    /// A one-off run that keeps no session, e.g. drafting a skill from a chat.
    public static func oneShot(engine: BotEngine, model: String?, prompt: String, directory: URL) -> EngineInvocation {
        var options = RunOptions()
        options.ephemeral = true
        let bot = Bot(id: "scratch", name: "Scratch", engine: engine, model: model, permission: .readOnly)
        return invocation(for: bot, prompt: prompt, botDirectory: directory, sessionId: nil, options: options)
    }

    /// `--settings` JSON that runs the approval guard before shell commands and MCP tools.
    static func guardSettings(command: String) -> String {
        let hook: [String: Any] = ["type": "command", "command": command, "timeout": 10]
        let obj: [String: Any] = ["hooks": ["PreToolUse": [["matcher": "Bash|mcp__.*", "hooks": [hook]]]]]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
