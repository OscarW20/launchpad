import Foundation

/// A request to make a routine, as a bot would send it through a `create_routine` tool (planned MCP tool):
///
/// ```json
/// {"name": "Morning brief", "target": "bot:planner", "message": "Brief me on today",
///  "trigger": {"type": "weekdays", "hour": 9, "minute": 0},
///  "catchUp": false, "ownChat": true, "enabled": true}
/// ```
///
/// `target` is `"bot:<id>"` or `"group:<id>"`. Trigger types: `once` (`at`: ISO 8601), `hourly` (`minute`),
/// `daily` / `weekdays` (`hour`, `minute`), `weekly` (`weekday` 1 = Sunday … 7, `hour`, `minute`), `every`
/// (`minutes`, at least 5), `folder` (`folder`: an existing folder), `webhook`.
public struct RoutineRequest: Codable, Equatable, Sendable {
    public struct TriggerSpec: Codable, Equatable, Sendable {
        public var type: String
        public var hour: Int?
        public var minute: Int?
        public var weekday: Int?
        public var minutes: Int?
        public var at: String?
        public var folder: String?

        public init(type: String, hour: Int? = nil, minute: Int? = nil, weekday: Int? = nil, minutes: Int? = nil,
                    at: String? = nil, folder: String? = nil) {
            self.type = type
            self.hour = hour
            self.minute = minute
            self.weekday = weekday
            self.minutes = minutes
            self.at = at
            self.folder = folder
        }
    }

    public var name: String
    public var target: String
    public var message: String
    public var trigger: TriggerSpec
    public var catchUp: Bool?
    public var ownChat: Bool?
    public var enabled: Bool?
}

public enum RoutineRequestError: Error, Equatable, LocalizedError, Sendable {
    case badJSON(String)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .badJSON(let why): return "The request isn't valid JSON for a routine: \(why)"
        case .invalid(let why): return why
        }
    }
}

public enum RoutineRequests {
    public static let maxRoutines = 100
    public static let maxNameLength = 80
    public static let maxMessageLength = 4000
    public static let minEveryMinutes = 5

    /// Checks a request and turns it into a routine (not saved). `bots` / `groups`: the ids that exist.
    public static func routine(from request: RoutineRequest, existing: [Routine], bots: Set<String>, groups: Set<String>,
                               now: Date = Date(), fileManager fm: FileManager = .default) -> Result<Routine, RoutineRequestError> {
        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = request.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.invalid("Give the routine a name.")) }
        guard name.count <= maxNameLength else { return .failure(.invalid("The name is over \(maxNameLength) characters.")) }
        guard !message.isEmpty else { return .failure(.invalid("Say what the routine should send (message).")) }
        guard message.count <= maxMessageLength else { return .failure(.invalid("The message is over \(maxMessageLength) characters.")) }
        guard existing.count < maxRoutines else { return .failure(.invalid("There are already \(maxRoutines) routines. Delete one first.")) }

        let target: Routine.Target
        let t = request.target.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("bot:"), bots.contains(String(t.dropFirst(4))) {
            target = .bot(String(t.dropFirst(4)))
        } else if t.hasPrefix("group:"), groups.contains(String(t.dropFirst(6))) {
            target = .group(String(t.dropFirst(6)))
        } else {
            return .failure(.invalid("No bot or group \"\(t)\". Use \"bot:<id>\" or \"group:<id>\" with an id that exists."))
        }

        let trigger: Routine.Trigger
        switch parseTrigger(request.trigger, now: now, fileManager: fm) {
        case .success(let tr): trigger = tr
        case .failure(let e): return .failure(e)
        }

        let id = Slug.unique(name, taken: Set(existing.map(\.id)))
        let r = Routine(id: id, name: name, target: target, message: message, trigger: trigger,
                        enabled: request.enabled ?? true, createdAt: now,
                        catchUp: request.catchUp ?? false, ownChat: request.ownChat ?? true)
        return .success(r.preparedForSave(stored: nil, now: now))
    }

    /// Decodes, checks and appends. Returns the new routine and the full list to save.
    public static func add(json: Data, to existing: [Routine], bots: Set<String>, groups: Set<String>,
                           now: Date = Date(), fileManager fm: FileManager = .default) -> Result<(routine: Routine, all: [Routine]), RoutineRequestError> {
        let request: RoutineRequest
        do {
            request = try JSONDecoder().decode(RoutineRequest.self, from: json)
        } catch {
            return .failure(.badJSON(describe(error)))
        }
        return routine(from: request, existing: existing, bots: bots, groups: groups, now: now, fileManager: fm)
            .map { ($0, existing + [$0]) }
    }

    static func parseTrigger(_ spec: RoutineRequest.TriggerSpec, now: Date, fileManager fm: FileManager) -> Result<Routine.Trigger, RoutineRequestError> {
        func time() -> Result<(Int, Int), RoutineRequestError> {
            guard let h = spec.hour, (0...23).contains(h) else { return .failure(.invalid("hour must be 0–23.")) }
            let m = spec.minute ?? 0
            guard (0...59).contains(m) else { return .failure(.invalid("minute must be 0–59.")) }
            return .success((h, m))
        }
        switch spec.type.lowercased() {
        case "daily", "weekdays":
            return time().map { .daily(hour: $0.0, minute: $0.1, weekdaysOnly: spec.type.lowercased() == "weekdays") }
        case "weekly":
            guard let wd = spec.weekday, (1...7).contains(wd) else { return .failure(.invalid("weekday must be 1 (Sunday) to 7 (Saturday).")) }
            return time().map { .weekly(weekday: wd, hour: $0.0, minute: $0.1) }
        case "hourly":
            let m = spec.minute ?? 0
            guard (0...59).contains(m) else { return .failure(.invalid("minute must be 0–59.")) }
            return .success(.hourly(minute: m))
        case "every":
            guard let n = spec.minutes, n >= minEveryMinutes, n <= 7 * 1440 else {
                return .failure(.invalid("minutes must be \(minEveryMinutes) to \(7 * 1440)."))
            }
            return .success(.every(minutes: n))
        case "once":
            guard let s = spec.at, let at = parseDate(s) else { return .failure(.invalid("at must be a date and time like 2026-12-01T09:00:00Z.")) }
            guard at > now else { return .failure(.invalid("That time has already passed.")) }
            return .success(.once(at: at))
        case "folder", "newfile":
            guard let raw = spec.folder?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
                return .failure(.invalid("Say which folder to watch (folder)."))
            }
            let path = FolderArrivalWatch.standard(raw)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                return .failure(.invalid("There's no folder at \(raw)."))
            }
            guard path != "/", path != FolderArrivalWatch.standard(fm.homeDirectoryForCurrentUser.path) else {
                return .failure(.invalid("Pick a specific folder, not your whole home folder or disk."))
            }
            return .success(.newFile(folder: path))
        case "webhook":
            return .success(.webhook)
        default:
            return .failure(.invalid("Unknown trigger type \"\(spec.type)\". Use once, hourly, daily, weekdays, weekly, every, folder or webhook."))
        }
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, _): return "\(key.stringValue) is missing"
        case DecodingError.typeMismatch(_, let ctx), DecodingError.valueNotFound(_, let ctx):
            return "\(ctx.codingPath.map(\.stringValue).joined(separator: ".")) has the wrong type"
        default: return "it couldn't be read"
        }
    }
}
