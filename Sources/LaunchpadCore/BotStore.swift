import Foundation

public enum BotStoreError: Error, LocalizedError {
    case notFound(String)
    case emptyName

    public var errorDescription: String? {
        switch self {
        case .notFound(let id): return "There's no bot called \"\(id)\" in your Launchpad folder."
        case .emptyName: return "Give your bot a name first."
        }
    }
}

/// Reads and writes bot folders: bots/<id>/{bot.json, CLAUDE.md, AGENTS.md, notes.md, workspace/}.
public final class BotStore: @unchecked Sendable {
    public let paths: LaunchpadPaths
    private let fm: FileManager

    public init(paths: LaunchpadPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fm = fileManager
    }

    // MARK: Reading

    public func loadAll() -> [Bot] {
        guard let ids = try? fm.contentsOfDirectory(atPath: paths.bots.path) else { return [] }
        return ids
            .filter { !$0.hasPrefix(".") }
            .compactMap { try? load(id: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func load(id: String) throws -> Bot {
        let url = paths.botJSON(id)
        guard fm.fileExists(atPath: url.path) else { throw BotStoreError.notFound(id) }
        var bot = try JSONCoding.decoder().decode(Bot.self, from: Data(contentsOf: url))
        bot.id = id // the folder name is the source of truth
        return bot
    }

    // MARK: Writing

    @discardableResult
    public func create(
        name: String, emoji: String = "🤖", colour: String = BotPalette.default, role: String = "",
        engine: BotEngine = .claude, model: String? = nil,
        permission: PermissionLevel = .editWorkspace, instructions: String? = nil
    ) throws -> Bot {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BotStoreError.emptyName }
        try paths.ensureStructure(fileManager: fm)

        let taken = Set((try? fm.contentsOfDirectory(atPath: paths.bots.path)) ?? [])
        let id = Slug.unique(trimmed, taken: taken)
        let bot = Bot(
            id: id, name: trimmed, emoji: emoji, colour: colour,
            role: role.trimmingCharacters(in: .whitespacesAndNewlines), engine: engine,
            model: model, permission: permission
        )
        try fm.createDirectory(at: paths.workspace(id), withIntermediateDirectories: true)
        try save(bot)
        try setInstructions(instructions ?? Instructions.defaultText(for: bot), for: id)
        try Data(Instructions.notesTemplate(for: bot).utf8).write(to: paths.notesMD(id), options: .atomic)
        return bot
    }

    public func save(_ bot: Bot) throws {
        try fm.createDirectory(at: paths.botDir(bot.id), withIntermediateDirectories: true)
        let data = try JSONCoding.encoder().encode(bot)
        try data.write(to: paths.botJSON(bot.id), options: .atomic)
    }

    /// Moves the bot folder to the Trash where possible, so nothing is lost by accident.
    public func delete(id: String) throws {
        let dir = paths.botDir(id)
        #if os(macOS)
        try fm.trashItem(at: dir, resultingItemURL: nil)
        #else
        try fm.removeItem(at: dir)
        #endif
    }

    // MARK: Instructions (CLAUDE.md <-> AGENTS.md)

    /// The bot's instructions, from whichever of CLAUDE.md / AGENTS.md was edited last.
    public func instructions(for id: String) -> String {
        let newest = newestInstructionsFile(id)
        return (try? String(contentsOf: newest ?? paths.claudeMD(id), encoding: .utf8)) ?? ""
    }

    public func setInstructions(_ text: String, for id: String) throws {
        let data = Data(text.utf8)
        try data.write(to: paths.claudeMD(id), options: .atomic)
        try data.write(to: paths.agentsMD(id), options: .atomic)
    }

    /// Keeps CLAUDE.md and AGENTS.md identical: the most recently edited one wins.
    /// Returns true if a file was rewritten.
    @discardableResult
    public func syncInstructions(for id: String) -> Bool {
        let claude = paths.claudeMD(id)
        let agents = paths.agentsMD(id)
        let claudeText = try? String(contentsOf: claude, encoding: .utf8)
        let agentsText = try? String(contentsOf: agents, encoding: .utf8)

        switch (claudeText, agentsText) {
        case (nil, nil):
            return false
        case (let c?, nil):
            try? Data(c.utf8).write(to: agents, options: .atomic)
            return true
        case (nil, let a?):
            try? Data(a.utf8).write(to: claude, options: .atomic)
            return true
        case (let c?, let a?):
            if c == a { return false }
            let source = newestInstructionsFile(id) ?? claude
            let text = source == claude ? c : a
            let target = source == claude ? agents : claude
            try? Data(text.utf8).write(to: target, options: .atomic)
            return true
        }
    }

    private func newestInstructionsFile(_ id: String) -> URL? {
        let candidates = [paths.claudeMD(id), paths.agentsMD(id)]
        return candidates
            .compactMap { url -> (URL, Date)? in
                guard let d = modificationDate(url) else { return nil }
                return (url, d)
            }
            .max { $0.1 < $1.1 }?.0
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

public enum Instructions {
    public static func defaultText(for bot: Bot) -> String {
        let role = bot.role.isEmpty ? "a helpful teammate" : bot.role
        return """
        # \(bot.emoji) \(bot.name)

        You are **\(bot.name)**, \(role) on my personal AI team in Launchpad.
        I talk to you in a chat app, like a colleague.

        ## How you work
        - Do your work inside `./workspace/`. Create projects and files there.
        - `./notes.md` is your memory. Read it when you start a task. Add short notes about
          decisions, my preferences and anything worth remembering next time.
        - Reply like a friendly colleague: clear and brief. Use markdown, and code blocks for code.
        - If something important is unclear, ask me one focused question.
        - Never put passwords, API keys or tokens in files, logs or chat.

        ## Your role
        \(bot.role.isEmpty ? "General help with whatever I ask." : bot.role)

        """
    }

    public static func notesTemplate(for bot: Bot) -> String {
        """
        # \(bot.name)'s notes

        My own memory. I keep it short and up to date.

        """
    }
}
