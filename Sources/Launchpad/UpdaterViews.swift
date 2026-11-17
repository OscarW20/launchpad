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
    /// The status the banner's Later button hid; a different one (more commits) shows it again.
    private var dismissed: UpdateStatus?
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

    /// What the main window's banner shows, if anything.
    var showsBanner: Bool {
        if isUpdating || failure != nil || finished != nil { return true }
        guard let status, status.isAvailable else { return false }
        return status != dismissed
    }

    /// A quiet check now and every few hours.
    func start() {
        guard !started else { return }
        started = true
        Task { [weak self] in
            while !Task.isCancelled {
                self?.check(quiet: true)
                try? await Task.sleep(nanoseconds: UInt64(Self.interval * 1_000_000_000))
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
            if !quiet { dismissed = nil }
        }
    }

    func later() {
        dismissed = status
        failure = nil
        finished = nil
    }

    /// The Update button: asks first when bots are working.
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

// MARK: - Main window banner

/// "3 updates available" across the top of the main window, with What's New, Update and Later; then the update's
/// progress, or why it failed. Nothing at all when there's nothing to say.
struct UpdateBanner: View {
    @Environment(AppModel.self) private var model
    @State private var showingNew = false
    @State private var showingDetail = false

    var body: some View {
        let updater = Updater.shared
        if updater.showsBanner {
            HStack(spacing: Theme.Space.m) {
                content(updater)
            }
            .font(.system(size: 13))
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line))
            .padding(.horizontal, Theme.Space.m)
            .padding(.bottom, Theme.Space.s)
        }
    }

    @ViewBuilder private func content(_ updater: Updater) -> some View {
        if let step = updater.progress {
            ProgressView().controlSize(.small)
            Text("Updating Launchpad: \(step)").foregroundStyle(Theme.text).lineLimit(1)
            Spacer()
            Text("Launchpad reopens by itself when it's done.").foregroundStyle(Theme.secondary).lineLimit(1)
        } else if let failure = updater.failure {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            Text("The update didn't finish, so you're still on the version you had. \(failure.reason)")
                .foregroundStyle(Theme.text)
                .lineLimit(2)
            Spacer()
            if !failure.detail.isEmpty {
                Button("Show Details") { showingDetail = true }
                    .buttonStyle(SoftButtonStyle())
                    .controlSize(.small)
                    .popover(isPresented: $showingDetail, arrowEdge: .bottom) {
                        ScrollView {
                            Text(failure.detail)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(Theme.Space.l)
                        }
                        .frame(width: 560, height: 260)
                    }
            }
            Button("Try Again") { updater.requestUpdate(model: model) }
                .buttonStyle(PillButtonStyle())
                .controlSize(.small)
            Button("Dismiss") { updater.later() }
                .buttonStyle(PillButtonStyle(kind: .plain))
                .controlSize(.small)
        } else if let finished = updater.finished {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
            Text("\(finished). Quit and reopen Launchpad to use it.").foregroundStyle(Theme.text).lineLimit(1)
            Spacer()
            Button("Dismiss") { updater.later() }
                .buttonStyle(PillButtonStyle(kind: .plain))
                .controlSize(.small)
        } else if case .available(let count, let subjects) = updater.status {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent)
            Text(count == 1 ? "1 update available" : "\(count) updates available")
                .fontWeight(.semibold)
                .foregroundStyle(Theme.text)
                .fixedSize()
            if let newest = subjects.first {
                Text(newest).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer()
            if !subjects.isEmpty {
                Button("What's New") { showingNew = true }
                    .buttonStyle(SoftButtonStyle())
                    .controlSize(.small)
                    .popover(isPresented: $showingNew, arrowEdge: .bottom) {
                        ScrollView {
                            WhatsNewList(count: count, subjects: subjects).padding(Theme.Space.l)
                        }
                        .frame(width: 420)
                        .frame(maxHeight: 360)
                    }
            }
            Button("Update") { updater.requestUpdate(model: model) }
                .buttonStyle(PillButtonStyle())
                .controlSize(.small)
                .help("Gets the latest code, rebuilds Launchpad and reopens it. Takes a minute or two.")
            Button("Later") { updater.later() }
                .buttonStyle(PillButtonStyle(kind: .plain))
                .controlSize(.small)
        }
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
    /// "Update now and stop them, or wait?", asked when the Update button is pressed while bots are working.
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
