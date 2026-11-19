import Foundation

// What stops a group that is working. A team should finish its task: it stops when the task is done, when a bot asks you
// something (a question, a plan card or an approval), or when it's stuck. "Stuck" is a loop (the same hand-off again and
// again with nothing new in it) or a generous safety cap on hand-offs. Neither is a routine pause: both say why they stopped.
// The token controls (auto-compact, the context checks) are separate and stay on.

/// The safety cap, saved in Launchpad's data folder (which bots can't write).
public struct RunLimits: Codable, Equatable, Sendable {
    /// High enough that normal multi-step work never reaches it. It only stops a run that never settles.
    public static let defaultMaxHandoffs = 60
    public static let maxHandoffsRange = 3...500

    /// Hand-offs in one run before the team stops with a reason.
    public var maxHandoffs: Int

    public init(maxHandoffs: Int = RunLimits.defaultMaxHandoffs) {
        self.maxHandoffs = min(max(maxHandoffs, Self.maxHandoffsRange.lowerBound), Self.maxHandoffsRange.upperBound)
    }

    enum CodingKeys: String, CodingKey { case maxHandoffs }

    /// Reads leniently: missing or unreadable is the default, and out-of-range values are clamped.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(maxHandoffs: (try? c.decodeIfPresent(Int.self, forKey: .maxHandoffs)) ?? Self.defaultMaxHandoffs)
    }
}

/// `.launchpad/run-limits.json`.
public struct RunLimitsStore {
    public let file: URL

    public init(paths: LaunchpadPaths) {
        file = paths.launchpadData.appendingPathComponent("run-limits.json")
    }

    public func load() -> RunLimits {
        guard let data = try? Data(contentsOf: file),
              let limits = try? JSONCoding.decoder().decode(RunLimits.self, from: data) else { return RunLimits() }
        return limits
    }

    public func save(_ limits: RunLimits) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.encoder().encode(limits).write(to: file, options: .atomic)
    }
}

/// Spots a team going round in circles: the same bot handing the same work to the same people, over and over, with
/// nothing new in the message. Different work, or a different message, never counts, so a long task that keeps moving
/// is never mistaken for a loop. One per run.
public struct LoopDetector: Sendable {
    /// The same hand-off this many times is a loop.
    public static let repeats = 3
    /// How alike two messages must be (share of the same words) to count as the same.
    static let similarity = 0.85

    private struct Seen { var botId: String, targets: Set<String>, words: Set<String> }
    private var seen: [Seen] = []

    public init() {}

    /// Notes one hand-off (`botId` wrote `text` and handed on to `targets`). Returns how many times this same hand-off has
    /// now happened once it reaches `repeats`.
    public mutating func observe(botId: String, text: String, handedTo targets: [String]) -> Int? {
        guard !targets.isEmpty else { return nil }
        let entry = Seen(botId: botId, targets: Set(targets), words: Self.words(text))
        let same = seen.filter { $0.botId == entry.botId && $0.targets == entry.targets && Self.alike($0.words, entry.words) }.count + 1
        seen.append(entry)
        return same >= Self.repeats ? same : nil
    }

    /// The words of a message, lower-cased, without punctuation, digits or @mentions (so "step 3" and "step 4" match).
    static func words(_ text: String) -> Set<String> {
        var out = Set<String>()
        var word = ""
        func flush() { if !word.isEmpty { out.insert(word); word = "" } }
        var skipping = false
        for ch in text.lowercased() {
            if ch == "@" { flush(); skipping = true; continue }
            if ch.isLetter { if !skipping { word.append(ch) } } else { flush(); skipping = false }
        }
        flush()
        return out
    }

    static func alike(_ a: Set<String>, _ b: Set<String>) -> Bool {
        if a.isEmpty && b.isEmpty { return true }
        let shared = a.intersection(b).count, all = a.union(b).count
        return all > 0 && Double(shared) / Double(all) >= similarity
    }
}

extension GroupOutcome {
    /// What to tell the user when a run stops for being stuck rather than finished. nil for every other outcome.
    public func stuckReason(names: (String) -> String) -> String? {
        switch self {
        case .loopDetected(let botId, let times):
            return "\(names(botId)) has handed the same work on \(times) times with nothing new in it, so I stopped the team. Continue to try again, or leave it and tell them what to do differently."
        case .handoffLimitReached(let limit, _):
            return "The team reached the safety limit of \(limit) hand-offs in one run, so I stopped it. Continue to carry on, or raise the limit in Settings."
        default:
            return nil
        }
    }
}
