#if os(macOS)
import SwiftUI
import AppKit
import LaunchpadCore

// MARK: - Shared

/// Picks a bot or group.
struct TargetPicker: View {
    @Environment(AppModel.self) private var model
    let title: String
    @Binding var target: WorkTarget?
    var allowNone = false

    var body: some View {
        Picker(title, selection: Binding(get: { target.map(Self.key) ?? "" }, set: { target = Self.target(from: $0) })) {
            if allowNone || target == nil { Text("Nobody").tag("") }
            ForEach(model.groups) { g in Text("\(g.emoji) \(g.displayName)").tag("group:\(g.id)") }
            ForEach(model.bots) { b in Text("\(b.emoji) \(b.name)").tag("bot:\(b.id)") }
        }
    }

    static func key(_ t: WorkTarget) -> String {
        switch t {
        case .bot(let id): return "bot:\(id)"
        case .group(let id): return "group:\(id)"
        }
    }

    static func target(from key: String) -> WorkTarget? {
        if key.hasPrefix("group:") { return .group(String(key.dropFirst(6))) }
        if key.hasPrefix("bot:") { return .bot(String(key.dropFirst(4))) }
        return nil
    }
}

struct StatusPill: View {
    let status: TaskStatus

    var body: some View {
        Label(status.title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(colour.opacity(0.16), in: Capsule())
            .foregroundStyle(colour)
    }

    private var symbol: String {
        switch status {
        case .queued: return "hourglass"
        case .working: return "ellipsis.circle"
        case .needsYou: return "hand.raised.fill"
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private var colour: Color {
        switch status {
        case .queued: return .secondary
        case .working: return Theme.accent
        case .needsYou: return Theme.warning
        case .done: return Theme.success
        case .failed: return Theme.failure
        }
    }
}

// MARK: - Tasks

struct TaskListView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var target: WorkTarget?

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                TargetPicker(title: "For", target: $target)
                HStack(alignment: .bottom, spacing: Theme.Space.s) {
                    TextField("What needs doing?", text: $text, axis: .vertical)
                        .textFieldStyle(PillFieldStyle())
                        .lineLimit(1...4)
                        .onSubmit(send)
                    Button(action: send) { Label("Send the task", systemImage: "paperplane.fill") }
                        .buttonStyle(CircleButtonStyle(kind: .accent, size: 34))
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || target == nil)
                        .help("Send the task")
                }
            }
            .card(padding: Theme.Space.m, radius: 20)
            .padding(.horizontal, Theme.Space.m)
            .padding(.bottom, Theme.Space.s)
            if model.visibleTasks.isEmpty {
                VStack(spacing: 8) {
                    Text("No tasks yet.").font(Theme.rounded(.headline))
                    Text("Hand a job to a bot or group above. Workflow approvals show up here too.")
                        .foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PanelList(selection: $model.selectedTaskId) {
                    ForEach(model.visibleTasks) { task in
                        TaskRow(task: task).selectableRow(task.id)
                            .contextMenu {
                                Button("Dismiss") { model.dismissTask(task.id) }
                            }
                    }
                }
            }
        }
        .navigationTitle("Tasks")
        .columnHeader("Tasks") { EmptyView() }
        .onAppear {
            model.loadTaskChats()
            if target == nil { target = model.bots.first.map { .bot($0.id) } ?? model.groups.first.map { .group($0.id) } }
        }
    }

    private func send() {
        guard let target else { return }
        model.newTask(text, to: target)
        text = ""
    }
}

struct TaskRow: View {
    @Environment(AppModel.self) private var model
    let task: TaskItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                StatusPill(status: model.status(of: task))
                Spacer()
                Text(TimeLabel.short(task.createdAt))
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }
            Text(task.text)
                .font(Theme.rounded(.body, weight: .medium))
                .lineLimit(2)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        if case .approval(let runId, _) = task.kind {
            return "Approval · \(model.workflowEngine.run(runId)?.name ?? "workflow")"
        }
        return "For \(model.targetName(task.target))"
    }
}

struct TaskDetailView: View {
    @Environment(AppModel.self) private var model
    let taskId: String

    var body: some View {
        if let task = model.task(taskId) {
            let status = model.status(of: task)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        StatusPill(status: status)
                        Spacer()
                        if let chatId = task.chatId, model.chat(chatId) != nil {
                            Button("Open Chat") { model.show(chat: chatId) }
                        }
                        Button("Dismiss") { model.dismissTask(task.id) }
                    }
                    .buttonStyle(SoftButtonStyle())
                    Text(task.text)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                    if let runId = approvalRun(task) {
                        approval(task, runId: runId, status: status)
                    } else if let chatId = task.chatId, let msgId = task.messageId {
                        let replies = TaskStatus.replies(after: msgId, in: model.messages(for: chatId))
                        if replies.isEmpty {
                            Text(status == .working ? "Working on it…" : "No reply yet.")
                                .foregroundStyle(Theme.secondary)
                        }
                        ForEach(replies) { m in
                            MessageRow(message: m, chatId: chatId)
                        }
                        ForEach(model.liveRuns(for: chatId)) { run in
                            MessageRow(message: run.message, chatId: chatId, activeStep: run.builder.activeStep, isLive: true)
                        }
                    }
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: 860, alignment: .leading)
            }
            .navigationTitle("Task")
            .onAppear { model.loadTaskChats() }
        } else {
            EmptyDetail(symbol: "checklist", title: "Tasks", message: "Pick a task to see how it's going.")
        }
    }

    private func approvalRun(_ task: TaskItem) -> String? {
        if case .approval(let runId, _) = task.kind { return runId }
        return nil
    }

    @ViewBuilder private func approval(_ task: TaskItem, runId: String, status: TaskStatus) -> some View {
        let run = model.workflowEngine.run(runId)
        VStack(alignment: .leading, spacing: 10) {
            Label("\(run?.name ?? "A workflow") is waiting for your OK", systemImage: "hand.raised.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)
            if status == .needsYou {
                HStack {
                    Button {
                        model.answerWorkflowApproval(task, approve: true)
                    } label: {
                        Label("Approve", systemImage: "checkmark")
                    }
                    .buttonStyle(PillButtonStyle())
                    Button {
                        model.answerWorkflowApproval(task, approve: false)
                    } label: {
                        Label("Decline", systemImage: "xmark")
                    }
                    .buttonStyle(SoftButtonStyle())
                }
                .controlSize(.large)
            } else if run?.approved == true {
                Label("Approved", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
            } else if run?.approved == false {
                Label("Declined", systemImage: "xmark.circle.fill").foregroundStyle(Theme.secondary)
            } else {
                Text(run?.note ?? "This run isn't waiting any more.").foregroundStyle(Theme.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: Theme.Space.l, radius: 22)
    }
}

// MARK: - Workflows

struct WorkflowListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.workflows.isEmpty {
                VStack(spacing: 10) {
                    Text("No workflows yet.").font(Theme.rounded(.headline))
                    Text("Chain steps: a prompt, bots doing jobs, a check, your OK, and where the result goes.")
                        .foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.center)
                    Button("New Workflow") { model.newWorkflow() }
                        .buttonStyle(PillButtonStyle())
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PanelList(selection: $model.selectedWorkflowId) {
                    ForEach(model.workflows) { wf in
                        HStack(spacing: 10) {
                            Image(systemName: model.workflowEngine.isRunning(wf.id) ? "play.fill" : "flowchart")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(wf.enabled ? Theme.accentText : Theme.secondary)
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(wf.enabled ? Theme.accentSoft : Theme.field))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(wf.name).font(Theme.rounded(.body, weight: .semibold))
                                Text("\(wf.steps.count) step\(wf.steps.count == 1 ? "" : "s") · \(wf.scheduleSummary)")
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                        .selectableRow(wf.id)
                        .contextMenu {
                            Button("Run") { model.startWorkflow(wf.id) }
                            Button("Show File in Finder") { SystemActions.reveal(model.paths.workflowFile(wf.id)) }
                            Button("Delete", role: .destructive) { model.deleteWorkflow(wf.id) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Workflows")
        .columnHeader("Workflows") {
            Button { model.newWorkflow() } label: { Label("New Workflow", systemImage: "plus") }
                .help("Create a workflow")
        }
    }
}

struct WorkflowDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case steps = "Steps", runs = "Runs", history = "History"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    let workflowId: String
    @State private var draft: Workflow?
    @State private var original: Workflow?
    @State private var tab: Tab = .steps
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ResumeBanner(workflowId: workflowId)
            PillTabs(selection: $tab, options: Tab.allCases.map { ($0.rawValue, $0) })
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.xl)
                .padding(.bottom, Theme.Space.s)
            switch tab {
            case .steps:
                if let binding = Binding($draft) {
                    WorkflowEditor(workflow: binding)
                } else {
                    EmptyState(symbol: "questionmark.circle", title: "Workflow not found")
                }
            case .runs:
                WorkflowRunsView(workflowId: workflowId)
            case .history:
                RunHistoryView()
            }
        }
        .navigationTitle(draft?.name ?? "Workflow")
        .toolbar {
            ToolbarItemGroup {
                if draft != original {
                    Button("Revert") { load() }
                }
                Button("Save") {
                    if let d = draft { model.saveWorkflow(d); load() }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(draft == original)
            }
        }
        .onAppear(perform: load)
        .onChange(of: model.workflows) {
            if draft == original { load() }
        }
        .confirmationDialog("Delete \(draft?.name ?? "this workflow")?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.deleteWorkflow(workflowId) }
        } message: {
            Text("Its file in ~/Launchpad/workflows is removed. Past runs stay in History.")
        }
    }

    private var header: some View {
        let running = model.workflowEngine.isRunning(workflowId)
        let live = model.workflowRuns.last { $0.workflowId == workflowId && $0.isLive }
        return HStack(spacing: 12) {
            IconTile(symbol: "flowchart", size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(draft?.name ?? workflowId)
                    .font(Theme.rounded(.title2, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text(subtitle(live))
                    .foregroundStyle(Theme.secondary)
            }
            Spacer()
            Button { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
            if running, let live {
                Button { model.workflowEngine.stop(live.id) } label: { Label("Stop", systemImage: "stop.fill") }
            } else {
                Button {
                    if let d = draft, d != original { model.saveWorkflow(d); load() }
                    model.startWorkflow(workflowId)
                    tab = .runs
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .buttonStyle(PillButtonStyle())
                .disabled((draft?.steps ?? []).isEmpty)
            }
        }
        .buttonStyle(SoftButtonStyle())
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.l)
    }

    private func subtitle(_ live: WorkflowRun?) -> String {
        guard let live else { return draft?.scheduleSummary ?? "" }
        let count = draft?.steps.count ?? 0
        let step = min(live.current + 1, max(1, count))
        let waiting = live.status == .waiting ? ", waiting for your OK in Tasks" : ""
        return "Running: step \(step) of \(count)\(waiting)"
    }

    private func load() {
        draft = model.workflowEngine.workflow(workflowId)
        original = draft
    }
}

/// "Stopped when Launchpad quit" with Resume / Discard.
struct ResumeBanner: View {
    @Environment(AppModel.self) private var model
    let workflowId: String

    var body: some View {
        let _ = model.workRevision
        if let run = model.workflowEngine.resumableRuns.last(where: { $0.workflowId == workflowId }) {
            HStack(spacing: 10) {
                Image(systemName: "pause.circle.fill").foregroundStyle(Theme.warning)
                Text("A run stopped when Launchpad quit, at step \((run.resumeFrom ?? 0) + 1).")
                Spacer()
                Button("Resume") { Task { await model.workflowEngine.resume(run.id) } }
                    .buttonStyle(PillButtonStyle())
                Button("Discard") { model.workflowEngine.discardResume(run.id) }
            }
            .buttonStyle(SoftButtonStyle())
            .controlSize(.small)
            .padding(Theme.Space.m)
            .background(Theme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.warning.opacity(0.35)))
            .padding(.horizontal, Theme.Space.xl)
            .padding(.bottom, 8)
        }
    }
}

struct WorkflowEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var workflow: Workflow

    var body: some View {
        Form {
            Section("Workflow") {
                TextField("Name", text: $workflow.name)
                Toggle("On", isOn: $workflow.enabled)
                    .help("Off: its schedule doesn't run it. You can still run it by hand.")
            }
            Section {
                Picker("Runs", selection: Binding(get: { ScheduleKind(workflow.schedule) }, set: { workflow.schedule = $0.defaultTrigger(current: workflow.schedule) })) {
                    ForEach(ScheduleKind.allCases) { Text($0.rawValue).tag($0) }
                }
                scheduleFields
            } header: {
                Text("When")
            } footer: {
                Text("Scheduled workflows run while Launchpad is open.")
            }
            ForEach($workflow.steps) { $step in
                let id = step.id
                StepEditor(step: $step, index: workflow.steps.firstIndex { $0.id == id } ?? 0, count: workflow.steps.count,
                           move: { move(id, by: $0) }, remove: { workflow.steps.removeAll { $0.id == id } })
            }
            Section {
                Menu {
                    ForEach(WorkflowStep.Kind.allCases) { kind in
                        Button {
                            add(kind)
                        } label: {
                            Label("\(kind.title): \(kind.blurb)", systemImage: kind.symbol)
                        }
                    }
                } label: {
                    Label("Add a Step", systemImage: "plus")
                }
            }
        }
        .themedForm()
    }

    @ViewBuilder private var scheduleFields: some View {
        switch workflow.schedule {
        case let .daily(hour, minute, weekdays)?:
            DatePicker("Time", selection: Binding(get: { time(hour, minute) }, set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                workflow.schedule = .daily(hour: c.hour ?? 9, minute: c.minute ?? 0, weekdaysOnly: weekdays)
            }), displayedComponents: .hourAndMinute)
            Toggle("Weekdays only", isOn: Binding(get: { weekdays }, set: { workflow.schedule = .daily(hour: hour, minute: minute, weekdaysOnly: $0) }))
        case let .weekly(weekday, hour, minute)?:
            Picker("Day", selection: Binding(get: { weekday }, set: { workflow.schedule = .weekly(weekday: $0, hour: hour, minute: minute) })) {
                ForEach(1...7, id: \.self) { d in Text(Calendar.current.weekdaySymbols[d - 1]).tag(d) }
            }
            DatePicker("Time", selection: Binding(get: { time(hour, minute) }, set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                workflow.schedule = .weekly(weekday: weekday, hour: c.hour ?? 9, minute: c.minute ?? 0)
            }), displayedComponents: .hourAndMinute)
        case .hourly(let minute)?:
            Stepper("At :\(String(format: "%02d", minute)) past the hour", value: Binding(get: { minute }, set: { workflow.schedule = .hourly(minute: $0) }), in: 0...59, step: 5)
        case .every(let minutes)?:
            Picker("Every", selection: Binding(get: { minutes }, set: { workflow.schedule = .every(minutes: $0) })) {
                Text("30 minutes").tag(30)
                Text("hour").tag(60)
                Text("2 hours").tag(120)
                Text("4 hours").tag(240)
                Text("day").tag(1440)
                if ![30, 60, 120, 240, 1440].contains(minutes) { Text("\(minutes) minutes").tag(minutes) }
            }
        case .once(let at)?:
            DatePicker("At", selection: Binding(get: { at }, set: { workflow.schedule = .once(at: $0) }), displayedComponents: [.date, .hourAndMinute])
        default:
            EmptyView()
        }
    }

    private func time(_ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }

    private func move(_ id: String, by offset: Int) {
        guard let index = workflow.steps.firstIndex(where: { $0.id == id }) else { return }
        let to = index + offset
        guard workflow.steps.indices.contains(to) else { return }
        workflow.steps.swapAt(index, to)
    }

    private func add(_ kind: WorkflowStep.Kind) {
        let lastTarget = workflow.steps.last { $0.target != nil }?.target
            ?? model.bots.first.map { .bot($0.id) } ?? model.groups.first.map { .group($0.id) }
        var step = WorkflowStep(kind: kind)
        switch kind {
        case .agent: step.target = lastTarget
        case .output: step.target = lastTarget
        default: break
        }
        workflow.steps.append(step)
    }

    enum ScheduleKind: String, CaseIterable, Identifiable {
        case manual = "By hand", daily = "Every day", weekly = "Every week", hourly = "Every hour", every = "Every few hours", once = "Once"
        var id: String { rawValue }

        init(_ t: Routine.Trigger?) {
            switch t {
            case .daily?: self = .daily
            case .weekly?: self = .weekly
            case .hourly?: self = .hourly
            case .every?: self = .every
            case .once?: self = .once
            default: self = .manual
            }
        }

        func defaultTrigger(current: Routine.Trigger?) -> Routine.Trigger? {
            if ScheduleKind(current) == self { return current }
            switch self {
            case .manual: return nil
            case .daily: return .daily(hour: 9, minute: 0, weekdaysOnly: true)
            case .weekly: return .weekly(weekday: 2, hour: 9, minute: 0)
            case .hourly: return .hourly(minute: 0)
            case .every: return .every(minutes: 240)
            case .once: return .once(at: Date().addingTimeInterval(3600))
            }
        }
    }
}

struct StepEditor: View {
    @Binding var step: WorkflowStep
    let index: Int
    let count: Int
    let move: (Int) -> Void
    let remove: () -> Void

    var body: some View {
        Section {
            switch step.kind {
            case .prompt:
                TextEditor(text: $step.text).frame(minHeight: 60)
            case .agent:
                TargetPicker(title: "Bot or group", target: $step.target)
                TextEditor(text: $step.text).frame(minHeight: 60)
                Picker("Give up after", selection: Binding(get: { step.timeout }, set: { step.timeoutMinutes = $0 })) {
                    ForEach(WorkflowStep.timeoutChoices, id: \.self) { Text(WorkflowStep.timeoutTitle($0)).tag($0) }
                    if !WorkflowStep.timeoutChoices.contains(step.timeout) { Text(WorkflowStep.timeoutTitle(step.timeout)).tag(step.timeout) }
                }
            case .condition:
                Picker("Carry on if the result", selection: $step.match) {
                    Text("contains").tag(WorkflowStep.Match.contains)
                    Text("doesn't contain").tag(WorkflowStep.Match.notContains)
                }
                TextField("Words", text: $step.text, prompt: Text("e.g. APPROVED"))
            case .approval:
                TextField("Question", text: $step.text, prompt: Text("e.g. Send this to the team?"))
            case .output:
                TargetPicker(title: "Post in the chat with", target: $step.target, allowNone: true)
                Toggle("Also save as a Markdown file", isOn: $step.saveFile)
            }
        } header: {
            HStack {
                Label("\(index + 1). \(step.kind.title)", systemImage: step.kind.symbol)
                Text(step.kind.blurb).font(.caption).foregroundStyle(Theme.secondary)
                Spacer()
                Button { move(-1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                Button { move(1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == count - 1)
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }
            }
            .buttonStyle(.borderless)
        } footer: {
            if step.kind == .agent && step.target == nil {
                Text("Pick a bot or group for this step.").foregroundStyle(Theme.warning)
            }
        }
    }
}

struct WorkflowRunsView: View {
    @Environment(AppModel.self) private var model
    let workflowId: String

    var body: some View {
        let runs = model.workflowRuns.filter { $0.workflowId == workflowId }.reversed()
        let steps = model.workflowEngine.workflow(workflowId)?.steps ?? []
        List {
            if runs.isEmpty {
                Text("No runs yet. Press Run to start one.").foregroundStyle(Theme.secondary)
            }
            ForEach(Array(runs)) { run in
                DisclosureGroup {
                    ForEach(run.results.sorted { $0.step < $1.step }, id: \.step) { result in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(result.ok ? Theme.success : Theme.failure)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(steps.indices.contains(result.step) ? "\(result.step + 1). \(steps[result.step].kind.title)" : "Step \(result.step + 1)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.secondary)
                                Text(result.text)
                                    .font(.callout)
                                    .lineLimit(8)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    if let note = run.note { Text(note).font(.callout).foregroundStyle(Theme.secondary) }
                    if let chat = run.waitingChat, model.chat(chat) != nil {
                        Button("Open Chat") { model.show(chat: chat) }
                    }
                } label: {
                    HStack {
                        Image(systemName: symbol(run.status)).foregroundStyle(colour(run.status))
                        Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                        Text("· \(run.trigger)").foregroundStyle(Theme.secondary)
                        Spacer()
                        Text(title(run.status)).font(.caption).foregroundStyle(Theme.secondary)
                        if run.isLive {
                            Button("Stop") { model.workflowEngine.stop(run.id) }.controlSize(.small)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .buttonStyle(SoftButtonStyle())
    }

    private func symbol(_ s: WorkflowRun.Status) -> String {
        switch s {
        case .running: return "play.circle.fill"
        case .waiting: return "hand.raised.fill"
        case .done: return "checkmark.circle.fill"
        case .stopped: return "stop.circle"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func colour(_ s: WorkflowRun.Status) -> Color {
        switch s {
        case .running: return Theme.accent
        case .waiting: return Theme.warning
        case .done: return Theme.success
        case .stopped: return Theme.secondary
        case .failed: return Theme.failure
        }
    }

    private func title(_ s: WorkflowRun.Status) -> String {
        switch s {
        case .running: return "Running"
        case .waiting: return "Waiting for you"
        case .done: return "Done"
        case .stopped: return "Stopped"
        case .failed: return "Didn't finish"
        }
    }
}

/// Everything that ran: routines, workflows and tasks, newest first.
struct RunHistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let log = Array(model.runLog.suffix(300).reversed())
        List {
            if log.isEmpty {
                Text("Nothing has run yet.").foregroundStyle(Theme.secondary)
            }
            ForEach(log) { entry in
                HStack(spacing: 10) {
                    Image(systemName: symbol(entry.kind))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).lineLimit(1)
                        Text([kindTitle(entry.kind), entry.target.map { model.targetName($0) }, entry.date.formatted(date: .abbreviated, time: .shortened)]
                                .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    if entry.kind == .workflow {
                        Text(outcome(entry.outcome)).font(.caption).foregroundStyle(Theme.secondary)
                    }
                    if let chat = entry.chatId, model.chat(chat) != nil {
                        Button("Open") { model.show(chat: chat) }.controlSize(.small)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .buttonStyle(SoftButtonStyle())
    }

    private func symbol(_ k: RunLogEntry.Kind) -> String {
        switch k {
        case .routine: return "clock.arrow.circlepath"
        case .workflow: return "flowchart"
        case .task: return "checklist"
        }
    }

    private func kindTitle(_ k: RunLogEntry.Kind) -> String {
        switch k {
        case .routine: return "Routine"
        case .workflow: return "Workflow"
        case .task: return "Task"
        }
    }

    private func outcome(_ o: RunLogEntry.Outcome) -> String {
        switch o {
        case .running: return "Running"
        case .done: return "Done"
        case .failed: return "Didn't finish"
        case .stopped: return "Stopped"
        }
    }
}
#endif
