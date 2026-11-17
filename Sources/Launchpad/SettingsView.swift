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

            ForEach(BotEngine.allCases) { engine in
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
                Button("Check again") { model.refreshEngines() }
            }
        }
        .formStyle(.grouped)
        .background(Theme.canvas)
        .navigationTitle("Settings")
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
