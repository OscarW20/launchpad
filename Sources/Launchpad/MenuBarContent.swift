#if os(macOS)
import SwiftUI
import AppKit
import LaunchpadCore

/// The menu bar icon (a template image), with a count while bots work.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let n = model.workingRuns.count
        HStack(spacing: 3) {
            Image(nsImage: MenuBarIcon.image)
            if n > 0 { Text("\(n)") }
        }
        .help(n == 0 ? "Launchpad" : "\(n) working")
    }
}

/// The menu bar panel: who's working (with Stop), recent chats, Quick Ask and quick ways into the app.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let working = model.workingRuns
        let needs = model.desks().filter { $0.state == .needsYou }
        VStack(alignment: .leading, spacing: 0) {
            header(working: working.count, needs: needs.count)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)

            askBar
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            if !working.isEmpty {
                sectionTitle("Working now") {
                    Button("Stop All") { model.stopEveryone() }
                        .buttonStyle(.borderless)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.failure)
                }
                ForEach(working) { item in
                    MenuWorkingRow(chatId: item.chatId, run: item.run) { open(item.chatId) }
                }
                .padding(.horizontal, 6)
            }

            if !needs.isEmpty {
                sectionTitle("Needs you") { EmptyView() }
                ForEach(needs) { desk in
                    MenuRow(title: desk.bot.name, detail: desk.line, avatar: AnyView(AvatarView(bot: desk.bot, size: 28)), action: {
                        if let id = desk.chatId { open(id) } else { closeMenu(); model.openChat(with: desk.bot); bringForward() }
                    })
                }
                .padding(.horizontal, 6)
            }

            sectionTitle("Recent chats") { EmptyView() }
            if model.chats.isEmpty {
                Text("No chats yet.").font(.callout).foregroundStyle(Theme.secondary).padding(.horizontal, 14)
            }
            ForEach(Array(model.chats.prefix(6))) { chat in
                MenuRow(title: chat.title, detail: chat.lastPreview ?? "No messages yet", avatar: avatar(chat),
                        trailing: TimeLabel.short(chat.updatedAt), action: { open(chat.id) })
            }
            .padding(.horizontal, 6)

            Divider().padding(.vertical, 8)

            HStack(spacing: 8) {
                Button { closeMenu(); model.showingNewBot = true; bringForward() } label: { Label("New Bot", systemImage: "plus") }
                Button { closeMenu(); model.section = .office; bringForward() } label: { Label("Office", systemImage: "building.2") }
                Button { closeMenu(); bringForward() } label: { Label("Open", systemImage: "macwindow") }
                Spacer()
                Button { closeMenu(); model.section = .settings; bringForward() } label: { Image(systemName: "gearshape") }
                    .help("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .help("Quit Launchpad")
            }
            .buttonStyle(SoftButtonStyle())
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .frame(width: 330)
        .background(Theme.canvas)
    }

    private func header(working: Int, needs: Int) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Launchpad").font(.headline)
                HStack(spacing: 5) {
                    Circle().fill(working == 0 ? Theme.success : Theme.accent).frame(width: 6, height: 6)
                    Text(status(working: working))
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if needs > 0 {
                Text("\(needs) need\(needs == 1 ? "s" : "") you")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.warning)
            }
        }
    }

    private func status(working: Int) -> String {
        if working == 0 { return "All quiet · \(model.bots.count) bot\(model.bots.count == 1 ? "" : "s") ready" }
        if working == 1, let id = model.workingRuns.first?.run.botId, let b = model.bot(id) { return "\(b.name) is working" }
        return "\(working) bots working"
    }

    /// Opens Quick Ask, the floating bar for asking any bot something.
    private var askBar: some View {
        Button {
            closeMenu()
            QuickAsk.shared.show()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkle").foregroundStyle(Theme.accent)
                Text("Ask your team anything…").foregroundStyle(Theme.secondary)
                Spacer()
                Text("⌃⌥B").font(.caption).foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionTitle<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func avatar(_ chat: ChatMeta) -> AnyView {
        chat.kind == .group ? AnyView(GroupAvatar(group: model.group(chat.groupId), size: 28))
                            : AnyView(AvatarView(bot: model.bot(chat.botId), size: 28))
    }

    private func open(_ chatId: String) {
        closeMenu()
        model.show(chat: chatId)
        bringForward()
    }

    private func bringForward() {
        if MainWindow.openWindow == nil { MainWindow.openWindow = openWindow }
        MainWindow.bringForward()
    }

    /// Closes the panel (it's the key window while open).
    private func closeMenu() {
        NSApp.windows.first { $0.isKeyWindow && $0.className.contains("MenuBarExtra") }?.close()
    }
}

/// A bot at work: what it's doing now, with Stop.
private struct MenuWorkingRow: View {
    @Environment(AppModel.self) private var model
    let chatId: String
    let run: LiveRun
    var action: () -> Void

    var body: some View {
        let bot = model.bot(run.botId)
        MenuRow(title: bot?.name ?? "Bot", detail: WorkSummary.line(for: run.message, todos: run.builder.todos),
                avatar: AnyView(AvatarView(bot: bot, size: 28).overlay(Circle().strokeBorder(Theme.accent, lineWidth: 2))),
                action: action) {
            Button { model.stop(chatId) } label: {
                Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.borderless)
            .help("Stop \(bot?.name ?? "this bot")")
        }
    }
}

/// One row: avatar, title, a line of detail, an optional time and an optional trailing control.
private struct MenuRow<Accessory: View>: View {
    let title: String
    let detail: String
    let avatar: AnyView
    var trailing: String? = nil
    var action: () -> Void
    @ViewBuilder var accessory: () -> Accessory
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: action) {
                HStack(spacing: 10) {
                    avatar
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text(title).font(.callout.weight(.medium)).lineLimit(1)
                            Spacer(minLength: 4)
                            if let trailing { Text(trailing).font(.caption2).foregroundStyle(Theme.secondary) }
                        }
                        Text(detail.replacingOccurrences(of: "\n", with: " "))
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            accessory()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? Theme.field : .clear))
        .onHover { hover = $0 }
    }
}

extension MenuRow where Accessory == EmptyView {
    init(title: String, detail: String, avatar: AnyView, trailing: String? = nil, action: @escaping () -> Void) {
        self.init(title: title, detail: detail, avatar: avatar, trailing: trailing, action: action, accessory: { EmptyView() })
    }
}
#endif
