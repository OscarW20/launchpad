import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A running engine. Read `events` until it ends; call `cancel()` for the Stop button.
public final class RunHandle: @unchecked Sendable {
    public let events: AsyncStream<RunEvent>
    private let onCancel: @Sendable () -> Void

    init(events: AsyncStream<RunEvent>, onCancel: @escaping @Sendable () -> Void) {
        self.events = events
        self.onCancel = onCancel
    }

    public func cancel() { onCancel() }
}

/// Launches Claude Code or Codex for one message and streams what it does.
///
/// The stream always ends with exactly one of `.finished`, `.failed` or `.stopped`.
public final class EngineRunner: @unchecked Sendable {
    public let locator: CLILocator

    public init(locator: CLILocator = CLILocator()) {
        self.locator = locator
    }

    public func run(_ invocation: EngineInvocation) -> RunHandle {
        let state = RunState()
        var continuation: AsyncStream<RunEvent>.Continuation!
        let stream = AsyncStream<RunEvent>(bufferingPolicy: .unbounded) { continuation = $0 }
        let cont = continuation!

        let handle = RunHandle(events: stream) { state.cancel() }

        Self.spawnThread { [locator] in
            Self.execute(invocation, locator: locator, state: state, emit: { cont.yield($0) })
            cont.finish()
        }
        cont.onTermination = { reason in
            if case .cancelled = reason { state.cancel() }
        }
        return handle
    }

    /// Blocking pipe reads get their own threads so they never starve the shared queues.
    static func spawnThread(_ body: @escaping @Sendable () -> Void) {
        let t = Thread { body() }
        t.stackSize = 1 << 20
        t.start()
    }

    private static func execute(_ inv: EngineInvocation, locator: CLILocator, state: RunState, emit: @escaping (RunEvent) -> Void) {
        guard let executable = locator.locate(inv.engine) else {
            emit(.failed(ErrorClassifier.cliMissing(inv.engine)))
            return
        }
        let parser: StreamParser = inv.engine == .claude ? ClaudeStreamParser() : CodexStreamParser()

        let process = Process()
        process.executableURL = executable
        process.arguments = inv.arguments
        process.currentDirectoryURL = inv.workingDirectory
        process.environment = locator.environment().merging(inv.environment) { _, new in new }
        let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin

        do {
            try process.run()
        } catch {
            emit(.failed(ErrorClassifier.classify(engine: inv.engine, text: "\(error.localizedDescription)", exitCode: 127)))
            return
        }
        guard state.attach(process) else {
            // Stop was pressed before the process started.
            process.terminate()
            process.waitUntilExit()
            emit(.stopped)
            return
        }

        // Send the prompt, then close stdin so the engine knows the message is complete.
        let input = stdin.fileHandleForWriting
        try? input.write(contentsOf: Data(inv.stdin.utf8))
        try? input.close()

        // Drain stderr in the background so the pipe never fills up and blocks the engine.
        let errBuffer = LockedBuffer(limit: 64 * 1024)
        let errDone = DispatchSemaphore(value: 0)
        Self.spawnThread {
            let h = stderr.fileHandleForReading
            while true {
                let chunk = h.availableData
                if chunk.isEmpty { break }
                errBuffer.append(chunk)
            }
            errDone.signal()
        }

        // Read stdout on its own thread. If the engine leaves a child process behind that still
        // holds the pipe open, we stop waiting shortly after the engine itself exits.
        let gate = EmitGate(emit: emit)
        let readDone = DispatchSemaphore(value: 0)
        Self.spawnThread {
            var lineBuffer = Data()
            let out = stdout.fileHandleForReading
            func handle(line: Data) {
                guard let text = String(data: line, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { return }
                for event in parser.parse(line: text) { gate.offer(event) }
            }
            while true {
                let chunk = out.availableData
                if chunk.isEmpty { break }
                lineBuffer.append(chunk)
                while let nl = lineBuffer.firstIndex(of: 0x0A) {
                    let line = lineBuffer[lineBuffer.startIndex..<nl]
                    lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
                    handle(line: Data(line))
                }
            }
            if !lineBuffer.isEmpty { handle(line: lineBuffer) }
            readDone.signal()
        }

        process.waitUntilExit()
        _ = readDone.wait(timeout: .now() + (state.isCancelled ? 0.5 : 3))
        _ = errDone.wait(timeout: .now() + 0.5)
        let (terminal, engineError) = gate.close()
        if terminal { return }

        if state.isCancelled {
            emit(.stopped)
            return
        }
        let status = process.terminationStatus
        let errText = errBuffer.string
        if let engineError {
            let combined = errText.isEmpty ? engineError : engineError + "\n" + errText
            emit(.failed(ErrorClassifier.classify(engine: inv.engine, text: combined, exitCode: status)))
        } else if status == 0 && parser.isComplete {
            emit(.finished(resultText: nil))
        } else {
            let text = [parser.lastError, errText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            emit(.failed(ErrorClassifier.classify(engine: inv.engine, text: text, exitCode: status)))
        }
    }
}

/// Shared between the run and the Stop button.
final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private(set) var isCancelledFlag = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return isCancelledFlag
    }

    /// Returns false if Stop was already pressed.
    func attach(_ p: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        process = p
        return !isCancelledFlag
    }

    func cancel() {
        lock.lock()
        guard !isCancelledFlag else { lock.unlock(); return }
        isCancelledFlag = true
        let p = process
        lock.unlock()

        guard let p, p.isRunning else { return }
        p.interrupt() // SIGINT first: lets the engine save its session cleanly
        let pid = p.processIdentifier
        EngineRunner.spawnThread {
            // Then end the engine and anything it started (dev servers, test runners…):
            // SIGTERM after 1.5s, SIGKILL after 4s.
            Thread.sleep(forTimeInterval: 1.5)
            ProcessTree.signal(root: pid, SIGTERM)
            Thread.sleep(forTimeInterval: 2.5)
            ProcessTree.signal(root: pid, SIGKILL)
        }
    }
}

enum ProcessTree {
    /// Sends `sig` to `root` and all of its descendants (children first).
    static func signal(root: Int32, _ sig: Int32) {
        var all: [Int32] = []
        var frontier = [root]
        while let next = frontier.popLast() {
            let kids = children(of: next)
            all.append(contentsOf: kids)
            frontier.append(contentsOf: kids)
        }
        for pid in all.reversed() { kill(pid, sig) }
        kill(root, sig)
    }

    static func children(of pid: Int32) -> [Int32] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", String(pid)]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }
}

/// Passes events through until the run is decided, then drops anything late.
final class EmitGate: @unchecked Sendable {
    private let lock = NSLock()
    private let emit: (RunEvent) -> Void
    private var closed = false
    private var terminal = false
    private var engineError: String?

    init(emit: @escaping (RunEvent) -> Void) { self.emit = emit }

    func offer(_ event: RunEvent) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !terminal else { return }
        switch event {
        case .engineError(let message):
            engineError = message
        case .finished:
            terminal = true
            emit(event)
        default:
            emit(event)
        }
    }

    /// Stops passing events on; returns whether the run already finished and any engine error.
    func close() -> (Bool, String?) {
        lock.lock(); defer { lock.unlock() }
        closed = true
        return (terminal, engineError)
    }
}

final class LockedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        if data.count > limit { data = data.suffix(limit) }
    }

    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
