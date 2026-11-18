#if os(macOS)
import SwiftUI
import AppKit
import LaunchpadCore

// MARK: - Live approval card

/// A card the permission guard raised while a reply runs: the bot's tool call waits for your answer.
/// The category and tool are shown big, because the details come from a file the bot could have written.
struct LiveApprovalCardView: View {
    @Environment(AppModel.self) private var model
    let card: LiveApproval
    let chatId: String
    let botId: String?

    var body: some View {
        let kind = card.kind
        let name = model.bot(botId)?.name ?? "This bot"
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: kind?.symbol ?? "hand.raised.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.warning)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Theme.warning.opacity(0.14)))
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(name) wants to \(kind?.wants ?? "do something that needs your OK")")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    HStack(spacing: 6) {
                        Text(kind?.title ?? card.category)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.accentText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Theme.accentSoft, in: Capsule())
                        Text(ToolNames.readable(card.tool))
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Theme.secondary)
                    }
                    if let why = modeLine {
                        Text(why)
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                    }
                }
            }
            if !card.detail.isEmpty {
                ScrollView {
                    Text(card.detail)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, 10)
                .background(Theme.code, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            }
            state
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.l)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(card.state == .pending ? Theme.accent.opacity(0.45) : Theme.line, lineWidth: card.state == .pending ? 1.5 : 1))
    }

    /// Which mode this chat is in, so a card that still appears says why: a group's mode, or that one-to-one chats always ask.
    private var modeLine: String? {
        guard let chat = model.chat(chatId) else { return nil }
        if chat.kind == .group { return "Group mode: \(model.approvalMode(for: chat.groupId).title)" }
        return "One-to-one chats always ask"
    }

    @ViewBuilder private var state: some View {
        switch card.state {
        case .pending:
            HStack(spacing: 10) {
                Button {
                    model.answerApproval(card.id, in: chatId, .approve)
                } label: {
                    Label("Approve", systemImage: "checkmark")
                }
                .buttonStyle(PillButtonStyle())
                .controlSize(.large)
                Button {
                    model.answerApproval(card.id, in: chatId, .deny)
                } label: {
                    Label("Decline", systemImage: "xmark")
                }
                .buttonStyle(SoftButtonStyle())
                .controlSize(.large)
                if model.canAlwaysAllow(card, botId: botId) {
                    Button("Always allow") { model.answerApproval(card.id, in: chatId, .always) }
                        .buttonStyle(SoftButtonStyle())
                        .controlSize(.large)
                        .help("Approve, and let \(model.bot(botId)?.name ?? "this bot") use \(ToolNames.readable(card.tool)) for this without asking again. You can take it back in the bot's settings.")
                }
            }
        case .approved:
            Label("Approved", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.success)
                .font(.callout.weight(.medium))
        case .always:
            Label("Approved, and always allowed from now on", systemImage: "checkmark.seal.fill")
                .foregroundStyle(Theme.success)
                .font(.callout.weight(.medium))
        case .denied:
            Label("Declined", systemImage: "xmark.circle.fill")
                .foregroundStyle(Theme.secondary)
                .font(.callout.weight(.medium))
        case .expired:
            Label("Nobody answered in time, so it didn't go ahead", systemImage: "clock.badge.xmark")
                .foregroundStyle(Theme.secondary)
                .font(.callout.weight(.medium))
        }
    }
}

// MARK: - Undo a reply

/// "Changed 3 files · Undo" under a reply.
struct ReplyChangesBar: View {
    @Environment(AppModel.self) private var model
    let message: ChatMessage
    let chatId: String
    @State private var confirm = false

    var body: some View {
        let files = message.changedFiles ?? []
        HStack(spacing: 10) {
            Image(systemName: message.undone == true ? "arrow.uturn.backward.circle" : "doc.badge.ellipsis")
                .foregroundStyle(Theme.secondary)
            Text(message.undone == true
                 ? "Undone: \(files.count) file change\(files.count == 1 ? "" : "s") put back"
                 : "Changed \(files.count) file\(files.count == 1 ? "" : "s") in its folder")
                .font(.callout)
                .foregroundStyle(Theme.secondary)
            Spacer()
            if message.undone != true {
                Button {
                    confirm = true
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(SoftButtonStyle())
                .controlSize(.small)
                .disabled(model.isRunning(chatId) || model.snapshots == nil)
                .help(model.snapshots == nil ? "Undo needs git, which Launchpad couldn't find." : "Put these files back as they were before this reply")
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 6)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .confirmationDialog("Undo this reply's changes?", isPresented: $confirm) {
            Button("Undo Changes", role: .destructive) { model.undoReply(message.id, in: chatId) }
        } message: {
            Text("These files go back to how they were before the reply (new ones are removed). Changes made to them since are undone too.\n\n"
                 + files.prefix(12).joined(separator: "\n")
                 + (files.count > 12 ? "\n… and \(files.count - 12) more" : ""))
        }
    }
}

// MARK: - Bot editor: permissions

/// Ask / Allow / Never per category, the Always-allowed list, and your own "change" commands.
struct PermissionsSection: View {
    @Binding var bot: Bot
    /// Always-allows removed in this edit (so saving doesn't bring them back from the stored copy).
    @Binding var removedAlways: Set<String>
    @State private var newPattern = ""

    var body: some View {
        Section {
            ForEach(ApprovalCategory.allCases) { category in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: category.symbol)
                        .foregroundStyle(Theme.accent)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.title)
                        Text(category.detail)
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Picker(category.title, selection: Binding(
                        get: { bot.rules.rule(category) },
                        set: { bot.rules.set($0, for: category) }
                    )) {
                        ForEach(ApprovalRule.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text(bot.engine == .claude
                 ? "Ask: \(bot.name.isEmpty ? "the bot" : bot.name) waits while you Approve or Decline a card in the chat. Never: it's told no, every time."
                 : "Codex has no way to pause for a card, so these go into its instructions and its sandbox is set to match.")
        }

        Section {
            if bot.rules.alwaysAllowed.isEmpty {
                Text("Nothing yet. Pick “Always allow” on an approval card to add one.")
                    .foregroundStyle(Theme.secondary)
            }
            ForEach(bot.rules.alwaysAllowed, id: \.self) { key in
                let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
                let category = ApprovalCategory(rawValue: parts.first ?? "")
                HStack {
                    Image(systemName: category?.symbol ?? "checkmark.seal")
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ToolNames.readable(parts.count > 1 ? parts[1] : key))
                        Text(category?.title ?? (parts.first ?? ""))
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    Button {
                        bot.rules.alwaysAllowed.removeAll { $0 == key }
                        removedAlways.insert(key)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Ask again next time")
                }
            }
        } header: {
            Text("Always allowed")
        } footer: {
            Text("Tools you said this bot may always use for that kind of action. Never applies to the Terminal: one command says nothing about the next.")
        }

        Section {
            ForEach(Array(bot.rules.changePatterns.enumerated()), id: \.offset) { index, pattern in
                HStack {
                    Text(pattern)
                        .font(.system(.body, design: .monospaced))
                    if !GuardEngine.invalidPatterns([pattern]).isEmpty {
                        Label("Not a valid pattern", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.warning)
                    }
                    Spacer()
                    Button {
                        bot.rules.changePatterns.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("Add a command", text: $newPattern, prompt: Text("e.g. \\bkubectl\\s+apply\\b"))
                    .font(.system(.body, design: .monospaced))
                Button("Add") {
                    let p = newPattern.trimmingCharacters(in: .whitespaces)
                    if !p.isEmpty, !bot.rules.changePatterns.contains(p) { bot.rules.changePatterns.append(p) }
                    newPattern = ""
                }
                .disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            let bad = GuardEngine.invalidPatterns([newPattern.trimmingCharacters(in: .whitespaces)].filter { !$0.isEmpty })
            if !bad.isEmpty {
                Text("That isn't a valid regular expression yet.")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
            }
        } header: {
            Text("Your own “change” commands")
        } footer: {
            Text("Terminal commands matching these (regular expressions, any case) count as “Change code or shared systems”, e.g. your company's deploy tool.")
        }
    }
}

/// Lock-down: no internet except the listed sites, no opening other apps.
struct LockDownSection: View {
    @Environment(AppModel.self) private var model
    @Binding var bot: Bot
    @State private var newSite = ""

    var body: some View {
        Section {
            Toggle(isOn: $bot.lockedDown) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lock down")
                    Text("Only the websites below, no opening or scripting other apps, no startup files, and no “Always allow” for sends, deletes, spending or changes.")
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if bot.lockedDown {
                if !BotSandbox.available {
                    Label("This Mac has no sandbox-exec, so a locked-down bot won't run.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                }
                ForEach(bot.sites, id: \.self) { site in
                    HStack {
                        Image(systemName: "globe").foregroundStyle(Theme.secondary)
                        Text(site)
                        Spacer()
                        Button {
                            bot.sites.removeAll { $0 == site }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Add a website", text: $newSite, prompt: Text("e.g. github.com"))
                        .onSubmit(addSite)
                    Button("Add", action: addSite)
                        .disabled(cleaned(newSite).isEmpty)
                }
                let automatic = Set(BotSandbox.engineSites(bot.engine)
                    + BotSandbox.connectorSites(MCPConfig.effective(for: bot, groups: model.groups, all: model.connectors)))
                    .subtracting(bot.sites).sorted()
                if !automatic.isEmpty {
                    LabeledContent("Added for it") {
                        Text(automatic.joined(separator: ", "))
                            .foregroundStyle(Theme.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    .help("Its engine's and its connectors' own sites, so it can still work.")
                }
            }
        } header: {
            Text("Lock-down")
        } footer: {
            if bot.lockedDown {
                Text("“github.com” also allows its subdomains, like api.github.com.")
            }
        }
    }

    private func cleaned(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if let url = URL(string: t), let host = url.host, t.contains("://") { t = host }
        return t.trimmingCharacters(in: CharacterSet(charactersIn: "/. "))
    }

    private func addSite() {
        let site = cleaned(newSite)
        if !site.isEmpty, !bot.sites.contains(site) { bot.sites.append(site) }
        newSite = ""
    }
}

// MARK: - Skill lock

struct SkillLockToggle: View {
    @Environment(AppModel.self) private var model
    let skillId: String

    var body: some View {
        Toggle(isOn: Binding(
            get: { model.lockedSkills.contains(skillId) },
            set: { model.setSkillLocked(skillId, $0) }
        )) {
            Label(model.lockedSkills.contains(skillId) ? "Locked" : "Lock", systemImage: model.lockedSkills.contains(skillId) ? "lock.fill" : "lock.open")
        }
        .toggleStyle(.button)
        .help("Locked skills can't be changed by any bot. You can still edit them here.")
    }
}
#endif
