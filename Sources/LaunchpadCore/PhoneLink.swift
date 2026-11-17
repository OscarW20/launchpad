import Foundation

// Phone link: the Launchpad iPhone app talks to this Mac over the local network. A small HTTP server on port 8790
// (every interface, so the phone can reach it), found with Bonjour (`_launchpad._tcp`, advertised by the app).
// A phone pairs once with the 6-digit code shown in Settings › Mobile and then uses its own token, which lives in the
// SecretStore (Keychain), never in a file. The bots keep running on the Mac.
//
//   GET  /hello                                   -> {app, mac, v}                      (no token needed)
//   POST /pair     {code, device}                 -> {token, mac, device}
//   GET  /rev                                     -> {rev}   changes whenever anything a phone shows changes
//   GET  /state                                   -> {app, mac, bots, chats, rev}
//   GET  /messages?thread=<chat id>&limit=<n>     -> {messages}
//   POST /send     {thread, text, replyTo?}       sends as you, exactly like typing on the Mac
//   POST /side     {thread, text}                 a quick side question while the bot works
//   POST /answer   {thread, message, answers}     answers a question card
//                  {thread, message, approve}     Approve / Decline on an approval card
//                  {thread, card, decision}       a live approval card: approve, deny or always
//   POST /read     {thread}                       marks a chat read
//   POST /stop     {thread}                       stops work in a chat
//
// Everything but /hello and /pair needs `Authorization: Bearer <token>`.

public enum PhoneLink {
    public static let port: UInt16 = 8790
    /// The Bonjour service type the app advertises and the phone browses for.
    public static let serviceType = "_launchpad._tcp"
    public static let appName = "Launchpad"
    public static let version = 1
    public static let maxDevices = 20
    /// Longest message a phone can send.
    public static let maxText = 20_000
}

// MARK: - What the phone sees

public struct PhoneBot: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var emoji: String
    public var colour: String
    public var role: String
    public var engine: String
    public var working: Bool
}

public struct PhoneChat: Codable, Hashable, Sendable {
    public struct Last: Codable, Hashable, Sendable {
        public var text: String
        public var date: Date
        public var from: String
    }

    public var id: String
    /// "bot" or "group".
    public var kind: String
    public var name: String
    public var emoji: String
    public var colour: String?
    public var role: String?
    /// The bot, for a bot chat.
    public var botId: String?
    /// Everyone in a group, lead first.
    public var members: [String]?
    public var lead: String?
    public var unread: Int
    public var working: Bool
    /// Names of the bots replying right now.
    public var typing: [String]
    public var last: Last?
}

public struct PhoneMessage: Codable, Hashable, Sendable {
    public struct Author: Codable, Hashable, Sendable {
        /// "user", "bot" or "system".
        public var kind: String
        public var id: String?
        public var name: String
        public var emoji: String?
        public var colour: String?
        public var role: String?
    }

    /// A live approval card from the guard.
    public struct Card: Codable, Hashable, Sendable {
        public var id: String
        public var category: String
        /// "Send or post", "Spend money"…
        public var title: String
        /// The tool, readable ("Terminal", "Slack · post message").
        public var tool: String
        public var detail: String
        /// pending, approved, denied, always, expired.
        public var state: String
        /// Whether "Always allow" can be offered for it.
        public var canAlways: Bool
    }

    public var id: String
    public var author: Author
    public var text: String
    public var date: Date
    /// streaming, done, stopped or failed.
    public var state: String
    public var steps: Int
    /// What it's doing now (the last step), while streaming.
    public var step: String?
    /// The plain-English problem, for a reply that failed.
    public var error: String?
    public var reactions: [String: Int]?
    public var deleted: Bool?
    public var gif: String?
    public var poll: String?
    public var files: [String]?
    public var questions: QuestionCard?
    public var approval: ApprovalRequest?
    public var cards: [Card]?
}

public struct PhoneState: Codable, Hashable, Sendable {
    public var app: String
    public var mac: String
    public var bots: [PhoneBot]
    public var chats: [PhoneChat]
    public var rev: String
}

// MARK: - The app's side

/// Everything the phone can see, read from the app in one go.
public struct PhoneSnapshot: Sendable {
    public var bots: [Bot]
    public var groups: [BotGroup]
    public var chats: [ChatMeta]
    /// Messages per chat in order, with replies still streaming at the end.
    public var messages: [String: [ChatMessage]]
    /// Chats with work going on.
    public var working: Set<String>
    /// Chat id -> bots replying right now.
    public var typing: [String: [String]]
    /// When each chat was last read (on the phone, or open on the Mac).
    public var readMarks: [String: Date]
    /// Messages before this count as read in chats with no mark (so pairing doesn't show every old reply as new).
    public var readBaseline: Date?
    /// Settings: "Always allow" may cover writes.
    public var alwaysForWrites: Bool

    public init(bots: [Bot] = [], groups: [BotGroup] = [], chats: [ChatMeta] = [], messages: [String: [ChatMessage]] = [:],
                working: Set<String> = [], typing: [String: [String]] = [:], readMarks: [String: Date] = [:],
                readBaseline: Date? = nil, alwaysForWrites: Bool = true) {
        self.bots = bots
        self.groups = groups
        self.chats = chats
        self.messages = messages
        self.working = working
        self.typing = typing
        self.readMarks = readMarks
        self.readBaseline = readBaseline
        self.alwaysForWrites = alwaysForWrites
    }
}

/// What the app said to a request from the phone.
public enum PhoneResult: Equatable, Sendable {
    case ok
    case rejected(Int, String)
}

/// The app, as the phone link sees it. The app implements this against its model; tests use a fake.
public protocol PhoneLinkBridge: AnyObject, Sendable {
    func phoneSnapshot() async -> PhoneSnapshot
    func phoneSend(chat: String, text: String) async -> PhoneResult
    func phoneSide(chat: String, text: String) async -> PhoneResult
    func phoneAnswerQuestions(chat: String, message: String, answers: [String]) async -> PhoneResult
    func phoneAnswerApproval(chat: String, message: String, approve: Bool) async -> PhoneResult
    func phoneAnswerCard(chat: String, card: String, answer: ApprovalAnswer) async -> PhoneResult
    func phoneMarkRead(chat: String, at: Date) async
    func phoneStop(chat: String) async -> PhoneResult
}

// MARK: - Turning app data into phone data

public enum PhoneMapper {
    public static func bot(_ b: Bot, working: Bool) -> PhoneBot {
        PhoneBot(id: b.id, name: b.name, emoji: b.emoji, colour: b.colour, role: b.role, engine: b.engine.rawValue,
                 working: working)
    }

    public static func author(_ m: ChatMessage, bots: [String: Bot]) -> PhoneMessage.Author {
        switch m.role {
        case .user: return .init(kind: "user", name: "You")
        case .notice: return .init(kind: "system", name: "")
        case .bot:
            let b = m.botId.flatMap { bots[$0] }
            return .init(kind: "bot", id: m.botId, name: b?.name ?? "Deleted bot", emoji: b?.emoji ?? "🤖",
                         colour: b?.colour, role: b?.role)
        }
    }

    public static func card(_ c: LiveApproval, bot: Bot?, alwaysForWrites: Bool) -> PhoneMessage.Card {
        var canAlways = false
        if c.offersAlways, let kind = c.kind {
            canAlways = !ApprovalCategory.writes.contains(kind) || (alwaysForWrites && !(bot?.lockedDown ?? false))
        }
        return .init(id: c.id, category: c.category, title: c.kind?.title ?? c.category, tool: ToolNames.readable(c.tool),
                     detail: String(c.detail.prefix(2000)), state: c.state.rawValue, canAlways: c.state == .pending && canAlways)
    }

    public static func message(_ m: ChatMessage, bots: [String: Bot], alwaysForWrites: Bool = true) -> PhoneMessage {
        let gone = m.deleted == true
        var out = PhoneMessage(id: m.id, author: author(m, bots: bots), text: gone ? "" : m.text, date: m.createdAt,
                               state: m.status.rawValue, steps: m.steps.count)
        if m.status == .streaming, let last = m.steps.last { out.step = last.title }
        if gone { out.deleted = true; return out }
        out.error = m.failure?.message
        if let r = m.reactions, !r.isEmpty { out.reactions = r.mapValues(\.count).filter { $0.value > 0 } }
        out.gif = m.gif?.url
        out.poll = m.poll?.question
        if let files = m.attachments, !files.isEmpty { out.files = files.map { ($0 as NSString).lastPathComponent } }
        out.questions = m.questions
        out.approval = m.approval
        if let cards = m.liveApprovals, !cards.isEmpty {
            let b = m.botId.flatMap { bots[$0] }
            out.cards = cards.map { card($0, bot: b, alwaysForWrites: alwaysForWrites) }
        }
        return out
    }

    /// One line for the chat list.
    public static func preview(_ m: ChatMessage) -> String {
        if m.deleted == true { return "Message deleted" }
        if let p = m.poll { return "Poll: \(p.question)" }
        if m.gif != nil, m.text.isEmpty { return "GIF" }
        if let a = m.approval, a.status == .pending { return "Asks to: \(a.action)" }
        if m.liveApprovals?.contains(where: { $0.state == .pending }) == true { return "Needs your OK" }
        if let q = m.questions, !q.answered, m.text.isEmpty {
            return q.items.count == 1 ? q.items[0].text : "Asked you \(q.items.count) questions"
        }
        let t = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty, m.status == .streaming { return "Typing…" }
        if t.isEmpty, let f = m.failure { return f.message }
        if t.isEmpty, let files = m.attachments, !files.isEmpty { return "📎 \(files.count) file\(files.count == 1 ? "" : "s")" }
        return String(t.prefix(160))
    }

    /// Replies (from bots) since the chat was last read.
    public static func unread(_ messages: [ChatMessage], since: Date?) -> Int {
        guard let since else { return 0 }
        return messages.filter { $0.role == .bot && $0.status != .streaming && $0.createdAt > since }.count
    }

    public static func chat(_ meta: ChatMeta, in s: PhoneSnapshot, bots: [String: Bot], groups: [String: BotGroup]) -> PhoneChat {
        let list = s.messages[meta.id] ?? []
        let typing = (s.typing[meta.id] ?? []).compactMap { bots[$0]?.name }
        var row = PhoneChat(id: meta.id, kind: meta.kind.rawValue, name: meta.title, emoji: "💬", unread: 0,
                            working: s.working.contains(meta.id) || !typing.isEmpty, typing: typing)
        switch meta.kind {
        case .bot:
            row.botId = meta.botId
            if let b = meta.botId.flatMap({ bots[$0] }) {
                row.name = b.name
                row.emoji = b.emoji
                row.colour = b.colour
                row.role = b.role
            }
        case .group:
            if let g = meta.groupId.flatMap({ groups[$0] }) {
                row.name = g.displayName
                row.emoji = g.emoji
                row.members = g.everyone
                row.lead = g.lead
            }
        }
        if let last = list.last(where: { $0.role != .notice }) {
            var from = author(last, bots: bots).name
            if last.role == .user { from = "You" }
            row.last = .init(text: preview(last), date: last.createdAt, from: from)
        } else if let p = meta.lastPreview, !p.isEmpty {
            row.last = .init(text: String(p.prefix(160)), date: meta.updatedAt, from: "")
        }
        row.unread = unread(list, since: s.readMarks[meta.id] ?? s.readBaseline)
        return row
    }

    public static func state(_ s: PhoneSnapshot, mac: String) -> PhoneState {
        let bots = Dictionary(s.bots.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let groups = Dictionary(s.groups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let busyBots = Set(s.typing.values.flatMap { $0 })
        let chats = s.chats.map { chat($0, in: s, bots: bots, groups: groups) }
            .sorted { ($0.last?.date ?? .distantPast) > ($1.last?.date ?? .distantPast) }
        var state = PhoneState(app: PhoneLink.appName, mac: mac,
                               bots: s.bots.map { bot($0, working: busyBots.contains($0.id)) }, chats: chats, rev: "")
        state.rev = revision(state, s)
        return state
    }

    /// A cheap fingerprint of everything the phone shows. The phone asks for it every second and refetches when it
    /// moves. Stable across runs (FNV-1a), unlike `Hasher`.
    public static func revision(_ state: PhoneState, _ s: PhoneSnapshot) -> String {
        var h = PhoneRevision()
        var plain = state
        plain.rev = ""
        if let data = try? phoneEncoder().encode(plain) { h.add(data) }
        for id in s.messages.keys.sorted() {
            let list = s.messages[id] ?? []
            h.add(id)
            h.add(list.count)
            for m in list.suffix(4) {
                h.add(m.id)
                h.add(m.status.rawValue)
                h.add(m.text.count)
                h.add(m.steps.count)
                h.add(m.steps.last?.title ?? "")
                h.add(m.reactions?.values.reduce(0) { $0 + $1.count } ?? 0)
                h.add(m.deleted == true ? 1 : 0)
                h.add(m.questions?.answered == true ? 1 : 0)
                h.add(m.approval?.status.rawValue ?? "")
                for c in m.liveApprovals ?? [] { h.add(c.id); h.add(c.state.rawValue) }
            }
            // An answered question or a deleted message further up.
            for m in list.dropLast(4) where m.questions != nil || m.approval != nil || m.deleted == true {
                h.add(m.id)
                h.add(m.questions?.answered == true ? 1 : 0)
                h.add(m.approval?.status.rawValue ?? "")
                h.add(m.deleted == true ? 1 : 0)
            }
        }
        return h.value
    }

    /// The text to send for a reply to an earlier message: the quoted line first.
    public static func reply(_ text: String, quoting m: ChatMessage?, bots: [String: Bot]) -> String {
        guard let m, m.deleted != true else { return text }
        let quoted = m.text.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !quoted.isEmpty else { return text }
        let who = author(m, bots: bots).name
        let short = quoted.count > 140 ? String(quoted.prefix(139)) + "…" : quoted
        return "> \(who): \(short)\n\n\(text)"
    }
}

/// FNV-1a, 64 bit.
public struct PhoneRevision: Sendable {
    private var h: UInt64 = 0xcbf2_9ce4_8422_2325

    public init() {}

    public mutating func add<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        for b in bytes {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        // A separator, so "ab"+"c" and "a"+"bc" differ.
        h ^= 0xff
        h = h &* 0x0000_0100_0000_01b3
    }

    public mutating func add(_ s: String) { add(s.utf8) }
    public mutating func add(_ i: Int) { add(String(i)) }

    public var value: String { String(h, radix: 36) }
}

func phoneEncoder() -> JSONEncoder {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    e.dateEncodingStrategy = .iso8601
    return e
}

// MARK: - Pairing

public enum PhonePairing {
    /// A fresh 6-digit code.
    public static func newCode() -> String {
        var g = SystemRandomNumberGenerator()
        return String(format: "%06d", Int.random(in: 0...999_999, using: &g))
    }

    /// 32 random bytes as hex.
    public static func newToken() -> String { WebhookSecrets.newToken() }

    /// Digits only, so "123 456" and "123-456" work.
    public static func matches(_ typed: String, code: String) -> Bool {
        let digits = typed.filter { $0.isASCII && $0.isNumber }
        return digits.count == 6 && WebhookAuth.constantTimeEquals(digits, code)
    }
}

/// Slows down guessing the pairing code: after `maxFailures` wrong codes in `window`, pairing is refused for a while
/// and the code changes, so one code never gets more than `maxFailures` guesses.
public struct PhonePairLimiter: Sendable {
    public static let maxFailures = 5
    public static let window: TimeInterval = 300

    public var failures: [Date] = []

    public init() {}

    public mutating func lockedOut(_ now: Date) -> Bool {
        failures.removeAll { now.timeIntervalSince($0) > Self.window }
        return failures.count >= Self.maxFailures
    }

    /// Notes a wrong code. True when that was the last allowed guess.
    @discardableResult
    public mutating func noteFailure(_ now: Date) -> Bool {
        failures.removeAll { now.timeIntervalSince($0) > Self.window }
        failures.append(now)
        return failures.count >= Self.maxFailures
    }
}

// MARK: - Paired phones

public struct PhoneDevice: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var pairedAt: Date
    public var lastSeen: Date?

    public init(id: String = UUID().uuidString.lowercased(), name: String, pairedAt: Date = Date(), lastSeen: Date? = nil) {
        self.id = id
        self.name = name
        self.pairedAt = pairedAt
        self.lastSeen = lastSeen
    }
}

/// Paired phones. Names and dates go in a JSON file; each phone's token goes in the SecretStore (Keychain) only.
public final class PhoneDeviceStore: @unchecked Sendable {
    public enum StoreError: Error, LocalizedError {
        case tooMany, keychain
        public var errorDescription: String? {
            switch self {
            case .tooMany: return "Too many phones are paired. Remove one in Settings › Mobile first."
            case .keychain: return "Couldn't save the phone's key in your Keychain."
            }
        }
    }

    public static func account(for deviceId: String) -> String { "phone.\(deviceId).token" }

    public let file: URL
    private let secrets: SecretStore
    private let lock = NSLock()
    private var list: [PhoneDevice] = []
    /// Device id -> token, read from the SecretStore once.
    private var tokens: [String: String] = [:]
    private var lastSaved = Date.distantPast

    public init(file: URL, secrets: SecretStore) {
        self.file = file
        self.secrets = secrets
        load()
    }

    public var devices: [PhoneDevice] {
        lock.lock(); defer { lock.unlock() }
        return list
    }

    public func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = (try? Data(contentsOf: file)).flatMap { try? decoder.decode([PhoneDevice].self, from: $0) } ?? []
        var found: [String: String] = [:]
        for d in loaded {
            if case .found(let t) = secrets.read(Self.account(for: d.id)), !t.isEmpty { found[d.id] = t }
        }
        lock.lock()
        list = loaded
        tokens = found
        lock.unlock()
    }

    /// Pairs a new phone. Returns it and its token (shown to that phone once, kept in the SecretStore).
    public func add(name: String, now: Date = Date()) throws -> (device: PhoneDevice, token: String) {
        lock.lock(); defer { lock.unlock() }
        guard list.count < PhoneLink.maxDevices else { throw StoreError.tooMany }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).filter { !$0.isNewline }
        let device = PhoneDevice(name: clean.isEmpty ? "iPhone" : String(clean.prefix(60)), pairedAt: now, lastSeen: now)
        let token = PhonePairing.newToken()
        do { try secrets.setSecret(token, for: Self.account(for: device.id)) } catch { throw StoreError.keychain }
        list.append(device)
        tokens[device.id] = token
        do {
            try saveLocked()
        } catch {
            list.removeAll { $0.id == device.id }
            tokens[device.id] = nil
            try? secrets.setSecret(nil, for: Self.account(for: device.id))
            throw error
        }
        return (device, token)
    }

    /// Unpairs a phone: its token stops working straight away.
    public func revoke(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        list.removeAll { $0.id == id }
        tokens[id] = nil
        try? secrets.setSecret(nil, for: Self.account(for: id))
        try? saveLocked()
    }

    /// The phone a token belongs to. Every paired token is compared in full, so timing says nothing.
    public func device(token: String) -> PhoneDevice? {
        guard !token.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        var match: String?
        for (id, t) in tokens where WebhookAuth.constantTimeEquals(token, t) { match = id }
        return match.flatMap { id in list.first { $0.id == id } }
    }

    /// Notes that a phone was here. Saved at most once a minute.
    public func touch(_ id: String, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].lastSeen = now
        if now.timeIntervalSince(lastSaved) > 60 { try? saveLocked(now: now) }
    }

    private func saveLocked(now: Date = Date()) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try e.encode(list).write(to: file, options: .atomic)
        lastSaved = now
    }
}

// MARK: - The server

/// Answers the phone. `handle` is pure request handling against the bridge; `start` puts it on the network.
public final class PhoneLinkServer: @unchecked Sendable {
    public let macName: String
    public let devices: PhoneDeviceStore
    private let bridge: PhoneLinkBridge
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private var code: String
    private var limiter = PhonePairLimiter()
    private var listener: LoopbackHTTPListener?
    /// Called (on any thread) when a phone pairs or the code changes, so Settings can refresh.
    public var onChange: (@Sendable () -> Void)?

    public init(macName: String, bridge: PhoneLinkBridge, devices: PhoneDeviceStore, code: String = PhonePairing.newCode(),
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.macName = macName
        self.bridge = bridge
        self.devices = devices
        self.code = code
        self.clock = clock
    }

    deinit { listener?.stop() }

    public var pairingCode: String {
        lock.lock(); defer { lock.unlock() }
        return code
    }

    public func newPairingCode() {
        lock.lock()
        code = PhonePairing.newCode()
        lock.unlock()
        onChange?()
    }

    // MARK: Network

    /// Starts listening on every interface. Returns the port (0 picks a free one, for tests).
    @discardableResult
    public func start(port: UInt16 = PhoneLink.port) throws -> UInt16 {
        stop()
        let l = LoopbackHTTPListener(interface: .all) { [weak self] req in
            guard let self else { return .error(503, "Launchpad is closing") }
            return await self.handle(req)
        }
        l.maxConnections = 24
        let got = try l.start(port: port)
        lock.lock()
        listener = l
        lock.unlock()
        return got
    }

    public func stop() {
        lock.lock()
        let l = listener
        listener = nil
        lock.unlock()
        l?.stop()
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return listener?.isListening ?? false
    }

    // MARK: Requests

    public func handle(_ req: HTTPRequest) async -> HTTPResponse {
        // Browsers say where a request came from; the phone app doesn't. No web page gets to pair or guess.
        if req.headers["origin"] != nil || req.headers["sec-fetch-site"] != nil {
            return .error(403, "Web pages can’t use the phone link")
        }
        switch (req.method, req.path) {
        case ("GET", "/hello"):
            return Self.json(["app": PhoneLink.appName, "mac": macName, "v": PhoneLink.version])
        case ("POST", "/pair"):
            return pair(req)
        default:
            break
        }

        // Everything else needs a paired phone.
        let auth = req.headers["authorization"] ?? ""
        let token = auth.lowercased().hasPrefix("bearer ") ? String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces) : ""
        guard let device = devices.device(token: token) else { return .error(401, "Pair this phone first") }
        devices.touch(device.id, now: clock())

        let body = Self.object(req.body)
        let thread = (body["thread"] as? String) ?? req.query["thread"] ?? ""

        switch (req.method, req.path) {
        case ("GET", "/rev"):
            let snap = await bridge.phoneSnapshot()
            return Self.json(["rev": PhoneMapper.state(snap, mac: macName).rev])

        case ("GET", "/state"):
            let snap = await bridge.phoneSnapshot()
            return Self.encode(PhoneMapper.state(snap, mac: macName))

        case ("GET", "/messages"):
            let snap = await bridge.phoneSnapshot()
            guard snap.chats.contains(where: { $0.id == thread }) else { return .error(404, "That chat isn’t on your Mac any more") }
            let limit = max(1, min(Int(req.query["limit"] ?? "") ?? 80, 300))
            let bots = Dictionary(snap.bots.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let list = (snap.messages[thread] ?? []).suffix(limit)
                .map { PhoneMapper.message($0, bots: bots, alwaysForWrites: snap.alwaysForWrites) }
            return Self.encode(MessagesBody(messages: Array(list)))

        case ("POST", "/send"):
            guard let text = (body["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return .error(400, "Nothing to send")
            }
            guard text.count <= PhoneLink.maxText else { return .error(413, "That message is too long") }
            let snap = await bridge.phoneSnapshot()
            guard snap.chats.contains(where: { $0.id == thread }) else { return .error(404, "That chat isn’t on your Mac any more") }
            if snap.working.contains(thread) { return .error(409, "Still working on the last message. Wait, or tap Stop.") }
            let bots = Dictionary(snap.bots.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let quoted = (body["replyTo"] as? String).flatMap { id in snap.messages[thread]?.first { $0.id == id } }
            return Self.result(await bridge.phoneSend(chat: thread, text: PhoneMapper.reply(text, quoting: quoted, bots: bots)))

        case ("POST", "/side"):
            guard let text = (body["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return .error(400, "Nothing to ask")
            }
            guard text.count <= PhoneLink.maxText else { return .error(413, "That question is too long") }
            guard await knows(thread) else { return .error(404, "That chat isn’t on your Mac any more") }
            return Self.result(await bridge.phoneSide(chat: thread, text: text))

        case ("POST", "/answer"):
            guard await knows(thread) else { return .error(404, "That chat isn’t on your Mac any more") }
            if let card = body["card"] as? String {
                guard let answer = (body["decision"] as? String).flatMap(ApprovalAnswer.init(rawValue:)) else {
                    return .error(400, "Approve, deny or always?")
                }
                return Self.result(await bridge.phoneAnswerCard(chat: thread, card: card, answer: answer))
            }
            guard let message = body["message"] as? String else { return .error(400, "Which question?") }
            if let approve = body["approve"] as? Bool {
                return Self.result(await bridge.phoneAnswerApproval(chat: thread, message: message, approve: approve))
            }
            guard let answers = body["answers"] as? [String], !answers.isEmpty, answers.count <= 10,
                  answers.allSatisfy({ $0.count <= 2000 }) else { return .error(400, "Which answers?") }
            return Self.result(await bridge.phoneAnswerQuestions(chat: thread, message: message, answers: answers))

        case ("POST", "/read"):
            guard await knows(thread) else { return .error(404, "That chat isn’t on your Mac any more") }
            await bridge.phoneMarkRead(chat: thread, at: clock())
            return Self.json(["ok": true])

        case ("POST", "/stop"):
            guard await knows(thread) else { return .error(404, "That chat isn’t on your Mac any more") }
            return Self.result(await bridge.phoneStop(chat: thread))

        default:
            let known = ["/hello", "/pair", "/rev", "/state", "/messages", "/send", "/side", "/answer", "/read", "/stop"]
            return known.contains(req.path) ? .error(405, "Wrong method") : .error(404, "Not found")
        }
    }

    private func knows(_ chat: String) async -> Bool {
        guard !chat.isEmpty else { return false }
        return await bridge.phoneSnapshot().chats.contains { $0.id == chat }
    }

    private func pair(_ req: HTTPRequest) -> HTTPResponse {
        let body = Self.object(req.body)
        let now = clock()
        lock.lock()
        if limiter.lockedOut(now) {
            lock.unlock()
            return .error(429, "Too many wrong codes. Wait a few minutes, then use the new code on your Mac.")
        }
        guard let typed = body["code"] as? String, PhonePairing.matches(typed, code: code) else {
            var changed = false
            if limiter.noteFailure(now) {
                code = PhonePairing.newCode()
                changed = true
            }
            lock.unlock()
            if changed { onChange?() }
            return .error(401, "That code doesn’t match. Check Settings › Mobile on your Mac.")
        }
        // Used: the next phone gets a new code.
        code = PhonePairing.newCode()
        lock.unlock()
        defer { onChange?() }
        do {
            let (device, token) = try devices.add(name: body["device"] as? String ?? "iPhone", now: now)
            return Self.json(["token": token, "mac": macName, "device": device.id])
        } catch {
            return .error(503, error.localizedDescription)
        }
    }

    // MARK: JSON

    private struct MessagesBody: Encodable { var messages: [PhoneMessage] }

    static func object(_ data: Data) -> [String: Any] {
        guard !data.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static func json(_ obj: [String: Any], status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8))
    }

    static func encode<T: Encodable>(_ value: T) -> HTTPResponse {
        guard let data = try? phoneEncoder().encode(value) else { return .error(500, "Couldn't encode the answer") }
        return HTTPResponse(status: 200, body: data)
    }

    static func result(_ r: PhoneResult) -> HTTPResponse {
        switch r {
        case .ok: return json(["ok": true])
        case let .rejected(status, message): return .error(status, message)
        }
    }
}
