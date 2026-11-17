import Foundation

/// Graphify (github.com/Graphify-Labs/graphify) turns a project into a knowledge graph bots can
/// query instead of grepping. Launchpad imports its official skill into the skill library.
///
/// We run `graphify install --project` in a scratch folder and copy only the skill
/// (SKILL.md + references/). Its always-on hooks and CLAUDE.md section are left out, so a bot's
/// own instructions stay its own.
public enum Graphify {
    public static let skillId = "graphify"
    public static let command = "graphify"
    /// What to run in Terminal if it isn't installed (needs Python 3.11+ with uv or pipx).
    public static let installCommand = "(command -v uv >/dev/null && uv tool install graphifyy) || pipx install graphifyy"

    public enum ImportError: Error, LocalizedError {
        case installFailed(String)
        case skillMissing

        public var errorDescription: String? {
            switch self {
            case .installFailed(let output): return "Graphify's installer didn't finish: \(output)"
            case .skillMissing: return "Graphify installed, but its skill wasn't where Launchpad expected it."
            }
        }
    }

    /// Imports (or refreshes) the graphify skill into ~/Launchpad/skills/graphify.
    public static func importSkill(executable: URL, paths: LaunchpadPaths, environment: [String: String]) throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("launchpad-graphify-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        let p = Process()
        p.executableURL = executable
        p.arguments = ["install", "--project"]
        p.currentDirectoryURL = scratch
        p.environment = environment
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw ImportError.installFailed(String(output.suffix(400)).trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let candidates = [".claude/skills/graphify", ".agents/skills/graphify"].map { scratch.appendingPathComponent($0) }
        guard let source = candidates.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("SKILL.md").path) }) else {
            throw ImportError.skillMissing
        }
        try paths.ensureStructure()
        let dest = paths.skills.appendingPathComponent(skillId, isDirectory: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: source, to: dest)
    }
}
