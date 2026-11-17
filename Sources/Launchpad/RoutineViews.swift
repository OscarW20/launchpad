#if os(macOS)
import SwiftUI
import AppKit
import LaunchpadCore

// MARK: - List

struct RoutineListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        PanelList(selection: $model.selectedRoutineId) {
            ForEach(model.routines) { r in
                HStack(spacing: 10) {
                    Image(systemName: RoutineListView.icon(r))
                        .foregroundStyle(r.enabled ? Theme.accent : .secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.name).font(Theme.rounded(.body, weight: .semibold))
                        Text("\(r.summary) → \(model.targetName(r.target))")
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                        if r.missedPending != nil {
                            Label("Missed \(r.missedCount ?? 1) run\((r.missedCount ?? 1) == 1 ? "" : "s")", systemImage: "exclamationmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(Theme.warning)
                        } else if model.unavailableFolders.contains(r.id) {
                            Label("Folder not found", systemImage: "folder.badge.questionmark")
                                .font(.caption)
                                .foregroundStyle(Theme.warning)
                        } else if r.isWebhook, r.enabled, model.webhookStatus != nil {
                            Label("Not listening", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(Theme.warning)
                        }
                    }
                    Spacer()
                    if !r.enabled { Text("Off").font(.caption).foregroundStyle(Theme.secondary) }
                }
                .padding(.vertical, 3)
                .selectableRow(r.id)
            }
        }
        .navigationTitle("Routines")
        .columnHeader("Routines") {
            Button { model.newRoutine() } label: { Label("New Routine", systemImage: "plus") }
                .help("Create a routine")
        }
    }

    static func icon(_ r: Routine) -> String {
        switch r.trigger {
        case .newFile: return "tray.and.arrow.down"
        case .webhook: return "link"
        case .once: return "calendar.badge.clock"
        default: return "clock"
        }
    }
}

// MARK: - Editor

struct RoutineDetailView: View {
    enum TriggerKind: String, CaseIterable, Identifiable {
        case daily = "Every day at…"
        case weekly = "Every week on…"
        case hourly = "Every hour at…"
        case every = "Every few minutes or hours"
        case once = "Once, at…"
        case newFile = "When a file appears"
        case webhook = "When its web address is called"
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
                    if let stored = model.routines.first(where: { $0.id == routineId }), let missed = stored.missedPending {
                        Section {
                            MissedRunsBanner(routine: stored, last: missed)
                        }
                    }
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
                        triggerFields(r.trigger)
                        if r.isClock {
                            if r.enabled, let next = RoutineSchedule.nextSlot(of: r, after: Date()) {
                                LabeledContent("Next run", value: next.formatted(date: .abbreviated, time: .shortened))
                            }
                            if !isEvery(r.trigger) {
                                Toggle("If missed while closed, run once when you're back", isOn: Binding(
                                    get: { r.catchesUp }, set: { draft?.catchUp = $0 }
                                ))
                            }
                        }
                    } header: {
                        Text("When")
                    } footer: {
                        Text(footer(r))
                    }
                    if r.isWebhook {
                        WebhookSection(routineId: routineId, saved: model.routines.contains { $0.id == routineId && $0.isWebhook })
                    }
                    Section {
                        Toggle(isOn: Binding(get: { r.runsInOwnChat }, set: { draft?.ownChat = $0 })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Each run in its own chat")
                                Text("Keeps the newest \(RoutineRuns.kept) run chats; older ones are deleted.")
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondary)
                            }
                        }
                    } header: {
                        Text("Where it posts")
                    }
                    Section {
                        if let last = r.lastRun {
                            LabeledContent("Last ran", value: last.formatted(date: .abbreviated, time: .shortened))
                        }
                        HStack {
                            Button("Run Now") { model.runRoutineNow(routineId) }
                            if let chatId = r.lastRunChat ?? r.chatId, model.chat(chatId) != nil {
                                Button("Open Chat") { model.show(chat: chatId) }
                            }
                            Spacer()
                            Button("Delete Routine", role: .destructive) { model.deleteRoutine(routineId) }
                        }
                    }
                }
                .themedForm()
            } else {
                ContentUnavailableView("Routine not found", systemImage: "questionmark.circle")
            }
        }
        .navigationTitle(draft?.name ?? "Routine")
        .toolbar {
            ToolbarItem {
                Button("Save") {
                    if let d = draft { model.saveEditedRoutine(d); load() }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(draft == original)
            }
        }
        .onAppear(perform: load)
        .onChange(of: model.routines) {
            // A run changed its bookkeeping: pick that up if you haven't edited anything.
            if draft == original { load() }
        }
    }

    private func footer(_ r: Routine) -> String {
        switch r.trigger {
        case .newFile:
            return "Runs once a file has finished arriving (downloads included), at most once a minute. The new files are passed along. Runs while Launchpad is open."
        case .webhook:
            return "Runs when another app or script on this Mac calls its address with the secret. Only this Mac can reach it."
        case .once:
            return "Switches itself off after it runs. If Launchpad was closed at that time, it runs once when you're back."
        default:
            return "Routines run while Launchpad is open."
        }
    }

    @ViewBuilder private func triggerFields(_ t: Routine.Trigger) -> some View {
        switch t {
        case let .daily(hour, minute, weekdays):
            DatePicker("Time", selection: Binding(
                get: { time(hour, minute) },
                set: { d in
                    let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                    draft?.trigger = .daily(hour: c.hour ?? 9, minute: c.minute ?? 0, weekdaysOnly: weekdays)
                }
            ), displayedComponents: .hourAndMinute)
            Toggle("Weekdays only", isOn: Binding(get: { weekdays }, set: { draft?.trigger = .daily(hour: hour, minute: minute, weekdaysOnly: $0) }))
        case let .weekly(weekday, hour, minute):
            Picker("Day", selection: Binding(get: { weekday }, set: { draft?.trigger = .weekly(weekday: $0, hour: hour, minute: minute) })) {
                ForEach(1...7, id: \.self) { d in Text(Calendar.current.weekdaySymbols[d - 1]).tag(d) }
            }
            DatePicker("Time", selection: Binding(
                get: { time(hour, minute) },
                set: { d in
                    let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                    draft?.trigger = .weekly(weekday: weekday, hour: c.hour ?? 9, minute: c.minute ?? 0)
                }
            ), displayedComponents: .hourAndMinute)
        case .hourly(let minute):
            Picker("Minutes past the hour", selection: Binding(get: { minute }, set: { draft?.trigger = .hourly(minute: $0) })) {
                ForEach([0, 5, 10, 15, 20, 30, 40, 45, 50], id: \.self) { m in Text(String(format: ":%02d", m)).tag(m) }
                if ![0, 5, 10, 15, 20, 30, 40, 45, 50].contains(minute) { Text(String(format: ":%02d", minute)).tag(minute) }
            }
        case .every(let minutes):
            Picker("Every", selection: Binding(get: { minutes }, set: { draft?.trigger = .every(minutes: $0) })) {
                Text("15 minutes").tag(15)
                Text("30 minutes").tag(30)
                Text("hour").tag(60)
                Text("2 hours").tag(120)
                Text("4 hours").tag(240)
                Text("day").tag(1440)
                if ![15, 30, 60, 120, 240, 1440].contains(minutes) { Text("\(minutes) minutes").tag(minutes) }
            }
        case .once(let at):
            DatePicker("At", selection: Binding(get: { at }, set: { draft?.trigger = .once(at: $0) }),
                       displayedComponents: [.date, .hourAndMinute])
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
            if model.unavailableFolders.contains(routineId) {
                Label("That folder isn't there right now (moved, renamed or on a disk that isn't connected).", systemImage: "folder.badge.questionmark")
                    .foregroundStyle(Theme.warning)
            }
        case .webhook:
            EmptyView()
        }
    }

    private func isEvery(_ t: Routine.Trigger) -> Bool {
        if case .every = t { return true }
        return false
    }

    private func time(_ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }

    private func load() {
        draft = model.routines.first { $0.id == routineId }
        original = draft
    }

    private func kind(_ t: Routine.Trigger) -> TriggerKind {
        switch t {
        case .daily: return .daily
        case .weekly: return .weekly
        case .hourly: return .hourly
        case .every: return .every
        case .once: return .once
        case .newFile: return .newFile
        case .webhook: return .webhook
        }
    }

    private func defaultTrigger(_ k: TriggerKind) -> Routine.Trigger {
        if let t = draft?.trigger, k == kind(t) { return t }
        switch k {
        case .daily: return .daily(hour: 9, minute: 0, weekdaysOnly: true)
        case .weekly: return .weekly(weekday: 2, hour: 9, minute: 0)
        case .hourly: return .hourly(minute: 0)
        case .every: return .every(minutes: 60)
        case .once:
            let inAnHour = Date().addingTimeInterval(3600)
            let rounded = Date(timeIntervalSince1970: (inAnHour.timeIntervalSince1970 / 300).rounded() * 300)
            return .once(at: rounded)
        case .newFile: return .newFile(folder: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path)
        case .webhook: return .webhook
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

/// "Missed 3 runs (last at 09:00)" with Run now / Skip.
struct MissedRunsBanner: View {
    @Environment(AppModel.self) private var model
    let routine: Routine
    let last: Date

    var body: some View {
        let n = routine.missedCount ?? 1
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 6) {
                Text(n > 1 ? "Missed \(n) runs (the last at \(last.formatted(date: .abbreviated, time: .shortened)))"
                           : "Missed the run at \(last.formatted(date: .abbreviated, time: .shortened))")
                    .font(.callout.weight(.medium))
                Text("Your Mac was asleep or Launchpad was closed.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                HStack {
                    Button("Run Now") { model.runRoutineNow(routine.id) }
                        .buttonStyle(PillButtonStyle())
                    Button("Skip") { model.skipMissed(routine.id) }
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}

/// The routine's web address, its secret and a curl example.
struct WebhookSection: View {
    @Environment(AppModel.self) private var model
    let routineId: String
    /// Saved as a web address routine (the address works only once it's saved and on).
    let saved: Bool
    @State private var token: String?
    @State private var tried = false
    @State private var showSecret = false
    @State private var confirmNew = false

    var body: some View {
        Section {
            if let status = model.webhookStatus {
                Label(status, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
            }
            LabeledContent("Address") {
                HStack {
                    Text(WebhookAuth.address(for: routineId))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                    CopyButton(text: WebhookAuth.address(for: routineId))
                }
            }
            if let token {
                LabeledContent("Secret") {
                    HStack {
                        Text(showSecret ? token : String(repeating: "•", count: 16))
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button(showSecret ? "Hide" : "Show") { showSecret.toggle() }
                            .controlSize(.small)
                        CopyButton(text: token)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Try it from Terminal")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.secondary)
                        Spacer()
                        CopyButton(text: WebhookAuth.curl(for: routineId, token: token))
                    }
                    Text(WebhookAuth.curl(for: routineId, token: showSecret ? token : "YOUR_SECRET"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.code, in: RoundedRectangle(cornerRadius: 8))
                }
                Button("New Secret…") { confirmNew = true }
            } else if tried {
                Label("Your Keychain didn't hand over this routine's secret.", systemImage: "lock.trianglebadge.exclamationmark")
                    .foregroundStyle(Theme.warning)
                Button("Try Again") { load() }
            }
        } header: {
            Text("Web address")
        } footer: {
            Text(saved
                 ? "Send a POST with the secret as “Authorization: Bearer …”. What you send is passed to the bot as information, not instructions. The secret stays in your Keychain."
                 : "Save the routine to start using its address.")
        }
        .onAppear(perform: load)
        .confirmationDialog("Make a new secret?", isPresented: $confirmNew) {
            Button("New Secret", role: .destructive) { token = model.newWebhookSecret(routineId) ?? token }
        } message: {
            Text("Anything using the old secret stops working.")
        }
    }

    private func load() {
        token = model.webhookToken(routineId)
        tried = true
    }
}

struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("Copy")
    }
}
#endif
