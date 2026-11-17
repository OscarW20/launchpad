#if os(macOS)
import AppKit
import Foundation
import LaunchpadCore

// The phone link's view of the app (see LaunchpadCore/PhoneLink.swift). Everything a phone does goes through the
// same AppModel calls as clicking on the Mac.

/// The bridge the phone link server calls. Main-actor bound; holds the model weakly.
@MainActor
final class AppPhoneBridge: PhoneLinkBridge {
    weak var model: AppModel?

    init(model: AppModel) { self.model = model }

    func phoneSnapshot() async -> PhoneSnapshot {
        model?.phoneSnapshot() ?? PhoneSnapshot()
    }

    func phoneSend(chat: String, text: String) async -> PhoneResult {
        guard let model else { return .rejected(503, "Launchpad is closing") }
        guard model.chat(chat) != nil else { return .rejected(404, "That chat isn’t on your Mac any more") }
        guard !model.isRunning(chat) else { return .rejected(409, "Still working on the last message. Wait, or tap Stop.") }
        model.send(chatId: chat, text: text)
        model.phoneMarkRead(chat, at: Date())
        return .ok
    }

    func phoneSide(chat: String, text: String) async -> PhoneResult {
        model?.phoneSideQuestion(chatId: chat, text: text) ?? .rejected(503, "Launchpad is closing")
    }

    func phoneAnswerQuestions(chat: String, message: String, answers: [String]) async -> PhoneResult {
        model?.phoneAnswerQuestions(chatId: chat, messageId: message, answers: answers) ?? .rejected(503, "Launchpad is closing")
    }

    func phoneAnswerApproval(chat: String, message: String, approve: Bool) async -> PhoneResult {
        guard let model else { return .rejected(503, "Launchpad is closing") }
        guard let m = model.messages(for: chat).first(where: { $0.id == message }), m.approval?.status == .pending else {
            return .rejected(409, "That was already answered")
        }
        guard !model.isRunning(chat) else { return .rejected(409, "Still working. Answer once it’s finished.") }
        model.respond(to: message, in: chat, approve: approve)
        return .ok
    }

    func phoneAnswerCard(chat: String, card: String, answer: ApprovalAnswer) async -> PhoneResult {
        guard let model else { return .rejected(503, "Launchpad is closing") }
        let pending = model.liveRuns(for: chat).contains { $0.approvals.contains { $0.id == card && $0.state == .pending } }
        guard pending else { return .rejected(409, "That was already answered, or the reply ended") }
        model.answerApproval(card, in: chat, answer)
        return .ok
    }

    func phoneMarkRead(chat: String, at: Date) async {
        model?.phoneMarkRead(chat, at: at)
    }

    func phoneStop(chat: String) async -> PhoneResult {
        guard let model else { return .rejected(503, "Launchpad is closing") }
        model.stop(chat)
        return .ok
    }
}

extension AppModel {
    private static let readMarksKey = "phone.readMarks"
    static let phoneReadBaselineKey = "phone.readBaseline"

    /// Everything the phone can see right now.
    func phoneSnapshot() -> PhoneSnapshot {
        var all: [String: [ChatMessage]] = [:]
        var typing: [String: [String]] = [:]
        var working: Set<String> = []
        for meta in chats {
            loadMessagesIfNeeded(meta.id)
            let runs = liveRuns(for: meta.id)
            all[meta.id] = messages(for: meta.id) + runs.map(\.message)
            if !runs.isEmpty { typing[meta.id] = runs.map(\.botId) }
            if isRunning(meta.id) { working.insert(meta.id) }
        }
        var marks = Self.phoneReadMarks
        // The chat open on the Mac, while you're looking at it, counts as read.
        if NSApp?.isActive == true, section == .chats, let open = selectedChatId { marks[open] = Date() }
        let baseline = UserDefaults.standard.object(forKey: Self.phoneReadBaselineKey) as? Date
        return PhoneSnapshot(bots: bots, groups: groups, chats: chats, messages: all, working: working, typing: typing,
                             readMarks: marks, readBaseline: baseline, alwaysForWrites: alwaysForWrites)
    }

    static var phoneReadMarks: [String: Date] {
        let raw = UserDefaults.standard.dictionary(forKey: readMarksKey) as? [String: Double] ?? [:]
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    func phoneMarkRead(_ chatId: String, at date: Date) {
        var raw = UserDefaults.standard.dictionary(forKey: Self.readMarksKey) as? [String: Double] ?? [:]
        // Drop marks for chats that are gone.
        let live = Set(chats.map(\.id))
        raw = raw.filter { live.contains($0.key) }
        raw[chatId] = date.timeIntervalSince1970
        UserDefaults.standard.set(raw, forKey: Self.readMarksKey)
    }

    /// Answers a question card the way tapping the choices would: the card is marked answered and the answers go
    /// to the bot as your next message.
    func phoneAnswerQuestions(chatId: String, messageId: String, answers: [String]) -> PhoneResult {
        guard let meta = chat(chatId) else { return .rejected(404, "That chat isn’t on your Mac any more") }
        guard var m = messages(for: chatId).first(where: { $0.id == messageId }), let card = m.questions else {
            return .rejected(404, "That question isn’t there any more")
        }
        guard !card.answered else { return .rejected(409, "Already answered") }
        guard !isRunning(chatId) else { return .rejected(409, "Still working. Answer once it’s finished.") }
        let mention = meta.kind == .group ? m.botId : nil
        guard let answered = ChatOps.answer(card, with: answers, mention: mention) else {
            return .rejected(400, "Answer every question")
        }
        m.questions = answered.card
        phoneReplaceMessage(m, in: chatId)
        send(chatId: chatId, text: answered.prompt)
        phoneMarkRead(chatId, at: Date())
        return .ok
    }

    /// A quick side question while the bot (or a group's lead) works: answered from a read-only fork of its session,
    /// so the main job carries on untouched. The question and answer appear in the chat.
    func phoneSideQuestion(chatId: String, text: String) -> PhoneResult {
        guard let meta = chat(chatId) else { return .rejected(404, "That chat isn’t on your Mac any more") }
        let askerId = meta.kind == .bot ? meta.botId : group(meta.groupId)?.lead
        guard let bot = bot(askerId) else { return .rejected(409, "There’s no one to ask in this chat") }
        if bot.lockedDown {
            return .rejected(409, "\(bot.name) is locked down, so side questions aren’t available for it yet.")
        }
        loadMessagesIfNeeded(chatId)
        let history = messages(for: chatId)
        append(ChatMessage(role: .user, text: "💭 Side question for \(bot.name): \(text)"), to: chatId)
        var options = RunOptions()
        if BotSandbox.available { options.sandboxProfile = BotSandbox(bot: bot, paths: paths).profile() }
        options.quiet = true
        let names = Dictionary(bots.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let invocation = SideQuestion.invocation(for: bot, question: text, botDirectory: paths.botDir(bot.id),
                                                 sessionId: meta.sessions[bot.id], history: history, names: names,
                                                 options: options)
        let handle = runner.run(invocation)
        let botId = bot.id
        Task { @MainActor [weak self] in
            var builder = MessageBuilder(botId: botId)
            for await event in handle.events { builder.apply(event) }
            var answer = builder.message
            answer.steps = []
            if answer.status == .done, !answer.text.isEmpty { answer.text = "💭 " + answer.text }
            self?.append(answer, to: chatId)
        }
        return .ok
    }
}
#endif
