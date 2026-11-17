#if os(macOS)
import SwiftUI
import LaunchpadCore

// MARK: - Skills

struct SkillListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedSkillId) {
            ForEach(model.skills) { skill in
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name)
                        .font(Theme.rounded(.body, weight: .semibold))
                    Text(skill.description.isEmpty ? "No description" : skill.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    let users = model.bots.filter { $0.skills.contains(skill.id) }.count + model.groups.filter { $0.skills.contains(skill.id) }.count
                    if users > 0 {
                        Text("Given to \(users) bot\(users == 1 ? "" : "s")/group\(users == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                    }
                }
                .padding(.vertical, 3)
                .tag(skill.id)
                .contextMenu {
                    Button("Duplicate") { model.duplicateSkill(skill.id) }
                    Button("Delete", role: .destructive) { model.deleteSkill(skill.id) }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(Theme.canvas)
        .navigationTitle("Skills")
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("New Skill") { model.newSkill() }
                    Divider()
                    Button(model.skill(Graphify.skillId) == nil ? "Add Graphify (code knowledge graph)" : "Update Graphify Skill") { model.addGraphify() }
                } label: {
                    Label("New Skill", systemImage: "plus")
                }
                .help("Create a skill, or add Graphify")
            }
        }
    }
}

struct SkillDetailView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case edit = "Edit", preview = "Preview", split = "Side by side"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    let skillId: String
    @State private var text = ""
    @State private var original = ""
    @State private var mode: Mode = .split
    @State private var confirmDelete = false

    var body: some View {
        let parsed = SkillFile.parse(text)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(parsed.name ?? skillId)
                        .font(Theme.rounded(.title2, weight: .bold))
                    Text(parsed.description ?? "Add a description: it tells bots when to use this skill.")
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
            }
            .padding(20)

            HStack(spacing: 0) {
                if mode != .preview {
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .background(Theme.surface)
                }
                if mode == .split { Divider() }
                if mode != .edit {
                    ScrollView {
                        MarkdownView(text: parsed.body)
                            .padding(16)
                    }
                    .background(Theme.canvas)
                }
            }
            .overlay(Rectangle().strokeBorder(Theme.border).allowsHitTesting(false))

            GiveSkillBar(skillId: skillId)
        }
        .background(Theme.canvas)
        .navigationTitle(parsed.name ?? "Skill")
        .toolbar {
            ToolbarItemGroup {
                Button { model.duplicateSkill(skillId) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                    .help("Duplicate")
                Button { SystemActions.reveal(model.skillStore.file(skillId)) } label: { Label("Show in Finder", systemImage: "folder") }
                    .help("Show SKILL.md in Finder")
                Button { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                    .help("Delete")
                Button("Save") {
                    model.saveSkill(id: skillId, text: text)
                    original = text
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(text == original)
            }
        }
        .onAppear(perform: load)
        .onChange(of: model.skills) { if text == original { load() } }
        .confirmationDialog("Delete \(parsed.name ?? skillId)?", isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive) { model.deleteSkill(skillId) }
        } message: {
            Text("It's removed from every bot and group that has it.")
        }
    }

    private func load() {
        let t = model.skill(skillId)?.text ?? ""
        text = t
        original = t
    }
}

/// "Give this skill to…" chips for bots and groups.
struct GiveSkillBar: View {
    @Environment(AppModel.self) private var model
    let skillId: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Give to")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.groups) { g in
                        chip(title: g.displayName, emoji: g.emoji, on: g.skills.contains(skillId)) {
                            model.toggle(skill: skillId, forGroup: g.id)
                        }
                    }
                    ForEach(model.bots) { b in
                        chip(title: b.name, emoji: b.emoji, on: b.skills.contains(skillId)) {
                            model.toggle(skill: skillId, for: b.id)
                        }
                    }
                    if model.bots.isEmpty && model.groups.isEmpty {
                        Text("No bots or groups yet.").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Theme.surface.opacity(0.6))
    }

    private func chip(title: String, emoji: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(emoji)
                Text(title)
                if on { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(on ? Theme.accent.opacity(0.2) : Theme.raised, in: Capsule())
            .overlay(Capsule().strokeBorder(on ? Theme.accent.opacity(0.6) : Theme.border))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Marketplace (see MarketplaceView.swift)

struct TemplateCard: View {
    @Environment(AppModel.self) private var model
    let template: HireTemplate

    var body: some View {
        let hired = model.bots.contains { $0.id == template.id }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AvatarView(bot: template.bot, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(template.name)
                        .font(Theme.rounded(.headline, weight: .bold))
                    Text(template.role)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Text(template.blurb)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Pill(text: template.engine.displayName, symbol: template.engine == .claude ? "sparkle" : "chevron.left.forwardslash.chevron.right")
                Pill(text: template.permission.displayName, symbol: "lock")
            }
            Spacer(minLength: 0)
            HStack {
                if hired {
                    Label("On your team", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(Theme.success)
                    Spacer()
                    Button("Hire another") { model.hire(template) }
                        .controlSize(.small)
                } else {
                    Spacer()
                    Button("Hire") { model.hire(template) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
    }
}

// MARK: - Connectors

struct ConnectorListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedConnectorId) {
            ForEach(model.connectors) { c in
                HStack(spacing: 10) {
                    Image(systemName: c.kind == .http ? "globe" : "terminal")
                        .foregroundStyle(Theme.accent)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name).font(Theme.rounded(.body, weight: .semibold))
                        Text(c.kind == .http ? (c.url ?? "") : ([c.command ?? ""] + c.args).joined(separator: " "))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 3)
                .tag(c.id)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(Theme.canvas)
        .navigationTitle("Connectors")
        .toolbar {
            ToolbarItem {
                Button { model.addConnector() } label: { Label("Add Connector", systemImage: "plus") }
                    .help("Add an MCP server")
            }
        }
    }
}

struct ConnectorDetailView: View {
    @Environment(AppModel.self) private var model
    let connectorId: String
    @State private var draft: Connector?
    @State private var original: Connector?
    @State private var argsText = ""
    @State private var token = ""
    @State private var envValues: [String: String] = [:]
    @State private var newEnvName = ""
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let binding = Binding($draft), let c = draft {
                Form {
                    Section("Server") {
                        TextField("Name", text: binding.name)
                        Picker("Type", selection: binding.kind) {
                            Text("URL (HTTP)").tag(Connector.Kind.http)
                            Text("Command (stdio)").tag(Connector.Kind.stdio)
                        }
                        .pickerStyle(.segmented)
                        if c.kind == .http {
                            TextField("URL", text: Binding(get: { c.url ?? "" }, set: { draft?.url = $0 }), prompt: Text("https://mcp.example.com/mcp"))
                        } else {
                            TextField("Command", text: Binding(get: { c.command ?? "" }, set: { draft?.command = $0 }), prompt: Text("npx"))
                            TextField("Arguments", text: $argsText, prompt: Text("-y @modelcontextprotocol/server-filesystem ~/Documents"))
                        }
                    }

                    Section {
                        if c.kind == .http {
                            Toggle("Sends an API token", isOn: binding.usesToken)
                            if c.usesToken {
                                SecretField(title: "Token", account: c.tokenAccount, value: $token)
                            }
                        }
                        ForEach(c.secretEnv, id: \.self) { name in
                            HStack {
                                SecretField(title: name, account: c.envAccount(name), value: Binding(
                                    get: { envValues[name] ?? "" }, set: { envValues[name] = $0 }
                                ))
                                Button { draft?.secretEnv.removeAll { $0 == name } } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                            }
                        }
                        HStack {
                            TextField("Add a secret variable", text: $newEnvName, prompt: Text("e.g. API_KEY"))
                            Button("Add") {
                                let n = newEnvName.trimmingCharacters(in: .whitespaces).uppercased()
                                if !n.isEmpty, !(draft?.secretEnv.contains(n) ?? true) { draft?.secretEnv.append(n) }
                                newEnvName = ""
                            }
                        }
                    } header: {
                        Text("Secrets")
                    } footer: {
                        Text("Saved in your macOS Keychain. Bots get them only while they run, through the environment: never in files, logs or chat.")
                    }

                    Section {
                        HStack {
                            Button("Sign in with Claude Code…") { signInClaude(c) }
                            Button("Sign in with Codex…") { signInCodex(c) }
                        }
                    } header: {
                        Text("Sign-in")
                    } footer: {
                        Text("For servers that use OAuth. Opens Terminal; Claude Code or Codex handles the sign-in and keeps the login itself.")
                    }

                    Section("Turned on for") {
                        ForEach(model.groups) { g in
                            Toggle("\(g.emoji) \(g.displayName)", isOn: Binding(
                                get: { model.group(g.id)?.connectors.contains(connectorId) ?? false },
                                set: { _ in model.toggle(connector: connectorId, forGroup: g.id) }
                            ))
                        }
                        ForEach(model.bots) { b in
                            Toggle("\(b.emoji) \(b.name)", isOn: Binding(
                                get: { model.bot(b.id)?.connectors.contains(connectorId) ?? false },
                                set: { _ in model.toggle(connector: connectorId, for: b.id) }
                            ))
                        }
                    }

                    Section {
                        Button("Remove Connector…", role: .destructive) { confirmDelete = true }
                    }
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView("Connector not found", systemImage: "questionmark.circle")
            }
        }
        .background(Theme.canvas)
        .navigationTitle(draft?.name ?? "Connector")
        .toolbar {
            ToolbarItem {
                Button("Save") { save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!isDirty)
            }
        }
        .onAppear(perform: load)
        .confirmationDialog("Remove \(draft?.name ?? "this connector")?", isPresented: $confirmDelete) {
            Button("Remove", role: .destructive) { model.removeConnector(connectorId) }
        } message: {
            Text("Its saved secrets are deleted from your Keychain too.")
        }
    }

    private var isDirty: Bool {
        var d = draft
        d?.args = splitArgs(argsText)
        return d != original || !token.isEmpty || envValues.values.contains { !$0.isEmpty }
    }

    private func load() {
        draft = model.connectors.first { $0.id == connectorId }
        original = draft
        argsText = (draft?.args ?? []).joined(separator: " ")
        token = ""
        envValues = [:]
    }

    private func save() {
        guard var c = draft else { return }
        c.args = splitArgs(argsText)
        c.name = c.name.trimmingCharacters(in: .whitespaces).isEmpty ? c.id : c.name
        model.saveConnector(c)
        if !token.isEmpty { model.setSecret(token, for: c.tokenAccount) }
        for (name, value) in envValues where !value.isEmpty { model.setSecret(value, for: c.envAccount(name)) }
        load()
    }

    private func splitArgs(_ s: String) -> [String] {
        s.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    }

    private func signInClaude(_ c: Connector) {
        let add = c.kind == .http
            ? "claude mcp add --scope user --transport http \(c.serverKey) '\(c.url ?? "")'"
            : "claude mcp add --scope user \(c.serverKey) -- \(([c.command ?? ""] + c.args).joined(separator: " "))"
        let script = "\(add); echo; echo 'Now type /mcp, pick \(c.serverKey) and sign in. Then type /exit.'; claude"
        model.perform(.openTerminal(command: script))
    }

    private func signInCodex(_ c: Connector) {
        let add = c.kind == .http
            ? "codex mcp add \(c.serverKey) --url '\(c.url ?? "")'"
            : "codex mcp add \(c.serverKey) -- \(([c.command ?? ""] + c.args).joined(separator: " "))"
        model.perform(.openTerminal(command: "\(add); codex mcp login \(c.serverKey)"))
    }
}

/// A secure text field that shows whether a value is already in the Keychain.
struct SecretField: View {
    @Environment(AppModel.self) private var model
    let title: String
    let account: String
    @Binding var value: String

    var body: some View {
        let saved = model.hasSecret(account)
        HStack {
            SecureField(title, text: $value, prompt: Text(saved ? "Saved in Keychain. Type to replace." : "Paste value"))
            if saved {
                Image(systemName: "lock.fill")
                    .foregroundStyle(Theme.success)
                    .help("Saved in your Keychain")
                Button("Forget") { model.setSecret(nil, for: account); value = "" }
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - Routines

struct RoutineListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedRoutineId) {
            ForEach(model.routines) { r in
                HStack(spacing: 10) {
                    Image(systemName: icon(r))
                        .foregroundStyle(r.enabled ? Theme.accent : .secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.name).font(Theme.rounded(.body, weight: .semibold))
                        Text("\(r.summary) → \(targetName(r.target))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if !r.enabled { Text("Off").font(.caption).foregroundStyle(.secondary) }
                }
                .padding(.vertical, 3)
                .tag(r.id)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(Theme.canvas)
        .navigationTitle("Routines")
        .toolbar {
            ToolbarItem {
                Button { model.newRoutine() } label: { Label("New Routine", systemImage: "plus") }
                    .help("Create a routine")
            }
        }
    }

    private func icon(_ r: Routine) -> String {
        if case .newFile = r.trigger { return "tray.and.arrow.down" }
        return "clock"
    }

    private func targetName(_ t: Routine.Target) -> String {
        switch t {
        case .bot(let id): return model.bot(id)?.name ?? id
        case .group(let id): return model.group(id)?.displayName ?? id
        }
    }
}

struct RoutineDetailView: View {
    enum TriggerKind: String, CaseIterable, Identifiable {
        case daily = "At a time", every = "Every…", newFile = "When a file appears"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    let routineId: String
    @State private var draft: Routine?
    @State private var original: Routine?

    var body: some View {
        Group {
            if let binding = Binding($draft), let r = draft {
                Form {
                    Section("Routine") {
                        TextField("Name", text: binding.name)
                        Toggle("On", isOn: binding.enabled)
                    }
                    Section("Send to") {
                        Picker("Bot or group", selection: Binding(get: { targetKey(r.target) }, set: { draft?.target = target(from: $0) })) {
                            ForEach(model.groups) { g in Text("\(g.emoji) \(g.displayName)").tag("group:\(g.id)") }
                            ForEach(model.bots) { b in Text("\(b.emoji) \(b.name)").tag("bot:\(b.id)") }
                        }
                        TextEditor(text: binding.message)
                            .frame(minHeight: 90)
                    }
                    Section {
                        Picker("When", selection: Binding(get: { kind(r.trigger) }, set: { draft?.trigger = defaultTrigger($0) })) {
                            ForEach(TriggerKind.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        triggerFields(r.trigger)
                    } header: {
                        Text("When")
                    } footer: {
                        Text("Routines run while Launchpad is open. A daily routine you missed runs once when you next open the app that day.")
                    }
                    Section {
                        if let last = r.lastRun {
                            LabeledContent("Last ran", value: last.formatted(date: .abbreviated, time: .shortened))
                        }
                        HStack {
                            Button("Run Now") { model.runRoutineNow(routineId) }
                            if let chatId = r.chatId, model.chat(chatId) != nil {
                                Button("Open Chat") { model.show(chat: chatId) }
                            }
                            Spacer()
                            Button("Delete Routine", role: .destructive) { model.deleteRoutine(routineId) }
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView("Routine not found", systemImage: "questionmark.circle")
            }
        }
        .background(Theme.canvas)
        .navigationTitle(draft?.name ?? "Routine")
        .toolbar {
            ToolbarItem {
                Button("Save") {
                    if let d = draft { model.saveRoutine(d); load() }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(draft == original)
            }
        }
        .onAppear(perform: load)
    }

    @ViewBuilder private func triggerFields(_ t: Routine.Trigger) -> some View {
        switch t {
        case let .daily(hour, minute, weekdays):
            DatePicker("Time", selection: Binding(
                get: { Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date() },
                set: { d in
                    let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                    draft?.trigger = .daily(hour: c.hour ?? 9, minute: c.minute ?? 0, weekdaysOnly: weekdays)
                }
            ), displayedComponents: .hourAndMinute)
            Toggle("Weekdays only", isOn: Binding(get: { weekdays }, set: { draft?.trigger = .daily(hour: hour, minute: minute, weekdaysOnly: $0) }))
        case .every(let minutes):
            Picker("Every", selection: Binding(get: { minutes }, set: { draft?.trigger = .every(minutes: $0) })) {
                Text("15 minutes").tag(15)
                Text("30 minutes").tag(30)
                Text("hour").tag(60)
                Text("2 hours").tag(120)
                Text("4 hours").tag(240)
                Text("day").tag(1440)
            }
        case .newFile(let folder):
            HStack {
                Text(folder.isEmpty ? "No folder chosen" : folder)
                    .font(.callout.monospaced())
                    .foregroundStyle(folder.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url { draft?.trigger = .newFile(folder: url.path) }
                }
            }
        }
    }

    private func load() {
        draft = model.routines.first { $0.id == routineId }
        original = draft
    }

    private func kind(_ t: Routine.Trigger) -> TriggerKind {
        switch t {
        case .daily: return .daily
        case .every: return .every
        case .newFile: return .newFile
        }
    }

    private func defaultTrigger(_ k: TriggerKind) -> Routine.Trigger {
        if k == kind(draft?.trigger ?? .every(minutes: 60)), let t = draft?.trigger { return t }
        switch k {
        case .daily: return .daily(hour: 9, minute: 0, weekdaysOnly: true)
        case .every: return .every(minutes: 60)
        case .newFile: return .newFile(folder: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path)
        }
    }

    private func targetKey(_ t: Routine.Target) -> String {
        switch t {
        case .bot(let id): return "bot:\(id)"
        case .group(let id): return "group:\(id)"
        }
    }

    private func target(from key: String) -> Routine.Target {
        if key.hasPrefix("group:") { return .group(String(key.dropFirst(6))) }
        return .bot(String(key.dropFirst(4)))
    }
}

// MARK: - Usage

struct UsageSummary: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let u = model.usage
        VStack(alignment: .leading, spacing: 5) {
            Text("Usage")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if u.claudeWindows.isEmpty {
                row("Claude", detail: "no data yet")
            } else {
                ForEach(u.claudeWindows, id: \.name) { w in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Claude · \(w.label)").font(.caption)
                            Spacer()
                            Text("\(Int((w.utilization * 100).rounded()))%").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        ProgressView(value: min(1, max(0, w.utilization)))
                            .tint(w.utilization > 0.8 ? Theme.failure : Theme.accent)
                            .controlSize(.mini)
                    }
                    .help(w.resetsAt.map { "Resets \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
                }
            }
            row("ChatGPT", detail: u.codexTokensToday > 0 && u.codexDay == todayKey ? "\(formatTokens(u.codexTokensToday)) tokens today" : "no data yet")
            Divider().padding(.vertical, 2)
        }
    }

    private var todayKey: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private func row(_ title: String, detail: String) -> some View {
        HStack {
            Text(title).font(.caption)
            Spacer()
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func formatTokens(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }
}
#endif
