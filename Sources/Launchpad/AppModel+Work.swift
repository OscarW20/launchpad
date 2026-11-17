#if os(macOS)
import SwiftUI
import AppKit
import LaunchpadCore

// Tasks and workflows: the app's side of `WorkflowEngine`.

extension AppModel: WorkflowStepExecutor {
    // MARK: - Reading work state (touching `workRevision` so views refresh)

    var visibleTasks: [TaskItem] {
        _ = workRevision
        return workflowEngine.tasks.filter { !$0.dismissed }.sorted { $0.createdAt > $1.createdAt }
    }

    var workflows: [Workflow] {
        _ = workRevision
        return workflowEngine.workflows
    }

    var workflowRuns: [WorkflowRun] {
        _ = workRevision
        return workflowEngine.runs
    }

    var runLog: [RunLogEntry] {
        _ = workRevision
        return workflowEngine.log
    }

    func task(_ id: String?) -> TaskItem? {
        guard let id else { return nil }
        return visibleTasks.first { $0.id == id }
    }

    func status(of task: TaskItem) -> TaskStatus {
        _ = workRevision
        let history = task.chatId.map { messages(for: $0) } ?? []
        return workflowEngine.status(of: task, history: history, busy: task.chatId.map { isRunning($0) } ?? false)
    }

    /// Tasks that need your answer (for the sidebar badge).
    var tasksNeedingYou: Int {
        visibleTasks.filter { status(of: $0) == .needsYou }.count
    }

    /// Loads the chats tasks ran in, so their status can be worked out.
    func loadTaskChats() {
        for t in workflowEngine.tasks where !t.dismissed { if let c = t.chatId, chat(c) != nil { loadMessagesIfNeeded(c) } }
    }

    // MARK: - Tasks

    /// The target's everyday chat (not a routine's or a workflow's), if it has one.
    func primaryChat(for target: WorkTarget) -> String? {
        chats.first { c in
            guard !c.title.hasPrefix("⏰"), !c.title.hasPrefix("🔁") else { return false }
            switch target {
            case .bot(let id): return c.kind == .bot && c.botId == id
            case .group(let id): return c.kind == .group && c.groupId == id
            }
        }?.id
    }

    /// Sends a task to a bot or group and tracks it on the Tasks page.
    func newTask(_ text: String, to target: WorkTarget) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard targetExists(target) else {
            alertMessage = "That bot or group isn't in your Launchpad folder any more."
            return
        }
        var chatId = primaryChat(for: target)
        if let c = chatId, isRunning(c) { chatId = nil }
        if chatId == nil { chatId = makeChat(for: target, title: targetName(target)) }
        guard let chatId else { return }
        loadMessagesIfNeeded(chatId)
        send(chatId: chatId, text: text)
        guard let msg = messages(for: chatId).last(where: { $0.role == .user && $0.text == text }) else { return }
        let task = workflowEngine.addTask(text, to: target, chatId: chatId, messageId: msg.id)
        selectedTaskId = task.id
    }

    func dismissTask(_ id: String) {
        workflowEngine.dismissTask(id)
        if selectedTaskId == id { selectedTaskId = nil }
    }

    func answerWorkflowApproval(_ task: TaskItem, approve: Bool) {
        guard case .approval(let runId, _) = task.kind else { return }
        workflowEngine.answer(runId, approve: approve)
    }

    // MARK: - Workflows

    func newWorkflow() {
        do {
            let first: [WorkflowStep] = [
                WorkflowStep(kind: .prompt, text: "What to work on…"),
                WorkflowStep(kind: .agent, text: "Do the job described in the input.",
                             target: bots.first.map { .bot($0.id) } ?? groups.first.map { .group($0.id) }),
            ]
            let wf = try workflowEngine.newWorkflow(name: "New workflow", steps: first)
            selectedWorkflowId = wf.id
        } catch {
            alertMessage = "Couldn't make the workflow: \(error.localizedDescription)"
        }
    }

    func saveWorkflow(_ wf: Workflow) {
        do {
            try workflowEngine.save(wf)
        } catch {
            alertMessage = "Couldn't save \(wf.name): \(error.localizedDescription)"
        }
    }

    func deleteWorkflow(_ id: String) {
        workflowEngine.deleteWorkflow(id)
        if selectedWorkflowId == id { selectedWorkflowId = nil }
    }

    func startWorkflow(_ id: String) {
        if workflowEngine.start(id) == nil {
            alertMessage = "That workflow is already running."
        }
    }

    // MARK: - WorkflowStepExecutor

    /// The chat a workflow's bot steps run in: "🔁 <workflow>" with that bot or group.
    private func workflowChat(for target: WorkTarget, name: String) -> String? {
        let title = "🔁 \(name)"
        let existing = chats.first { c in
            guard c.title == title else { return false }
            switch target {
            case .bot(let id): return c.kind == .bot && c.botId == id
            case .group(let id): return c.kind == .group && c.groupId == id
            }
        }
        return existing?.id ?? makeChat(for: target, title: title)
    }

    func runAgentStep(_ request: AgentStepRequest, sent: @escaping @MainActor (String, String) -> Void) async -> AgentStepResult {
        guard let chatId = workflowChat(for: request.target, name: request.workflowName) else {
            return AgentStepResult(ok: false, text: "Couldn't open a chat with \(targetName(request.target)).")
        }
        return await withTaskCancellationHandler {
            await self.runStep(request, chatId: chatId, sent: sent)
        } onCancel: {
            Task { @MainActor [weak self] in self?.stop(chatId) }
        }
    }

    private func runStep(_ request: AgentStepRequest, chatId: String,
                         sent: @escaping @MainActor (String, String) -> Void) async -> AgentStepResult {
        // Wait for the chat to be free (another step, or you, may be using it).
        while isRunning(chatId) {
            if Task.isCancelled { return AgentStepResult(ok: false, text: "Stopped.") }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        if Task.isCancelled { return AgentStepResult(ok: false, text: "Stopped.") }
        loadMessagesIfNeeded(chatId)
        let msg = ChatMessage(role: .user, text: request.prompt)
        append(msg, to: chatId)
        sent(chatId, msg.id)
        let task: Task<Void, Never>?
        switch request.target {
        case .bot(let id):
            guard let b = bot(id) else { return AgentStepResult(ok: false, text: "That bot isn't there any more.") }
            task = startSolo(chatId, bot: b, prompt: request.prompt)
        case .group:
            task = startGroup(chatId) { await $0.runTask() }
        }
        await task?.value
        return stepResult(TaskStatus.replies(after: msg.id, in: messages(for: chatId)), group: request.target.isGroup)
            ?? AgentStepResult(ok: false, text: "No reply came back.")
    }

    private func stepResult(_ replies: [ChatMessage], group: Bool) -> AgentStepResult? {
        guard let last = replies.last else { return nil }
        if group {
            let ok = replies.allSatisfy { $0.status == .done }
            let text = replies.map { "\(bot($0.botId)?.name ?? "Bot"): \($0.text)" }.joined(separator: "\n\n")
            return AgentStepResult(ok: ok, text: text)
        }
        return AgentStepResult(ok: last.status == .done, text: last.text)
    }

    func finishedReply(chatId: String, messageId: String) -> AgentStepResult? {
        guard chat(chatId) != nil, !isRunning(chatId) else { return nil }
        loadMessagesIfNeeded(chatId)
        let replies = TaskStatus.replies(after: messageId, in: messages(for: chatId))
        guard !replies.isEmpty, !replies.contains(where: { $0.status == .streaming }) else { return nil }
        return stepResult(replies, group: chat(chatId)?.kind == .group)
    }

    func askApproval(_ request: ApprovalStepRequest) async -> Bool? {
        _ = NSApp.requestUserAttention(.informationalRequest)
        return await workflowEngine.approvals.wait(request.runId)
    }

    func postOutput(_ text: String, workflowName: String, to target: WorkTarget) async {
        guard let chatId = primaryChat(for: target) ?? makeChat(for: target, title: targetName(target)) else { return }
        append(ChatMessage(role: .notice, text: "📤 \(workflowName)\n\n\(text)"), to: chatId)
    }
}
#endif
