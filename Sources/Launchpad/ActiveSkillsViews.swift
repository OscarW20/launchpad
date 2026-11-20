#if os(macOS)
import SwiftUI
import LaunchpadCore

// Always-on skills: switch several skills on for a chat (or a whole group) so every bot applies them to what it builds,
// without typing /skill each time. `ActiveSkillsStore` (LaunchpadCore) keeps the set in the protected data folder and puts
// the list into each run's instructions; this is the app's side: the button, the checklist and the chips.

@MainActor
@Observable
final class ActiveSkillsCenter {
    static let shared = ActiveSkillsCenter()

    private(set) var snapshot = ActiveSkillSet()
    private var store: ActiveSkillsStore?
    private weak var model: AppModel?

    func install(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        store = ActiveSkillsStore(paths: model.paths)
        reload()
    }

    func reload() {
        if let store { snapshot = store.load() }
    }

    /// What's on for a chat: its group's skills, then its own.
    func active(for chat: ChatMeta) -> [String] {
        guard let store else { return [] }
        return store.active(for: chat, in: snapshot)
    }

    func onForChat(_ chatId: String) -> [String] { snapshot.chats[chatId] ?? [] }
    func onForGroup(_ groupId: String?) -> [String] { groupId.flatMap { snapshot.groups[$0] } ?? [] }

    /// Switches one skill. Returns the error text to show, or nil.
    func set(_ skillId: String, on: Bool, scope: ActiveSkillScope, chat: ChatMeta?) -> String? {
        guard let store else { return "Launchpad isn't ready yet." }
        defer { reload() }
        do { _ = try store.set(skillId, on: on, scope: scope, chat: chat); return nil } catch { return error.localizedDescription }
    }

    /// About how many tokens the active list adds to every message.
    func tokens(for chat: ChatMeta) -> Int {
        guard let model else { return 0 }
        return ActiveSkillsPrompt.estimate(ids: active(for: chat), library: model.skills, paths: model.paths)
    }
}

/// "Skills · 2" beside the + in the composer.
struct ActiveSkillsButton: View {
    @Environment(AppModel.self) private var model
    let chatId: String
    @State private var showing = false

    var body: some View {
        let count = model.chat(chatId).map { ActiveSkillsCenter.shared.active(for: $0).count } ?? 0
        Button { showing.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: count > 0 ? "sparkles" : "sparkle")
                Text(count > 0 ? "Skills · \(count)" : "Skills")
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(count > 0 ? Theme.accentText : Theme.secondary)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(count > 0 ? Theme.accentSoft : Theme.field, in: Capsule())
            .overlay(Capsule().strokeBorder(count > 0 ? Theme.accent.opacity(0.5) : Theme.line))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(count > 0 ? "\(count) skill\(count == 1 ? "" : "s") on: the bots apply them to everything they build here" : "Switch skills on so the bots apply them to everything they build, without typing /skill")
        .accessibilityLabel(count > 0 ? "Apply skills, \(count) on" : "Apply skills")
        .popover(isPresented: $showing, arrowEdge: .top) { ActiveSkillsPopover(chatId: chatId) }
    }
}

struct ActiveSkillsPopover: View {
    @Environment(AppModel.self) private var model
    let chatId: String
    @State private var search = ""
    @State private var wholeGroup = false
    @State private var problem: String?
    @State private var found: String?

    private var center: ActiveSkillsCenter { ActiveSkillsCenter.shared }
    private var chat: ChatMeta? { model.chat(chatId) }
    private var isGroup: Bool { chat?.kind == .group }
    private var groupId: String? { chat?.groupId }

    var body: some View {
        let chatOn = Set(center.onForChat(chatId))
        let groupOn = Set(center.onForGroup(groupId))
        let skills = DesignSkills.ordered(model.skills).filter { matches($0) }
        let tokens = chat.map { center.tokens(for: $0) } ?? 0
        let count = chatOn.union(groupOn).count
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Apply skills").font(Theme.rounded(.headline, weight: .bold))
            Text("Switched on, the bots apply these to anything they build here. No need to type /skill.")
                .font(.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            SearchField(text: $search, prompt: "Search skills")
            if isGroup {
                Toggle(isOn: $wholeGroup) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Apply to the whole group").font(.system(size: 13, weight: .medium))
                        Text(wholeGroup ? "Switches below apply to every chat of this group." : "Switches below apply to this chat only.")
                            .font(.caption).foregroundStyle(Theme.secondary)
                    }
                }
            }
            if skills.isEmpty {
                Text(model.skills.isEmpty ? "Your skill library is empty." : "No skills match.").foregroundStyle(Theme.secondary).padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(skills) { skill in row(skill, chatOn: chatOn.contains(skill.id), groupOn: groupOn.contains(skill.id)) }
                    }
                }
                .frame(maxHeight: 320)
            }
            if let problem { Text(problem).font(.callout).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true) }
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text(count == 0 ? "Nothing on" : "\(count) on, adds about \(tokens) tokens to every message")
                    .font(.caption).foregroundStyle(count > 3 ? Theme.warning : Theme.secondary)
                Spacer()
                Text("Up to \(ActiveSkillsStore.maxActive)").font(.caption).foregroundStyle(Theme.secondary)
            }
            if count > 3 {
                Text("More skills on means more instructions every time. A handful is plenty.").font(.caption).foregroundStyle(Theme.warning)
            }
            if DesignSkills.ids.contains(where: { id in !model.skills.contains { $0.id == id } }) {
                Button("Add design skills from this Mac") { importDesign() }
                    .buttonStyle(SoftButtonStyle()).controlSize(.small)
            }
            if let found { Text(found).font(.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(Theme.Space.l)
        .frame(width: 380)
    }

    private func matches(_ skill: Skill) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || skill.name.lowercased().contains(q) || skill.description.lowercased().contains(q)
    }

    private func row(_ skill: Skill, chatOn: Bool, groupOn: Bool) -> some View {
        let on = chatOn || groupOn
        return Toggle(isOn: Binding(get: { on }, set: { toggle(skill, to: $0, chatOn: chatOn, groupOn: groupOn) })) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(skill.name).font(.system(size: 13, weight: .semibold))
                    if DesignSkills.ids.contains(skill.id) { RoleTag(text: "Design") }
                    if groupOn { RoleTag(text: "Whole group") }
                }
                if !skill.description.isEmpty {
                    Text(skill.description).font(.caption).foregroundStyle(Theme.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func toggle(_ skill: Skill, to on: Bool, chatOn: Bool, groupOn: Bool) {
        problem = nil
        guard let chat else { return }
        if on {
            let scope: ActiveSkillScope = (isGroup && wholeGroup && groupId != nil) ? .group(groupId!) : .chat(chatId)
            problem = center.set(skill.id, on: true, scope: scope, chat: chat)
        } else {
            if chatOn { problem = center.set(skill.id, on: false, scope: .chat(chatId), chat: chat) }
            if groupOn, let g = groupId { problem = center.set(skill.id, on: false, scope: .group(g), chat: chat) ?? problem }
        }
    }

    private func importDesign() {
        let report = DesignSkills.importAvailable(into: model.skillStore)
        model.reloadSkills()
        found = report.summary
    }
}

/// Small chips above the message box for the skills that are on; the x switches one off.
struct ActiveSkillChips: View {
    @Environment(AppModel.self) private var model
    let chatId: String

    var body: some View {
        let center = ActiveSkillsCenter.shared
        let chat = model.chat(chatId)
        let chatOn = center.onForChat(chatId)
        let groupOn = center.onForGroup(chat?.groupId)
        let all = chat.map { center.active(for: $0) } ?? []
        if !all.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(all, id: \.self) { id in
                        let name = model.skills.first { $0.id == id }?.name ?? id
                        let group = groupOn.contains(id)
                        HStack(spacing: 4) {
                            Image(systemName: group ? "person.3.fill" : "sparkles")
                            Text(name).lineLimit(1)
                            Button {
                                if chatOn.contains(id) { _ = center.set(id, on: false, scope: .chat(chatId), chat: chat) }
                                if group, let g = chat?.groupId { _ = center.set(id, on: false, scope: .group(g), chat: chat) }
                            } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(Theme.secondary)
                                .help(group ? "Switch off for the whole group" : "Switch off")
                                .accessibilityLabel("Switch off \(name)")
                        }
                        .font(.callout)
                        .foregroundStyle(Theme.accentText)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Theme.accentSoft, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.35)))
                        .help(group ? "\(name): on for the whole group" : "\(name): on for this chat")
                    }
                }
            }
        }
    }
}
#endif
