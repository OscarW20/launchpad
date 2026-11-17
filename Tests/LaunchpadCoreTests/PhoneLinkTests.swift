import XCTest
@testable import LaunchpadCore

/// The app, faked: a snapshot to show and a record of what the phone asked for.
final class FakePhoneBridge: PhoneLinkBridge, @unchecked Sendable {
    private let lock = NSLock()
    private var snap: PhoneSnapshot
    private(set) var calls: [String] = []
    var reply: PhoneResult = .ok

    init(_ snap: PhoneSnapshot) { self.snap = snap }

    var snapshot: PhoneSnapshot {
        get { lock.lock(); defer { lock.unlock() }; return snap }
        set { lock.lock(); snap = newValue; lock.unlock() }
    }
    var log: [String] { lock.lock(); defer { lock.unlock() }; return calls }
    private func note(_ s: String) -> PhoneResult { lock.lock(); calls.append(s); lock.unlock(); return reply }

    func phoneSnapshot() async -> PhoneSnapshot { snapshot }
    func phoneSend(chat: String, text: String) async -> PhoneResult { note("send \(chat) \(text)") }
    func phoneSide(chat: String, text: String) async -> PhoneResult { note("side \(chat) \(text)") }
    func phoneAnswerQuestions(chat: String, message: String, answers: [String]) async -> PhoneResult {
        note("questions \(chat) \(message) \(answers.joined(separator: "|"))")
    }
    func phoneAnswerApproval(chat: String, message: String, approve: Bool) async -> PhoneResult {
        note("approval \(chat) \(message) \(approve)")
    }
    func phoneAnswerCard(chat: String, card: String, answer: ApprovalAnswer) async -> PhoneResult {
        note("card \(chat) \(card) \(answer.rawValue)")
    }
    func phoneMarkRead(chat: String, at: Date) async { _ = note("read \(chat)") }
    func phoneStop(chat: String) async -> PhoneResult { note("stop \(chat)") }
}

final class PhoneLinkTests: XCTestCase {
    var dir: URL!
    var secrets: MemorySecretStore!
    var bridge: FakePhoneBridge!
    var server: PhoneLinkServer!
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("phone-\(UUID().uuidString)")
        secrets = MemorySecretStore()
        bridge = FakePhoneBridge(Self.sampleSnapshot(t0))
        let devices = PhoneDeviceStore(file: dir.appendingPathComponent("phones.json"), secrets: secrets)
        let now = t0.addingTimeInterval(100)
        server = PhoneLinkServer(macName: "Studio", bridge: bridge, devices: devices, code: "123456", clock: { now })
    }

    override func tearDown() {
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    static func sampleSnapshot(_ t0: Date) -> PhoneSnapshot {
        let ada = Bot(id: "ada", name: "Ada", emoji: "🦉", colour: "#6C9BD2", role: "Planner")
        let bo = Bot(id: "bo", name: "Bo", emoji: "🐝", role: "Builder", lockedDown: true)
        let team = BotGroup(id: "team", name: "build", emoji: "🚀", members: ["bo"], lead: "ada")
        let solo = ChatMeta(id: "c1", title: "Ada", kind: .bot, botId: "ada", updatedAt: t0)
        let group = ChatMeta(id: "c2", title: "#build", kind: .group, groupId: "team", updatedAt: t0)
        var asked = ChatMessage(id: "m3", role: .bot, botId: "ada", text: "", createdAt: t0.addingTimeInterval(30))
        asked.questions = QuestionCard(items: [.init(text: "Which colour?", options: ["Red", "Blue"])])
        let streaming = ChatMessage(id: "m4", role: .bot, botId: "bo", text: "Work",
                                    steps: [Step(id: "s", tool: "Bash", title: "Running tests")], status: .streaming,
                                    createdAt: t0.addingTimeInterval(40),
                                    liveApprovals: [LiveApproval(id: "card1", category: "send", tool: "mcp__slack__post_message",
                                                                 detail: "Post to #general", offersAlways: true),
                                                    LiveApproval(id: "card2", category: "shell", tool: "Bash",
                                                                 detail: "ls ~", offersAlways: true)])
        return PhoneSnapshot(
            bots: [ada, bo], groups: [team], chats: [solo, group],
            messages: [
                "c1": [
                    ChatMessage(id: "m1", role: .user, text: "Plan the launch", createdAt: t0),
                    ChatMessage(id: "m2", role: .bot, botId: "ada", text: "Here's the plan.\nStep one.", createdAt: t0.addingTimeInterval(10)),
                    asked,
                ],
                "c2": [ChatMessage(id: "g1", role: .user, text: "Ship it", createdAt: t0.addingTimeInterval(35)), streaming],
            ],
            working: ["c2"], typing: ["c2": ["bo"]], readMarks: ["c1": t0.addingTimeInterval(5)], readBaseline: t0,
            alwaysForWrites: true)
    }

    // MARK: Helpers

    func call(_ method: String, _ path: String, token: String? = nil, body: [String: Any]? = nil,
              headers: [String: String] = [:]) async -> (status: Int, json: [String: Any], raw: Data) {
        var h = headers
        if let token { h["authorization"] = "Bearer \(token)" }
        let data = body.map { try! JSONSerialization.data(withJSONObject: $0) } ?? Data()
        var target = path
        var query: [String: String] = [:]
        if let q = path.firstIndex(of: "?") {
            target = String(path[..<q])
            for pair in path[path.index(after: q)...].split(separator: "&") {
                let kv = pair.split(separator: "=")
                query[String(kv[0])] = String(kv[1])
            }
        }
        let res = await server.handle(HTTPRequest(method: method, path: target, query: query, headers: h, body: data))
        let json = (try? JSONSerialization.jsonObject(with: res.body)) as? [String: Any] ?? [:]
        return (res.status, json, res.body)
    }

    func paired() async -> String {
        let r = await call("POST", "/pair", body: ["code": server.pairingCode, "device": "Oscar's iPhone"])
        XCTAssertEqual(r.status, 200)
        return r.json["token"] as? String ?? ""
    }

    // MARK: Pairing

    func testHelloNeedsNoToken() async {
        let r = await call("GET", "/hello")
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.json["app"] as? String, "Launchpad")
        XCTAssertEqual(r.json["mac"] as? String, "Studio")
    }

    func testPairingGivesATokenKeptOnlyInTheSecretStore() async throws {
        let wrong = await call("POST", "/pair", body: ["code": "000000", "device": "x"])
        XCTAssertEqual(wrong.status, 401)
        let r = await call("POST", "/pair", body: ["code": "123 456", "device": "Oscar's iPhone"])
        XCTAssertEqual(r.status, 200)
        let token = try XCTUnwrap(r.json["token"] as? String)
        XCTAssertEqual(token.count, 64)
        XCTAssertEqual(r.json["mac"] as? String, "Studio")
        XCTAssertNotEqual(server.pairingCode, "123456", "a used code changes")

        let device = try XCTUnwrap(server.devices.devices.first)
        XCTAssertEqual(device.name, "Oscar's iPhone")
        XCTAssertEqual(secrets.secret(PhoneDeviceStore.account(for: device.id)), token)
        let file = try String(contentsOf: dir.appendingPathComponent("phones.json"), encoding: .utf8)
        XCTAssertTrue(file.contains("Oscar's iPhone"))
        XCTAssertFalse(file.contains(token), "tokens never go in files")

        // A fresh store (the app restarting) still knows the phone, from the SecretStore.
        let reloaded = PhoneDeviceStore(file: dir.appendingPathComponent("phones.json"), secrets: secrets)
        XCTAssertEqual(reloaded.device(token: token)?.id, device.id)
        let nearMiss = String(token.dropLast()) + (token.hasSuffix("0") ? "1" : "0")
        XCTAssertNil(reloaded.device(token: nearMiss))
        XCTAssertNil(reloaded.device(token: ""))
    }

    func testTooManyWrongCodesLocksPairingAndChangesTheCode() async {
        for _ in 0..<PhonePairLimiter.maxFailures {
            let r = await call("POST", "/pair", body: ["code": "999999"])
            XCTAssertEqual(r.status, 401)
        }
        let code = server.pairingCode
        XCTAssertNotEqual(code, "123456", "the guessed-at code is retired")
        let locked = await call("POST", "/pair", body: ["code": code])
        XCTAssertEqual(locked.status, 429)
        XCTAssertTrue(server.devices.devices.isEmpty)
    }

    func testLimiterForgetsOldFailures() {
        var l = PhonePairLimiter()
        let now = Date()
        for i in 0..<4 { XCTAssertFalse(l.noteFailure(now.addingTimeInterval(Double(i)))) }
        XCTAssertTrue(l.noteFailure(now.addingTimeInterval(5)))
        XCTAssertTrue(l.lockedOut(now.addingTimeInterval(10)))
        XCTAssertFalse(l.lockedOut(now.addingTimeInterval(PhonePairLimiter.window + 10)))
    }

    func testCodesAndMatching() {
        for _ in 0..<50 {
            let c = PhonePairing.newCode()
            XCTAssertEqual(c.count, 6)
            XCTAssertTrue(c.allSatisfy(\.isNumber))
        }
        XCTAssertTrue(PhonePairing.matches("042-917", code: "042917"))
        XCTAssertFalse(PhonePairing.matches("04291", code: "042917"))
        XCTAssertFalse(PhonePairing.matches("0429170", code: "042917"))
        XCTAssertFalse(PhonePairing.matches("٠٤٢٩١٧", code: "042917"), "only ASCII digits")
    }

    // MARK: Who may ask

    func testEverythingElseNeedsAPairedPhone() async {
        let none = await call("GET", "/state")
        XCTAssertEqual(none.status, 401)
        let wrong = await call("GET", "/state", token: WebhookSecrets.newToken())
        XCTAssertEqual(wrong.status, 401)
        let token = await paired()
        let ok = await call("GET", "/state", token: token)
        XCTAssertEqual(ok.status, 200)
        let web = await call("GET", "/state", token: token, headers: ["origin": "http://evil.example"])
        XCTAssertEqual(web.status, 403, "browsers are turned away")
        let webPair = await call("POST", "/pair", body: ["code": server.pairingCode], headers: ["sec-fetch-site": "cross-site"])
        XCTAssertEqual(webPair.status, 403)

        server.devices.revoke(server.devices.devices[0].id)
        let revoked = await call("GET", "/state", token: token)
        XCTAssertEqual(revoked.status, 401, "a removed phone stops working straight away")
        XCTAssertNil(secrets.secret(PhoneDeviceStore.account(for: "x")))
        XCTAssertTrue(server.devices.devices.isEmpty)
    }

    func testUnknownRoutesAndMethods() async {
        let token = await paired()
        let missing = await call("GET", "/avatar/ada.png", token: token)
        XCTAssertEqual(missing.status, 404)
        let method = await call("GET", "/send", token: token)
        XCTAssertEqual(method.status, 405)
    }

    // MARK: What the phone sees

    func testStateListsChatsWithUnreadTypingAndLastMessage() async throws {
        let token = await paired()
        let r = await call("GET", "/state", token: token)
        XCTAssertEqual(r.status, 200)
        let state = try JSONDecoder.phone.decode(PhoneState.self, from: r.raw)
        XCTAssertEqual(state.app, "Launchpad")
        XCTAssertEqual(state.bots.map(\.id), ["ada", "bo"])
        XCTAssertEqual(state.bots.first { $0.id == "bo" }?.working, true)
        XCTAssertEqual(state.bots.first { $0.id == "ada" }?.emoji, "🦉")

        XCTAssertEqual(state.chats.map(\.id), ["c2", "c1"], "most recent first")
        let group = try XCTUnwrap(state.chats.first { $0.id == "c2" })
        XCTAssertEqual(group.kind, "group")
        XCTAssertEqual(group.name, "#build")
        XCTAssertEqual(group.members, ["ada", "bo"])
        XCTAssertEqual(group.lead, "ada")
        XCTAssertEqual(group.typing, ["Bo"])
        XCTAssertTrue(group.working)
        XCTAssertEqual(group.unread, 0, "a reply still streaming isn't unread yet")

        let solo = try XCTUnwrap(state.chats.first { $0.id == "c1" })
        XCTAssertEqual(solo.name, "Ada")
        XCTAssertEqual(solo.emoji, "🦉")
        XCTAssertEqual(solo.colour, "#6C9BD2")
        XCTAssertEqual(solo.unread, 2)
        XCTAssertEqual(solo.last?.text, "Which colour?")
        XCTAssertEqual(solo.last?.from, "Ada")
        XCTAssertFalse(state.rev.isEmpty)
    }

    func testRevisionMovesWhenSomethingChanges() async throws {
        let token = await paired()
        let a = await call("GET", "/rev", token: token)
        let b = await call("GET", "/rev", token: token)
        let first = try XCTUnwrap(a.json["rev"] as? String)
        XCTAssertEqual(first, b.json["rev"] as? String, "steady while nothing changes")

        var s = bridge.snapshot
        s.messages["c2"]![1].text += " in progress"
        bridge.snapshot = s
        let c = await call("GET", "/rev", token: token)
        XCTAssertNotEqual(c.json["rev"] as? String, first, "streaming text moves it")

        s.messages["c1"]![2].questions?.answered = true
        bridge.snapshot = s
        let d = await call("GET", "/rev", token: token)
        XCTAssertNotEqual(d.json["rev"] as? String, c.json["rev"] as? String)

        s.messages["c2"]![1].liveApprovals![0].state = .approved
        bridge.snapshot = s
        let e = await call("GET", "/rev", token: token)
        XCTAssertNotEqual(e.json["rev"] as? String, d.json["rev"] as? String, "an answered card moves it")
    }

    func testRevisionHashIsStable() {
        var a = PhoneRevision(), b = PhoneRevision(), c = PhoneRevision()
        a.add("ab"); a.add("c")
        b.add("ab"); b.add("c")
        c.add("a"); c.add("bc")
        XCTAssertEqual(a.value, b.value)
        XCTAssertNotEqual(a.value, c.value)
    }

    func testMessagesCarryCardsQuestionsAndSteps() async throws {
        let token = await paired()
        let r = await call("GET", "/messages?thread=c2", token: token)
        XCTAssertEqual(r.status, 200)
        struct Body: Decodable { let messages: [PhoneMessage] }
        let list = try JSONDecoder.phone.decode(Body.self, from: r.raw).messages
        XCTAssertEqual(list.map(\.id), ["g1", "m4"])
        XCTAssertEqual(list[0].author.kind, "user")
        let m = list[1]
        XCTAssertEqual(m.author.name, "Bo")
        XCTAssertEqual(m.author.emoji, "🐝")
        XCTAssertEqual(m.state, "streaming")
        XCTAssertEqual(m.step, "Running tests")
        let cards = try XCTUnwrap(m.cards)
        XCTAssertEqual(cards[0].title, "Send or post")
        XCTAssertEqual(cards[0].tool, "Slack · post message")
        XCTAssertFalse(cards[0].canAlways, "a locked-down bot never gets Always allow for writes")
        XCTAssertTrue(cards[1].canAlways)

        let limited = await call("GET", "/messages?thread=c1&limit=1", token: token)
        let one = try JSONDecoder.phone.decode(Body.self, from: limited.raw).messages
        XCTAssertEqual(one.map(\.id), ["m3"])
        XCTAssertEqual(one[0].questions?.items.first?.options, ["Red", "Blue"])

        let unknown = await call("GET", "/messages?thread=nope", token: token)
        XCTAssertEqual(unknown.status, 404)
    }

    func testDeletedMessagesShowNothing() {
        var m = ChatMessage(id: "x", role: .bot, botId: "ada", text: "secret plan")
        m.deleted = true
        m.gif = GifRef(url: "https://example.com/a.gif", width: 1, height: 1)
        let p = PhoneMapper.message(m, bots: [:])
        XCTAssertEqual(p.text, "")
        XCTAssertNil(p.gif)
        XCTAssertEqual(p.deleted, true)
        XCTAssertEqual(p.author.name, "Deleted bot")
        XCTAssertEqual(PhoneMapper.preview(m), "Message deleted")
    }

    // MARK: Doing things

    func testSendGoesToTheAppWithTheQuote() async {
        let token = await paired()
        let r = await call("POST", "/send", token: token, body: ["thread": "c1", "text": "  Go blue  ", "replyTo": "m2"])
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(bridge.log.last, "send c1 > Ada: Here's the plan.\n\nGo blue")

        let busy = await call("POST", "/send", token: token, body: ["thread": "c2", "text": "More"])
        XCTAssertEqual(busy.status, 409, "a working chat says so instead of dropping the message")
        let empty = await call("POST", "/send", token: token, body: ["thread": "c1", "text": "  "])
        XCTAssertEqual(empty.status, 400)
        let gone = await call("POST", "/send", token: token, body: ["thread": "zz", "text": "hi"])
        XCTAssertEqual(gone.status, 404)
        let long = await call("POST", "/send", token: token, body: ["thread": "c1", "text": String(repeating: "a", count: PhoneLink.maxText + 1)])
        XCTAssertEqual(long.status, 413)

        bridge.reply = .rejected(409, "Busy")
        let refused = await call("POST", "/send", token: token, body: ["thread": "c1", "text": "hi"])
        XCTAssertEqual(refused.status, 409)
        XCTAssertEqual(refused.json["error"] as? String, "Busy")
    }

    func testAnswersSideQuestionsReadAndStop() async {
        let token = await paired()
        let q = await call("POST", "/answer", token: token, body: ["thread": "c1", "message": "m3", "answers": ["Blue"]])
        XCTAssertEqual(q.status, 200)
        let a = await call("POST", "/answer", token: token, body: ["thread": "c1", "message": "m2", "approve": false])
        XCTAssertEqual(a.status, 200)
        let c = await call("POST", "/answer", token: token, body: ["thread": "c2", "card": "card1", "decision": "always"])
        XCTAssertEqual(c.status, 200)
        let bad = await call("POST", "/answer", token: token, body: ["thread": "c2", "card": "card1", "decision": "maybe"])
        XCTAssertEqual(bad.status, 400)
        let side = await call("POST", "/side", token: token, body: ["thread": "c2", "text": "How long left?"])
        XCTAssertEqual(side.status, 200)
        let read = await call("POST", "/read", token: token, body: ["thread": "c1"])
        XCTAssertEqual(read.status, 200)
        let stop = await call("POST", "/stop", token: token, body: ["thread": "c2"])
        XCTAssertEqual(stop.status, 200)
        XCTAssertEqual(bridge.log, [
            "questions c1 m3 Blue", "approval c1 m2 false", "card c2 card1 always",
            "side c2 How long left?", "read c1", "stop c2",
        ])
    }

    // MARK: On a real socket

    func testServesOverTheNetwork() async throws {
        let port = try server.start(port: 0)
        XCTAssertTrue(server.isRunning)
        let hello = try TestSocket.exchange(port: port, "GET /hello HTTP/1.1\r\nHost: studio.local\r\n\r\n")
        XCTAssertTrue(hello.hasPrefix("HTTP/1.1 200"), hello)
        XCTAssertTrue(hello.contains("\"app\":\"Launchpad\""))

        let body = "{\"code\":\"123456\",\"device\":\"Phone\"}"
        let pair = try TestSocket.exchange(port: port, "POST /pair HTTP/1.1\r\nHost: 192.168.1.5:8790\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
        XCTAssertTrue(pair.hasPrefix("HTTP/1.1 200"), pair)
        let json = try XCTUnwrap(pair.components(separatedBy: "\r\n\r\n").last)
        let token = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["token"] as? String)

        let state = try TestSocket.exchange(port: port, "GET /state HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer \(token)\r\n\r\n")
        XCTAssertTrue(state.hasPrefix("HTTP/1.1 200"), state)
        XCTAssertTrue(state.contains("\"#build\""))
        let denied = try TestSocket.exchange(port: port, "GET /state HTTP/1.1\r\nHost: x\r\n\r\n")
        XCTAssertTrue(denied.hasPrefix("HTTP/1.1 401"), denied)

        server.stop()
        XCTAssertFalse(server.isRunning)
    }
}

extension JSONDecoder {
    static var phone: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
