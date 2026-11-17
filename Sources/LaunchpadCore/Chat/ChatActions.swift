import Foundation

// The file protocol between the `launchpad-chat` MCP server (run by the bot's engine) and the app.
//
// Per run (all under ~/Launchpad/.launchpad):
//   requests/chat/<run>.actions.jsonl   one `ChatAction` per line, appended by the server (bots may write here:
//                                       the sandbox allows `requests/`). The app tails it during the run.
//   answers/chat/<run>.plan             your answer to a plan card ("start", "cancel" or your own words), written by
//                                       the app only (bots can't write `answers/`, so a bot can't start its own plan).
// Shared:
//   scratch/app-claims.json             which bot is using which Mac app (use_app / done_with_app), 15 min expiry.
//   routines.json                       read by list_routines and to check create_routine; only the app writes it.

/// One thing a bot did with its chat tools.
public struct ChatAction: Codable, Equatable, Sendable {
    public enum Tool: String, Codable, Sendable {
        case react
        case sendGif = "send_gif"
        case startPoll = "start_poll"
        case vote
        case askUser = "ask_user"
        case sharePlan = "share_plan"
        case createRoutine = "create_routine"
    }

    public var id: String
    public var tool: Tool
    public var at: Date
    /// react
    public var emoji: String?
    /// send_gif
    public var search: String?
    /// start_poll
    public var question: String?
    public var options: [String]?
    /// vote: option number, from 1
    public var option: Int?
    public var reason: String?
    /// ask_user
    public var questions: [QuestionCard.Item]?
    /// share_plan
    public var message: String?
    public var steps: [String]?
    /// create_routine (already checked by the server; the app checks again and fixes the target to the chat)
    public var routine: RoutineRequest?

    public init(id: String = UUID().uuidString.lowercased(), tool: Tool, at: Date = Date(), emoji: String? = nil,
                search: String? = nil, question: String? = nil, options: [String]? = nil, option: Int? = nil,
                reason: String? = nil, questions: [QuestionCard.Item]? = nil, message: String? = nil,
                steps: [String]? = nil, routine: RoutineRequest? = nil) {
        self.id = id
        self.tool = tool
        self.at = at
        self.emoji = emoji
        self.search = search
        self.question = question
        self.options = options
        self.option = option
        self.reason = reason
        self.questions = questions
        self.message = message
        self.steps = steps
        self.routine = routine
    }

    public static func react(_ emoji: String) -> ChatAction { ChatAction(tool: .react, emoji: emoji) }
    public static func gif(_ search: String) -> ChatAction { ChatAction(tool: .sendGif, search: search) }
    public static func poll(_ question: String, _ options: [String]) -> ChatAction { ChatAction(tool: .startPoll, question: question, options: options) }
    public static func vote(_ option: Int, reason: String? = nil) -> ChatAction { ChatAction(tool: .vote, option: option, reason: reason) }

    /// One JSONL line (no newline).
    public func line() throws -> Data { try JSONCoding.lineEncoder().encode(self) }
}

/// Settings for one run of the chat tools server: command-line flags (what `ChatToolsRun` passes) or LP_* variables.
public struct ChatToolsConfig: Equatable, Sendable {
    public var actionsFile: String?
    public var planAnswerFile: String?
    /// Seconds before a plan starts by itself; 0 waits for your OK.
    public var planWait: Int
    public var claimsFile: String?
    public var botName: String
    public var botId: String?
    public var routinesFile: String?
    /// "bot:<id>" or "group:<id>": who a routine made in this chat goes to.
    public var routineTarget: String?

    public init(actionsFile: String? = nil, planAnswerFile: String? = nil, planWait: Int = 0, claimsFile: String? = nil,
                botName: String = "A bot", botId: String? = nil, routinesFile: String? = nil, routineTarget: String? = nil) {
        self.actionsFile = actionsFile
        self.planAnswerFile = planAnswerFile
        self.planWait = planWait
        self.claimsFile = claimsFile
        self.botName = botName
        self.botId = botId
        self.routinesFile = routinesFile
        self.routineTarget = routineTarget
    }

    /// Flag -> environment variable.
    static let keys: [(flag: String, env: String)] = [
        ("--actions", "LP_ACTIONS_FILE"), ("--plan-answer", "LP_PLAN_ANSWER_FILE"), ("--plan-wait", "LP_PLAN_WAIT"),
        ("--claims", "LP_CLAIMS_FILE"), ("--bot-name", "LP_BOT_NAME"), ("--bot-id", "LP_BOT_ID"),
        ("--routines", "LP_ROUTINES_FILE"), ("--routine-target", "LP_ROUTINE_TARGET"),
    ]

    /// Flags win over the environment.
    public static func from(arguments: [String], environment: [String: String]) -> ChatToolsConfig {
        var values: [String: String] = [:]
        for (flag, env) in keys {
            if let v = environment[env], !v.isEmpty { values[flag] = v }
        }
        var i = 0
        while i < arguments.count {
            if keys.contains(where: { $0.flag == arguments[i] }), i + 1 < arguments.count {
                values[arguments[i]] = arguments[i + 1]
                i += 2
            } else {
                i += 1
            }
        }
        return ChatToolsConfig(actionsFile: values["--actions"], planAnswerFile: values["--plan-answer"],
                               planWait: max(0, Int(values["--plan-wait"] ?? "") ?? 0), claimsFile: values["--claims"],
                               botName: values["--bot-name"] ?? "A bot", botId: values["--bot-id"],
                               routinesFile: values["--routines"], routineTarget: values["--routine-target"])
    }

    public var arguments: [String] {
        var out: [String] = []
        func add(_ flag: String, _ v: String?) { if let v, !v.isEmpty { out += [flag, v] } }
        add("--actions", actionsFile)
        add("--plan-answer", planAnswerFile)
        add("--plan-wait", "\(planWait)")
        add("--claims", claimsFile)
        add("--bot-name", botName)
        add("--bot-id", botId)
        add("--routines", routinesFile)
        add("--routine-target", routineTarget)
        return out
    }
}

extension LaunchpadPaths {
    /// Chat tool actions, one file per run (bots' tools may write here).
    public var chatActions: URL { approvalRequests.appendingPathComponent("chat", isDirectory: true) }
    public func chatActionsFile(_ runId: String) -> URL { chatActions.appendingPathComponent("\(Slug.make(runId)).actions.jsonl") }
    /// Your answers to plan cards (app only).
    public var planAnswers: URL { approvalAnswers.appendingPathComponent("chat", isDirectory: true) }
    public func planAnswerFile(_ runId: String) -> URL { planAnswers.appendingPathComponent("\(Slug.make(runId)).plan") }
    /// Which bot is using which Mac app.
    public var appClaimsFile: URL { launchpadData.appendingPathComponent("scratch/app-claims.json") }
    public var routinesFile: URL { root.appendingPathComponent("routines.json") }
    /// Files every bot shares (TEAM.md).
    public var shared: URL { root.appendingPathComponent("Shared", isDirectory: true) }
    public var teamNotes: URL { shared.appendingPathComponent("TEAM.md") }
    /// Saved prompts for the composer.
    public var savedPromptsFile: URL { launchpadData.appendingPathComponent("saved-prompts.json") }
}
