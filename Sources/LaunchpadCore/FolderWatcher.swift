import Foundation

/// Watches ~/Launchpad for changes made by you or by any agent, so the app updates live.
///
/// It polls a small set of files once a second (bot.json, CLAUDE.md, AGENTS.md, SKILL.md,
/// group.json, connectors.json, chat files) rather than the whole tree, so big workspaces
/// such as node_modules cost nothing.
public final class FolderWatcher: @unchecked Sendable {
    public enum Area: String, CaseIterable, Sendable {
        case bots, groups, skills, connectors, chats, routines
    }

    private let paths: LaunchpadPaths
    private let interval: TimeInterval
    private let fm = FileManager.default
    private let queue = DispatchQueue(label: "launchpad.watcher")
    private var timer: DispatchSourceTimer?
    private var last: [Area: [String: Date]] = [:]
    private let onChange: @Sendable (Set<Area>) -> Void

    public init(paths: LaunchpadPaths, interval: TimeInterval = 1.0, onChange: @escaping @Sendable (Set<Area>) -> Void) {
        self.paths = paths
        self.interval = interval
        self.onChange = onChange
        self.last = snapshot()
    }

    public func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + self.interval, repeating: self.interval, leeway: .milliseconds(200))
            t.setEventHandler { [weak self] in
                guard let self else { return }
                let changed = self.checkNow()
                if !changed.isEmpty { self.onChange(changed) }
            }
            t.resume()
            self.timer = t
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    /// Compares the folder with the last look and returns which areas changed.
    public func checkNow() -> Set<Area> {
        let now = snapshot()
        var changed = Set<Area>()
        for area in Area.allCases where now[area] != last[area] {
            changed.insert(area)
        }
        last = now
        return changed
    }

    func snapshot() -> [Area: [String: Date]] {
        var result: [Area: [String: Date]] = [:]
        result[.bots] = stamps(in: paths.bots, files: ["bot.json", "CLAUDE.md", "AGENTS.md"])
        result[.skills] = stamps(in: paths.skills, files: ["SKILL.md"])
        result[.groups] = stamps(in: paths.groups, files: ["group.json"])
        result[.connectors] = stamp(paths.connectorsFile).map { [paths.connectorsFile.path: $0] } ?? [:]
        let routines = paths.root.appendingPathComponent("routines.json")
        result[.routines] = stamp(routines).map { [routines.path: $0] } ?? [:]
        var chats: [String: Date] = [:]
        if let names = try? fm.contentsOfDirectory(atPath: paths.chats.path) {
            for name in names where name.hasSuffix(".json") {
                let url = paths.chats.appendingPathComponent(name)
                chats[url.path] = stamp(url)
            }
        }
        result[.chats] = chats
        return result
    }

    private func stamps(in dir: URL, files: [String]) -> [String: Date] {
        var out: [String: Date] = [:]
        guard let children = try? fm.contentsOfDirectory(atPath: dir.path) else { return out }
        for child in children where !child.hasPrefix(".") {
            let childDir = dir.appendingPathComponent(child, isDirectory: true)
            // Record the folder itself so adding or removing an item counts as a change.
            out[childDir.path] = Date(timeIntervalSince1970: 0)
            for file in files {
                let url = childDir.appendingPathComponent(file)
                if let d = stamp(url) { out[url.path] = d }
            }
        }
        return out
    }

    private func stamp(_ url: URL) -> Date? {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return nil }
        let date = attrs[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)
        let size = (attrs[.size] as? NSNumber)?.doubleValue ?? 0
        // Fold the size in so two writes within the same second still register.
        return date.addingTimeInterval(size / 1_000_000_000)
    }
}
