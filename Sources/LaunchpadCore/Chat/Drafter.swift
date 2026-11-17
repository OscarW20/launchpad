import Foundation

/// A bot written from a one-line description.
public struct BotDraft: Codable, Equatable, Sendable {
    public var name: String
    public var role: String
    public var instructions: String
    public var emoji: String
    public var colour: String

    public init(name: String, role: String, instructions: String, emoji: String, colour: String) {
        self.name = name
        self.role = role
        self.instructions = instructions
        self.emoji = emoji
        self.colour = colour
    }
}

public enum DraftError: Error, Equatable, LocalizedError, Sendable {
    case empty
    case unreadable
    case engine(String)

    public var errorDescription: String? {
        switch self {
        case .empty: return "Say in a few words what the bot should do."
        case .unreadable: return "The draft came back in a format I couldn't read. Try again or fill it in by hand."
        case .engine(let message): return message
        }
    }
}

/// Turns "a researcher who digs up sources" into a name, role, instructions, emoji and colour with a one-shot run.
public enum BotDrafter {
    public static func prompt(_ description: String) -> String {
        let colours = BotPalette.colours.joined(separator: ", ")
        return """
        Design a persistent AI teammate from this description: "\(description.trimmingCharacters(in: .whitespacesAndNewlines))"

        Reply with ONLY a JSON object, no prose, no code fences:
        {"name": "a short, friendly name (1–2 words)",
         "role": "one line, under 60 characters",
         "instructions": "6–12 lines of clear working instructions written to the bot in second person: what it does, how it works, its tone, what it should hand to teammates, what it must never do",
         "emoji": "one emoji that fits the role",
         "colour": "one of: \(colours)"}
        """
    }

    /// A one-shot run in a scratch folder (no session kept). Run it with `EngineRunner` (e.g. via
    /// `MemoryReviewer.engine(using:)`).
    public static func invocation(for description: String, engine: BotEngine, model: String?, directory: URL) -> EngineInvocation {
        EngineCommand.oneShot(engine: engine, model: model, prompt: prompt(description), directory: directory)
    }

    /// Reads the JSON (also inside prose or a code fence). Missing or odd fields get sensible values: the colour
    /// must be one of `BotPalette.colours`, the emoji one character; name, role and instructions are required.
    public static func parse(_ text: String) -> BotDraft? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let obj = (try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))) as? [String: Any] else { return nil }
        func field(_ k: String) -> String { (obj[k] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let name = field("name"), role = field("role"), instructions = field("instructions")
        guard !name.isEmpty, !instructions.isEmpty else { return nil }
        let rawColour = field("colour").isEmpty ? field("color") : field("colour")
        let colour = BotPalette.colours.first { $0.lowercased() == rawColour.lowercased() }
            ?? BotPalette.colours[abs(name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % BotPalette.colours.count]
        let emoji = ChatOps.normalisedEmoji(field("emoji"))
        let isEmoji = emoji.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0x238C }
        return BotDraft(name: String(name.prefix(30)), role: String(role.prefix(80)), instructions: instructions,
                        emoji: isEmoji ? emoji : BotPalette.emojis[0], colour: colour)
    }

    /// Runs the draft. `run` is a one-shot engine (`MemoryReviewer.engine(using: runner)` in the app; a fake in tests).
    public static func draft(_ description: String, engine: BotEngine, model: String?, directory: URL,
                             run: MemoryReviewEngine) async -> Result<BotDraft, DraftError> {
        guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.empty) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        switch await run(invocation(for: description, engine: engine, model: model, directory: directory)) {
        case .text(let text): return parse(text).map { .success($0) } ?? .failure(.unreadable)
        case .failed(let failure): return .failure(.engine(failure.message))
        }
    }
}
