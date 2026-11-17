import Foundation

/// Finds `claude` and `codex` the way your Terminal would.
///
/// Apps opened from the Dock don't get your shell's PATH, so we ask your login shell for it
/// once and also check the usual install places.
public final class CLILocator: @unchecked Sendable {
    private let fm = FileManager.default
    private let lock = NSLock()
    private var cachedPATH: String?
    private let overrides: [BotEngine: String]

    public init(overrides: [BotEngine: String] = [:]) {
        self.overrides = overrides
    }

    public func locate(_ engine: BotEngine) -> URL? {
        if let o = overrides[engine] { return fm.isExecutableFile(atPath: o) ? URL(fileURLWithPath: o) : nil }
        return locate(command: engine.executableName)
    }

    /// Finds any command-line tool the way your Terminal would (e.g. `graphify`).
    public func locate(command: String) -> URL? {
        for dir in searchDirectories() {
            let candidate = (dir as NSString).appendingPathComponent(command)
            if fm.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }

    /// The environment for engine processes: yours, with a PATH that can find node, git and friends.
    public func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        env["PATH"] = searchDirectories().joined(separator: ":")
        env["NO_COLOR"] = "1"
        return env
    }

    func searchDirectories() -> [String] {
        let home = fm.homeDirectoryForCurrentUser.path
        var dirs: [String] = []
        dirs += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += (loginShellPATH() ?? "").split(separator: ":").map(String.init)
        dirs += [
            "\(home)/.local/bin", "\(home)/.claude/local", "\(home)/.npm-global/bin",
            "\(home)/.bun/bin", "\(home)/.volta/bin", "\(home)/.cargo/bin",
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        dirs += nvmDirectories(home: home)
        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func nvmDirectories(home: String) -> [String] {
        let base = "\(home)/.nvm/versions/node"
        guard let versions = try? fm.contentsOfDirectory(atPath: base) else { return [] }
        return versions.sorted().reversed().map { "\(base)/\($0)/bin" }
    }

    /// Runs your login shell once to read its PATH (with a 5 second limit).
    func loginShellPATH() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cachedPATH { return cachedPATH }
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        guard fm.isExecutableFile(atPath: shell) else { cachedPATH = ""; return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "printf '__LP__%s__LP__' \"$PATH\""]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { cachedPATH = ""; return nil }

        // Read until we see the PATH between the markers. Don't wait for the pipe to close:
        // shell start-up files sometimes leave a background process holding it open.
        let buffer = LockedBuffer(limit: 256 * 1024)
        let found = DispatchSemaphore(value: 0)
        let handle = out.fileHandleForReading
        EngineRunner.spawnThread {
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                let s = buffer.string
                if let a = s.range(of: "__LP__"), s.range(of: "__LP__", range: a.upperBound..<s.endIndex) != nil { break }
            }
            found.signal()
        }
        _ = found.wait(timeout: .now() + 5)
        if process.isRunning { process.terminate() }

        let text = buffer.string
        guard let start = text.range(of: "__LP__"),
              let end = text.range(of: "__LP__", range: start.upperBound..<text.endIndex) else {
            cachedPATH = ""
            return nil
        }
        let path = String(text[start.upperBound..<end.lowerBound])
        cachedPATH = path
        return path
    }
}
