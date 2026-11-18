#if os(macOS)
import SwiftUI
import AppKit
import LaunchpadCore

// MARK: - Capture panel

/// The panel Create ticket opens: the selected text, who it's for, a note, and then the run's progress and result.
struct TicketPanelView: View {
    @Environment(AppModel.self) private var model
    let draft: TicketPanelState
    let close: () -> Void
    @State private var importing = false
    @State private var showingAll = false

    private var center: TicketCenter { TicketCenter.shared }

    var body: some View {
        let settings = center.settings
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            header(settings)
            if let run = draft.run, run.phase == .working {
                working(run)
            } else if let run = draft.run, case .done(let result, let duplicate) = run.phase {
                done(result, duplicate: duplicate)
            } else {
                form(settings)
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(.regularMaterial)
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.panel)
                GlowBackground().opacity(0.5).clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.line))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
        .padding(30)
        .frame(maxHeight: .infinity, alignment: .top)
        .onExitCommand(perform: close)
    }

    // MARK: Header

    private func header(_ settings: TicketSettings) -> some View {
        HStack(spacing: Theme.Space.s) {
            IconTile(symbol: "ticket", size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("Create ticket").font(Theme.rounded(.title3, weight: .bold)).foregroundStyle(Theme.text)
                Text("Goes to \(settings.projectKey) in Jira").font(.caption).foregroundStyle(Theme.secondary)
            }
            Spacer()
            let skip = settings.approval == .skip
            Label(settings.approval.title, systemImage: skip ? "bolt.fill" : "hand.raised.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(skip ? Theme.warning : Theme.accentText)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(skip ? Theme.warning.opacity(0.15) : Theme.accentSoft))
                .help(settings.approval.detail)
                .accessibilityLabel("Approval: \(settings.approval.title). \(settings.approval.detail)")
        }
    }

    // MARK: Form

    @ViewBuilder private func form(_ settings: TicketSettings) -> some View {
        let request = TicketRequest(selectedText: draft.selection, sourceApp: draft.sourceApp, sourceWindow: draft.sourceWindow,
                                    note: draft.note, assignee: settings.assignee(id: draft.assigneeId))
        let preview = TicketPrompt.prepare(request, settings: settings)
        let problems = center.problems
        @Bindable var draft = draft

        if case .failed(let why)? = draft.run?.phase {
            banner("The ticket wasn't created", why, symbol: "exclamationmark.triangle.fill", tint: Theme.warning)
            Text("Your text and note are still here. Trying again checks Jira for a ticket about the same thing first.")
                .font(.caption).foregroundStyle(Theme.secondary)
        }
        if draft.needsAccessibility {
            banner("Launchpad can't read your selection with the hotkey yet",
                   "Allow Launchpad under Privacy & Security › Accessibility. Right-click › Services › Create ticket with Claude works without it. You can also paste the text below.",
                   symbol: "lock.shield", tint: Theme.warning) {
                Button("Open Accessibility Settings") { SelectionReader.openAccessibilitySettings() }
                    .buttonStyle(SoftButtonStyle()).controlSize(.small)
            }
        }
        ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in
            banner(problem.message, nil, symbol: "exclamationmark.circle.fill", tint: Theme.warning) { fix(problem) }
        }
        if let error = draft.error {
            banner(error, nil, symbol: "exclamationmark.triangle.fill", tint: Theme.warning)
        }

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Selected text").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
                Spacer()
                if let source = sourceLine { Text(source).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1) }
            }
            TextEditor(text: $draft.selection)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(Theme.Space.s)
                .frame(height: 140)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).strokeBorder(Theme.line))
                .overlay(alignment: .topLeading) {
                    if draft.selection.isEmpty {
                        Text("Nothing was selected. Paste or type the text here, or just write a note below.")
                            .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                            .padding(.horizontal, 13).padding(.vertical, 12).allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Selected text")
            warnings(preview)
            if let siteWarning = settings.siteWarning {
                note(siteWarning, symbol: "link.badge.plus")
            }
        }

        HStack(alignment: .top, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Assign to").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
                Picker("Assign to", selection: $draft.assigneeId) {
                    Text("Nobody").tag(String?.none)
                    ForEach(settings.assignees) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
                .fixedSize()
                if settings.assignees.isEmpty {
                    Text("Add people in Settings › Create ticket.").font(.caption).foregroundStyle(Theme.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Note (optional)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
                TextField("Anything the ticket should say that the text doesn't", text: $draft.note, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...3)
                    .padding(.horizontal, Theme.Space.m).padding(.vertical, 8)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).strokeBorder(Theme.line))
            }
        }

        HStack {
            if let bot = center.chosenBot {
                Text("\(bot.emoji) \(bot.name) will draft it")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
            Spacer()
            Button("Cancel", action: close).keyboardShortcut(.cancelAction)
            Button(retrying ? "Try Again" : "File Ticket") { center.file(draft) }
                .buttonStyle(PillButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!problems.isEmpty || (preview.selection.isEmpty && preview.note.isEmpty))
                .help("⌘Return")
        }
    }

    private var retrying: Bool {
        if case .failed? = draft.run?.phase { return true }
        return false
    }

    private var sourceLine: String? {
        [draft.sourceApp, draft.sourceWindow].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    }

    @ViewBuilder private func warnings(_ preview: TicketPreview) -> some View {
        ForEach(Array(preview.warnings.enumerated()), id: \.offset) { _, warning in
            switch warning {
            case .noSelection:
                EmptyView()
            case .truncated(let shown, let of):
                note("Too long: only the first \(shown) of \(of) characters are sent, and the ticket says it's partial.", symbol: "scissors")
            case .looksSensitive:
                note("This looks like it holds a password, key or card number. Anything you send ends up in Jira, so remove it first.",
                     symbol: "exclamationmark.triangle.fill", tint: Theme.warning)
            }
        }
    }

    private func note(_ text: String, symbol: String, tint: Color = Theme.secondary) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func banner<Action: View>(_ title: String, _ detail: String?, symbol: String, tint: Color,
                                      @ViewBuilder action: () -> Action = { EmptyView() }) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail { Text(detail).font(.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: Theme.Space.s)
            action()
        }
        .padding(Theme.Space.m)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
    }

    /// The button beside a problem: sign in to Jira, import the skill, or fix the project key.
    @ViewBuilder private func fix(_ problem: TicketProblem) -> some View {
        switch problem {
        case .jiraNotConnected:
            Button("Open Apps") {
                model.section = .connectors
                MainWindow.bringForward()
                close()
            }
            .buttonStyle(SoftButtonStyle()).controlSize(.small)
        case .skillMissing:
            Button(importing ? "Importing…" : "Import Skill") { importSkill() }
                .buttonStyle(SoftButtonStyle()).controlSize(.small).disabled(importing)
        case .badProjectKey:
            Button("Open Settings") {
                model.section = .settings
                MainWindow.bringForward()
                close()
            }
            .buttonStyle(SoftButtonStyle()).controlSize(.small)
        }
    }

    private func importSkill() {
        importing = true
        draft.error = nil
        do {
            try model.skillStore.ensureTicketSkill(settings: center.settings)
            model.reloadSkills()
        } catch {
            draft.error = error.localizedDescription
        }
        importing = false
    }

    // MARK: Working

    @ViewBuilder private func working(_ run: TicketRun) -> some View {
        let replies = model.replies(after: run.messageId, in: run.chatId)
        let cards = replies.flatMap { $0.liveApprovals ?? [] }
        let bot = model.bot(run.botId)
        HStack(spacing: Theme.Space.s) {
            ProgressView().controlSize(.small)
            Text(cards.contains { $0.state == .pending } ? "\(bot?.name ?? "The bot") is waiting for your OK"
                                                         : WorkSummary.line(for: replies.last))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
        }
        ForEach(cards) { card in
            LiveApprovalCardView(card: card, chatId: run.chatId, botId: run.botId)
        }
        HStack {
            Text("Drafting with \(run.settings.skillId), filing in \(run.settings.projectKey).")
                .font(.caption).foregroundStyle(Theme.secondary)
            Spacer()
            Button("Open Chat") {
                model.show(chat: run.chatId)
                MainWindow.bringForward()
                close()
            }
            .buttonStyle(SoftButtonStyle()).controlSize(.small)
            Button("Hide", action: close).controlSize(.small).keyboardShortcut(.cancelAction)
        }
    }

    // MARK: Done

    @ViewBuilder private func done(_ result: TicketResult, duplicate: Bool) -> some View {
        if result.siteConfirmed {
            confirmedDone(result, duplicate: duplicate)
        } else {
            unconfirmedDone(result, duplicate: duplicate)
        }
    }

    /// No Jira site is set, so the link could be on anyone's atlassian.net site: show it, don't copy or open it, and
    /// let you say "yes, that's mine" once.
    @ViewBuilder private func unconfirmedDone(_ result: TicketResult, duplicate: Bool) -> some View {
        let host = result.site ?? "that site"
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: "questionmark.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 4) {
                Text(duplicate ? "\(result.key) may already cover this" : "\(result.key) was reported filed")
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text)
                Text("The link is on \(host). Your Jira site isn't set, and anyone can make an atlassian.net site, so Launchpad hasn't copied or opened the link. If \(host) is your Jira site, confirm it.")
                    .font(.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        HStack {
            Spacer()
            Button("Close", action: close).keyboardShortcut(.cancelAction)
            Button("\(host) is my Jira site") { confirmSite(of: result, duplicate: duplicate) }
                .buttonStyle(PillButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.small)
    }

    private func confirmSite(of result: TicketResult, duplicate: Bool) {
        center.update { $0 = $0.confirmingSite(of: result) }
        draft.run?.phase = .done(result.confirmed(), duplicate: duplicate)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.url.absoluteString, forType: .string)
    }

    @ViewBuilder private func confirmedDone(_ result: TicketResult, duplicate: Bool) -> some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.success)
            VStack(alignment: .leading, spacing: 2) {
                Text(duplicate ? "\(result.key) already covers this" : "Created \(result.key)")
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text)
                Text(result.url.absoluteString).font(.caption).foregroundStyle(Theme.secondary).textSelection(.enabled).lineLimit(1)
            }
        }
        Text("The link is on your clipboard.").font(.caption).foregroundStyle(Theme.secondary)
        HStack {
            Spacer()
            Button("Close", action: close).keyboardShortcut(.cancelAction)
            Button("Copy Link Again") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.url.absoluteString, forType: .string)
            }
            Button("Open Ticket") {
                NSWorkspace.shared.open(result.url)
                close()
            }
            .buttonStyle(PillButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .controlSize(.small)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Settings

/// Settings › Create ticket: the hotkey, who tickets go to, which skill writes them and whether they need your OK.
struct TicketSettingsSection: View {
    @Environment(AppModel.self) private var model
    @AppStorage(TicketCenter.enabledKey) private var hotkeyOn = true
    @AppStorage(TicketCenter.letterKey) private var letter = TicketHotkey.defaultLetter
    @AppStorage(TicketCenter.botKey) private var botId = ""
    @State private var rows: [Row] = []
    @State private var loaded = false
    @State private var trusted = AXIsProcessTrusted()
    @State private var message: String?

    struct Row: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var jira: String
    }

    private var center: TicketCenter { TicketCenter.shared }

    var body: some View {
        let settings = center.settings
        Section {
            Toggle(isOn: $hotkeyOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Create ticket with \(TicketHotkey.label(for: letter))")
                    Text("Select text in any app and press the hotkey. Right-click › Services › Create ticket with Claude works too, once Launchpad is in Applications.")
                        .font(.caption).foregroundStyle(Theme.secondary)
                }
            }
            .onChange(of: hotkeyOn) { _, _ in center.registerHotKey() }
            Picker("Hotkey", selection: $letter) {
                ForEach(TicketHotkey.letters, id: \.self) { Text(TicketHotkey.modifiers + $0).tag($0) }
            }
            .disabled(!hotkeyOn)
            .onChange(of: letter) { _, _ in center.registerHotKey() }
            LabeledContent("Reading the selection") {
                HStack(spacing: Theme.Space.s) {
                    Text(trusted ? "Allowed" : "Not allowed yet")
                        .foregroundStyle(trusted ? Theme.success : Theme.warning)
                    if !trusted {
                        Button("Open Accessibility Settings") { SelectionReader.openAccessibilitySettings() }
                        Button("Check Again") { trusted = AXIsProcessTrusted() }
                    }
                }
            }
            if !trusted {
                Text("Without Accessibility the hotkey can't read what you've selected, so the panel opens empty. The right-click Service doesn't need it.")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }

            TextField("Jira project", text: Binding(
                get: { settings.projectKey },
                set: { v in center.update { $0.projectKey = v.uppercased().trimmingCharacters(in: .whitespaces) } }
            ), prompt: Text(TicketSettings.defaultProjectKey))
            if !TicketSettings.validProjectKey(settings.projectKey) {
                Text(TicketProblem.badProjectKey(settings.projectKey).message).font(.caption).foregroundStyle(Theme.warning)
            }
            TextField("Jira site", text: Binding(
                get: { settings.siteHost ?? "" },
                set: { v in center.update { $0.siteHost = TicketSettings.cleanHost(v) ?? (v.isEmpty ? nil : $0.siteHost) } }
            ), prompt: Text("your-site.atlassian.net"))
            Text("Recommended. Only a link on this site counts as a created ticket. Until it's set, Launchpad won't copy or open ticket links.")
                .font(.caption).foregroundStyle(settings.siteHost == nil ? Theme.warning : Theme.secondary)

            Picker("Bot", selection: $botId) {
                Text("Automatic").tag("")
                ForEach(center.candidateBots) { Text("\($0.emoji) \($0.name)").tag($0.id) }
            }
            if center.candidateBots.isEmpty {
                Text("No bot can file tickets yet. Turn on Jira & Confluence for a Claude bot in Apps and sign in there.")
                    .font(.caption).foregroundStyle(Theme.warning)
                Button("Open Apps") { model.section = .connectors }
            }

            Picker("Skill", selection: Binding(
                get: { settings.skillId },
                set: { v in center.update { $0.skillId = v } }
            )) {
                ForEach(skillChoices(settings), id: \.self) { Text($0).tag($0) }
            }
            HStack {
                if model.skill(settings.skillId) == nil {
                    Text("\"\(settings.skillId)\" isn't in your skills library yet.").font(.caption).foregroundStyle(Theme.warning)
                    Button("Import from this Mac") { importSkill(settings) }
                } else {
                    Text("Found in your skills library.").font(.caption).foregroundStyle(Theme.secondary)
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(Theme.warning) }

            Picker("Approval", selection: Binding(
                get: { settings.approval },
                set: { v in center.update { $0.approval = v } }
            )) {
                ForEach(TicketApproval.allCases) { Text($0.title).tag($0) }
            }
            Text(settings.approval.detail)
                .font(.caption)
                .foregroundStyle(settings.approval == .skip ? Theme.warning : Theme.secondary)

            Stepper(value: Binding(
                get: { settings.maxSelectionCharacters },
                set: { v in center.update { $0.maxSelectionCharacters = v } }
            ), in: TicketSettings.selectionLimits, step: 1_000) {
                Text("Longest selection: \(settings.maxSelectionCharacters) characters")
            }

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("People tickets can be assigned to")
                ForEach($rows) { $row in
                    HStack {
                        TextField("Name", text: $row.name).frame(maxWidth: 160)
                        TextField("Jira name or email", text: $row.jira)
                        Button { rows.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                            .help("Remove \(row.name)")
                            .accessibilityLabel("Remove \(row.name)")
                    }
                }
                Button("Add Person") { rows.append(Row(name: "", jira: "")) }
                Text("The bot looks the account up from the Jira name or email. If it finds none, or two, the ticket is left unassigned and it tells you.")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
        } header: {
            Text("Create ticket")
        } footer: {
            Text("The settings are kept in Launchpad's protected data folder, so a bot can't change the approval mode.")
        }
        .onAppear {
            trusted = AXIsProcessTrusted()
            if !loaded {
                rows = center.settings.assignees.map { Row(name: $0.name, jira: $0.jira) }
                loaded = true
            }
        }
        .onChange(of: rows) { _, new in
            var seen = Set<String>()
            let people = new.map { TicketAssignee(name: $0.name, jira: $0.jira) }.filter { $0.isValid && seen.insert($0.id).inserted }
            if people != center.settings.assignees { center.update { $0.assignees = people } }
        }
    }

    /// The library's skills, and the chosen one even if it isn't in the library yet.
    private func skillChoices(_ settings: TicketSettings) -> [String] {
        var ids = model.skills.map(\.id)
        if !ids.contains(settings.skillId) { ids.insert(settings.skillId, at: 0) }
        return ids
    }

    private func importSkill(_ settings: TicketSettings) {
        message = nil
        do {
            try model.skillStore.ensureTicketSkill(settings: settings)
            model.reloadSkills()
        } catch {
            message = error.localizedDescription
        }
    }
}
#endif
