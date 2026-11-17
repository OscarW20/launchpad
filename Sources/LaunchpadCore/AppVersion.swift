import Foundation

/// Which build of Launchpad this is, as `scripts/make-app.sh` stamps it into the app's Info.plist: the version from
/// the newest `v*` git tag, the build number from the commit count, and `git describe` for the exact commit.
public struct AppVersion: Equatable, Sendable {
    /// The Info.plist key holding `git describe` ("v0.2.0", or "v0.2.0-3-gabc1234" three commits after the tag).
    public static let describeKey = "LaunchpadGitDescribe"

    public let short: String
    public let build: String
    public let describe: String?

    public init(short: String, build: String, describe: String? = nil) {
        self.short = short
        self.build = build
        self.describe = describe
    }

    /// Reads an Info.plist dictionary; nil outside the .app bundle (`swift run` has no version).
    public init?(info: [String: Any]?) {
        guard let short = info?["CFBundleShortVersionString"] as? String, !short.isEmpty else { return nil }
        self.init(short: short, build: info?["CFBundleVersion"] as? String ?? "",
                  describe: (info?[Self.describeKey] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    /// "0.2.0 (57)" for a tagged release; "0.2.0 (60, v0.2.0-3-gabc1234)" for a build between tags, so a bug
    /// report always names the exact commit.
    public var label: String {
        var inside = build.isEmpty ? [] : [build]
        if let describe, describe != "v\(short)" { inside.append(describe) }
        return inside.isEmpty ? short : "\(short) (\(inside.joined(separator: ", ")))"
    }

    /// What Settings shows.
    public static func label(info: [String: Any]?) -> String {
        AppVersion(info: info)?.label ?? "Development build"
    }
}

/// Where an installed build came from, stamped into Info.plist by `scripts/make-app.sh`: the git commit it was built
/// at and the checkout it was built in. The in-app updater compares the commit with `origin/main` and runs
/// `scripts/update.sh` in that checkout.
public struct BuildStamp: Equatable, Sendable {
    public static let commitKey = "LaunchpadGitCommit"
    public static let sourceKey = "LaunchpadSourcePath"

    /// The full commit hash.
    public let commit: String
    /// The folder of the git checkout.
    public let source: URL

    public init(commit: String, source: URL) {
        self.commit = commit
        self.source = source
    }

    /// Nil for a build without the stamps (`swift run`, or an app built before they existed).
    public init?(info: [String: Any]?) {
        guard let commit = info?[Self.commitKey] as? String, !commit.isEmpty,
              let source = info?[Self.sourceKey] as? String, !source.isEmpty else { return nil }
        self.init(commit: commit, source: URL(fileURLWithPath: source, isDirectory: true))
    }

    public var updateScript: URL { source.appendingPathComponent("scripts/update.sh") }
}

/// The log `scripts/update.sh` writes while it runs. Lines starting "==> " are progress; the last one is
/// "==> Done: …" or "==> Failed: …". Everything else is build output.
public enum UpdateLog {
    public static let environmentKey = "LAUNCHPAD_UPDATE_LOG"

    public static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment[environmentKey], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Launchpad/update.log")
    }

    public enum State: Equatable, Sendable {
        /// Still going; the text is the current step ("Building Launchpad 0.1.0 (48)").
        case running(String)
        case done(String)
        case failed(String)
    }

    /// Where the update has got to, from the log's text; nil before the first progress line.
    public static func state(of log: String) -> State? {
        let marker = "==> "
        guard let last = log.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix(marker) }) else { return nil }
        let step = String(last.dropFirst(marker.count))
        if step.hasPrefix("Done: ") { return .done(String(step.dropFirst(6))) }
        if step.hasPrefix("Failed: ") { return .failed(String(step.dropFirst(8))) }
        return .running(step)
    }
}
