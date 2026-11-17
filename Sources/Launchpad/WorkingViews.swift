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
                        ForEach(runs) { run in row(run, now: context.date) }
                    }
                }
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 320, alignment: .leading)
    }

    private func row(_ run: LiveRun, now: Date) -> some View {
        let bot = model.bot(run.botId)
        let reply = run.message
        return HStack(alignment: .top, spacing: 10) {
            AvatarView(bot: bot, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(bot?.name ?? "Bot")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: Theme.Space.s)
                    Text(WorkSummary.elapsed(since: run.builder.message.createdAt, now: now))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
                Text(WorkSummary.line(for: reply, todos: run.builder.todos))
                    .font(.system(size: 12))
                    .foregroundStyle(Attention.waitsOnYou(reply) ? Theme.warning : Theme.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
