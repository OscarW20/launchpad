import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Local models: Ollama, LM Studio or any server that speaks OpenAI's `POST {base}/chat/completions`.
///
/// They have no session of their own, so every turn sends the chat so far, and no tools: they can only talk.
public enum LocalModel {
    /// Ollama's OpenAI-compatible endpoint.
    public static let defaultBaseURL = "http://localhost:11434/v1"
    /// LM Studio's local server.
    public static let lmStudioBaseURL = "http://localhost:1234/v1"
    /// How much of the chat goes with each turn (characters, newest kept). Small local models have small windows.
    public static let historyBudget = 24_000

    /// "localhost:11434" → "http://localhost:11434/v1"; trailing slashes and a pasted "/chat/completions" go.
    public static func normalizedBaseURL(_ raw: String?) -> URL? {
        var text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = defaultBaseURL }
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix("/chat/completions") { text.removeLast("/chat/completions".count) }
        guard var parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = parts.host, !host.isEmpty else { return nil }
        if parts.path.isEmpty || parts.path == "/" { parts.path = "/v1" }
        return parts.url
    }

    public static func chatCompletionsURL(_ base: String?) -> URL? {
        normalizedBaseURL(base)?.appendingPathComponent("chat").appendingPathComponent("completions")
    }

    /// True for Ollama's usual address, so errors can suggest `ollama pull`.
    static func looksLikeOllama(_ base: String?) -> Bool {
        normalizedBaseURL(base)?.port == 11434
    }

    /// What the model is told about itself: the bot's instructions plus a note that it has no tools.
    public static func systemPrompt(botName: String, instructions: String?) -> String {
        var parts: [String] = []
        if let instructions = instructions?.trimmingCharacters(in: .whitespacesAndNewlines), !instructions.isEmpty {
            parts.append(instructions)
        } else {
            parts.append("You are \(botName), a helpful assistant.")
        }
        parts.append("You are running as a local model on the user's computer. You have no tools: you can't read or "
            + "change files, run commands or browse the web, so don't claim to. Answer from the conversation.")
        return parts.joined(separator: "\n\n")
    }

    /// The messages for one turn: system prompt, the chat so far (newest kept within `budget`), then the new prompt.
    ///
    /// `history` is the chat's messages; if its last one is the user's message being answered, it isn't sent twice.
    /// In group chats other bots' replies go in as user turns prefixed with their name.
    public static func messages(system: String, history: [ChatMessage], prompt: String, botId: String?,
                                names: [String: String] = [:], budget: Int = historyBudget) -> [LocalChatMessage] {
        var turns: [LocalChatMessage] = []
        for m in history {
            let text = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            switch m.role {
            case .notice: continue
            case .user: turns.append(LocalChatMessage(role: "user", content: text))
            case .bot:
                guard m.status == .done || m.status == .stopped else { continue }
                if m.botId == botId || botId == nil {
                    turns.append(LocalChatMessage(role: "assistant", content: text))
                } else {
                    let who = m.botId.flatMap { names[$0] } ?? "Another bot"
                    turns.append(LocalChatMessage(role: "user", content: "\(who): \(text)"))
                }
            }
        }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = turns.last, last.role == "user", last.content == trimmedPrompt { turns.removeLast() }
        // Keep the newest turns that fit.
        var kept: [LocalChatMessage] = []
        var used = trimmedPrompt.count
        for turn in turns.reversed() {
            used += turn.content.count
            if used > budget { break }
            kept.insert(turn, at: 0)
        }
        // The API wants user/assistant turns to alternate after the system prompt; merge neighbours with the same role.
        var merged: [LocalChatMessage] = []
        for turn in kept + [LocalChatMessage(role: "user", content: prompt)] {
            if let last = merged.last, last.role == turn.role {
                merged[merged.count - 1].content += "\n\n" + turn.content
            } else {
                merged.append(turn)
            }
        }
        if merged.first?.role == "assistant" { merged.removeFirst() }
        return [LocalChatMessage(role: "system", content: system)] + merged
    }
}

public struct LocalChatMessage: Codable, Hashable, Sendable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

/// One HTTP call to a local model.
public struct LocalModelRequest: Equatable, Sendable {
    public var baseURL: String
    public var model: String
    public var messages: [LocalChatMessage]
    /// Only for servers that want one (LM Studio and Ollama don't). From the Keychain; never logged or saved.
    public var apiKey: String?
    public var stream: Bool

    public init(baseURL: String, model: String, messages: [LocalChatMessage], apiKey: String? = nil, stream: Bool = true) {
        self.baseURL = baseURL
        self.model = model
        self.messages = messages
        self.apiKey = apiKey
        self.stream = stream
    }

    public var url: URL? { LocalModel.chatCompletionsURL(baseURL) }

    public func body() -> Data {
        var object: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "stream": stream,
        ]
        if stream { object["stream_options"] = ["include_usage": true] }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    public func urlRequest() -> URLRequest? {
        guard let url else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.timeoutInterval = 600
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty { r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        r.httpBody = body()
        return r
    }
}

/// Reads a chat-completions response as it arrives: server-sent events (`data: {…}` … `data: [DONE]`) when
/// streaming, or one JSON body when the server ignored `stream` (or answered with an error).
public final class LocalStreamDecoder: @unchecked Sendable {
    private var buffer = Data()
    private var raw = Data()
    private var sawEvent = false
    public private(set) var sawDone = false
    public private(set) var receivedText = false
    /// An error the server reported inside the body.
    public private(set) var errorMessage: String?
    private let window: Int?

    public init(contextWindow: Int? = nil) { window = contextWindow }

    /// Feed bytes as they arrive; returns events to pass on.
    public func feed(_ data: Data) -> [RunEvent] {
        if raw.count < 256 * 1024 { raw.append(data) }
        buffer.append(data)
        var events: [RunEvent] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            events += handle(line: String(decoding: line, as: UTF8.self))
        }
        return events
    }

    /// The response is over; returns any last events (a whole JSON body, or a final unterminated line).
    public func finish() -> [RunEvent] {
        var events: [RunEvent] = []
        if !buffer.isEmpty {
            events += handle(line: String(decoding: buffer, as: UTF8.self))
            buffer.removeAll()
        }
        if !sawEvent {
            let text = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if let obj = jsonObject(text) { events += handleObject(obj, whole: true) }
        }
        return events
    }

    /// The raw body (first 256 KB), for error details.
    public var bodyText: String { String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }

    private func handle(line rawLine: String) -> [RunEvent] {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("data:") else { return [] }
        sawEvent = true
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { sawDone = true; return [] }
        guard let obj = jsonObject(payload) else { return [] }
        return handleObject(obj, whole: false)
    }

    private func handleObject(_ obj: [String: Any], whole: Bool) -> [RunEvent] {
        if let err = obj["error"] {
            errorMessage = (err as? [String: Any])?["message"] as? String ?? (err as? String) ?? "The local model reported an error."
            return []
        }
        var events: [RunEvent] = []
        for choice in obj["choices"] as? [[String: Any]] ?? [] {
            let part = (choice[whole ? "message" : "delta"] as? [String: Any])?["content"] as? String
                ?? (whole ? nil : (choice["message"] as? [String: Any])?["content"] as? String)
            if let part, !part.isEmpty {
                receivedText = true
                events.append(whole ? .text(part) : .textDelta(part))
            }
        }
        if let usage = obj["usage"] as? [String: Any], let prompt = (usage["prompt_tokens"] as? NSNumber)?.intValue {
            let completion = (usage["completion_tokens"] as? NSNumber)?.intValue ?? 0
            events.append(.context(ContextUsage(engine: .local, used: prompt + completion, window: window)))
        }
        return events
    }
}

/// Plain-English failures for local models.
public enum LocalModelErrors {
    public static func notRunning(baseURL: String?, detail: String?) -> RunFailure {
        let shown = LocalModel.normalizedBaseURL(baseURL)?.absoluteString ?? LocalModel.defaultBaseURL
        let ollama = LocalModel.looksLikeOllama(baseURL)
        let message = ollama
            ? "Your local model isn't running. Start Ollama (open the app, or run `ollama serve` in Terminal), then try again."
            : "Couldn't reach the local model at \(shown). Start Ollama or LM Studio's server, then try again."
        return RunFailure(kind: .network, message: message, detail: detail,
                          action: ollama ? .openTerminal(command: "ollama serve") : .openURL(BotEngine.local.installURL))
    }

    public static func badURL(_ baseURL: String?) -> RunFailure {
        RunFailure(kind: .unknown,
                   message: "The local model address “\(baseURL ?? "")” isn't a web address. Try \(LocalModel.defaultBaseURL).")
    }

    public static let noModel = RunFailure(
        kind: .unknown,
        message: "Pick a model for this bot first (for example llama3.2), in its settings.")

    /// An HTTP error or an error in the body.
    public static func classify(status: Int?, body: String, baseURL: String?, model: String) -> RunFailure {
        let lower = body.lowercased()
        let detail = body.isEmpty ? (status.map { "HTTP \($0)" }) : body
        if lower.contains("not found") && (lower.contains("model") || status == 404) || lower.contains("try pulling it") {
            if LocalModel.looksLikeOllama(baseURL) {
                return RunFailure(kind: .unknown,
                                  message: "The model “\(model)” isn't on this computer yet. Download it with `ollama pull \(model)`, then try again.",
                                  detail: detail, action: .openTerminal(command: "ollama pull \(model)"))
            }
            return RunFailure(kind: .unknown,
                              message: "The local server doesn't have a model called “\(model)”. Load it in LM Studio (or check the name), then try again.",
                              detail: detail)
        }
        if status == 401 || status == 403 {
            return RunFailure(kind: .signedOut, message: "The local model server turned down the request. Check its API key in Settings.",
                              detail: detail)
        }
        if status == 404 {
            return RunFailure(kind: .unknown,
                              message: "That address doesn't look like an OpenAI-compatible server (no /chat/completions). Try \(LocalModel.defaultBaseURL).",
                              detail: detail)
        }
        if lower.contains("context") && (lower.contains("length") || lower.contains("too long") || lower.contains("exceed")) {
            return RunFailure(kind: .unknown, message: "This chat is too long for the local model. Start a new thread, or compact this one.",
                              detail: detail)
        }
        let first = body.split(separator: "\n").first.map(String.init) ?? ""
        let summary = first.isEmpty ? "The local model stopped unexpectedly\(status.map { " (HTTP \($0))" } ?? "")."
            : "The local model ran into a problem: \(ToolSummary.short(first, max: 160))"
        return RunFailure(kind: .unknown, message: summary, detail: detail)
    }

    /// A transport error (nothing listening, timed out…).
    public static func transport(_ error: Error, baseURL: String?) -> RunFailure {
        let ns = error as NSError
        let text = "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
        let refused: Set<Int> = [
            URLError.cannotConnectToHost.rawValue, URLError.cannotFindHost.rawValue,
            URLError.networkConnectionLost.rawValue, URLError.notConnectedToInternet.rawValue,
            URLError.dnsLookupFailed.rawValue, URLError.secureConnectionFailed.rawValue,
        ]
        if ns.domain == NSURLErrorDomain, refused.contains(ns.code) { return notRunning(baseURL: baseURL, detail: text) }
        if ns.domain == NSURLErrorDomain, ns.code == URLError.timedOut.rawValue {
            return RunFailure(kind: .network, message: "The local model took too long to answer. It may still be loading: try again in a moment.",
                              detail: text)
        }
        let lower = text.lowercased()
        if lower.contains("connect") || lower.contains("refused") { return notRunning(baseURL: baseURL, detail: text) }
        return RunFailure(kind: .network, message: "Something went wrong talking to the local model: \(ns.localizedDescription)", detail: text)
    }
}

/// Sends a `LocalModelRequest` and streams its answer as RunEvents. Blocks until done (the runner calls it on its own thread).
enum LocalModelClient {
    static func run(_ request: LocalModelRequest, state: RunState, emit: @escaping (RunEvent) -> Void) {
        guard !request.model.trimmingCharacters(in: .whitespaces).isEmpty else { emit(.failed(LocalModelErrors.noModel)); return }
        guard let urlRequest = request.urlRequest() else { emit(.failed(LocalModelErrors.badURL(request.baseURL))); return }

        let decoder = LocalStreamDecoder()
        let delegate = StreamDelegate(decoder: decoder, emit: emit)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 3600
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Local servers are on this computer: never send them through a proxy.
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: urlRequest)
        guard state.attach(cancel: { task.cancel() }) else {
            session.invalidateAndCancel()
            emit(.stopped)
            return
        }
        task.resume()
        delegate.done.wait()
        session.finishTasksAndInvalidate()

        if state.isCancelled { emit(.stopped); return }
        if let error = delegate.error {
            if (error as NSError).code == URLError.cancelled.rawValue { emit(.stopped); return }
            emit(.failed(LocalModelErrors.transport(error, baseURL: request.baseURL)))
            return
        }
        let status = delegate.status ?? 0
        let last = decoder.finish()
        if status < 400 { for event in last { emit(event) } }
        if let message = decoder.errorMessage {
            emit(.failed(LocalModelErrors.classify(status: status, body: message, baseURL: request.baseURL, model: request.model)))
        } else if status >= 400 {
            emit(.failed(LocalModelErrors.classify(status: status, body: decoder.bodyText, baseURL: request.baseURL, model: request.model)))
        } else if !decoder.receivedText {
            emit(.failed(RunFailure(kind: .unknown, message: "The local model didn't send back an answer.",
                                    detail: decoder.bodyText.isEmpty ? nil : String(decoder.bodyText.prefix(2000)))))
        } else {
            emit(.finished(resultText: nil))
        }
    }

    private final class StreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let decoder: LocalStreamDecoder
        let emit: (RunEvent) -> Void
        let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var _status: Int?
        private var _error: Error?

        init(decoder: LocalStreamDecoder, emit: @escaping (RunEvent) -> Void) {
            self.decoder = decoder
            self.emit = emit
        }

        var status: Int? { lock.lock(); defer { lock.unlock() }; return _status }
        var error: Error? { lock.lock(); defer { lock.unlock() }; return _error }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            lock.lock(); _status = (response as? HTTPURLResponse)?.statusCode; lock.unlock()
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock(); let failed = (_status ?? 200) >= 400; lock.unlock()
            let events = decoder.feed(data)
            if !failed { for e in events { emit(e) } }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock(); _error = error; lock.unlock()
            done.signal()
        }
    }
}
