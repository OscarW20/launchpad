import Foundation

/// A ready-made MCP server ("app") you can install as a `Connector`.
/// Hosted servers are `.http` and sign in with your account in the browser (the Connectors page's
/// sign-in button). Local servers are `.stdio` and run through npx or uvx.
public struct ConnectorPreset: Identifiable, Hashable, Sendable {
    /// A value the server needs. Secrets go to the Keychain as environment variables;
    /// plain settings (a folder or file path) are filled into the args at install time.
    public struct Field: Hashable, Sendable {
        public var key: String
        public var label: String
        public var help: String
        public init(_ key: String, _ label: String, help: String = "") {
            self.key = key
            self.label = label
            self.help = help
        }
    }

    public var id: String
    public var name: String
    public var category: String
    public var blurb: String
    public var kind: Connector.Kind
    public var url: String?
    public var command: String?
    /// May contain `${KEY}` placeholders for `settings`, filled in by `connector(settings:)`.
    public var args: [String] = []
    /// Environment variables holding secrets (stored in the Keychain, never in files).
    public var secrets: [Field] = []
    /// Bearer token for an http server, stored in the Keychain.
    public var token: Field? = nil
    /// Non-secret values the user types when installing (paths), substituted into `args`.
    public var settings: [Field] = []
    /// File name in the app's `Logos` resource folder, or nil (use `symbol`).
    public var logo: String?
    /// SF Symbol fallback and accent colour.
    public var symbol: String
    public var tint: String
    public var docsURL: String

    /// Hosted servers that sign in with your own account (OAuth) the first time.
    public var signsIn: Bool { kind == .http && token == nil }
    /// What must be on the Mac for it to run.
    public var needs: String? { kind == .stdio ? command : nil }

    /// The connector this preset installs, with settings filled in.
    public func connector(id: String? = nil, settings values: [String: String] = [:]) throws -> Connector {
        for field in settings where (values[field.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            throw ConnectorCatalog.InstallError.missingSetting(field.label)
        }
        let filled = args.map { arg in
            settings.reduce(arg) { $0.replacingOccurrences(of: "${\($1.key)}", with: values[$1.key] ?? "") }
        }
        return Connector(id: id ?? self.id, name: name, kind: kind, url: url, command: command, args: filled,
                         secretEnv: secrets.map(\.key), usesToken: token != nil)
    }
}

public enum ConnectorCatalog {
    public enum InstallError: Error, LocalizedError, Equatable {
        case missingSetting(String)
        public var errorDescription: String? {
            switch self {
            case .missingSetting(let label): return "\(label) is needed to add this connector."
            }
        }
    }

    public static let categories = ["Work", "Code", "Web & research", "Design", "Data", "Payments & commerce", "Utilities"]

    // MARK: helpers

    private static func remote(_ id: String, _ name: String, _ category: String, _ blurb: String, url: String,
                               logo: String?, symbol: String, tint: String, docs: String) -> ConnectorPreset {
        ConnectorPreset(id: id, name: name, category: category, blurb: blurb, kind: .http, url: url, command: nil,
                        logo: logo, symbol: symbol, tint: tint, docsURL: docs)
    }

    /// Hosted servers that only speak the older SSE transport, bridged with mcp-remote.
    private static func sse(_ id: String, _ name: String, _ category: String, _ blurb: String, url: String,
                            logo: String?, symbol: String, tint: String, docs: String) -> ConnectorPreset {
        ConnectorPreset(id: id, name: name, category: category, blurb: blurb, kind: .stdio, url: nil, command: "npx",
                        args: ["-y", "mcp-remote", url], logo: logo, symbol: symbol, tint: tint, docsURL: docs)
    }

    private static func npx(_ id: String, _ name: String, _ category: String, _ blurb: String, package: String,
                            args: [String] = [], secrets: [ConnectorPreset.Field] = [], settings: [ConnectorPreset.Field] = [],
                            logo: String?, symbol: String, tint: String, docs: String) -> ConnectorPreset {
        ConnectorPreset(id: id, name: name, category: category, blurb: blurb, kind: .stdio, url: nil, command: "npx",
                        args: ["-y", package] + args, secrets: secrets, settings: settings,
                        logo: logo, symbol: symbol, tint: tint, docsURL: docs)
    }

    private static func uvx(_ id: String, _ name: String, _ category: String, _ blurb: String, package: String,
                            args: [String] = [], settings: [ConnectorPreset.Field] = [],
                            logo: String?, symbol: String, tint: String, docs: String) -> ConnectorPreset {
        ConnectorPreset(id: id, name: name, category: category, blurb: blurb, kind: .stdio, url: nil, command: "uvx",
                        args: [package] + args, settings: settings,
                        logo: logo, symbol: symbol, tint: tint, docsURL: docs)
    }

    private static let archived = "https://github.com/modelcontextprotocol/servers-archived/tree/main/src/"
    private static let reference = "https://github.com/modelcontextprotocol/servers/tree/main/src/"

    // MARK: presets

    public static let all: [ConnectorPreset] = [
        // Work
        npx("slack", "Slack", "Work", "Read channels, post messages and reply in threads.",
            package: "@modelcontextprotocol/server-slack",
            secrets: [.init("SLACK_BOT_TOKEN", "Bot token", help: "Starts with xoxb-. Create a Slack app with chat:write and channels:history."),
                      .init("SLACK_TEAM_ID", "Workspace ID", help: "Starts with T.")],
            logo: "slack.png", symbol: "number", tint: "#4A154B", docs: archived + "slack"),
        remote("notion", "Notion", "Work", "Search, read and write pages and databases.", url: "https://mcp.notion.com/mcp",
               logo: "notion.svg", symbol: "doc.text", tint: "#111111", docs: "https://developers.notion.com/docs/mcp"),
        remote("linear", "Linear", "Work", "Create, update and triage issues and projects.", url: "https://mcp.linear.app/mcp",
               logo: "linear.svg", symbol: "line.3.horizontal.decrease", tint: "#5E6AD2", docs: "https://linear.app/docs/mcp"),
        remote("atlassian", "Jira & Confluence", "Work", "Work with Jira tickets and Confluence pages.",
               url: "https://mcp.atlassian.com/v2/mcp",
               logo: "atlassian.svg", symbol: "checklist", tint: "#0052CC",
               docs: "https://support.atlassian.com/atlassian-rovo-mcp-server/"),
        sse("asana", "Asana", "Work", "Tasks, projects and comments.", url: "https://mcp.asana.com/sse",
            logo: "asana.svg", symbol: "circle.grid.3x3", tint: "#F06A6A", docs: "https://developers.asana.com/docs/using-asanas-mcp-server"),
        sse("monday", "monday.com", "Work", "Boards, items and updates.", url: "https://mcp.monday.com/sse",
            logo: "monday.png", symbol: "rectangle.3.group", tint: "#FF3D57", docs: "https://github.com/mondaycom/mcp"),
        sse("intercom", "Intercom", "Work", "Look up conversations and customers.", url: "https://mcp.intercom.com/sse",
            logo: "intercom.svg", symbol: "bubble.left.and.text.bubble.right", tint: "#1F8DED",
            docs: "https://developers.intercom.com/docs/guides/mcp"),
        remote("box", "Box", "Work", "Search and read files in Box.", url: "https://mcp.box.com",
               logo: "box.svg", symbol: "shippingbox", tint: "#0061D5", docs: "https://developer.box.com/guides/box-mcp/"),
        remote("zapier", "Zapier", "Work", "Trigger thousands of app actions through Zapier.", url: "https://mcp.zapier.com/api/mcp/mcp",
               logo: "zapier.svg", symbol: "bolt.horizontal", tint: "#FF4F00", docs: "https://zapier.com/mcp"),
        npx("gdrive", "Google Drive", "Work", "Search and read Docs, Sheets and files.", package: "@modelcontextprotocol/server-gdrive",
            logo: "gdrive.svg", symbol: "externaldrive", tint: "#1FA463", docs: archived + "gdrive"),
        // Code
        ConnectorPreset(id: "github", name: "GitHub", category: "Code", blurb: "Repos, issues, pull requests and code search.",
                        kind: .http, url: "https://api.githubcopilot.com/mcp/", command: nil,
                        token: .init("GITHUB_PERSONAL_ACCESS_TOKEN", "Personal access token",
                                     help: "github.com › Settings › Developer settings › Personal access tokens."),
                        logo: "github.svg", symbol: "chevron.left.forwardslash.chevron.right", tint: "#24292F",
                        docsURL: "https://github.com/github/github-mcp-server"),
        uvx("git", "Git", "Code", "Read history, diffs and branches in local repos.", package: "mcp-server-git",
            logo: "git.svg", symbol: "arrow.triangle.branch", tint: "#F05032", docs: reference + "git"),
        remote("sentry", "Sentry", "Code", "Look into errors and performance issues.", url: "https://mcp.sentry.dev/mcp",
               logo: "sentry.svg", symbol: "exclamationmark.triangle", tint: "#362D59", docs: "https://docs.sentry.io/product/sentry-mcp/"),
        remote("vercel", "Vercel", "Code", "Deployments, logs and projects.", url: "https://mcp.vercel.com",
               logo: "vercel.svg", symbol: "triangle.fill", tint: "#000000", docs: "https://vercel.com/docs/mcp/vercel-mcp"),
        // The server reads SUPABASE_ACCESS_TOKEN from its environment, so the token never goes on the command line.
        npx("supabase", "Supabase", "Code", "Query and manage your Supabase projects.", package: "@supabase/mcp-server-supabase",
            secrets: [.init("SUPABASE_ACCESS_TOKEN", "Access token", help: "supabase.com › Account › Access tokens.")],
            logo: "supabase.svg", symbol: "bolt.fill", tint: "#3ECF8E", docs: "https://supabase.com/docs/guides/getting-started/mcp"),
        npx("context7", "Context7 docs", "Code", "Up-to-date docs for any library, right in the prompt.", package: "@upstash/context7-mcp",
            logo: "context7.png", symbol: "books.vertical", tint: "#0E9F6E", docs: "https://github.com/upstash/context7"),
        // Web & research
        npx("playwright", "Browser", "Web & research", "Open sites, click, type and read pages in a real browser.",
            package: "@playwright/mcp@latest",
            logo: "playwright.png", symbol: "safari", tint: "#2EAD33", docs: "https://github.com/microsoft/playwright-mcp"),
        uvx("fetch", "Web fetch", "Web & research", "Download any web page as clean text.", package: "mcp-server-fetch",
            logo: nil, symbol: "arrow.down.doc", tint: "#4F8EF7", docs: reference + "fetch"),
        npx("brave", "Brave Search", "Web & research", "Private web and local search.", package: "@modelcontextprotocol/server-brave-search",
            secrets: [.init("BRAVE_API_KEY", "API key", help: "brave.com/search/api")],
            logo: "brave.svg", symbol: "magnifyingglass", tint: "#FB542B", docs: archived + "brave-search"),
        npx("exa", "Exa", "Web & research", "AI-native web search and page contents.", package: "exa-mcp-server",
            secrets: [.init("EXA_API_KEY", "API key", help: "dashboard.exa.ai")],
            logo: "exa.png", symbol: "sparkle.magnifyingglass", tint: "#1F40ED", docs: "https://github.com/exa-labs/exa-mcp-server"),
        npx("tavily", "Tavily", "Web & research", "Search and extract for research agents.", package: "tavily-mcp",
            secrets: [.init("TAVILY_API_KEY", "API key", help: "app.tavily.com")],
            logo: "tavily.png", symbol: "text.magnifyingglass", tint: "#6C47FF", docs: "https://github.com/tavily-ai/tavily-mcp"),
        npx("firecrawl", "Firecrawl", "Web & research", "Crawl whole sites and scrape structured data.", package: "firecrawl-mcp",
            secrets: [.init("FIRECRAWL_API_KEY", "API key", help: "firecrawl.dev")],
            logo: "firecrawl.png", symbol: "flame", tint: "#FF6B00", docs: "https://github.com/firecrawl/firecrawl-mcp-server"),
        npx("maps", "Google Maps", "Web & research", "Places, directions and distances.", package: "@modelcontextprotocol/server-google-maps",
            secrets: [.init("GOOGLE_MAPS_API_KEY", "API key", help: "Google Cloud console › Maps APIs.")],
            logo: "maps.svg", symbol: "map", tint: "#34A853", docs: archived + "google-maps"),
        npx("apify", "Apify", "Web & research", "Run thousands of ready-made web scrapers.", package: "@apify/actors-mcp-server",
            secrets: [.init("APIFY_TOKEN", "API token", help: "console.apify.com › Integrations.")],
            logo: "apify.png", symbol: "ant", tint: "#97D700", docs: "https://github.com/apify/actors-mcp-server"),
        // Design
        remote("figma-desktop", "Figma (desktop)", "Design", "Read frames and design context from the Figma app.",
               url: "http://127.0.0.1:3845/mcp",
               logo: "figma.svg", symbol: "paintpalette", tint: "#A259FF",
               docs: "https://help.figma.com/hc/en-us/articles/32132100833559"),
        remote("figma", "Figma (cloud)", "Design", "Figma's hosted server for files and designs.", url: "https://mcp.figma.com/mcp",
               logo: "figma.svg", symbol: "square.on.circle", tint: "#F24E1E",
               docs: "https://help.figma.com/hc/en-us/articles/32132100833559"),
        remote("canva", "Canva", "Design", "Find and create Canva designs.", url: "https://mcp.canva.com/mcp",
               logo: "canva.png", symbol: "scribble.variable", tint: "#00C4CC", docs: "https://www.canva.dev/docs/connect/canva-mcp-server-setup/"),
        sse("webflow", "Webflow", "Design", "Edit CMS items and site content.", url: "https://mcp.webflow.com/sse",
            logo: "webflow.svg", symbol: "globe", tint: "#146EF5", docs: "https://developers.webflow.com/mcp/reference/overview"),
        // Data
        // The connection string holds a password, so it's a Keychain secret and reaches the server
        // through its environment; a tiny sh wrapper turns it into the argument the server expects.
        ConnectorPreset(id: "postgres", name: "PostgreSQL", category: "Data", blurb: "Read-only SQL on a Postgres database.",
                        kind: .stdio, url: nil, command: "sh",
                        args: ["-c", "exec npx -y @modelcontextprotocol/server-postgres \"$DATABASE_URL\""],
                        secrets: [.init("DATABASE_URL", "Connection string", help: "postgresql://user:pass@host:5432/db")],
                        logo: "postgres.svg", symbol: "cylinder.split.1x2", tint: "#336791", docsURL: archived + "postgres"),
        uvx("sqlite", "SQLite", "Data", "Query and update a local SQLite file.", package: "mcp-server-sqlite",
            args: ["--db-path", "${DB_PATH}"], settings: [.init("DB_PATH", "Database file", help: "Full path to a .db or .sqlite file.")],
            logo: "sqlite.svg", symbol: "tablecells", tint: "#003B57", docs: archived + "sqlite"),
        npx("airtable", "Airtable", "Data", "Read and write bases, tables and records.", package: "airtable-mcp-server",
            secrets: [.init("AIRTABLE_API_KEY", "Personal access token", help: "airtable.com/create/tokens")],
            logo: "airtable.svg", symbol: "square.grid.3x2", tint: "#FCB400", docs: "https://github.com/domdomegg/airtable-mcp-server"),
        // Payments & commerce
        remote("stripe", "Stripe", "Payments & commerce", "Customers, payments, invoices and products.", url: "https://mcp.stripe.com",
               logo: "stripe.svg", symbol: "creditcard", tint: "#635BFF", docs: "https://docs.stripe.com/mcp"),
        sse("paypal", "PayPal", "Payments & commerce", "Invoices, orders and transactions.", url: "https://mcp.paypal.com/sse",
            logo: "paypal.svg", symbol: "p.circle", tint: "#003087", docs: "https://developer.paypal.com/tools/mcp-server/"),
        sse("square", "Square", "Payments & commerce", "Payments, catalog and customers.", url: "https://mcp.squareup.com/sse",
            logo: "square.svg", symbol: "square", tint: "#3E4348", docs: "https://developer.squareup.com/docs/mcp"),
        npx("shopify-dev", "Shopify docs", "Payments & commerce", "Shopify API docs and schema help for builders.",
            package: "@shopify/dev-mcp",
            logo: "shopify.svg", symbol: "bag", tint: "#95BF47", docs: "https://shopify.dev/docs/apps/build/devmcp"),
        // Utilities
        npx("memory", "Long-term memory", "Utilities", "A knowledge graph the bot can remember things in.",
            package: "@modelcontextprotocol/server-memory",
            logo: nil, symbol: "brain", tint: "#8B74DC", docs: reference + "memory"),
        npx("thinking", "Step-by-step thinking", "Utilities", "Lets the bot plan and revise its thinking in steps.",
            package: "@modelcontextprotocol/server-sequential-thinking",
            logo: nil, symbol: "list.number", tint: "#4CC9A0", docs: reference + "sequentialthinking"),
        npx("filesystem", "Folder access", "Utilities", "Read and write files in a folder you choose.",
            package: "@modelcontextprotocol/server-filesystem", args: ["${FOLDER}"],
            settings: [.init("FOLDER", "Folder", help: "Full path to the folder bots may read and write.")],
            logo: nil, symbol: "folder", tint: "#E2B07A", docs: reference + "filesystem"),
        npx("desktop", "Desktop Commander", "Utilities", "Terminal, file search and edits across your Mac.",
            package: "@wonderwhy-er/desktop-commander",
            logo: nil, symbol: "terminal", tint: "#3D3A43", docs: "https://github.com/wonderwhy-er/DesktopCommanderMCP"),
        uvx("time", "Time zones", "Utilities", "Current time and conversions between zones.", package: "mcp-server-time",
            logo: nil, symbol: "clock", tint: "#FF7A59", docs: reference + "time"),
    ]

    public static func preset(_ id: String) -> ConnectorPreset? { all.first { $0.id == id } }

    /// Every logo file the presets use.
    public static var logoFiles: Set<String> { Set(all.compactMap(\.logo)) }
}

extension ConnectorStore {
    /// The installed connector made from this preset, if any.
    public func installed(_ preset: ConnectorPreset) -> Connector? { loadAll().first { $0.id == preset.id } }

    /// Adds the preset as a connector with id = preset id. Installing again refreshes its shape
    /// (url, command, args, secret names) and keeps the id, so Keychain values and the bots and
    /// groups using it stay connected. Secret values are stored with `storeSecrets`, never here.
    @discardableResult
    public func install(_ preset: ConnectorPreset, settings: [String: String] = [:]) throws -> Connector {
        let connector = try preset.connector(settings: settings)
        try update(connector)
        return connector
    }

    /// Puts the values the user typed for a preset's secrets (and token) into the secret store
    /// (the Keychain in the app). Empty values remove the stored secret.
    public static func storeSecrets(_ values: [String: String], for preset: ConnectorPreset, connector: Connector,
                                    in secrets: SecretStore) throws {
        for field in preset.secrets {
            guard let v = values[field.key] else { continue }
            try secrets.setSecret(v.isEmpty ? nil : v, for: connector.envAccount(field.key))
        }
        if let token = preset.token, let v = values[token.key] {
            try secrets.setSecret(v.isEmpty ? nil : v, for: connector.tokenAccount)
        }
    }
}
