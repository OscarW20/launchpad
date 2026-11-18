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

    /// The shared server's address once it's answering; nil while it starts (that run uses its own browser).
    func readyURL(for connector: Connector, locator: CLILocator, paths: LaunchpadPaths) -> String? {
        if let p = process, p.isRunning, ready, let port { return SharedBrowser.url(port: port) }
        start(connector, locator: locator, paths: paths)
        return nil
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
                if Self.answers(port: port) { self.ready = true; break }
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
