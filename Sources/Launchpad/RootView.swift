#if os(macOS)
import SwiftUI
import LaunchpadCore

struct RootView: View {
    @Environment(AppModel.self) private var model

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
        }
        .sheet(isPresented: $model.showingNewBot) {
            NewBotSheet()
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
        case .bots: BotListView()
        default: SectionIntro(section: model.section)
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
        case .settings:
            SettingsView()
        default:
            ComingSoonView(section: model.section)
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
            }
            Section("Team") {
                row(.bots)
                row(.groups)
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

    private func row(_ section: SidebarSection) -> some View {
        Label(section.title, systemImage: section.symbol)
            .badge(section == .bots ? model.bots.count : 0)
            .tag(section)
    }
}

struct EngineStatusFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(BotEngine.allCases) { engine in
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

    private func colour(for engine: BotEngine) -> Color {
        guard let found = model.engineLocations else { return .gray }
        return found[engine] != nil ? Theme.success : Theme.failure
    }

    private func label(for engine: BotEngine) -> String {
        guard let found = model.engineLocations else { return "checking…" }
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

struct ComingSoonView: View {
    let section: SidebarSection

    var body: some View {
        ContentUnavailableView {
            Label(section.title, systemImage: section.symbol)
        } description: {
            Text(section.blurb + (section.comingInPhase.map { "\nComing in phase \($0)." } ?? ""))
        }
        .background(Theme.canvas)
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
            Button {
                model.showingNewBot = true
            } label: {
                Label("New Bot", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }
}
#endif
