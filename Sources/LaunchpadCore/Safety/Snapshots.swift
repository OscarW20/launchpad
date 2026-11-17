import Foundation

/// "Undo what a bot did": before each reply the bot's folder is snapshotted into a private git store
/// (`.launchpad/snapshots/<bot-id>.git`, separate from any repos the bot makes), so its file changes can be rolled back.
///
/// Not covered: files in git repos nested inside the bot's folder (git records them as one entry), files its
/// `.gitignore` leaves out, the instructions and memory files, and anything outside the bot's folder.
public final class Snapshots: @unchecked Sendable {
    public let paths: LaunchpadPaths
    public let git: URL?
    /// One git command at a time, so a reply's snapshot and the last reply's changes never fight over index.lock.
    private let serial = DispatchQueue(label: "launchpad.snapshots")

    /// Left out of snapshots: build output, engine config, and the files Launchpad itself manages.
    public static let excluded = ["node_modules/", ".build/", "*.zip", ".DS_Store", ".claude/", ".codex/", ".agents/",
                                  "AGENTS.md", "CLAUDE.md", "notes.md", "bot.json"]

    public init(paths: LaunchpadPaths, git: URL? = CLILocator().locate(command: "git")) {
        self.paths = paths
        self.git = git
    }

    public var available: Bool { git != nil }

    /// Records the bot's folder as it is now. Returns the snapshot id (keep it on the reply), or nil if git isn't
    /// installed, the folder is missing, or it took too long.
    public func take(botId: String, folder: URL) -> String? { serial.sync { takeNow(botId, folder) } }

    /// Files the reply added, changed or deleted since the snapshot (paths relative to the bot's folder).
    public func changes(botId: String, folder: URL, since snapshot: String) -> [String] {
        serial.sync { changesNow(botId, folder, snapshot) }
    }

    /// Puts the folder back the way it was at the snapshot: changed and deleted files come back, new files go.
    @discardableResult
    public func undo(botId: String, folder: URL, to snapshot: String) -> Bool { serial.sync { undoNow(botId, folder, snapshot) } }

    // MARK: -

    @discardableResult
    private func run(_ botId: String, _ work: URL, _ args: [String], timeout: TimeInterval = 15) -> (status: Int32, output: String)? {
        guard let git else { return nil }
        let base = ["--git-dir=\(paths.snapshotStore(botId).path)", "--work-tree=\(work.path)",
                    "-c", "user.name=Launchpad", "-c", "user.email=launchpad@localhost", "-c", "core.quotepath=off",
                    "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "core.autocrlf=false"]
        let p = Process()
        p.executableURL = git
        p.arguments = base + args
        p.currentDirectoryURL = work
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let buffer = LockedBuffer(limit: 4 * 1024 * 1024)
        let done = DispatchSemaphore(value: 0)
        EngineRunner.spawnThread {
            let h = out.fileHandleForReading
            while true {
                let chunk = h.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
            }
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            p.waitUntilExit()
            return nil
        }
        p.waitUntilExit()
        return (p.terminationStatus, buffer.string)
    }

    private func takeNow(_ botId: String, _ work: URL) -> String? {
        let fm = FileManager.default
        guard available, fm.fileExists(atPath: work.path) else { return nil }
        let dir = paths.snapshotStore(botId)
        if !fm.fileExists(atPath: dir.appendingPathComponent("HEAD").path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            guard run(botId, work, ["init", "-q"])?.status == 0 else { return nil }
        }
        try? fm.createDirectory(at: dir.appendingPathComponent("info"), withIntermediateDirectories: true)
        try? (Self.excluded.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("info/exclude"), atomically: true, encoding: .utf8)
        guard run(botId, work, ["add", "-A"], timeout: 30)?.status == 0,
              run(botId, work, ["commit", "-q", "--allow-empty", "--no-verify", "-m", "before reply"])?.status == 0,
              let head = run(botId, work, ["rev-parse", "HEAD"])?.output.trimmingCharacters(in: .whitespacesAndNewlines),
              !head.isEmpty else { return nil }
        return head
    }

    private func changesNow(_ botId: String, _ work: URL, _ snapshot: String) -> [String] {
        guard Self.isCommitId(snapshot), run(botId, work, ["add", "-A"], timeout: 30)?.status == 0,
              let out = run(botId, work, ["diff", "--cached", "--name-only", "--no-renames", snapshot])?.output else { return [] }
        return out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    private func undoNow(_ botId: String, _ work: URL, _ snapshot: String) -> Bool {
        guard Self.isCommitId(snapshot), run(botId, work, ["add", "-A"], timeout: 30)?.status == 0 else { return false }
        let added = run(botId, work, ["diff", "--cached", "--name-only", "--no-renames", "--diff-filter=A", snapshot])?.output
            .split(separator: "\n").map(String.init) ?? []
        let root = work.standardizedFileURL.path
        for path in added where !path.isEmpty {
            let url = work.appendingPathComponent(path).standardizedFileURL
            guard url.path.hasPrefix(root + "/") else { continue }
            try? FileManager.default.removeItem(at: url)
        }
        // Fails harmlessly when the snapshot had no files at all.
        let restored = run(botId, work, ["checkout", snapshot, "--", "."], timeout: 30)
        run(botId, work, ["reset", "-q"])
        return restored != nil
    }

    static func isCommitId(_ s: String) -> Bool {
        (7...64).contains(s.count) && s.allSatisfy { $0.isHexDigit }
    }
}
