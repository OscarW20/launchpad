import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The way online for locked-down bots. Their sandbox only lets them reach this Mac, so their engine and tools go
/// through this small HTTP proxy on 127.0.0.1, which lets through only the sites on that bot's list.
///
/// HTTPS goes through as an opaque tunnel (CONNECT); plain HTTP is forwarded. Each run gets its own token, sent as the
/// proxy password, which picks the site list. Nothing is logged and no traffic is inspected beyond the host name.
public final class SiteGateway: @unchecked Sendable {
    public static let shared = SiteGateway()

    private let lock = NSLock()
    private var listener: Int32 = -1
    private var tokens: [String: [String]] = [:]
    public private(set) var port: UInt16 = 0

    public init() {}

    deinit { stop() }

    /// Starts listening (once) and returns the port, or 0 if it couldn't.
    @discardableResult
    public func start() -> UInt16 {
        lock.lock(); defer { lock.unlock() }
        if listener >= 0 { return port }
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { return 0 }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 64) == 0 else { close(fd); return 0 }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        listener = fd
        port = UInt16(bigEndian: addr.sin_port)
        EngineRunner.spawnThread { [weak self] in self?.acceptLoop(fd) }
        return port
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard listener >= 0 else { return }
        shutdown(listener, Int32(SHUT_RDWR))
        close(listener)
        listener = -1
        port = 0
    }

    /// A token for one run that may reach `sites` ("github.com" also allows "api.github.com").
    public func issue(sites: [String]) -> String {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        lock.lock(); tokens[token] = sites.map { $0.lowercased() }; lock.unlock()
        return token
    }

    /// The run ended: its token stops working.
    public func revoke(_ token: String) {
        lock.lock(); tokens[token] = nil; lock.unlock()
    }

    /// Environment that sends a run's traffic through the gateway. Merge into `RunOptions.environment`.
    public static func proxyEnvironment(port: UInt16, token: String) -> [String: String] {
        let proxy = "http://bot:\(token)@127.0.0.1:\(port)"
        var env: [String: String] = [:]
        for key in ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"] { env[key] = proxy }
        for key in ["NO_PROXY", "no_proxy"] { env[key] = "localhost,127.0.0.1,::1" }
        env["NODE_USE_ENV_PROXY"] = "1"   // Node's own fetch only honours the proxy with this
        return env
    }

    /// Whether `host` is one of `sites` or under one.
    public static func allows(host: String, sites: [String]) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        guard !h.isEmpty else { return false }
        return sites.contains { s in
            let site = s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            return !site.isEmpty && (h == site || h.hasSuffix("." + site))
        }
    }

    // MARK: -

    private func sites(for token: String?) -> [String]? {
        guard let token else { return nil }
        lock.lock(); defer { lock.unlock() }
        return tokens[token]
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            EngineRunner.spawnThread { [weak self] in
                guard let self else { close(client); return }
                self.handle(client)
            }
        }
    }

    private func handle(_ client: Int32) {
        var closeClient = true
        defer { if closeClient { close(client) } }
        guard let (head, rest) = Self.readHead(client) else { return }
        var lines = head.components(separatedBy: "\r\n")
        let request = lines.removeFirst().split(separator: " ").map(String.init)
        guard request.count == 3 else { return Self.reply(client, 400, "Bad request") }
        let method = request[0], target = request[1]
        let token = Self.token(from: lines)
        guard let allowed = sites(for: token) else {
            return Self.reply(client, 407, "Launchpad: this bot's proxy password is missing or expired.",
                              extra: "Proxy-Authenticate: Basic realm=\"launchpad\"\r\n")
        }
        let host: String, port: UInt16
        var forward = Data()
        if method.uppercased() == "CONNECT" {
            guard let (h, p) = Self.hostPort(target, defaultPort: 443) else { return Self.reply(client, 400, "Bad request") }
            host = h; port = p
        } else {
            guard let url = URL(string: target), url.scheme?.lowercased() == "http", let h = url.host else {
                return Self.reply(client, 400, "Launchpad's gateway only forwards http:// and tunnels https://")
            }
            host = h; port = UInt16(url.port ?? 80)
            var path = url.path.isEmpty ? "/" : url.path
            if let q = url.query { path += "?" + q }
            let kept = lines.filter { !$0.lowercased().hasPrefix("proxy-") && !$0.isEmpty }
            forward = Data(([("\(method) \(path) \(request[2])")] + kept + ["", ""]).joined(separator: "\r\n").utf8) + rest
        }
        guard Self.allows(host: host, sites: allowed) else {
            return Self.reply(client, 403, "Launchpad: this bot is locked down and \(host) isn't on its list of sites. Ask the user to add it.")
        }
        guard let upstream = Self.connect(host: host, port: port) else { return Self.reply(client, 502, "Couldn't reach \(host).") }
        if method.uppercased() == "CONNECT" {
            Self.send(client, Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
            if !rest.isEmpty { Self.send(upstream, rest) }
        } else {
            Self.send(upstream, forward)
        }
        closeClient = false
        Self.relay(client, upstream)
    }

    /// Reads up to the end of the request head. Returns the head and any bytes after it.
    static func readHead(_ fd: Int32) -> (String, Data)? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        let end = Data("\r\n\r\n".utf8)
        while data.count < 64 * 1024 {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { return nil }
            data.append(buf, count: n)
            if let r = data.range(of: end) {
                return (String(decoding: data[..<r.lowerBound], as: UTF8.self), Data(data[r.upperBound...]))
            }
        }
        return nil
    }

    static func token(from headers: [String]) -> String? {
        for line in headers where line.lowercased().hasPrefix("proxy-authorization:") {
            let value = line.dropFirst("proxy-authorization:".count).trimmingCharacters(in: .whitespaces)
            guard value.lowercased().hasPrefix("basic "),
                  let decoded = Data(base64Encoded: String(value.dropFirst(6)).trimmingCharacters(in: .whitespaces)),
                  let text = String(data: decoded, encoding: .utf8), let colon = text.firstIndex(of: ":") else { return nil }
            return String(text[text.index(after: colon)...])
        }
        return nil
    }

    static func hostPort(_ s: String, defaultPort: UInt16) -> (String, UInt16)? {
        if s.hasPrefix("[") {   // [::1]:443
            guard let close = s.firstIndex(of: "]") else { return nil }
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            let port = rest.hasPrefix(":") ? UInt16(rest.dropFirst()) : defaultPort
            return port.map { (host, $0) }
        }
        let parts = s.split(separator: ":")
        guard let h = parts.first, !h.isEmpty, parts.count <= 2 else { return nil }
        let port = parts.count == 2 ? UInt16(parts[1]) : defaultPort
        return port.map { (String(h), $0) }
    }

    static func reply(_ fd: Int32, _ code: Int, _ text: String, extra: String = "") {
        let reason = [400: "Bad Request", 403: "Forbidden", 407: "Proxy Authentication Required", 502: "Bad Gateway"][code] ?? "Error"
        let body = Data((text + "\n").utf8)
        let head = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\n\(extra)Connection: close\r\n\r\n"
        send(fd, Data(head.utf8) + body)
    }

    static func send(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                #if canImport(Glibc)
                let n = Glibc.send(fd, base + sent, raw.count - sent, Int32(MSG_NOSIGNAL))
                #else
                let n = Darwin.send(fd, base + sent, raw.count - sent, 0)
                #endif
                if n <= 0 { return }
                sent += n
            }
        }
    }

    static func connect(host: String, port: UInt16) -> Int32? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Glibc)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(first) }
        var ai: UnsafeMutablePointer<addrinfo>? = first
        while let a = ai {
            let fd = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if fd >= 0 {
                #if canImport(Darwin)
                var one: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                #endif
                if connectSocket(fd, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0 { return fd }
                close(fd)
            }
            ai = a.pointee.ai_next
        }
        return nil
    }

    /// Copies bytes both ways until either side closes, then closes both.
    static func relay(_ a: Int32, _ b: Int32) {
        let done = DispatchSemaphore(value: 0)
        @Sendable func pump(_ from: Int32, _ to: Int32) {
            var buf = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let n = recv(from, &buf, buf.count, 0)
                if n <= 0 { break }
                send(to, Data(buf[0..<n]))
            }
            shutdown(to, Int32(SHUT_WR))
            done.signal()
        }
        EngineRunner.spawnThread { pump(a, b) }
        EngineRunner.spawnThread { pump(b, a) }
        EngineRunner.spawnThread {
            done.wait(); done.wait()
            close(a); close(b)
        }
    }
}

private func connectSocket(_ fd: Int32, _ addr: UnsafeMutablePointer<sockaddr>!, _ len: socklen_t) -> Int32 {
    #if canImport(Glibc)
    return Glibc.connect(fd, addr, len)
    #else
    return Darwin.connect(fd, addr, len)
    #endif
}
