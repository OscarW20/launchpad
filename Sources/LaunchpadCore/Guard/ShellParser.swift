import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// One simple command of a shell line: its words (quotes and escapes removed) and where it redirects to.
public struct ShellCommand: Equatable, Sendable {
    public var words: [String]
    /// Files it writes with > >> &>.
    public var outputs: [String] = []
    /// Files it reads with <.
    public var inputs: [String] = []
    /// The command as written, for the approval card.
    public var raw: String
    /// The line has a here-document (<<), whose text isn't in the words.
    public var heredoc = false

    public init(words: [String], outputs: [String] = [], inputs: [String] = [], raw: String, heredoc: Bool = false) {
        self.words = words
        self.outputs = outputs
        self.inputs = inputs
        self.raw = raw
        self.heredoc = heredoc
    }

    /// The program's name ("/bin/rm" -> "rm").
    public var head: String? { words.first.map { ($0 as NSString).lastPathComponent } }
    public var args: ArraySlice<String> { words.dropFirst() }
}

/// Reads shell lines the way the shell would, well enough to see what each part does.
///
/// It isn't a full shell: it splits a line into simple commands, unwraps wrappers (env, sudo, xargs, bash -c…),
/// and follows cd. Anything it can't follow (a cd to a variable, say) is reported as unknown, so the guard
/// can treat it as risky instead of guessing.
public enum ShellParser {
    /// Folder-changing commands.
    public static let changesDirectory: Set<String> = ["cd", "pushd", "popd", "chdir"]

    /// Every simple command in a line, wrappers unwrapped, with the folder it runs in
    /// (nil once a cd goes somewhere we can't follow).
    public static func walk(_ command: String, cwd: String) -> [(ShellCommand, String?)] {
        var out: [(ShellCommand, String?)] = []
        var here: String? = cwd
        for c in parse(command).flatMap({ expand($0, depth: 0) }) {
            out.append((c, here))
            if let head = c.head, changesDirectory.contains(head) { here = here.flatMap { cdTarget(c, from: $0) } }
        }
        return out
    }

    /// Where a cd / pushd goes from `base`: nil if we can't tell (cd -, popd, a variable, a command's output).
    public static func cdTarget(_ c: ShellCommand, from base: String) -> String? {
        guard c.head != "popd" else { return nil }
        let args = c.args.filter { !$0.hasPrefix("-") || $0 == "-" }
        guard let to = args.first else { return ShellPath.resolve("~", cwd: base) }   // plain cd: home
        if to == "-" || (to.contains("$") && !ShellPath.homeForm(to)) || to.contains("`") { return nil }
        return ShellPath.resolve(to, cwd: base)
    }

    /// Wrappers and the options of theirs that take a value.
    static let wrappers: [String: Set<String>] = [
        "env": ["-u", "-S", "-P", "-C"], "nice": ["-n"], "timeout": ["-s", "-k", "--signal", "--kill-after"],
        "gtimeout": ["-s", "-k"], "sudo": ["-u", "-g", "-h", "-p", "-C", "-U", "-r", "-t", "-D", "-R"], "doas": ["-u", "-C"],
        "xargs": ["-I", "-J", "-L", "-n", "-P", "-R", "-S", "-s", "-E", "-d", "-a"], "caffeinate": ["-t", "-w"],
        "exec": ["-a"], "time": [], "nohup": [], "command": [], "builtin": [], "noglob": [], "stdbuf": ["-i", "-o", "-e"],
    ]
    static let keywords: Set<String> = ["then", "do", "else", "elif", "if", "while", "until", "{", "}", "!", "done", "fi", "esac"]
    static let shells: Set<String> = ["bash", "sh", "zsh", "dash", "ksh", "fish", "csh", "tcsh"]

    /// Unwraps env, nohup, sudo, xargs, time, then, do, eval, bash -c '…' and the like, down to the command that runs.
    public static func expand(_ command: ShellCommand, depth: Int) -> [ShellCommand] {
        var c = command
        var w = c.words
        while let first = w.first {
            let name = (first as NSString).lastPathComponent
            if keywords.contains(first) { w.removeFirst(); continue }
            // NAME=value before a command.
            if first.range(of: #"^[A-Za-z_][A-Za-z0-9_]*\+?="#, options: .regularExpression) != nil { w.removeFirst(); continue }
            if name == "eval" {
                guard depth < 6 else { break }
                return parse(w.dropFirst().joined(separator: " ")).flatMap { expand($0, depth: depth + 1) }
            }
            guard let takesValue = wrappers[name] else { break }
            w.removeFirst()
            var duration = name == "timeout" || name == "gtimeout"
            while let o = w.first {
                if o == "--" { w.removeFirst(); break }
                if o.hasPrefix("-") && o.count > 1 {
                    w.removeFirst()
                    if takesValue.contains(o), !w.isEmpty { w.removeFirst() }
                    continue
                }
                if name == "env", o.contains("=") { w.removeFirst(); continue }
                if name == "nice" || duration, o.range(of: #"^[0-9.]+[smhd]?$"#, options: .regularExpression) != nil {
                    w.removeFirst(); duration = false; continue
                }
                break
            }
        }
        // A command written with a backslash (\rm) is the same command.
        if let f = w.first, f.hasPrefix("\\") { w[0] = String(f.dropFirst()) }
        c.words = w
        // bash -c '…', sh -c "…", zsh -lc '…': the string is the command.
        if let head = c.head, shells.contains(head),
           let flag = c.args.firstIndex(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("c") }),
           flag + 1 < c.words.endIndex, depth < 6 {
            return parse(c.words[flag + 1]).flatMap { expand($0, depth: depth + 1) }
        }
        return [c]
    }

    /// Splits a shell line into simple commands at ; & && | || new lines and ( ), keeping quoted text together,
    /// removing quotes and backslash escapes, and pulling out what runs inside $( ) and backticks.
    /// Commands inside a substitution come before the command that uses them.
    public static func parse(_ line: String, depth: Int = 0) -> [ShellCommand] {
        let chars = Array(line)
        var out: [ShellCommand] = []
        var words: [String] = [], outputs: [String] = [], inputs: [String] = []
        var cur = "", inWord = false
        var redirect = 0   // 1: the next word is a file written to, 2: a file read from
        var rawStart = 0
        let heredoc = line.contains("<<")

        func endWord() {
            guard inWord else { return }
            switch redirect {
            case 1: outputs.append(cur)
            case 2: inputs.append(cur)
            default: words.append(cur)
            }
            redirect = 0
            cur = ""; inWord = false
        }
        func endCommand(_ at: Int) {
            endWord()
            if !words.isEmpty || !outputs.isEmpty || !inputs.isEmpty {
                let lo = min(rawStart, chars.count), hi = min(max(at, rawStart), chars.count)
                let raw = String(chars[lo..<hi]).trimmingCharacters(in: .whitespacesAndNewlines)
                out.append(ShellCommand(words: words, outputs: outputs, inputs: inputs, raw: raw, heredoc: heredoc))
            }
            words = []; outputs = []; inputs = []
            rawStart = at + 1
        }
        /// The text up to the matching ")", from just after "$(", and where that ")" is.
        func balanced(from start: Int) -> (String, Int) {
            var level = 1, j = start
            var quote: Character?
            while j < chars.count {
                let ch = chars[j]
                if let q = quote {
                    if ch == q { quote = nil } else if ch == "\\", q == "\"" { j += 1 }
                } else if ch == "'" || ch == "\"" { quote = ch }
                else if ch == "\\" { j += 1 }
                else if ch == "(" { level += 1 }
                else if ch == ")" { level -= 1; if level == 0 { return (String(chars[start..<j]), j) } }
                j += 1
            }
            return (start < chars.count ? String(chars[start...]) : "", chars.count)
        }
        func until(_ end: Character, from start: Int) -> (String, Int) {
            var j = start, text = ""
            while j < chars.count, chars[j] != end {
                if chars[j] == "\\", j + 1 < chars.count { text.append(chars[j + 1]); j += 2; continue }
                text.append(chars[j]); j += 1
            }
            return (text, j)
        }
        func substitute(_ inner: String) {
            if depth < 6 { out += parse(inner, depth: depth + 1) }
            cur += "$(…)"; inWord = true
        }

        var i = 0
        while i < chars.count {
            let ch = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            switch ch {
            case "\\":
                if let n = next, n != "\n" { cur.append(n); inWord = true }
                i += 2; continue
            case "'":
                var j = i + 1
                while j < chars.count, chars[j] != "'" { cur.append(chars[j]); j += 1 }
                inWord = true; i = j + 1; continue
            case "\"":
                var j = i + 1
                while j < chars.count, chars[j] != "\"" {
                    let c = chars[j]
                    if c == "\\", j + 1 < chars.count, "$`\"\\\n".contains(chars[j + 1]) { cur.append(chars[j + 1]); j += 2; continue }
                    if c == "$", j + 1 < chars.count, chars[j + 1] == "(" {
                        let (inner, end) = balanced(from: j + 2); substitute(inner); j = end + 1; continue
                    }
                    if c == "`" { let (inner, end) = until("`", from: j + 1); substitute(inner); j = end + 1; continue }
                    cur.append(c); j += 1
                }
                inWord = true; i = j + 1; continue
            case "`":
                let (inner, end) = until("`", from: i + 1); substitute(inner); i = end + 1; continue
            case "$" where next == "(":
                let (inner, end) = balanced(from: i + 2); substitute(inner); i = end + 1; continue
            case "$" where next == "{":
                let (inner, end) = until("}", from: i + 2); cur += "${" + inner + "}"; inWord = true; i = end + 1; continue
            case " ", "\t":
                endWord()
            case ";", "\n", "|", "(", ")":
                endCommand(i)
            case "&":
                if next == ">" {
                    endWord(); redirect = 1; i += 2
                    if i < chars.count, chars[i] == ">" { i += 1 }
                    continue
                }
                endCommand(i)
            case ">", "<":
                // "2>" and "2>&1": the digits are a file descriptor, not a word.
                if inWord, !cur.isEmpty, cur.allSatisfy(\.isNumber) { cur = ""; inWord = false }
                endWord()
                var j = i + 1
                while j < chars.count, chars[j] == ">" || chars[j] == "<" || chars[j] == "|" { j += 1 }
                if j < chars.count, chars[j] == "&" {
                    // >&2: another descriptor, not a file.
                    j += 1
                    while j < chars.count, chars[j].isNumber || chars[j] == "-" { j += 1 }
                    i = j; continue
                }
                if ch == "<", j < chars.count, chars[j] == "(" { i = j; continue }   // <( … ) runs a command
                redirect = ch == ">" ? 1 : 2
                i = j; continue
            default:
                cur.append(ch); inWord = true
            }
            i += 1
        }
        endCommand(chars.count)
        return out
    }
}

/// Paths the way the shell and the disk see them.
public enum ShellPath {
    /// "$HOME/…" or "${HOME}/…".
    public static func homeForm(_ t: String) -> Bool { t.hasPrefix("$HOME") || t.hasPrefix("${HOME}") }

    /// An absolute path for `raw` run from `cwd`: ~ and $HOME expanded, symlinks followed for the parts that
    /// exist (so "docs/../x" means what the shell means), /private/tmp, /private/var and /private/etc as /tmp, /var, /etc.
    public static func resolve(_ raw: String, cwd: String, home: String = NSHomeDirectory()) -> String {
        var p = raw
        if p == "~" || p.hasPrefix("~/") { p = home + p.dropFirst() }
        else if p.hasPrefix("${HOME}") { p = home + p.dropFirst(7) }
        else if p.hasPrefix("$HOME") { p = home + p.dropFirst(5) }
        if !p.hasPrefix("/") { p = (cwd.isEmpty ? "/" : cwd) + "/" + p }
        var path = "/"
        var real = true
        for c in p.split(separator: "/", omittingEmptySubsequences: true) {
            if c == "." { continue }
            if c == ".." {
                path = (path as NSString).deletingLastPathComponent
                if path.isEmpty { path = "/" }
                continue
            }
            let next = path == "/" ? "/" + c : path + "/" + c
            if real, let r = realpath(next, nil) {
                path = String(cString: r)
                free(r)
            } else {
                path = next
                real = false
            }
        }
        for alias in ["/private/tmp", "/private/var", "/private/etc"] where path == alias || path.hasPrefix(alias + "/") {
            path = String(path.dropFirst(8))
        }
        return path
    }

    /// Is `path` in `dir`? Case-insensitive (Mac disks are) and with symlinks followed.
    public static func inside(_ path: String, _ dir: String) -> Bool {
        let p = resolve(path, cwd: "/").lowercased(), d = resolve(dir, cwd: "/").lowercased()
        return d == "/" || p == d || p.hasPrefix(d + "/")
    }
}
