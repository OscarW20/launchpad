import Foundation

/// An MCP server. connectors.json holds the shape only; tokens and secret values live in the Keychain.
public struct Connector: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case http, stdio
    }

    public var id: String
    public var name: String
    public var kind: Kind
    public var url: String?
    public var command: String?
    public var args: [String]
    /// Environment variable names the server needs. Values are in the Keychain.
    public var secretEnv: [String]
    /// Sends a Bearer token from the Keychain (for http servers that use API keys).
    public var usesToken: Bool

    public init(id: String, name: String, kind: Kind, url: String? = nil, command: String? = nil,
                args: [String] = [], secretEnv: [String] = [], usesToken: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.url = url
        self.command = command
        self.args = args
        self.secretEnv = secretEnv
        self.usesToken = usesToken
    }

    enum CodingKeys: String, CodingKey { case id, name, kind, url, command, args, secretEnv, usesToken }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        url = try c.decodeIfPresent(String.self, forKey: .url)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? (url != nil ? .http : .stdio)
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        secretEnv = try c.decodeIfPresent([String].self, forKey: .secretEnv) ?? []
        usesToken = try c.decodeIfPresent(Bool.self, forKey: .usesToken) ?? false
    }

    /// Keychain account names for this connector's secrets.
    public var tokenAccount: String { "connector.\(id).token" }
    public func envAccount(_ name: String) -> String { "connector.\(id).env.\(name)" }

    /// Placeholder variable used to pass the token to the engine without writing it anywhere.
    public var tokenVariable: String { "LP_\(Self.envSafe(id))_TOKEN" }
    public func envVariable(_ name: String) -> String { "LP_\(Self.envSafe(id))_\(Self.envSafe(name))" }

    static func envSafe(_ s: String) -> String {
        String(s.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }

    /// The id as a TOML/JSON key both CLIs accept.
    public var serverKey: String { id.replacingOccurrences(of: "-", with: "_") }
}

public struct ConnectorsFile: Codable, Equatable {
    public var servers: [Connector]
    public init(servers: [Connector] = []) { self.servers = servers }
}

public final class ConnectorStore: @unchecked Sendable {
    public let paths: LaunchpadPaths

    public init(paths: LaunchpadPaths) {
        self.paths = paths
    }

    public func loadAll() -> [Connector] {
        guard let data = try? Data(contentsOf: paths.connectorsFile),
              let file = try? JSONCoding.decoder().decode(ConnectorsFile.self, from: data) else { return [] }
        return file.servers.filter { !$0.id.isEmpty }
    }

    public func saveAll(_ servers: [Connector]) throws {
        try paths.ensureStructure()
        try JSONCoding.encoder().encode(ConnectorsFile(servers: servers)).write(to: paths.connectorsFile, options: .atomic)
    }

    @discardableResult
    public func add(name: String, kind: Connector.Kind, url: String?, command: String?, args: [String]) throws -> Connector {
        var all = loadAll()
        let id = Slug.unique(name, taken: Set(all.map(\.id)))
        let c = Connector(id: id, name: name, kind: kind, url: url, command: command, args: args)
        all.append(c)
        try saveAll(all)
        return c
    }

    public func update(_ connector: Connector) throws {
        var all = loadAll()
        if let i = all.firstIndex(where: { $0.id == connector.id }) { all[i] = connector } else { all.append(connector) }
        try saveAll(all)
    }

    public func remove(id: String) throws {
        try saveAll(loadAll().filter { $0.id != id })
    }
}

/// What reading a secret found. `failed` (access denied, Keychain locked…) is not the same as `missing`:
/// the secret may still be there, so don't offer to replace it or tell the person it's gone.
public enum SecretRead: Equatable, Sendable {
    case found(String)
    case missing
    /// Why it couldn't be read, in plain words (never the secret itself).
    case failed(String)

    public var value: String? {
        if case .found(let v) = self { return v }
        return nil
    }
}

/// Where secrets live. The app uses the macOS Keychain; tests use memory.
public protocol SecretStore: AnyObject {
    func secret(_ account: String) -> String?
    func setSecret(_ value: String?, for account: String) throws
    /// Found, missing or failed. Stores that can't tell a failure apart get the default: found or missing.
    func read(_ account: String) -> SecretRead
}

extension SecretStore {
    public func read(_ account: String) -> SecretRead {
        guard let value = secret(account), !value.isEmpty else { return .missing }
        return .found(value)
    }
}

public final class MemorySecretStore: SecretStore {
    private var values: [String: String] = [:]
    /// Accounts that fail to read (for tests of the `failed` path).
    public var failing: [String: String] = [:]
    public init() {}
    public func secret(_ account: String) -> String? { read(account).value }
    public func setSecret(_ value: String?, for account: String) throws { values[account] = value }
    public func read(_ account: String) -> SecretRead {
        if let reason = failing[account] { return .failed(reason) }
        guard let v = values[account], !v.isEmpty else { return .missing }
        return .found(v)
    }
}

/// Builds MCP settings for each engine. Secrets are referenced by variable name and handed to the
/// engine process through its environment, never written to disk or put on the command line.
public enum MCPConfig {
    /// The connectors a bot gets: its own plus its groups'.
    public static func effective(for bot: Bot, groups: [BotGroup], all: [Connector]) -> [Connector] {
        var ids = bot.connectors
        for g in groups where g.members.contains(bot.id) || g.lead == bot.id { ids += g.connectors }
        let set = Set(ids)
        return all.filter { set.contains($0.id) }
    }

    /// JSON for `claude --mcp-config`. Uses `${VAR}` placeholders that Claude Code expands.
    public static func claudeJSON(_ connectors: [Connector]) -> String {
        var servers: [String: Any] = [:]
        for c in connectors {
            switch c.kind {
            case .http:
                var entry: [String: Any] = ["type": "http", "url": c.url ?? ""]
                if c.usesToken { entry["headers"] = ["Authorization": "Bearer ${\(c.tokenVariable)}"] }
                servers[c.serverKey] = entry
            case .stdio:
                var entry: [String: Any] = ["command": c.command ?? "", "args": c.args]
                if !c.secretEnv.isEmpty {
                    entry["env"] = Dictionary(uniqueKeysWithValues: c.secretEnv.map { ($0, "${\(c.envVariable($0))}") })
                }
                servers[c.serverKey] = entry
            }
        }
        let obj: [String: Any] = ["mcpServers": servers]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{\"mcpServers\":{}}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// `-c` overrides for `codex exec`.
    public static func codexArgs(_ connectors: [Connector]) -> [String] {
        var args: [String] = []
        for c in connectors {
            let key = "mcp_servers.\(c.serverKey)"
            switch c.kind {
            case .http:
                args += ["-c", "\(key).url=\(toml(c.url ?? ""))"]
                if c.usesToken { args += ["-c", "\(key).bearer_token_env_var=\(toml(c.tokenVariable))"] }
            case .stdio:
                args += ["-c", "\(key).command=\(toml(c.command ?? ""))"]
                args += ["-c", "\(key).args=[\(c.args.map(toml).joined(separator: ","))]"]
                if !c.secretEnv.isEmpty {
                    args += ["-c", "\(key).env_vars=[\(c.secretEnv.map(toml).joined(separator: ","))]"]
                }
            }
        }
        return args
    }

    /// Environment for the engine process, filled from the secret store.
    /// Claude reads the LP_* placeholders; Codex forwards the server's own variable names.
    public static func environment(_ connectors: [Connector], secrets: SecretStore, engine: BotEngine) -> [String: String] {
        var env: [String: String] = [:]
        for c in connectors {
            if c.usesToken, let token = secrets.secret(c.tokenAccount) { env[c.tokenVariable] = token }
            for name in c.secretEnv {
                guard let value = secrets.secret(c.envAccount(name)) else { continue }
                env[engine == .claude ? c.envVariable(name) : name] = value
            }
        }
        return env
    }

    static func toml(_ s: String) -> String {
        var out = "\""
        for ch in s {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            default: out.append(ch)
            }
        }
        return out + "\""
    }
}
