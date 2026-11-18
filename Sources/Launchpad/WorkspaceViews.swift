#if os(macOS)
import SwiftUI
import AppKit
import LaunchpadCore

// MARK: - Tile and dot

/// A workspace's tile: its colour with its icon. Never colour alone: the name is always beside it.
struct WorkspaceTile: View {
    let workspace: Workspace
    var size: CGFloat = 28

    var body: some View {
        let colour = Color(hex: workspace.colour)
        Text(workspace.icon)
            .font(.system(size: size * 0.55))
            .frame(width: size, height: size)
            .background(colour.opacity(0.22), in: RoundedRectangle(cornerRadius: size * 0.29, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.29, style: .continuous).strokeBorder(colour.opacity(0.5), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// A solid dot when a bot needs you, a pulsing one while a bot works.
struct WorkspaceDot: View {
    let activity: WorkspaceCenter.Activity
    @State private var pulse = false

    var body: some View {
        if activity != .quiet {
            Circle()
                .fill(activity == .needsYou ? Theme.warning : Theme.accent)
                .frame(width: 8, height: 8)
                .scaleEffect(activity == .working && pulse ? 1.35 : 1)
                .animation(activity == .working ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: pulse)
                .onAppear { pulse = true }
                .accessibilityLabel(activity == .needsYou ? "Waiting for you" : "A bot is working")
        }
    }
}

// MARK: - Switcher

/// The button at the top of the sidebar: where you are, and a list to go elsewhere.
struct WorkspaceSwitcher: View {
    @Environment(AppModel.self) private var model
    var compact = false
    @State private var showing = false

    private var center: WorkspaceCenter { WorkspaceCenter.shared }

    var body: some View {
        let current = center.current
        Button { showing.toggle() } label: {
            HStack(spacing: Theme.Space.s) {
                WorkspaceTile(workspace: current)
                if !compact {
                    Text(current.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.secondary)
                }
            }
            .padding(.horizontal, compact ? 0 : Theme.Space.s)
            .frame(maxWidth: compact ? nil : .infinity, minHeight: 44, alignment: .leading)
            .background(compact ? Color.clear : Theme.field, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .overlay(alignment: compact ? .topTrailing : .trailing) {
                WorkspaceDot(activity: center.elsewhere).padding(compact ? 2 : 28)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(compact ? "Workspace: \(current.name)" : "Switch workspace")
        .accessibilityLabel("Workspace: \(current.name). Switch workspace")
        .popover(isPresented: $showing, arrowEdge: .bottom) { WorkspaceList { showing = false } }
    }
}

private struct WorkspaceList: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void
    private var center: WorkspaceCenter { WorkspaceCenter.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // General is hidden once it's empty and you've made others; it's still in Manage workspaces.
            ForEach(Array(center.workspaces.enumerated()), id: \.element.id) { index, ws in
                if shows(ws) { row(ws, index: index) }
            }
            Divider().padding(.vertical, 4)
            item("Add Workspace…", symbol: "plus") { open(.edit(nil)) }
            item("Manage Workspaces…", symbol: "slider.horizontal.3") { open(.manage) }
        }
        .padding(Theme.Space.s)
        .frame(width: 280)
    }

    private func shows(_ ws: Workspace) -> Bool {
        guard ws.isGeneral, center.isInUse else { return true }
        let held = center.counts(of: ws.id)
        return held.bots + held.groups > 0 || center.currentId == ws.id
    }

    private func row(_ ws: Workspace, index: Int) -> some View {
        let held = center.counts(of: ws.id)
        let activity = center.activity(in: ws.id)
        let selected = ws.id == center.currentId
        return Button {
            center.select(ws.id)
            close()
        } label: {
            HStack(spacing: Theme.Space.s) {
                WorkspaceTile(workspace: ws, size: 22)
                Text(ws.name).font(.system(size: 13, weight: selected ? .semibold : .regular)).foregroundStyle(Theme.text).lineLimit(1)
                WorkspaceDot(activity: activity)
                Spacer(minLength: 4)
                Text("\(held.bots) bot\(held.bots == 1 ? "" : "s")").font(.caption).foregroundStyle(Theme.secondary)
                if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent) }
                if index < 9 { Text("⌘\(index + 1)").font(.caption).foregroundStyle(Theme.secondary) }
            }
            .padding(.horizontal, Theme.Space.s)
            .frame(height: 32)
            .background(selected ? Theme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(ws.name), \(held.bots) bots" + (activity == .working ? ", a bot is working" : activity == .needsYou ? ", waiting for you" : ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func item(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, Theme.Space.s)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func open(_ sheet: WorkspaceCenter.Sheet) {
        close()
        center.sheet = sheet
    }
}

// MARK: - First run

/// Shown when the workspaces file is damaged (with Reset), and once while General is the only workspace.
struct WorkspaceBanner: View {
    @AppStorage(WorkspaceCenter.bannerKey) private var dismissed = false

    var body: some View {
        if WorkspaceCenter.shared.damaged {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Label("Workspaces file is damaged", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                Text("Everything shows in General for now, and moving or adding workspaces is paused so nothing is lost. Reset keeps the old file and starts you again from General.")
                    .font(.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Reset Workspaces") { WorkspaceCenter.shared.resetDamaged() }
                    .buttonStyle(PillButtonStyle()).controlSize(.small)
            }
            .padding(Theme.Space.m)
            .background(Theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        } else if !dismissed, !WorkspaceCenter.shared.isInUse {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Sort your bots into workspaces").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                Text("Keep Biscuit, Launchpad and your own apps apart: each shows only its own bots and groups.")
                    .font(.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Add a Workspace") { WorkspaceCenter.shared.sheet = .edit(nil) }
                        .buttonStyle(PillButtonStyle()).controlSize(.small)
                    Button("Not Now") { dismissed = true }
                        .buttonStyle(PillButtonStyle(kind: .plain)).controlSize(.small)
                }
            }
            .padding(Theme.Space.m)
            .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        }
    }
}

/// Before the chat's name when the sidebar is hidden, so you still know which workspace you're in.
struct WorkspaceChip: View {
    @Environment(AppModel.self) private var model
    let chatId: String

    var body: some View {
        let center = WorkspaceCenter.shared
        if center.isInUse, let chat = model.chat(chatId), let ws = center.workspace(center.id(for: chat)) {
            HStack(spacing: 4) {
                Text(ws.icon).font(.system(size: 11))
                Text(ws.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(Color(hex: ws.colour))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color(hex: ws.colour).opacity(0.15)))
            .accessibilityLabel("Workspace: \(ws.name)")
        }
    }
}

// MARK: - Menus on bots and groups

/// "Move to Workspace" and "Duplicate into Workspace" for a bot's context menu.
struct BotWorkspaceMenu: View {
    @Environment(AppModel.self) private var model
    let bot: Bot

    var body: some View {
        let center = WorkspaceCenter.shared
        let here = center.id(forBot: bot.id)
        let others = center.workspaces.filter { $0.id != here }
        let inGroups = model.groups(containing: bot.id).map(\.name)
        if center.isInUse || !others.isEmpty {
            if inGroups.isEmpty {
                Menu("Move to Workspace") {
                    ForEach(others) { ws in Button("\(ws.icon) \(ws.name)") { center.sheet = .move(WorkspaceMove(kind: .bot(bot), destination: ws)) } }
                }
            } else {
                Button("Move to Workspace: move the group instead") {}.disabled(true)
                    .help("\(bot.name) is in \(inGroups.joined(separator: ", ")). A group and its bots move together.")
            }
            Menu("Duplicate into Workspace") {
                ForEach(others) { ws in Button("\(ws.icon) \(ws.name)") { center.sheet = .move(WorkspaceMove(kind: .duplicate(bot), destination: ws)) } }
            }
        }
    }
}

struct GroupWorkspaceMenu: View {
    let group: BotGroup

    var body: some View {
        let center = WorkspaceCenter.shared
        let others = center.workspaces.filter { $0.id != center.id(forGroup: group.id) }
        if !others.isEmpty {
            Menu("Move to Workspace") {
                ForEach(others) { ws in Button("\(ws.icon) \(ws.name)") { center.sheet = .move(WorkspaceMove(kind: .group(group), destination: ws)) } }
            }
        }
    }
}

// MARK: - Sheets

extension View {
    /// The workspace sheets, for the main window.
    func workspaceSheets() -> some View {
        modifier(WorkspaceSheets())
    }
}

private struct WorkspaceSheets: ViewModifier {
    func body(content: Content) -> some View {
        @Bindable var center = WorkspaceCenter.shared
        content.sheet(item: $center.sheet) { sheet in
            switch sheet {
            case .edit(let ws): EditWorkspaceSheet(workspace: ws)
            case .manage: ManageWorkspacesSheet()
            case .move(let move): MoveSheet(move: move)
            }
        }
    }
}

/// Add or edit a workspace: a name, a colour and an icon, with the tile as it will look.
struct EditWorkspaceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let workspace: Workspace?
    @State private var name = ""
    @State private var colour = "#3B82FF"
    @State private var icon = "📁"

    static let colours = ["#3B82FF", "#3DD68C", "#F5A524", "#F472B6", "#A78BFA", "#2DD4BF", "#F87171", "#94A3B8"]
    static let icons = ["📁", "🏢", "🚀", "📱", "🛍️", "🧪", "🎨", "📈", "🐶", "🏠", "💼", "🌱"]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                WorkspaceTile(workspace: Workspace(id: "preview", name: name, colour: colour, icon: icon), size: 44)
                Text(workspace == nil ? "Add workspace" : "Edit workspace").font(Theme.rounded(.title3, weight: .bold))
            }
            TextField("Name", text: $name, prompt: Text("e.g. Biscuit")).textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 4) {
                Text("Colour").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
                HStack {
                    ForEach(Self.colours, id: \.self) { hex in
                        Button { colour = hex } label: {
                            Circle().fill(Color(hex: hex)).frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(Theme.text, lineWidth: colour == hex ? 2 : 0))
                        }
                        .buttonStyle(.plain).accessibilityLabel("Colour \(hex)")
                        .accessibilityAddTraits(colour == hex ? .isSelected : [])
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Icon").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(30)), count: 12), spacing: 6) {
                    ForEach(Self.icons, id: \.self) { e in
                        Button { icon = e } label: {
                            Text(e).font(.system(size: 18)).frame(width: 28, height: 28)
                                .background(icon == e ? Theme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain).accessibilityLabel("Icon \(e)")
                    }
                }
                TextField("Or type one emoji", text: Binding(get: { icon }, set: { if let c = $0.last { icon = String(c) } }))
                    .textFieldStyle(.roundedBorder).frame(width: 140)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(workspace == nil ? "Add Workspace" : "Save") { save() }
                    .buttonStyle(PillButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 440)
        .sheetBackground()
        .onAppear {
            if let workspace { name = workspace.name; colour = workspace.colour; icon = workspace.icon }
        }
    }

    private func save() {
        let center = WorkspaceCenter.shared
        if var ws = workspace {
            ws.name = name; ws.colour = colour; ws.icon = icon
            if center.update(ws) { dismiss() }
        } else if let id = center.create(name: name, colour: colour, icon: icon) {
            center.select(id)
            dismiss()
        }
    }
}

/// Rename, restyle, reorder and delete. Deleting a workspace with things in it asks where they go first.
struct ManageWorkspacesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var deleting: Workspace?
    @State private var destination = Workspace.generalId

    private var center: WorkspaceCenter { WorkspaceCenter.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Workspaces").font(Theme.rounded(.title3, weight: .bold))
            ForEach(Array(center.workspaces.enumerated()), id: \.element.id) { index, ws in
                let held = center.counts(of: ws.id)
                HStack(spacing: Theme.Space.s) {
                    WorkspaceTile(workspace: ws, size: 26)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(ws.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                        Text("\(held.groups) group\(held.groups == 1 ? "" : "s"), \(held.bots) bot\(held.bots == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    if !ws.isGeneral {
                        Button { move(ws, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(index <= 1)
                            .accessibilityLabel("Move \(ws.name) up")
                        Button { move(ws, by: 1) } label: { Image(systemName: "chevron.down") }.disabled(index >= center.workspaces.count - 1)
                            .accessibilityLabel("Move \(ws.name) down")
                    }
                    Button("Edit") { center.sheet = .edit(ws) }
                    if !ws.isGeneral {
                        Button("Delete…", role: .destructive) { begin(ws) }
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            if let ws = deleting { deleteBox(ws) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(PillButtonStyle()) }
        }
        .padding(Theme.Space.xl)
        .frame(width: 500)
        .sheetBackground()
    }

    private func move(_ ws: Workspace, by step: Int) {
        var ids = center.workspaces.filter { !$0.isGeneral }.map(\.id)
        guard let i = ids.firstIndex(of: ws.id), ids.indices.contains(i + step) else { return }
        ids.swapAt(i, i + step)
        center.reorder(ids)
    }

    private func begin(_ ws: Workspace) {
        destination = center.workspaces.first { $0.id != ws.id }?.id ?? Workspace.generalId
        deleting = ws
    }

    @ViewBuilder private func deleteBox(_ ws: Workspace) -> some View {
        let held = center.counts(of: ws.id)
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if held.bots + held.groups == 0 {
                Text("Delete \(ws.name)? It's empty.").foregroundStyle(Theme.text)
            } else {
                Text("\(ws.name) still has \(held.groups) group\(held.groups == 1 ? "" : "s") and \(held.bots) bot\(held.bots == 1 ? "" : "s"). Nothing is deleted: they all move, with their chats and memory, to:")
                    .foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                Picker("Move them to", selection: $destination) {
                    ForEach(center.workspaces.filter { $0.id != ws.id }) { Text("\($0.icon) \($0.name)").tag($0.id) }
                }
                .labelsHidden().fixedSize()
            }
            HStack {
                Button("Cancel") { deleting = nil }
                Button(held.bots + held.groups == 0 ? "Delete Workspace" : "Move Everything and Delete the Workspace", role: .destructive) {
                    if center.delete(ws.id, movingContentsTo: held.bots + held.groups == 0 ? nil : destination) {
                        deleting = nil
                        model.reloadAll()
                    }
                }
            }
            .controlSize(.small)
        }
        .padding(Theme.Space.m)
        .background(Theme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
    }
}

/// Confirms a move or a duplicate, and sorts out bots that are also in a group that isn't moving.
struct MoveSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let move: WorkspaceMove
    @State private var shared: [SharedBot] = []
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                WorkspaceTile(workspace: move.destination, size: 40)
                Text(title).font(Theme.rounded(.title3, weight: .bold)).fixedSize(horizontal: false, vertical: true)
            }
            if shared.isEmpty {
                Text(detail).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("\(shared.map { model.bot($0.botId)?.name ?? $0.botId }.joined(separator: ", ")) also \(shared.count == 1 ? "belongs" : "belong") to other groups that aren't moving: \(sharedGroups). A bot lives in one workspace, so choose:")
                    .foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            }
            if let problem { Text(problem).font(.callout).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if shared.isEmpty {
                    Button(buttonTitle) { run(.ask) }.buttonStyle(PillButtonStyle()).keyboardShortcut(.defaultAction)
                } else {
                    Button("Take Them Out of This Group") { run(.leaveOut) }
                    Button("Give This Group Its Own Copies") { run(.duplicate) }.buttonStyle(PillButtonStyle())
                }
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 480)
        .sheetBackground()
    }

    private var sharedGroups: String {
        let names = shared.flatMap(\.otherGroups).compactMap { model.group($0)?.name }
        return Array(Set(names)).sorted().joined(separator: ", ")
    }

    private var title: String {
        switch move.kind {
        case .group(let g): return "Move \(g.name) and its \(g.everyone.count) bot\(g.everyone.count == 1 ? "" : "s") to \(move.destination.name)?"
        case .bot(let b): return "Move \(b.name) to \(move.destination.name)?"
        case .duplicate(let b): return "Duplicate \(b.name) into \(move.destination.name)?"
        }
    }

    private var detail: String {
        switch move.kind {
        case .group, .bot: return "Their chats, memory and routines go with them, and they keep everything they know. They'll show in \(move.destination.name) and no longer in this workspace."
        case .duplicate: return "Makes a copy with the same setup and instructions, but its own empty memory and its own chats. The original is unchanged, and the two won't share anything from here on."
        }
    }

    private var buttonTitle: String {
        switch move.kind {
        case .duplicate: return "Duplicate"
        default: return "Move"
        }
    }

    private func run(_ policy: SharedBotPolicy) {
        switch WorkspaceCenter.shared.perform(move, shared: policy) {
        case .done: dismiss()
        case .failed(let message): problem = message
        case .sharedBots(let found): shared = found
        }
    }
}
#endif
