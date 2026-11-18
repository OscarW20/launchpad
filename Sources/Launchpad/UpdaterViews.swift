#if os(macOS)
import SwiftUI
import AppKit
import LaunchpadCore

/// The in-app updater: checks whether GitHub's `main` is ahead of this build (`UpdateCheck`), and runs
/// `scripts/update.sh` in the checkout the app was built from, following its log (`UpdateLog`).
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    /// How often to look for updates while the app is open.
    static let interval: TimeInterval = 3 * 60 * 60

    /// The last answer worth showing (a quiet check that couldn't reach GitHub doesn't replace it).
    private(set) var status: UpdateStatus?
    private(set) var checking = false
    private(set) var lastChecked: Date?
    /// The current step of an update that's running ("Building Launchpad 0.1.0 (48)"); nil when none is.
    private(set) var progress: String?
    /// Why the last update failed, and the end of its build output.
    private(set) var failure: (reason: String, detail: String)?
    /// The update finished but this copy is still open (it isn't the installed one).
    private(set) var finished: String?
    /// Bots are working: "Update now and stop them, or wait?"
    var confirming = false
    private var started = false

    private let stamp = BuildStamp(info: Bundle.main.infoDictionary)

    var isUpdating: Bool { progress != nil }

    /// This copy is the one in Applications that `make-app.sh --install` replaces (not a development build).
    private var isInstalledCopy: Bool {
        let app = Bundle.main.bundleURL.standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").standardizedFileURL
        return app.lastPathComponent == "Launchpad.app"
            && ["/Applications", home.path].contains(app.deletingLastPathComponent().path)
    }

    /// The toolbar's Update button shows when this build is behind, while an update runs, and after one ends.
    var showsButton: Bool {
        isUpdating || failure != nil || finished != nil || status?.isAvailable == true
    }

    /// A quiet check now, every few hours, and whenever you come back to Launchpad (at most every few minutes).
    func start() {
        guard !started else { return }
        started = true
        Task { [weak self] in
            while !Task.isCancelled {
                self?.check(quiet: true)
                try? await Task.sleep(nanoseconds: UInt64(Self.interval * 1_000_000_000))
            }
        }
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                guard let self else { return }
                if UpdateCheck.isDue(lastChecked: self.lastChecked) { self.check(quiet: true) }
            }
        }
    }

    /// - Parameter quiet: true for the checks nobody asked for: a failure then shows nothing and keeps the last answer.
    func check(quiet: Bool) {
        guard !checking, !isUpdating else { return }
        checking = true
        let stamp = stamp
        Task {
            let result = await Task.detached(priority: .utility) { UpdateCheck().check(stamp: stamp) }.value
            checking = false
            lastChecked = Date()
            if case .cantCheck = result, quiet { return }
            status = result
        }
    }

    /// Clears a failed or finished update's message (the button goes back to "Update", or away).
    func clearResult() {
        failure = nil
        finished = nil
    }

    /// Update Now in Settings: asks first when bots are working.
    func requestUpdate(model: AppModel) {
        guard !isUpdating else { return }
        if model.anyoneWorking { confirming = true } else { update() }
    }

    /// Starts `scripts/update.sh` on its own (it outlives this app, which it replaces) and follows its log.
    func update() {
        guard !isUpdating else { return }
        failure = nil
        finished = nil
        guard let stamp, FileManager.default.fileExists(atPath: stamp.updateScript.path) else {
            failure = ("Launchpad can't find the code it was built from, so it can't update itself. Run scripts/update.sh in Terminal once.", "")
            return
        }
        let log = UpdateLog.defaultURL
        // So an earlier update's "Done" isn't read as this one's.
        try? FileManager.default.removeItem(at: log)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [stamp.updateScript.path]
        p.currentDirectoryURL = stamp.source
        // Not a pipe: the script must be able to keep writing after this app has quit.
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        // Launched from the Finder the app has a bare PATH; Homebrew's git and gh may be needed by the scripts.
        env["PATH"] = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin") + ":/opt/homebrew/bin:/usr/local/bin"
        p.environment = env
        do { try p.run() } catch {
            failure = ("Couldn't start the update: \(error.localizedDescription)", "")
            return
        }
        progress = "Starting…"
        Task { await follow(log: log, process: p) }
    }

    private func follow(log: URL, process: Process) async {
        while isUpdating {
            try? await Task.sleep(nanoseconds: 700_000_000)
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            switch UpdateLog.state(of: text) {
            case .running(let step):
                progress = step
                // The installer is waiting for the installed app: if that's this one, quit now rather than after
                // its polite request times out.
                if step == UpdateLog.quitStep, isInstalledCopy { NSApp.terminate(nil) }
                if !process.isRunning, UpdateLog.state(of: (try? String(contentsOf: log, encoding: .utf8)) ?? "") == .running(step) {
                    // The script was ended from outside, so it never wrote how it finished.
                    progress = nil
                    failure = ("The update stopped unexpectedly at \"\(step)\".", UpdateLog.detail(of: text))
                }
            case .done(let message):
                // Still here: this copy isn't the installed one (a development build, or a copy elsewhere).
                progress = nil
                status = .upToDate
                finished = message
            case .failed(let reason):
                progress = nil
                failure = (reason.prefix(1).uppercased() + reason.dropFirst(), UpdateLog.detail(of: text))
            case nil:
                // It ended without writing a word, e.g. another update already holds the lock.
                if !process.isRunning {
                    progress = nil
                    failure = ("The update stopped before it began. Another update may already be running; try again in a minute.", "")
                }
            }
        }
    }
}

// MARK: - Toolbar button

/// The Update button in the main window's top right corner. It appears by itself when GitHub's `main` is ahead
/// of this build, shows progress while an update runs, and turns into a warning if one fails. Hidden otherwise.
struct UpdateToolbarButton: View {
    @Environment(AppModel.self) private var model
    @State private var showing = false

    var body: some View {
        let updater = Updater.shared
        if updater.showsButton {
            Button { showing.toggle() } label: { label(updater) }
                .buttonStyle(PillButtonStyle(kind: updater.failure == nil ? .primary : .plain))
                .controlSize(.small)
                .fixedSize()
                .help(help(updater))
                .accessibilityLabel(help(updater))
                .popover(isPresented: $showing, arrowEdge: .bottom) {
                    UpdatePopover { showing = false }
                        .environment(model)
                }
        }
    }

    @ViewBuilder private func label(_ updater: Updater) -> some View {
        if updater.isUpdating {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).tint(.white)
                Text("Updating…")
            }
        } else if updater.failure != nil {
            Label("Update Failed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
        } else if updater.finished != nil {
            Label("Updated", systemImage: "checkmark.circle.fill")
        } else if case .available(let count, _) = updater.status {
            HStack(spacing: 6) {
                Label("Update", systemImage: "arrow.down.circle.fill")
                Text("\(count)")
                    .font(.system(size: 11, weight: .bold))
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.25)))
            }
        }
    }

    private func help(_ updater: Updater) -> String {
        if let step = updater.progress { return "Updating Launchpad: \(step)" }
        if updater.failure != nil { return "The last update didn't finish. Click to see why" }
        if updater.finished != nil { return "Launchpad was updated. Quit and reopen it to use the new version" }
        if case .available(let count, _) = updater.status {
            return count == 1 ? "1 update available. Click to see what's new" : "\(count) updates available. Click to see what's new"
        }
        return "Update Launchpad"
    }
}

/// What the Update button opens: what's new with Update Now, the update's progress, or why it failed.
struct UpdatePopover: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void
    @State private var showingDetail = false
    /// Bots are working: the question is asked here, in the popover, rather than in a dialog over it.
    @State private var confirming = false

    var body: some View {
        let updater = Updater.shared
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if confirming, !updater.isUpdating {
                title("Bots are working")
                Text("Updating restarts Launchpad, which stops whatever your bots are doing. Update now and stop them, or wait until they've finished?")
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Wait") { confirming = false }
                        .buttonStyle(PillButtonStyle(kind: .plain))
                        .keyboardShortcut(.cancelAction)
                    Button("Update Now and Stop Them") {
                        confirming = false
                        model.stopEveryone()
                        updater.update()
                    }
                    .buttonStyle(PillButtonStyle(kind: .destructive))
                }
                .controlSize(.small)
            } else if let step = updater.progress {
                title("Updating Launchpad")
                HStack(spacing: Theme.Space.s) {
                    ProgressView().controlSize(.small)
                    Text(step).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                }
                Text("This takes a minute or two. Launchpad quits and reopens by itself when it's done.")
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let failure = updater.failure {
                title("The update didn't finish")
                Text("You're still on the version you had. \(failure.reason)")
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if showingDetail, !failure.detail.isEmpty {
                    ScrollView {
                        Text(failure.detail)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Theme.Space.s)
                    }
                    .frame(height: 180)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                }
                HStack {
                    if !failure.detail.isEmpty {
                        Button(showingDetail ? "Hide Details" : "Show Details") { showingDetail.toggle() }
                            .buttonStyle(SoftButtonStyle())
                    }
                    Spacer()
                    Button("Dismiss") { updater.clearResult(); close() }
                        .buttonStyle(PillButtonStyle(kind: .plain))
                    Button("Try Again") { start(updater) }
                        .buttonStyle(PillButtonStyle())
                }
                .controlSize(.small)
            } else if let finished = updater.finished {
                title("Launchpad was updated")
                Text("\(finished). Quit and reopen Launchpad to use it.")
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("OK") { updater.clearResult(); close() }
                        .buttonStyle(PillButtonStyle(kind: .plain))
                        .controlSize(.small)
                }
            } else if case .available(let count, let subjects) = updater.status {
                title(count == 1 ? "1 update available" : "\(count) updates available")
                if !subjects.isEmpty {
                    ScrollView {
                        WhatsNewList(count: count, subjects: subjects)
                    }
                    .frame(maxHeight: 280)
                }
                HStack {
                    Text("Takes a minute or two, then Launchpad reopens.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                    Spacer()
                    Button("Update Now") { start(updater) }
                        .buttonStyle(PillButtonStyle())
                        .controlSize(.small)
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                // The check came back up to date while this was open.
                title("Launchpad is up to date")
            }
        }
        .font(.system(size: 13))
        .padding(Theme.Space.l)
        .frame(width: 400, alignment: .leading)
    }

    /// Starts the update, asking first when bots are working.
    private func start(_ updater: Updater) {
        if model.anyoneWorking { confirming = true } else { updater.update() }
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
    }
}

/// What an update brings: one line per commit, newest first.
struct WhatsNewList: View {
    let count: Int
    let subjects: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(subjects.enumerated()), id: \.offset) { _, subject in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•").foregroundStyle(Theme.secondary)
                    Text(subject).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                }
            }
            if count > subjects.count {
                Text("and \(count - subjects.count) more").foregroundStyle(Theme.secondary)
            }
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Settings

/// The rows under Version in Settings: where things stand, Check for Updates, and Update Now with what's new.
struct UpdateSettingsRows: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let updater = Updater.shared
        LabeledContent("Updates") {
            HStack(spacing: Theme.Space.s) {
                if updater.checking || updater.isUpdating { ProgressView().controlSize(.small) }
                Text(line(updater))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if case .available(let count, let subjects) = updater.status, !updater.isUpdating {
            WhatsNewList(count: count, subjects: subjects)
        }
        HStack {
            Button("Check for Updates") { updater.check(quiet: false) }
                .disabled(updater.checking || updater.isUpdating)
            if updater.status?.isAvailable == true {
                Button("Update Now") { updater.requestUpdate(model: model) }
                    .disabled(updater.isUpdating)
            }
        }
    }

    private func line(_ updater: Updater) -> String {
        if let step = updater.progress { return "Updating: \(step)" }
        if let failure = updater.failure { return "The last update didn't finish. \(failure.reason)" }
        if updater.checking { return "Checking…" }
        guard let status = updater.status else {
            return updater.lastChecked == nil ? "Not checked yet" : "Couldn't check just now"
        }
        guard let checked = updater.lastChecked, !status.isAvailable else { return status.summary }
        if case .cantCheck = status { return status.summary }
        return "\(status.summary) · checked \(checked.formatted(date: .omitted, time: .shortened))"
    }
}

extension View {
    /// "Update now and stop them, or wait?", asked when Update Now in Settings is pressed while bots are working.
    /// (The toolbar button's popover asks the same thing inline.)
    func updateConfirmation(model: AppModel) -> some View {
        let updater = Updater.shared
        return confirmationDialog(
            "Bots are working",
            isPresented: Binding(get: { updater.confirming }, set: { updater.confirming = $0 })
        ) {
            Button("Update Now and Stop Them", role: .destructive) {
                model.stopEveryone()
                updater.update()
            }
            Button("Wait", role: .cancel) {}
        } message: {
            Text("Updating restarts Launchpad, which stops whatever your bots are doing. Update now and stop them, or wait until they've finished?")
        }
    }
}
#endif
