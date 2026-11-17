import XCTest
@testable import LaunchpadCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A tiny HTTP server on 127.0.0.1 that answers every request with a canned response and remembers the requests.
final class FakeHTTPServer: @unchecked Sendable {
    let fd: Int32
    let port: UInt16
    private let lock = NSLock()
    private var _requests: [String] = []
    var requests: [String] { lock.lock(); defer { lock.unlock() }; return _requests }

    /// `chunks` are written one after another with `pause` seconds between them, then the connection closes.
    init(status: String = "200 OK", contentType: String = "text/event-stream", chunks: [String], pause: Double = 0) throws {
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0, listen(fd, 8) == 0 else { throw CocoaError(.fileWriteUnknown) }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        self.fd = fd
        port = UInt16(bigEndian: addr.sin_port)
        let listener = fd
        Thread.detachNewThread { [weak self] in
            while true {
                let c = accept(listener, nil, nil)
                if c < 0 { return }
                #if canImport(Darwin)
                var one: Int32 = 1
                setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                #endif
                let request = Self.readRequest(c)
                self?.lock.lock(); self?._requests.append(request); self?.lock.unlock()
                let head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nConnection: close\r\n\r\n"
                Self.write(c, head)
                for chunk in chunks {
                    Self.write(c, chunk)
                    if pause > 0 { Thread.sleep(forTimeInterval: pause) }
                }
                shutdown(c, Int32(SHUT_RDWR))
                close(c)
            }
        }
    }

    static func write(_ c: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        var sent = 0
        while sent < bytes.count {
            #if canImport(Glibc)
            let flags = Int32(MSG_NOSIGNAL)   // the client may hang up first (Stop): no SIGPIPE
            #else
            let flags: Int32 = 0
            #endif
            let n = bytes.withUnsafeBytes { send(c, $0.baseAddress! + sent, bytes.count - sent, flags) }
            if n <= 0 { return }
            sent += n
        }
    }

    static func readRequest(_ c: Int32) -> String {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = recv(c, &buf, buf.count, 0)
            if n <= 0 { break }
            data.append(buf, count: n)
            let text = String(decoding: data, as: UTF8.self)
            guard let headEnd = text.range(of: "\r\n\r\n") else { continue }
            let head = text[..<headEnd.lowerBound].lowercased()
            let length = head.components(separatedBy: "\r\n").first { $0.hasPrefix("content-length:") }
                .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
            if text.utf8.count - text[..<headEnd.upperBound].utf8.count >= length { break }
        }
        return String(decoding: data, as: UTF8.self)
    }

    func stop() {
        shutdown(fd, Int32(SHUT_RDWR))
        close(fd)
    }

    /// A port with nothing listening.
    static func closedPort() throws -> UInt16 {
        let s = try FakeHTTPServer(chunks: [])
        let p = s.port
        s.stop()
        return p
    }
}

final class LocalModelTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lp-local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func collect(_ handle: RunHandle) async -> [RunEvent] {
        var events: [RunEvent] = []
        for await e in handle.events { events.append(e) }
        return events
    }

    private func localBot(port: UInt16, model: String? = "llama3.2") -> Bot {
        Bot(id: "loco", name: "Loco", engine: .local, model: model, localBaseURL: "http://127.0.0.1:\(port)/v1")
    }

    // MARK: Pure parts

    func testBaseURLNormalising() {
        XCTAssertEqual(LocalModel.normalizedBaseURL(nil)?.absoluteString, "http://localhost:11434/v1")
        XCTAssertEqual(LocalModel.normalizedBaseURL("  ")?.absoluteString, "http://localhost:11434/v1")
        XCTAssertEqual(LocalModel.normalizedBaseURL("localhost:1234")?.absoluteString, "http://localhost:1234/v1")
        XCTAssertEqual(LocalModel.normalizedBaseURL("http://localhost:1234/v1/")?.absoluteString, "http://localhost:1234/v1")
        XCTAssertEqual(LocalModel.normalizedBaseURL("http://box:8080/v1/chat/completions")?.absoluteString, "http://box:8080/v1")
        XCTAssertEqual(LocalModel.normalizedBaseURL("https://llm.example/api")?.absoluteString, "https://llm.example/api")
        XCTAssertNil(LocalModel.normalizedBaseURL("ftp://nope"))
        XCTAssertNil(LocalModel.normalizedBaseURL("http://"))
        XCTAssertEqual(LocalModel.chatCompletionsURL("localhost:11434")?.absoluteString, "http://localhost:11434/v1/chat/completions")
        XCTAssertTrue(LocalModel.looksLikeOllama(nil))
        XCTAssertFalse(LocalModel.looksLikeOllama(LocalModel.lmStudioBaseURL))
    }

    func testMessagesFromHistory() {
        let history = [
            ChatMessage(role: .user, text: "Hi"),
            ChatMessage(role: .bot, botId: "loco", text: "Hello!"),
            ChatMessage(role: .notice, text: "Memory updated"),
            ChatMessage(role: .bot, botId: "loco", text: "half", status: .failed),
            ChatMessage(role: .bot, botId: "other", text: "I agree"),
            ChatMessage(role: .user, text: "What next?"),
        ]
        let msgs = LocalModel.messages(system: "SYS", history: history, prompt: "What next?", botId: "loco", names: ["other": "Ada"])
        XCTAssertEqual(msgs.map(\.role), ["system", "user", "assistant", "user"])
        XCTAssertEqual(msgs[0].content, "SYS")
        XCTAssertEqual(msgs[2].content, "Hello!")
        // Another bot's reply and the new prompt are merged into one user turn; the prompt isn't sent twice.
        XCTAssertEqual(msgs[3].content, "Ada: I agree\n\nWhat next?")
    }

    func testMessagesKeepNewestWithinBudget() {
        let history = (0..<20).flatMap { i in
            [ChatMessage(role: .user, text: "q\(i) " + String(repeating: "x", count: 100)),
             ChatMessage(role: .bot, botId: "b", text: "a\(i) " + String(repeating: "y", count: 100))]
        }
        let msgs = LocalModel.messages(system: "S", history: history, prompt: "now", botId: "b", budget: 500)
        XCTAssertEqual(msgs.first?.role, "system")
        XCTAssertEqual(msgs[1].role, "user", "starts with a user turn after the system prompt")
        XCTAssertTrue(msgs.last!.content.hasSuffix("now"))
        XCTAssertTrue(msgs.contains { $0.content.hasPrefix("a19") })
        XCTAssertFalse(msgs.contains { $0.content.hasPrefix("q0 ") })
        XCTAssertLessThan(msgs.dropFirst().map(\.content.count).reduce(0, +), 600)
    }

    func testRequestBodyAndHeaders() throws {
        let req = LocalModelRequest(baseURL: "localhost:1234", model: "qwen", messages: [LocalChatMessage(role: "user", content: "hi")],
                                    apiKey: "k-123")
        let r = try XCTUnwrap(req.urlRequest())
        XCTAssertEqual(r.url?.absoluteString, "http://localhost:1234/v1/chat/completions")
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer k-123")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: r.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "qwen")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual((body["messages"] as? [[String: String]])?.first?["content"], "hi")

        var plain = req
        plain.apiKey = nil
        plain.stream = false
        let r2 = try XCTUnwrap(plain.urlRequest())
        XCTAssertNil(r2.value(forHTTPHeaderField: "Authorization"))
        let body2 = try XCTUnwrap(JSONSerialization.jsonObject(with: r2.httpBody ?? Data()) as? [String: Any])
        XCTAssertNil(body2["stream_options"])
    }

    func testStreamDecoderSplitsAcrossChunks() {
        let d = LocalStreamDecoder()
        var events: [RunEvent] = []
        events += d.feed(Data("data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"Hel".utf8))
        XCTAssertTrue(events.isEmpty)
        events += d.feed(Data("lo\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\" there\"}}]}\n\n".utf8))
        events += d.feed(Data("data: {\"choices\":[],\"usage\":{\"prompt_tokens\":40,\"completion_tokens\":2}}\n\ndata: [DONE]\n\n".utf8))
        events += d.finish()
        XCTAssertEqual(events, [.textDelta("Hello"), .textDelta(" there"), .context(ContextUsage(engine: .local, used: 42))])
        XCTAssertTrue(d.sawDone)
        XCTAssertTrue(d.receivedText)
    }

    func testStreamDecoderWholeBodyAndErrors() {
        let d = LocalStreamDecoder()
        XCTAssertTrue(d.feed(Data(#"{"choices":[{"message":{"role":"assistant","content":"All at once"}}]}"#.utf8)).isEmpty)
        XCTAssertEqual(d.finish(), [.text("All at once")])

        let e = LocalStreamDecoder()
        _ = e.feed(Data(#"{"error":{"message":"model \"llama9\" not found, try pulling it first","type":"api_error"}}"#.utf8))
        _ = e.finish()
        XCTAssertEqual(e.errorMessage, "model \"llama9\" not found, try pulling it first")

        let f = LocalStreamDecoder()
        _ = f.feed(Data("data: {\"error\":\"Model unloaded\"}\n\n".utf8))
        XCTAssertEqual(f.errorMessage, "Model unloaded")
    }

    func testErrorsArePlainEnglish() {
        let missing = LocalModelErrors.classify(status: 404, body: "model \"llama9\" not found, try pulling it first",
                                                baseURL: nil, model: "llama9")
        XCTAssertTrue(missing.message.contains("ollama pull llama9"))
        XCTAssertEqual(missing.action, .openTerminal(command: "ollama pull llama9"))

        let lmStudio = LocalModelErrors.classify(status: 404, body: "model not found", baseURL: LocalModel.lmStudioBaseURL, model: "x")
        XCTAssertTrue(lmStudio.message.contains("LM Studio"))

        let wrongPath = LocalModelErrors.classify(status: 404, body: "404 page", baseURL: "http://box:8080/api", model: "x")
        XCTAssertTrue(wrongPath.message.contains("OpenAI-compatible"))

        let tooLong = LocalModelErrors.classify(status: 400, body: "the request exceeds the available context size", baseURL: nil, model: "m")
        XCTAssertTrue(tooLong.message.contains("too long"))

        let down = LocalModelErrors.transport(URLError(.cannotConnectToHost), baseURL: nil)
        XCTAssertEqual(down.kind, .network)
        XCTAssertTrue(down.message.contains("Start Ollama"))
        XCTAssertEqual(down.action, .openTerminal(command: "ollama serve"))
        let downLM = LocalModelErrors.transport(URLError(.cannotConnectToHost), baseURL: LocalModel.lmStudioBaseURL)
        XCTAssertTrue(downLM.message.contains("http://localhost:1234/v1"))
    }

    func testInvocationReadsInstructionsAndHistory() throws {
        try "Be a pirate.".write(to: tmp.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        var o = RunOptions()
        o.history = [ChatMessage(role: .user, text: "ahoy"), ChatMessage(role: .bot, botId: "loco", text: "arr")]
        o.localAPIKey = "secret"
        let bot = Bot(id: "loco", name: "Loco", engine: .local, model: "llama3.2")
        let inv = EngineCommand.invocation(for: bot, prompt: "more", botDirectory: tmp, sessionId: "ignored", options: o)
        XCTAssertEqual(inv.engine, .local)
        XCTAssertTrue(inv.arguments.isEmpty)
        XCTAssertNil(inv.plannedSessionId)
        let req = try XCTUnwrap(inv.local)
        XCTAssertEqual(req.baseURL, LocalModel.defaultBaseURL)
        XCTAssertEqual(req.model, "llama3.2")
        XCTAssertEqual(req.apiKey, "secret")
        XCTAssertTrue(req.messages[0].content.hasPrefix("Be a pirate."))
        XCTAssertTrue(req.messages[0].content.contains("no tools"))
        XCTAssertEqual(req.messages.map(\.role), ["system", "user", "assistant", "user"])
        XCTAssertEqual(req.messages.last?.content, "more")
    }

    func testBotJSONStaysBackwardCompatible() throws {
        let old = #"{"id":"a","name":"A","engine":"codex","model":"gpt-5"}"#
        let bot = try JSONCoding.decoder().decode(Bot.self, from: Data(old.utf8))
        XCTAssertNil(bot.backup)
        XCTAssertNil(bot.localBaseURL)
        // Optional fields aren't written when unset, so older builds read the file as before.
        let encoded = String(decoding: try JSONCoding.encoder().encode(bot), as: UTF8.self)
        XCTAssertFalse(encoded.contains("backup"))
        XCTAssertFalse(encoded.contains("localBaseURL"))

        var local = Bot(id: "l", name: "L", engine: .local, model: "llama3.2", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                        localBaseURL: LocalModel.lmStudioBaseURL)
        local.backup = BotBrain(engine: .claude, model: "haiku")
        let back = try JSONCoding.decoder().decode(Bot.self, from: try JSONCoding.encoder().encode(local))
        XCTAssertEqual(back, local)
        XCTAssertEqual(back.engine, .local)

        let messy = #"{"id":"m","name":"M","engine":"local","localBaseURL":"","backup":{"engine":"warp","model":""}}"#
        let m = try JSONCoding.decoder().decode(Bot.self, from: Data(messy.utf8))
        XCTAssertNil(m.localBaseURL)
        XCTAssertEqual(m.backup, BotBrain(engine: .claude))
    }

    func testEngineNamesForLocal() {
        XCTAssertEqual(BotEngine.local.displayName, "Local model")
        XCTAssertFalse(BotEngine.local.isAgent)
        XCTAssertTrue(BotEngine.codex.isAgent)
        XCTAssertEqual(BotSandbox.engineSites(.local), [])
        XCTAssertEqual(BotEngine.allCases, [.claude, .codex, .local])
    }

    // MARK: Runner, against a fake server

    func testRunnerStreamsFromServer() async throws {
        let server = try FakeHTTPServer(chunks: [
            "data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\" there\"}}]}\n\n",
            "data: [DONE]\n\n",
        ], pause: 0.05)
        defer { server.stop() }
        var o = RunOptions()
        o.history = [ChatMessage(role: .user, text: "earlier"), ChatMessage(role: .bot, botId: "loco", text: "sure")]
        let inv = EngineCommand.invocation(for: localBot(port: server.port), prompt: "hello", botDirectory: tmp, sessionId: nil, options: o)
        let events = await collect(EngineRunner().run(inv))
        XCTAssertEqual(events, [.textDelta("Hi"), .textDelta(" there"), .finished(resultText: nil)])

        let request = try XCTUnwrap(server.requests.first)
        XCTAssertTrue(request.hasPrefix("POST /v1/chat/completions"), request)
        XCTAssertTrue(request.contains("\"earlier\""), request)
        XCTAssertTrue(request.contains("\"hello\""))
        XCTAssertTrue(request.contains("\"llama3.2\""))

        var builder = MessageBuilder(botId: "loco")
        events.forEach { builder.apply($0) }
        XCTAssertEqual(builder.message.text, "Hi there")
        XCTAssertEqual(builder.message.status, .done)
    }

    func testRunnerHandlesNonStreamingServer() async throws {
        let server = try FakeHTTPServer(contentType: "application/json",
                                        chunks: [#"{"choices":[{"message":{"role":"assistant","content":"Whole answer"}}]}"#])
        defer { server.stop() }
        let inv = EngineCommand.invocation(for: localBot(port: server.port), prompt: "q", botDirectory: tmp, sessionId: nil)
        let events = await collect(EngineRunner().run(inv))
        XCTAssertEqual(events, [.text("Whole answer"), .finished(resultText: nil)])
    }

    func testRunnerExplainsMissingModel() async throws {
        let server = try FakeHTTPServer(status: "404 Not Found", contentType: "application/json",
                                        chunks: [#"{"error":{"message":"model \"nope\" not found, try pulling it first"}}"#])
        defer { server.stop() }
        var bot = localBot(port: server.port, model: "nope")
        bot.localBaseURL = "http://127.0.0.1:\(server.port)/v1"
        let events = await collect(EngineRunner().run(EngineCommand.invocation(for: bot, prompt: "q", botDirectory: tmp, sessionId: nil)))
        guard case .failed(let f)? = events.last else { return XCTFail("\(events)") }
        XCTAssertTrue(f.message.contains("nope"), f.message)
        XCTAssertEqual(events.count, 1)
    }

    func testRunnerExplainsServerNotRunning() async throws {
        let port = try FakeHTTPServer.closedPort()
        let events = await collect(EngineRunner().run(
            EngineCommand.invocation(for: localBot(port: port), prompt: "q", botDirectory: tmp, sessionId: nil)))
        guard case .failed(let f)? = events.last else { return XCTFail("\(events)") }
        XCTAssertEqual(f.kind, .network)
        XCTAssertTrue(f.message.contains("Start Ollama or LM Studio"), f.message)
    }

    func testRunnerNeedsAModel() async throws {
        let events = await collect(EngineRunner().run(
            EngineCommand.invocation(for: localBot(port: 9, model: nil), prompt: "q", botDirectory: tmp, sessionId: nil)))
        XCTAssertEqual(events, [.failed(LocalModelErrors.noModel)])
    }

    func testStopEndsALocalRun() async throws {
        let server = try FakeHTTPServer(chunks: (0..<40).map { _ in "data: {\"choices\":[{\"delta\":{\"content\":\".\"}}]}\n\n" }, pause: 0.1)
        defer { server.stop() }
        let handle = EngineRunner().run(EngineCommand.invocation(for: localBot(port: server.port), prompt: "q", botDirectory: tmp, sessionId: nil))
        Task { try? await Task.sleep(nanoseconds: 400_000_000); handle.cancel() }
        let started = Date()
        let events = await collect(handle)
        XCTAssertEqual(events.last, .stopped)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
}
