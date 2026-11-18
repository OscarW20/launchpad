#if os(macOS)
import SwiftUI
import AppKit
import LaunchpadCore

/// Connectors, done the easy way: a catalogue of apps with + Add, plus your own MCP servers.
struct AppsPage: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var openApp: ConnectorPreset?
    @State private var openServer: ServerRef?

    struct ServerRef: Identifiable { let id: String }

    private let columns = [GridItem(.flexible(), spacing: Theme.Space.xl), GridItem(.flexible(), spacing: Theme.Space.xl)]

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                header
                yourServers
                ForEach(ConnectorCatalog.categories, id: \.self) { category in
                    let apps = ConnectorCatalog.all.filter { $0.category == category && matches($0.name, $0.blurb) }
                    if !apps.isEmpty {
                        section(title: category, count: apps.count) {
                            ForEach(apps) { preset in
                                AppRowView(preset: preset) { openApp = preset }
                            }
                        }
                    }
                }
            }
            .padding(Theme.Space.xxl)
            .frame(maxWidth: 1120)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Apps")
        .sheet(item: $openApp) { AppDetailSheet(preset: $0) }
        .sheet(item: $openServer) { ServerSheet(connectorId: $0.id) }
        .sheet(isPresented: $model.showingNewServer) { ServerSheet(connectorId: nil) }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Apps")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.text)
                Text("Give your bots apps and services. Keys stay in your Keychain.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                if WorkspaceCenter.shared.isInUse {
                    Label("Shared across all workspaces: an app you turn on for a bot works the same wherever that bot lives.",
                          systemImage: "square.on.square")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                }
            }
            Spacer()
            SearchField(text: $search, prompt: "Search apps")
                .frame(width: 240)
        }
    }

    private var customServers: [Connector] {
        let catalog = Set(ConnectorCatalog.all.map(\.id))
        return model.connectors.filter { !catalog.contains($0.id) && matches($0.name, $0.url ?? $0.command ?? "") }
    }

    private var yourServers: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Text("Your MCP servers")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button { model.showingNewServer = true } label: { Label("Add MCP server", systemImage: "plus") }
                    .buttonStyle(PillButtonStyle())
            }
            if customServers.isEmpty {
                Text("Connect any MCP server by command or URL, then give it to bots or groups.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.l)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                            .strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    )
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Space.xs) {
                    ForEach(customServers) { c in
                        ServerRowView(connector: c) { openServer = ServerRef(id: c.id) }
                    }
                }
            }
            Divider().padding(.top, Theme.Space.s)
        }
    }

    private func section<Content: View>(title: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.text)
                Text("\(count)").font(.system(size: 15)).foregroundStyle(Theme.secondary)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Space.xs) {
                content()
            }
            Divider().padding(.top, Theme.Space.s)
        }
    }

    private func matches(_ parts: String...) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || parts.joined(separator: " ").lowercased().contains(q)
    }
}

/// "On 2 bots", "On 1 group", or nil.
@MainActor
func holderSummary(_ model: AppModel, _ id: String) -> String? {
    let h = model.holders(of: id)
    var parts: [String] = []
    if !h.bots.isEmpty { parts.append("\(h.bots.count) bot\(h.bots.count == 1 ? "" : "s")") }
    if !h.groups.isEmpty { parts.append("\(h.groups.count) group\(h.groups.count == 1 ? "" : "s")") }
    return parts.isEmpty ? nil : "On " + parts.joined(separator: ", ")
}

/// One catalogue app: logo, name, one-line blurb, and + Add or ✓ On N bots.
struct AppRowView: View {
    @Environment(AppModel.self) private var model
    let preset: ConnectorPreset
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: Theme.Space.m) {
                AppLogo(logo: preset.logo, symbol: preset.symbol, tint: preset.tint, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(preset.blurb).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: Theme.Space.s)
                StateBadge(text: holderSummary(model, preset.id))
            }
            .padding(Theme.Space.m)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(hover ? Theme.rowHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("\(preset.name): \(preset.blurb)")
    }
}

struct ServerRowView: View {
    @Environment(AppModel.self) private var model
    let connector: Connector
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: Theme.Space.m) {
                AppLogo(logo: nil, symbol: connector.kind == .http ? "globe" : "terminal", tint: nil, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(connector.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(connector.kind == .http ? (connector.url ?? "") : ([connector.command ?? ""] + connector.args).joined(separator: " "))
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: Theme.Space.s)
                StateBadge(text: holderSummary(model, connector.id), addLabel: "Turn on")
            }
            .padding(Theme.Space.m)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(hover ? Theme.rowHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// "✓ On 2 bots" or a soft "+ Add" pill.
struct StateBadge: View {
    let text: String?
    var addLabel = "Add"

    var body: some View {
        if let text {
            Label(text, systemImage: "checkmark")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .labelStyle(.titleAndIcon)
        } else {
            Label(addLabel, systemImage: "plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accentText)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(Capsule().fill(Theme.accentSoft))
        }
    }
}

// MARK: - App sheet

/// Everything about one app in one place: keys, sign-in and who has it. Turning a bot on adds the app.
struct AppDetailSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let preset: ConnectorPreset
    @State private var settings: [String: String] = [:]
    @State private var keys: [String: String] = [:]
    @State private var error: String?
    @State private var confirmRemove = false

    private var installed: Connector? { model.connectors.first { $0.id == preset.id } }
    private var keyFields: [ConnectorPreset.Field] { preset.secrets + (preset.token.map { [$0] } ?? []) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.m) {
                AppLogo(logo: preset.logo, symbol: preset.symbol, tint: preset.tint, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name).font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text)
                    Text(preset.blurb).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                if let url = URL(string: preset.docsURL) {
                    Link(destination: url) { Image(systemName: "questionmark.circle") }
                        .help("Docs")
                }
            }
            .padding(Theme.Space.xl)

            Form {
                if let needs = preset.needs, model.runner.locator.locate(command: needs) == nil {
                    Section {
                        Label(needsHelp(needs), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warning)
                    }
                }
                if !preset.settings.isEmpty {
                    Section("Settings") {
                        ForEach(preset.settings, id: \.key) { f in
                            TextField(f.label, text: Binding(get: { settings[f.key] ?? "" }, set: { settings[f.key] = $0 }),
                                      prompt: Text(f.help))
                        }
                    }
                }
                if !keyFields.isEmpty {
                    Section {
                        ForEach(keyFields, id: \.key) { f in
                            let account = installed.map { preset.token?.key == f.key ? $0.tokenAccount : $0.envAccount(f.key) }
                            let saved = account.map { model.hasSecret($0) } ?? false
                            VStack(alignment: .leading, spacing: 3) {
                                SecureField(f.label, text: Binding(get: { keys[f.key] ?? "" }, set: { keys[f.key] = $0 }),
                                            prompt: Text(saved ? "Saved in Keychain. Type to replace." : "Paste it here"))
                                if !f.help.isEmpty {
                                    Text(f.help).font(.caption).foregroundStyle(Theme.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("Keys")
                    } footer: {
                        Text("Saved in your Mac's Keychain. Bots get them only while they run, never in files or chat.")
                    }
                }
                if preset.signsIn {
                    Section {
                        HStack {
                            Button("Sign in with Claude Code…") { if ensureInstalled(), let c = installed { model.signIn(c, with: .claude) } }
                            Button("Sign in with Codex…") { if ensureInstalled(), let c = installed { model.signIn(c, with: .codex) } }
                        }
                    } header: {
                        Text("Sign in")
                    } footer: {
                        Text("\(preset.name) signs in with your own account. Opens Terminal; Claude Code or Codex keeps the login.")
                    }
                }
                Section("Turn on for") {
                    if model.bots.isEmpty && model.groups.isEmpty {
                        Text("No bots or groups yet.").foregroundStyle(Theme.secondary)
                    }
                    ForEach(model.groups) { g in
                        Toggle("\(g.emoji) \(g.displayName)", isOn: Binding(
                            get: { g.connectors.contains(preset.id) },
                            set: { on in if !on || ensureInstalled() { model.setApp(preset, on: on, group: g.id) } }
                        ))
                    }
                    ForEach(model.bots) { b in
                        Toggle("\(b.emoji) \(b.name)", isOn: Binding(
                            get: { b.connectors.contains(preset.id) },
                            set: { on in if !on || ensureInstalled() { model.setApp(preset, on: on, bot: b.id) } }
                        ))
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(Theme.failure) }
                }
                if installed != nil {
                    Section {
                        Button("Remove \(preset.name)…", role: .destructive) { confirmRemove = true }
                    }
                }
            }
            .themedForm()

            HStack {
                Spacer()
                Button("Done") { saveKeys(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PillButtonStyle())
            }
            .padding(Theme.Space.l)
        }
        .frame(width: 560, height: 640)
        .sheetBackground()
        .confirmationDialog("Remove \(preset.name)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                model.removeConnector(preset.id)
                dismiss()
            }
        } message: {
            Text("It's turned off for every bot and group, and its keys are deleted from your Keychain.")
        }
    }

    /// Adds the app if it isn't added yet, using the settings typed here.
    private func ensureInstalled() -> Bool {
        if installed != nil { return true }
        if let e = model.installApp(preset, settings: settings, secrets: nonEmptyKeys) {
            error = e
            return false
        }
        error = nil
        keys = [:]
        return true
    }

    private var nonEmptyKeys: [String: String] { keys.filter { !$0.value.isEmpty } }

    private func saveKeys() {
        guard !nonEmptyKeys.isEmpty else { return }
        if installed == nil {
            _ = ensureInstalled()
        } else if let c = installed {
            try? ConnectorStore.storeSecrets(nonEmptyKeys, for: preset, connector: c, in: model.secrets)
        }
    }

    private func needsHelp(_ needs: String) -> String {
        switch needs {
        case "npx", "node": return "Needs Node.js. Install it from nodejs.org or with: brew install node"
        case "uvx", "uv": return "Needs uv. Install it with: brew install uv"
        case "docker": return "Needs Docker Desktop."
        default: return "Needs `\(needs)` on this Mac."
        }
    }
}

// MARK: - Your own MCP server

/// Add or edit your own MCP server. Nothing is saved until you press Add / Save.
struct ServerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let connectorId: String?
    @State private var draft = Connector(id: "", name: "", kind: .http, url: "")
    @State private var argsText = ""
    @State private var newVariable = ""
    @State private var values: [String: String] = [:]
    @State private var token = ""
    @State private var error: String?
    @State private var confirmRemove = false

    private var existing: Connector? { connectorId.flatMap { id in model.connectors.first { $0.id == id } } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.m) {
                AppLogo(logo: nil, symbol: draft.kind == .http ? "globe" : "terminal", tint: nil, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(existing == nil ? "Add MCP server" : draft.name)
                        .font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text)
                    Text("Any MCP server, by web address or by command.")
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                Spacer()
            }
            .padding(Theme.Space.xl)

            Form {
                Section("Server") {
                    TextField("Name", text: $draft.name, prompt: Text("e.g. My database"))
                    Picker("Type", selection: $draft.kind) {
                        Text("Web address").tag(Connector.Kind.http)
                        Text("Command").tag(Connector.Kind.stdio)
                    }
                    .pickerStyle(.segmented)
                    if draft.kind == .http {
                        TextField("Address", text: Binding(get: { draft.url ?? "" }, set: { draft.url = $0 }),
                                  prompt: Text("https://mcp.example.com/mcp"))
                        Toggle("Sends an API token", isOn: $draft.usesToken)
                        if draft.usesToken {
                            SecureField("Token", text: $token, prompt: Text(tokenSaved ? "Saved in Keychain. Type to replace." : "Paste it here"))
                        }
                    } else {
                        TextField("Command", text: Binding(get: { draft.command ?? "" }, set: { draft.command = $0 }), prompt: Text("npx"))
                        TextField("Arguments", text: $argsText, prompt: Text("-y @modelcontextprotocol/server-filesystem ~/Documents"))
                    }
                }
                Section {
                    ForEach(draft.secretEnv, id: \.self) { name in
                        HStack {
                            SecureField(name, text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 }),
                                        prompt: Text(variableSaved(name) ? "Saved in Keychain" : "Value"))
                            Button { draft.secretEnv.removeAll { $0 == name } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        TextField("Secret variable", text: $newVariable, prompt: Text("e.g. API_KEY"))
                        Button("Add") {
                            let n = newVariable.trimmingCharacters(in: .whitespaces).uppercased()
                            if !n.isEmpty, !draft.secretEnv.contains(n) { draft.secretEnv.append(n) }
                            newVariable = ""
                        }
                        .disabled(newVariable.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Secrets (optional)")
                } footer: {
                    Text("Saved in your Mac's Keychain and passed to the server only while a bot runs.")
                }
                if let c = existing {
                    Section("Turn on for") {
                        ForEach(model.groups) { g in
                            Toggle("\(g.emoji) \(g.displayName)", isOn: Binding(
                                get: { g.connectors.contains(c.id) },
                                set: { _ in model.toggle(connector: c.id, forGroup: g.id) }
                            ))
                        }
                        ForEach(model.bots) { b in
                            Toggle("\(b.emoji) \(b.name)", isOn: Binding(
                                get: { b.connectors.contains(c.id) },
                                set: { _ in model.toggle(connector: c.id, for: b.id) }
                            ))
                        }
                    }
                    Section {
                        HStack {
                            Button("Sign in with Claude Code…") { model.signIn(c, with: .claude) }
                            Button("Sign in with Codex…") { model.signIn(c, with: .codex) }
                        }
                        Button("Remove Server…", role: .destructive) { confirmRemove = true }
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(Theme.failure) }
                }
            }
            .themedForm()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SoftButtonStyle())
                Button(existing == nil ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PillButtonStyle())
            }
            .padding(Theme.Space.l)
        }
        .frame(width: 560, height: 640)
        .sheetBackground()
        .onAppear {
            if let c = existing {
                draft = c
                argsText = c.args.joined(separator: " ")
            }
        }
        .confirmationDialog("Remove \(draft.name)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                if let id = connectorId { model.removeConnector(id) }
                dismiss()
            }
        } message: {
            Text("It's turned off for every bot and group, and its secrets are deleted from your Keychain.")
        }
    }

    private var tokenSaved: Bool { existing.map { model.hasSecret($0.tokenAccount) } ?? false }
    private func variableSaved(_ name: String) -> Bool { existing.map { model.hasSecret($0.envAccount(name)) } ?? false }

    private func save() {
        var c = draft
        c.args = argsText.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if c.kind == .http { c.command = nil; c.args = [] } else { c.url = nil; c.usesToken = false }
        let saved: Connector
        if existing != nil {
            model.saveConnector(c)
            saved = c
        } else {
            if let e = model.addServer(c) { error = e; return }
            guard let added = model.connectors.last(where: { $0.name == c.name.trimmingCharacters(in: .whitespaces) }) else { dismiss(); return }
            saved = added
        }
        if c.usesToken, !token.isEmpty { model.setSecret(token, for: saved.tokenAccount) }
        for (name, value) in values where !value.isEmpty { model.setSecret(value, for: saved.envAccount(name)) }
        dismiss()
    }
}

extension AppModel {
    /// Opens Terminal to sign in to an OAuth MCP server with Claude Code's or Codex's own flow.
    func signIn(_ c: Connector, with engine: BotEngine) {
        let server = ([c.command ?? ""] + c.args).joined(separator: " ")
        switch engine {
        case .codex:
            let add = c.kind == .http ? "codex mcp add \(c.serverKey) --url '\(c.url ?? "")'" : "codex mcp add \(c.serverKey) -- \(server)"
            perform(.openTerminal(command: "\(add); codex mcp login \(c.serverKey)"))
        default:
            let add = c.kind == .http
                ? "claude mcp add --scope user --transport http \(c.serverKey) '\(c.url ?? "")'"
                : "claude mcp add --scope user \(c.serverKey) -- \(server)"
            perform(.openTerminal(command: "\(add); echo; echo 'Now type /mcp, pick \(c.serverKey) and sign in. Then type /exit.'; claude"))
        }
    }
}
#endif
