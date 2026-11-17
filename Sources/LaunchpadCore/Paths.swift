import Foundation

/// The on-disk layout of ~/Launchpad. Everything the app knows lives here.
public struct LaunchpadPaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static var `default`: LaunchpadPaths {
        if let override = ProcessInfo.processInfo.environment["LAUNCHPAD_HOME"], !override.isEmpty {
            return LaunchpadPaths(root: URL(fileURLWithPath: override, isDirectory: true))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return LaunchpadPaths(root: home.appendingPathComponent("Launchpad", isDirectory: true))
    }

    public var bots: URL { root.appendingPathComponent("bots", isDirectory: true) }
    public var groups: URL { root.appendingPathComponent("groups", isDirectory: true) }
    public var skills: URL { root.appendingPathComponent("skills", isDirectory: true) }
    public var chats: URL { root.appendingPathComponent("chats", isDirectory: true) }
    public var connectorsFile: URL { root.appendingPathComponent("connectors.json") }

    public func botDir(_ id: String) -> URL { bots.appendingPathComponent(id, isDirectory: true) }
    public func botJSON(_ id: String) -> URL { botDir(id).appendingPathComponent("bot.json") }
    public func claudeMD(_ id: String) -> URL { botDir(id).appendingPathComponent("CLAUDE.md") }
    public func agentsMD(_ id: String) -> URL { botDir(id).appendingPathComponent("AGENTS.md") }
    /// Before MEMORY.md, a bot's memory was notes.md; it's imported into MEMORY.md once (see MemoryStore).
    public func notesMD(_ id: String) -> URL { botDir(id).appendingPathComponent("notes.md") }
    /// The bot's long-term memory, grouped by topic (see MemoryBook).
    public func memoryMD(_ id: String) -> URL { botDir(id).appendingPathComponent("MEMORY.md") }
    /// The app's own memory data for a bot (versions for Undo), kept out of the bot's folder.
    public func memoryData(_ id: String) -> URL {
        root.appendingPathComponent(".launchpad/memory/bots/\(id)", isDirectory: true)
    }
    public func workspace(_ id: String) -> URL { botDir(id).appendingPathComponent("workspace", isDirectory: true) }

    // The app's own data. Bots may never write here (the guard and the sandbox both stop them), except
    // `approvalRequests`, where the guard hook (which runs inside the bot's sandbox) leaves its questions.
    public var launchpadData: URL { root.appendingPathComponent(".launchpad", isDirectory: true) }
    /// Each bot's guard rules: `rules/<bot-id>.json`, written by the app, read by `launchpad-guard`.
    public var guardRules: URL { launchpadData.appendingPathComponent("rules", isDirectory: true) }
    public func rulesFile(_ botId: String) -> URL { guardRules.appendingPathComponent("\(botId).json") }
    /// Approval cards the guard is waiting on (written by the hook).
    public var approvalRequests: URL { launchpadData.appendingPathComponent("requests", isDirectory: true) }
    /// Your answers to approval cards (written by the app only).
    public var approvalAnswers: URL { launchpadData.appendingPathComponent("answers", isDirectory: true) }
    /// Private git stores for undo: `snapshots/<bot-id>.git`.
    public var snapshots: URL { launchpadData.appendingPathComponent("snapshots", isDirectory: true) }
    public func snapshotStore(_ botId: String) -> URL { snapshots.appendingPathComponent("\(botId).git", isDirectory: true) }

    public func chatMeta(_ id: String) -> URL { chats.appendingPathComponent("\(id).json") }
    public func chatLog(_ id: String) -> URL { chats.appendingPathComponent("\(id).jsonl") }

    /// Creates the top-level folders and an empty connectors.json if missing.
    public func ensureStructure(fileManager fm: FileManager = .default) throws {
        for dir in [root, bots, groups, skills, chats] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: connectorsFile.path) {
            try Data("{\n  \"servers\": []\n}\n".utf8).write(to: connectorsFile, options: .atomic)
        }
    }
}

enum JSONCoding {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func lineEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

public enum Slug {
    /// "Frontend Dev!" -> "frontend-dev"
    public static func make(_ name: String) -> String {
        let lowered = name.lowercased().folding(options: .diacriticInsensitive, locale: .current)
        var out = ""
        var lastDash = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII {
                out.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash && !out.isEmpty {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "bot" : String(out.prefix(40))
    }

    /// A slug that isn't in `taken`: "lead", "lead-2", "lead-3"…
    public static func unique(_ name: String, taken: Set<String>) -> String {
        let base = make(name)
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }
}
