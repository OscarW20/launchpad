import Foundation

/// Exactly what to launch for one message: program, arguments, the prompt (sent on stdin) and folder.
public struct EngineInvocation: Equatable, Sendable {
    public var engine: BotEngine
    public var arguments: [String]
    public var stdin: String
    public var workingDirectory: URL
    /// The session id this run will use, when the app chooses it up front (Claude's --session-id).
    public var plannedSessionId: String?

    public init(engine: BotEngine, arguments: [String], stdin: String, workingDirectory: URL, plannedSessionId: String? = nil) {
        self.engine = engine
        self.arguments = arguments
        self.stdin = stdin
        self.workingDirectory = workingDirectory
        self.plannedSessionId = plannedSessionId
    }
}

public enum EngineCommand {
    /// Tools a read-only Claude bot may use without asking.
    static let claudeReadOnlyTools = ["Read", "Grep", "Glob", "WebSearch", "WebFetch", "TodoWrite"]
    static let claudeWriteTools = ["Edit", "MultiEdit", "Write", "NotebookEdit", "Bash"]

    /// Builds the command for a bot.
    /// - Parameter sessionId: the engine session stored for this chat, or nil for a fresh one.
    public static func invocation(
        for bot: Bot, prompt: String, botDirectory: URL, sessionId: String?,
        newSessionId: () -> String = { UUID().uuidString.lowercased() }
    ) -> EngineInvocation {
        switch bot.engine {
        case .claude:
            return claude(prompt: prompt, botDirectory: botDirectory, model: bot.model,
                          permission: bot.permission, sessionId: sessionId, newSessionId: newSessionId)
        case .codex:
            return codex(prompt: prompt, botDirectory: botDirectory, model: bot.model,
                         permission: bot.permission, threadId: sessionId)
        }
    }

    /// `claude -p --output-format stream-json --verbose --include-partial-messages [--resume ID | --session-id NEW] …`
    /// The prompt goes on stdin, so text starting with "-" can't be mistaken for a flag.
    public static func claude(
        prompt: String, botDirectory: URL, model: String?, permission: PermissionLevel,
        sessionId: String?, newSessionId: () -> String = { UUID().uuidString.lowercased() }
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
        return EngineInvocation(engine: .claude, arguments: args, stdin: prompt,
                                workingDirectory: botDirectory, plannedSessionId: planned)
    }

    /// `codex exec --json …  -` or `codex exec resume --json … THREAD -`, prompt on stdin.
    public static func codex(
        prompt: String, botDirectory: URL, model: String?, permission: PermissionLevel, threadId: String?
    ) -> EngineInvocation {
        var args = ["exec"]
        if let threadId, !threadId.isEmpty { args.append("resume") }
        args += ["--json", "--skip-git-repo-check"]
        switch permission {
        case .readOnly: args += ["-c", "sandbox_mode=\"read-only\""]
        case .editWorkspace: args += ["-c", "sandbox_mode=\"workspace-write\""]
        case .fullAccess: args += ["--dangerously-bypass-approvals-and-sandbox"]
        }
        if let model, !model.isEmpty { args += ["-m", model] }
        if let threadId, !threadId.isEmpty { args.append(threadId) }
        args.append("-")
        return EngineInvocation(engine: .codex, arguments: args, stdin: prompt,
                                workingDirectory: botDirectory, plannedSessionId: threadId)
    }
}
