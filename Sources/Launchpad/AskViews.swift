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
    private weak var model: AppModel?

    func install(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
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

    /// Whether this message's ask still waits on you, from the messages the app already holds.
    func isOpen(messageId: String, chatId: String) -> Bool {
        guard let model else { return false }
        let done = AskStore(paths: model.paths).doneSet()
        return AskBook.open(in: model.messages(for: chatId), chatId: chatId, done: done).contains { $0.messageId == messageId }
    }

    func markDone(_ ask: UserAsk) { markDone(messageId: ask.messageId) }

    func markDone(messageId: String) {
        guard let model else { return }
        do { try AskStore(paths: model.paths).markDone(messageId) } catch {
            model.alertMessage = "Couldn't mark that done: \(error.localizedDescription)"
        }
        refresh()
        model.objectWillChangeTick()
    }
}

extension AppModel {
    /// A nudge so views that check `AskCenter.isOpen` redraw after a mark. (Reading a store isn't observable.)
    func objectWillChangeTick() { askTick &+= 1 }
}

// MARK: - The callout on a message

/// The ask pulled out of a long message and shown first, with its choices as buttons that reply with that choice.
struct NeedsYouCallout: View {
    @Environment(AppModel.self) private var model
    let ask: ParsedAsk
    let messageId: String
    let chatId: String

    var body: some View {
        let _ = model.askTick
        let open = AskCenter.shared.isOpen(messageId: messageId, chatId: chatId)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: open ? "exclamationmark.bubble.fill" : "checkmark.bubble")
                Text(open ? "Needs you" : "Needs you · done")
                    .font(.system(size: 12, weight: .bold))
                    .textCase(.uppercase)
                Spacer()
                if open {
                    Button("Mark done") { AskCenter.shared.markDone(messageId: messageId) }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.medium))
                        .help("Take this off your Needs you list without replying")
                }
            }
            .foregroundStyle(open ? Theme.accentText : Theme.secondary)
            if !ask.text.isEmpty {
                Text(.init(ask.text))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !ask.choices.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(ask.choices.enumerated()), id: \.offset) { _, choice in
                        Button { model.send(chatId: chatId, text: choice) } label: {
                            Text(choice).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        }
                        .buttonStyle(SoftButtonStyle())
                        .disabled(!open || model.isRunning(chatId))
                        .help("Reply with this choice")
                    }
                }
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(open ? Theme.accentSoft : Theme.field, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
            .strokeBorder(open ? Theme.accent.opacity(0.6) : Theme.line, lineWidth: open ? 1.5 : 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(open ? "Needs you: \(ask.text)" : "Needs you, done: \(ask.text)")
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

enum AskText {
    /// Splits a finished bot message into its report and the ask to you. Cheap for the usual message with no ask.
    static func split(_ message: ChatMessage, live: Bool) -> (report: String, ask: ParsedAsk?) {
        guard !live, message.role == .bot, !message.text.isEmpty,
              message.text.range(of: "@oscar", options: .caseInsensitive) != nil
                || message.text.range(of: "needs you", options: .caseInsensitive) != nil else { return (message.text, nil) }
        let parts = AskParser.split(message.text)
        return parts.ask == nil ? (message.text, nil) : parts
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
