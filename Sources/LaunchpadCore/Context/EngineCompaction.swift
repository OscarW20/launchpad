import Foundation

/// Telling each engine when to compact by itself. Claude Code and Codex both summarise their own session when it nears
/// the model's window, but only at the very top by default (a Claude session was seen compacting at 998,221 tokens on a
/// 1M window). These settings move that point to the threshold, and they work mid-run, which an app-level step can't.
public enum EngineCompaction {
    /// Claude Code: the share of the window (1 to 100) at which it compacts. The installed CLI knows this setting.
    public static let claudeVariable = "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"
    /// Codex's own typical window, when it hasn't said.
    public static let codexDefaultWindow = 272_000

    /// How a chat's context is kept in check for each engine.
    public enum Mechanism: Equatable, Sendable {
        /// Set the engine's own compaction point at launch (`environment`, `codexArguments`).
        case engineSetting
        /// The app builds the history itself (a local model has no session), so the app summarises and trims it.
        case appHistory
    }

    public static func mechanism(for engine: BotEngine) -> Mechanism {
        engine == .local ? .appHistory : .engineSetting
    }

    /// `environment` with Claude's compaction point set to the threshold. A value already in `environment` wins, so
    /// it can still be set by hand. Unchanged for other engines and when auto-compact is off.
    public static func environment(_ environment: [String: String], engine: BotEngine, settings: ContextSettings?) -> [String: String] {
        guard engine == .claude, let settings, settings.autoCompact, environment[claudeVariable] == nil else { return environment }
        var out = environment
        out[claudeVariable] = String(settings.percent)
        return out
    }

    /// Codex's compaction point in tokens: the threshold of its window (`window`, or its typical one).
    public static func codexTokenLimit(settings: ContextSettings?, window: Int?) -> Int? {
        guard let settings, settings.autoCompact else { return nil }
        let size = (window ?? 0) > 0 ? window! : codexDefaultWindow
        return max(1_000, Int(Double(size) * settings.threshold))
    }

    /// `-c model_auto_compact_token_limit=N` for `codex exec`, or nothing.
    public static func codexArguments(settings: ContextSettings?, window: Int?) -> [String] {
        guard let limit = codexTokenLimit(settings: settings, window: window) else { return [] }
        return ["-c", "model_auto_compact_token_limit=\(limit)"]
    }
}
