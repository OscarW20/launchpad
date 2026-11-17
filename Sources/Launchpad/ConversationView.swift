#if os(macOS)
import SwiftUI
import LaunchpadCore

struct ConversationView: View {
    @Environment(AppModel.self) private var model
    let chatId: String

    var body: some View {
        VStack(spacing: 0) {
            ConversationHeader(chatId: chatId)
            Divider()
            MessagesList(chatId: chatId)
            Composer(chatId: chatId)
        }
        .background(Theme.canvas)
        .navigationTitle(model.chat(chatId)?.title ?? "Chat")
        .task(id: chatId) { model.loadMessagesIfNeeded(chatId) }
    }
}

struct ConversationHeader: View {
    @Environment(AppModel.self) private var model
    let chatId: String

    var body: some View {
        let bot = model.bot(model.chat(chatId)?.botId)
        HStack(spacing: 12) {
            AvatarView(bot: bot, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(bot?.name ?? model.chat(chatId)?.title ?? "Chat")
                    .font(Theme.rounded(.title3, weight: .bold))
                HStack(spacing: 6) {
                    if let bot {
                        if !bot.role.isEmpty {
                            Text(bot.role)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Pill(text: bot.engine.displayName, symbol: bot.engine == .claude ? "sparkle" : "chevron.left.forwardslash.chevron.right")
                        Pill(text: bot.permission.displayName, symbol: permissionSymbol(bot.permission))
                    } else {
                        Text("This chat's bot was removed.")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
            Spacer()
            if let bot {
                Button {
                    model.newChat(with: bot)
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .help("Start a fresh chat with \(bot.name)")
                Button {
                    SystemActions.reveal(model.paths.botDir(bot.id))
                } label: {
                    Label("Show Folder", systemImage: "folder")
                }
                .help("Show \(bot.name)'s folder in Finder")
                Button {
                    model.selectedBotId = bot.id
                    model.section = .bots
                } label: {
                    Label("Edit Bot", systemImage: "slider.horizontal.3")
                }
                .help("Edit \(bot.name)")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Theme.surface.opacity(0.6))
    }

    private func permissionSymbol(_ p: PermissionLevel) -> String {
        switch p {
        case .readOnly: return "eye"
        case .editWorkspace: return "pencil"
        case .fullAccess: return "bolt"
        }
    }
}

struct Pill: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Theme.raised, in: Capsule())
            .foregroundStyle(.secondary)
    }
}

struct MessagesList: View {
    @Environment(AppModel.self) private var model
    let chatId: String

    var body: some View {
        let messages = model.messages(for: chatId)
        let live = model.live[chatId]
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if messages.isEmpty && live == nil {
                        WelcomeCard(chatId: chatId)
                    }
                    ForEach(messages) { message in
                        MessageRow(message: message)
                            .id(message.id)
                    }
                    if let live {
                        MessageRow(message: live.message, activeStep: live.activeStep)
                            .id("live")
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: messages.count) { scrollDown(proxy) }
            .onChange(of: live?.message.text.count ?? -1) { scrollDown(proxy) }
            .onChange(of: live?.message.steps.count ?? -1) { scrollDown(proxy) }
        }
    }

    private func scrollDown(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }
}

struct WelcomeCard: View {
    @Environment(AppModel.self) private var model
    let chatId: String

    private let suggestions = [
        "Introduce yourself. What can you help me with?",
        "Look around your workspace and tell me what's there.",
        "Help me plan a small project.",
    ]

    var body: some View {
        let bot = model.bot(model.chat(chatId)?.botId)
        VStack(spacing: 12) {
            AvatarView(bot: bot, size: 72)
            Text("Say hi to \(bot?.name ?? "your bot")")
                .font(Theme.rounded(.title2, weight: .bold))
            if let role = bot?.role, !role.isEmpty {
                Text(role)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        model.send(chatId: chatId, text: suggestion)
                    } label: {
                        Text(suggestion)
                            .frame(maxWidth: 380)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Theme.surface, in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.border))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

struct Composer: View {
    @Environment(AppModel.self) private var model
    let chatId: String
    @FocusState private var focused: Bool

    var body: some View {
        let running = model.isRunning(chatId)
        let draft = model.drafts[chatId] ?? ""
        let name = model.bot(model.chat(chatId)?.botId)?.name ?? "bot"
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField(
                    "Message \(name)…",
                    text: Binding(get: { model.drafts[chatId] ?? "" }, set: { model.drafts[chatId] = $0 }),
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .lineLimit(1...10)
                .focused($focused)
                .onSubmit { model.send(chatId: chatId) }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(focused ? Theme.accent.opacity(0.6) : Theme.border)
                )

                if running {
                    Button {
                        model.stop(chatId)
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 34, height: 34)
                            .background(Theme.failure, in: Circle())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help("Stop (Esc)")
                } else {
                    Button {
                        model.send(chatId: chatId)
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 34, height: 34)
                            .background(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray.opacity(0.35) : Theme.accent, in: Circle())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Send (Return)")
                }
            }
            Text(running ? "\(name) is working. Press Esc to stop." : "Return to send · ⌥Return for a new line")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.leading, 14)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .onAppear { focused = true }
    }
}
#endif
