#if os(macOS)
import SwiftUI
import LaunchpadCore

// Asks addressed to you ("@oscar" or a "Needs you" block at the end of a bot's message). `AskParser` and `AskInbox`
// (LaunchpadCore) find them and track open and done; this is the app's side: the callout on the message, the count on the
// sidebar and the workspace list, and the Needs you list.

@MainActor
@Observable
final class AskCenter {
    static let shared = AskCenter()

    /// Open asks across every chat, newest first.
    private(set) var open: [UserAsk] = []
    /// Message ids you've marked done by hand (kept in the data folder, which bots can't write).
    private(set) var doneIds: Set<String> = []
    private weak var model: AppModel?

    func install(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        doneIds = AskStore(paths: model.paths).doneSet()
        refresh()
    }

    /// Re-reads the open asks (off the main thread: it reads chats from disk). `delay` lets a reply that just ended be saved.
    func refresh(after delay: Double = 0) {
        guard let paths = model?.paths else { return }
        Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            let found = await Task.detached { AskInbox(paths: paths).open() }.value
            self?.open = found
        }
    }

    private func workspace(of ask: UserAsk) -> String {
        guard let chat = model?.chat(ask.chatId) else { return Workspace.generalId }
        return WorkspaceCenter.shared.id(for: chat)
    }

    func asks(in workspaceId: String) -> [UserAsk] { open.filter { workspace(of: $0) == workspaceId } }
    func count(in workspaceId: String) -> Int { asks(in: workspaceId).count }

    /// This chat's open asks from the messages the app already holds, newest last: what the tray pins.
    func pinned(chatId: String) -> [UserAsk] {
        guard let model else { return [] }
        return AskBook.pinned(in: model.messages(for: chatId), chatId: chatId, done: doneIds)
    }

    func markDone(_ ask: UserAsk) { markDone(messageId: ask.messageId) }

    /// Takes an ask off your list without replying ("handled elsewhere").
    func markDone(messageId: String) {
        guard let model else { return }
        do {
            try AskStore(paths: model.paths).markDone(messageId)
            doneIds.insert(messageId)
        } catch {
            model.alertMessage = "Couldn't mark that done: \(error.localizedDescription)"
        }
        refresh()
    }
}

// MARK: - The card

/// Amber, not red (red means error here) and not accent blue (selection). The icon, the words and the bar carry the meaning,
/// so it never relies on colour alone.
enum AskStyle {
    static let background = Color.dynamic(light: "#FEF3C7", dark: "#43331B")
    static let bar = Color.dynamic(light: "#D97706", dark: "#FBBF24")
    static let label = Color.dynamic(light: "#78350F", dark: "#FCD34D")
    static let fill = Color.dynamic(light: "#D97706", dark: "#FBBF24")
    static let onFill = Color.dynamic(light: "#FFFFFF", dark: "#000000")

    static func symbol(_ kind: AskKind) -> String {
        switch kind {
        case .question: return "questionmark.bubble.fill"
        case .decision: return "arrow.triangle.branch"
        case .task: return "checkmark.square.fill"
        }
    }

    static func name(_ kind: AskKind) -> String {
        switch kind {
        case .question: return "Question"
        case .decision: return "Decision"
        case .task: return "Task"
        }
    }
}

/// A big amber button.
private struct AskButtonStyle: ButtonStyle {
    var filled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .multilineTextAlignment(.leading)
            .foregroundStyle(filled ? AskStyle.onFill : AskStyle.label)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(filled ? AskStyle.fill : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(AskStyle.bar.opacity(filled ? 0 : 0.9), lineWidth: 1.5))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// An ask that's waiting on you, as its own card: the exact thing needed, big buttons for the answers, a reply box, and the
/// bot's long report folded underneath. Replies go the way the composer's do, so a busy bot is steered.
struct NeedsYouCard: View {
    @Environment(AppModel.self) private var model
    let ask: UserAsk
    @State private var reply = ""
    @State private var moreDetail = false
    @State private var moreChoices = false
    @FocusState private var replyFocused: Bool

    private var kind: AskKind { ask.ask.kind }
    private var botName: String { model.bot(ask.botId)?.name ?? "A bot" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "flag.fill")
                Text("NEEDS YOU").font(.system(size: 12, weight: .heavy))
                Image(systemName: AskStyle.symbol(kind))
                Text("\(AskStyle.name(kind)) · \(botName)").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(TimeLabel.clock(ask.at)).font(.system(size: 11))
                Menu {
                    Button("Handled elsewhere, no reply") { AskCenter.shared.markDone(ask) }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("More")
            }
            .foregroundStyle(AskStyle.label)

            Text(ask.ask.headline)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if let detail = ask.ask.detail {
                VStack(alignment: .leading, spacing: 2) {
                    Text(.init(detail))
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(moreDetail ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(moreDetail ? "Less" : "More") { moreDetail.toggle() }
                        .buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(AskStyle.label)
                }
            }

            actions

            replyBox

            if let text = reportText { ReportFold(botName: botName, text: text) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AskStyle.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AskStyle.bar).frame(width: 4).padding(.vertical, 1)
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AskStyle.bar.opacity(0.8), lineWidth: 1.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Needs you, \(AskStyle.name(kind).lowercased()), from \(botName): \(ask.ask.headline)")
    }

    @ViewBuilder private var actions: some View {
        switch kind {
        case .decision:
            let choices = ask.ask.choices
            let shown = moreChoices ? choices : Array(choices.prefix(4))
            VStack(spacing: 8) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, choice in
                    Button { send(choice) } label: { Text(choice).fixedSize(horizontal: false, vertical: true) }
                        .buttonStyle(AskButtonStyle())
                }
                if choices.count > 4, !moreChoices {
                    Button("More choices (\(choices.count - 4))") { moreChoices = true }
                        .buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(AskStyle.label)
                }
            }
        case .task:
            HStack(spacing: 8) {
                Button { send(ask.ask.doneReply) } label: { Label("Done", systemImage: "checkmark") }
                    .buttonStyle(AskButtonStyle())
                Button { send(ask.ask.declineReply) } label: { Text("Can't right now") }
                    .buttonStyle(AskButtonStyle(filled: false))
            }
        case .question:
            EmptyView()
        }
    }

    private var replyBox: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(kind == .question ? "Your answer…" : "Or reply in your own words…", text: $reply, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($replyFocused)
                .onSubmit { send(reply) }
                .onKeyPress(.return, phases: .down) { press in
                    // Shift+Return is a new line, as in the composer.
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    if !NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil) { reply += "\n" }
                    return .handled
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(replyFocused ? AskStyle.bar : Theme.line, lineWidth: replyFocused ? 1.5 : 1))
            Button { send(reply) } label: { Image(systemName: "paperplane.fill") }
                .buttonStyle(CircleButtonStyle(kind: .accent, size: 34))
                .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send")
                .accessibilityLabel("Send reply")
            if kind == .question {
                Button("Not now") { send("Not now: skip \"\(ask.ask.headline)\" for now.") }
                    .buttonStyle(AskButtonStyle(filled: false)).fixedSize()
            }
        }
        .onAppear { if kind == .question { replyFocused = true } }
    }

    /// The bot's message the ask came from, for the folded report.
    private var reportText: String? {
        model.messages(for: ask.chatId).first { $0.id == ask.messageId }?.text
    }

    private func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        model.replyFromNotification(t, chatId: ask.chatId)
        reply = ""
        AskCenter.shared.refresh(after: 1)
    }
}

/// "Show Tester's report (28 lines)": the long message the ask came from, folded.
private struct ReportFold: View {
    let botName: String
    let text: String
    @State private var expanded = false

    var body: some View {
        let lines = text.filter { $0 == "\n" }.count + 1
        DisclosureGroup(isExpanded: $expanded) {
            ScrollView { MarkdownView(text: text).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 220).padding(.top, 6)
        } label: {
            Text(expanded ? "Hide \(botName)'s report" : "Show \(botName)'s report (\(lines) line\(lines == 1 ? "" : "s"))")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(AskStyle.label)
        }
    }
}

/// A short row for an older ask in the tray: tap to answer it.
private struct CompactAsk: View {
    @Environment(AppModel.self) private var model
    let ask: UserAsk
    let answer: () -> Void

    var body: some View {
        Button(action: answer) {
            HStack(spacing: 8) {
                Image(systemName: AskStyle.symbol(ask.ask.kind))
                Text(ask.ask.headline).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                Text("\(model.bot(ask.botId)?.name ?? "A bot")").font(.caption)
                Text("Answer").font(.caption.weight(.bold))
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(AskStyle.label)
            .padding(.horizontal, 12).frame(minHeight: 32)
            .background(AskStyle.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(AskStyle.bar.opacity(0.6)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Needs you, \(AskStyle.name(ask.ask.kind).lowercased()): \(ask.ask.headline). Answer")
    }
}

/// Open asks for this chat, pinned above the composer so they stay in view however far you scroll. The newest is the full
/// card; older ones are one-line rows; Hide leaves a thin bar.
struct NeedsYouTray: View {
    let chatId: String
    @State private var hidden = false
    @State private var focusedId: String?
    @State private var showingList = false

    var body: some View {
        let asks = AskCenter.shared.pinned(chatId: chatId)
        if !asks.isEmpty {
            let full = asks.first { $0.id == focusedId } ?? asks[asks.count - 1]
            let others = asks.filter { $0.id != full.id }.reversed()
            VStack(spacing: 8) {
                HStack {
                    Label(asks.count == 1 ? "1 needs you" : "\(asks.count) need you", systemImage: "flag.fill")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(AskStyle.label)
                    Spacer()
                    Button(hidden ? "Show" : "Hide") { withAnimation(.easeOut(duration: 0.15)) { hidden.toggle() } }
                        .buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(AskStyle.label)
                }
                if !hidden {
                    ForEach(Array(others.prefix(3))) { ask in CompactAsk(ask: ask) { focusedId = ask.id } }
                    if others.count > 3 {
                        Button("+\(others.count - 3) more") { showingList = true }
                            .buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(AskStyle.label)
                            .popover(isPresented: $showingList) { NeedsYouList(close: { showingList = false }) }
                    }
                    ScrollView { NeedsYouCard(ask: full).id(full.id) }
                        .frame(maxHeight: 340)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, Theme.Space.l).padding(.vertical, 10)
            .background(Theme.panelSolid)
            .overlay(alignment: .top) { Rectangle().fill(AskStyle.bar.opacity(0.5)).frame(height: 1) }
            .onChange(of: asks.map(\.id)) { if let f = focusedId, !asks.contains(where: { $0.id == f }) { focusedId = nil } }
        }
    }
}

// MARK: - In the transcript

/// What happened to an ask, for the line left in the transcript.
enum AskOutcome: Equatable {
    case open
    case answered(String)
    case handled
    case movedOn
}

enum AskText {
    /// Splits a finished bot message into its report and the ask to you. Cheap for the usual message with no ask.
    static func split(_ message: ChatMessage, live: Bool) -> (report: String, ask: ParsedAsk?) {
        guard !live, message.role == .bot, !message.text.isEmpty,
              message.text.range(of: "oscar", options: .caseInsensitive) != nil
                || message.text.range(of: "needs you", options: .caseInsensitive) != nil else { return (message.text, nil) }
        let parts = AskParser.split(message.text)
        return parts.ask == nil ? (message.text, nil) : parts
    }

    @MainActor
    static func outcome(of message: ChatMessage, ask: ParsedAsk, in messages: [ChatMessage], chatId: String) -> AskOutcome {
        if AskBook.pinned(in: messages, chatId: chatId, done: AskCenter.shared.doneIds).contains(where: { $0.messageId == message.id }) { return .open }
        if AskCenter.shared.doneIds.contains(message.id) { return .handled }
        guard let at = messages.firstIndex(where: { $0.id == message.id }) else { return .movedOn }
        if let reply = messages[(at + 1)...].first(where: { $0.role == .user }) { return .answered(reply.text) }
        return .movedOn
    }
}

/// The ask where it was made, in the transcript: while it's open a one-line amber banner (the card is pinned below);
/// after it's dealt with, a quiet grey line.
struct AskTranscriptLine: View {
    @Environment(AppModel.self) private var model
    let message: ChatMessage
    let ask: ParsedAsk
    let chatId: String

    var body: some View {
        let outcome = AskText.outcome(of: message, ask: ask, in: model.messages(for: chatId), chatId: chatId)
        switch outcome {
        case .open:
            HStack(spacing: 6) {
                Image(systemName: "flag.fill")
                Text("NEEDS YOU").font(.system(size: 11, weight: .heavy))
                Text("· \(AskStyle.name(ask.kind)) · \(ask.headline)").font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Spacer(minLength: 0)
            }
            .foregroundStyle(AskStyle.label)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(AskStyle.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(AskStyle.bar.opacity(0.7)))
            .accessibilityLabel("Needs you, \(AskStyle.name(ask.kind).lowercased()): \(ask.headline). Answer in the card above the message box.")
        default:
            Label(text(outcome), systemImage: "checkmark.circle")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(2)
        }
    }

    private func text(_ outcome: AskOutcome) -> String {
        switch outcome {
        case .answered(let reply):
            let flat = reply.replacingOccurrences(of: "\n", with: " ")
            return "You answered · \(AskStyle.name(ask.kind)) · \u{201C}\(flat.count > 60 ? String(flat.prefix(59)) + "…" : flat)\u{201D}"
        case .handled: return "Handled · no reply"
        case .movedOn: return "Answered in chat"
        case .open: return ""
        }
    }
}

/// The rest of a long message, folded under "Show report" so the ask is the first thing you see.
struct CollapsibleReport: View {
    let text: String
    @State private var expanded = false

    /// A short report just shows; a long one folds.
    static func isLong(_ text: String) -> Bool { text.count > 700 || text.filter { $0 == "\n" }.count > 12 }

    var body: some View {
        if Self.isLong(text) {
            DisclosureGroup(isExpanded: $expanded) {
                MarkdownView(text: text).padding(.top, 6)
            } label: {
                Text(expanded ? "Hide report" : "Show report").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
            }
        } else {
            MarkdownView(text: text)
        }
    }
}

// MARK: - Needs you list

/// A button in the Chats toolbar with the count of open asks in this workspace, and the list behind it.
struct NeedsYouButton: View {
    @State private var showing = false

    var body: some View {
        let count = AskCenter.shared.count(in: WorkspaceCenter.shared.currentId)
        Button { showing.toggle() } label: {
            Label(count > 0 ? "Needs you (\(count))" : "Needs you", systemImage: count > 0 ? "exclamationmark.bubble.fill" : "exclamationmark.bubble")
        }
        .help(count > 0 ? "\(count) thing\(count == 1 ? "" : "s") waiting on you" : "Nothing is waiting on you")
        .popover(isPresented: $showing) { NeedsYouList(close: { showing = false }) }
    }
}

struct NeedsYouList: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void

    var body: some View {
        let asks = AskCenter.shared.asks(in: WorkspaceCenter.shared.currentId)
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Needs you").font(Theme.rounded(.headline, weight: .bold))
            if asks.isEmpty {
                Text("Nothing is waiting on you.").foregroundStyle(Theme.secondary).padding(.vertical, Theme.Space.s)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        ForEach(asks) { ask in row(ask) }
                    }
                }
                .frame(maxHeight: 380)
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 360)
    }

    private func row(_ ask: UserAsk) -> some View {
        let bot = model.bot(ask.botId)
        let chat = model.chat(ask.chatId)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                AvatarView(bot: bot, size: 20)
                Text(bot?.name ?? "A bot").font(.system(size: 13, weight: .semibold))
                if chat?.kind == .group, let title = chat?.title { Text("in \(title)").font(.caption).foregroundStyle(Theme.secondary).lineLimit(1) }
                Spacer()
                Text(TimeLabel.short(ask.at)).font(.caption).foregroundStyle(Theme.secondary)
            }
            Text(ask.ask.text.isEmpty ? (ask.ask.choices.first ?? "") : ask.ask.text)
                .font(.system(size: 13))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open") { model.show(chat: ask.chatId); close() }
                    .buttonStyle(PillButtonStyle()).controlSize(.small)
                Button("Mark done") { AskCenter.shared.markDone(ask) }
                    .buttonStyle(SoftButtonStyle()).controlSize(.small)
            }
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
    }
}
#endif
