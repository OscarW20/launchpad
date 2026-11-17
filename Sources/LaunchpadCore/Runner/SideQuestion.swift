import Foundation

/// Side questions: ask a bot something quick while it works, without stopping or steering its main task.
///
/// The answer comes from a fork of the bot's conversation, so it knows the context, and the main session is left
/// untouched (verified live):
/// - Claude Code 2.1: `claude -p --resume <id> --fork-session --session-id <new> --no-session-persistence`
///   (a new session id carrying the old context; nothing saved).
/// - Codex 0.169: `codex exec fork --json --ephemeral … <id> -` (a new thread id; `--ephemeral` keeps no files).
/// - No session yet, or a local model: a fresh one-off run with a recap of the chat.
///
/// Side questions run read-only and keep no session, so they can run alongside the main job.
public enum SideQuestion {
    public static let preface = "(A quick side question from the user while you're busy. Answer it briefly and directly "
        + "from what you know. Don't change any files, don't run long commands, and don't carry on with your main task "
        + "here: that's still running elsewhere.)"

    /// The prompt for a side question; with no session to fork, the recent chat goes in front.
    public static func prompt(_ question: String, history: [ChatMessage], forking: Bool, names: [String: String] = [:]) -> String {
        let asked = preface + "\n\n" + question
        guard !forking else { return asked }
        return ConversationRecap.seed(prompt: asked, recap: ConversationRecap.text(history, names: names),
                                      header: "Recent conversation:")
    }

    /// The command for a side question to `bot` in a chat whose stored session is `sessionId`.
    ///
    /// `options` are the bot's usual run options (connectors, guard, sandbox); this adds read-only, no session kept,
    /// and the fork. For a local bot, `options.history` should hold the chat as usual.
    public static func invocation(
        for bot: Bot, question: String, botDirectory: URL, sessionId: String?, history: [ChatMessage],
        names: [String: String] = [:], options: RunOptions = RunOptions(),
        newSessionId: () -> String = { UUID().uuidString.lowercased() }
    ) -> EngineInvocation {
        var o = options
        o.ephemeral = true
        var asker = bot
        asker.permission = .readOnly
        let session = bot.engine.isAgent ? sessionId.flatMap { $0.isEmpty ? nil : $0 } : nil
        o.forkSession = session != nil
        if bot.engine == .local {
            if o.history.isEmpty { o.history = history }
            return EngineCommand.invocation(for: asker, prompt: preface + "\n\n" + question, botDirectory: botDirectory,
                                            sessionId: nil, options: o, newSessionId: newSessionId)
        }
        let text = prompt(question, history: history, forking: session != nil, names: names)
        return EngineCommand.invocation(for: asker, prompt: text, botDirectory: botDirectory, sessionId: session,
                                        options: o, newSessionId: newSessionId)
    }
}
