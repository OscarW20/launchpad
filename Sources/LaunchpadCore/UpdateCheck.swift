import Foundation

/// Whether GitHub's `main` has moved past the build that's running.
public enum UpdateStatus: Equatable, Sendable {
    case upToDate
    /// How many commits behind, and their subject lines, newest first (at most `UpdateCheck.subjectLimit`).
    case available(count: Int, subjects: [String])
    /// Couldn't tell (offline, an unstamped build, a moved checkout…), with a reason to show quietly.
    case cantCheck(String)
}

/// The in-app updater's check: compares the installed build's commit (`BuildStamp`) with `origin/main` in the
/// checkout it was built from. It never throws; anything that goes wrong is `.cantCheck`.
public struct UpdateCheck: Sendable {
    /// Runs `git <args>` in a folder. `status` is nil when git couldn't be started or took too long.
    public typealias Git = @Sendable (_ args: [String], _ directory: URL) -> (status: Int32?, output: String)

    public static let subjectLimit = 30
    public static let branch = "origin/main"

    let git: Git

    public init(git: @escaping Git = UpdateCheck.runGit) {
        self.git = git
    }

    /// - Parameter fetch: false compares with what the checkout last saw of GitHub, without going online.
    public func check(stamp: BuildStamp?, fetch: Bool = true) -> UpdateStatus {
        guard let stamp else {
            return .cantCheck("This build doesn't know which code it was made from. Update once from Terminal with scripts/update.sh; after that Launchpad can check by itself.")
        }
        let dir = stamp.source
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) else {
            return .cantCheck("Launchpad's code isn't at \(dir.path) any more, so it can't check for updates.")
        }
        if fetch {
            let fetched = git(["fetch", "--quiet", "origin", "main"], dir)
            guard fetched.status != nil else { return .cantCheck("Couldn't run git to check for updates.") }
            guard fetched.status == 0 else { return .cantCheck("Couldn't reach GitHub. Launchpad will try again later.") }
        }
        let head = git(["rev-parse", "--verify", "--quiet", "\(Self.branch)^{commit}"], dir)
        let latest = head.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard head.status == 0, !latest.isEmpty else {
            return .cantCheck("The code in \(dir.path) has no \(Self.branch) to compare with.")
        }
        if latest == stamp.commit { return .upToDate }

        switch git(["merge-base", "--is-ancestor", stamp.commit, Self.branch], dir).status {
        case 0:
            break
        case 1:
            // Built from commits GitHub doesn't have yet: nothing to pull if it already includes GitHub's main.
            if git(["merge-base", "--is-ancestor", Self.branch, stamp.commit], dir).status == 0 { return .upToDate }
            return .cantCheck("This build and GitHub's main have gone separate ways, so there's no simple update. Run scripts/update.sh in Terminal to see why.")
        default:
            return .cantCheck("This build's commit isn't in \(dir.path), so Launchpad can't tell how far behind it is.")
        }

        let range = "\(stamp.commit)..\(Self.branch)"
        let counted = git(["rev-list", "--count", range], dir)
        let log = git(["log", "--format=%s", "--max-count=\(Self.subjectLimit)", range], dir)
        let subjects = log.status == 0 ? log.output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } : []
        let count = counted.status == 0 ? Int(counted.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? subjects.count : subjects.count
        // It is behind (the ancestor check said so) even if the log couldn't be read.
        return .available(count: max(count, subjects.count, 1), subjects: subjects)
    }

    /// The shortest gap between the checks made when you come back to the app (each one is a `git fetch`).
    public static let activationInterval: TimeInterval = 10 * 60

    /// Whether coming back to the app should check again: never checked, or not within `minimum`.
    public static func isDue(lastChecked: Date?, now: Date = Date(), minimum: TimeInterval = activationInterval) -> Bool {
        guard let lastChecked else { return true }
        return now.timeIntervalSince(lastChecked) >= minimum
    }

    /// How long one git command may take before it's stopped (a fetch on a dead connection can hang).
    public static let timeout: TimeInterval = 30

    /// Runs the real git, never asking for a password, and gives up after `timeout`.
    public static let runGit: Git = { args, directory in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = directory
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (nil, "") }
        let timedOut = TimedOut()
        let stop = DispatchWorkItem {
            guard p.isRunning else { return }
            timedOut.set()
            p.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        stop.cancel()
        if timedOut.value { return (nil, "") }
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private final class TimedOut: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.lock(); flag = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }
}

extension UpdateStatus {
    /// One line for Settings: "3 updates available", "Launchpad is up to date", or the reason.
    public var summary: String {
        switch self {
        case .upToDate: return "Launchpad is up to date"
        case .available(let count, _): return count == 1 ? "1 update available" : "\(count) updates available"
        case .cantCheck(let reason): return reason
        }
    }

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}
