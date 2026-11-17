#if os(macOS)
import SwiftUI
import AppKit
import LaunchpadCore

/// Settings › This Mac: Quick Ask, the menu bar icon, keeping the Mac awake and notifications.
struct MacSettingsSection: View {
    @Environment(AppModel.self) private var model
    @AppStorage(MacPrefs.quickAsk) private var quickAsk = true
    @AppStorage(MacPrefs.menuBar) private var menuBar = true
    @AppStorage(MacPrefs.keepAwake) private var keepAwake = true
    @AppStorage(MacPrefs.notify) private var notify = true

    var body: some View {
        Section {
            Toggle(isOn: $quickAsk) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quick Ask with ⌃⌥B")
                    Text("A floating bar to message any bot from any app.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .onChange(of: quickAsk) { _, on in QuickAsk.shared.setEnabled(on) }
            Toggle(isOn: $menuBar) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show in the menu bar")
                    Text("Who's working, recent chats and Stop. With it on, closing the window keeps Launchpad running.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $keepAwake) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep the Mac awake while bots work")
                    Text("The screen can still dim and lock; the Mac just doesn't go to sleep mid-job.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .onChange(of: keepAwake) { _, _ in
                Awake.update(working: false)
                model.workingChanged()
            }
            Toggle(isOn: $notify) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notify me when a bot finishes or needs me")
                    Text(Notifier.available
                         ? "Only while Launchpad is in the background. Reply right from the notification."
                         : "Notifications need the app bundle: build it with scripts/make-app.sh.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .onChange(of: notify) { _, on in if on { Notifier.shared.requestPermission() } }
            if Notifier.available {
                Button("Notification Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        } header: {
            Text("This Mac")
        }
    }
}

/// Settings › Computer use: Cua Driver, the two permissions, and who's using which app.
struct ComputerUseSection: View {
    @Environment(AppModel.self) private var model
    @State private var cu = ComputerUseController.shared

    var body: some View {
        Section {
            LabeledContent("Cua Driver") {
                if let path = cu.driverPath {
                    Label(path, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.success)
                        .textSelection(.enabled)
                } else {
                    HStack {
                        Label("Not installed", systemImage: "xmark.circle.fill").foregroundStyle(Theme.failure)
                        Button("Install in Terminal…") {
                            do { try cu.openInstaller() } catch {
                                model.alertMessage = "Couldn't open Terminal. Run this yourself: \(ComputerUse.installCommand)"
                            }
                        }
                    }
                }
            }
            if cu.driverPath == nil {
                Text("Runs the official installer in Terminal, so you see what it does: \(ComputerUse.installCommand)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            LabeledContent("Accessibility") {
                permission(cu.accessibility) { cu.requestAccessibility() }
            }
            LabeledContent("Screen Recording") {
                permission(cu.screenRecording) { cu.requestScreenRecording() }
            }
            LabeledContent("Driver") {
                HStack {
                    Text(cu.daemonRunning ? "Running" : "Starts when a bot needs it").foregroundStyle(.secondary)
                    if cu.daemonRunning {
                        Button("Stop") { cu.stopDaemon() }
                    }
                }
            }
            if let problem = cu.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            }
            let claims = cu.claims(paths: model.paths)
            if !claims.isEmpty {
                ForEach(claims, id: \.self) { c in
                    Label("\(c.bot) is using \(c.app)\(c.purpose.map { " (\($0))" } ?? "")", systemImage: "cursorarrow.click.2")
                }
            }
            let users = model.bots.filter(\.useComputer)
            LabeledContent("Bots that may use this Mac") {
                Text(users.isEmpty ? "None yet" : users.map(\.name).joined(separator: ", ")).foregroundStyle(.secondary)
            }
            HStack {
                Button("Check Again") { cu.checkAgain() }
                Button("About Cua Driver") { NSWorkspace.shared.open(ComputerUse.projectURL) }
            }
        } header: {
            Text("Computer use")
        } footer: {
            Text("Bots with “Use this Mac” switched on (in the bot's settings, Claude Code bots only) can click and type in your Mac's apps in the background through Cua Driver, without taking your mouse or keyboard. Every action asks you first unless you change the bot's “Use your Mac” permission, and bots claim an app so two never drive the same one. macOS may ask you to restart Launchpad after granting a permission.")
        }
        .onAppear { cu.refresh() }
    }

    @ViewBuilder private func permission(_ granted: Bool, request: @escaping () -> Void) -> some View {
        if granted {
            Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
        } else {
            HStack {
                Label("Not granted", systemImage: "xmark.circle.fill").foregroundStyle(Theme.failure)
                Button("Open System Settings…", action: request)
            }
        }
    }
}

/// In the bot editor: the "Use this Mac" switch, and why it won't work yet if it won't.
struct ComputerUseBotSection: View {
    @Environment(AppModel.self) private var model
    @Binding var bot: Bot
    @State private var cu = ComputerUseController.shared

    var body: some View {
        Section {
            Toggle(isOn: $bot.useComputer) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use this Mac")
                    Text("Click and type in your Mac's apps in the background (computer use). Each action asks you first, as set under Permissions › Use your Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if bot.useComputer {
                let guardActive = model.guardExecutable != nil
                if let blocker = ComputerUse.blocker(for: bot, guardActive: guardActive, driverInstalled: cu.driverPath != nil,
                                                     accessibility: cu.accessibility, screenRecording: cu.screenRecording) {
                    HStack {
                        Label(blocker.message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warning)
                        Spacer()
                        if [ComputerUse.Blocker.noDriver, .noAccessibility, .noScreenRecording, .driverFailed].contains(blocker) {
                            Button("Set Up…") { model.section = .settings }
                        }
                    }
                } else {
                    Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
                }
            }
        } header: {
            Text("Computer use")
        }
        .onAppear { cu.refresh() }
    }
}
#endif
