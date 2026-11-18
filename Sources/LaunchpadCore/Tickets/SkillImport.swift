import Foundation

// Bringing a skill that lives elsewhere on this Mac (a Claude plugin, ~/.claude/skills) into Launchpad's skills
// library. The ticket-writing skill is company process, so it's copied from where it is at run time rather than
// shipped inside this (public) repository.

public enum SkillImportError: Error, LocalizedError, Equatable {
    case noSkillFile(String)
    case unsafe(String)
    case tooLarge
    case taken(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .noSkillFile(let folder): return "There's no SKILL.md in \(folder)."
        case .unsafe(let what): return "Launchpad won't import this skill: \(what)."
        case .tooLarge: return "This skill folder is too big to import (more than \(SkillImport.maxFiles) files or \(SkillImport.maxBytes / 1_000_000) MB)."
        case .taken(let id): return "There's already a different skill called \"\(id)\" in your library, so it wasn't replaced. Delete it in Skills first if you want this one."
        case .notFound(let id): return "Couldn't find a \"\(id)\" skill on this Mac. Copy its folder (the one with SKILL.md in it) into ~/Launchpad/skills, then try again."
        }
    }
}

public enum SkillImportResult: Equatable {
    case installed(Skill)
    /// The same skill was already in the library; nothing was changed.
    case alreadyInstalled(Skill)

    public var skill: Skill {
        switch self {
        case .installed(let s), .alreadyInstalled(let s): return s
        }
    }
}

public enum SkillImport {
    public static let maxFiles = 100
    public static let maxBytes = 2_000_000
    public static let maxDepth = 3
}

extension SkillStore {
    /// Copies a skill folder (its SKILL.md and any files under it, such as references/) into the library.
    /// - Never replaces a skill: one with the same name and the same SKILL.md is left alone, a different one throws.
    /// - Copies regular files only; a link, an oversized folder or a built-in name is refused.
    /// - All or nothing: it's copied into a hidden folder first and moved into place when complete.
    @discardableResult
    public func importSkill(from directory: URL, as name: String? = nil) throws -> SkillImportResult {
        let fm = FileManager.default
        let source = directory.standardizedFileURL
        let main = source.appendingPathComponent("SKILL.md")
        guard Self.isRegularFile(main) else { throw SkillImportError.noSkillFile(source.path) }
        let id = try SkillCapture.skillId(name ?? source.lastPathComponent)
        guard !SkillCapture.isBuiltIn(id) else { throw SkillCaptureError.builtIn(id) }

        let incoming = try String(contentsOf: main, encoding: .utf8)
        if let existing = load(id: id) {
            if existing.text == incoming { return .alreadyInstalled(existing) }
            throw SkillImportError.taken(id)
        }

        var files: [(from: URL, relative: String)] = []
        var total = 0
        try Self.collect(source, relative: "", depth: 0, into: &files, bytes: &total)
        try paths.ensureStructure()
        let temp = paths.skills.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        do {
            for file in files {
                let dest = temp.appendingPathComponent(file.relative)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: file.from, to: dest)
            }
            try fm.moveItem(at: temp, to: folder(id))
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        guard let saved = load(id: id) else { throw SkillImportError.notFound(id) }
        return .installed(saved)
    }

    static func isRegularFile(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        return attributes[.type] as? FileAttributeType == .typeRegular
    }

    private static func collect(_ dir: URL, relative: String, depth: Int, into files: inout [(from: URL, relative: String)], bytes: inout Int) throws {
        guard depth <= SkillImport.maxDepth else { throw SkillImportError.tooLarge }
        let fm = FileManager.default
        for name in try fm.contentsOfDirectory(atPath: dir.path).sorted() where !name.hasPrefix(".") {
            let url = dir.appendingPathComponent(name)
            let rel = relative.isEmpty ? name : relative + "/" + name
            let type = (try? fm.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
            switch type {
            case .typeRegular:
                bytes += ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
                files.append((url, rel))
                if files.count > SkillImport.maxFiles || bytes > SkillImport.maxBytes { throw SkillImportError.tooLarge }
            case .typeDirectory:
                try collect(url, relative: rel, depth: depth + 1, into: &files, bytes: &bytes)
            default:
                throw SkillImportError.unsafe("\"\(rel)\" is a link or another kind of file, not a plain file")
            }
        }
    }
}

/// Where a skill that's already on this Mac might be.
public enum SkillSources {
    /// Folders named `name` (with a SKILL.md) in the places Claude keeps skills, newest first.
    public static func find(named name: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let fm = FileManager.default
        guard let id = try? SkillCapture.skillId(name) else { return [] }
        var roots: [URL] = [home.appendingPathComponent(".claude/skills", isDirectory: true)]
        func children(_ url: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
                .map { url.appendingPathComponent($0, isDirectory: true) }
        }
        roots += children(home.appendingPathComponent(".claude/skills/synced", isDirectory: true))
        let plugins = home.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions/skills-plugin", isDirectory: true)
        for account in children(plugins) {
            for org in children(account) { roots.append(org.appendingPathComponent("skills", isDirectory: true)) }
        }
        let found = roots.map { $0.appendingPathComponent(id, isDirectory: true) }
            .filter { SkillStore.isRegularFile($0.appendingPathComponent("SKILL.md")) }
        func modified(_ url: URL) -> Date {
            ((try? fm.attributesOfItem(atPath: url.appendingPathComponent("SKILL.md").path))?[.modificationDate] as? Date) ?? .distantPast
        }
        return found.sorted { modified($0) > modified($1) }
    }
}

extension SkillStore {
    /// Makes sure the ticket-writing skill is in the library, copying it from the newest place it's found on this
    /// Mac if it isn't. Throws `SkillImportError.notFound` (with what to copy) when it's nowhere.
    @discardableResult
    public func ensureTicketSkill(settings: TicketSettings, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> SkillImportResult {
        if let existing = load(id: settings.skillId) { return .alreadyInstalled(existing) }
        guard let source = SkillSources.find(named: settings.skillId, home: home).first else {
            throw SkillImportError.notFound(settings.skillId)
        }
        return try importSkill(from: source, as: settings.skillId)
    }
}
