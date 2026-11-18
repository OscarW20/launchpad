#if os(macOS)
import SwiftUI
import AppKit
import LaunchpadCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                LabeledContent("Folder") {
                    Text(model.paths.root.path)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                Button("Show in Finder") { SystemActions.reveal(model.paths.root) }
            } header: {
                Text("Launchpad folder")
            } footer: {
                Text("Bots, groups, skills and chats are plain files here. Edit them by hand or with any agent; the app picks up changes live. Set LAUNCHPAD_HOME to use a different folder.")
            }

            ForEach(BotEngine.allCases.filter(\.isAgent)) { engine in
                Section(engine.displayName) {
                    LabeledContent("Status") {
                        if let found = model.engineLocations {
                            if let path = found[engine] {
                                Label(path, systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(Theme.success)
                                    .textSelection(.enabled)
                            } else {
                                Label("Not installed", systemImage: "xmark.circle.fill")
                                    .foregroundStyle(Theme.failure)
                            }
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    LabeledContent("Plan") { Text(engine.planName) }
                    HStack {
                        Button("Sign in…") { model.perform(.openTerminal(command: engine.signInCommand)) }
                        Button("Install guide") { NSWorkspace.shared.open(engine.installURL) }
                    }
                }
            }

            Section {
                LabeledContent("Ollama") {
                    if let found = model.engineLocations {
                        if let path = found[.local] {
                            Label(path, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(Theme.success)
                                .textSelection(.enabled)
                        } else {
                            Text("Not found (optional)").foregroundStyle(Theme.secondary)
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                LabeledContent("Default address") {
                    Text(LocalModel.defaultBaseURL).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                KeychainField(title: "API key", account: LocalModelKey.account,
                            prompt: "Only if your server asks for one")
                HStack {
                    Button("Start Ollama") { model.perform(.openTerminal(command: BotEngine.local.signInCommand)) }
                        .disabled(model.engineLocations?[.local] == nil)
                    Button("Get Ollama") { NSWorkspace.shared.open(BotEngine.local.installURL) }
                }
            } header: {
                Text(BotEngine.local.displayName)
            } footer: {
                Text("Bots on a local model talk to Ollama, LM Studio or any OpenAI-compatible server on your Mac. They chat only: no tools or files. Pick the address per bot.")
            }

            Section {
                Picker("Plan cards", selection: Binding(get: { model.planWait }, set: { model.planWait = $0 })) {
                    ForEach(PlanWait.options.map { $0.seconds }, id: \.self) { seconds in
                        Text(PlanWait.title(seconds)).tag(seconds)
                    }
                }
                KeychainField(title: "GIPHY API key", account: GiphySearch.keyAccount, prompt: "For GIFs (free at developers.giphy.com)")
            } header: {
                Text("Chat")
            } footer: {
                Text("Before a long task, a bot shares its plan with Start and Cancel. Pick whether it waits for you or starts by itself. GIFs need a GIPHY key, kept in your Keychain.")
            }

            Section {
                Picker(selection: Binding(get: { model.botModel }, set: { model.botModel = $0 })) {
                    Text("Sonnet (recommended)").tag("sonnet")
                    Text("Haiku (cheapest)").tag("haiku")
                    Text("Opus").tag("opus")
                    Text("Claude Code's default (top model, uses the most)").tag("")
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Model for bots")
                        Text("For bots that don't pick their own model in the bot editor.")
                            .font(.caption).foregroundStyle(Theme.secondary)
                    }
                }
                Picker(selection: Binding(get: { model.botEffort }, set: { model.botEffort = $0 })) {
                    Text("Low").tag("low")
                    Text("Medium (recommended)").tag("medium")
                    Text("High").tag("high")
                    Text("Very high").tag("xhigh")
                    Text("Max").tag("max")
                    Text("Engine's own default").tag("")
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Thinking effort")
                        Text("How hard bots think before answering, unless a bot picks its own in the bot editor. Higher uses more of your plan.")
                            .font(.caption).foregroundStyle(Theme.secondary)
                    }
                }
                Toggle(isOn: Binding(get: { !model.leanRuns }, set: { model.leanRuns = !$0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bots use my personal Claude Code setup")
                        Text("Off (recommended): bots skip your own Claude Code plugins, hooks and settings and get only the tools they need. A turn costs about 9k prompt tokens instead of about 44k, and the prompt cache isn't reset every run.")
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                    }
                }
            } header: {
                Text("Token use")
            } footer: {
                Text("Biggest savings: give simple bots a cheaper model (e.g. sonnet or haiku) in the bot editor, only turn on the apps a bot needs, keep hand-off limits low, and use Compact on long chats.")
            }

            TeamNotesSection()

            MacSettingsSection()

            ComputerUseSection()

            Section {
                LabeledContent("Approval guard") {
                    if let url = model.guardExecutable {
                        Label("Active", systemImage: "checkmark.shield.fill")
                            .foregroundStyle(Theme.success)
                            .help(url.path)
                    } else {
                        Label("Missing: build with scripts/make-app.sh", systemImage: "exclamationmark.shield")
                            .foregroundStyle(Theme.warning)
                    }
                }
                Toggle(isOn: Binding(get: { model.alwaysForWrites }, set: { model.alwaysForWrites = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("“Always allow” for sends, deletes, spending and changes")
                        Text("Off: bots ask every time for these, even where you picked Always allow before.")
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                    }
                }
                LabeledContent("Sandbox") {
                    if BotSandbox.available {
                        Label("On", systemImage: "checkmark.shield.fill").foregroundStyle(Theme.success)
                    } else {
                        Label("Not available on this Mac", systemImage: "exclamationmark.shield").foregroundStyle(Theme.warning)
                    }
                }
                LabeledContent("Undo for replies") {
                    if model.snapshots != nil {
                        Label("On", systemImage: "arrow.uturn.backward.circle.fill").foregroundStyle(Theme.success)
                    } else {
                        Label("Needs git", systemImage: "exclamationmark.circle").foregroundStyle(Theme.warning)
                    }
                }
            } header: {
                Text("Safety")
            } footer: {
                Text("Claude Code bots wait for your Approve on a card before they send, delete, spend or change shared systems (set this per bot under Permissions). Codex bots are told the same and kept in their sandbox. Bots can't touch Launchpad's own files or your Claude settings.")
            }

            PhoneSettingsSection()   // Phone link hook (PhoneSettingsView.swift)

            Section {
                LabeledContent("Version") {
                    Text(AppVersion.label(info: Bundle.main.infoDictionary))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                UpdateSettingsRows()
                Button("Check again") { model.refreshEngines() }
            }
        }
        .themedForm()
        .columnHeader("Settings") { EmptyView() }
        .navigationTitle("Settings")
    }
}

/// A secret kept in your Keychain: shows whether it's set, and lets you save or remove it. Never shows the value.
struct KeychainField: View {
    @Environment(AppModel.self) private var model
    let title: String
    let account: String
    var prompt = ""
    @State private var value = ""
    @State private var isSet = false

    var body: some View {
        LabeledContent(title) {
            if isSet {
                HStack {
                    Label("Saved in your Keychain", systemImage: "key.fill").foregroundStyle(Theme.success)
                    Button("Remove") {
                        model.setSecret(nil, for: account)
                        isSet = model.hasSecret(account)
                    }
                }
            } else {
                HStack {
                    SecureField("", text: $value, prompt: Text(prompt))
                        .frame(maxWidth: 260)
                    Button("Save") {
                        model.setSecret(value.trimmingCharacters(in: .whitespacesAndNewlines), for: account)
                        value = ""
                        isSet = model.hasSecret(account)
                    }
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear { isSet = model.hasSecret(account) }
    }
}

/// Shared/TEAM.md: one page every bot reads.
struct TeamNotesSection: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var saved = ""

    var body: some View {
        Section {
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 180)
            HStack {
                Button("Save") {
                    model.saveTeamNotes(text)
                    saved = text
                }
                .disabled(text == saved)
                Button("Revert") { text = saved }
                    .disabled(text == saved)
                Spacer()
                Button("Open in Editor") { SystemActions.open(model.paths.teamNotes) }
            }
        } header: {
            Text("Team notes")
        } footer: {
            Text("~/Launchpad/Shared/TEAM.md. Every bot reads it before it starts and adds decisions the team should know. Bots can also ask a teammate for help in a 1:1 chat.")
        }
        .onAppear {
            text = model.teamNotesText()
            saved = text
        }
    }
}

enum SystemActions {
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Opens a Terminal window that runs `command` in your login shell.
    /// Uses a .command file, so no automation permission is needed.
    static func openTerminal(running command: String) throws {
        let script = """
        #!/bin/zsh -l
        clear
        echo "Launchpad: running \\"\(command)\\""
        echo
        \(command)
        echo
        echo "All done? You can close this window and go back to Launchpad."
        exec $SHELL -l
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchpad-\(UUID().uuidString.prefix(8)).command")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)

        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        if FileManager.default.fileExists(atPath: terminal.path) {
            NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
#endif
