import Foundation

/// Wires the `launchpad-chat` server into one run of a bot.
public enum ChatToolsSetup {
    public static let connectorId = "launchpad-chat"
    /// The MCP server key both engines see (`Connector.serverKey`), so tools are `mcp__launchpad_chat__<tool>`.
    public static let serverKey = "launchpad_chat"
    /// For Claude's `--allowedTools`: every tool on the server.
    public static let allowedToolsEntry = "mcp__launchpad_chat"
    public static let executableName = "launchpad-chat"

    /// The server shipped next to the app's executable (Contents/MacOS/launchpad-chat), if it's there.
    public static func executable(nextTo appExecutable: URL?, fileManager fm: FileManager = .default) -> URL? {
        guard let dir = appExecutable?.deletingLastPathComponent() else { return nil }
        let url = dir.appendingPathComponent(executableName)
        return fm.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Lets a Claude run use the chat tools without asking: adds `mcp__launchpad_chat` to its `--allowedTools`
    /// (joining an existing list, e.g. a read-only bot's). Codex runs are returned unchanged.
    public static func allowingChatTools(_ invocation: EngineInvocation) -> EngineInvocation {
        allowing(allowedToolsEntry, in: invocation)
    }

    /// Adds one entry (e.g. `mcp__computer`) to a Claude run's `--allowedTools`, joining an existing list.
    /// Codex runs are returned unchanged.
    public static func allowing(_ entry: String, in invocation: EngineInvocation) -> EngineInvocation {
        guard invocation.engine == .claude else { return invocation }
        var inv = invocation
        if let i = inv.arguments.firstIndex(of: "--allowedTools"), i + 1 < inv.arguments.count {
            let list = inv.arguments[i + 1].split(separator: ",").map(String.init)
            if !list.contains(entry) { inv.arguments[i + 1] = (list + [entry]).joined(separator: ",") }
        } else {
            inv.arguments += ["--allowedTools", entry]
        }
        return inv
    }

    /// Tells bots what they can do in the chat (add to `RunOptions.systemAppend`).
    public static let instructions = """
    Chat tools: you can use chat features like a person in a chat app, with your launchpad_chat tools: react (an emoji on the user's last message), send_gif, start_poll and vote. Use them when the user asks, or now and then when it genuinely fits. They're real: never say you can't send reactions, GIFs or polls.
    If you don't have those tools, write the same thing as a line on its own instead, and the app does it: [react: 🎉], [gif: search words], [poll: Question | Option 1 | Option 2], [vote: 2].
    Long tasks: before work that takes more than about a minute (a build, a fix, research, changes in many files), first call share_plan with one short sentence and up to four steps, and follow its answer. Skip it for quick answers and small changes.
    When you need the user to choose or decide something, use ask_user (tappable choices) instead of writing the questions out.
    When the user wants something repeated or at a set time (every morning, each Friday, remind me at 3), set it up with create_routine; list_routines shows what exists.
    Before driving a Mac app with computer tools, claim it with use_app, and call done_with_app when you finish.
    """
}

/// The chat tools for one run: where its files are and the MCP server entry to add to the bot's connectors.
public struct ChatToolsRun: Sendable {
    public let runId: String
    public let chatId: String
    public let bot: Bot
    /// "bot:<id>" or "group:<id>": who routines made in this chat go to.
    public let routineTarget: String
    /// Seconds before a plan starts by itself (0 = waits for your OK).
    public let planWait: Int
    public let paths: LaunchpadPaths

    public init(runId: String, chat: ChatMeta, bot: Bot, planWait: Int = 0, paths: LaunchpadPaths) {
        self.runId = runId
        self.chatId = chat.id
        self.bot = bot
        if chat.kind == .group, let g = chat.groupId { routineTarget = "group:\(g)" } else { routineTarget = "bot:\(chat.botId ?? bot.id)" }
        self.planWait = max(0, planWait)
        self.paths = paths
    }

    public var actionsFile: URL { paths.chatActionsFile(runId) }
    public var planAnswerFile: URL { paths.planAnswerFile(runId) }

    public var config: ChatToolsConfig {
        ChatToolsConfig(actionsFile: actionsFile.path, planAnswerFile: planAnswerFile.path, planWait: planWait,
                        claimsFile: paths.appClaimsFile.path, botName: bot.name, botId: bot.id,
                        routinesFile: paths.routinesFile.path, routineTarget: routineTarget)
    }

    /// A stdio connector that runs `launchpad-chat` with this run's settings as flags (no secrets in them).
    /// Append it to `RunOptions.connectors`; `MCPConfig` turns it into Claude's `--mcp-config` and Codex's `-c` flags.
    public func connector(executable: URL) -> Connector {
        Connector(id: ChatToolsSetup.connectorId, name: "Chat tools", kind: .stdio, command: executable.path,
                  args: config.arguments)
    }

    /// Makes the folders the server writes to. Call before starting the run.
    public func prepare(fileManager fm: FileManager = .default) throws {
        try fm.createDirectory(at: paths.chatActions, withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.planAnswers, withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.appClaimsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: planAnswerFile)
    }

    /// Your answer to the plan card: "start", "cancel" or your own words. The waiting tool picks it up.
    public func answerPlan(_ answer: String, fileManager fm: FileManager = .default) throws {
        try fm.createDirectory(at: paths.planAnswers, withIntermediateDirectories: true)
        try Data(answer.utf8).write(to: planAnswerFile, options: .atomic)
    }

    /// Removes the run's files once its actions are applied.
    public func cleanUp(fileManager fm: FileManager = .default) {
        try? fm.removeItem(at: actionsFile)
        try? fm.removeItem(at: planAnswerFile)
    }
}
