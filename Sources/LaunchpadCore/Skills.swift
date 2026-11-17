import Foundation

/// A skill: skills/<id>/SKILL.md with a small front matter (name, description) and markdown body.
public struct Skill: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    /// The whole SKILL.md, front matter included.
    public var text: String
    public var updatedAt: Date

    public var body: String { SkillFile.parse(text).body }
}

public enum SkillFile {
    public struct Parsed: Equatable {
        public var name: String?
        public var description: String?
        public var body: String
    }

    /// Reads `---\nname: x\ndescription: y\n---\nbody`.
    public static func parse(_ text: String) -> Parsed {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else { return Parsed(name: nil, description: nil, body: normalized) }
        let rest = normalized.dropFirst(4)
        guard let end = rest.range(of: "\n---") else { return Parsed(name: nil, description: nil, body: normalized) }
        var name: String?
        var description: String?
        for line in rest[rest.startIndex..<end.lowerBound].split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let f = value.first, (f == "\"" || f == "'"), value.last == f {
                value = String(value.dropFirst().dropLast())
            }
            if key == "name" { name = value }
            if key == "description" { description = value }
        }
        var body = String(rest[end.upperBound...])
        if let nl = body.firstIndex(of: "\n") { body = String(body[body.index(after: nl)...]) } else { body = "" }
        return Parsed(name: name, description: description, body: body.trimmingCharacters(in: .newlines))
    }

    public static func compose(name: String, description: String, body: String) -> String {
        """
        ---
        name: \(oneLine(name))
        description: \(oneLine(description))
        ---

        \(body.trimmingCharacters(in: .whitespacesAndNewlines))

        """
    }

    private static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }
}

public final class SkillStore: @unchecked Sendable {
    public let paths: LaunchpadPaths
    private let fm: FileManager

    public init(paths: LaunchpadPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fm = fileManager
    }

    public func file(_ id: String) -> URL { paths.skills.appendingPathComponent(id).appendingPathComponent("SKILL.md") }
    public func folder(_ id: String) -> URL { paths.skills.appendingPathComponent(id, isDirectory: true) }

    public func loadAll() -> [Skill] {
        guard let ids = try? fm.contentsOfDirectory(atPath: paths.skills.path) else { return [] }
        return ids.filter { !$0.hasPrefix(".") }.compactMap { load(id: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func load(id: String) -> Skill? {
        let url = file(id)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let parsed = SkillFile.parse(text)
        let date = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? Date()
        return Skill(id: id, name: parsed.name ?? id, description: parsed.description ?? "", text: text, updatedAt: date)
    }

    @discardableResult
    public func create(name: String, description: String, body: String) throws -> Skill {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BotStoreError.emptyName }
        try paths.ensureStructure(fileManager: fm)
        let taken = Set((try? fm.contentsOfDirectory(atPath: paths.skills.path)) ?? [])
        let id = Slug.unique(trimmed, taken: taken)
        try save(id: id, text: SkillFile.compose(name: id, description: description, body: body))
        return load(id: id)!
    }

    public func save(id: String, text: String) throws {
        try fm.createDirectory(at: folder(id), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file(id), options: .atomic)
    }

    @discardableResult
    public func duplicate(id: String) throws -> Skill {
        guard let original = load(id: id) else { throw BotStoreError.notFound(id) }
        let taken = Set((try? fm.contentsOfDirectory(atPath: paths.skills.path)) ?? [])
        let newId = Slug.unique("\(id)-copy", taken: taken)
        let parsed = SkillFile.parse(original.text)
        try save(id: newId, text: SkillFile.compose(name: newId, description: parsed.description ?? "", body: parsed.body))
        return load(id: newId)!
    }

    public func delete(id: String) throws {
        #if os(macOS)
        try fm.trashItem(at: folder(id), resultingItemURL: nil)
        #else
        try fm.removeItem(at: folder(id))
        #endif
    }

    /// Adds the starter skills the first time Launchpad runs (and never again, so deleting one sticks).
    public func seedStarterSkillsIfNeeded() {
        let marker = paths.root.appendingPathComponent(".launchpad/seeded-skills")
        guard !fm.fileExists(atPath: marker.path) else { return }
        for starter in StarterSkills.all where !fm.fileExists(atPath: file(starter.id).path) {
            try? save(id: starter.id, text: SkillFile.compose(name: starter.id, description: starter.description, body: starter.body))
        }
        try? fm.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("1\n".utf8).write(to: marker)
    }
}

/// Puts each bot's skills where Claude Code (.claude/skills) and Codex (.agents/skills, .codex/skills)
/// look for them, as symlinks back to the library, so edits show up everywhere.
public struct SkillLinker {
    public static let linkFolders = [".claude/skills", ".agents/skills", ".codex/skills"]
    let paths: LaunchpadPaths
    let fm = FileManager.default

    public init(paths: LaunchpadPaths) {
        self.paths = paths
    }

    /// The skills a bot gets: its own plus those of every group it's in.
    public static func effectiveSkills(for bot: Bot, groups: [BotGroup]) -> [String] {
        var out = bot.skills
        for group in groups where group.members.contains(bot.id) || group.lead == bot.id {
            out += group.skills
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    public func link(botId: String, skills: [String]) {
        let wanted = Set(skills.filter { fm.fileExists(atPath: paths.skills.appendingPathComponent($0).appendingPathComponent("SKILL.md").path) })
        let libraryRoot = paths.skills.resolvingSymlinksInPath().path
        for folder in Self.linkFolders {
            let dir = paths.botDir(botId).appendingPathComponent(folder, isDirectory: true)
            // Remove links we made that are no longer wanted. Never touch real folders.
            if let entries = try? fm.contentsOfDirectory(atPath: dir.path) {
                for name in entries {
                    let url = dir.appendingPathComponent(name)
                    guard let dest = try? fm.destinationOfSymbolicLink(atPath: url.path) else { continue }
                    let resolved = URL(fileURLWithPath: dest).resolvingSymlinksInPath().path
                    let ours = resolved.hasPrefix(libraryRoot) || dest.hasPrefix(paths.skills.path)
                    if ours && (!wanted.contains(name) || !fm.fileExists(atPath: url.path)) {
                        try? fm.removeItem(at: url)
                    }
                }
            }
            guard !wanted.isEmpty else { continue }
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for id in wanted {
                let link = dir.appendingPathComponent(id)
                if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil || fm.fileExists(atPath: link.path) { continue }
                try? fm.createSymbolicLink(at: link, withDestinationURL: paths.skills.appendingPathComponent(id, isDirectory: true))
            }
        }
    }
}

/// "Teach a skill from this chat": the prompt and the clean-up of the answer.
public enum SkillTeacher {
    public static func transcript(_ messages: [ChatMessage], botName: (String?) -> String, limit: Int = 30) -> String {
        messages.suffix(limit).compactMap { m -> String? in
            switch m.role {
            case .notice: return nil
            case .user: return "### Me\n\(m.text)"
            case .bot:
                var s = "### \(botName(m.botId))\n\(m.text)"
                if !m.steps.isEmpty {
                    s += "\n\nSteps taken:\n" + m.steps.map { "- \($0.title)" + ($0.detail.map { ": " + ToolSummary.short($0.replacingOccurrences(of: "\n", with: " "), max: 200) } ?? "") }.joined(separator: "\n")
                }
                return s
            }
        }.joined(separator: "\n\n")
    }

    public static func prompt(transcript: String) -> String {
        """
        Below is a chat where an AI teammate did a task. Turn what it did into a reusable skill, \
        so any teammate can do the same kind of task well next time.

        Write a SKILL.md file and output ONLY its contents, nothing before or after:
        - Start with front matter: `name:` (short, lowercase-with-dashes) and `description:` \
        (one sentence saying when to use this skill).
        - Then a markdown body: when to use it, the steps in order, commands or code that matter, \
        checks to make sure it worked, and pitfalls seen in the chat.
        - Keep it general (no one-off names or paths unless they always apply). Never include secrets.

        Chat:

        \(transcript)
        """
    }

    /// Strips a ```markdown fence or chatter around the SKILL.md the model returned.
    public static func cleanDraft(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
            if let close = text.range(of: "```", options: .backwards) { text = String(text[..<close.lowerBound]) }
        } else if let start = text.range(of: "---\nname:") {
            text = String(text[start.lowerBound...])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}

public enum StarterSkills {
    public struct Starter {
        public let id: String
        public let description: String
        public let body: String
    }

    public static let all: [Starter] = [
        Starter(id: "new-project", description: "Use when starting a new app or project from scratch.", body: """
        # New project

        ## Steps
        1. Agree the goal in one sentence and the smallest version worth shipping.
        2. Pick the stack. Default for web apps: Next.js (App Router, TypeScript), Tailwind, Supabase, Vercel.
        3. Create the project in the shared workspace folder, e.g. `npx create-next-app@latest <name> --ts --tailwind --eslint --app --use-npm`.
        4. Initialise git and make a first commit.
        5. Add a README with: what it is, how to run it, environment variables needed (names only).
        6. Add `.env.example` with variable names and no values. Make sure `.env*` is in `.gitignore`.
        7. Run it locally (`npm run dev`) and check the home page loads.

        ## Done when
        - It runs locally with one command.
        - README explains setup. No secrets in the repo.
        """),
        Starter(id: "deploy", description: "Use when deploying a web app to Vercel (preview or production).", body: """
        # Deploy to Vercel

        Deploying needs approval first. Ask with `[[approve: deploy <app> to <preview/production>]]` and wait.

        ## Steps
        1. Make sure it builds: `npm run build`. Fix errors before deploying.
        2. Check environment variables the app needs exist in Vercel: `vercel env ls`. Add missing ones with `vercel env add` (ask me for values; never paste secrets into chat or files).
        3. Link the project if needed: `vercel link --yes`.
        4. Preview deploy: `vercel deploy --yes`. Production: `vercel deploy --prod --yes`.
        5. Open the URL it prints and check the main pages load and sign-in works.
        6. Reply with the live URL and anything that didn't work.

        ## Pitfalls
        - Supabase auth: add the deployed URL to Supabase Auth redirect URLs.
        - Google sign-in: add the deployed URL to the Google OAuth client's authorised redirect URIs.
        """),
        Starter(id: "code-review", description: "Use when reviewing a change, branch or project for bugs and risks.", body: """
        # Code review

        ## Steps
        1. Read what the change is meant to do.
        2. Look at the diff (`git diff main...HEAD` or the files named).
        3. Check, in order: correctness and edge cases; security (auth checks, RLS, secrets, input validation); data loss; error handling; tests; readability.
        4. Run the tests and the build if you can.

        ## Reply with
        - A one-line verdict: ship / ship after fixes / don't ship.
        - Findings ranked by severity, each with file:line, what's wrong, and a suggested fix.
        - Keep nitpicks separate and short.
        """),
        Starter(id: "write-spec", description: "Use when turning an idea into a short product spec before building.", body: """
        # Write a spec

        Write `SPEC.md` in the project folder.

        ## Sections
        1. **Goal**: one paragraph. Who it's for and the problem it solves.
        2. **Must have**: the smallest set of features for a first version.
        3. **Not now**: things deliberately left out.
        4. **User flows**: step by step for the main 2–3 journeys.
        5. **Data**: tables/entities and who can see or change each (for Supabase: RLS rules).
        6. **Pages/screens**: list with a line on each.
        7. **Done means**: checks that prove it works.
        8. **Open questions**: things to ask me.

        Keep it to about one page. Plain words.
        """),
    ]
}
