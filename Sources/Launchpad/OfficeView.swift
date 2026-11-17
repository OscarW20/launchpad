#if os(macOS)
import SwiftUI
import LaunchpadCore

/// The Office: every bot's desk with its live status (working, needs you, up next, free), what it's doing, a way to
/// watch it work (its live chat in its own window), and the team notes every bot reads.
struct OfficeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let desks = model.desks(now: context.date)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(desks)
                    if desks.isEmpty {
                        ContentUnavailableView {
                            Label("The office is empty", systemImage: "building.2")
                        } description: {
                            Text("Create a bot, or hire a ready-made team.")
                        } actions: {
                            Button("Hire a Team") { model.section = .hire }
                                .buttonStyle(PillButtonStyle())
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 14)], spacing: 14) {
                            ForEach(desks) { desk in
                                DeskCard(desk: desk, now: context.date) { watch(desk) }
                            }
                        }
                    }
                    TeamNotesCard()
                }
                .padding(24)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle("Office")
        .onAppear { model.loadRecentMessages() }
    }

    private func header(_ desks: [DeskInfo]) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Office").font(Theme.rounded(.largeTitle, weight: .bold))
                Text("Your team at their desks. Watch anyone who's working, or click a desk to open their chat.")
                    .foregroundStyle(Theme.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                counter(desks.filter { $0.state == .working }.count, "working", Theme.accent)
                counter(desks.filter { $0.state == .needsYou }.count, "need you", Theme.warning)
                counter(desks.filter { $0.state == .waiting }.count, "up next", .secondary)
            }
        }
    }

    private func counter(_ n: Int, _ label: String, _ tint: Color) -> some View {
        HStack(spacing: 5) {
            Text("\(n)").font(.headline).foregroundStyle(tint)
            Text(label).font(.callout).foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Theme.card, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.line))
    }

    /// Watching a bot: its live chat in its own window.
    private func watch(_ desk: DeskInfo) {
        if let chatId = desk.chatId {
            openWindow(id: "chat", value: chatId)
        } else {
            model.openChat(with: desk.bot)
        }
    }
}

/// One desk: avatar, name, status badge, what it's doing, and its buttons.
private struct DeskCard: View {
    @Environment(AppModel.self) private var model
    let desk: DeskInfo
    let now: Date
    var watch: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AvatarView(bot: desk.bot, size: 44)
                    .overlay(Circle().strokeBorder(tint, lineWidth: desk.state == .idle || desk.state == .waiting ? 0 : 2.5))
                VStack(alignment: .leading, spacing: 2) {
                    Text(desk.bot.name).font(.headline).lineLimit(1)
                    Text(desk.bot.role.isEmpty ? desk.bot.engine.displayName : desk.bot.role)
                        .font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(desk.state.title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 7)
                    .frame(height: 18)
                    .background(tint.opacity(0.13), in: Capsule())
            }
            Text(detail)
                .font(.callout)
                .foregroundStyle(Theme.secondary)
                .lineLimit(3, reservesSpace: true)
            if let app = desk.app {
                Label("Using \(app)", systemImage: "cursorarrow.click.2")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
            }
            HStack {
                if desk.state == .working || desk.state == .needsYou, desk.chatId != nil {
                    Button { watch() } label: { Label("Watch", systemImage: "eye") }
                        .help("Open \(desk.bot.name)'s live chat in its own window")
                }
                Button { open() } label: { Label("Chat", systemImage: "bubble.left") }
                Spacer()
                if desk.state == .working {
                    Button(role: .destructive) { model.stopBot(desk.bot.id) } label: { Label("Stop", systemImage: "stop.fill") }
                }
            }
            .buttonStyle(SoftButtonStyle())
            .controlSize(.small)
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(desk.state == .working || desk.state == .needsYou ? tint.opacity(0.6) : Theme.line,
                          lineWidth: desk.state == .working || desk.state == .needsYou ? 1.5 : 1))
        .shadow(color: .black.opacity(hover ? 0.08 : 0.03), radius: hover ? 10 : 4, y: 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open() }
        .onHover { hover = $0 }
        .contextMenu {
            Button("Open Chat") { open() }
            Button("Edit Bot") {
                model.selectedBotId = desk.bot.id
                model.section = .bots
            }
        }
    }

    private var tint: Color {
        switch desk.state {
        case .working: return Theme.accent
        case .needsYou: return Theme.warning
        case .waiting: return .secondary
        case .idle: return Theme.success
        }
    }

    private var detail: String {
        guard desk.state == .working, let since = desk.since else { return desk.line }
        let mins = Int(now.timeIntervalSince(since) / 60)
        return "\(mins < 1 ? "Just started" : "\(mins) min"): \(desk.line)"
    }

    private func open() {
        if let id = desk.chatId { model.show(chat: id) } else { model.openChat(with: desk.bot) }
    }
}

/// The live activity feed, shown next to the desks (the Office's list column).
struct OfficeFeedColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let events = model.activity.recent(120)
        let working = model.workingRuns.count
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(working == 0 ? Color.secondary.opacity(0.5) : Theme.success).frame(width: 8, height: 8)
                Text("Live").font(.headline)
                Spacer()
                Text(working == 0 ? "All quiet" : "\(working) working").font(.caption).foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            if events.isEmpty {
                Text("What your bots do shows up here as it happens: what they start, the tools they use, who they ask for help and when they finish.")
                    .foregroundStyle(Theme.secondary)
                    .padding(14)
                Spacer()
            } else {
                List(events) { e in
                    ActivityRow(event: e)
                        .contentShape(Rectangle())
                        .onTapGesture { if model.chat(e.chatId) != nil { model.show(chat: e.chatId) } }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Office")
    }
}

private struct ActivityRow: View {
    @Environment(AppModel.self) private var model
    let event: ActivityEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                AvatarView(bot: model.bot(event.botId), size: 26)
                Image(systemName: symbol)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 13, height: 13)
                    .background(Circle().fill(tint))
                    .offset(x: 3, y: 3)
            }
            VStack(alignment: .leading, spacing: 1) {
                (Text(model.bot(event.botId)?.name ?? "Bot").bold() + Text(" " + verb).foregroundColor(.secondary))
                    .font(.callout)
                Text(event.text).font(.caption).lineLimit(2)
                Text("\(TimeLabel.clock(event.date)) · \(model.chat(event.chatId)?.title ?? "a chat")")
                    .font(.caption2)
                    .foregroundStyle(Theme.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var verb: String {
        switch event.kind {
        case .started: return "started"
        case .step: return "is working"
        case .asked: return "asked"
        case .finished: return "finished"
        case .failed: return "got stuck"
        }
    }

    private var symbol: String {
        switch event.kind {
        case .started: return "play.fill"
        case .step: return "gearshape.fill"
        case .asked: return "person.2.fill"
        case .finished: return "checkmark"
        case .failed: return "exclamationmark"
        }
    }

    private var tint: Color {
        switch event.kind {
        case .started: return Theme.accent
        case .step: return .blue
        case .asked: return Theme.warning
        case .finished: return Theme.success
        case .failed: return Theme.failure
        }
    }
}

/// Team notes (Shared/TEAM.md): a preview, and an editor sheet.
private struct TeamNotesCard: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Team notes", systemImage: "note.text").font(.headline)
                Spacer()
                Button("Edit") { editing = true }
                Button("Open in Editor") { SystemActions.open(model.paths.teamNotes) }
            }
            .buttonStyle(SoftButtonStyle())
            .controlSize(.small)
            Text(text.isEmpty
                 ? "One page every bot reads before it starts: what you do, how you like things done, and decisions made. Bots add a line when they decide something."
                 : text)
                .font(.callout)
                .foregroundStyle(Theme.secondary)
                .lineLimit(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
        .onAppear(perform: load)
        .sheet(isPresented: $editing, onDismiss: load) { TeamNotesEditorSheet() }
    }

    private func load() {
        text = model.teamNotesText().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct TeamNotesEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Team notes").font(Theme.rounded(.title2, weight: .bold))
            Text("~/Launchpad/Shared/TEAM.md. Every bot reads this before it starts work. Keep it short.")
                .foregroundStyle(Theme.secondary)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 340)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.saveTeamNotes(text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
        .onAppear { text = model.teamNotesText() }
    }
}
#endif
