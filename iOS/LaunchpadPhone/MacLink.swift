import Foundation
import Network
import Observation
import Security
import UIKit

// The phone's side of the phone link: finds the Mac with Bonjour, pairs with a code, then keeps the chat list and
// the open chat fresh by asking the Mac what changed. The JSON shapes match LaunchpadCore/PhoneLink.swift.

struct BotInfo: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let emoji: String
    let colour: String
    let role: String
    let engine: String
    let working: Bool
}

struct ChatInfo: Decodable, Identifiable, Hashable {
    struct Last: Decodable, Hashable { let text: String; let date: Date; let from: String }
    let id: String
    let kind: String
    let name: String
    let emoji: String
    var colour: String?
    var role: String?
    var botId: String?
    var members: [String]?
    var lead: String?
    let unread: Int
    let working: Bool
    let typing: [String]
    var last: Last?

    var isGroup: Bool { kind == "group" }
    var lastDate: Date { last?.date ?? .distantPast }
}

struct StateResponse: Decodable {
    let app: String
    let mac: String
    let bots: [BotInfo]
    let chats: [ChatInfo]
    let rev: String
}

struct Message: Decodable, Identifiable, Hashable {
    struct Author: Decodable, Hashable {
        let kind: String
        var id: String?
        let name: String
        var emoji: String?
        var colour: String?
        var role: String?
    }
    struct Questions: Decodable, Hashable {
        struct Item: Decodable, Hashable { let text: String; let options: [String]; let multi: Bool }
        let items: [Item]
        let answered: Bool
        var answers: [String]?
    }
    struct Approval: Decodable, Hashable { let action: String; let status: String }
    struct Card: Decodable, Hashable, Identifiable {
        let id: String
        let category: String
        let title: String
        let tool: String
        let detail: String
        let state: String
        let canAlways: Bool
    }

    let id: String
    let author: Author
    let text: String
    let date: Date
    let state: String
    let steps: Int
    var step: String?
    var error: String?
    var reactions: [String: Int]?
    var deleted: Bool?
    var gif: String?
    var poll: String?
    var files: [String]?
    var questions: Questions?
    var approval: Approval?
    var cards: [Card]?

    var isMine: Bool { author.kind == "user" }
    var isStreaming: Bool { state == "streaming" }
}

struct FoundMac: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let url: URL
}

@MainActor @Observable
final class MacLink {
    var base: URL? = UserDefaults.standard.url(forKey: "mac.url")
    var macName = UserDefaults.standard.string(forKey: "mac.name") ?? ""
    private(set) var token: String? = Keychain.read("phone.token")

    var state: StateResponse?
    var messages: [String: [Message]] = [:]
    var openThread: String?
    var connected = false
    var lastError: String?
    var found: [FoundMac] = []

    var isPaired: Bool { base != nil && token != nil }

    private var rev = ""
    private var loop: Task<Void, Never>?
    private var browser: NWBrowser?

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: Finding the Mac

    func browse() {
        browser?.cancel()
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_launchpad._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { results, _ in
            var macs: [FoundMac] = []
            for r in results {
                guard case let .service(name, _, _, _) = r.endpoint, case let .bonjour(txt) = r.metadata,
                      let host = txt["host"], let port = txt["port"],
                      let url = URL(string: "http://\(host):\(port)") else { continue }
                macs.append(FoundMac(name: name, url: url))
            }
            Task { @MainActor in self.found = macs.sorted { $0.name < $1.name } }
        }
        b.start(queue: .main)
        browser = b
    }

    func stopBrowsing() { browser?.cancel(); browser = nil }

    /// "192.168.1.5", "100.64.0.3:8790" or "studio.local" -> a URL.
    static func url(from typed: String) -> URL? {
        var s = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.hasPrefix("http") { s = "http://" + s }
        guard var c = URLComponents(string: s), c.host != nil else { return nil }
        if c.port == nil { c.port = 8790 }
        c.path = ""
        return c.url
    }

    // MARK: Pairing

    func pair(with url: URL, code: String) async throws {
        var req = URLRequest(url: url.appending(path: "pair"))
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "device": UIDevice.current.name])
        let (data, response) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200, let token = obj["token"] as? String else {
            throw LinkError.message(obj["error"] as? String ?? "Couldn’t pair. Check the code and try again.")
        }
        Keychain.write("phone.token", token)
        self.token = token
        base = url
        macName = obj["mac"] as? String ?? "Mac"
        UserDefaults.standard.set(url, forKey: "mac.url")
        UserDefaults.standard.set(macName, forKey: "mac.name")
        start()
    }

    func unpair() {
        loop?.cancel()
        Keychain.delete("phone.token")
        token = nil
        base = nil
        state = nil
        messages = [:]
        UserDefaults.standard.removeObject(forKey: "mac.url")
    }

    // MARK: Staying fresh

    func start() {
        guard isPaired else { return }
        loop?.cancel()
        rev = ""
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .milliseconds(1000))
            }
        }
    }

    func pause() { loop?.cancel(); loop = nil }

    private func tick() async {
        do {
            let r: [String: String] = try await get("rev")
            connected = true
            lastError = nil
            guard let newRev = r["rev"], newRev != rev else { return }
            rev = newRev
            await refresh()
        } catch LinkError.unauthorized {
            connected = false
            lastError = "This Mac forgot your phone. Pair again."
        } catch {
            connected = false
            lastError = "Can’t reach \(macName.isEmpty ? "your Mac" : macName). Is Launchpad open, with Mobile on, and are you on the same Wi-Fi?"
        }
    }

    func refresh() async {
        if let s: StateResponse = try? await get("state") { state = s }
        if let id = openThread { await loadMessages(id) }
    }

    func loadMessages(_ id: String) async {
        struct Wrap: Decodable { let messages: [Message] }
        if let w: Wrap = try? await get("messages", query: ["thread": id, "limit": "120"]) { messages[id] = w.messages }
    }

    /// nil when it went through, otherwise what went wrong.
    func send(_ text: String, to thread: String, replyTo: String? = nil) async -> String? {
        var body: [String: Any] = ["thread": thread, "text": text]
        if let replyTo { body["replyTo"] = replyTo }
        return await act("send", body)
    }

    func askOnTheSide(_ text: String, in thread: String) async -> String? {
        await act("side", ["thread": thread, "text": text])
    }

    func answer(_ thread: String, message: String, answers: [String]) async -> String? {
        await act("answer", ["thread": thread, "message": message, "answers": answers])
    }

    func answer(_ thread: String, message: String, approve: Bool) async -> String? {
        await act("answer", ["thread": thread, "message": message, "approve": approve])
    }

    /// decision: "approve", "deny" or "always".
    func answer(_ thread: String, card: String, decision: String) async -> String? {
        await act("answer", ["thread": thread, "card": card, "decision": decision])
    }

    func markRead(_ thread: String) async { _ = try? await post("read", ["thread": thread]) }
    func stop(_ thread: String) async { _ = await act("stop", ["thread": thread]) }

    private func act(_ path: String, _ body: [String: Any]) async -> String? {
        do {
            try await post(path, body)
            rev = ""
            await tick()
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "Couldn’t reach your Mac."
        }
    }

    func bot(_ id: String?) -> BotInfo? { id.flatMap { id in state?.bots.first { $0.id == id } } }

    // MARK: HTTP

    enum LinkError: LocalizedError {
        case unauthorized, message(String)
        var errorDescription: String? {
            switch self {
            case .unauthorized: "Pair again"
            case .message(let m): m
            }
        }
    }

    private func request(_ path: String, query: [String: String] = [:]) throws -> URLRequest {
        guard let base, let token else { throw LinkError.unauthorized }
        var c = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 6
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: try request(path, query: query))
        if (response as? HTTPURLResponse)?.statusCode == 401 { throw LinkError.unauthorized }
        return try Self.decoder.decode(T.self, from: data)
    }

    @discardableResult
    private func post(_ path: String, _ body: [String: Any]) async throws -> Data {
        var req = try request(path)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw LinkError.unauthorized }
        guard code == 200 else {
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw LinkError.message(obj?["error"] as? String ?? "That didn’t work.")
        }
        return data
    }
}

/// The pairing token lives in the Keychain, never in plain settings.
enum Keychain {
    static let service = "app.launchpad.phone"

    static func read(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ key: String, _ value: String) {
        delete(key)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key,
                                kSecValueData as String: Data(value.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(_ key: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: key] as CFDictionary)
    }
}
