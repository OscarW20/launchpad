#if os(macOS)
import SwiftUI
import AppKit
import ApplicationServices
import CoreGraphics
import LaunchpadCore

/// Computer use on this Mac: finds Cua Driver, runs Launchpad's private driver, and checks the two permissions it
/// acts with (Accessibility and Screen Recording, both Launchpad's own). See `ComputerUse` in the core.
@MainActor
@Observable
final class ComputerUseController {
    static let shared = ComputerUseController()

    private(set) var driverPath: String?
    private(set) var accessibility = false
    private(set) var screenRecording = false
    private(set) var daemonRunning = false
    /// Why the driver didn't start last time.
    private(set) var problem: String?
    /// Folders from your login shell's PATH (found once, off the main thread).
    @ObservationIgnored private var pathDirectories: [String] = []
    @ObservationIgnored private var daemon: Process?
    @ObservationIgnored private var lastFailure: Date?
    let socket = ComputerUse.socketPath()

    var permissionsGranted: Bool { accessibility && screenRecording }
    var ready: Bool { driverPath != nil && permissionsGranted }

    /// At launch: end drivers an earlier run left behind (a crash), then look for the driver.
    func start(locator: CLILocator) {
        cleanUpLeftovers()
        refreshPermissions()
        driverPath = ComputerUse.findDriver()
        Task.detached(priority: .utility) {
            let path = locator.environment()["PATH"] ?? ""
            let dirs = path.split(separator: ":").map(String.init)
            await MainActor.run { [weak self] in
                self?.pathDirectories = dirs
                self?.refresh()
            }
        }
    }

    /// Looks again (Settings, and before each reply of a bot that may use the Mac).
    func refresh() {
        driverPath = ComputerUse.findDriver(pathDirectories: pathDirectories)
        refreshPermissions()
        if let d = daemon, !d.isRunning { daemon = nil }
        daemonRunning = daemon?.isRunning == true
    }

    private func refreshPermissions() {
        accessibility = AXIsProcessTrusted()
        screenRecording = CGPreflightScreenCaptureAccess()
    }

    /// Why this bot can't use the Mac on this reply (nil: it can).
    func blocker(for bot: Bot, guardActive: Bool) -> ComputerUse.Blocker? {
        guard bot.useComputer else { return .switchedOff }
        refresh()
        return ComputerUse.blocker(for: bot, guardActive: guardActive, driverInstalled: driverPath != nil,
                                   accessibility: accessibility, screenRecording: screenRecording)
    }

    /// Starts the private driver if it isn't running. Cheap to call before every reply. A driver that keeps failing
    /// isn't retried for 10 minutes (Check again in Settings resets that).
    func ensureDaemon() -> Bool {
        if let d = daemon, d.isRunning { return true }
        guard let path = driverPath else { return false }
        if let failed = lastFailure, Date().timeIntervalSince(failed) < 600 { return false }
        if daemon != nil {
            // It was started and has died.
            daemon = nil
            daemonRunning = false
            lastFailure = Date()
            problem = "Cua Driver stopped by itself. Check it works in Terminal: \(path) serve"
            return false
        }
        try? FileManager.default.createDirectory(atPath: (socket as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: socket)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ComputerUse.serveArguments(socket: socket)
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            lastFailure = Date()
            problem = "Couldn't start Cua Driver: \(error.localizedDescription)"
            return false
        }
        daemon = p
        daemonRunning = true
        problem = nil
        return true
    }

    func stopDaemon() {
        daemon?.terminate()
        daemon = nil
        daemonRunning = false
    }

    /// Try again now (after installing, or after a failure).
    func checkAgain() {
        lastFailure = nil
        problem = nil
        refresh()
    }

    /// Ends drivers left from a run that didn't quit cleanly (they'd hold our socket).
    private func cleanUpLeftovers() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", "serve --socket \(socket)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
        } catch {}
    }

    // MARK: Installing and permissions

    /// Opens Terminal with the official installer, so you see exactly what runs. Never run silently.
    func openInstaller() throws {
        try SystemActions.openTerminal(running: ComputerUse.installCommand + " && echo && echo 'Cua Driver is installed. Go back to Launchpad and click Check Again.'")
    }

    /// Asks macOS for Accessibility (it shows its own prompt once) and opens the right Settings pane.
    func requestAccessibility() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        Self.openPrivacyPane("Privacy_Accessibility")
    }

    /// Asks macOS for Screen Recording (it shows its own prompt once) and opens the right Settings pane.
    func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        Self.openPrivacyPane("Privacy_ScreenCapture")
    }

    static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Who's using which app right now (from the bots' use_app claims).
    func claims(paths: LaunchpadPaths) -> [AppClaim] {
        AppClaims.read(file: paths.appClaimsFile)
    }
}
#endif
