import Foundation

/// Codex bots run with a CODEX_HOME of Launchpad's own: everything in it links back to `~/.codex` (sign-in,
/// sessions, history, skills), except `config.toml`, which is a copy of yours without your personal MCP servers.
///
/// Why: `codex exec` has no "only these MCP servers" switch, so every Codex bot would otherwise also load every
/// connector in your personal config (slower start, and tools the bot wasn't given). Launchpad passes each bot's
/// own connectors with `-c mcp_servers.…` as before. Your model, provider and profile settings still apply.
///
/// One home is shared by all Codex bots (their differences are all passed per run), outside `~/Launchpad` so
/// Launchpad's sandbox, which protects that folder, doesn't stop Codex writing its logs.
public struct CodexHome: Sendable {
    /// `~/.codex` (or `$CODEX_HOME` if you set one).
    public var real: URL
    /// Launchpad's own, e.g. `~/Library/Application Support/Launchpad/codex-home`.
    public var own: URL

    public init(real: URL = CodexHome.defaultReal, own: URL = CodexHome.defaultOwn) {
        self.real = real
        self.own = own
    }

    public static var defaultReal: URL {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty { return URL(fileURLWithPath: env) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    public static var defaultOwn: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Launchpad/codex-home", isDirectory: true)
    }

    static let header = "# Launchpad: a copy of ~/.codex/config.toml without your personal MCP servers.\n"
        + "# Rewritten before each Codex run; edit ~/.codex/config.toml instead.\n"

    /// Brings the home up to date and returns `["CODEX_HOME": path]` for the run's environment, or nothing if you
    /// haven't signed in to Codex yet (then Codex uses ~/.codex as usual and tells you to sign in).
    @discardableResult
    public func environment(fileManager fm: FileManager = .default) -> [String: String] {
        guard prepare(fileManager: fm) else { return [:] }
        return ["CODEX_HOME": own.path]
    }

    /// Links everything in `real` into `own` except config.toml, and rewrites config.toml. False if not signed in.
    public func prepare(fileManager fm: FileManager = .default) -> Bool {
        guard fm.fileExists(atPath: real.appendingPathComponent("auth.json").path) else { return false }
        do { try fm.createDirectory(at: own, withIntermediateDirectories: true) } catch { return false }
        // Codex writes its logs here: make sure they land in ~/.codex, not in a folder of our own.
        try? fm.createDirectory(at: real.appendingPathComponent("sessions", isDirectory: true), withIntermediateDirectories: true)

        for name in (try? fm.contentsOfDirectory(atPath: real.path)) ?? [] where name != "config.toml" {
            let target = real.appendingPathComponent(name)
            let link = own.appendingPathComponent(name)
            if let dest = try? fm.destinationOfSymbolicLink(atPath: link.path) {
                if dest == target.path { continue }
                try? fm.removeItem(at: link)
            } else if fm.fileExists(atPath: link.path) {
                // Codex replaced our link with a file of its own (e.g. a refreshed sign-in, saved by renaming).
                // Keep whichever is newer in ~/.codex, then link again.
                if Self.modified(link, fm) > Self.modified(target, fm), !Self.isDirectory(link, fm) {
                    _ = try? fm.removeItem(at: target)
                    try? fm.copyItem(at: link, to: target)
                }
                try? fm.removeItem(at: link)
            }
            try? fm.createSymbolicLink(at: link, withDestinationURL: target)
        }

        let personal = (try? String(contentsOf: real.appendingPathComponent("config.toml"), encoding: .utf8)) ?? ""
        let config = Self.header + Self.withoutMCPServers(personal)
        let configURL = own.appendingPathComponent("config.toml")
        if (try? String(contentsOf: configURL, encoding: .utf8)) != config {
            try? config.write(to: configURL, atomically: true, encoding: .utf8)
        }
        return true
    }

    /// config.toml without `[mcp_servers.*]` tables (and their sub-tables) or a top-level `mcp_servers = …` line.
    public static func withoutMCPServers(_ toml: String) -> String {
        var out: [Substring] = []
        var skipping = false
        var inTable = false
        for line in toml.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") {
                let name = t.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                skipping = name == "mcp_servers" || name.hasPrefix("mcp_servers.") || name.hasPrefix("\"mcp_servers\"")
                inTable = true
                if skipping { continue }
            }
            if skipping { continue }
            if !inTable, t.hasPrefix("mcp_servers"), t.dropFirst("mcp_servers".count).trimmingCharacters(in: .whitespaces).hasPrefix("=") {
                continue
            }
            out.append(line)
        }
        var text = out.joined(separator: "\n")
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        return text
    }

    private static func modified(_ url: URL, _ fm: FileManager) -> Date {
        ((try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast
    }

    private static func isDirectory(_ url: URL, _ fm: FileManager) -> Bool {
        var dir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }
}

// MARK: - Codex session logs

/// Reads what Codex writes to `~/.codex/sessions/YYYY/MM/DD/rollout-…-<thread id>.jsonl`: plan usage
/// (`rate_limits`: used_percent, window_minutes, resets_at) and the context window, from its `token_count` events:
/// `{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{…},"model_context_window":…},
/// "rate_limits":{"primary":{…},"secondary":{…}}}}`. No network, no tokens.
public enum CodexSessionLogs {
    /// The default sessions folder (`~/.codex/sessions`).
    public static var defaultRoot: URL { CodexHome.defaultReal.appendingPathComponent("sessions", isDirectory: true) }

    /// What the newest `token_count` in one log says.
    public struct TokenCount: Equatable, Sendable {
        public var windows: [UsageWindow]
        public var context: ContextUsage?
    }

    /// Plan usage for ChatGPT from the newest logs (the first of the `scan` newest that has `rate_limits`).
    public static func usageReport(root: URL = defaultRoot, scan: Int = 5, fileManager fm: FileManager = .default) -> UsageReport? {
        for file in newestLogs(root: root, limit: scan, fileManager: fm) {
            if let count = lastTokenCount(in: file, needRateLimits: true), !count.windows.isEmpty {
                return UsageReport(engine: .codex, windows: count.windows)
            }
        }
        return nil
    }

    /// How full one thread's context is (exact: Codex's own count for its last model call).
    public static func context(threadId: String, root: URL = defaultRoot, fileManager fm: FileManager = .default) -> ContextUsage? {
        guard let file = log(threadId: threadId, root: root, fileManager: fm) else { return nil }
        return lastTokenCount(in: file, needRateLimits: false)?.context
    }

    /// The log file for a thread id.
    public static func log(threadId: String, root: URL = defaultRoot, fileManager fm: FileManager = .default) -> URL? {
        guard !threadId.isEmpty else { return nil }
        let suffix = "\(threadId).jsonl"
        return allLogs(root: root, fileManager: fm).first { $0.url.lastPathComponent.hasSuffix(suffix) }?.url
    }

    /// The newest logs first (by modification time).
    public static func newestLogs(root: URL = defaultRoot, limit: Int = 5, fileManager fm: FileManager = .default) -> [URL] {
        Array(allLogs(root: root, fileManager: fm).prefix(limit).map(\.url))
    }

    private static func allLogs(root: URL, fileManager fm: FileManager) -> [(url: URL, date: Date)] {
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                         options: [.skipsHiddenFiles]) else { return [] }
        var found: [(URL, Date)] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            found.append((url, date))
        }
        return found.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.lastPathComponent > $1.0.lastPathComponent }
    }

    /// The newest `token_count` in a log (only the last 1 MB is read).
    public static func lastTokenCount(in file: URL, needRateLimits: Bool) -> TokenCount? {
        guard let text = tail(file, bytes: 1 << 20) else { return nil }
        for line in text.split(separator: "\n").reversed() where line.contains("token_count") || line.contains("rate_limits") {
            guard let obj = jsonObject(String(line)) else { continue }
            let payload = (obj["payload"] as? [String: Any]) ?? obj
            let lineDate = (obj["timestamp"] as? String).flatMap(parseDate)
            let windows = (payload["rate_limits"] as? [String: Any]).map { rateWindows($0, now: lineDate) } ?? []
            if needRateLimits && windows.isEmpty { continue }
            var context: ContextUsage?
            if let info = payload["info"] as? [String: Any], let last = info["last_token_usage"] as? [String: Any] {
                let total = (last["total_tokens"] as? NSNumber)?.intValue
                    ?? (((last["input_tokens"] as? NSNumber)?.intValue ?? 0) + ((last["output_tokens"] as? NSNumber)?.intValue ?? 0))
                let window = (info["model_context_window"] as? NSNumber)?.intValue
                if total > 0 { context = ContextUsage(engine: .codex, used: total, window: window) }
            }
            if !needRateLimits && context == nil { continue }
            return TokenCount(windows: windows, context: context)
        }
        return nil
    }

    /// `{"primary":{"used_percent":12.0,"window_minutes":300,"resets_at":1763…},"secondary":{…}}` → windows named like
    /// Claude's ("five_hour", "seven_day") so the sidebar can show both plans the same way.
    static func rateWindows(_ limits: [String: Any], now: Date?) -> [UsageWindow] {
        var out: [UsageWindow] = []
        for (slot, fallback) in [("primary", "five_hour"), ("secondary", "seven_day")] {
            guard let w = limits[slot] as? [String: Any], let used = (w["used_percent"] as? NSNumber)?.doubleValue else { continue }
            let minutes = (w["window_minutes"] as? NSNumber)?.intValue
            let name: String
            switch minutes {
            case nil: name = fallback
            case 300?: name = "five_hour"
            case 10080?: name = "seven_day"
            case let m?: name = m % 1440 == 0 ? "\(m / 1440)_day" : m % 60 == 0 ? "\(m / 60)_hour" : "\(m)_minute"
            }
            var resets: Date?
            if let at = (w["resets_at"] as? NSNumber)?.doubleValue {
                resets = Date(timeIntervalSince1970: at)
            } else if let inSeconds = (w["resets_in_seconds"] as? NSNumber)?.doubleValue, let now {
                resets = now.addingTimeInterval(inSeconds)
            }
            out.append(UsageWindow(name: name, utilization: min(1, max(0, used / 100)), resetsAt: resets))
        }
        return out
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    static func tail(_ file: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }   // drop the partial first line
        return text
    }
}
