import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Places that hold credentials, which a bot never needs to read: connectors and your sign-ins are already set up for the
/// tools a bot uses. The guard refuses them whatever the rules or Full freedom say (`GuardEngine.credentialReason`).
public enum CredentialFiles {
    /// Folders and files under your home folder. A path inside any of these is refused.
    public static let homeRelative: [String] = [
        // Keys and cloud sign-ins.
        ".ssh", ".gnupg", ".aws", ".azure", ".config/gcloud", ".oci", ".kube", ".config/doctl", ".config/op", ".config/rclone",
        // Git's own config (token URLs, credential helpers, hooks), loose environment files, and shell history (pasted keys).
        ".gitconfig", ".config/git", ".env", ".zsh_history", ".bash_history", ".zsh_sessions",
        // Code hosting and package registries.
        ".config/gh", ".config/hub", ".git-credentials", ".config/git/credentials", ".netrc", ".npmrc", ".pypirc",
        ".cargo/credentials", ".cargo/credentials.toml", ".gem/credentials", ".docker/config.json", ".terraform.d/credentials.tfrc.json",
        // The AI tools' own sign-in and settings (the latter can hold connector tokens).
        ".claude/.credentials.json", ".claude.json", ".codex/auth.json", ".config/anthropic", ".openai",
        "Library/Application Support/Launchpad/codex-home/auth.json", "Library/Application Support/com.vercel.cli",
        "Library/Application Support/Claude",
        // Saved passwords, cookies and logins.
        "Library/Keychains", "Library/Cookies", "Library/Safari",
        "Library/Application Support/Google/Chrome", "Library/Application Support/Chromium", "Library/Application Support/BraveSoftware",
        "Library/Application Support/Microsoft Edge", "Library/Application Support/Vivaldi", "Library/Application Support/Arc",
        "Library/Application Support/Firefox", "Library/Application Support/Mozilla",
    ]

    /// Absolute paths for `home`.
    public static func roots(home: String) -> [String] {
        let base = home.hasSuffix("/") && home.count > 1 ? String(home.dropLast()) : home
        return homeRelative.map { base + "/" + $0 }
    }

    public static let reason = "That reaches a credentials file or the Keychain (SSH keys, cloud and GitHub sign-ins, browser data, saved passwords). A bot never needs them: connectors and the user's sign-ins are already set up for the tools it uses. If you really need something from there, ask the user. Don't try another way to read it."

    /// `security` (the Keychain tool) subcommands that print, export, unlock or change what's in a keychain.
    static let keychainSubcommands: Set<String> = [
        "find-generic-password", "find-internet-password", "find-key", "dump-keychain", "export", "import", "unlock-keychain",
        "set-key-partition-list", "add-trusted-cert",
    ]

    /// Commands that print a sign-in (a token, a key) out of the tool that holds it, so they never name the file.
    static let printingPatterns: [String] = [
        #"\bgh\s+auth\s+token\b"#, #"\bgh\s+auth\s+status\b.*(-t\b|--show-token)"#,
        #"\baws\s+configure\s+(get\s+\S*(secret|key|token)\S*|export-credentials)\b"#, #"\baws\s+sts\s+get-session-token\b"#,
        #"\bgcloud\s+auth\s+(application-default\s+)?print-(access|identity)-token\b"#,
        #"\bgit\b(\s+-\S+(\s+\S+)?)*\s+credential(-\S+)?(\s|$)"#, #"\bgit-credential-\S+"#,
        #"\bop\s+(read|signin|inject|run|item\s+get)\b"#, #"\bheroku\s+auth:token\b"#, #"\bfly(ctl)?\s+auth\s+token\b"#,
        #"\bkubectl\s+config\s+view\b.*--(raw|flatten)"#, #"\bnpm\s+config\s+get\s+\S*(token|auth|password)\S*"#,
        #"\bsupabase\s+projects\s+api-keys\b"#, #"\bstripe\s+config\s+--list\b"#,
    ]

    /// Commands that read every file under a folder they're given, so naming your home folder reaches the rest.
    static let recursiveReaders: Set<String> = ["rg", "ag", "ack", "cp", "rsync", "tar", "zip", "ditto", "scp", "7z", "7za", "gtar", "bsdtar"]
    static let recursiveFlag = #"^-[A-Za-z]*[rR][A-Za-z]*$|^--recursive$"#
}

extension GuardEngine {
    /// Why this tool call is refused for reaching a credentials location, or nil.
    /// - Shell: any word that is, or resolves into (following `~`, `$HOME`, `..`, links, globs, braces and `cd`), one of the
    ///   places in `config.credentialRoots`; the Keychain tool's printing commands; tools that print a sign-in; and
    ///   commands that read everything under a folder that holds them (your home folder, `/`).
    /// - File tools (Read, Write, Edit, MultiEdit, NotebookEdit, Grep, Glob): their path.
    ///
    /// Friction, not a boundary: a script file that opens one of these, or an encoding trick, isn't seen.
    public static func credentialReason(tool: String, input: [String: Any], cwd: String, config: GuardConfig) -> String? {
        guard !config.credentialRoots.isEmpty else { return nil }
        if tool == "Bash", let command = input["command"] as? String {
            return credentialShellReason(command, cwd: cwd, config: config)
        }
        let keys: [String: [String]] = ["Read": ["file_path"], "Write": ["file_path"], "Edit": ["file_path"], "MultiEdit": ["file_path"],
                                        "NotebookEdit": ["notebook_path"], "NotebookRead": ["notebook_path"],
                                        "Grep": ["path"], "Glob": ["path", "pattern"]]
        for key in keys[tool] ?? [] {
            if let value = input[key] as? String, touchesCredentials(value, cwd: cwd, config: config) { return CredentialFiles.reason }
        }
        return nil
    }

    /// Whether one path or glob is, or is inside, a credentials location.
    static func touchesCredentials(_ raw: String, cwd: String, config: GuardConfig) -> Bool {
        guard !raw.isEmpty else { return false }
        for variant in expandBraces(raw) {
            let path = ShellPath.resolve(variant, cwd: cwd, home: config.home)
            let glob = variant.contains { "*?[".contains($0) }
            for root in config.credentialRoots {
                if ShellPath.inside(path, root) { return true }
                if glob, globReaches(path, root) { return true }
            }
        }
        return false
    }

    /// `a{b,c}d` as `abd` and `acd` (one level, at most 16 results), so `~/.{ssh,aws}` is seen as both.
    static func expandBraces(_ s: String) -> [String] {
        guard let open = s.firstIndex(of: "{"), let close = s[open...].firstIndex(of: "}"), s[open..<close].contains(",") else { return [s] }
        let prefix = s[..<open], suffix = s[s.index(after: close)...]
        let options = s[s.index(after: open)..<close].split(separator: ",", omittingEmptySubsequences: false)
        return options.prefix(16).flatMap { expandBraces(prefix + String($0) + suffix) }.prefix(16).map { $0 }
    }

    /// Could this glob select `root` itself, or something inside it? Matched a folder at a time the way the shell does:
    /// a leading `*` or `?` never matches a name that starts with a dot, so `~/*` can't reach `~/.ssh` but `~/.s*` can.
    static func globReaches(_ pattern: String, _ root: String) -> Bool {
        let p = pattern.lowercased().split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let r = root.lowercased().split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard p.count >= r.count else { return false }
        for (pc, rc) in zip(p, r) where fnmatch(pc, rc, FNM_PERIOD) != 0 { return false }
        return true
    }

    static func credentialShellReason(_ command: String, cwd: String, config: GuardConfig) -> String? {
        let roots = config.credentialRoots
        // Commands that print a sign-in or a keychain item.
        if matches(command, CredentialFiles.printingPatterns) { return CredentialFiles.reason }

        for (c, cur) in ShellParser.walk(command, cwd: cwd) {
            guard let head = c.head else { continue }
            if head == "security", let sub = c.args.first(where: { !$0.hasPrefix("-") }), CredentialFiles.keychainSubcommands.contains(sub) {
                return CredentialFiles.reason
            }
            let here = cur ?? cwd
            let searches = ["rg", "ag", "ack", "grep", "egrep", "fgrep"].contains(head)
            let recursive = CredentialFiles.recursiveReaders.contains(head)
                || (["grep", "egrep", "fgrep"].contains(head) && c.args.contains { $0.range(of: CredentialFiles.recursiveFlag, options: .regularExpression) != nil })
                || (head == "find" && c.words.contains { ["-exec", "-execdir", "-ok", "-okdir"].contains($0) })
            for word in c.words.dropFirst() + c.inputs + c.outputs {
                // "--file=/x", "FOO=/x" and "a:/x" name a path after the = or :.
                for piece in word.components(separatedBy: CharacterSet(charactersIn: "=:")) where !piece.isEmpty && !piece.hasPrefix("-") {
                    let pathLike = piece.contains("/") || piece.hasPrefix("~") || piece.hasPrefix(".") || ShellPath.homeForm(piece)
                    guard pathLike else { continue }
                    if touchesCredentials(piece, cwd: here, config: config) { return CredentialFiles.reason }
                    if recursive {
                        // `grep -r … ~`, `cp -r ~ …`, `tar czf x ~`: everything under it, credentials included.
                        let resolved = ShellPath.resolve(piece, cwd: here, home: config.home)
                        if roots.contains(where: { ShellPath.inside($0, resolved) }) { return CredentialFiles.reason }
                    }
                }
            }
            // A search with no folder named looks in the folder the shell is in (`cd ~; rg token`).
            if recursive, searches {
                let operands = c.args.filter { !$0.hasPrefix("-") }
                if operands.count <= 1, roots.contains(where: { ShellPath.inside($0, here) }) { return CredentialFiles.reason }
            }
        }
        return credentialTextReason(command, cwd: cwd, config: config)
    }

    /// The same places, found in the text of a command: through variables, quotes, here-documents and inline code that the
    /// word-by-word check can't follow (`D=~/.ssh; cat $D/id_rsa`, `python3 -c "open('/Users/x/.ssh/id_rsa')"`).
    static func credentialTextReason(_ command: String, cwd: String, config: GuardConfig) -> String? {
        let text = normalized(command)
        var home = config.home.lowercased()
        while home.count > 1, home.hasSuffix("/") { home.removeLast() }
        let here = cwd.lowercased()
        for root in config.credentialRoots {
            let lower = root.lowercased()
            guard lower.hasPrefix(home + "/") else {
                if textMentions(text, lower) { return CredentialFiles.reason }
                continue
            }
            let rest = String(lower.dropFirst(home.count))   // "/.ssh"
            var forms = [lower, "~" + rest, "$home" + rest, "${home}" + rest]
            // Another variable standing in for the home folder: `$D/.ssh/id_rsa`, `${X}/.ssh`.
            let variable = #"\$\{?[a-z_][a-z0-9_]*\}?"# + NSRegularExpression.escapedPattern(for: rest) + #"(?![a-z0-9_.\-])"#
            if text.range(of: variable, options: .regularExpression) != nil { return CredentialFiles.reason }
            // Relative to where the command runs, when that's the home folder or inside it.
            if here == home || (here.hasPrefix(home + "/") && lower.hasPrefix(here + "/")) {
                forms.append(String(lower.dropFirst(here.count + 1)))
            }
            for form in forms where textMentions(text, form) { return CredentialFiles.reason }
        }
        return nil
    }

    /// `form` in `text`, not as the start of a longer name (`.ssh` but not `.sshd_config`).
    private static func textMentions(_ text: String, _ form: String) -> Bool {
        guard !form.isEmpty else { return false }
        var start = text.startIndex
        while let range = text.range(of: form, range: start..<text.endIndex) {
            let after = range.upperBound
            if after == text.endIndex { return true }
            let next = text[after]
            if !(next.isLetter || next.isNumber || next == "_" || next == "-" || next == ".") { return true }
            start = range.upperBound
        }
        return false
    }
}
