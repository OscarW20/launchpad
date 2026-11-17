import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// Computer use: bots drive Mac apps through Cua Driver (MIT, github.com/trycua/cua), an external tool that clicks and
// types through the accessibility layer of a given window, in the background. Launchpad never installs it silently:
// the official installer is opened in Terminal for you. Launchpad runs its own private driver
// (`cua-driver serve --socket <tmp>/launchpad-cua/driver.sock`) and gives a bot the MCP server "computer"
// (`cua-driver mcp --socket …`) when its "Use this Mac" switch is on. Every call to that server is in the guard's
// "Use your Mac" category (Ask by default), and bots claim an app (use_app / done_with_app) so two of them never
// drive the same one.

public enum ComputerUse {
    /// The connector id, and so the MCP server key the guard treats as "Use your Mac" (`GuardConfig.computerServers`).
    public static let serverId = "computer"
    /// For Claude's `--allowedTools`, so a call the guard lets through isn't refused by Claude Code itself.
    public static let allowedToolsEntry = "mcp__computer"
    public static let driverName = "cua-driver"
    /// The official installer. Shown and run in Terminal, never in the background.
    public static let installCommand = "curl -fsSL https://cua.ai/driver/install.sh | bash"
    public static let projectURL = URL(string: "https://github.com/trycua/cua")!

    /// Where the official installer (and Homebrew) put the driver.
    public static func driverCandidates(home: String) -> [String] {
        [
            "\(home)/.local/bin/cua-driver",
            "/Applications/CuaDriver.app/Contents/MacOS/cua-driver",
            "\(home)/Applications/CuaDriver.app/Contents/MacOS/cua-driver",
            "/opt/homebrew/bin/cua-driver",
            "/usr/local/bin/cua-driver",
        ]
    }

    /// The driver, if it's installed: the usual places first, then the given PATH folders.
    public static func findDriver(home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                                  pathDirectories: [String] = [], fileManager fm: FileManager = .default) -> String? {
        let candidates = driverCandidates(home: home) + pathDirectories.map { ($0 as NSString).appendingPathComponent(driverName) }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// `<tmp>/launchpad-cua/driver.sock`: Launchpad's own driver, so it never depends on (or disturbs) another app's.
    public static func socketPath(temporaryDirectory: String = NSTemporaryDirectory()) -> String {
        ((temporaryDirectory as NSString).appendingPathComponent("launchpad-cua") as NSString).appendingPathComponent("driver.sock")
    }

    /// Arguments for the private driver the app starts.
    public static func serveArguments(socket: String) -> [String] { ["serve", "--socket", socket] }

    /// The "computer" MCP server for one bot. It waits (in the bot's process, up to 5 s) for a driver that has just
    /// been started to open its socket, then becomes `cua-driver mcp --socket …`.
    public static func connector(driver: String, socket: String) -> Connector {
        let q = shellQuote
        let script = "for i in $(seq 50); do [ -S \(q(socket)) ] && break; sleep 0.1; done; exec \(q(driver)) mcp --socket \(q(socket))"
        return Connector(id: serverId, name: "Computer", kind: .stdio, command: "/bin/sh", args: ["-c", script])
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Lets a Claude run call the computer tools once the guard has said yes (or the bot's rule is Allow).
    public static func allowingComputer(_ invocation: EngineInvocation) -> EngineInvocation {
        ChatToolsSetup.allowing(allowedToolsEntry, in: invocation)
    }

    /// Why a bot doesn't get the computer tools for a reply.
    public enum Blocker: Equatable, Sendable {
        /// "Use this Mac" is off for this bot (nothing to say).
        case switchedOff
        /// Only Claude Code bots: their every action goes through the guard hook. Codex has no hook.
        case notClaude
        /// Locked-down bots can't open or script other apps.
        case lockedDown
        /// The bot's "Use your Mac" permission is Never.
        case never
        /// The guard (with live approval cards) isn't running, so actions couldn't be asked about.
        case noGuard
        case noDriver
        case noAccessibility
        case noScreenRecording
        /// The driver is installed but wouldn't start.
        case driverFailed

        /// One line for the bot (and the settings page).
        public var message: String {
            switch self {
            case .switchedOff: return "Computer use is off for this bot."
            case .notClaude: return "Computer use only works for Claude Code bots."
            case .lockedDown: return "Locked-down bots can't use other apps."
            case .never: return "This bot's “Use your Mac” permission is set to Never."
            case .noGuard: return "The approval guard isn't running, so computer use is off."
            case .noDriver: return "Cua Driver isn't installed. Install it from Settings › Computer use."
            case .noAccessibility: return "Launchpad needs Accessibility permission. Grant it in Settings › Computer use."
            case .noScreenRecording: return "Launchpad needs Screen Recording permission. Grant it in Settings › Computer use."
            case .driverFailed: return "Cua Driver wouldn't start. Check it in Settings › Computer use."
            }
        }
    }

    /// The first reason this bot can't use the Mac on this reply, or nil when it can.
    /// The order goes from the bot's own settings to the Mac's set-up.
    public static func blocker(for bot: Bot, guardActive: Bool, driverInstalled: Bool, accessibility: Bool,
                               screenRecording: Bool) -> Blocker? {
        guard bot.useComputer else { return .switchedOff }
        guard bot.engine == .claude else { return .notClaude }
        guard !bot.lockedDown else { return .lockedDown }
        guard bot.rules.rule(.computer) != .never else { return .never }
        guard guardActive else { return .noGuard }
        guard driverInstalled else { return .noDriver }
        guard accessibility else { return .noAccessibility }
        guard screenRecording else { return .noScreenRecording }
        return nil
    }

    /// How to use the Mac without getting in your way, and alongside teammates. Added to the bot's instructions.
    public static func instructions(handle: String, others: [String]) -> String {
        let also = others.isEmpty ? "" : ", and so may your teammates \(others.joined(separator: ", "))"
        return """
        Using the Mac: you have computer tools (the "computer" server) that work in the background. The user is using this Mac at the same time\(also), so:
        - Never take the screen. Don't use delivery_mode "foreground", bring_to_front, invoke_menu, or anything that moves the real mouse or keyboard. For menu commands, send the app's keyboard shortcut in the background with hotkey. Always pass the app's pid (and window_id) to click, type_text, press_key and hotkey, and never use scope "desktop". Launch apps with launch_app, find windows with list_windows, read them with get_window_state, and act with element_token clicks, type_text and set_value.
        - Use the session label "\(handle)" on every computer call, so your cursor is labelled as you.
        - Before you work in an app, call use_app with its name; when you're done, call done_with_app. If use_app says a teammate has it, use another way or try later. Never act on a window someone else is using.
        - Each computer action may need the user's OK on a card first. Prefer a command, file, API or CLI over clicking when one exists.
        """
    }

    /// For a bot whose switch is on but can't use the Mac right now.
    public static func unavailableNote(_ blocker: Blocker) -> String {
        "Computer use is switched on for you, but not available right now: \(blocker.message) If a task needs it, tell the user that in one line instead of trying."
    }
}

// MARK: - Who's using which app

/// A bot's claim on a Mac app (made with the use_app chat tool).
public struct AppClaim: Equatable, Hashable, Sendable {
    public var app: String
    public var bot: String
    public var botId: String
    public var purpose: String?
    public var at: Date

    public init(app: String, bot: String, botId: String, purpose: String? = nil, at: Date) {
        self.app = app
        self.bot = bot
        self.botId = botId
        self.purpose = purpose
        self.at = at
    }
}

/// Reads and tidies `.launchpad/scratch/app-claims.json` (written by `launchpad-chat`, under the same `flock`).
public enum AppClaims {
    /// Current claims (older than `ChatToolsServer.claimLifetime` are dropped).
    public static func read(file: URL, now: Date = Date()) -> [AppClaim] {
        guard let data = FileManager.default.contents(atPath: file.path),
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        let iso = ISO8601DateFormatter()
        return list.compactMap { c in
            guard let app = c["app"] as? String, let at = (c["at"] as? String).flatMap(iso.date(from:)),
                  now.timeIntervalSince(at) < ChatToolsServer.claimLifetime else { return nil }
            let bot = c["bot"] as? String ?? "A bot"
            let purpose = (c["purpose"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return AppClaim(app: app, bot: bot, botId: c["botId"] as? String ?? bot, purpose: purpose, at: at)
        }
    }

    /// The app a bot holds right now (its newest claim), for "Scout is using Figma".
    public static func app(heldBy botId: String, file: URL, now: Date = Date()) -> String? {
        read(file: file, now: now).last { $0.botId == botId }?.app
    }

    /// Lets go of everything a bot held (when its reply ends). Takes the same lock as use_app, so a claim made at
    /// the same moment is never lost.
    public static func release(botId: String, file: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else { return }
        let fd = open(file.path + ".lock", O_RDWR | O_CREAT, 0o644)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        guard let data = fm.contents(atPath: file.path),
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
        let left = list.filter { $0["botId"] as? String != botId }
        guard left.count != list.count,
              let out = try? JSONSerialization.data(withJSONObject: left, options: [.sortedKeys]) else { return }
        try? out.write(to: file, options: .atomic)
    }
}
