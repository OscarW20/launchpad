import XCTest
@testable import LaunchpadCore

final class UpdateCheckTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lp-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: With a scripted git

    /// A checkout folder that only looks like one, and a git that answers from a table (first matching prefix).
    private func scripted(_ answers: [(String, Int32?, String)]) throws -> (BuildStamp, UpdateCheck, Calls) {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let calls = Calls()
        let check = UpdateCheck { args, _ in
            let line = args.joined(separator: " ")
            calls.add(line)
            guard let hit = answers.first(where: { line.hasPrefix($0.0) }) else { return (0, "") }
            return (hit.1, hit.2)
        }
        return (BuildStamp(commit: "aaa111", source: root), check, calls)
    }

    func testAnUnstampedBuildCantCheck() {
        let check = UpdateCheck { _, _ in XCTFail("git shouldn't run"); return (0, "") }
        guard case .cantCheck(let reason) = check.check(stamp: nil) else { return XCTFail() }
        XCTAssertTrue(reason.contains("scripts/update.sh"))
    }

    func testAMissingCheckoutCantCheck() {
        let check = UpdateCheck { _, _ in XCTFail("git shouldn't run"); return (0, "") }
        let gone = BuildStamp(commit: "aaa111", source: root.appendingPathComponent("nowhere"))
        guard case .cantCheck(let reason) = check.check(stamp: gone) else { return XCTFail() }
        XCTAssertTrue(reason.contains("nowhere"))
    }

    func testOfflineIsQuiet() throws {
        let (stamp, check, calls) = try scripted([("fetch", 128, "")])
        XCTAssertEqual(check.check(stamp: stamp), .cantCheck("Couldn't reach GitHub. Launchpad will try again later."))
        XCTAssertEqual(calls.all.count, 1, "nothing else is tried once the fetch fails")
    }

    func testGitThatWontStartOrHangsCantCheck() throws {
        let (stamp, check, _) = try scripted([("fetch", nil, "")])
        XCTAssertEqual(check.check(stamp: stamp), .cantCheck("Couldn't run git to check for updates."))
    }

    func testSameCommitIsUpToDate() throws {
        let (stamp, check, calls) = try scripted([("rev-parse", 0, "aaa111\n")])
        XCTAssertEqual(check.check(stamp: stamp), .upToDate)
        XCTAssertFalse(calls.all.contains { $0.hasPrefix("log") })
    }

    func testBehindListsWhatsNew() throws {
        let (stamp, check, calls) = try scripted([
            ("rev-parse", 0, "bbb222\n"), ("merge-base --is-ancestor aaa111", 0, ""),
            ("rev-list --count", 0, "2\n"), ("log", 0, "Add the update button\nFix the badge\n"),
        ])
        XCTAssertEqual(check.check(stamp: stamp), .available(count: 2, subjects: ["Add the update button", "Fix the badge"]))
        XCTAssertTrue(calls.all.contains("rev-list --count aaa111..origin/main"))
    }

    func testTheCountCanBeMoreThanTheSubjectsShown() throws {
        let many = (1...UpdateCheck.subjectLimit).map { "Change \($0)" }.joined(separator: "\n")
        let (stamp, check, _) = try scripted([
            ("rev-parse", 0, "bbb222\n"), ("merge-base", 0, ""), ("rev-list --count", 0, "75\n"), ("log", 0, many),
        ])
        guard case .available(let count, let subjects) = check.check(stamp: stamp) else { return XCTFail() }
        XCTAssertEqual(count, 75)
        XCTAssertEqual(subjects.count, UpdateCheck.subjectLimit)
    }

    func testBehindEvenIfTheLogCantBeRead() throws {
        let (stamp, check, _) = try scripted([
            ("rev-parse", 0, "bbb222\n"), ("merge-base", 0, ""), ("rev-list", 128, ""), ("log", 128, ""),
        ])
        XCTAssertEqual(check.check(stamp: stamp), .available(count: 1, subjects: []))
    }

    func testABuildAheadOfGitHubIsUpToDate() throws {
        let (stamp, check, _) = try scripted([
            ("rev-parse", 0, "bbb222\n"), ("merge-base --is-ancestor aaa111", 1, ""), ("merge-base --is-ancestor origin/main", 0, ""),
        ])
        XCTAssertEqual(check.check(stamp: stamp), .upToDate)
    }

    func testDivergedCantCheck() throws {
        let (stamp, check, _) = try scripted([("rev-parse", 0, "bbb222\n"), ("merge-base", 1, "")])
        guard case .cantCheck(let reason) = check.check(stamp: stamp) else { return XCTFail() }
        XCTAssertTrue(reason.contains("separate ways"))
    }

    func testAnUnknownCommitCantCheck() throws {
        let (stamp, check, _) = try scripted([("rev-parse", 0, "bbb222\n"), ("merge-base", 128, "")])
        guard case .cantCheck = check.check(stamp: stamp) else { return XCTFail() }
    }

    func testNoFetchWhenAskedNotTo() throws {
        let (stamp, check, calls) = try scripted([("rev-parse", 0, "aaa111\n")])
        XCTAssertEqual(check.check(stamp: stamp, fetch: false), .upToDate)
        XCTAssertFalse(calls.all.contains { $0.hasPrefix("fetch") })
    }

    func testSummaries() {
        XCTAssertEqual(UpdateStatus.upToDate.summary, "Launchpad is up to date")
        XCTAssertEqual(UpdateStatus.available(count: 1, subjects: []).summary, "1 update available")
        XCTAssertEqual(UpdateStatus.available(count: 4, subjects: []).summary, "4 updates available")
        XCTAssertTrue(UpdateStatus.available(count: 4, subjects: []).isAvailable)
        XCTAssertFalse(UpdateStatus.cantCheck("x").isAvailable)
    }

    // MARK: With the real git

    @discardableResult
    private func git(_ args: [String], in dir: URL) throws -> String {
        let r = UpdateCheck.runGit(["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"] + args, dir)
        guard r.status == 0 else { throw XCTSkip("git \(args.first ?? "") isn't usable here") }
        return r.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit(_ subject: String, in dir: URL) throws {
        try Data(subject.utf8).write(to: dir.appendingPathComponent("file.txt"))
        try git(["add", "file.txt"], in: dir)
        try git(["commit", "--quiet", "-m", subject], in: dir)
    }

    func testAgainstARealCheckout() throws {
        let remote = root.appendingPathComponent("remote"), checkout = root.appendingPathComponent("checkout")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try git(["init", "--quiet", "--initial-branch=main"], in: remote)
        try commit("First", in: remote)
        try git(["clone", "--quiet", remote.path, checkout.path], in: root)
        let built = try git(["rev-parse", "HEAD"], in: checkout)
        let stamp = BuildStamp(commit: built, source: checkout)
        let check = UpdateCheck()
        XCTAssertEqual(check.check(stamp: stamp), .upToDate)

        try commit("Add the update button", in: remote)
        try commit("Fix the badge", in: remote)
        XCTAssertEqual(check.check(stamp: stamp, fetch: false), .upToDate, "without fetching it only knows what it last saw")
        XCTAssertEqual(check.check(stamp: stamp), .available(count: 2, subjects: ["Fix the badge", "Add the update button"]))

        // The checkout's own files and branch are untouched by a check.
        XCTAssertEqual(try git(["rev-parse", "HEAD"], in: checkout), built)
        XCTAssertEqual(try git(["status", "--porcelain"], in: checkout), "")

        // GitHub gone: quiet.
        try FileManager.default.removeItem(at: remote)
        XCTAssertEqual(check.check(stamp: stamp), .cantCheck("Couldn't reach GitHub. Launchpad will try again later."))
    }
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
