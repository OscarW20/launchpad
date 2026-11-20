#if os(macOS)
import SwiftUI
import LaunchpadCore

// "Spawn a group from chat": a bot proposes up to three team setups in a `team-proposal` block at the end of its reply
// (`TeamProposalParser`, LaunchpadCore). The app turns the block into this card. Nothing is created until you tap Launch,
// which calls `WorkspaceStore.launch`.

/// What launching a card made, for the line the card shows afterwards.
struct TeamLaunchRecord: Equatable {
    var groupId: String
    var missingConnectors: [String] = []
    var unknownSkills: [String] = []
    var renamed = false
}

@MainActor
@Observable
final class TeamLaunchCenter {
    static let shared = TeamLaunchCenter()
    private static let key = "launchedTeams"

    /// Message id to the group it launched. Remembered across launches of the app (the group id is enough to say "Open").
    private(set) var launched: [String: TeamLaunchRecord] = [:]

    init() {
        let saved = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        launched = saved.mapValues { TeamLaunchRecord(groupId: $0) }
    }

    func record(_ r: TeamLaunchRecord, for messageId: String) {
        launched[messageId] = r
        var saved = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        saved[messageId] = r.groupId
        UserDefaults.standard.set(saved, forKey: Self.key)
    }
}

enum TeamText {
    /// A finished bot message with a team proposal block in it.
    static func hasProposal(_ message: ChatMessage, live: Bool) -> Bool {
        !live && message.role == .bot && message.text.contains("```team-proposal")
    }
}

struct ProposedTeamCard: View {
    @Environment(AppModel.self) private var model
    let message: ChatMessage
    let chatId: String

    @State private var selected = 0
    @State private var tweaking = false
    @State private var name = ""
    @State private var removed = Set<String>()
    @State private var problem: String?

    var body: some View {
        let result = Result { try TeamProposalParser.parse(message.text) }
        switch result {
        case .failure(let error):
            Label("Couldn't use that team proposal: \(error.localizedDescription)", systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
        case .success(let proposal):
            card(proposal)
        }
    }

    @ViewBuilder private func card(_ proposal: TeamProposal) -> some View {
        let center = WorkspaceCenter.shared
        let chat = model.chat(chatId)
        let workspace = chat.flatMap { center.workspace(center.id(for: $0)) } ?? center.current
        let index = min(selected, proposal.options.count - 1)
        let base = proposal.options[index]
        let launched = TeamLaunchCenter.shared.launched[message.id]
        let option = tweaked(base)
        let installed = Set(model.connectors.map(\.id))
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "person.3.fill")
                Text("PROPOSED TEAM").font(.system(size: 12, weight: .heavy))
                Spacer()
                Text("in \(workspace.name)").font(.caption)
            }
            .foregroundStyle(Theme.accentText)
            if !proposal.goal.isEmpty {
                Text(proposal.goal).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            }
            if proposal.options.count > 1 {
                Picker("Setup", selection: Binding(get: { index }, set: { selected = $0; tweaking = false; removed = []; name = "" })) {
                    ForEach(Array(proposal.options.enumerated()), id: \.offset) { i, o in Text(o.label).tag(i) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            HStack(spacing: 8) {
                Text(option.emoji.isEmpty ? "👥" : option.emoji).font(.system(size: 22))
                VStack(alignment: .leading, spacing: 0) {
                    Text(option.name).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                    Text("\(option.members.count) bot\(option.members.count == 1 ? "" : "s")").font(.caption).foregroundStyle(Theme.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(option.members, id: \.key) { m in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(m.name).font(.system(size: 13, weight: .semibold))
                        if m.key == option.lead { RoleTag(text: "Lead") }
                        if !m.role.isEmpty { Text(m.role).font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true) }
                        Spacer(minLength: 0)
                        if tweaking, m.key != option.lead {
                            Button { removed.insert(m.key) } label: { Image(systemName: "minus.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(Theme.secondary).help("Take \(m.name) out").accessibilityLabel("Remove \(m.name)")
                        }
                    }
                }
            }
            if !option.skills.isEmpty {
                Label("Skills on: \(option.skills.joined(separator: ", "))", systemImage: "sparkles").font(.caption).foregroundStyle(Theme.secondary)
            }
            ForEach(option.connectors, id: \.self) { c in
                if installed.contains(c) {
                    Label("\(c): ready", systemImage: "checkmark.circle").font(.caption).foregroundStyle(Theme.success)
                } else {
                    Label("Add \(c) in Apps first", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(Theme.warning)
                }
            }
            if !option.notes.isEmpty { Text(option.notes).font(.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true) }
            ForEach(proposal.dropped, id: \.self) { why in
                Label("Left out: \(why)", systemImage: "minus.circle").font(.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Label("Starts in Ask me. The team asks you before posting, sending or publishing anything.", systemImage: "hand.raised")
                .font(.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            if tweaking {
                TextField("Group name", text: Binding(get: { name.isEmpty ? base.name : name }, set: { name = $0 }))
                    .textFieldStyle(.roundedBorder)
            }
            if let problem { Text(problem).font(.callout).foregroundStyle(Theme.warning) }
            if let launched, let group = model.group(launched.groupId) {
                HStack {
                    Label("Launched as \(group.displayName)", systemImage: "checkmark.circle.fill").font(.callout.weight(.semibold)).foregroundStyle(Theme.success)
                    Spacer()
                    Button("Open") { model.openChat(with: group) }.buttonStyle(PillButtonStyle()).controlSize(.small)
                }
                if !launched.missingConnectors.isEmpty {
                    Text("Add \(launched.missingConnectors.joined(separator: ", ")) in Apps before the team can use it.").font(.caption).foregroundStyle(Theme.warning)
                }
                if !launched.unknownSkills.isEmpty {
                    Text("Not in your library, so not switched on: \(launched.unknownSkills.joined(separator: ", ")).").font(.caption).foregroundStyle(Theme.secondary)
                }
            } else {
                HStack {
                    Button("Launch") { launch(option, goal: proposal.goal) }.buttonStyle(PillButtonStyle())
                    Button(tweaking ? "Done tweaking" : "Tweak") { tweaking.toggle() }.buttonStyle(SoftButtonStyle())
                }
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).strokeBorder(Theme.accent.opacity(0.4)))
        .accessibilityElement(children: .contain)
    }

    /// The option with your tweaks: a new group name, and the members you took out (never the lead).
    private func tweaked(_ base: TeamOption) -> TeamOption {
        var o = base
        let newName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !newName.isEmpty { o.name = newName }
        o.members.removeAll { removed.contains($0.key) && $0.key != base.lead }
        return o
    }

    private func launch(_ option: TeamOption, goal: String) {
        problem = nil
        if let error = WorkspaceCenter.shared.launchTeam(option, goal: goal, from: chatId, messageId: message.id) { problem = error }
    }
}
#endif
