import Foundation

/// One long-lived browser for all bots.
///
/// Each bot reply is its own Claude Code / Codex process, and a stdio MCP server dies with it, so a browser a bot
/// opened closed a few seconds after the reply ended (and "open it and I'll sign in" couldn't work). Instead the app
/// runs the Playwright MCP server once (`--port`, `--shared-browser-context`, a saved profile) and every bot connects
/// to it over HTTP: the window stays open between replies and your logins in it persist.
public enum SharedBrowser {
    public static let defaultPort = 8931

    /// Is this the Browser app (Playwright MCP over stdio)?
    public static func isBrowser(_ c: Connector) -> Bool {
        c.kind == .stdio && c.args.contains { $0.hasPrefix("@playwright/mcp") }
    }

    /// Where bots reach the shared server.
    public static func url(port: Int) -> String { "http://localhost:\(port)/mcp" }

    /// The arguments to start the shared server, from the connector's own (keeps its package/version and your flags,
    /// drops ones that clash with sharing).
    public static func serverArguments(from c: Connector, port: Int, profileDir: String) -> [String] {
        var out: [String] = []
        var skipNext = false
        for a in c.args {
            if skipNext { skipNext = false; continue }
            if ["--port", "--user-data-dir", "--host"].contains(a) { skipNext = true; continue }
            if ["--isolated", "--no-sandbox", "--shared-browser-context", "--headless"].contains(a) { continue }
            out.append(a)
        }
        return out + ["--port", String(port), "--shared-browser-context", "--user-data-dir", profileDir]
    }

    /// Points browser connectors at the shared server (same id, so tool names and permissions don't change).
    public static func pointed(_ connectors: [Connector], at url: String) -> [Connector] {
        connectors.map { c in
            guard isBrowser(c) else { return c }
            return Connector(id: c.id, name: c.name, kind: .http, url: url)
        }
    }
}

/// Keeping the shared browser alive.
///
/// The Playwright server opens the browser lazily, for whichever bot session first uses it, and closes it when *that session
/// ends*, which is when that bot's reply ends. (Checked against the real server: with `--shared-browser-context`, bot A opens a
/// page, A's session closes, and bot B gets a blank browser; if a session that already opened the browser is still connected, B
/// sees A's page.) So the app keeps a session of its own connected and opens the browser on it. Bots then come and go, and a
/// sign-in you're doing stays open until the app quits, you close it, or the bot that opened it closes it.
///
/// This is only the messages; `SharedBrowserHost` (macOS) sends them.
public enum BrowserHold {
    public static let sessionHeader = "Mcp-Session-Id"
    public static let protocolVersion = "2025-03-26"

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// The first message of a session.
    public static func initialize() -> Data {
        json(["jsonrpc": "2.0", "id": 1, "method": "initialize",
              "params": ["protocolVersion": protocolVersion, "capabilities": [String: Any](),
                         "clientInfo": ["name": "launchpad-browser-holder", "version": "1"]]])
    }

    /// Sent after `initialize` is answered.
    public static func initialized() -> Data { json(["jsonrpc": "2.0", "method": "notifications/initialized"]) }

    /// Opens the browser (listing tabs starts it if it isn't running) so it belongs to this session.
    public static func openBrowser() -> Data { tool("browser_tabs", ["action": "list"], id: 2) }

    /// Closes it (you pressed Close). Not used for anything else: a run ending never calls this.
    public static func closeBrowser() -> Data { tool("browser_close", [:], id: 3) }

    /// A cheap check that the session is still there (does not start a browser).
    public static func ping() -> Data { json(["jsonrpc": "2.0", "id": 4, "method": "ping"]) }

    private static func tool(_ name: String, _ arguments: [String: Any], id: Int) -> Data {
        json(["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": name, "arguments": arguments]])
    }

    /// Did the server answer a request without an error? The body is JSON or server-sent events (`data: {…}`).
    public static func succeeded(_ response: String) -> Bool {
        var payload: [String: Any]?
        for line in response.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            let text = t.hasPrefix("data:") ? String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces) : t
            if text.hasPrefix("{"), let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] { payload = obj }
        }
        guard let payload, payload["error"] == nil else { return false }
        if let result = payload["result"] as? [String: Any], result["isError"] as? Bool == true { return false }
        return payload["result"] != nil
    }
}
