import Foundation

/// Watches folders for "a new file appeared" routines by polling (like `FolderWatcher`, so it works the same on
/// Linux and costs nothing for big folders). A file only counts once it's finished:
/// - its size stayed the same between two looks,
/// - no download is still running next to it ("report.pdf" while "report.pdf.part" / ".crdownload" / ".download" is
///   there: Firefox makes an empty placeholder first),
/// - an empty file only counts once it has stayed empty for `emptyGrace` (a download's placeholder is filled in later).
///
/// A folder that's deleted, renamed or unmounted shows as unwatchable until it's back; a folder replaced by a new one
/// (different inode) starts again with a fresh snapshot, so the files already in it don't count as new.
public final class FolderArrivalWatch: @unchecked Sendable {
    /// Downloads in progress and other files that aren't finished yet.
    public static let partialExtensions: Set<String> = ["crdownload", "download", "part", "partial", "tmp", "opdownload", "icloud"]

    public enum Check: Equatable, Sendable {
        /// Finished new files (full paths), possibly none.
        case files([String])
        /// The folder isn't there (or isn't a folder) right now.
        case unavailable
    }

    private struct State {
        var identity: Identity
        var known: Set<String>
        var growing: [String: (size: Int, since: Date)]
    }

    struct Identity: Equatable {
        var device: UInt64
        var inode: UInt64
    }

    private var states: [String: State] = [:]
    private let fm = FileManager.default
    private let lock = NSLock()
    public var emptyGrace: TimeInterval

    public init(emptyGrace: TimeInterval = 10) {
        self.emptyGrace = emptyGrace
    }

    /// Looks at the folder. The first look (and the first after it came back or was replaced) only takes a snapshot.
    public func check(_ folder: String, now: Date = Date()) -> Check {
        lock.lock()
        defer { lock.unlock() }
        let path = Self.standard(folder)
        guard let identity = identity(of: path) else {
            states[path] = nil
            return .unavailable
        }
        let (names, busy) = Self.listing(in: path, fm: fm)
        guard var state = states[path], state.identity == identity else {
            states[path] = State(identity: identity, known: Set(names), growing: [:])
            return .files([])
        }
        let current = Set(names)
        state.known.formIntersection(current)   // a file that's removed and comes back counts as new again
        var ready: [String] = []
        for name in current.subtracting(state.known).sorted() {
            let full = (path as NSString).appendingPathComponent(name)
            let size = (try? fm.attributesOfItem(atPath: full)[.size] as? NSNumber)?.intValue ?? 0
            if let seen = state.growing[name], seen.size == size {
                if !busy.contains(name), size > 0 || now.timeIntervalSince(seen.since) >= emptyGrace {
                    ready.append(name)
                    state.growing[name] = nil
                }
            } else {
                state.growing[name] = (size, now)
            }
        }
        state.growing = state.growing.filter { current.contains($0.key) }
        state.known.formUnion(ready)
        states[path] = state
        return .files(ready.map { (path as NSString).appendingPathComponent($0) })
    }

    /// Stops tracking folders that aren't wanted any more.
    public func keepOnly(_ folders: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        let wanted = Set(folders.map(Self.standard))
        states = states.filter { wanted.contains($0.key) }
    }

    /// Is any new file still settling (worth looking again soon)?
    public var hasPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return states.values.contains { !$0.growing.isEmpty }
    }

    /// Finished files in the folder, and the names that still have a download in progress next to them.
    public static func listing(in path: String, fm: FileManager = .default) -> (names: [String], busy: Set<String>) {
        var names: [String] = [], busy = Set<String>()
        for name in (try? fm.contentsOfDirectory(atPath: path)) ?? [] where !name.hasPrefix(".") {
            if partialExtensions.contains((name as NSString).pathExtension.lowercased()) {
                busy.insert((name as NSString).deletingPathExtension)
            } else {
                var isDir: ObjCBool = false
                // Sub-folders don't count as files.
                if fm.fileExists(atPath: (path as NSString).appendingPathComponent(name), isDirectory: &isDir), isDir.boolValue { continue }
                names.append(name)
            }
        }
        return (names, busy)
    }

    static func standard(_ folder: String) -> String {
        URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL.path
    }

    private func identity(of path: String) -> Identity? {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
              let attrs = try? fm.attributesOfItem(atPath: path) else { return nil }
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let device = (attrs[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        return Identity(device: device, inode: inode)
    }
}

/// Folder routines, ready for the routine timer: watches each enabled folder routine's folder, and batches new files
/// so a burst of files is one run, at most one run per routine every `cooldown` seconds.
public final class FolderTriggers: @unchecked Sendable {
    public static let defaultCooldown: TimeInterval = 60

    public struct Poll: Equatable, Sendable {
        /// Routine id → finished new files to run it with now.
        public var runs: [String: [String]] = [:]
        /// Enabled folder routines whose folder isn't there (show a warning on the row).
        public var unavailable: Set<String> = []
    }

    public let watch: FolderArrivalWatch
    public var cooldown: TimeInterval
    private var pending: [String: [String]] = [:]
    private var lastRun: [String: Date] = [:]

    public init(cooldown: TimeInterval = FolderTriggers.defaultCooldown, emptyGrace: TimeInterval = 10) {
        self.cooldown = cooldown
        watch = FolderArrivalWatch(emptyGrace: emptyGrace)
    }

    /// Call every few seconds. Returns the runs to start now.
    public func poll(_ routines: [Routine], now: Date = Date()) -> Poll {
        var poll = Poll()
        let folderRoutines = routines.filter { $0.enabled && $0.watchedFolder != nil }
        let live = Set(folderRoutines.map(\.id))
        // Each folder is looked at once per poll; its new files go to every routine watching it.
        let byFolder = Dictionary(grouping: folderRoutines) { FolderArrivalWatch.standard($0.watchedFolder!) }
        let wanted = Set(byFolder.keys)
        for (folder, group) in byFolder {
            switch watch.check(folder, now: now) {
            case .unavailable:
                for r in group { poll.unavailable.insert(r.id) }
            case .files(let files):
                guard !files.isEmpty else { continue }
                for r in group { pending[r.id, default: []] += files }
            }
        }
        watch.keepOnly(wanted)
        pending = pending.filter { live.contains($0.key) }
        for (id, files) in pending where !files.isEmpty {
            if let last = lastRun[id], now.timeIntervalSince(last) < cooldown { continue }
            poll.runs[id] = files
            lastRun[id] = now
            pending[id] = nil
        }
        return poll
    }

    /// Takes the first snapshot of every folder, so files already there don't count. Call at launch and after saving.
    public func prime(_ routines: [Routine], now: Date = Date()) {
        for r in routines where r.enabled { if let f = r.watchedFolder { _ = watch.check(f, now: now) } }
    }
}
