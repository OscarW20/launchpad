#if os(macOS)
import SwiftUI
import LaunchpadCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } content: {
            contentColumn
                .navigationSplitViewColumnWidth(min: 260, ideal: 310, max: 420)
        } detail: {
            detailColumn
                .toolbar {
                    ToolbarItem(placement: .navigation) { HistoryButtons() }
                }
        }
        .background(WindowReader { MainWindow.window = $0 })
        .onAppear {
            MainWindow.openWindow = openWindow
            model.startMacFeatures()
        }
        .onChange(of: model.navSpot) { old, new in model.navigated(from: old, to: new) }
        .sheet(isPresented: $model.showingNewBot) {
            NewBotSheet()
        }
        .sheet(isPresented: $model.showingNewGroup) {
            NewGroupSheet()
        }
        .sheet(isPresented: Binding(get: { model.teach != nil }, set: { if !$0 { model.cancelTeach() } })) {
            TeachSkillSheet()
        }
        .sheet(isPresented: Binding(get: { model.summaryGroupId != nil }, set: { if !$0 { model.summaryGroupId = nil } })) {
            if let id = model.summaryGroupId { GroupSummarySheet(groupId: id) }
        }
        .sheet(isPresented: Binding(get: { model.pastThreadsChatId != nil }, set: { if !$0 { model.pastThreadsChatId = nil } })) {
            if let id = model.pastThreadsChatId { PastThreadsSheet(chatId: id) }
        }
        .sheet(isPresented: $model.showingQuickSwitcher) {
            QuickSwitcherSheet()
        }
        .sheet(isPresented: $model.showingSavedMessages) {
            SavedMessagesSheet()
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    @ViewBuilder private var contentColumn: some View {
        switch model.section {
        case .chats: ChatListView()
        case .office: OfficeFeedColumn()
        case .bots: BotListView()
        case .groups: GroupListView()
        case .skills: SkillListView()
        case .connectors: ConnectorListView()
        case .tasks: TaskListView()
        case .workflows: WorkflowListView()
        case .routines: RoutineListView()
        case .hire, .settings: SectionIntro(section: model.section)
        }
    }

    @ViewBuilder private var detailColumn: some View {
        switch model.section {
        case .chats:
            if let id = model.selectedChatId, model.chat(id) != nil {
                ConversationView(chatId: id).id(id)
            } else {
                EmptyDetail(
                    symbol: "bubble.left.and.bubble.right",
                    title: model.bots.isEmpty ? "Meet your first teammate" : "Pick a chat",
                    message: model.bots.isEmpty
                        ? "Create a bot, give it a role, and start chatting."
                        : "Choose a conversation, or start a new one with any bot."
                )
            }
        case .bots:
            if let id = model.selectedBotId, model.bot(id) != nil {
                BotDetailView(botId: id).id(id)
            } else {
                EmptyDetail(symbol: "face.smiling", title: "Your bots",
                            message: "Select a bot to edit its profile and instructions, or create a new one.")
            }
        case .groups:
            if let id = model.selectedGroupId, model.group(id) != nil {
                GroupDetailView(groupId: id).id(id)
            } else {
                EmptyDetail(symbol: "person.3", title: "Groups",
                            message: "Put bots together with a lead. Make one, or add the Dev team from Hire.")
            }
        case .office:
            OfficeView()
        case .hire:
            MarketplaceView()
        case .skills:
            if let id = model.selectedSkillId, model.skill(id) != nil {
                SkillDetailView(skillId: id).id(id)
            } else {
                EmptyDetail(symbol: "sparkles", title: "Skills", message: "Pick a skill to edit it, or make a new one.")
            }
        case .connectors:
            if let id = model.selectedConnectorId, model.connectors.contains(where: { $0.id == id }) {
                ConnectorDetailView(connectorId: id).id(id)
            } else {
                EmptyDetail(symbol: "powerplug", title: "Connectors", message: "Add an MCP server by URL or command, then turn it on for bots or groups.")
            }
        case .tasks:
            if let id = model.selectedTaskId, model.task(id) != nil {
                TaskDetailView(taskId: id).id(id)
            } else {
                EmptyDetail(symbol: "checklist", title: "Tasks", message: "Hand a job to a bot or group, then follow it here. Workflow approvals wait here too.")
            }
        case .workflows:
            if let id = model.selectedWorkflowId, model.workflows.contains(where: { $0.id == id }) {
                WorkflowDetailView(workflowId: id).id(id)
            } else {
                EmptyDetail(symbol: "flowchart", title: "Workflows", message: "Steps that pass work from bot to bot: a prompt, bot jobs, checks, your OK and where the result goes.")
            }
        case .routines:
            if let id = model.selectedRoutineId, model.routines.contains(where: { $0.id == id }) {
                RoutineDetailView(routineId: id).id(id)
            } else {
                EmptyDetail(symbol: "clock.arrow.circlepath", title: "Routines", message: "Send a message to a bot or group on a schedule, or when a file lands in a folder.")
            }
        case .settings:
            SettingsView()
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: Binding(get: { Optional(model.section) }, set: { if let s = $0 { model.section = s } })) {
            Section("Talk") {
                row(.chats)
                row(.office)
            }
            Section("Team") {
                row(.bots)
                row(.groups)
                row(.hire)
            }
            Section("Work") {
                row(.tasks)
                row(.workflows)
                row(.routines)
            }
            Section("Tools") {
                row(.skills)
                row(.connectors)
            }
            Section {
                row(.settings)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.accent.gradient)
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .rotationEffect(.degrees(-20))
                }
                .frame(width: 28, height: 28)
                Text("Launchpad")
                    .font(Theme.rounded(.title3, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 4)
        }
        .safeAreaInset(edge: .bottom) {
            EngineStatusFooter()
        }
    }

    private func badge(for section: SidebarSection) -> Int {
        switch section {
        case .bots: return model.bots.count
        case .groups: return model.groups.count
        case .tasks: return model.tasksNeedingYou
        case .office: return model.workingRuns.count
        default: return 0
        }
    }

    private func row(_ section: SidebarSection) -> some View {
        Label(section.title, systemImage: section.symbol)
            .badge(badge(for: section))
            .tag(section)
    }
}

struct EngineStatusFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            UsageSummary()
            ForEach(shownEngines) { engine in
                HStack(spacing: 6) {
                    Circle()
                        .fill(colour(for: engine))
                        .frame(width: 7, height: 7)
                    Text(engine.displayName)
                        .font(.caption)
                    Spacer()
                    Text(label(for: engine))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(Theme.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(10)
        .contentShape(Rectangle())
        .onTapGesture { model.section = .settings }
        .help("Engines Launchpad can use. Click for details.")
    }

    /// The local engine only shows once a bot uses it (Ollama is optional).
    private var shownEngines: [BotEngine] {
        BotEngine.allCases.filter { $0.isAgent || model.bots.contains { $0.engine == .local } }
    }

    private func colour(for engine: BotEngine) -> Color {
        guard let found = model.engineLocations else { return .gray }
        if engine == .local { return found[engine] != nil ? Theme.success : .gray }
        return found[engine] != nil ? Theme.success : Theme.failure
    }

    private func label(for engine: BotEngine) -> String {
        guard let found = model.engineLocations else { return "checking…" }
        if engine == .local { return found[engine] != nil ? "Ollama found" : "server needed" }
        return found[engine] != nil ? "ready" : "not installed"
    }
}

// MARK: - Placeholders

struct SectionIntro: View {
    let section: SidebarSection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: section.symbol)
                .font(.system(size: 28))
                .foregroundStyle(Theme.accent)
            Text(section.title)
                .font(Theme.rounded(.title2, weight: .bold))
            Text(section.blurb)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .navigationTitle(section.title)
    }
}

struct EmptyDetail: View {
    let symbol: String
    let title: String
    let message: String
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            HStack {
                switch model.section {
                case .groups:
                    Button { model.showingNewGroup = true } label: { Label("New Group", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                    Button("Hire the Dev team") { model.section = .hire }
                case .skills:
                    Button { model.newSkill() } label: { Label("New Skill", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                case .connectors:
                    Button { model.addConnector() } label: { Label("Add Connector", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                case .routines:
                    Button { model.newRoutine() } label: { Label("New Routine", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                case .workflows:
                    Button { model.newWorkflow() } label: { Label("New Workflow", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                case .tasks:
                    EmptyView()
                default:
                    Button { model.showingNewBot = true } label: { Label("New Bot", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                    if model.bots.isEmpty {
                        Button("Hire ready-made bots") { model.section = .hire }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }
}
#endif
