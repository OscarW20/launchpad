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
