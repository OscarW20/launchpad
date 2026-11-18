import Foundation

/// The environment a bot's engine process starts with.
///
/// A bot's shell commands inherit the engine's environment, and whatever a command prints goes back to the model.
/// So the engine gets a short list of what it needs (a PATH, your home folder, your language, your network setup and
/// its own sign-in settings) instead of a copy of Launchpad's whole environment, in which anything set in your shell
/// when Launchpad started (an `AWS_SECRET_ACCESS_KEY`, a `GITHUB_TOKEN`) would reach every bot.
///
/// What this does not do: connector tokens still have to reach the engine's process (`MCPConfig.environment`), so
/// they are readable by that bot's own shell. The guard makes that harder (`GuardEngine.environmentReadReason`), but a
/// block-list is friction, not a boundary. The boundary is not giving the engine the token at all.
public enum EngineEnvironment {
    /// Variables passed from Launchpad's environment to every engine: none of these is a secret.
    public static let names: Set<String> = [
        "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "TERM", "COLORTERM", "TZ", "LANG", "LANGUAGE", "NO_COLOR",
        // macOS: the login session (the Keychain needs it) and the text encoding.
        "SECURITYSESSIONID", "__CF_USER_TEXT_ENCODING", "DEVELOPER_DIR",
        // Where tools keep their settings, if you moved them.
        "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME",
        // Lets git over ssh use your agent. It allows using your keys, not reading them.
        "SSH_AUTH_SOCK",
        // Your network setup: a proxy and certificate files, so the engine can still get online.
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy",
        "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE",
    ]

    /// Locale settings (LC_ALL, LC_CTYPE…).
    public static let prefixes = ["LC_"]

    /// The engine's own settings, including an API key if you sign in that way. They stay readable by that engine's
    /// shell commands, so signing in with the app (no key in the environment) is the safer way to use it.
    public static func enginePrefixes(_ engine: BotEngine) -> [String] {
        switch engine {
        case .claude: return ["CLAUDE_", "ANTHROPIC_"]
        case .codex: return ["CODEX_", "OPENAI_"]
        case .local: return []
        }
    }

    /// What passes from `base` (Launchpad's environment) to an engine.
    public static func filtered(_ base: [String: String], engine: BotEngine) -> [String: String] {
        let engineOwn = enginePrefixes(engine)
        return base.filter { name, _ in
            names.contains(name) || prefixes.contains { name.hasPrefix($0) } || engineOwn.contains { name.hasPrefix($0) }
        }
    }

    /// The environment for an engine process: the allowed part of `base`, plus `extra` (what Launchpad chose to give
    /// this run: connector secrets, its own settings), which wins.
    public static func build(base: [String: String], extra: [String: String], engine: BotEngine) -> [String: String] {
        filtered(base, engine: engine).merging(extra) { _, new in new }
    }

    /// Whether a variable's name says it holds a secret: TOKEN, SECRET, PASSWORD, API_KEY, a trailing _KEY, and
    /// Launchpad's own LP_ variables. By name only, so it can be applied to a command without knowing any value.
    public static func looksSecret(_ name: String) -> Bool {
        let upper = name.uppercased()
        if upper.hasPrefix("LP_") { return true }
        let parts = upper.split(separator: "_").map(String.init)
        // A whole word between underscores, so API_KEY, PRIVATE_KEY and STRIPE_KEY count but KEYBOARD doesn't, and
        // neither does AUTH on its own (GIT_AUTHOR_NAME, SSH_AUTH_SOCK are not secrets; AUTH_TOKEN is, by "TOKEN").
        let words: Set<String> = ["TOKEN", "TOKENS", "SECRET", "SECRETS", "PASSWORD", "PASSWD", "PASSPHRASE", "CREDENTIAL",
                                  "CREDENTIALS", "BEARER", "COOKIE", "COOKIES", "APIKEY", "KEY", "KEYS"]
        return parts.contains { words.contains($0) }
    }
}
