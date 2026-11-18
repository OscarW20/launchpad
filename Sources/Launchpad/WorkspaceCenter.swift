#if os(macOS)
import SwiftUI
import AppKit
import LaunchpadCore

// Workspaces keep one area of work apart (Biscuit, Launchpad, a personal app): each bot and group is in exactly one, and
// the app shows only the current workspace's. Which workspace each is in lives in `WorkspaceStore` (LaunchpadCore), in
// the protected data folder. This is the app's side: the current workspace, what's shown, and the move, duplicate and
// delete flows.

/// A thing the Move or Duplicate sheet is asking about.
struct WorkspaceMove: Identifiable {
    enum Kind { case group(BotGroup), bot(Bot), duplicate(Bot), duplicateGroup(BotGroup) }
    let kind: Kind
    let destination: Workspace
    var id: String {
        switch kind {
        case .group(let g): return "group-\(g.id)-\(destination.id)"
        case .bot(let b): return "bot-\(b.id)-\(destination.id)"
        case .duplicate(let b): return "dup-\(b.id)-\(destination.id)"
        case .duplicateGroup(let g): return "dupgroup-\(g.id)-\(destination.id)"
        }
    }
}

@MainActor
@Observable
final class WorkspaceCenter {
    static let shared = WorkspaceCenter()
    static let currentKey = "currentWorkspace"
    private static let lastChatKey = "workspaceLastChat"
    private static let knownBotsKey = "workspaceKnownBots"
    private static let knownGroupsKey = "workspaceKnownGroups"
    static let bannerKey = "workspaceBannerDismissed"

    enum Sheet: Identifiable {
        case edit(Workspace?)
        case manage
        case move(WorkspaceMove)

        var id: String {
            switch self {
            case .edit(let w): return "edit-\(w?.id ?? "new")"
            case .manage: return "manage"
            case .move(let m): return m.id
            }
        }
    }

    /// What's happening in a workspace, for the dots.
    enum Activity { case quiet, needsYou, working }

    private(set) var layout = WorkspaceLayout()
    private(set) var currentId = Workspace.generalId
    /// The workspaces file exists but can't be read: everything shows in General, and changes are refused until it's reset.
    private(set) var damaged = false
    var sheet: Sheet?
    private var store: WorkspaceStore?
    private weak var model: AppModel?

    var workspaces: [Workspace] { layout.workspaces }
    var current: Workspace { layout.workspaces.first { $0.id == currentId } ?? .general }
    /// More than General: nothing about workspaces shows until you make one.
    var isInUse: Bool { layout.workspaces.count > 1 }

    func install(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        store = WorkspaceStore(paths: model.paths)
        reload()
        if let saved = UserDefaults.standard.string(forKey: Self.currentKey), layout.workspaces.contains(where: { $0.id == saved }) {
            currentId = saved
        }
        reconcile(bots: model.bots, groups: model.groups)
    }

    func reload() {
        guard let store else { return }
        layout = store.load()
        damaged = store.isUnreadable
        if !layout.workspaces.contains(where: { $0.id == currentId }) { currentId = Workspace.generalId }
    }

    // MARK: Where things are

    func id(forBot botId: String) -> String { layout.bots[botId] ?? Workspace.generalId }
    func id(forGroup groupId: String) -> String { layout.groups[groupId] ?? Workspace.generalId }

    func id(for chat: ChatMeta) -> String {
        if chat.kind == .group, let g = chat.groupId { return id(forGroup: g) }
        if let b = chat.botId { return id(forBot: b) }
        return Workspace.generalId
    }

    func workspace(_ id: String) -> Workspace? { layout.workspaces.first { $0.id == id } }

    func bots(in workspaceId: String, from all: [Bot]) -> [Bot] { all.filter { id(forBot: $0.id) == workspaceId } }
    func groups(in workspaceId: String, from all: [BotGroup]) -> [BotGroup] { all.filter { id(forGroup: $0.id) == workspaceId } }

    /// Dots for a workspace: a bot working in it, or one waiting on you.
    func activity(in workspaceId: String) -> Activity {
        guard let model else { return .quiet }
        var result = Activity.quiet
        for run in model.workingRuns {
            guard let chat = model.chat(run.chatId), id(for: chat) == workspaceId else { continue }
            if Attention.waitsOnYou(run.run.message) { return .needsYou }
            result = .working
        }
        return result
    }

    /// Activity in any workspace but the current one.
    var elsewhere: Activity {
        var result = Activity.quiet
        for ws in workspaces where ws.id != currentId {
            switch activity(in: ws.id) {
            case .needsYou: return .needsYou
            case .working: result = .working
            case .quiet: break
            }
        }
        return result
    }

    /// "Biscuit · Data analyst finished": notifications say which workspace they're from.
    func titled(_ title: String, chatId: String) -> String {
        guard isInUse, let model, let chat = model.chat(chatId), let ws = workspace(id(for: chat)) else { return title }
        return "\(ws.name) · \(title)"
    }

    // MARK: Switching

    func select(_ workspaceId: String) {
        guard workspaceId != currentId, layout.workspaces.contains(where: { $0.id == workspaceId }), let model else { return }
        remember(chat: model.selectedChatId)
        currentId = workspaceId
        UserDefaults.standard.set(workspaceId, forKey: Self.currentKey)
        // Back to the chat you had open here, or none.
        if let last = lastChats[workspaceId], let chat = model.chat(last), id(for: chat) == workspaceId {
            model.selectedChatId = last
        } else {
            model.selectedChatId = nil
        }
        if let b = model.selectedBotId, id(forBot: b) != workspaceId { model.selectedBotId = nil }
        if let g = model.selectedGroupId, id(forGroup: g) != workspaceId { model.selectedGroupId = nil }
    }

    /// Opening a chat from somewhere else (a notification, ⌘K) takes you to its workspace.
    func reveal(chat chatId: String) {
        guard let model, let chat = model.chat(chatId) else { return }
        let target = id(for: chat)
        guard target != currentId else { return }
        currentId = target
        UserDefaults.standard.set(target, forKey: Self.currentKey)
    }

    private var lastChats: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Self.lastChatKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastChatKey) }
    }

    func remember(chat chatId: String?) {
        guard let chatId, let model, let chat = model.chat(chatId), id(for: chat) == currentId else { return }
        lastChats[currentId] = chatId
    }

    // MARK: New things land in the current workspace

    /// A bot or group that wasn't there before goes into the workspace you're in. The first run just notes what exists:
    /// everything already there is in General.
    func reconcile(bots: [Bot], groups: [BotGroup]) {
        guard let store else { return }
        let defaults = UserDefaults.standard
        let seeded = defaults.object(forKey: Self.knownBotsKey) != nil
        let knownBots = Set(defaults.stringArray(forKey: Self.knownBotsKey) ?? [])
        let knownGroups = Set(defaults.stringArray(forKey: Self.knownGroupsKey) ?? [])
        let newBots = bots.map(\.id).filter { !knownBots.contains($0) }
        let newGroups = groups.map(\.id).filter { !knownGroups.contains($0) }
        defaults.set(bots.map(\.id), forKey: Self.knownBotsKey)
        defaults.set(groups.map(\.id), forKey: Self.knownGroupsKey)
        guard seeded, currentId != Workspace.generalId, !(newBots.isEmpty && newGroups.isEmpty) else { return }
        for g in newGroups { _ = try? store.move(group: g, to: currentId) }
        for b in newBots where store.workspaceId(forBot: b) == Workspace.generalId { try? store.move(bot: b, to: currentId) }
        reload()
    }

    /// After an operation that made bots or groups itself: they're accounted for, so `reconcile` leaves them be.
    private func syncKnown() {
        guard let model else { return }
        UserDefaults.standard.set(model.botStore.loadAll().map(\.id), forKey: Self.knownBotsKey)
        UserDefaults.standard.set(model.groupStore.loadAll().map(\.id), forKey: Self.knownGroupsKey)
    }

    // MARK: Editing workspaces

    @discardableResult
    func create(name: String, colour: String, icon: String) -> String? {
        guard let store else { return nil }
        do {
            let ws = try store.create(name: name, colour: colour, icon: icon)
            reload()
            return ws.id
        } catch { report(error); return nil }
    }

    func update(_ workspace: Workspace) -> Bool {
        guard let store else { return false }
        do { try store.update(workspace); reload(); return true } catch { report(error); return false }
    }

    func reorder(_ ids: [String]) {
        try? store?.reorder(ids)
        reload()
    }

    func counts(of workspaceId: String) -> (bots: Int, groups: Int) { store?.counts(of: workspaceId) ?? (0, 0) }

    /// Deletes a workspace; what's in it goes whole to `destination`. Nothing inside is ever deleted.
    func delete(_ workspaceId: String, movingContentsTo destination: String?) -> Bool {
        guard let store else { return false }
        do {
            try store.delete(id: workspaceId, movingContentsTo: destination)
            if currentId == workspaceId { select(destination ?? Workspace.generalId) }
            reload()
            return true
        } catch { report(error); return false }
    }

    // MARK: Moving and duplicating

    /// Error text for the Move sheet, or nil when it worked.
    enum Outcome {
        case done
        case failed(String)
        /// Moving the group would split these bots from groups that stay: ask what to do.
        case sharedBots([SharedBot])
    }

    func perform(_ move: WorkspaceMove, shared policy: SharedBotPolicy = .ask) -> Outcome {
        guard let store, let model else { return .failed("Launchpad isn't ready yet.") }
        do {
            switch move.kind {
            case .group(let g): try store.move(group: g.id, to: move.destination.id, shared: policy)
            case .bot(let b): try store.move(bot: b.id, to: move.destination.id)
            case .duplicate(let b): try store.duplicate(bot: b.id, into: move.destination.id)
            case .duplicateGroup(let g): try store.duplicate(group: g.id, into: move.destination.id)
            }
        } catch WorkspaceError.sharedBots(let bots) {
            return .sharedBots(bots)
        } catch {
            if case WorkspaceError.unreadable = error { damaged = true }
            return .failed(error.localizedDescription)
        }
        syncKnown()
        model.reloadAll()
        reload()
        if let b = model.selectedBotId, id(forBot: b) != currentId { model.selectedBotId = nil }
        if let g = model.selectedGroupId, id(forGroup: g) != currentId { model.selectedGroupId = nil }
        if let c = model.selectedChatId, let chat = model.chat(c), id(for: chat) != currentId { model.selectedChatId = nil }
        return .done
    }

    func origin(ofBot botId: String) -> (bot: String, workspace: Workspace)? {
        guard let o = layout.origins[botId], let ws = workspace(o.workspaceId) else { return nil }
        return (model?.bot(o.botId)?.name ?? o.botId, ws)
    }

    func origin(ofGroup groupId: String) -> (group: String, workspace: Workspace)? {
        guard let o = layout.groupOrigins[groupId], let ws = workspace(o.workspaceId) else { return nil }
        return (model?.group(o.groupId)?.name ?? o.groupId, ws)
    }

    /// A team card's team (by the pack's group id) as it is in the workspace you're in, if it's there.
    func team(family: String, from groups: [BotGroup]) -> BotGroup? {
        groups.first { id(forGroup: $0.id) == currentId && (layout.groupOrigins[$0.id]?.rootId ?? $0.id) == family }
    }

    /// Whether another workspace already holds this team, so adding it here makes a copy.
    func isElsewhere(family: String, in groups: [BotGroup]) -> Bool {
        groups.contains { id(forGroup: $0.id) != currentId && (layout.groupOrigins[$0.id]?.rootId ?? $0.id) == family }
    }

    /// "Add to <workspace>" on a team card: opens the team if it's here, copies it from another workspace, or installs it.
    func addTeam(_ pack: TeamPack) {
        guard let store, let model else { return }
        do {
            let result = try store.addTeam(pack, to: currentId)
            syncKnown()
            model.reloadAll()
            reload()
            model.openChat(with: result.group)
        } catch {
            report(error)
        }
    }

    /// The Reset button for a damaged workspaces file: sets it aside (kept, never deleted) so everything starts in General.
    func resetDamaged() {
        guard let store, let model else { return }
        do {
            if let aside = try store.resetUnreadable() {
                model.alertMessage = "The old file is kept as \(aside.lastPathComponent), next to where it was, in case you want it back. Everything is in General now: add your workspaces again and move your groups."
            }
        } catch {
            model.alertMessage = "Couldn't reset the workspaces file: \(error.localizedDescription)"
        }
        reload()
    }

    private func report(_ error: Error) {
        if case WorkspaceError.unreadable = error { damaged = true }
        model?.alertMessage = error.localizedDescription
    }
}

extension AppModel {
    /// The bots and groups of the workspace you're in: what the lists show.
    var workspaceBots: [Bot] { WorkspaceCenter.shared.bots(in: WorkspaceCenter.shared.currentId, from: bots) }
    var workspaceGroups: [BotGroup] { WorkspaceCenter.shared.groups(in: WorkspaceCenter.shared.currentId, from: groups) }
}
#endif
