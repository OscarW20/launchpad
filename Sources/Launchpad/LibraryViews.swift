#if os(macOS)
import SwiftUI
import LaunchpadCore

// MARK: - Skills

struct SkillListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        PanelList(selection: $model.selectedSkillId) {
            ForEach(model.skills) { skill in
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name)
                        .font(Theme.rounded(.body, weight: .semibold))
                    Text(skill.description.isEmpty ? "No description" : skill.description)
                        .font(.callout)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                    let users = model.bots.filter { $0.skills.contains(skill.id) }.count + model.groups.filter { $0.skills.contains(skill.id) }.count
                    if users > 0 {
                        Text("Given to \(users) bot\(users == 1 ? "" : "s")/group\(users == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                    }
                }
                .padding(.vertical, 3)
                .selectableRow(skill.id)
                .contextMenu {
                    Button("Duplicate") { model.duplicateSkill(skill.id) }
                    Button("Delete", role: .destructive) { model.deleteSkill(skill.id) }
                }
            }
        }
        .navigationTitle("Skills")
        .columnHeader("Skills") {
            CircleMenu(symbol: "plus", help: "Create a skill, or add Graphify") {
                Button("New Skill") { model.newSkill() }
                Divider()
                Button(model.skill(Graphify.skillId) == nil ? "Add Graphify (code knowledge graph)" : "Update Graphify Skill") { model.addGraphify() }
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
                IconTile(symbol: "sparkles", size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(parsed.name ?? skillId)
                        .font(Theme.rounded(.title2, weight: .bold))
                        .foregroundStyle(Theme.text)
                    Text(parsed.description ?? "Add a description: it tells bots when to use this skill.")
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                }
                Spacer()
                SkillLockToggle(skillId: skillId)
                PillTabs(selection: $mode, options: Mode.allCases.map { ($0.rawValue, $0) })
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.vertical, Theme.Space.l)

            HStack(spacing: 0) {
                if mode != .preview {
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(Theme.Space.m)
                        .background(Theme.code)
                }
                if mode == .split { Rectangle().fill(Theme.line).frame(width: 1) }
                if mode != .edit {
                    ScrollView {
                        MarkdownView(text: parsed.body)
                            .padding(Theme.Space.l)
                    }
                    .background(Theme.card)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.line).allowsHitTesting(false))
            .padding(.horizontal, Theme.Space.l)

            GiveSkillBar(skillId: skillId)
        }
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
            SectionHeader("Give to")
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
                        Text("No bots or groups yet.").foregroundStyle(Theme.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.m)
    }

    private func chip(title: String, emoji: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(emoji)
                Text(title)
                if on { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(on ? Theme.accentText : Theme.text)
            .padding(.horizontal, Theme.Space.m)
            .frame(height: 30)
            .background(on ? Theme.accentSoft : Theme.field, in: Capsule())
            .overlay(Capsule().strokeBorder(on ? Theme.accent.opacity(0.5) : Theme.line))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
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
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(template.role)
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                }
            }
            Text(template.blurb)
                .font(.callout)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Pill(text: template.engine.displayName, symbol: EngineStyle.symbol(template.engine))
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
                        .buttonStyle(SoftButtonStyle())
                        .controlSize(.small)
                } else {
                    Spacer()
                    Button("Hire") { model.hire(template) }
                        .buttonStyle(PillButtonStyle())
                }
            }
        }
        .padding(Theme.Space.l + 4)
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.line))
    }
}

// MARK: - Connectors

struct ConnectorListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        PanelList(selection: $model.selectedConnectorId) {
            ForEach(model.connectors) { c in
                HStack(spacing: 10) {
                    Image(systemName: c.kind == .http ? "globe" : "terminal")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accentText)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Theme.accentSoft))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name).font(Theme.rounded(.body, weight: .semibold))
                        Text(c.kind == .http ? (c.url ?? "") : ([c.command ?? ""] + c.args).joined(separator: " "))
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 3)
                .selectableRow(c.id)
            }
        }
        .navigationTitle("Connectors")
        .columnHeader("Connectors") {
            Button { model.addConnector() } label: { Label("Add Connector", systemImage: "plus") }
                .help("Add an MCP server")
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
                .themedForm()
            } else {
                EmptyState(symbol: "questionmark.circle", title: "Connector not found")
            }
        }
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

// MARK: - Routines (see RoutineViews.swift)

// MARK: - Usage

struct UsageSummary: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let u = model.usage
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Plan usage")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
            windows("Claude", u.claudeWindows, empty: "no data yet")
            if let codex = u.codexWindows, !codex.isEmpty {
                windows("ChatGPT", codex, empty: "")
            } else {
                row("ChatGPT", detail: u.codexTokensToday > 0 && u.codexDay == todayKey ? "\(formatTokens(u.codexTokensToday)) tokens today" : "no data yet")
            }
            Divider().overlay(Theme.line).padding(.vertical, 2)
        }
    }

    @ViewBuilder private func windows(_ plan: String, _ list: [UsageWindow], empty: String) -> some View {
        if list.isEmpty {
            row(plan, detail: empty)
        } else {
            ForEach(list, id: \.name) { w in
                let fraction = min(1, max(0, w.utilization))
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("\(plan) · \(w.label)").font(.system(size: 12)).foregroundStyle(Theme.text)
                        Spacer()
                        Text("\(Int((w.utilization * 100).rounded()))%")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.secondary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.line)
                            Capsule().fill(w.utilization > 0.8 ? Theme.failureFill : Theme.accent)
                                .frame(width: max(4, geo.size.width * fraction))
                        }
                    }
                    .frame(height: 4)
                    .accessibilityElement()
                    .accessibilityLabel("\(plan) \(w.label)")
                    .accessibilityValue("\(Int((w.utilization * 100).rounded())) percent")
                }
                .help(w.resetsAt.map { "Resets \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
            }
        }
    }

    private var todayKey: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private func row(_ title: String, detail: String) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.text)
            Spacer()
            Text(detail).font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
    }

    private func formatTokens(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }
}
#endif
