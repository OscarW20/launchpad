#if os(macOS)
import SwiftUI
import LaunchpadCore

struct GroupAvatar: View {
    let group: BotGroup?
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.accentSoft)
            Circle()
                .strokeBorder(Theme.accent.opacity(0.25), lineWidth: 1)
            Text(group?.emoji ?? "👥")
                .font(.system(size: size * 0.5))
        }
        .frame(width: size, height: size)
        .accessibilityLabel(group?.displayName ?? "Group")
    }
}

struct GroupListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.workspaceGroups.isEmpty {
                VStack(spacing: 10) {
                    Text(WorkspaceCenter.shared.isInUse ? "No groups in \(WorkspaceCenter.shared.current.name) yet." : "No groups yet.")
                        .font(Theme.rounded(.headline))
                    Button("New Group") { model.showingNewGroup = true }
                        .buttonStyle(PillButtonStyle())
                        .disabled(model.workspaceBots.isEmpty)
                    Button("Hire the Dev team") { model.section = .hire }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PanelList(selection: $model.selectedGroupId) {
                    ForEach(model.workspaceGroups) { group in
                        HStack(spacing: 10) {
                            GroupAvatar(group: group, size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.displayName)
                                    .font(Theme.rounded(.body, weight: .semibold))
                                Text("\(group.everyone.count) members · lead: \(model.bot(group.lead)?.name ?? "none")")
                                    .font(.callout)
                                    .foregroundStyle(Theme.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 3)
                        .selectableRow(group.id)
                        .contextMenu {
                            Button("Open Chat") { model.openChat(with: group) }
                            Divider()
                            GroupWorkspaceMenu(group: group)
                        }
                    }
                }
            }
        }
        .navigationTitle("Groups")
        .columnHeader("Groups") {
            Button { model.showingNewGroup = true } label: { Label("New Group", systemImage: "plus") }
                .help("Create a group")
                .disabled(model.bots.isEmpty)
        }
    }
}

/// Members, lead, rules and limit. Shared by the new-group sheet and the editor.
struct GroupFormSections: View {
    @Environment(AppModel.self) private var model
    @Binding var group: BotGroup

    var body: some View {
        Section("Group") {
            TextField("Name", text: $group.name, prompt: Text("e.g. build-and-ship"))
            TextField("Emoji", text: Binding(get: { group.emoji }, set: { if let c = $0.last { group.emoji = String(c) } }))
        }
        Section {
            ForEach(model.workspaceBots) { bot in
                Toggle(isOn: Binding(
                    get: { group.members.contains(bot.id) },
                    set: { on in
                        if on { group.members.append(bot.id) } else {
                            group.members.removeAll { $0 == bot.id }
                            if group.lead == bot.id { group.lead = group.members.first }
                        }
                        if group.lead == nil { group.lead = group.members.first }
                    }
                )) {
                    HStack(spacing: 8) {
                        AvatarView(bot: bot, size: 22)
                        Text(bot.name)
                        if !bot.role.isEmpty { Text(bot.role).foregroundStyle(Theme.secondary).lineLimit(1) }
                    }
                }
            }
            Picker("Lead", selection: Binding(get: { group.lead ?? "" }, set: { group.lead = $0.isEmpty ? nil : $0 })) {
                Text("None").tag("")
                ForEach(group.members, id: \.self) { id in
                    Text(model.bot(id)?.name ?? id).tag(id)
                }
            }
        } header: {
            Text("Members")
        } footer: {
            Text("The lead replies first and hands work to members by @mention.")
        }
        Section {
            TextEditor(text: $group.rules)
                .frame(minHeight: 100)
            Stepper("Hand-off limit: \(group.handoffLimit)", value: $group.handoffLimit, in: 1...20)
        } header: {
            Text("Rules")
        } footer: {
            Text("Every bot in the group sees these rules. When the team has handed work on this many times, it stops and asks you.")
        }
    }
}

struct NewGroupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var group = BotGroup(id: "", name: "", emoji: "👥")

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                GroupAvatar(group: group, size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.name.isEmpty ? "New group" : "#\(group.name)")
                        .font(Theme.rounded(.title2, weight: .bold))
                    Text("Bots that work together, with a lead.")
                        .foregroundStyle(Theme.secondary)
                }
                Spacer()
            }
            .buttonStyle(SoftButtonStyle())
            .padding(.horizontal, Theme.Space.xl)
            .padding(.vertical, Theme.Space.l)
            Form {
                GroupFormSections(group: $group)
            }
            .themedForm()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Group") {
                    if let g = model.createGroup(name: group.name, emoji: group.emoji, members: group.members,
                                                 lead: group.lead, rules: group.rules, limit: group.handoffLimit) {
                        dismiss()
                        model.openChat(with: g)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(PillButtonStyle())
                .disabled(group.name.trimmingCharacters(in: .whitespaces).isEmpty || group.members.isEmpty)
            }
            .padding(Theme.Space.l)
        }
        .frame(width: 560, height: 680)
        .sheetBackground()
    }
}

struct GroupDetailView: View {
    @Environment(AppModel.self) private var model
    let groupId: String
    @State private var draft: BotGroup?
    @State private var original: BotGroup?
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let binding = Binding($draft), let group = draft {
                VStack(spacing: 0) {
                    HStack(spacing: 14) {
                        GroupAvatar(group: group, size: 56)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(group.displayName)
                                .font(Theme.rounded(.title2, weight: .bold))
                            Text("~/Launchpad/groups/\(groupId)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Theme.secondary)
                            if let origin = WorkspaceCenter.shared.origin(ofGroup: groupId) {
                                Text("Copied from \(origin.group) in \(origin.workspace.name). The two are separate.")
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondary)
                            }
                        }
                        Spacer()
                        Button { model.summaryGroupId = groupId } label: { Label("Summary", systemImage: "doc.text") }
                        Button { SystemActions.reveal(model.groupStore.dir(groupId)) } label: { Label("Show in Finder", systemImage: "folder") }
                        Button {
                            if let g = model.group(groupId) { model.openChat(with: g) }
                        } label: { Label("Open Chat", systemImage: "bubble.left.and.bubble.right.fill") }
                            .buttonStyle(PillButtonStyle())
                    }
                    .buttonStyle(SoftButtonStyle())
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.vertical, Theme.Space.l)
                    Form {
                        GroupFormSections(group: binding)
                        // Kept outside group.json (bots can edit that), so it applies straight away, without Save.
                        let mode = model.approvalMode(for: groupId)
                        Section {
                            Picker("Approvals", selection: Binding(get: { mode }, set: { model.setApprovalMode($0, for: group) })) {
                                ForEach(ApprovalMode.allCases) { m in
                                    Text(m.title).tag(m)
                                }
                            }
                            .pickerStyle(.segmented)
                        } header: {
                            Text("Approvals")
                        } footer: {
                            Text(mode.detail + " You can also type “accept mode” or “ask mode” in the group chat.")
                                .foregroundStyle(mode == .fullFreedom ? Theme.warning : Theme.secondary)
                        }
                        Section {
                            ForEach(model.skills) { skill in
                                Toggle(skill.name, isOn: Binding(
                                    get: { draft?.skills.contains(skill.id) ?? false },
                                    set: { on in
                                        if on { draft?.skills.append(skill.id) } else { draft?.skills.removeAll { $0 == skill.id } }
                                    }
                                ))
                            }
                        } header: {
                            Text("Skills for the whole group")
                        } footer: {
                            Text("Every member gets these, on top of their own.")
                        }
                        Section("Connectors for the whole group") {
                            if model.connectors.isEmpty {
                                Text("No connectors yet.").foregroundStyle(Theme.secondary)
                            }
                            ForEach(model.connectors) { c in
                                Toggle(c.name, isOn: Binding(
                                    get: { draft?.connectors.contains(c.id) ?? false },
                                    set: { on in
                                        if on { draft?.connectors.append(c.id) } else { draft?.connectors.removeAll { $0 == c.id } }
                                    }
                                ))
                            }
                        }
                        Section {
                            Button("Move Group to Trash…", role: .destructive) { confirmDelete = true }
                        }
                    }
                    .themedForm()
                }
            } else {
                EmptyState(symbol: "questionmark.circle", title: "Group not found")
            }
        }
        .navigationTitle(draft?.displayName ?? "Group")
        .toolbar {
            ToolbarItemGroup {
                if draft != original {
                    Button("Revert") { load() }
                }
                Button("Save") {
                    if var g = draft {
                        g.name = g.name.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                        if g.name.isEmpty { g.name = original?.name ?? groupId }
                        model.saveGroup(g)
                        load()
                    }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(draft == original)
            }
        }
        .onAppear(perform: load)
        .onChange(of: model.groups) { if draft == original { load() } }
        .confirmationDialog("Move \(draft?.displayName ?? "this group") to the Trash?", isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive) { model.deleteGroup(groupId) }
        } message: {
            Text("The bots stay. The group's folder, summary and shared project go to the Trash.")
        }
    }

    private func load() {
        draft = model.group(groupId)
        original = draft
    }
}
#endif
