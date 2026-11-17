import XCTest
@testable import LaunchpadCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// Ported from Biscuit Bots' AutomationTests / AutomationFixTests, against LaunchpadCore types.

private var london: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/London")!
    return c
}

private func date(_ s: String) -> Date {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_GB")
    f.timeZone = TimeZone(identifier: "Europe/London")
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.date(from: s)!
}

private func tempDir(_ tag: String = "lp-auto") throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - Routine model: decoding and triggers

final class RoutineModelTests: XCTestCase {
    /// routines.json exactly as phase 6 wrote it.
    func testPhase6RoutinesStillDecode() throws {
        let json = """
        [{"chatId":"c1","createdAt":"2026-11-17T08:00:00Z","enabled":true,"id":"standup","lastRun":"2026-11-17T09:30:00Z",
          "message":"Standup","name":"Standup","target":{"group":{"_0":"team"}},
          "trigger":{"daily":{"hour":9,"minute":30,"weekdaysOnly":true}}},
         {"createdAt":"2026-11-17T08:00:00Z","enabled":false,"id":"inbox","message":"Sort it","name":"Inbox",
          "target":{"bot":{"_0":"a"}},"trigger":{"newFile":{"folder":"/tmp/x"}}},
         {"createdAt":"2026-11-17T08:00:00Z","enabled":true,"id":"tick","message":"Hi","name":"Tick",
          "target":{"bot":{"_0":"a"}},"trigger":{"every":{"minutes":60}}}]
        """
        let list = try JSONCoding.decoder().decode([Routine].self, from: Data(json.utf8))
        XCTAssertEqual(list.map(\.id), ["standup", "inbox", "tick"])
        let r = list[0]
        XCTAssertEqual(r.target, .group("team"))
        XCTAssertEqual(r.trigger, .daily(hour: 9, minute: 30, weekdaysOnly: true))
        XCTAssertNil(r.ownChat)
        XCTAssertFalse(r.runsInOwnChat, "an older routine keeps posting in its one chat")
        XCTAssertNil(r.catchUp)
        XCTAssertTrue(r.catchesUp, "older routines keep catching up a missed run")
        XCTAssertEqual(list[1].watchedFolder, "/tmp/x")
        XCTAssertEqual(list[2].trigger, .every(minutes: 60))
    }

    func testNewTriggersRoundTrip() throws {
        let triggers: [Routine.Trigger] = [.hourly(minute: 15), .weekly(weekday: 2, hour: 9, minute: 0),
                                           .once(at: Date(timeIntervalSince1970: 1_800_000_000)), .webhook]
        for t in triggers {
            let r = Routine(id: "r", name: "R", target: .bot("a"), message: "m", trigger: t,
                            createdAt: Date(timeIntervalSince1970: 1_800_000_000), catchUp: false, ownChat: true)
            let back = try JSONCoding.decoder().decode(Routine.self, from: JSONCoding.encoder().encode(r))
            XCTAssertEqual(back, r)
        }
    }

    func testSummaries() {
        func s(_ t: Routine.Trigger) -> String { Routine(id: "r", name: "R", target: .bot("a"), message: "", trigger: t).summary }
        XCTAssertEqual(s(.hourly(minute: 5)), "Every hour at :05")
        XCTAssertEqual(s(.weekly(weekday: 2, hour: 9, minute: 0)), "Mondays at 09:00")
        XCTAssertEqual(s(.webhook), "When its web address is called")
        XCTAssertEqual(s(.daily(hour: 9, minute: 0, weekdaysOnly: true)), "Weekdays at 09:00")
    }

    func testNonClockTriggersNeverFireOnTheClock() {
        let now = Date()
        for t in [Routine.Trigger.webhook, .newFile(folder: "/tmp")] {
            let r = Routine(id: "r", name: "Hook", target: .bot("a"), message: "Go", trigger: t, createdAt: now.addingTimeInterval(-86_400 * 3))
            XCTAssertNil(RoutineSchedule.lastSlot(of: r, before: now))
            XCTAssertFalse(RoutineSchedule.isDue(r, now: now))
            XCTAssertNil(RoutineSchedule.missed(r, now: now))
            XCTAssertTrue(RoutineSchedule.slots(of: r, in: DateInterval(start: now, duration: 86_400)).isEmpty)
            XCTAssertTrue(RoutineSchedule.tick([r], now: now).events.isEmpty)
        }
    }

    func testHourlyAndWeeklySlots() {
        var r = Routine(id: "h", name: "H", target: .bot("a"), message: "", trigger: .hourly(minute: 15),
                        createdAt: date("2026-11-10 08:00"))
        XCTAssertEqual(RoutineSchedule.lastSlot(of: r, before: date("2026-11-12 10:20"), calendar: london), date("2026-11-12 10:15"))
        XCTAssertEqual(RoutineSchedule.lastSlot(of: r, before: date("2026-11-12 10:05"), calendar: london), date("2026-11-12 09:15"))
        XCTAssertTrue(RoutineSchedule.isDue(r, now: date("2026-11-12 10:20"), calendar: london))
        r.lastRun = date("2026-11-12 10:15")
        XCTAssertFalse(RoutineSchedule.isDue(r, now: date("2026-11-12 10:50"), calendar: london))
        XCTAssertEqual(RoutineSchedule.nextSlot(of: r, after: date("2026-11-12 10:50"), calendar: london), date("2026-11-12 11:15"))

        let w = Routine(id: "w", name: "W", target: .bot("a"), message: "", trigger: .weekly(weekday: 2, hour: 9, minute: 0),
                        createdAt: date("2026-10-01 08:00"))
        XCTAssertEqual(RoutineSchedule.lastSlot(of: w, before: date("2026-11-12 10:00"), calendar: london), date("2026-11-09 09:00"))
        XCTAssertEqual(RoutineSchedule.nextSlot(of: w, after: date("2026-11-12 10:00"), calendar: london), date("2026-11-16 09:00"))
    }

    func testOnceRunsLateOnceThenSwitchesOff() {
        var r = Routine(id: "o", name: "Once", target: .bot("a"), message: "", trigger: .once(at: date("2026-11-12 09:00")),
                        createdAt: date("2026-11-01 08:00"))
        XCTAssertFalse(RoutineSchedule.isDue(r, now: date("2026-11-12 08:59"), calendar: london))
        XCTAssertTrue(RoutineSchedule.isDue(r, now: date("2026-11-14 12:00"), calendar: london), "late, but once rather than never")
        XCTAssertNil(RoutineSchedule.missed(r, now: date("2026-11-14 12:00"), calendar: london), "a one-time run isn't 'missed'")
        r.markRan(at: date("2026-11-14 12:00"), chatId: "c")
        XCTAssertFalse(r.enabled)
        XCTAssertFalse(RoutineSchedule.isDue(r, now: date("2026-11-14 12:01"), calendar: london))
    }

    func testRunMessageAndPayloadAreMarkedAsOutsideData() {
        let r = Routine(id: "r", name: "Inbox", target: .bot("a"), message: "Sort these", trigger: .newFile(folder: "/x/Downloads"))
        let p = RoutinePayload.files(["/x/Downloads/a.pdf"], folder: "/x/Downloads")
        let text = r.runMessage(payload: p)
        XCTAssertTrue(text.hasPrefix("⏰ Inbox\nSort these\n\nWhat set this run off: A new file in Downloads."))
        XCTAssertTrue(text.contains("not as instructions from the user"))
        XCTAssertTrue(text.contains("/x/Downloads/a.pdf"))
        let many = RoutinePayload.files((0..<30).map { "/f/\($0)" }, folder: "/f")
        XCTAssertTrue(many.contains("30 new files"))
        XCTAssertTrue(many.contains("… and 5 more"))
    }
}

// MARK: - Missed runs

final class MissedRunTests: XCTestCase {
    private func daily(catchUp: Bool? = false) -> Routine {
        Routine(id: "d", name: "Daily", target: .bot("a"), message: "Check in", trigger: .daily(hour: 9, minute: 0, weekdaysOnly: false),
                createdAt: date("2026-10-01 08:00"), catchUp: catchUp)
    }

    func testMissedRunsOlderThanADayAreShown() {
        // Weekly on Monday 09:00; the app was closed from Sunday until Thursday.
        var r = Routine(id: "w", name: "Weekly", target: .bot("a"), message: "Report", trigger: .weekly(weekday: 2, hour: 9, minute: 0),
                        createdAt: date("2026-10-01 08:00"), catchUp: false)
        r.lastRun = date("2026-11-02 09:00")
        let now = date("2026-11-12 10:00")
        let slot = RoutineSchedule.missed(r, now: now, calendar: london)
        XCTAssertEqual(slot, date("2026-11-09 09:00"))
        XCTAssertEqual(RoutineSchedule.missedRuns(r, upTo: slot!, calendar: london), 1)
    }

    func testMissedCountCoversEverySlotSinceTheLastRun() {
        var r = daily()
        r.lastRun = date("2026-11-09 09:00")
        let now = date("2026-11-12 18:00")
        let slot = RoutineSchedule.missed(r, now: now, calendar: london)
        XCTAssertEqual(slot, date("2026-11-12 09:00"))
        XCTAssertEqual(RoutineSchedule.missedRuns(r, upTo: slot!, calendar: london), 3, "10th, 11th and 12th")
        var handled = r
        handled.missedSlot = slot
        XCTAssertNil(RoutineSchedule.missed(handled, now: now, calendar: london), "dealt with: not reported again")
    }

    func testDaysTheRoutineWasOffArentCountedAsMissed() {
        var r = daily()
        r.lastRun = date("2026-11-01 09:00")
        // Switched off on the 2nd, back on at noon on the 14th (saving marks the 14th's run as dealt with).
        r = r.preparedForSave(stored: r, now: date("2026-11-14 12:00"), calendar: london)
        let slot = RoutineSchedule.missed(r, now: date("2026-11-15 11:00"), calendar: london)
        XCTAssertEqual(slot, date("2026-11-15 09:00"))
        XCTAssertEqual(RoutineSchedule.missedRuns(r, upTo: slot!, calendar: london), 1, "only the 15th; the 2nd–14th it was off")
    }

    func testSkippedRunsArentCountedAgain() {
        var r = daily()
        r.lastRun = date("2026-11-10 09:00")
        let first = RoutineSchedule.tick([r], now: date("2026-11-13 11:00"), calendar: london)
        XCTAssertEqual(first.events, [.missed("d", missed: 3, last: date("2026-11-13 09:00"))])
        r = first.routines[0]
        XCTAssertEqual(r.missedPending, date("2026-11-13 09:00"))
        XCTAssertEqual(r.missedCount, 3)
        r.skipMissed()
        let next = RoutineSchedule.tick([r], now: date("2026-11-14 11:00"), calendar: london)
        XCTAssertEqual(next.events, [.missed("d", missed: 1, last: date("2026-11-14 09:00"))], "the three you skipped stay skipped")
    }

    func testMissesStillWaitingAddUp() {
        var r = daily()
        r.lastRun = date("2026-11-10 09:00")
        r = RoutineSchedule.tick([r], now: date("2026-11-13 11:00"), calendar: london).routines[0]
        XCTAssertTrue(RoutineSchedule.tick([r], now: date("2026-11-13 11:20"), calendar: london).events.isEmpty, "reported once")
        let next = RoutineSchedule.tick([r], now: date("2026-11-14 11:00"), calendar: london)
        XCTAssertEqual(next.events, [.missed("d", missed: 4, last: date("2026-11-14 09:00"))])
    }

    func testCatchUpRunsOnceAndSaysSo() {
        var r = daily(catchUp: true)
        r.lastRun = date("2026-11-09 09:00")
        let tick = RoutineSchedule.tick([r], now: date("2026-11-12 18:00"), calendar: london)
        XCTAssertEqual(tick.events, [.catchUp("d", missed: 3, last: date("2026-11-12 09:00"))])
        XCTAssertTrue(tick.events[0].runsNow)
        XCTAssertNil(tick.routines[0].missedPending, "nothing left waiting: it runs now")
        let note = RoutineSchedule.missedNotice(name: "Daily", missed: 3, last: date("2026-11-12 09:00"), caughtUp: true,
                                                now: date("2026-11-12 18:00"), calendar: london)
        XCTAssertEqual(note, "“Daily” missed 3 runs (the last at 09:00) while your Mac was asleep or Launchpad was closed, so it's running once now.")
    }

    func testOnTimeRunsAndMissingTargetsInATick() {
        let on = Routine(id: "on", name: "On", target: .bot("a"), message: "", trigger: .daily(hour: 9, minute: 0, weekdaysOnly: false),
                         createdAt: date("2026-11-01 08:00"))
        let gone = Routine(id: "gone", name: "Gone", target: .bot("deleted"), message: "", trigger: .daily(hour: 9, minute: 0, weekdaysOnly: false),
                           createdAt: date("2026-11-01 08:00"))
        let tick = RoutineSchedule.tick([on, gone], now: date("2026-11-12 09:10"), calendar: london) { $0 != .bot("deleted") }
        XCTAssertEqual(tick.events, [.due("on")])
    }

    func testSavingAnEditorOpenDuringARunKeepsTheRun() {
        let now = Date()
        var stored = Routine(id: "h", name: "Hourly", target: .bot("a"), message: "x", trigger: .hourly(minute: 0),
                             createdAt: now.addingTimeInterval(-86_400), ownChat: true)
        let editorCopy = stored
        _ = stored.markRan(at: now, chatId: "run-1")
        var edited = editorCopy
        edited.message = "y"
        let saved = edited.preparedForSave(stored: stored, now: now)
        XCTAssertEqual(saved.message, "y", "your edits are kept")
        XCTAssertEqual(saved.lastRun, now)
        XCTAssertEqual(saved.lastRunChat, "run-1")
        XCTAssertEqual(saved.runChats, ["run-1"])
        XCTAssertFalse(RoutineSchedule.isDue(saved, now: now), "it doesn't run a second time")
    }

    func testAOneTimeRoutineThatRanWhileEditedStaysOff() {
        let now = Date()
        var stored = Routine(id: "o", name: "Once", target: .bot("a"), message: "x", trigger: .once(at: now.addingTimeInterval(-300)))
        let editorCopy = stored
        stored.markRan(at: now, chatId: "c")
        XCTAssertFalse(stored.enabled)
        let saved = editorCopy.keepingRunState(of: stored)
        XCTAssertFalse(saved.enabled)
        XCTAssertFalse(RoutineSchedule.isDue(saved, now: now))
        var moved = editorCopy
        moved.trigger = .once(at: now.addingTimeInterval(86_400))
        XCTAssertTrue(moved.keepingRunState(of: stored).enabled, "moved to tomorrow: it's on for that")
    }
}

// MARK: - Run chats

final class RunChatTests: XCTestCase {
    func testOnlyTheNewestRunChatsAreKept() {
        let chats = (0..<35).map { "run-\($0)" }
        let drop = RoutineRuns.chatsToDrop(chats, keep: 30) { $0 == "run-1" }
        XCTAssertEqual(drop, ["run-0", "run-2", "run-3", "run-4"], "the oldest 5 go, except the busy one")
        XCTAssertTrue(RoutineRuns.chatsToDrop(chats, keep: 40) { _ in false }.isEmpty)
        XCTAssertEqual(RoutineRuns.kept, 30)
    }

    func testMarkRanKeepsRunChatsTrimmed() {
        var r = Routine(id: "r", name: "R", target: .bot("a"), message: "", trigger: .webhook, ownChat: true)
        var dropped: [String] = []
        for i in 0..<5 { dropped += r.markRan(at: Date(), chatId: "c\(i)", keep: 3) }
        XCTAssertEqual(r.runChats, ["c2", "c3", "c4"])
        XCTAssertEqual(dropped, ["c0", "c1"])
        XCTAssertEqual(r.lastRunChat, "c4")
        XCTAssertNil(r.chatId, "run chats don't replace the routine's own chat")

        var legacy = Routine(id: "l", name: "L", target: .bot("a"), message: "", trigger: .every(minutes: 60))
        XCTAssertEqual(legacy.markRan(at: Date(), chatId: "main"), [])
        XCTAssertEqual(legacy.chatId, "main")
        XCTAssertNil(legacy.runChats)
    }
}

// MARK: - New file in a folder

final class FolderArrivalTests: XCTestCase {
    func testNewFilesAreReportedOnceFinishedAndPartialOnesIgnored() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("old".utf8).write(to: dir.appendingPathComponent("already-there.txt"))
        let w = FolderArrivalWatch()
        let t = Date()
        XCTAssertEqual(w.check(dir.path, now: t), .files([]), "the first look is a snapshot")

        try Data("partial".utf8).write(to: dir.appendingPathComponent("movie.mov.crdownload"))
        try Data("hidden".utf8).write(to: dir.appendingPathComponent(".DS_Store"))
        try Data("new".utf8).write(to: dir.appendingPathComponent("export.png"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        XCTAssertEqual(w.check(dir.path, now: t.addingTimeInterval(2)), .files([]), "seen once: waiting to see it stop growing")
        XCTAssertTrue(w.hasPending)
        XCTAssertEqual(w.check(dir.path, now: t.addingTimeInterval(4)), .files([dir.appendingPathComponent("export.png").path]))
        XCTAssertEqual(w.check(dir.path, now: t.addingTimeInterval(6)), .files([]), "reported once")
    }

    func testAGrowingFileWaitsUntilItStops() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let w = FolderArrivalWatch()
        let t = Date()
        _ = w.check(dir.path, now: t)
        let f = dir.appendingPathComponent("big.zip")
        try Data(repeating: 1, count: 10).write(to: f)
        XCTAssertEqual(w.check(dir.path, now: t.addingTimeInterval(1)), .files([]))
        try Data(repeating: 1, count: 20).write(to: f)
        XCTAssertEqual(w.check(dir.path, now: t.addingTimeInterval(2)), .files([]), "still growing")
        XCTAssertEqual(w.check(dir.path, now: t.addingTimeInterval(3)), .files([f.path]))
    }

    /// Firefox: an empty "report.pdf" placeholder plus "report.pdf.part", then the .part is moved over the placeholder.
    func testAFirefoxDownloadIsReportedOnceItsReal() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let w = FolderArrivalWatch(emptyGrace: 2)
        let t = Date()
        _ = w.check(dir.path, now: t)
        let final = dir.appendingPathComponent("report.pdf"), part = dir.appendingPathComponent("report.pdf.part")
        FileManager.default.createFile(atPath: final.path, contents: Data())
        FileManager.default.createFile(atPath: part.path, contents: Data(repeating: 1, count: 100))
        for s in 1...6 {   // 6 s of downloading: longer than the empty grace, so only the .part keeps it waiting
            XCTAssertEqual(w.check(dir.path, now: t.addingTimeInterval(Double(s))), .files([]), "second \(s)")
        }
        try FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: part, to: final)
        XCTAssertEqual(w.check(dir.path, now: t.addingTimeInterval(7)), .files([]), "new size: one more look")
        XCTAssertEqual(w.check(dir.path, now: t.addingTimeInterval(8)), .files([final.path]))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: final.path)[.size] as? NSNumber)?.intValue, 100)
    }

    func testAnEmptyFileOnItsOwnIsReportedAfterAWhile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let w = FolderArrivalWatch(emptyGrace: 10)
        let t = Date()
        _ = w.check(dir.path, now: t)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("marker").path, contents: Data())
        XCTAssertEqual(w.check(dir.path, now: t.addingTimeInterval(1)), .files([]))
        XCTAssertEqual(w.check(dir.path, now: t.addingTimeInterval(5)), .files([]))
        XCTAssertEqual(w.check(dir.path, now: t.addingTimeInterval(11.5)), .files([dir.appendingPathComponent("marker").path]))
    }

    func testWatchingStartsAgainWhenADeletedFolderComesBack() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let triggers = FolderTriggers(cooldown: 0)
        let r = Routine(id: "inbox", name: "Inbox", target: .bot("a"), message: "", trigger: .newFile(folder: dir.path))
        let t = Date()
        triggers.prime([r], now: t)
        try FileManager.default.removeItem(at: dir)
        XCTAssertEqual(triggers.poll([r], now: t.addingTimeInterval(1)).unavailable, ["inbox"], "the row can warn")

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("was-there-when-it-came-back.txt"))
        XCTAssertEqual(triggers.poll([r], now: t.addingTimeInterval(2)), FolderTriggers.Poll(), "back: a fresh snapshot")
        try Data("hi".utf8).write(to: dir.appendingPathComponent("after.txt"))
        _ = triggers.poll([r], now: t.addingTimeInterval(3))
        XCTAssertEqual(triggers.poll([r], now: t.addingTimeInterval(4)).runs, ["inbox": [dir.appendingPathComponent("after.txt").path]])
    }

    func testAFolderReplacedStraightAwayStartsAFreshSnapshot() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let w = FolderArrivalWatch()
        let t = Date()
        _ = w.check(dir.path, now: t)
        // Replaced between two looks: a new folder (new inode) full of files that were never "new" to us.
        let other = try tempDir()
        try Data("x".utf8).write(to: other.appendingPathComponent("old-contents.txt"))
        try FileManager.default.removeItem(at: dir)
        try FileManager.default.moveItem(at: other, to: dir)
        XCTAssertEqual(w.check(dir.path, now: t.addingTimeInterval(1)), .files([]))
        XCTAssertEqual(w.check(dir.path, now: t.addingTimeInterval(2)), .files([]), "its contents don't count as new")
        try Data("y".utf8).write(to: dir.appendingPathComponent("later.txt"))
        _ = w.check(dir.path, now: t.addingTimeInterval(3))
        XCTAssertEqual(w.check(dir.path, now: t.addingTimeInterval(4)), .files([dir.appendingPathComponent("later.txt").path]))
    }

    func testABurstOfFilesIsOneRunAndTheCooldownBatchesTheRest() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let triggers = FolderTriggers(cooldown: 60)
        let r = Routine(id: "inbox", name: "Inbox", target: .bot("a"), message: "", trigger: .newFile(folder: dir.path))
        let off = Routine(id: "off", name: "Off", target: .bot("a"), message: "", trigger: .newFile(folder: dir.path), enabled: false)
        let t = Date()
        triggers.prime([r, off], now: t)
        for n in ["a", "b"] { try Data(n.utf8).write(to: dir.appendingPathComponent("\(n).txt")) }
        _ = triggers.poll([r, off], now: t.addingTimeInterval(1))
        let first = triggers.poll([r, off], now: t.addingTimeInterval(2))
        XCTAssertEqual(first.runs.keys.sorted(), ["inbox"])
        XCTAssertEqual(first.runs["inbox"]?.map { ($0 as NSString).lastPathComponent }, ["a.txt", "b.txt"])

        try Data("c".utf8).write(to: dir.appendingPathComponent("c.txt"))
        _ = triggers.poll([r, off], now: t.addingTimeInterval(3))
        XCTAssertTrue(triggers.poll([r, off], now: t.addingTimeInterval(4)).runs.isEmpty, "inside the cool-down it waits")
        let later = triggers.poll([r, off], now: t.addingTimeInterval(63))
        XCTAssertEqual(later.runs["inbox"]?.map { ($0 as NSString).lastPathComponent }, ["c.txt"])
    }
}

// MARK: - Webhook checks

final class WebhookAuthTests: XCTestCase {
    private let id = "inbox-hook"
    private let secret = WebhookSecrets.newToken()

    private func request(_ method: String = "POST", path: String? = nil, headers: [String: String] = [:], body: String = "{}") -> HTTPRequest {
        var head = "\(method) \(path ?? "/hooks/\(id)") HTTP/1.1\r\nHost: 127.0.0.1:8791\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "Content-Length: \(body.utf8.count)\r\n\r\n"
        guard case .complete(let req) = HTTPRequest.parse(Data((head + body).utf8)) else { fatalError("didn't parse") }
        return req
    }

    private func check(_ req: HTTPRequest) -> WebhookAuth.Decision {
        WebhookAuth.check(req) { $0 == self.id ? self.secret : nil }
    }

    func testParsing() {
        let raw = "POST /hooks/a?token=x%20y&b=1 HTTP/1.1\r\nHost: localhost\r\nX-Thing:  v \r\nContent-Length: 5\r\n\r\nhello"
        guard case .complete(let r) = HTTPRequest.parse(Data(raw.utf8)) else { return XCTFail() }
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/hooks/a")
        XCTAssertEqual(r.query, ["token": "x y", "b": "1"])
        XCTAssertEqual(r.headers["x-thing"], "v")
        XCTAssertEqual(r.body, Data("hello".utf8))
        XCTAssertEqual(HTTPRequest.parse(Data(raw.dropLast(2).utf8)), .incomplete, "body not all in yet")
        XCTAssertEqual(HTTPRequest.parse(Data("POST /x HTTP/1.1\r\nHost: a".utf8)), .incomplete)
        XCTAssertEqual(HTTPRequest.parse(Data("NONSENSE\r\n\r\n".utf8)), .invalid)
        XCTAssertEqual(HTTPRequest.parse(Data("POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8)), .invalid)
    }

    func testTokensAreLongAndRandom() {
        let a = WebhookSecrets.newToken(), b = WebhookSecrets.newToken()
        XCTAssertEqual(a.count, 64)
        XCTAssertNotEqual(a, b)
    }

    func testTheRightSecretIsAcceptedThreeWays() {
        XCTAssertEqual(check(request(headers: ["Authorization": "Bearer \(secret)"])), .accept(id))
        XCTAssertEqual(check(request(headers: ["X-Launchpad-Token": secret])), .accept(id))
        XCTAssertEqual(check(request(path: "/hooks/\(id)?token=\(secret)")), .accept(id))
        XCTAssertEqual(check(request(path: "/hooks/\(id)/", headers: ["Authorization": "bearer \(secret)"])), .accept(id))
    }

    func testWrongOrMissingSecretIsRefused() {
        XCTAssertEqual(check(request()), .reject(401, "Wrong or missing secret"))
        XCTAssertEqual(check(request(headers: ["Authorization": "Bearer nope"])), .reject(401, "Wrong or missing secret"))
        XCTAssertEqual(check(request(headers: ["Authorization": "Bearer \(secret.dropLast())"])), .reject(401, "Wrong or missing secret"))
        XCTAssertEqual(check(request(path: "/hooks/someone-else", headers: ["Authorization": "Bearer \(secret)"])),
                       .reject(401, "Wrong or missing secret"), "another routine's id looks the same as a wrong secret")
    }

    func testOnlyPostToAHookPathFromThisMac() {
        XCTAssertEqual(check(request("GET", headers: ["Authorization": "Bearer \(secret)"])), .reject(405, "Use POST"))
        XCTAssertEqual(check(request(path: "/state")), .reject(404, "Not found"))
        XCTAssertEqual(check(request(path: "/hooks/../etc")), .reject(404, "Not found"))
        XCTAssertEqual(check(request(path: "/hooks/")), .reject(404, "Not found"))
        var req = request(headers: ["Authorization": "Bearer \(secret)"])
        req.headers["host"] = "evil.example:8791"
        XCTAssertEqual(check(req), .reject(403, "Only this Mac can call this address"))
    }

    func testLoopbackHosts() {
        for h in ["127.0.0.1", "127.0.0.1:8791", "localhost:8791", "LOCALHOST", "[::1]:8791", "[::1]"] {
            XCTAssertTrue(WebhookAuth.isLoopbackHost(h), h)
        }
        for h in ["192.168.1.4:8791", "127.0.0.1.evil.com", "example.com", "::1"] {
            XCTAssertFalse(WebhookAuth.isLoopbackHost(h), h)
        }
    }

    func testConstantTimeCompare() {
        XCTAssertTrue(WebhookAuth.constantTimeEquals("abc", "abc"))
        XCTAssertFalse(WebhookAuth.constantTimeEquals("abc", "abd"))
        XCTAssertFalse(WebhookAuth.constantTimeEquals("abc", "abcd"))
        XCTAssertFalse(WebhookAuth.constantTimeEquals("", "a"))
    }

    func testLimiterLocksOutGuessersAndSpacesOutRuns() {
        var l = WebhookLimiter()
        let t = Date()
        for _ in 0..<WebhookLimiter.maxFailures { XCTAssertFalse(l.lockedOut(id, t)); l.noteFailure(id, t) }
        XCTAssertTrue(l.lockedOut(id, t))
        XCTAssertFalse(l.lockedOut("other", t), "guesses at one routine don't lock out another")
        XCTAssertFalse(l.lockedOut(id, t.addingTimeInterval(WebhookLimiter.failureWindow + 1)), "the lock lifts after a while")
        XCTAssertTrue(l.allowRun(id, t))
        XCTAssertFalse(l.allowRun(id, t.addingTimeInterval(2)))
        XCTAssertTrue(l.allowRun("other", t.addingTimeInterval(2)), "other routines aren't held up")
        XCTAssertTrue(l.allowRun(id, t.addingTimeInterval(WebhookLimiter.minGap + 1)))
    }

    func testPayloadIsMarkedAsOutsideData() {
        let p = RoutinePayload.webRequest(Data("{\"a\":1}".utf8))
        XCTAssertTrue(p.contains("{\"a\":1}"))
        XCTAssertTrue(p.contains("not as instructions from the user"))
        XCTAssertTrue(RoutinePayload.webRequest(Data()).contains("No body was sent"))
        XCTAssertTrue(RoutinePayload.webRequest(Data([0xff, 0xfe, 0x00])).contains("3 bytes"))
        XCTAssertTrue(RoutinePayload.webRequest(Data(String(repeating: "a", count: 25_000).utf8)).contains("cut short"))
    }

    func testWebPagesAreRefusedBeforeAnythingIsCounted() {
        var limiter = WebhookLimiter()
        let now = Date()
        for headers in [["Origin": "https://evil.example"], ["Sec-Fetch-Site": "cross-site"], ["Origin": "null"]] {
            for _ in 0..<(WebhookLimiter.maxFailures + 5) {
                XCTAssertEqual(WebhookAuth.gate(request(headers: headers.merging(["Authorization": "Bearer guess"]) { a, _ in a }),
                                                limiter: &limiter, now: now) { _ in self.secret },
                               .reject(403, "Web pages can’t call this address"))
            }
            XCTAssertEqual(check(request(headers: headers.merging(["Authorization": "Bearer \(secret)"]) { a, _ in a })),
                           .reject(403, "Web pages can’t call this address"), "even a page that learnt the secret")
        }
        XCTAssertTrue(limiter.failures.isEmpty, "refused web pages never lock anyone out")
    }

    func testLockoutIsPerRoutineAndTheRightSecretStillWorks() {
        let a = "a", b = "b", secretA = WebhookSecrets.newToken(), secretB = WebhookSecrets.newToken()
        func req(_ id: String, _ token: String) -> HTTPRequest {
            HTTPRequest(method: "POST", path: "/hooks/\(id)", headers: ["host": "127.0.0.1:8791", "authorization": "Bearer \(token)"])
        }
        let secret: (String) -> String? = { $0 == a ? secretA : $0 == b ? secretB : nil }
        var limiter = WebhookLimiter()
        let now = Date()
        for _ in 0..<WebhookLimiter.maxFailures {
            XCTAssertEqual(WebhookAuth.gate(req(a, "guess"), limiter: &limiter, now: now, secret: secret), .reject(401, "Wrong or missing secret"))
        }
        XCTAssertEqual(WebhookAuth.gate(req(a, "guess"), limiter: &limiter, now: now, secret: secret),
                       .reject(429, "Too many wrong tries. Wait a few minutes."))
        XCTAssertEqual(WebhookAuth.gate(req(a, secretA), limiter: &limiter, now: now, secret: secret), .accept(a))
        XCTAssertEqual(WebhookAuth.gate(req(b, secretB), limiter: &limiter, now: now, secret: secret), .accept(b))
        XCTAssertEqual(WebhookAuth.gate(req(b, "guess"), limiter: &limiter, now: now, secret: secret), .reject(401, "Wrong or missing secret"))
    }

    func testRefusedEarlyWhenTooBigOrChunked() {
        XCTAssertNil(WebhookAuth.refuseEarly(Data("POST /hooks/a HTTP/1.1\r\nContent-Length: 10\r\n\r\n".utf8)))
        XCTAssertEqual(WebhookAuth.refuseEarly(Data("POST /hooks/a HTTP/1.1\r\nContent-Length: 70000\r\n\r\n".utf8))?.status, 413)
        XCTAssertEqual(WebhookAuth.refuseEarly(Data("POST /hooks/a HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))?.status, 411)
        XCTAssertEqual(WebhookAuth.refuseEarly(Data(repeating: 0x61, count: WebhookAuth.maxHead + 1))?.status, 431)
    }

    func testRouterRunsOnlyEnabledWebhookRoutinesWithTheirSecret() {
        let hook = Routine(id: "hook", name: "Hook", target: .bot("a"), message: "Go", trigger: .webhook)
        var off = Routine(id: "off", name: "Off", target: .bot("a"), message: "Go", trigger: .webhook)
        off.enabled = false
        let timed = Routine(id: "timed", name: "Timed", target: .bot("a"), message: "Go", trigger: .every(minutes: 60))
        let gone = Routine(id: "gone", name: "Gone", target: .bot("deleted"), message: "Go", trigger: .webhook)
        let secrets = ["hook": "s1", "off": "s2", "timed": "s3", "gone": "s4"]
        var limiter = WebhookLimiter()
        let now = Date()
        func call(_ id: String, _ token: String, at: Date = now) -> WebhookOutcome {
            WebhookRouter.handle(HTTPRequest(method: "POST", path: "/hooks/\(id)", headers: ["authorization": "Bearer \(token)"], body: Data("{\"x\":1}".utf8)),
                                 routines: [hook, off, timed, gone], secrets: secrets, limiter: &limiter, now: at) { $0 != .bot("deleted") }
        }
        let ok = call("hook", "s1")
        XCTAssertEqual(ok.response.status, 200)
        XCTAssertEqual(ok.run?.id, "hook")
        XCTAssertTrue(ok.run?.payload.contains("{\"x\":1}") == true)
        XCTAssertEqual(call("hook", "s1", at: now.addingTimeInterval(1)).response.status, 429, "spaced out")
        XCTAssertEqual(call("off", "s2").response.status, 401, "switched off looks unknown")
        XCTAssertEqual(call("timed", "s3").response.status, 401, "not a web address routine")
        XCTAssertEqual(call("gone", "s4").response.status, 409)
        XCTAssertNil(call("gone", "s4").run)
    }
}

// MARK: - Webhook secrets

final class WebhookSecretTests: XCTestCase {
    final class LockedStore: SecretStore {
        var value: String?
        var read: SecretRead = .missing
        var writes = 0
        func secret(_ account: String) -> String? { value }
        func setSecret(_ value: String?, for account: String) throws { writes += 1; self.value = value }
        func read(_ account: String) -> SecretRead { read }
    }

    func testAKeychainErrorNeverReplacesTheSecret() {
        var made = 0
        let make = { () -> String? in made += 1; return "new" }
        XCTAssertNil(WebhookSecrets.secret(from: .failed("Keychain locked"), make: make))
        XCTAssertNil(WebhookSecrets.secret(from: .failed("Interaction not allowed"), make: make))
        XCTAssertEqual(made, 0, "a denied or locked Keychain doesn't mint a new secret")
        XCTAssertEqual(WebhookSecrets.secret(from: .found("old"), make: make), "old")
        XCTAssertEqual(WebhookSecrets.secret(from: .missing, make: make), "new")
        XCTAssertEqual(made, 1)

        let locked = LockedStore()
        locked.read = .failed("Interaction not allowed")
        XCTAssertNil(WebhookSecrets.token(for: "r", in: locked))
        XCTAssertEqual(locked.writes, 0)
    }

    func testSecretsLiveInTheSecretStoreNotTheRoutine() throws {
        let store = MemorySecretStore()
        let t = try XCTUnwrap(WebhookSecrets.token(for: "hook", in: store))
        XCTAssertEqual(WebhookSecrets.token(for: "hook", in: store), t, "made once, then read")
        XCTAssertEqual(store.secret("routine.hook.webhook"), t)
        let r = Routine(id: "hook", name: "Hook", target: .bot("a"), message: "Go", trigger: .webhook)
        XCTAssertEqual(r.webhookSecretAccount, "routine.hook.webhook")
        let json = String(decoding: try JSONCoding.encoder().encode(r), as: UTF8.self)
        XCTAssertFalse(json.contains(t))
        let fresh = try XCTUnwrap(WebhookSecrets.reset(for: "hook", in: store))
        XCTAssertNotEqual(fresh, t)
        WebhookSecrets.forget("hook", in: store)
        XCTAssertNil(store.secret("routine.hook.webhook"))
        XCTAssertTrue(WebhookAuth.curl(for: "hook", token: "T").contains("http://127.0.0.1:8791/hooks/hook"))
    }
}

// MARK: - The listener, on a free port

final class LoopbackListenerTests: XCTestCase {
    /// A raw HTTP exchange (URLSession on Linux may route through a proxy).
    private func exchange(_ port: UInt16, _ raw: Data, holdOpen: Bool = false) -> (status: Int, body: String)? {
        #if canImport(Glibc)
        let s = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let s = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard s >= 0 else { return nil }
        defer { close(s) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0 else { return nil }
        _ = [UInt8](raw).withUnsafeBytes { send(s, $0.baseAddress, $0.count, 0) }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            var p = pollfd(fd: s, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 5000) > 0 else { break }
            let n = recv(s, &buf, buf.count, 0)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        let text = String(decoding: out, as: UTF8.self)
        guard let line = text.components(separatedBy: "\r\n").first, line.hasPrefix("HTTP/1.1 "),
              let status = Int(line.dropFirst(9).prefix(3)) else { return nil }
        return (status, text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n"))
    }

    private func post(_ port: UInt16, path: String, token: String?, body: Data, extra: String = "") -> Data {
        var head = "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: \(body.count)\r\n"
        if let token { head += "Authorization: Bearer \(token)\r\n" }
        return Data((head + extra + "\r\n").utf8) + body
    }

    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var bodies: [String] = []
        func add(_ s: String) { lock.lock(); bodies.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return bodies }
    }

    func testListenerRunsOnlyWithTheRightSecret() throws {
        let secret = WebhookSecrets.newToken()
        let received = Box()
        let listener = LoopbackHTTPListener { req in
            switch WebhookAuth.check(req, secret: { $0 == "inbox" ? secret : nil }) {
            case .accept:
                received.add(String(decoding: req.body, as: UTF8.self))
                return .ok(routine: "Inbox")
            case let .reject(status, message):
                return .error(status, message)
            }
        }
        let port = try listener.start(port: 0)
        defer { listener.stop() }
        XCTAssertNotEqual(port, 0)
        XCTAssertTrue(listener.isListening)

        XCTAssertEqual(exchange(port, post(port, path: "/hooks/inbox", token: "guess", body: Data("x".utf8)))?.status, 401)
        XCTAssertEqual(exchange(port, post(port, path: "/hooks/inbox", token: nil, body: Data("x".utf8)))?.status, 401)
        let ok = exchange(port, post(port, path: "/hooks/inbox", token: secret, body: Data("{\"file\":\"a.png\"}".utf8)))
        XCTAssertEqual(ok?.status, 200)
        XCTAssertEqual(ok?.body, "{\"ok\":true,\"routine\":\"Inbox\"}")
        XCTAssertEqual(received.all, ["{\"file\":\"a.png\"}"], "the body reaches the routine")
        let big = exchange(port, post(port, path: "/hooks/inbox", token: secret, body: Data(repeating: 0x61, count: WebhookAuth.maxBody + 1)))
        XCTAssertEqual(big?.status, 413)
        XCTAssertEqual(exchange(port, post(port, path: "/hooks/inbox", token: secret, body: Data(), extra: "Transfer-Encoding: chunked\r\n"))?.status, 411)
        XCTAssertEqual(received.all.count, 1, "refused requests never run anything")
    }

    func testListenerTurnsAwayConnectionsOverTheCap() throws {
        let listener = LoopbackHTTPListener { _ in .error(401, "Wrong or missing secret") }
        listener.maxConnections = 2
        let port = try listener.start(port: 0)
        defer { listener.stop() }

        // Two connections that never send anything hold both places.
        var idle: [Int32] = []
        for _ in 0..<2 {
            #if canImport(Glibc)
            let s = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
            #else
            let s = socket(AF_INET, SOCK_STREAM, 0)
            #endif
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            idle.append(s)
        }
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(exchange(port, post(port, path: "/hooks/x", token: nil, body: Data("{}".utf8)))?.status, 503)
        for s in idle { close(s) }
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(exchange(port, post(port, path: "/hooks/x", token: nil, body: Data("{}".utf8)))?.status, 401,
                       "places free up when connections close")
    }

    func testStopFreesThePort() throws {
        let listener = LoopbackHTTPListener { _ in .ok(routine: "x") }
        let port = try listener.start(port: 0)
        listener.stop()
        XCTAssertFalse(listener.isListening)
        Thread.sleep(forTimeInterval: 0.3)
        let again = LoopbackHTTPListener { _ in .ok(routine: "again") }
        XCTAssertEqual(try again.start(port: port), port)
        defer { again.stop() }
        XCTAssertEqual(exchange(port, post(port, path: "/hooks/x", token: nil, body: Data()))?.status, 200)
    }
}

// MARK: - create_routine requests

final class RoutineRequestTests: XCTestCase {
    private let now = date("2026-11-17 10:00")

    private func add(_ json: String, existing: [Routine] = []) -> Result<(routine: Routine, all: [Routine]), RoutineRequestError> {
        RoutineRequests.add(json: Data(json.utf8), to: existing, bots: ["planner"], groups: ["team"], now: now)
    }

    func testAValidRequestMakesARoutine() throws {
        let result = try add("""
        {"name": "Morning brief", "target": "bot:planner", "message": "Brief me",
         "trigger": {"type": "weekdays", "hour": 9, "minute": 15}}
        """).get()
        let r = result.routine
        XCTAssertEqual(r.id, "morning-brief")
        XCTAssertEqual(r.target, .bot("planner"))
        XCTAssertEqual(r.trigger, .daily(hour: 9, minute: 15, weekdaysOnly: true))
        XCTAssertEqual(r.catchUp, false)
        XCTAssertTrue(r.runsInOwnChat)
        XCTAssertTrue(r.enabled)
        XCTAssertEqual(r.createdAt, now)
        XCTAssertEqual(result.all.count, 1)

        let again = try add("""
        {"name": "Morning brief", "target": "group:team", "message": "x", "trigger": {"type": "weekly", "weekday": 2, "hour": 8}}
        """, existing: result.all).get()
        XCTAssertEqual(again.routine.id, "morning-brief-2")
        XCTAssertEqual(again.routine.trigger, .weekly(weekday: 2, hour: 8, minute: 0))
    }

    func testEveryTriggerType() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cases: [(String, Routine.Trigger)] = [
            (#"{"type":"hourly","minute":5}"#, .hourly(minute: 5)),
            (#"{"type":"daily","hour":7}"#, .daily(hour: 7, minute: 0, weekdaysOnly: false)),
            (#"{"type":"every","minutes":30}"#, .every(minutes: 30)),
            (#"{"type":"once","at":"2026-12-01T09:00:00Z"}"#, .once(at: ISO8601DateFormatter().date(from: "2026-12-01T09:00:00Z")!)),
            ("{\"type\":\"folder\",\"folder\":\"\(dir.path)\"}", .newFile(folder: FolderArrivalWatch.standard(dir.path))),
            (#"{"type":"webhook"}"#, .webhook),
        ]
        for (trigger, expected) in cases {
            let r = try add(#"{"name":"R","target":"bot:planner","message":"m","trigger":"# + trigger + "}").get().routine
            XCTAssertEqual(r.trigger, expected, trigger)
        }
    }

    func testBadRequestsAreRefusedWithAReason() {
        func reason(_ json: String) -> String? {
            if case .failure(let e) = add(json) { return e.errorDescription }
            return nil
        }
        let base = #""target":"bot:planner","message":"m""#
        XCTAssertEqual(reason(#"{"name":"","# + base + #","trigger":{"type":"daily","hour":9}}"#), "Give the routine a name.")
        XCTAssertEqual(reason(#"{"name":"R","target":"bot:nobody","message":"m","trigger":{"type":"daily","hour":9}}"#),
                       "No bot or group \"bot:nobody\". Use \"bot:<id>\" or \"group:<id>\" with an id that exists.")
        XCTAssertEqual(reason(#"{"name":"R","# + base + #","trigger":{"type":"daily","hour":24}}"#), "hour must be 0–23.")
        XCTAssertEqual(reason(#"{"name":"R","# + base + #","trigger":{"type":"weekly","weekday":8,"hour":9}}"#),
                       "weekday must be 1 (Sunday) to 7 (Saturday).")
        XCTAssertEqual(reason(#"{"name":"R","# + base + #","trigger":{"type":"every","minutes":1}}"#), "minutes must be 5 to 10080.")
        XCTAssertEqual(reason(#"{"name":"R","# + base + #","trigger":{"type":"once","at":"2020-01-01T00:00:00Z"}}"#), "That time has already passed.")
        XCTAssertEqual(reason(#"{"name":"R","# + base + #","trigger":{"type":"folder","folder":"/no/such/folder"}}"#), "There's no folder at /no/such/folder.")
        XCTAssertEqual(reason(#"{"name":"R","# + base + #","trigger":{"type":"folder","folder":"/"}}"#),
                       "Pick a specific folder, not your whole home folder or disk.")
        XCTAssertEqual(reason(#"{"name":"R","# + base + #","trigger":{"type":"telepathy"}}"#),
                       "Unknown trigger type \"telepathy\". Use once, hourly, daily, weekdays, weekly, every, folder or webhook.")
        XCTAssertEqual(reason(#"{"name":"R"}"#), "The request isn't valid JSON for a routine: target is missing")
        XCTAssertEqual(reason("not json"), "The request isn't valid JSON for a routine: it couldn't be read")
        let full = (0..<RoutineRequests.maxRoutines).map { Routine(id: "r\($0)", name: "", target: .bot("planner"), message: "", trigger: .webhook) }
        if case .failure(let e) = add(#"{"name":"R","# + base + #","trigger":{"type":"webhook"}}"#, existing: full) {
            XCTAssertEqual(e, .invalid("There are already 100 routines. Delete one first."))
        } else {
            XCTFail("over the cap")
        }
    }
}
