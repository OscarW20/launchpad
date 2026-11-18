#if os(macOS)
import SwiftUI
import AppKit
import LaunchpadCore

// Auto-compacting long chats, the app side. The rules and the summary step are in LaunchpadCore (Context/); the engines
// also compact their own sessions at the threshold (`RunOptions.autoCompact`). This is what the app does itself: after a
// reply ends it checks how full each bot's session is, and if one is past the threshold (and the engine's own setting
// hasn't dealt with it) it has a bot summarise the older turns, then restarts the too-full sessions from that summary.
// The whole chat stays on screen; summarised messages are dimmed with a line that shows the summary.

/// What's being compacted now, and the latest compaction of each chat (for the marks in the chat).
@MainActor
@Observable
final class CompactionCenter {
    static let shared = CompactionCenter()

    /// Chats being summarised now.
    private(set) var compacting: Set<String> = []
    /// The latest compaction of each chat.
    private(set) var records: [String: CompactionRecord] = [:]
    /// When a chat's last attempt failed, so a bad summariser isn't tried again after every reply.
    private var failedAt: [String: Date] = [:]
    static let retryAfter: TimeInterval = 15 * 60

    func loadRecords(paths: LaunchpadPaths, chats: [ChatMeta]) {
        let log = CompactionLog(paths: paths)
        for chat in chats { if let record = log.latest(chat.id) { records[chat.id] = record } }
    }

    func begin(_ chatId: String) { compacting.insert(chatId) }
    func end(_ chatId: String) { compacting.remove(chatId) }
    func applied(_ record: CompactionRecord) { records[record.chatId] = record; failedAt[record.chatId] = nil }
    func failed(_ chatId: String) { failedAt[chatId] = Date() }

    func mayTry(_ chatId: String, now: Date = Date()) -> Bool {
        guard let at = failedAt[chatId] else { return true }
        return now.timeIntervalSince(at) >= Self.retryAfter
    }
}

extension AppModel {
    /// How the chat is compacted: the Compact button (`manual`), or after a reply when a session is too full.
    /// - Parameters:
    ///   - botIds: whose sessions to restart from the summary; nil restarts every bot's (the Compact button).
    func compactChat(_ chatId: String, manual: Bool, only botIds: [String]? = nil, fraction: Double? = nil) {
        let center = CompactionCenter.shared
        guard !center.compacting.contains(chatId), let meta = chat(chatId) else { return }
        if isRunning(chatId) {
            if manual { alertMessage = "A bot is replying in this chat. Compact when it has finished." }
            return
        }
        loadMessagesIfNeeded(chatId)
        let history = messages(for: chatId)
        let settings = ContextSettingsStore(paths: paths).load()
        let previous = ChatCompaction.applicable(CompactionLog(paths: paths).latest(chatId), to: history)
        guard let plan = ChatCompaction.plan(messages: history, previous: previous, keepRecent: settings.keepRecentMessages) else {
            // Too short to summarise (a few long replies fill a window too): the old Compact, which restarts from the
            // latest messages, is still what frees the room.
            if manual { restartFromRecap(chatId) }
            return
        }
        guard let summariser = ChatCompaction.summariser(for: meta, bots: bots, groups: groups) else {
            if manual { alertMessage = "No bot in this chat can write the summary." }
            return
        }
        center.begin(chatId)
        let scratch = paths.root.appendingPathComponent(".launchpad/scratch", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let invocation = EngineCommand.oneShot(engine: summariser.engine, model: summariser.model,
                                               prompt: ChatCompaction.prompt(for: plan, names: botNames), directory: scratch,
                                               localBaseURL: summariser.localBaseURL)
        let handle = runner.run(invocation)
        Task { @MainActor [weak self] in
            var builder = MessageBuilder(botId: nil)
            for await event in handle.events { builder.apply(event) }
            guard let self else { return }
            center.end(chatId)
            guard builder.message.status == .done else {
                center.failed(chatId)
                if manual { self.alertMessage = "Couldn't write the summary: \(builder.message.failure?.message ?? "the run didn't finish"). The chat is unchanged." }
                return
            }
            self.finishCompaction(summary: builder.message.text, plan: plan, chatId: chatId, manual: manual,
                                  botIds: botIds, fraction: fraction, engine: summariser.engine)
        }
    }

    private func finishCompaction(summary: String, plan: ChatCompaction.Plan, chatId: String, manual: Bool,
                                  botIds: [String]?, fraction: Double?, engine: BotEngine) {
        let center = CompactionCenter.shared
        guard let meta = chat(chatId) else { return }
        do {
            let record = try ChatCompaction.record(fromSummary: summary, plan: plan, chatId: chatId,
                                                   trigger: manual ? .manual : .auto, fractionBefore: fraction, engine: engine)
            // Asked again right before anything is written: if a bot started replying meanwhile, nothing changes.
            switch try ChatCompactor(paths: paths, chatStore: chatStore).apply(record, to: meta, clearing: botIds, isRunning: { isRunning(chatId) }) {
            case .applied(_, let notice):
                center.applied(record)
                reloadChats()
                contextByChat[chatId] = nil
                append(ChatMessage(role: .notice, text: notice), to: chatId)
            case .skipped:
                // Not an error: a reply began while the summary was being written. It'll be tried again after it.
                if manual { alertMessage = "A bot started replying while the summary was written, so nothing was changed. Compact again when it's done." }
            }
        } catch {
            center.failed(chatId)
            if manual { alertMessage = error.localizedDescription }
        }
    }

    /// The Compact button on a chat too short to summarise: keeps the messages and starts the bots from a recap.
    private func restartFromRecap(_ chatId: String) {
        compact(chatId)
    }

    /// After a reply ends: compact the chat if a bot's session is past the threshold. Never while a bot is replying.
    func autoCompactIfNeeded(_ chatId: String) {
        let center = CompactionCenter.shared
        guard let meta = chat(chatId), !center.compacting.contains(chatId), center.mayTry(chatId) else { return }
        var readings = CompactionLog(paths: paths).readings(chatId)
        // Codex's reading arrives from its session log after the reply, so the live one is the fresher.
        if meta.kind == .bot, let botId = meta.botId, let live = contextByChat[chatId] { readings[botId] = live }
        let settings = ContextSettingsStore(paths: paths).load()
        guard case .compact(let ids) = ContextAdvisor.decide(readings: readings, settings: settings, isRunning: isRunning(chatId)) else { return }
        compactChat(chatId, manual: false, only: ids, fraction: ids.compactMap { readings[$0]?.fraction }.max())
    }

    /// The latest compaction that still applies to this chat, to start a bot from.
    func activeCompaction(_ chatId: String, in history: [ChatMessage]) -> CompactionRecord? {
        ChatCompaction.applicable(CompactionLog(paths: paths).latest(chatId), to: history)
    }
}

/// The line after the last summarised message: says so, and shows the summary the bots were given.
struct SummaryDivider: View {
    let record: CompactionRecord
    @State private var showing = false

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Rectangle().fill(Theme.line).frame(height: 1)
            Button { showing.toggle() } label: {
                Label("\(record.summarizedCount) earlier messages are summarised for the bots", systemImage: "text.append")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize()
            }
            .buttonStyle(.plain)
            .help("The messages above are still here. The bots now remember them through a summary. Click to read it.")
            .accessibilityLabel("Earlier messages are summarised. Show the summary")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text(record.trigger == .auto ? "Summary (made automatically)" : "Summary")
                            .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
                        Text(record.summary)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if record.omittedCount > 0 {
                            Text("\(record.omittedCount) of the oldest messages were too long to include.")
                                .font(.caption).foregroundStyle(Theme.warning)
                        }
                    }
                    .padding(Theme.Space.l)
                }
                .frame(width: 420)
                .frame(maxHeight: 360)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
        }
        .padding(.vertical, 4)
    }
}

/// Settings › Long chats: when a chat is compacted by itself, and how much stays word for word.
struct ContextSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var settings = ContextSettings()
    @State private var loaded = false

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { settings.autoCompact }, set: { v in save { $0.autoCompact = v } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Compact long chats automatically")
                    Text("A chat that sits near the top of its window re-sends everything on every message, which is where tokens go. Compacting summarises the older turns and keeps the latest word for word.")
                        .font(.caption).foregroundStyle(Theme.secondary)
                }
            }
            Stepper(value: Binding(get: { settings.percent }, set: { v in save { $0.threshold = Double(v) / 100 } }),
                    in: 30...95, step: 5) {
                Text("Compact when a chat is \(settings.percent)% full")
            }
            .disabled(!settings.autoCompact)
            Stepper(value: Binding(get: { settings.keepRecentMessages }, set: { v in save { $0.keepRecentMessages = v } }),
                    in: ContextSettings.keepRecentRange) {
                Text("Keep the latest \(settings.keepRecentMessages) messages word for word")
            }
            .disabled(!settings.autoCompact)
        } header: {
            Text("Long chats")
        } footer: {
            Text("Nothing is deleted: the whole chat stays on screen, summarised messages are dimmed, and you can read the summary. Claude and Codex also compact their own memory at this point, from the next reply on. A bot's reply is never interrupted.")
        }
        .onAppear {
            if !loaded { settings = ContextSettingsStore(paths: model.paths).load(); loaded = true }
        }
    }

    private func save(_ change: (inout ContextSettings) -> Void) {
        var next = settings
        change(&next)
        // Through the initialiser, so out-of-range values are clamped.
        next = ContextSettings(autoCompact: next.autoCompact, threshold: next.threshold, keepRecentMessages: next.keepRecentMessages)
        settings = next
        do { try ContextSettingsStore(paths: model.paths).save(next) } catch {
            model.alertMessage = "Couldn't save the setting: \(error.localizedDescription)"
        }
    }
}
#endif
