import Foundation

// Auto-compacting long chats. A chat that sits near the top of the model's window re-sends everything on every message,
// which is where the tokens go. This is the part with no UI: the setting, what to tell each engine, the summary step and
// the rules for when it may run. Nothing is deleted: the full chat stays on disk, and what was summarised is marked.

/// When and how a long chat is compacted. Saved in Launchpad's data folder, which bots can't write.
public struct ContextSettings: Codable, Equatable, Sendable {
    public static let defaultThreshold = 0.75
    public static let thresholdRange = 0.30...0.95
    public static let defaultKeepRecent = 8
    public static let keepRecentRange = 2...40

    /// Compact by itself when a chat gets this full. Off: Launchpad only suggests it.
    public var autoCompact: Bool
    /// How full the window may get before compacting, 0.3 to 0.95 (default 0.75).
    public var threshold: Double
    /// How many of the latest messages stay word for word when older ones are summarised.
    public var keepRecentMessages: Int

    public init(autoCompact: Bool = true, threshold: Double = ContextSettings.defaultThreshold,
                keepRecentMessages: Int = ContextSettings.defaultKeepRecent) {
        self.autoCompact = autoCompact
        self.threshold = min(max(threshold.isFinite ? threshold : Self.defaultThreshold, Self.thresholdRange.lowerBound), Self.thresholdRange.upperBound)
        self.keepRecentMessages = min(max(keepRecentMessages, Self.keepRecentRange.lowerBound), Self.keepRecentRange.upperBound)
    }

    enum CodingKeys: String, CodingKey { case autoCompact, threshold, keepRecentMessages }

    /// Reads leniently: anything missing or unreadable falls back to its default, and out-of-range values are clamped.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(autoCompact: (try? c.decodeIfPresent(Bool.self, forKey: .autoCompact)) ?? true,
                  threshold: (try? c.decodeIfPresent(Double.self, forKey: .threshold)) ?? Self.defaultThreshold,
                  keepRecentMessages: (try? c.decodeIfPresent(Int.self, forKey: .keepRecentMessages)) ?? Self.defaultKeepRecent)
    }

    /// 75 for the default, for the engines' own percentage settings.
    public var percent: Int { Int((threshold * 100).rounded()) }
}

/// Where the setting lives: `.launchpad/context-settings.json`, next to the other files bots can't change.
public struct ContextSettingsStore {
    public let file: URL

    public init(paths: LaunchpadPaths) {
        file = paths.launchpadData.appendingPathComponent("context-settings.json")
    }

    public func load() -> ContextSettings {
        guard let data = try? Data(contentsOf: file),
              let settings = try? JSONCoding.decoder().decode(ContextSettings.self, from: data) else { return ContextSettings() }
        return settings
    }

    public func save(_ settings: ContextSettings) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.encoder().encode(settings).write(to: file, options: .atomic)
    }
}

/// A rough size for text, for when an engine hasn't reported one: about four bytes to a token.
public enum TokenEstimate {
    public static func tokens(_ text: String) -> Int { max(1, (text.utf8.count + 3) / 4) }

    public static func tokens(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + tokens($1.text) + 4 }
    }
}

/// What an engine did to a chat's context by itself.
public struct ContextCompaction: Codable, Hashable, Sendable {
    public enum Trigger: String, Codable, Sendable { case auto, manual }

    public var engine: BotEngine
    public var trigger: Trigger
    public var tokensBefore: Int?
    public var tokensAfter: Int?

    public init(engine: BotEngine, trigger: Trigger, tokensBefore: Int? = nil, tokensAfter: Int? = nil) {
        self.engine = engine
        self.trigger = trigger
        self.tokensBefore = tokensBefore
        self.tokensAfter = tokensAfter
    }

    /// The line to post in the chat, so a compaction is never silent.
    public func notice(botName: String? = nil) -> String {
        let who = botName.map { "\(engine.displayName) compacted \($0)'s memory" } ?? "\(engine.displayName) compacted this conversation"
        var text = who + (trigger == .auto ? " automatically" : "")
        if let before = tokensBefore {
            text += ": it was at \(ContextUsage.tokens(before)) tokens"
            if let after = tokensAfter { text += " and is now about \(ContextUsage.tokens(after))" }
        }
        return text + ". The whole chat is still here; the bot now remembers older turns through a summary."
    }
}
