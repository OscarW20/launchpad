import Foundation

/// One change a memory review made, for the "Memory updated" notice in the chat and its Undo button.
/// `id` is also the id of that notice message, so the app can find the update from the message.
public struct MemoryUpdate: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var botId: String
    public var chatId: String?
    /// The version saved just before this update (what MEMORY.md said then).
    public var version: String
    /// The lines it added or rewrote.
    public var added: [String]
    public var date: Date
    public var undone: Bool

    public init(id: String = UUID().uuidString.lowercased(), botId: String, chatId: String?, version: String,
                added: [String], date: Date, undone: Bool = false) {
        self.id = id
        self.botId = botId
        self.chatId = chatId
        self.version = version
        self.added = added
        self.date = date
        self.undone = undone
    }

    /// "Memory updated: Prefers British spelling; Ana runs QA"
    public var summary: String {
        let shown = added.prefix(3).map { MemoryBook.shorten($0, to: 60) }.joined(separator: "; ")
        let more = added.count > 3 ? " (+\(added.count - 3) more)" : ""
        return "Memory updated: \(shown)\(more)"
    }
}

public enum MemoryEditResult: Equatable, Sendable {
    case saved
    /// Nothing to change (an empty line, a duplicate, or the same text).
    case unchanged
    /// It looks like a password, key or token, so it isn't written to memory.
    case secret
    /// MEMORY.md exists but isn't UTF-8 / UTF-16 text, so it's never written over.
    case unreadable
    /// The line isn't there any more (the bot or a review changed the file).
    case notFound
}

/// Reads and writes bots' MEMORY.md. Every write from the app (reviews, Undo, the editor) re-reads the file first,
/// keeps the version from before it, and runs one at a time, so none of them writes over another's change.
/// A file that can't be decoded is never written over.
public final class MemoryStore: @unchecked Sendable {
    public let paths: LaunchpadPaths
    /// One memory write at a time across the app.
    private static let lock = NSRecursiveLock()
    /// The update log keeps this many entries (newest).
    static let logLimit = 200

    public init(paths: LaunchpadPaths) {
        self.paths = paths
    }

    public func file(_ botId: String) -> URL { paths.memoryMD(botId) }
    public func historyFolder(_ botId: String) -> URL { paths.memoryData(botId).appendingPathComponent("history", isDirectory: true) }
    var updatesFile: URL { paths.root.appendingPathComponent(".launchpad/memory/updates.json") }
    /// Where an imported notes.md is kept (and the sign that the import has happened).
    public func importedNotes(_ botId: String) -> URL { paths.memoryData(botId).appendingPathComponent("notes-imported.md") }

    private func locked<T>(_ body: () -> T) -> T {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return body()
    }

    // MARK: Reading

    public func read(_ botId: String) -> MemoryBook.ReadResult { MemoryBook.read(file(botId)) }

    /// The editor's view: topics and their lines. Nil when the file can't be decoded.
    public func outline(_ botId: String) -> [MemoryBook.OutlineTopic]? {
        read(botId).usable.map(MemoryBook.outline)
    }

    public func versions(_ botId: String) -> [MemoryHistory.Version] { MemoryHistory.versions(historyFolder(botId)) }

    public func version(_ name: String, botId: String) -> String? { MemoryHistory.read(name, in: historyFolder(botId)) }

    // MARK: notes.md → MEMORY.md (once)

    public enum NotesImport: Equatable, Sendable {
        /// Nothing to do (no notes.md, or already imported).
        case none
        case imported
        /// notes.md or MEMORY.md can't be decoded: both are left as they are.
        case unreadable
    }

    /// Moves an old notes.md into MEMORY.md, once per bot: its text goes under "## From notes.md" (an empty
    /// starter notes.md adds nothing), the original is kept in the app's memory folder, and the bot's
    /// CLAUDE.md / AGENTS.md are pointed at MEMORY.md. Call it when bots load.
    @discardableResult
    public func importNotesIfNeeded(_ bot: Bot, now: Date = Date()) -> NotesImport {
        locked {
            let fm = FileManager.default
            let notesURL = paths.notesMD(bot.id)
            guard fm.fileExists(atPath: notesURL.path), !fm.fileExists(atPath: importedNotes(bot.id).path) else { return .none }
            guard let notes = MemoryBook.read(notesURL).usable, let current = read(bot.id).usable else { return .unreadable }

            let body = Self.notesBody(notes, botName: bot.name)
            var text = current
            if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = Instructions.memoryTemplate(for: bot)
            }
            if !body.isEmpty {
                let startsWithHeading = body.hasPrefix("## ") || body.hasPrefix("### ")
                text = text.trimmingCharacters(in: .newlines) + "\n\n" + (startsWithHeading ? "" : "## From notes.md\n") + body + "\n"
            }
            if text != current {
                guard commit(bot.id, before: current, after: text, now: now) != nil else { return .unreadable }
            }
            try? fm.createDirectory(at: paths.memoryData(bot.id), withIntermediateDirectories: true)
            if (try? fm.moveItem(at: notesURL, to: importedNotes(bot.id))) == nil {
                try? Data(notes.utf8).write(to: importedNotes(bot.id), options: .atomic)
            }
            let store = BotStore(paths: paths)
            let instructions = store.instructions(for: bot.id)
            let pointed = Instructions.pointingAtMemory(instructions)
            if pointed != instructions { try? store.setInstructions(pointed, for: bot.id) }
            return .imported
        }
    }

    /// notes.md without the starter heading and line Launchpad used to write.
    static func notesBody(_ notes: String, botName: String) -> String {
        var lines = MemoryBook.stripBOM(notes).replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let starter: Set<String> = ["# \(botName)'s notes", "My own memory. I keep it short and up to date."]
        lines.removeAll { starter.contains($0.trimmingCharacters(in: .whitespaces)) }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Reviews

    /// Merges a review into MEMORY.md, keeping the version from before it (and what it wrote, for Undo), and logs it.
    /// Nil when nothing changed or the file can't be read (it's never written over then).
    public func applyReview(botId: String, chatId: String?, facts: [MemoryBook.Fact], condense: [MemoryBook.Condense] = [],
                            now: Date = Date()) -> MemoryUpdate? {
        locked {
            guard let before = read(botId).usable else { return nil }
            let result = MemoryBook.merge(before, facts: facts, condense: condense)
            guard result.changed, let version = commit(botId, before: before, after: result.text, now: now) else { return nil }
            let update = MemoryUpdate(botId: botId, chatId: chatId, version: version, added: result.added, date: now)
            var log = updates()
            log.append(update)
            saveUpdates(log)
            return update
        }
    }

    /// Every logged update, oldest first.
    public func updates() -> [MemoryUpdate] {
        guard let data = try? Data(contentsOf: updatesFile) else { return [] }
        return (try? JSONCoding.decoder().decode([MemoryUpdate].self, from: data)) ?? []
    }

    public func update(id: String) -> MemoryUpdate? { updates().last { $0.id == id } }

    private func saveUpdates(_ list: [MemoryUpdate]) {
        try? FileManager.default.createDirectory(at: updatesFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONCoding.encoder().encode(Array(list.suffix(Self.logLimit))) {
            try? data.write(to: updatesFile, options: .atomic)
        }
    }

    /// Versions an update that hasn't been undone still points at (pruning keeps them).
    func protectedVersions(_ botId: String) -> Set<String> {
        Set(updates().filter { $0.botId == botId && !$0.undone }.map(\.version))
    }

    /// MEMORY.md with just this update taken back: what it added comes out, what it folded or replaced goes back.
    /// Everything else (later updates, the bot's own notes, your edits) stays. `count` 0 = nothing left to undo.
    func undone(_ update: MemoryUpdate, current: String) -> (text: String, count: Int) {
        let dir = historyFolder(update.botId)
        if let before = MemoryHistory.read(update.version, in: dir), let after = MemoryHistory.readAfter(update.version, in: dir) {
            return MemoryBook.applyChanges(from: after, to: before, onto: current)
        }
        return MemoryBook.removing(update.added, from: current)
    }

    /// How many lines Undo would change now (0: nothing left to undo; nil: the file can't be read).
    public func undoCount(_ update: MemoryUpdate) -> Int? {
        guard !update.undone, let current = read(update.botId).usable else { return update.undone ? 0 : nil }
        return undone(update, current: current).count
    }

    /// Takes one update back. Returns how many lines changed (0: nothing to undo, nil: couldn't).
    @discardableResult
    public func undo(_ update: MemoryUpdate, now: Date = Date()) -> Int? {
        locked {
            guard let current = read(update.botId).usable else { return nil }
            let result = undone(update, current: current)
            guard result.count > 0 else { return 0 }
            guard commit(update.botId, before: current, after: result.text, now: now) != nil else { return nil }
            var log = updates()
            for i in log.indices where log[i].id == update.id { log[i].undone = true }
            saveUpdates(log)
            return result.count
        }
    }

    // MARK: Editor

    /// The editor's Save for the whole file. `original` is what the editor opened; if the file changed since
    /// (a review, the bot's own note), that change is carried onto your edit instead of being written over. With
    /// `replaceAll` (Forget everything, or going back to an earlier version) your text is written as it is.
    @discardableResult
    public func save(_ value: String, original: String, botId: String, replaceAll: Bool = false, now: Date = Date()) -> MemoryEditResult {
        locked {
            guard let disk = read(botId).usable else { return .unreadable }
            var final = value
            if !replaceAll, disk != original { final = MemoryBook.applyChanges(from: original, to: disk, onto: value).text }
            guard final != disk else { return .unchanged }
            return commit(botId, before: disk, after: final, now: now) != nil ? .saved : .unreadable
        }
    }

    /// Adds a line under `topic` (a review topic or a heading of your own).
    @discardableResult
    public func addEntry(_ text: String, topic: String, botId: String, now: Date = Date()) -> MemoryEditResult {
        if MemoryBook.containsSecret(text) { return .secret }
        return locked {
            guard let disk = read(botId).usable else { return .unreadable }
            let r = MemoryBook.addEntry(text, topic: topic, to: disk)
            guard r.changed else { return .unchanged }
            return commit(botId, before: disk, after: r.text, now: now) != nil ? .saved : .unreadable
        }
    }

    /// Rewrites one line. `expecting` is the line's text as the editor showed it: if the file moved on, the line is
    /// found by its text instead.
    @discardableResult
    public func editEntry(at position: MemoryBook.LinePosition, expecting: String, to value: String, botId: String,
                          now: Date = Date()) -> MemoryEditResult {
        if MemoryBook.containsSecret(value) { return .secret }
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return deleteEntry(at: position, expecting: expecting, botId: botId, now: now)
        }
        return change(at: position, expecting: expecting, to: value, botId: botId, now: now)
    }

    @discardableResult
    public func deleteEntry(at position: MemoryBook.LinePosition, expecting: String, botId: String, now: Date = Date()) -> MemoryEditResult {
        change(at: position, expecting: expecting, to: "", botId: botId, now: now)
    }

    private func change(at position: MemoryBook.LinePosition, expecting: String, to value: String, botId: String, now: Date) -> MemoryEditResult {
        locked {
            guard let disk = read(botId).usable else { return .unreadable }
            guard let pos = Self.locate(expecting, near: position, in: disk) else { return .notFound }
            let out = MemoryBook.editLine(disk, at: pos, to: value).text
            guard out != MemoryBook.Doc(disk).text else { return .unchanged }
            return commit(botId, before: disk, after: out, now: now) != nil ? .saved : .unreadable
        }
    }

    /// The line at `position` if it still says `expecting`, else the first line that does.
    static func locate(_ expecting: String, near position: MemoryBook.LinePosition, in text: String) -> MemoryBook.LinePosition? {
        let doc = MemoryBook.Doc(text)
        let want = MemoryBook.entryText(expecting)
        if doc.sections.indices.contains(position.section), doc.sections[position.section].lines.indices.contains(position.line),
           MemoryBook.entryText(doc.sections[position.section].lines[position.line]) == want {
            return position
        }
        for si in doc.sections.indices {
            for li in doc.sections[si].entryIndexes where MemoryBook.entryText(doc.sections[si].lines[li]) == want {
                return MemoryBook.LinePosition(section: si, line: li)
            }
        }
        return nil
    }

    /// Whether "Undo last change" has anything to go back to.
    public func canUndoLastChange(_ botId: String) -> Bool { !versions(botId).isEmpty }

    /// Takes back the most recent change the app made to MEMORY.md (a review, an Undo, or an edit), keeping any
    /// lines written since by someone else (the bot itself). Each call goes one change further back.
    /// Returns how many lines changed (0: nothing to undo; nil: the file can't be read).
    @discardableResult
    public func undoLastChange(_ botId: String) -> Int? {
        locked {
            guard let current = read(botId).usable else { return nil }
            let dir = historyFolder(botId)
            for v in versions(botId) {
                guard let before = MemoryHistory.read(v.id, in: dir) else { MemoryHistory.remove(v.id, in: dir); continue }
                let result: (text: String, count: Int)
                if let after = MemoryHistory.readAfter(v.id, in: dir) {
                    result = MemoryBook.applyChanges(from: after, to: before, onto: current)
                } else {
                    result = (before, before == current ? 0 : 1)
                }
                MemoryHistory.remove(v.id, in: dir)
                var log = updates()
                for i in log.indices where log[i].botId == botId && log[i].version == v.id { log[i].undone = true }
                saveUpdates(log)
                guard result.count > 0 else { continue }   // already taken back by hand: look further back
                guard write(result.text, botId: botId) else { return nil }
                return result.count
            }
            return 0
        }
    }

    // MARK: Writing

    /// Keeps `before` as a version (and `after` alongside it, for Undo), then writes `after`.
    /// Returns the version's name, or nil when nothing could be written.
    private func commit(_ botId: String, before: String, after: String, now: Date) -> String? {
        let dir = historyFolder(botId)
        guard let version = MemoryHistory.save(before, in: dir, now: now, protecting: protectedVersions(botId)) else { return nil }
        MemoryHistory.saveAfter(after, version: version, in: dir)
        guard write(after, botId: botId) else {
            MemoryHistory.remove(version, in: dir)
            return nil
        }
        return version
    }

    private func write(_ text: String, botId: String) -> Bool {
        let url = file(botId)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Forget everything: an empty file reads the same as a missing one.
            return (try? Data().write(to: url, options: .atomic)) != nil
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? Data(text.utf8).write(to: url, options: .atomic)) != nil
    }
}
