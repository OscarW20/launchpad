#if os(macOS)
import SwiftUI
import LaunchpadCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage("ui.sidebarHidden") private var sidebarHidden = false
    @AppStorage("ui.listColumnWidth") private var listWidth: Double = 320

    var body: some View {
        @Bindable var model = model
        HStack(spacing: Theme.Space.m) {
            if !sidebarHidden {
                SidebarView()
                    .frame(width: 228)
                    .panel()
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            if model.section.hasListColumn {
                contentColumn
                    .frame(width: CGFloat(listWidth))
                    .frame(maxHeight: .infinity, alignment: .top)
                    .panel()
                    .overlay(alignment: .trailing) {
                        ColumnResizeHandle(width: $listWidth, range: 260...460)
                            .offset(x: Theme.Space.m)
                    }
            }
            detailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .panel()
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.bottom, Theme.Space.m)
        .padding(.top, Theme.Space.xs)
        .background(GlowBackground())
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: Theme.Space.s) {
                    BrandMark(size: 24)
                    Text("Launchpad")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.text)
                }
                .padding(.leading, Theme.Space.xs)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Launchpad")
            }
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.snappy(duration: 0.25)) { sidebarHidden.toggle() }
                } label: {
                    Label(sidebarHidden ? "Show Sidebar" : "Hide Sidebar", systemImage: "sidebar.left")
                }
                .help(sidebarHidden ? "Show the sidebar (⌃⌘S)" : "Hide the sidebar (⌃⌘S)")
                .keyboardShortcut("s", modifiers: [.control, .command])
            }
            ToolbarItem(placement: .navigation) { HistoryButtons() }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
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

extension SidebarSection {
    /// Marketplace and Settings use the whole width; every other page has a list column.
    var hasListColumn: Bool { self != .hire && self != .settings }
}

/// The gap between the list and the conversation: drag to resize the list.
struct ColumnResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    @State private var start: Double?

    var body: some View {
        Color.clear
            .frame(width: Theme.Space.m)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let base = start ?? width
                        if start == nil { start = width }
                        width = min(range.upperBound, max(range.lowerBound, base + value.translation.width))
                    }
                    .onEnded { _ in start = nil }
            )
            .onTapGesture(count: 2) { width = 320 }
            .help("Drag to resize")
            .accessibilityHidden(true)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    row(.chats)
                    row(.office)
                    header("Work")
                    row(.tasks)
                    row(.workflows)
                    row(.routines)
                    header("Team")
                    row(.bots)
                    row(.groups)
                    row(.hire)
                    header("Tools")
                    row(.skills)
                    row(.connectors)
                }
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.m)
            }
            EngineStatusFooter()
                .padding(.horizontal, Theme.Space.m)
            row(.settings)
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.m)
        }
    }

    private func header(_ title: String) -> some View {
        SectionHeader(title)
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.l)
            .padding(.bottom, Theme.Space.xs)
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
        SidebarRow(section: section, selected: model.section == section, badge: badge(for: section)) {
            model.section = section
        }
    }
}

struct SidebarRow: View {
    let section: SidebarSection
    let selected: Bool
    let badge: Int
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: section.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20)
                    .foregroundStyle(selected ? Theme.accentText : Theme.secondary)
                Text(section.title)
                    .font(.system(size: 14, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Theme.accentText : Theme.text)
                Spacer(minLength: 4)
                CountBadge(count: badge)
            }
            .padding(.horizontal, Theme.Space.m)
            .frame(height: 36)
            .background(
                Capsule().fill(selected ? Theme.accentSoft : (hover ? Theme.rowHover : Color.clear))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(badge > 0 ? "\(badge)" : "")
    }
}

struct EngineStatusFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            UsageSummary()
            ForEach(shownEngines) { engine in
                HStack(spacing: 6) {
                    Circle()
                        .fill(colour(for: engine))
                        .frame(width: 7, height: 7)
                    Text(engine.displayName)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Text(label(for: engine))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                }
            }
        }
        .card(padding: Theme.Space.l - 2, radius: 20, fill: Theme.field)
        .contentShape(Rectangle())
        .onTapGesture { model.section = .settings }
        .help("Engines Launchpad can use. Click for details.")
    }

    /// The local engine only shows once a bot uses it (Ollama is optional).
    private var shownEngines: [BotEngine] {
        BotEngine.allCases.filter { $0.isAgent || model.bots.contains { $0.engine == .local } }
    }

    private func colour(for engine: BotEngine) -> Color {
        guard let found = model.engineLocations else { return Theme.secondary }
        if engine == .local { return found[engine] != nil ? Theme.successFill : Theme.secondary }
        return found[engine] != nil ? Theme.successFill : Theme.failureFill
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
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            IconTile(symbol: section.symbol, size: 44)
            Text(section.title)
                .font(Theme.rounded(.title2, weight: .bold))
                .foregroundStyle(Theme.text)
            Text(section.blurb)
                .foregroundStyle(Theme.secondary)
            Spacer()
        }
        .padding(Theme.Space.xl)
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
        EmptyState(symbol: symbol, title: title, message: message) {
            switch model.section {
            case .groups:
                Button { model.showingNewGroup = true } label: { Label("New Group", systemImage: "plus") }
                    .buttonStyle(PillButtonStyle())
                Button("Hire the Dev team") { model.section = .hire }
                    .buttonStyle(SoftButtonStyle())
            case .skills:
                Button { model.newSkill() } label: { Label("New Skill", systemImage: "plus") }
                    .buttonStyle(PillButtonStyle())
            case .connectors:
                Button { model.addConnector() } label: { Label("Add Connector", systemImage: "plus") }
                    .buttonStyle(PillButtonStyle())
            case .routines:
                Button { model.newRoutine() } label: { Label("New Routine", systemImage: "plus") }
                    .buttonStyle(PillButtonStyle())
            case .workflows:
                Button { model.newWorkflow() } label: { Label("New Workflow", systemImage: "plus") }
                    .buttonStyle(PillButtonStyle())
            case .tasks:
                EmptyView()
            default:
                Button { model.showingNewBot = true } label: { Label("New Bot", systemImage: "plus") }
                    .buttonStyle(PillButtonStyle())
                if model.bots.isEmpty {
                    Button("Hire ready-made bots") { model.section = .hire }
                        .buttonStyle(SoftButtonStyle())
                }
            }
        }
    }
}
#endif
