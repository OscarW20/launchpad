#if os(macOS)
import Foundation
import AppKit
import Darwin
import LaunchpadCore

/// Runs the Browser app's server once for every bot (see SharedBrowser), so the browser stays open between replies
/// and your logins in it are kept. Starts when a bot that has the Browser app runs, stops when Launchpad quits.
@MainActor
final class SharedBrowserHost {
    static let shared = SharedBrowserHost()

    private var process: Process?
    private var port: Int?
    private var ready = false
    private var starting = false
    private var quitObserver: NSObjectProtocol?

    // The session the app keeps open so the browser outlives any bot's reply (see `BrowserHold`).
    private var holderSession: String?
    private var holding = false
    private var holdWanted = false
    /// When the browser was opened for you to use, nil when it isn't open. For a "Browser open" indicator.
    private(set) var heldSince: Date?
    /// Set when the app opened or closed it, so a view can refresh.
    private(set) var changes = 0
    var isOpen: Bool { heldSince != nil && process?.isRunning == true }

    /// The shared server's address once it's answering; nil while it starts (that run uses its own browser).
    /// `forRun`: a bot is about to use it, so also open the browser on the app's own session (see `holdBrowser`). Warm-up at launch
    /// passes false: it only starts the server, and no window appears until a bot needs one.
    func readyURL(for connector: Connector, locator: CLILocator, paths: LaunchpadPaths, forRun: Bool = true) -> String? {
        if forRun { holdWanted = true }
        if let p = process, p.isRunning, ready, let port {
            if forRun { holdBrowser(port: port) }
            return SharedBrowser.url(port: port)
        }
        start(connector, locator: locator, paths: paths)
        return nil
    }

    /// Makes sure the app has its own session open on the server and the browser opened on it, so a bot's run ending (or
    /// being steered, or another bot starting and finishing) never takes the browser with it. Cheap when already done.
    func holdBrowser(port: Int) {
        guard !holding else { return }
        holding = true
        Task { @MainActor in
            defer { self.holding = false }
            // Is our session still good? A ping doesn't start a browser.
            if let sid = self.holderSession, await Self.send(BrowserHold.ping(), port: port, session: sid).ok {
                if self.heldSince == nil { await self.openBrowser(port: port, session: sid) }
                return
            }
            self.holderSession = nil
            self.heldSince = nil
            let first = await Self.send(BrowserHold.initialize(), port: port, session: nil)
            guard first.ok, let sid = first.session else { return }
            _ = await Self.send(BrowserHold.initialized(), port: port, session: sid)
            self.holderSession = sid
            await self.openBrowser(port: port, session: sid)
        }
    }

    private func openBrowser(port: Int, session: String) async {
        if await Self.send(BrowserHold.openBrowser(), port: port, session: session).ok {
            heldSince = Date()
            changes += 1
        }
    }

    /// You pressed Close: shuts the browser (a signed-in session in it is lost). The next bot run that uses the Browser app
    /// opens it again.
    func closeBrowser() async {
        guard let port, let sid = holderSession else { return }
        _ = await Self.send(BrowserHold.closeBrowser(), port: port, session: sid)
        heldSince = nil
        changes += 1
    }

    private static func send(_ body: Data, port: Int, session: String?) async -> (ok: Bool, session: String?) {
        var req = URLRequest(url: URL(string: SharedBrowser.url(port: port))!)
        req.httpMethod = "POST"
        req.httpBody = body
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let session { req.setValue(session, forHTTPHeaderField: BrowserHold.sessionHeader) }
        guard let (data, response) = try? await URLSession.shared.data(for: req), let http = response as? HTTPURLResponse else { return (false, nil) }
        let text = String(decoding: data, as: UTF8.self)
        let sid = http.value(forHTTPHeaderField: BrowserHold.sessionHeader) ?? session
        // The "initialized" notification gets an empty 202.
        return ((200..<300).contains(http.statusCode) && (text.isEmpty || BrowserHold.succeeded(text)), sid)
    }

    /// Starts the server if needed and waits (up to a minute, the first npx download can be slow) until it answers.
    func waitUntilReady(for connector: Connector, locator: CLILocator, paths: LaunchpadPaths) async -> String? {
        if let url = readyURL(for: connector, locator: locator, paths: paths) { return url }
        for _ in 0..<120 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let p = process, p.isRunning, ready, let port { return SharedBrowser.url(port: port) }
            if process == nil && !starting { return nil }
        }
        return nil
    }

    func stop() {
        if let p = process, p.isRunning { p.terminate() }
        holderSession = nil
        heldSince = nil
        process = nil
        ready = false
        port = nil
    }

    private func start(_ connector: Connector, locator: CLILocator, paths: LaunchpadPaths) {
        guard !starting, process?.isRunning != true else { return }
        guard let exe = locator.locate(command: connector.command ?? "npx"), let port = Self.freePort() else { return }
        starting = true
        ready = false
        let profile = paths.root.appendingPathComponent(".launchpad/browser-profile", isDirectory: true)
        try? FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = exe
        p.arguments = SharedBrowser.serverArguments(from: connector, port: port, profileDir: profile.path)
        p.environment = locator.environment()
        p.currentDirectoryURL = profile
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.process === p else { return }
                self.process = nil
                self.ready = false
                self.port = nil
                self.starting = false
                self.holderSession = nil
                self.heldSince = nil
                self.changes += 1
            }
        }
        do { try p.run() } catch { starting = false; return }
        process = p
        self.port = port
        if quitObserver == nil {
            quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                  object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { SharedBrowserHost.shared.stop() }
            }
        }
        Task { @MainActor in
            for _ in 0..<120 {
                if Self.answers(port: port) { self.ready = true; if self.holdWanted { self.holdBrowser(port: port) }; break }
                try? await Task.sleep(nanoseconds: 500_000_000)
                if self.process !== p { break }
            }
            self.starting = false
        }
    }

    /// Is something listening on localhost:port?
    private static func answers(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    /// The first free port from 8931 up.
    private static func freePort() -> Int? {
        for port in SharedBrowser.defaultPort..<(SharedBrowser.defaultPort + 40) where !answers(port: port) {
            return port
        }
        return nil
    }
}
#endif
