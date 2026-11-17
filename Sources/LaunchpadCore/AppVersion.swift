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
