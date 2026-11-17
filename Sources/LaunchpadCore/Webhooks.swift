import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// A routine with the `.webhook` trigger runs when something on this Mac calls
//   POST http://127.0.0.1:8791/hooks/<routine id>
// with the routine's secret (Authorization: Bearer …, X-Launchpad-Token: …, or ?token=…). The body goes to the bot,
// wrapped as outside data. The secret lives in the SecretStore (Keychain), never in routines.json.

// MARK: - HTTP, just enough

public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Header names lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    public enum Parse: Equatable, Sendable {
        case incomplete
        case invalid
        case complete(HTTPRequest)
    }

    /// Parses bytes read so far. `incomplete` until the headers and the whole Content-Length body are in.
    public static func parse(_ data: Data) -> Parse {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .invalid }
        let parts = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return .invalid }
            headers[name] = headers[name].map { $0 + ", " + value } ?? value
        }
        let length: Int
        if let raw = headers["content-length"] {
            guard let n = Int(raw), n >= 0 else { return .invalid }
            length = n
        } else {
            length = 0
        }
        let bodyStart = end.upperBound
        guard data.endIndex - bodyStart >= length else { return .incomplete }
        let body = Data(data[bodyStart..<(bodyStart + length)])

        let target = String(parts[1])
        var path = target, query: [String: String] = [:]
        if let q = target.firstIndex(of: "?") {
            path = String(target[..<q])
            for pair in target[target.index(after: q)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let value = kv.count > 1 ? (String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(kv[1])) : ""
                query[key] = value
            }
        }
        return .complete(HTTPRequest(method: String(parts[0]).uppercased(), path: path, query: query, headers: headers, body: body))
    }
}

public struct HTTPResponse: Equatable, Sendable {
    public var status: Int
    public var body: Data
    public var contentType: String

    public init(status: Int, body: Data, contentType: String = "application/json") {
        self.status = status
        self.body = body
        self.contentType = contentType
    }

    public static func error(_ status: Int, _ message: String) -> HTTPResponse {
        HTTPResponse(status: status, body: json(["ok": false, "error": message]))
    }

    public static func ok(routine name: String) -> HTTPResponse {
        HTTPResponse(status: 200, body: json(["ok": true, "routine": name]))
    }

    /// The error message, for tests and logs.
    public var message: String? {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? String
    }

    private static func json(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 503: return "Service Unavailable"
        default: return status < 400 ? "OK" : "Error"
        }
    }

    public var bytes: Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

// MARK: - Secrets

// Secret reads use `SecretRead` / `SecretStore.read(_:)` from Connectors.swift: a locked or denied Keychain
// reads as `.failed`, so a routine's secret is never replaced by mistake.

public enum WebhookSecrets {
    public static func account(for routineId: String) -> String { "routine.\(routineId).webhook" }

    /// 32 random bytes as hex. `SystemRandomNumberGenerator` is cryptographically secure on macOS and Linux.
    public static func newToken() -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &g)) }.joined()
    }

    /// What a read means for the secret: only a secret that's really not there is made anew.
    public static func secret(from read: SecretRead, make: () -> String?) -> String? {
        switch read {
        case .found(let t) where !t.isEmpty: return t
        case .found, .missing: return make()
        case .failed: return nil
        }
    }

    static func read(_ account: String, in store: SecretStore) -> SecretRead {
        store.read(account)
    }

    /// The routine's secret, made the first time. nil when the store wouldn't answer or save (nothing is replaced).
    public static func token(for routineId: String, in store: SecretStore) -> String? {
        secret(from: read(account(for: routineId), in: store)) { reset(for: routineId, in: store) }
    }

    /// A new secret: the old address stops working. nil if the store refused it.
    @discardableResult
    public static func reset(for routineId: String, in store: SecretStore) -> String? {
        let t = newToken()
        do { try store.setSecret(t, for: account(for: routineId)) } catch { return nil }
        return t
    }

    public static func forget(_ routineId: String, in store: SecretStore) {
        try? store.setSecret(nil, for: account(for: routineId))
    }
}

// MARK: - Checks

public enum WebhookAuth {
    public static let port: UInt16 = 8791
    /// Bigger bodies are refused (413).
    public static let maxBody = 64 * 1024
    /// Bigger headers are refused (431).
    public static let maxHead = 16 * 1024

    public static func address(for routineId: String, port: UInt16 = port) -> String {
        "http://127.0.0.1:\(port)/hooks/\(routineId)"
    }

    /// The address with the secret in it, for tools that only take a URL.
    public static func url(for routineId: String, token: String, port: UInt16 = port) -> String {
        address(for: routineId, port: port) + "?token=\(token)"
    }

    public static func curl(for routineId: String, token: String, port: UInt16 = port) -> String {
        """
        curl -X POST '\(address(for: routineId, port: port))' \\
          -H 'Authorization: Bearer \(token)' \\
          -H 'Content-Type: application/json' \\
          -d '{"note": "Hello from curl"}'
        """
    }

    /// Compares every byte, so how long it takes says nothing about how much of a guess was right.
    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = UInt8(x.count == y.count ? 0 : 1)
        for i in 0..<max(x.count, y.count) {
            diff |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)
        }
        return diff == 0
    }

    public enum Decision: Equatable, Sendable {
        case accept(String)
        case reject(Int, String)
    }

    /// The routine a /hooks/<id> path is for (Launchpad ids are slugs).
    public static func routineId(in path: String) -> String? {
        var path = path
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        guard path.hasPrefix("/hooks/") else { return nil }
        let id = String(path.dropFirst(7))
        guard !id.isEmpty, id.count <= 80,
              id.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") })
        else { return nil }
        return id
    }

    /// Who may run what. `secret` gives the secret of an enabled web-address routine (nil for anything else).
    public static func check(_ req: HTTPRequest, secret: (String) -> String?) -> Decision {
        guard let id = routineId(in: req.path) else { return .reject(404, "Not found") }
        guard req.method == "POST" else { return .reject(405, "Use POST") }
        // Only this Mac: a web page that points some other name at 127.0.0.1 (DNS rebinding) is refused.
        if let host = req.headers["host"], !isLoopbackHost(host) { return .reject(403, "Only this Mac can call this address") }
        // Browsers say where a request came from; scripts and apps don't. No web page gets to call (or lock out) a routine.
        if req.headers["origin"] != nil || req.headers["sec-fetch-site"] != nil {
            return .reject(403, "Web pages can’t call this address")
        }
        let auth = req.headers["authorization"] ?? ""
        let given = auth.lowercased().hasPrefix("bearer ")
            ? String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            : req.headers["x-launchpad-token"] ?? req.query["token"] ?? ""
        // An unknown routine and a wrong secret look the same from outside.
        guard let expected = secret(id), !expected.isEmpty, !given.isEmpty,
              constantTimeEquals(given, expected) else { return .reject(401, "Wrong or missing secret") }
        return .accept(id)
    }

    /// `check`, plus slowing down guessers: wrong secrets for one routine lock out wrong guesses for that routine
    /// only, and the right secret always gets through.
    public static func gate(_ req: HTTPRequest, limiter: inout WebhookLimiter, now: Date, secret: (String) -> String?) -> Decision {
        let decision = check(req, secret: secret)
        guard case .reject(401, _) = decision, let id = routineId(in: req.path) else { return decision }
        let locked = limiter.lockedOut(id, now)
        limiter.noteFailure(id, now)
        return locked ? .reject(429, "Too many wrong tries. Wait a few minutes.") : decision
    }

    public static func isLoopbackHost(_ host: String) -> Bool {
        var h = host.lowercased()
        if h.hasPrefix("[") {
            h = String(h.dropFirst().prefix { $0 != "]" })
        } else if let colon = h.lastIndex(of: ":") {
            h = String(h[..<colon])
        }
        return h == "127.0.0.1" || h == "localhost" || h == "::1"
    }

    /// Too big or chunked: answer straight away instead of reading more. nil = keep reading.
    public static func refuseEarly(_ buf: Data) -> HTTPResponse? {
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else {
            return buf.count > maxHead ? .error(431, "Headers too large") : nil
        }
        let head = String(decoding: buf[buf.startIndex..<end.lowerBound], as: UTF8.self).lowercased()
        if head.contains("\r\ntransfer-encoding:") { return .error(411, "Send a Content-Length") }
        let length = head.components(separatedBy: "\r\n").first { $0.hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) } ?? 0
        if length > maxBody || buf.endIndex - end.upperBound > maxBody {
            return .error(413, "The body is over \(maxBody / 1024) KB")
        }
        return nil
    }
}

/// Slows down guessing and floods, per routine: guesses at one routine never hold up another.
public struct WebhookLimiter: Sendable {
    public static let maxFailures = 20
    public static let failureWindow: TimeInterval = 300
    /// Each routine runs at most once in this many seconds from its web address.
    public static let minGap: TimeInterval = 10

    public var failures: [String: [Date]] = [:]
    public var lastRun: [String: Date] = [:]

    public init() {}

    public mutating func lockedOut(_ id: String, _ now: Date) -> Bool {
        failures[id]?.removeAll { now.timeIntervalSince($0) > Self.failureWindow }
        return (failures[id]?.count ?? 0) >= Self.maxFailures
    }

    public mutating func noteFailure(_ id: String, _ now: Date) {
        // Old entries go, so guesses at made-up ids don't pile up.
        failures = failures.compactMapValues { list in
            let kept = list.filter { now.timeIntervalSince($0) <= Self.failureWindow }
            return kept.isEmpty ? nil : kept
        }
        failures[id, default: []].append(now)
    }

    public mutating func allowRun(_ id: String, _ now: Date) -> Bool {
        if let last = lastRun[id], now.timeIntervalSince(last) < Self.minGap { return false }
        lastRun[id] = now
        return true
    }
}

/// The whole decision for one request: the answer to send, and the routine run to start (if any).
public struct WebhookOutcome: Equatable, Sendable {
    public var response: HTTPResponse
    /// Routine id and the message payload (the body, wrapped as outside data).
    public var run: (id: String, payload: String)?

    public static func == (a: WebhookOutcome, b: WebhookOutcome) -> Bool {
        a.response == b.response && a.run?.id == b.run?.id && a.run?.payload == b.run?.payload
    }
}

public enum WebhookRouter {
    /// - Parameters:
    ///   - secrets: routine id → secret, for routines whose secret has been read (from the SecretStore).
    ///   - targetExists: whether the routine's bot or group is still there.
    public static func handle(_ req: HTTPRequest, routines: [Routine], secrets: [String: String],
                              limiter: inout WebhookLimiter, now: Date,
                              targetExists: (Routine.Target) -> Bool = { _ in true }) -> WebhookOutcome {
        let enabled = Set(routines.filter { $0.enabled && $0.isWebhook }.map(\.id))
        let decision = WebhookAuth.gate(req, limiter: &limiter, now: now) { enabled.contains($0) ? secrets[$0] : nil }
        switch decision {
        case let .reject(status, message):
            return WebhookOutcome(response: .error(status, message), run: nil)
        case .accept(let id):
            guard let r = routines.first(where: { $0.id == id }), targetExists(r.target) else {
                return WebhookOutcome(response: .error(409, "This routine’s bot or group was deleted"), run: nil)
            }
            guard limiter.allowRun(id, now) else {
                return WebhookOutcome(response: .error(429, "This routine just ran. Try again in a few seconds."), run: nil)
            }
            return WebhookOutcome(response: .ok(routine: r.name), run: (id, RoutinePayload.webRequest(req.body)))
        }
    }
}

// MARK: - The listener

/// A tiny HTTP/1.1 listener on 127.0.0.1 only (nothing on the network can reach it), built on POSIX sockets so it
/// runs and is tested the same on macOS and Linux. One short-lived thread per connection, at most `maxConnections`
/// at once (more get 503); a connection that doesn't finish its request in `requestTimeout` is closed.
public final class LoopbackHTTPListener: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    public enum ListenError: Error, LocalizedError {
        case socket(Int32), bind(Int32), listen(Int32)
        public var errorDescription: String? {
            switch self {
            case .socket(let e): return "Couldn't make a socket (\(String(cString: strerror(e))))"
            case .bind(let e): return "Couldn't open the port (\(String(cString: strerror(e))))"
            case .listen(let e): return "Couldn't listen (\(String(cString: strerror(e))))"
            }
        }
    }

    private let handler: Handler
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var stopped = false
    private var open = 0
    public var maxConnections = 16
    public var requestTimeout: TimeInterval = 15
    public private(set) var port: UInt16 = 0

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    deinit { stop() }

    /// Starts listening on 127.0.0.1. `port` 0 picks a free one. Returns the port.
    @discardableResult
    public func start(port wanted: UInt16 = WebhookAuth.port) throws -> UInt16 {
        #if canImport(Glibc)
        let s = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let s = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard s >= 0 else { throw ListenError.socket(errno) }
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_port = wanted.bigEndian
        addr.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian   // 127.0.0.1 only
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { let e = errno; close(s); throw ListenError.bind(e) }
        guard listen(s, 32) == 0 else { let e = errno; close(s); throw ListenError.listen(e) }
        var got = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &got) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) }
        }
        lock.lock()
        fd = s
        stopped = false
        port = UInt16(bigEndian: got.sin_port)
        lock.unlock()
        let thread = Thread { [weak self] in self?.acceptLoop(s) }
        thread.name = "launchpad.hooks"
        thread.start()
        return port
    }

    public func stop() {
        lock.lock()
        let s = fd
        stopped = true
        fd = -1
        lock.unlock()
        if s >= 0 { close(s) }
    }

    public var isListening: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fd >= 0 && !stopped
    }

    private func acceptLoop(_ s: Int32) {
        while true {
            lock.lock()
            let done = stopped || fd != s
            lock.unlock()
            if done { return }
            var p = pollfd(fd: s, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, 200)
            if ready <= 0 { continue }
            let c = accept(s, nil, nil)
            if c < 0 { continue }
            Self.noSigPipe(c)
            lock.lock()
            let full = open >= maxConnections
            if !full { open += 1 }
            lock.unlock()
            let t = Thread { [weak self] in
                guard let self else { close(c); return }
                if full {
                    self.refuseFull(c)
                } else {
                    self.serve(c)
                    self.lock.lock(); self.open -= 1; self.lock.unlock()
                }
            }
            t.start()
        }
    }

    private static func noSigPipe(_ c: Int32) {
        #if canImport(Darwin)
        var yes: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    private func refuseFull(_ c: Int32) {
        // Read what it sent (closing on unread data would reset it before it sees the answer), then say so.
        _ = readSome(c, timeout: 1)
        write(c, .error(503, "Too many connections. Try again in a moment."))
        close(c)
    }

    private func serve(_ c: Int32) {
        defer { close(c) }
        let deadline = Date().addingTimeInterval(requestTimeout)
        var buf = Data()
        while Date() < deadline {
            guard let chunk = readSome(c, timeout: deadline.timeIntervalSinceNow), !chunk.isEmpty else { return }
            buf.append(chunk)
            if let early = WebhookAuth.refuseEarly(buf) { return write(c, early) }
            switch HTTPRequest.parse(buf) {
            case .incomplete: continue
            case .invalid: return write(c, .error(400, "Bad request"))
            case .complete(let req):
                let box = ResponseBox()
                let done = DispatchSemaphore(value: 0)
                let handler = self.handler
                Task {
                    box.value = await handler(req)
                    done.signal()
                }
                done.wait()
                return write(c, box.value ?? .error(503, "Launchpad is closing"))
            }
        }
    }

    /// nil on timeout or error; empty when the other side closed.
    private func readSome(_ c: Int32, timeout: TimeInterval) -> Data? {
        var p = pollfd(fd: c, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, Int32(max(1, min(timeout, 60)) * 1000)) > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        let n = recv(c, &bytes, bytes.count, 0)
        guard n >= 0 else { return nil }
        return Data(bytes[0..<n])
    }

    private func write(_ c: Int32, _ res: HTTPResponse) {
        let data = [UInt8](res.bytes)
        var sent = 0
        #if canImport(Glibc)
        let flags = Int32(MSG_NOSIGNAL)
        #else
        let flags: Int32 = 0
        #endif
        while sent < data.count {
            let n = data[sent...].withUnsafeBytes { send(c, $0.baseAddress, $0.count, flags) }
            if n <= 0 { return }
            sent += n
        }
        shutdown(c, Int32(SHUT_WR))
        // Let the client read the answer before the socket goes.
        _ = readSome(c, timeout: 0.5)
    }

    private final class ResponseBox: @unchecked Sendable { var value: HTTPResponse? }
}
