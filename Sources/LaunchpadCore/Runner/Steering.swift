import Foundation

/// A message waiting for a bot.
public struct QueuedMessage: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    /// The bot it's for.
    public var botId: String
    /// Who wrote it: nil for you, or another bot's id (group hand-offs).
    public var fromBotId: String?
    public var fromName: String
    public var text: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString.lowercased(), botId: String, fromBotId: String? = nil,
                fromName: String = "You", text: String, createdAt: Date = Date()) {
        self.id = id
        self.botId = botId
        self.fromBotId = fromBotId
        self.fromName = fromName
        self.text = text
        self.createdAt = createdAt
    }

    public var isFromUser: Bool { fromBotId == nil }
}

/// One turn for a bot: one or more waiting messages merged into a single prompt.
public struct Turn: Hashable, Sendable {
    public var botId: String
    public var messages: [QueuedMessage]
    /// The prompt to send.
    public var text: String
    /// This turn follows a run you interrupted by writing to the bot.
    public var carriesOn: Bool
}

/// What happens when you write to a bot, and what it works on next.
///
/// - Bot idle: start now.
/// - Bot busy on this chat and steering allowed (a 1:1 chat): **steer**. Stop the current run (Stop's SIGINT keeps
///   the session), then the next turn carries on with your new words, told not to start over.
/// - Otherwise: queue. When the bot is free, everything waiting for it becomes one turn (`merge`), so it works on
///   the latest picture instead of answering stale messages one by one.
public struct TurnQueue: Codable, Hashable, Sendable {
    public enum Decision: Equatable, Sendable {
        case startNow
        /// Cancel the bot's current run; call `next(for:)` once it has ended.
        case steer
        case queue
    }

    public private(set) var waiting: [QueuedMessage] = []
    /// Bots whose current run is being stopped to take in a new message.
    public private(set) var steering: Set<String> = []

    public static let carryOnNote = "(You were in the middle of the previous request when this came in, so your work was "
        + "paused. Everything you did so far is still in this conversation and on disk: don't start over. Carry on, "
        + "taking this new message into account; if it changes the plan, follow it.)"
    public static let batchNote = "Several messages came in while you were working. Handle them together in one reply. "
        + "If the user changed the plan, follow the user's latest words."

    public init() {}

    public var isEmpty: Bool { waiting.isEmpty }
    public func waiting(for botId: String) -> [QueuedMessage] { waiting.filter { $0.botId == botId } }
    public func isSteering(_ botId: String) -> Bool { steering.contains(botId) }

    /// Adds a message. `runningBotId` is the bot replying in this chat right now (nil if none).
    public mutating func submit(_ message: QueuedMessage, runningBotId: String?, allowSteering: Bool = true) -> Decision {
        waiting.append(message)
        guard let runningBotId else { return .startNow }
        if allowSteering, message.isFromUser, runningBotId == message.botId {
            if steering.contains(runningBotId) { return .queue }   // already being stopped; this joins the next turn
            steering.insert(runningBotId)
            return .steer
        }
        return .queue
    }

    /// Takes everything waiting for `botId` as one turn, or nil if nothing is waiting.
    public mutating func next(for botId: String) -> Turn? {
        let batch = waiting.filter { $0.botId == botId }
        guard !batch.isEmpty else { return nil }
        waiting.removeAll { $0.botId == botId }
        let carriesOn = steering.remove(botId) != nil
        var text = Self.merge(batch)
        if carriesOn { text = Self.carryOnNote + "\n\n" + text }
        return Turn(botId: botId, messages: batch, text: text, carriesOn: carriesOn)
    }

    /// The bot's run ended. If it was stopped for steering before the engine started a session, the interrupted
    /// turn never reached the bot's memory: its messages go back in front so they're sent with the new ones.
    public mutating func runEnded(_ turn: Turn, stoppedForSteering: Bool, hadSession: Bool) {
        guard stoppedForSteering, !hadSession else { return }
        let fresh = turn.messages.filter { m in !waiting.contains { $0.id == m.id } }
        waiting.insert(contentsOf: fresh, at: 0)
        steering.remove(turn.botId)   // it never started, so there's nothing to carry on from
    }

    /// Stop pressed, or the chat closed: forget what's waiting.
    public mutating func clear(botId: String? = nil) {
        if let botId {
            waiting.removeAll { $0.botId == botId }
            steering.remove(botId)
        } else {
            waiting.removeAll()
            steering.removeAll()
        }
    }

    /// One prompt from several messages. Teammates' messages first, yours last (they win if the plan changed).
    public static func merge(_ batch: [QueuedMessage]) -> String {
        guard batch.count > 1 else { return batch.first?.text ?? "" }
        let others = batch.filter { !$0.isFromUser }
        let yours = batch.filter(\.isFromUser)
        var parts = [batchNote]
        for m in others { parts.append("From \(m.fromName):\n\(m.text)") }
        if !yours.isEmpty {
            parts.append("From the user" + (yours.count > 1 ? " (in order, the last one is the latest)" : "") + ":\n"
                + yours.map(\.text).joined(separator: "\n\n"))
        }
        return parts.joined(separator: "\n\n---\n")
    }

    /// The reply that was cut short by steering: kept (as done, not "Stopped") if it has anything in it,
    /// otherwise nil so it can be dropped from the chat.
    public static func settleInterrupted(_ message: ChatMessage) -> ChatMessage? {
        let empty = message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && message.steps.isEmpty
            && message.approval == nil
        if empty { return nil }
        var m = message
        if m.status == .stopped || m.status == .streaming { m.status = .done }
        for i in m.steps.indices where m.steps[i].status == .running { m.steps[i].status = .stopped }
        return m
    }
}
