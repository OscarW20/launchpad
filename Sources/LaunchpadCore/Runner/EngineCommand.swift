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
    /// When set (macOS), the engine runs inside `sandbox-exec` with this profile (`BotSandbox`).
    public var sandboxProfile: String?
    /// Local engine: the HTTP call to make instead of launching a process (`arguments` and `stdin` are unused).
    public var local: LocalModelRequest?

    public init(engine: BotEngine, arguments: [String], stdin: String, workingDirectory: URL,
                plannedSessionId: String? = nil, environment: [String: String] = [:], sandboxProfile: String? = nil,
                local: LocalModelRequest? = nil) {
        self.local = local
        self.engine = engine
        self.arguments = arguments
        self.stdin = stdin
        self.workingDirectory = workingDirectory
        self.plannedSessionId = plannedSessionId
        self.environment = environment
        self.sandboxProfile = sandboxProfile
    }

    /// What to launch, given where the engine's executable is: the engine itself, or `sandbox-exec` around it.
    public func launch(executable: URL) -> (executable: URL, arguments: [String]) {
        guard let sandboxProfile else { return (executable, arguments) }
        return BotSandbox.wrap(executable: executable, arguments: arguments, profile: sandboxProfile)
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
    /// Claude Code PreToolUse hook command that blocks risky actions until approved (the older, Bash and MCP only
    /// guard: `launchpad-guard --approvals <dir>`). Ignored when `guardHook` is set.
    public var guardCommand: String?
    /// The permission guard on every tool, with the bot's rules and approval cards (`launchpad-guard hook …`).
    public var guardHook: GuardHookSetup?
    /// Run inside the macOS sandbox with this profile (`BotSandbox.profile()`). Claude: always when set, with Claude
    /// Code's own sandbox turned off. Codex: only when it runs without its own sandbox (they can't be nested).
    public var sandboxProfile: String?
    /// Secrets for connectors, passed via the process environment.
    public var environment: [String: String] = [:]
    /// Don't keep a session (e.g. drafting a skill).
    public var ephemeral = false
    /// No tools at all (e.g. a background memory review). Claude: `--tools ""`. Codex has no such switch; it runs
    /// read-only there.
    public var quiet = false
    /// Codex reasoning effort ("low", "medium", "high"): `-c model_reasoning_effort="low"`.
    public var reasoningEffort: String?
    /// Branch off the stored session instead of continuing it (side questions): Claude `--resume ID --fork-session
    /// --session-id NEW`, Codex `codex exec fork ID`. The stored session is left untouched.
    public var forkSession = false
    /// Local engine only: the chat so far (local models have no session) and other bots' names for group chats.
    public var history: [ChatMessage] = []
    public var historyNames: [String: String] = [:]
    /// Local engine only: the bot's instructions. nil = read CLAUDE.md from the bot's folder.
    public var instructions: String?
    /// Local engine only: an API key for servers that want one (from the Keychain; never saved).
    public var localAPIKey: String?

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
                         permission: bot.permission, threadId: sessionId, options: options,
                         rules: bot.rules, lockedDown: bot.lockedDown)
        case .local:
            return local(bot: bot, prompt: prompt, botDirectory: botDirectory, options: options)
        }
    }

    /// A local model: one `POST {base}/chat/completions` with the bot's instructions, the chat so far and the prompt.
    /// No tools, no session; `connectors`, permissions and the sandbox don't apply.
    public static func local(bot: Bot, prompt: String, botDirectory: URL, options: RunOptions = RunOptions()) -> EngineInvocation {
        let instructions = options.instructions
            ?? (try? String(contentsOf: botDirectory.appendingPathComponent("CLAUDE.md"), encoding: .utf8))
        let system = LocalModel.systemPrompt(botName: bot.name, instructions: instructions)
        let messages = LocalModel.messages(system: system, history: options.history, prompt: prompt, botId: bot.id,
                                           names: options.historyNames)
        let request = LocalModelRequest(baseURL: bot.localBaseURL ?? LocalModel.defaultBaseURL, model: bot.model ?? "",
                                        messages: messages, apiKey: options.localAPIKey)
        return EngineInvocation(engine: .local, arguments: [], stdin: prompt, workingDirectory: botDirectory, local: request)
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
        if let sessionId, !sessionId.isEmpty, options.forkSession {
            let id = newSessionId()
            args += ["--resume", sessionId, "--fork-session", "--session-id", id]
            planned = id
        } else if let sessionId, !sessionId.isEmpty {
            args += ["--resume", sessionId]
            planned = sessionId
        } else {
            let id = newSessionId()
            args += ["--session-id", id]
            planned = id
        }
        if options.ephemeral { args.append("--no-session-persistence") }
        if let model, !model.isEmpty { args += ["--model", model] }
        if options.quiet { args += ["--tools", ""] }
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
        if let settings = GuardHookSetup.claudeSettings(hook: options.guardHook, legacyCommand: options.guardCommand,
                                                        sandboxed: options.sandboxProfile != nil) {
            args += ["--settings", settings]
        }
        return EngineInvocation(engine: .claude, arguments: args, stdin: prompt, workingDirectory: botDirectory,
                                plannedSessionId: planned, environment: options.environment,
                                sandboxProfile: options.sandboxProfile)
    }

    /// `codex exec --json …  -` or `codex exec resume --json … THREAD -`, prompt on stdin.
    public static func codex(
        prompt: String, botDirectory: URL, model: String?, permission: PermissionLevel, threadId: String?,
        options: RunOptions = RunOptions(), rules: BotRules = BotRules(), lockedDown: Bool = false
    ) -> EngineInvocation {
        var args = ["exec"]
        let resuming = !(threadId ?? "").isEmpty
        let forking = resuming && options.forkSession
        if resuming { args.append(forking ? "fork" : "resume") }
        args += ["--json", "--skip-git-repo-check"]
        if options.ephemeral && (!resuming || forking) { args.append("--ephemeral") }
        // `codex exec` can't stop mid-task to ask (no hook), so the rules map onto its own sandbox where they can:
        // a full-access bot whose commands outside its folder are Ask/Never, or whose deletes are Never, is fenced
        // into its workspace (network stays on). Locked down: always the workspace sandbox, with no network.
        // Sends, spending and Ask rules go in its instructions (`BotRules.codexNote`).
        let fenced = permission == .fullAccess && (rules.rule(.shell) != .allow || rules.rule(.delete) == .never)
        switch permission {
        case .readOnly: args += ["-c", "sandbox_mode=\"read-only\""]
        case _ where lockedDown:
            args += ["-c", "sandbox_mode=\"workspace-write\"", "-c", "sandbox_workspace_write.network_access=false"]
        case .fullAccess where fenced:
            args += ["-c", "sandbox_mode=\"workspace-write\"", "-c", "sandbox_workspace_write.network_access=true"]
        case .editWorkspace: args += ["-c", "sandbox_mode=\"workspace-write\""]
        case .fullAccess: args += ["--dangerously-bypass-approvals-and-sandbox"]
        }
        let workspaceWrite = args.contains("sandbox_mode=\"workspace-write\"")
        if workspaceWrite, !options.addDirectories.isEmpty {
            let roots = options.addDirectories.map { MCPConfig.toml($0.path) }.joined(separator: ",")
            args += ["-c", "sandbox_workspace_write.writable_roots=[\(roots)]"]
        }
        args += MCPConfig.codexArgs(options.connectors)
        if let effort = options.reasoningEffort, !effort.isEmpty {
            args += ["-c", "model_reasoning_effort=\(MCPConfig.toml(effort))"]
        }
        if let model, !model.isEmpty { args += ["-m", model] }
        if let threadId, resuming { args.append(threadId) }
        args.append("-")
        var input = prompt
        if !resuming, let append = options.systemAppend, !append.isEmpty {
            input = "<launchpad-rules>\n\(append)\n</launchpad-rules>\n\n\(prompt)"
        }
        // Our sandbox goes around Codex only when Codex runs without its own (macOS can't nest them).
        let outer = args.contains("--dangerously-bypass-approvals-and-sandbox") ? options.sandboxProfile : nil
        return EngineInvocation(engine: .codex, arguments: args, stdin: input, workingDirectory: botDirectory,
                                plannedSessionId: forking ? nil : threadId, environment: options.environment, sandboxProfile: outer)
    }

    /// A one-off run that keeps no session, e.g. drafting a skill from a chat.
    public static func oneShot(engine: BotEngine, model: String?, prompt: String, directory: URL,
                               localBaseURL: String? = nil) -> EngineInvocation {
        var options = RunOptions()
        options.ephemeral = true
        let bot = Bot(id: "scratch", name: "Scratch", engine: engine, model: model, permission: .readOnly, localBaseURL: localBaseURL)
        return invocation(for: bot, prompt: prompt, botDirectory: directory, sessionId: nil, options: options)
    }
}
