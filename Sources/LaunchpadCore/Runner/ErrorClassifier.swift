import Foundation

/// Turns whatever an engine printed when it failed into a plain-English message and a next step.
public enum ErrorClassifier {
    public static func cliMissing(_ engine: BotEngine) -> RunFailure {
        RunFailure(
            kind: .cliMissing,
            message: "\(engine.displayName) isn't installed on this Mac yet. Install it, then try again.",
            detail: "Couldn't find the `\(engine.executableName)` command.",
            action: .openURL(engine.installURL)
        )
    }

    public static func classify(engine: BotEngine, text raw: String, exitCode: Int32? = nil) -> RunFailure {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        func has(_ needles: [String]) -> Bool { needles.contains { lower.contains($0) } }

        if exitCode == 127 || has(["command not found", "no such file or directory, posix_spawn"]) {
            var f = cliMissing(engine)
            f.detail = text
            return f
        }
        if has(["no conversation found", "session not found", "no session found", "thread not found",
                "no rollout found", "could not find session", "unknown session"]) {
            return RunFailure(kind: .sessionLost,
                              message: "I couldn't pick up the earlier conversation, so I started a fresh one.",
                              detail: text)
        }
        if has(["usage limit", "rate limit", "rate_limit", "429", "limit reached", "quota", "too many requests",
                "out of credits", "credit balance"]) {
            return RunFailure(kind: .usageLimit,
                              message: "You've reached your \(engine.planName) plan's usage limit for now. Try again a bit later.",
                              detail: text)
        }
        if has(["not logged in", "please run /login", "/login", "invalid api key", "401", "unauthorized",
                "authentication", "missing bearer", "token has expired", "token expired", "sign in", "log in",
                "login required", "codex login"]) {
            return RunFailure(kind: .signedOut,
                              message: "\(engine.displayName) needs you to sign in. Click here to open Terminal.",
                              detail: text,
                              action: .openTerminal(command: engine.signInCommand))
        }
        if has(["overloaded", "529", "503", "service unavailable", "server is busy"]) {
            return RunFailure(kind: .overloaded,
                              message: "\(engine.displayName) is busy right now. Try again in a minute.",
                              detail: text)
        }
        if has(["enotfound", "econnrefused", "econnreset", "etimedout", "network", "could not resolve",
                "offline", "timed out", "connection refused", "failed to connect", "stream disconnected"]) {
            return RunFailure(kind: .network,
                              message: "I couldn't reach \(engine.displayName). Check your internet connection and try again.",
                              detail: text)
        }
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? ""
        let summary = firstLine.isEmpty
            ? "\(engine.displayName) stopped unexpectedly\(exitCode.map { " (code \($0))" } ?? "")."
            : "\(engine.displayName) ran into a problem: \(ToolSummary.short(firstLine, max: 160))"
        return RunFailure(kind: .unknown, message: summary, detail: text.isEmpty ? nil : text)
    }
}
