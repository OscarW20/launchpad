import Foundation

/// What the sidebar shows about plan usage. Kept in ~/Launchpad/.launchpad/usage.json (no secrets).
public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var claudeWindows: [UsageWindow] = []
    public var claudeUpdatedAt: Date?
    public var claudeDay: String?
    public var claudeCostToday: Double = 0
    public var codexDay: String?
    public var codexTokensToday: Int = 0
    public var codexUpdatedAt: Date?

    public init() {}
}

public final class UsageStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(paths: LaunchpadPaths) {
        url = paths.root.appendingPathComponent(".launchpad/usage.json")
    }

    public func load() -> UsageSnapshot {
        guard let data = try? Data(contentsOf: url) else { return UsageSnapshot() }
        return (try? JSONCoding.decoder().decode(UsageSnapshot.self, from: data)) ?? UsageSnapshot()
    }

    @discardableResult
    public func record(_ report: UsageReport, now: Date = Date()) -> UsageSnapshot {
        update(now: now) { s, today in
            switch report.engine {
            case .claude:
                if !report.windows.isEmpty {
                    // Merge so a report about one window doesn't wipe the others.
                    for w in report.windows {
                        if let i = s.claudeWindows.firstIndex(where: { $0.name == w.name }) { s.claudeWindows[i] = w } else { s.claudeWindows.append(w) }
                    }
                    s.claudeUpdatedAt = now
                }
            case .codex:
                if let tokens = report.tokens {
                    if s.codexDay != today { s.codexDay = today; s.codexTokensToday = 0 }
                    s.codexTokensToday += tokens
                    s.codexUpdatedAt = now
                }
            }
        }
    }

    @discardableResult
    public func recordCost(_ usd: Double, now: Date = Date()) -> UsageSnapshot {
        update(now: now) { s, today in
            if s.claudeDay != today { s.claudeDay = today; s.claudeCostToday = 0 }
            s.claudeCostToday += usd
        }
    }

    private func update(now: Date, _ change: (inout UsageSnapshot, String) -> Void) -> UsageSnapshot {
        lock.lock(); defer { lock.unlock() }
        var s = load()
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        change(&s, f.string(from: now))
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONCoding.encoder().encode(s).write(to: url, options: .atomic)
        return s
    }
}
