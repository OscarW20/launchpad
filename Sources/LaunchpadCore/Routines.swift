import Foundation

/// Send a message to a bot or group on a schedule, or when a file appears. Runs while the app is open.
public struct Routine: Codable, Identifiable, Hashable, Sendable {
    public enum Target: Codable, Hashable, Sendable {
        case bot(String)
        case group(String)
    }

    public enum Trigger: Codable, Hashable, Sendable {
        case every(minutes: Int)
        case daily(hour: Int, minute: Int, weekdaysOnly: Bool)
        case newFile(folder: String)
    }

    public var id: String
    public var name: String
    public var target: Target
    public var message: String
    public var trigger: Trigger
    public var enabled: Bool
    /// The chat the routine posts into (made on first run).
    public var chatId: String?
    public var lastRun: Date?
    public var createdAt: Date

    public init(id: String, name: String, target: Target, message: String, trigger: Trigger,
                enabled: Bool = true, chatId: String? = nil, lastRun: Date? = nil, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.target = target
        self.message = message
        self.trigger = trigger
        self.enabled = enabled
        self.chatId = chatId
        self.lastRun = lastRun
        self.createdAt = createdAt
    }

    public var summary: String {
        switch trigger {
        case .every(let m):
            if m % 1440 == 0 { return "Every \(m / 1440 == 1 ? "day" : "\(m / 1440) days")" }
            if m % 60 == 0 { return "Every \(m / 60 == 1 ? "hour" : "\(m / 60) hours")" }
            return "Every \(m) minutes"
        case let .daily(h, m, weekdays):
            return "\(weekdays ? "Weekdays" : "Every day") at \(String(format: "%02d:%02d", h, m))"
        case .newFile(let folder):
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let shown = folder.hasPrefix(home) ? "~" + folder.dropFirst(home.count) : folder
            return "When a file appears in \(shown)"
        }
    }
}

public enum RoutineSchedule {
    /// Is a time-based routine due? (File routines are handled by `NewFileWatch`.)
    /// A daily routine missed while the app was closed runs once when it next opens, the same day.
    public static func isDue(_ r: Routine, now: Date, calendar: Calendar = .current) -> Bool {
        guard r.enabled else { return false }
        let since = r.lastRun ?? r.createdAt
        switch r.trigger {
        case .every(let minutes):
            return now.timeIntervalSince(since) >= Double(max(1, minutes)) * 60
        case let .daily(hour, minute, weekdaysOnly):
            guard let slot = lastSlot(hour: hour, minute: minute, weekdaysOnly: weekdaysOnly, before: now, calendar: calendar) else { return false }
            return slot > since && calendar.isDate(slot, inSameDayAs: now)
        case .newFile:
            return false
        }
    }

    /// The most recent scheduled time at or before `now`.
    static func lastSlot(hour: Int, minute: Int, weekdaysOnly: Bool, before now: Date, calendar: Calendar) -> Date? {
        var day = calendar.startOfDay(for: now)
        for _ in 0..<8 {
            if let slot = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day), slot <= now {
                let weekday = calendar.component(.weekday, from: slot)
                if !weekdaysOnly || (weekday != 1 && weekday != 7) { return slot }
            }
            guard let prev = calendar.date(byAdding: .day, value: -1, to: day) else { return nil }
            day = prev
        }
        return nil
    }
}

/// Spots files that appear in a folder after it starts watching.
public final class NewFileWatch {
    private var known: [String: Set<String>] = [:]
    private let fm = FileManager.default

    public init() {}

    /// Returns new file paths since the last call. The first call for a folder only takes a snapshot.
    public func newFiles(in folder: String) -> [String] {
        let path = (folder as NSString).expandingTildeInPath
        let current = Set(((try? fm.contentsOfDirectory(atPath: path)) ?? []).filter { !$0.hasPrefix(".") })
        defer { known[path] = current }
        guard let before = known[path] else { return [] }
        return current.subtracting(before).sorted().map { (path as NSString).appendingPathComponent($0) }
    }
}

public final class RoutineStore: @unchecked Sendable {
    public let url: URL

    public init(paths: LaunchpadPaths) {
        url = paths.root.appendingPathComponent("routines.json")
    }

    public func loadAll() -> [Routine] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONCoding.decoder().decode([Routine].self, from: data)) ?? []
    }

    public func saveAll(_ routines: [Routine]) throws {
        try JSONCoding.encoder().encode(routines).write(to: url, options: .atomic)
    }
}
