#if os(macOS)
import SwiftUI
import LaunchpadCore

/// The header's green "working" line as a button: click it to see who's working in this chat.
struct WorkingButton: View {
    let chatId: String
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            WorkingStatus().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("See who's working")
        .accessibilityLabel("Working. See who's working")
        .popover(isPresented: $showing, arrowEdge: .bottom) { WhoIsWorking(chatId: chatId) }
    }
}

/// Who's replying in a chat right now: each bot, what it's doing and how long it's been going.
struct WhoIsWorking: View {
    @Environment(AppModel.self) private var model
    let chatId: String

    var body: some View {
        let runs = (model.live[chatId] ?? []).filter { !$0.isSide }
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Who's working")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.text)
            if runs.isEmpty {
                // Busy with no live reply: the group is between two bots' turns.
                Text(model.isRunning(chatId) ? "Handing over to the next bot…" : "Nobody's working")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
            } else {
                TimelineView(.periodic(from: .now, by: 10)) { context in
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        ForEach(runs) { run in
                            BotStatusRow(bot: model.bot(run.botId), run: run, now: context.date)
                        }
                    }
                }
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 320, alignment: .leading)
    }
}

/// The group header's member avatars (and the members line when the group is quiet) as a button: click it to see
/// who's working and who's idle.
struct MembersButton: View {
    @Environment(AppModel.self) private var model
    let group: BotGroup
    let chatId: String
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: -6) {
                ForEach(group.everyone, id: \.self) { id in
                    AvatarView(bot: model.bot(id), size: 20)
                        .background(Circle().fill(Theme.card))
                        .help(model.bot(id)?.name ?? id)
                }
                if !model.isRunning(chatId) {
                    Text("\(group.everyone.count) members · lead: \(model.bot(group.lead)?.name ?? "none")")
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .padding(.leading, 12)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("See who's working and who's idle")
        .accessibilityLabel("\(group.everyone.count) members. See who's working and who's idle")
        .popover(isPresented: $showing, arrowEdge: .bottom) { GroupMembersStatus(group: group, chatId: chatId) }
    }
}

/// Every member of a group, the working ones first: what each is doing and for how long, or "Idle".
struct GroupMembersStatus: View {
    @Environment(AppModel.self) private var model
    let group: BotGroup
    let chatId: String

    var body: some View {
        // A member's reply in this chat, or failing that the one it's writing in another chat.
        let here = (model.live[chatId] ?? []).filter { !$0.isSide }
        var runs = Dictionary(model.workingRuns.map { ($0.run.botId, $0) }, uniquingKeysWith: { a, _ in a })
        for run in here { runs[run.botId] = WorkingRun(chatId: chatId, run: run) }
        let members = WorkSummary.workingFirst(group.everyone, working: Set(runs.keys))
        let working = members.filter { runs[$0] != nil }.count
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Members")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(working == 0 ? "Everyone's idle" : "\(working) working · \(members.count - working) idle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            }
            TimelineView(.periodic(from: .now, by: 10)) { context in
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    ForEach(members, id: \.self) { id in
                        let found = runs[id]
                        BotStatusRow(
                            bot: model.bot(id), run: found?.run,
                            elsewhere: found.flatMap { $0.chatId == chatId ? nil : model.chat($0.chatId)?.title },
                            showsStatus: true, now: context.date
                        )
                    }
                }
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 340, alignment: .leading)
    }
}

/// One bot in a "who's working" list: avatar, name, what it's doing and how long it's been going.
/// With `showsStatus` it also shows the role and a dot: green working, amber waiting on you, grey idle.
struct BotStatusRow: View {
    let bot: Bot?
    /// The bot's live reply; nil when it's idle.
    let run: LiveRun?
    /// The other chat the bot is working in, when it isn't this one.
    var elsewhere: String?
    var showsStatus = false
    let now: Date

    var body: some View {
        let reply = run?.message
        let waitsOnYou = reply.map(Attention.waitsOnYou) ?? false
        HStack(alignment: .top, spacing: 10) {
            AvatarView(bot: bot, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(bot?.name ?? "Removed bot")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    if showsStatus, let role = bot?.role, !role.isEmpty {
                        Text(role)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: Theme.Space.s)
                    if let run {
                        Text(WorkSummary.elapsed(since: run.builder.message.createdAt, now: now))
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if showsStatus {
                        Circle()
                            .fill(run == nil ? Theme.secondary.opacity(0.5) : (waitsOnYou ? Theme.warning : Theme.successFill))
                            .frame(width: 7, height: 7)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    }
                    Text(line(reply))
                        .font(.system(size: 12))
                        .foregroundStyle(waitsOnYou ? Theme.warning : Theme.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func line(_ reply: ChatMessage?) -> String {
        guard let run, let reply else { return "Idle" }
        let doing = WorkSummary.line(for: reply, todos: run.builder.todos)
        return elsewhere.map { "\(doing) · in \($0)" } ?? doing
    }
}
#endif
