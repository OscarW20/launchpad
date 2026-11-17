import Foundation

// Tasks (hand a job to a bot or group; its status comes from the replies) and Workflows (steps that pass work from
// bot to bot, run by hand or on a schedule). On disk:
//
//   ~/Launchpad/workflows/<id>.json      one workflow each, so you or an agent can edit them as files
//   ~/Launchpad/work/tasks.json          tasks
//   ~/Launchpad/work/runs/<run-id>.json  each workflow run, saved after every step so it can resume after a quit
//   ~/Launchpad/work/log.json            run history (routines, workflows, tasks), newest 1500

/// A bot or a group (the same shape routines use).
public typealias WorkTarget = Routine.Target

// MARK: - Tasks

/// Something you asked a bot or group to get done. Its status comes from the chat it runs in.
public struct TaskItem: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: Codable, Hashable, Sendable {
        case ask
        /// A workflow's approval step waiting for your OK.
        case approval(run: String, step: Int)
    }

    public var id: String
    public var text: String
    public var target: WorkTarget
    /// The chat the task was sent in, and your message there (replies after it are the task's replies).
    public var chatId: String?
    public var messageId: String?
    public var kind: Kind
    public var createdAt: Date
    public var finishedAt: Date?
    public var dismissed: Bool

    public init(id: String = UUID().uuidString.lowercased(), text: String, target: WorkTarget, chatId: String? = nil,
                messageId: String? = nil, kind: Kind = .ask, createdAt: Date = Date(), finishedAt: Date? = nil, dismissed: Bool = false) {
        self.id = id
        self.text = text
        self.target = target
        self.chatId = chatId
        self.messageId = messageId
        self.kind = kind
        self.createdAt = createdAt
        self.finishedAt = finishedAt
        self.dismissed = dismissed
    }
}

public enum TaskStatus: String, Equatable, Sendable {
    case queued, working, needsYou, done, failed

    public var title: String {
        switch self {
        case .queued: return "Waiting"
        case .working: return "Working"
        case .needsYou: return "Needs you"
        case .done: return "Done"
        case .failed: return "Didn’t finish"
        }
    }

    /// Bot replies after the task's message, until you spoke again.
    public static func replies(after messageId: String, in history: [ChatMessage]) -> [ChatMessage] {
        guard let i = history.firstIndex(where: { $0.id == messageId }) else { return [] }
        var out: [ChatMessage] = []
        for m in history[(i + 1)...] {
            if m.role == .user { break }
            if m.role == .bot { out.append(m) }
        }
        return out
    }

    /// A task's status from its replies. `busy`: the chat is running right now.
    public static func of(replies: [ChatMessage], busy: Bool) -> TaskStatus {
        if replies.contains(where: { $0.status == .streaming }) { return .working }
        guard let last = replies.last else { return busy ? .working : .queued }
        if busy { return .working }
        if last.status == .failed { return .failed }
        if last.approval?.status == .pending { return .needsYou }
        let text = last.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasSuffix("?") ? .needsYou : .done
    }

    /// An approval task's status from its run.
    public static func of(approvalRun run: WorkflowRun?) -> TaskStatus {
        guard let run else { return .failed }
        if run.status == .waiting { return .needsYou }
        if run.status == .running { return .working }
        return run.approved == false ? .failed : .done
    }
}

// MARK: - Workflows

/// A chain of steps that passes work from bot to bot, run by hand or on a schedule.
public struct Workflow: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var steps: [WorkflowStep]
    /// When it runs by itself, using routine timing (`every`, `daily`, `hourly`, `weekly`, `once`). nil = by hand only.
    /// Folder and web address triggers aren't used here.
    public var schedule: Routine.Trigger?
    public var enabled: Bool
    public var lastRun: Date?
    public var createdAt: Date

    public init(id: String, name: String, steps: [WorkflowStep] = [], schedule: Routine.Trigger? = nil,
                enabled: Bool = true, lastRun: Date? = nil, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.steps = steps
        self.schedule = schedule
        self.enabled = enabled
        self.lastRun = lastRun
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey { case id, name, steps, schedule, enabled, lastRun, createdAt }

    /// Lenient, because people and agents edit these files by hand.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        steps = try c.decodeIfPresent([WorkflowStep].self, forKey: .steps) ?? []
        schedule = try? c.decodeIfPresent(Routine.Trigger.self, forKey: .schedule)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        lastRun = try? c.decodeIfPresent(Date.self, forKey: .lastRun)
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date(timeIntervalSince1970: 0)
    }

    /// The schedule as a routine, so workflows share the routine timing rules.
    public var timing: Routine? {
        guard let schedule, enabled else { return nil }
        switch schedule {
        case .newFile, .webhook: return nil
        default: break
        }
        return Routine(id: id, name: name, target: .bot(""), message: "", trigger: schedule,
                       lastRun: lastRun, createdAt: createdAt)
    }

    public var scheduleSummary: String { timing?.summary ?? "By hand" }
}

public struct WorkflowStep: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case prompt, agent, condition, approval, output
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .prompt: return "Prompt"
            case .agent: return "Bot step"
            case .condition: return "Condition"
            case .approval: return "Approval"
            case .output: return "Output"
            }
        }
        /// SF Symbol for the UI.
        public var symbol: String {
            switch self {
            case .prompt: return "text.bubble"
            case .agent: return "person.crop.circle"
            case .condition: return "arrow.triangle.branch"
            case .approval: return "hand.raised"
            case .output: return "paperplane"
            }
        }
        public var blurb: String {
            switch self {
            case .prompt: return "Starting text passed to the next step"
            case .agent: return "A bot or group does a job with the input"
            case .condition: return "Carry on only if the result matches"
            case .approval: return "Pause until you approve in Tasks"
            case .output: return "Post the result to a chat or save a file"
            }
        }
    }

    public enum Match: String, Codable, CaseIterable, Sendable { case contains, notContains }

    public var id: String
    public var kind: Kind
    /// Prompt text, the bot's instructions, the condition's words, or the approval question.
    public var text: String
    public var target: WorkTarget?
    public var match: Match
    /// Output: also save the result as a Markdown file in ~/Launchpad/work/outputs/.
    public var saveFile: Bool
    /// Bot step: how long to wait for the reply before giving up (nil = 45 minutes).
    public var timeoutMinutes: Int?

    public static let defaultTimeout = 45
    public static let timeoutChoices = [5, 15, 30, 45, 60, 120, 240, 480]
    public var timeout: Int { max(1, timeoutMinutes ?? Self.defaultTimeout) }

    public init(id: String = UUID().uuidString.lowercased(), kind: Kind, text: String = "", target: WorkTarget? = nil,
                match: Match = .contains, saveFile: Bool = false, timeoutMinutes: Int? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.target = target
        self.match = match
        self.saveFile = saveFile
        self.timeoutMinutes = timeoutMinutes
    }

    enum CodingKeys: String, CodingKey { case id, kind, text, target, match, saveFile, timeoutMinutes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.lowercased()
        kind = try c.decode(Kind.self, forKey: .kind)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        target = try? c.decodeIfPresent(WorkTarget.self, forKey: .target)
        match = (try? c.decodeIfPresent(Match.self, forKey: .match)) ?? .contains
        saveFile = try c.decodeIfPresent(Bool.self, forKey: .saveFile) ?? false
        timeoutMinutes = try? c.decodeIfPresent(Int.self, forKey: .timeoutMinutes)
    }

    public static func timeoutTitle(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : minutes % 60 == 0 ? "\(minutes / 60) hr" : "\(minutes / 60) hr \(minutes % 60) min"
    }
}

public struct WorkflowRun: Codable, Identifiable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case running, waiting, done, stopped, failed }

    public struct StepResult: Codable, Hashable, Sendable {
        public var step: Int
        public var text: String
        public var ok: Bool
        public init(step: Int, text: String, ok: Bool) { self.step = step; self.text = text; self.ok = ok }
    }

    public var id: String
    public var workflowId: String
    public var name: String
    public var trigger: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var status: Status
    public var current: Int
    public var results: [StepResult]
    public var note: String?
    public var approved: Bool?
    /// The text passed on to the next step, saved after every step.
    public var carry: String?
    /// A bot step in flight: the chat and message it was sent as, so a resumed run can pick up a reply that already
    /// came in instead of asking twice.
    public var waitingChat: String?
    public var waitingOn: String?
    /// The app quit during this step. Set while the run can still be resumed from there; cleared on Resume or Discard.
    public var resumeFrom: Int?

    public init(id: String = UUID().uuidString.lowercased(), workflowId: String, name: String, trigger: String,
                startedAt: Date = Date()) {
        self.id = id
        self.workflowId = workflowId
        self.name = name
        self.trigger = trigger
        self.startedAt = startedAt
        status = .running
        current = 0
        results = []
    }

    public var isLive: Bool { status == .running || status == .waiting }

    /// What a run that was going when the app quit looks like on the next launch: stopped, but resumable from the
    /// step that didn't finish.
    public func interruptedByQuit(at now: Date = Date()) -> WorkflowRun {
        guard isLive else { return self }
        var r = self
        r.resumeFrom = current
        r.status = .stopped
        r.note = "Stopped when Launchpad quit."
        r.finishedAt = r.finishedAt ?? now
        return r
    }

    /// The run picked up again from `resumeFrom`.
    public func resumed() -> WorkflowRun? {
        guard let from = resumeFrom else { return nil }
        var r = self
        r.current = from
        r.status = .running
        r.finishedAt = nil
        r.note = nil
        r.resumeFrom = nil
        r.approved = nil   // an approval that was pending asks again
        return r
    }

    /// At an approval step: waiting for a fresh answer. The OK given to an earlier approval step doesn't count.
    public mutating func awaitApproval() {
        status = .waiting
        approved = nil
    }

    public mutating func record(_ step: Int, _ text: String, ok: Bool) {
        results.removeAll { $0.step == step }
        results.append(StepResult(step: step, text: text, ok: ok))
    }
}

// MARK: - Run history

public struct RunLogEntry: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case routine, workflow, task }
    public enum Outcome: String, Codable, Sendable { case running, done, failed, stopped }

    public var id: String
    public var kind: Kind
    public var name: String
    public var target: WorkTarget?
    /// The routine, workflow or task id.
    public var sourceId: String?
    public var chatId: String?
    public var runId: String?
    public var date: Date
    public var outcome: Outcome

    public init(id: String = UUID().uuidString.lowercased(), kind: Kind, name: String, target: WorkTarget? = nil,
                sourceId: String? = nil, chatId: String? = nil, runId: String? = nil, date: Date = Date(), outcome: Outcome = .running) {
        self.id = id
        self.kind = kind
        self.name = name
        self.target = target
        self.sourceId = sourceId
        self.chatId = chatId
        self.runId = runId
        self.date = date
        self.outcome = outcome
    }
}

// MARK: - Store

extension LaunchpadPaths {
    public var workflows: URL { root.appendingPathComponent("workflows", isDirectory: true) }
    public var work: URL { root.appendingPathComponent("work", isDirectory: true) }
    public func workflowFile(_ id: String) -> URL { workflows.appendingPathComponent("\(id).json") }
    public var workRuns: URL { work.appendingPathComponent("runs", isDirectory: true) }
    public var workOutputs: URL { work.appendingPathComponent("outputs", isDirectory: true) }
}

public final class WorkStore: @unchecked Sendable {
    public static let tasksKept = 400
    public static let runsKept = 200
    public static let logKept = 1500

    public let paths: LaunchpadPaths
    private let fm = FileManager.default

    public init(paths: LaunchpadPaths) {
        self.paths = paths
    }

    private var tasksURL: URL { paths.work.appendingPathComponent("tasks.json") }
    private var logURL: URL { paths.work.appendingPathComponent("log.json") }

    private func ensure(_ dir: URL) throws {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // Workflows

    public func loadWorkflows() -> [Workflow] {
        let files = ((try? fm.contentsOfDirectory(atPath: paths.workflows.path)) ?? []).filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
        var out: [Workflow] = []
        for name in files.sorted() {
            guard let data = try? Data(contentsOf: paths.workflows.appendingPathComponent(name)),
                  var wf = try? JSONCoding.decoder().decode(Workflow.self, from: data) else { continue }
            let fileId = String(name.dropLast(5))
            if wf.id.isEmpty || wf.id != fileId { wf.id = fileId }   // the file name is the id
            out.append(wf)
        }
        return out.sorted { $0.createdAt < $1.createdAt }
    }

    public func save(_ wf: Workflow) throws {
        try ensure(paths.workflows)
        try JSONCoding.encoder().encode(wf).write(to: paths.workflowFile(wf.id), options: .atomic)
    }

    public func deleteWorkflow(_ id: String) {
        try? fm.removeItem(at: paths.workflowFile(id))
    }

    /// A new workflow id that isn't taken.
    public func newWorkflowId(_ name: String) -> String {
        let taken = Set(loadWorkflows().map(\.id))
        return Slug.unique(name.isEmpty ? "workflow" : name, taken: taken)
    }

    // Tasks

    public func loadTasks() -> [TaskItem] {
        guard let data = try? Data(contentsOf: tasksURL) else { return [] }
        return (try? JSONCoding.decoder().decode([TaskItem].self, from: data)) ?? []
    }

    public func saveTasks(_ tasks: [TaskItem]) throws {
        try ensure(paths.work)
        try JSONCoding.encoder().encode(Array(tasks.suffix(Self.tasksKept))).write(to: tasksURL, options: .atomic)
    }

    // Runs

    /// All runs, oldest first. With `afterQuit`, runs that were going are marked stopped-but-resumable (call it once
    /// at launch).
    public func loadRuns(afterQuit: Bool = false, now: Date = Date()) -> [WorkflowRun] {
        let files = ((try? fm.contentsOfDirectory(atPath: paths.workRuns.path)) ?? []).filter { $0.hasSuffix(".json") }
        var runs: [WorkflowRun] = []
        for name in files {
            guard let data = try? Data(contentsOf: paths.workRuns.appendingPathComponent(name)),
                  let run = try? JSONCoding.decoder().decode(WorkflowRun.self, from: data) else { continue }
            if afterQuit, run.isLive {
                let stopped = run.interruptedByQuit(at: now)
                try? save(stopped)
                runs.append(stopped)
            } else {
                runs.append(run)
            }
        }
        runs.sort { $0.startedAt < $1.startedAt }
        // Keep the newest; older finished runs go.
        if runs.count > Self.runsKept {
            for old in runs.prefix(runs.count - Self.runsKept) where !old.isLive && old.resumeFrom == nil {
                try? fm.removeItem(at: paths.workRuns.appendingPathComponent("\(old.id).json"))
            }
            runs = runs.filter { fm.fileExists(atPath: paths.workRuns.appendingPathComponent("\($0.id).json").path) }
        }
        return runs
    }

    public func save(_ run: WorkflowRun) throws {
        try ensure(paths.workRuns)
        try JSONCoding.encoder().encode(run).write(to: paths.workRuns.appendingPathComponent("\(run.id).json"), options: .atomic)
    }

    // Log

    public func loadLog(afterQuit: Bool = false) -> [RunLogEntry] {
        guard let data = try? Data(contentsOf: logURL),
              var log = try? JSONCoding.decoder().decode([RunLogEntry].self, from: data) else { return [] }
        if afterQuit {
            for i in log.indices where log[i].kind == .workflow && log[i].outcome == .running { log[i].outcome = .stopped }
        }
        return log
    }

    public func saveLog(_ log: [RunLogEntry]) throws {
        try ensure(paths.work)
        try JSONCoding.encoder().encode(Array(log.suffix(Self.logKept))).write(to: logURL, options: .atomic)
    }

    public func appendLog(_ entry: RunLogEntry) {
        var log = loadLog()
        log.append(entry)
        try? saveLog(log)
    }

    public func updateLog(runId: String, outcome: RunLogEntry.Outcome) {
        var log = loadLog()
        guard let i = log.lastIndex(where: { $0.runId == runId }) else { return }
        log[i].outcome = outcome
        try? saveLog(log)
    }

    /// Writes a workflow's output as Markdown in work/outputs/. Returns the file.
    public func writeOutput(workflow name: String, body: String, now: Date = Date()) throws -> URL {
        try ensure(paths.workOutputs)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmmss"
        let safe = String(name.map { "/:\\".contains($0) ? "-" : $0 })
        let file = paths.workOutputs.appendingPathComponent("\(safe.isEmpty ? "Workflow" : safe) \(f.string(from: now)).md")
        try "# \(name)\n\n\(body)\n".write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}
