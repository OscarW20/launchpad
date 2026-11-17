import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The kernel sandbox around a bot run (macOS `sandbox-exec`). macOS enforces it, not the bot, and every process
/// the bot starts (its Terminal, a script, the guard hook) inherits it and can't leave it.
///
/// Every bot: can't write the app, Launchpad's own data (rules, approval answers, grants, snapshots; only the
/// approval-request and scratch folders stay writable), or any Claude Code settings file, so it can't switch the
/// guard off or approve itself.
///
/// Locked-down bots: on top of that, no network except to this Mac (Launchpad's site gateway listens there), no
/// opening or scripting other apps (they'd run outside the sandbox), and no startup files (shell profiles,
/// LaunchAgents, cron) that would run later outside the sandbox.
public struct BotSandbox: Equatable, Sendable {
    public var lockedDown = false
    /// Launchpad's folder (`LaunchpadPaths.root`).
    public var launchpadRoot: String
    /// The app bundle (…/Launchpad.app). Only protected when it really is a bundle.
    public var appBundle: String?
    /// The user's home folder.
    public var home: String
    /// Extra paths the bot may never write (absolute).
    public var extraProtected: [String] = []

    public static let tool = "/usr/bin/sandbox-exec"
    public static var available: Bool { FileManager.default.isExecutableFile(atPath: tool) }

    public init(lockedDown: Bool = false, launchpadRoot: String, appBundle: String? = nil,
                home: String = FileManager.default.homeDirectoryForCurrentUser.path, extraProtected: [String] = []) {
        self.lockedDown = lockedDown
        self.launchpadRoot = launchpadRoot
        self.appBundle = appBundle
        self.home = home
        self.extraProtected = extraProtected
    }

    public init(bot: Bot, paths: LaunchpadPaths, appBundle: String? = Bundle.main.bundleURL.path) {
        self.init(lockedDown: bot.lockedDown, launchpadRoot: paths.root.path, appBundle: appBundle)
    }

    /// The path as the kernel sees it (/tmp is really /private/tmp on a Mac). The file may not exist yet:
    /// the nearest existing parent is resolved and the rest added back.
    public static func real(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        var url = URL(fileURLWithPath: path)
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
            rest.insert(url.lastPathComponent, at: 0)
            url.deleteLastPathComponent()
        }
        // realpath(3), not resolvingSymlinksInPath: Foundation drops "/private", which the kernel needs.
        var resolved = url.path
        if let r = realpath(url.path, nil) { resolved = String(cString: r); free(r) }
        for part in rest { resolved = (resolved as NSString).appendingPathComponent(part) }
        return resolved
    }

    /// A string literal in SBPL.
    public static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The sandbox profile (SBPL). Later rules win over earlier ones.
    public func profile() -> String {
        let q = Self.quote
        let data = Self.real((launchpadRoot as NSString).appendingPathComponent(".launchpad"))
        var lines = ["(version 1)", "(allow default)"]

        // Never writable: the app, Launchpad's data and every Claude Code settings file.
        var denied = [data] + extraProtected.map(Self.real)
        if let appBundle, appBundle.hasSuffix(".app") { denied.append(Self.real(appBundle)) }
        denied.append("/Library/Application Support/ClaudeCode")
        lines.append("(deny file-write* " + denied.map { "(subpath \(q($0)))" }.joined(separator: " ")
                     + " (regex #\"/\\.claude/settings(\\.local)?\\.json$\") (regex #\"/managed-settings\\.json$\"))")
        // What the guard hook (which runs inside this sandbox) and one-off runs write inside Launchpad's data.
        lines.append("(allow file-write* (subpath \(q(data + "/requests"))) (subpath \(q(data + "/scratch"))))")

        if lockedDown {
            let h = Self.real(home)
            // Things that would run later, outside the sandbox.
            let startup = [".zshrc", ".zprofile", ".zshenv", ".zlogin", ".zlogout", ".bashrc", ".bash_profile", ".bash_login", ".profile", ".login"]
            lines.append("(deny file-write* (subpath \(q(h + "/Library/LaunchAgents"))) (subpath \"/Library/LaunchAgents\") "
                         + "(subpath \"/Library/LaunchDaemons\") (subpath \"/private/var/at\") (subpath \"/usr/lib/cron\") "
                         + startup.map { "(literal \(q(h + "/" + $0)))" }.joined(separator: " ") + ")")
            // Other apps run outside the sandbox: no opening them, no Apple Events.
            lines.append("(deny lsopen)")
            lines.append("(deny appleevent-send)")
            // Online only through Launchpad's site gateway on this Mac.
            lines.append("(deny network-outbound)")
            lines.append("(allow network-outbound (remote ip \"localhost:*\"))")
            // The system's own logging still works over local sockets.
            lines.append("(allow network-outbound (remote unix-socket (path-regex #\"^/private/var/run/(syslog|asl)\")))")
        }
        return lines.joined(separator: "\n")
    }

    /// The command line that runs `executable` inside a sandbox profile.
    public static func wrap(executable: URL, arguments: [String], profile: String) -> (executable: URL, arguments: [String]) {
        (URL(fileURLWithPath: tool), ["-p", profile, executable.path] + arguments)
    }

    /// The command line that runs `executable` inside this sandbox.
    public func wrap(executable: URL, arguments: [String]) -> (executable: URL, arguments: [String]) {
        Self.wrap(executable: executable, arguments: arguments, profile: profile())
    }

    /// The sites a locked-down bot always needs, so its engine can think at all.
    public static func engineSites(_ engine: BotEngine) -> [String] {
        switch engine {
        case .claude: return ["anthropic.com", "claude.ai", "claude.com"]
        case .codex: return ["openai.com", "chatgpt.com"]
        case .local: return []   // localhost is always reachable
        }
    }

    /// Package registries its connectors download from on first use (npx, uvx).
    public static func connectorSites(_ connectors: [Connector]) -> [String] {
        var out: [String] = []
        let heads = connectors.compactMap { $0.command.map { ($0 as NSString).lastPathComponent } }
        if heads.contains(where: { ["npx", "npm", "node", "bunx", "pnpm"].contains($0) }) { out.append("registry.npmjs.org") }
        if heads.contains(where: { ["uvx", "uv", "pipx", "python3", "python"].contains($0) }) { out += ["pypi.org", "files.pythonhosted.org"] }
        for c in connectors where c.kind == .http {
            if let host = c.url.flatMap(URL.init(string:))?.host { out.append(host) }
        }
        return out
    }

    /// Every site a locked-down bot may reach: yours, its engine's, and its connectors'.
    public static func allowedSites(for bot: Bot, connectors: [Connector] = []) -> [String] {
        Array(Set((bot.sites + engineSites(bot.engine) + connectorSites(connectors))
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })).sorted()
    }
}
