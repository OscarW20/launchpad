import Foundation

/// A bot's MEMORY.md as topics: parse it, merge new facts in without duplicates, keep its growth under a size cap,
/// and keep secrets out. Pure functions, so they're easy to test (Tests/LaunchpadCoreTests/MemoryTests.swift).
public enum MemoryBook {
    /// The headings a background review files facts under, in the order they appear in the file.
    public static let topics = ["Preferences", "Decisions", "People", "Projects", "How I work"]
    /// Where a fact goes when the model names a topic we don't know.
    public static let fallbackTopic = "Notes"
    /// A review never grows MEMORY.md past this size. Bots read it at the start of every job, so it has to stay small.
    public static let sizeCap = 12 * 1024

    public struct Fact: Codable, Hashable, Sendable {
        public var topic: String
        public var text: String
        public init(topic: String, text: String) { self.topic = topic; self.text = text }
    }

    /// Several old lines the model folded into one summary (only asked for when memory is nearly full).
    public struct Condense: Codable, Hashable, Sendable {
        public var topic: String
        public var replaces: [String]
        public var text: String
        public init(topic: String, replaces: [String], text: String) { self.topic = topic; self.replaces = replaces; self.text = text }
    }

    // MARK: Reading the file

    public enum ReadResult: Equatable, Sendable {
        /// No MEMORY.md yet: same as empty.
        case missing
        case text(String)
        /// It exists but isn't UTF-8 (or UTF-16 with a byte-order mark). Never write over it.
        case unreadable

        /// The text to work from, or nil when the file mustn't be touched.
        public var usable: String? {
            switch self {
            case .missing: return ""
            case .text(let t): return t
            case .unreadable: return nil
            }
        }
    }

    /// Reads MEMORY.md without ever mistaking a file we can't decode for an empty one.
    public static func read(_ url: URL) -> ReadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        return decode(data).map { .text($0) } ?? .unreadable
    }

    public static func decode(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(2))
        if bytes.count == 2, (bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF) {
            return String(data: data, encoding: .utf16).map(stripBOM)
        }
        return String(data: data, encoding: .utf8).map(stripBOM)
    }

    public static func stripBOM(_ s: String) -> String { s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s }

    // MARK: Document

    public struct Section: Hashable, Sendable {
        /// The heading line as written ("## Preferences"), or nil for text above the first heading.
        public var heading: String?
        public var lines: [String]

        public var title: String? {
            heading.map { $0.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) }
        }
        /// Indexes of the lines that hold something (not blank).
        public var entryIndexes: [Int] { lines.indices.filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty } }

        /// One of the topics a background review files facts under (or Notes).
        public var isReviewTopic: Bool {
            guard let t = title else { return false }
            return (MemoryBook.topics + [MemoryBook.fallbackTopic]).contains { $0.caseInsensitiveCompare(t) == .orderedSame }
        }
    }

    public struct Doc: Hashable, Sendable {
        public var sections: [Section]

        public init(_ text: String) {
            var out = [Section(heading: nil, lines: [])]
            let unified = MemoryBook.stripBOM(text).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            for raw in unified.components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("## ") || line.hasPrefix("### ") {
                    out.append(Section(heading: line, lines: []))
                } else {
                    out[out.count - 1].lines.append(raw)
                }
            }
            sections = out
        }

        public var text: String {
            var blocks: [String] = []
            for s in sections {
                var lines = s.lines
                while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
                while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
                if let heading = s.heading {
                    blocks.append(([heading] + lines).joined(separator: "\n"))
                } else if !lines.isEmpty {
                    blocks.append(lines.joined(separator: "\n"))
                }
            }
            return blocks.isEmpty ? "" : blocks.joined(separator: "\n\n") + "\n"
        }

        public func sectionIndex(_ topic: String) -> Int? {
            sections.firstIndex { $0.title?.caseInsensitiveCompare(topic) == .orderedSame }
        }

        /// Every entry in the file, for duplicate checks.
        public var allEntries: [String] { sections.flatMap { s in s.entryIndexes.map { MemoryBook.entryText(s.lines[$0]) } } }

        /// Adds a topic section in the usual order (Preferences, Decisions, People, Projects, How I work, Notes).
        /// Any other title (one of your own headings, coming back after an undo) goes at the end.
        public mutating func ensureSection(_ topic: String, heading: String? = nil) -> Int {
            if let i = sectionIndex(topic) { return i }
            let order = MemoryBook.topics + [MemoryBook.fallbackTopic]
            guard let rank = order.firstIndex(where: { $0.caseInsensitiveCompare(topic) == .orderedSame }) else {
                sections.append(Section(heading: heading ?? "## \(topic)", lines: []))
                return sections.count - 1
            }
            // After the last known topic section that comes before this one; else after the intro text.
            var insertAt = 1
            for (i, s) in sections.enumerated() {
                guard let t = s.title, let r = order.firstIndex(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) else { continue }
                if r < rank { insertAt = i + 1 }
            }
            if insertAt == 1, let firstTopic = sections.indices.dropFirst().first(where: { i in
                order.contains { $0.caseInsensitiveCompare(sections[i].title ?? "") == .orderedSame }
            }) { insertAt = firstTopic }
            sections.insert(Section(heading: heading ?? "## \(topic)", lines: []), at: min(insertAt, sections.count))
            return min(insertAt, sections.count - 1)
        }

        public mutating func append(_ entry: String, to topic: String) {
            let i = ensureSection(topic)
            while sections[i].lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { sections[i].lines.removeLast() }
            sections[i].lines.append("- " + entry)
        }
    }

    /// A line's text without its bullet.
    public static func entryText(_ line: String) -> String {
        var t = line.trimmingCharacters(in: .whitespaces)
        for bullet in ["- [ ] ", "- [x] ", "- ", "* ", "• "] where t.hasPrefix(bullet) { t = String(t.dropFirst(bullet.count)); break }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Keeps a line's bullet and swaps its text.
    public static func replacingEntryText(_ line: String, with text: String) -> String {
        let t = line.trimmingCharacters(in: .whitespaces)
        for bullet in ["- [ ] ", "- [x] ", "- ", "* ", "• "] where t.hasPrefix(bullet) { return bullet + text }
        return text
    }

    // MARK: Editing one line

    public struct LinePosition: Hashable, Sendable { public var section: Int; public var line: Int; public init(section: Int, line: Int) { self.section = section; self.line = line } }

    /// Edits (or, with an empty value, removes) one line and tidies the text. Also says where another line
    /// (`follow`) ends up afterwards, so the editor opens the line you actually clicked next (nil if it's gone).
    public static func editLine(_ text: String, at pos: LinePosition, to value: String,
                         follow: LinePosition? = nil) -> (text: String, followed: LinePosition?) {
        var d = Doc(text)
        guard d.sections.indices.contains(pos.section), d.sections[pos.section].lines.indices.contains(pos.line) else {
            return (text, follow)
        }
        var followed = follow
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        if value.isEmpty {
            d.sections[pos.section].lines.remove(at: pos.line)
            if let f = followed, f.section == pos.section {
                if f.line == pos.line { followed = nil } else if f.line > pos.line { followed?.line -= 1 }
            }
        } else {
            d.sections[pos.section].lines[pos.line] = replacingEntryText(d.sections[pos.section].lines[pos.line], with: value)
        }
        // Doc.text drops blank lines at the top of each section: shift the followed line by as many.
        if let f = followed {
            guard d.sections.indices.contains(f.section), d.sections[f.section].lines.indices.contains(f.line) else { return (d.text, nil) }
            let lead = d.sections[f.section].lines.prefix { $0.trimmingCharacters(in: .whitespaces).isEmpty }.count
            followed = f.line >= lead ? LinePosition(section: f.section, line: f.line - lead) : nil
        }
        return (d.text, followed)
    }

    // MARK: Topics

    /// The topic heading a model's label belongs under.
    public static func canonicalTopic(_ raw: String) -> String {
        let t = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if let exact = topics.first(where: { $0.lowercased() == t }) { return exact }
        if t.hasPrefix("pref") || t.contains("like") || t.contains("taste") || t.contains("style") { return "Preferences" }
        if t.hasPrefix("decision") || t.contains("decided") || t.contains("choice") { return "Decisions" }
        if t.hasPrefix("people") || t.hasPrefix("person") || t.contains("contact") || t.contains("team") { return "People" }
        if t.hasPrefix("project") || t.contains("work in progress") || t.contains("goal") { return "Projects" }
        if t.contains("how i work") || t.contains("workflow") || t.contains("habit") || t.contains("process") || t.contains("routine") { return "How I work" }
        return fallbackTopic
    }

    // MARK: Duplicates

    private static let nonWord = CharacterSet.alphanumerics.inverted

    public static func normalized(_ s: String) -> String {
        let lowered = s.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
        return lowered.components(separatedBy: nonWord).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static let stopWords: Set<String> = ["the", "a", "an", "and", "or", "to", "of", "in", "on", "for", "with", "is", "are", "be",
                                                 "user", "they", "their", "them", "i", "my", "me", "likes", "prefers", "wants", "uses"]

    private static func words(normalized n: String) -> Set<String> {
        Set(n.split(separator: " ").map(String.init).filter { !stopWords.contains($0) })
    }

    /// Same fact in different words: identical once normalised, or nearly the same set of words.
    public static func isDuplicate(_ a: String, _ b: String) -> Bool {
        let na = normalized(a), nb = normalized(b)
        return isDuplicate(na, words(normalized: na), nb, words(normalized: nb))
    }

    private static func isDuplicate(_ na: String, _ wa: Set<String>, _ nb: String, _ wb: Set<String>) -> Bool {
        if na.isEmpty || nb.isEmpty { return na == nb }
        if na == nb { return true }
        guard !wa.isEmpty, !wb.isEmpty else { return false }
        let overlap = Double(wa.intersection(wb).count) / Double(wa.union(wb).count)
        return overlap >= 0.75
    }

    /// The new line says everything the old one did and more ("Prefers British spelling" → "… in all documents").
    public static func extends(_ new: String, _ old: String) -> Bool {
        extends(normalized: normalized(new), normalized(old))
    }

    private static func extends(normalized nn: String, _ no: String) -> Bool {
        nn.count > no.count && no.split(separator: " ").count >= 2 && (" " + nn + " ").contains(" " + no + " ")
    }

    // MARK: Secrets

    private static let secretPatterns: [NSRegularExpression] = [
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)"#,
        #"\bsk-[A-Za-z0-9_\-]{16,}"#,                       // OpenAI, Anthropic (sk-ant-…)
        #"\bgh[pousr]_[A-Za-z0-9]{20,}"#,                   // GitHub tokens
        #"\bgithub_pat_[A-Za-z0-9_]{20,}"#,
        #"\bglpat-[A-Za-z0-9_\-]{20,}"#,                    // GitLab
        #"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#,                // Slack
        #"(?i)https?://hooks\.slack\.com/services/[A-Za-z0-9/_\-]+"#,   // Slack webhooks
        #"\bAKIA[0-9A-Z]{16}\b"#,                            // AWS access key id
        #"\bAIza[0-9A-Za-z_\-]{30,}"#,                       // Google API key
        #"\bya29\.[A-Za-z0-9_\-]{20,}"#,                     // Google OAuth access token
        #"\b(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{16,}"#,   // Stripe
        #"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#,   // JWT
        #"(?i)\bbearer\s+[A-Za-z0-9._\-]{16,}"#,
        #"(?i)\b[a-z][a-z0-9+.\-]*://[^\s/:@]+:[^\s/@]+@"#,  // passwords inside URLs
        #"\b(?:\d[ \-]?){13,19}\b"#,                         // card numbers
    ].map { try! NSRegularExpression(pattern: $0) }

    /// "password: hunter2", "my password is: hunter2", "the wifi password for the office is hunter2",
    /// "API key is abc123", "my PIN = 1234", "pw - hunter2", "Password = "correct horse"". Only the value is replaced.
    private static let labelledSecret = try! NSRegularExpression(pattern:
        #"(?i)\b(?:password|passwd|passcode|passphrase|pwd|pw|pin|secret|token|api[ _\-]?key|access[ _\-]?key|private[ _\-]?key|client[ _\-]?secret|2fa code|otp|recovery code)s?\b"#
        + #"(?:\s+(?!(?:is|are|was|were)\b)[\p{L}\p{N}'’]+){0,4}?"#      // up to four words in between ("for the office")
        + #"(?:\s*(?:(?:is|are|was|were)\b\s*:?|:|=)\s*|\s+[-–—]\s+)"#
        + #"(?<value>"[^"]*"|'[^']*'|“[^”]*”|[^\s,;]+(?:\s+(?:and|&)\s+[^\s,;]+)*)"#)

    /// "Login: sam / Hunter2!", "credentials are sam:hunter2": everything to the end of the clause.
    private static let loginSecret = try! NSRegularExpression(pattern:
        #"(?i)\b(?:login|log-in|credentials|creds)\b\s*(?:(?:is|are|was|were)\b\s*:?|:|=)\s*(?<value>[^\n,;]+)"#)

    /// Long opaque strings with letters and digits mixed (keys and tokens no pattern above knows).
    private static let opaque = try! NSRegularExpression(pattern: #"\b[A-Za-z0-9_\-]{32,}\b"#)
    /// Base64 secrets with + / = in them (AWS secret keys and the like), which `opaque` only sees as short pieces.
    private static let base64 = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9+/=_.:\-])[A-Za-z0-9+/]{30,}={0,2}(?![A-Za-z0-9+/=_\-])"#)

    /// Replaces anything that looks like a secret with [redacted].
    public static func redact(_ text: String) -> String {
        var out = text
        for re in secretPatterns {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "[redacted]")
        }
        for re in [labelledSecret, loginSecret] {
            let ns = out as NSString
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
                let r = m.range(withName: "value")
                guard r.location != NSNotFound else { continue }
                out = (out as NSString).replacingCharacters(in: r, with: "[redacted]")
            }
        }
        out = replaceMatches(base64, in: out) { s in
            let mixed = s.rangeOfCharacter(from: .decimalDigits) != nil && s.rangeOfCharacter(from: .uppercaseLetters) != nil
                && s.rangeOfCharacter(from: .lowercaseLetters) != nil
            return mixed && !s.hasPrefix("/") && (s.contains("+") || s.hasSuffix("=") || (s.count == 40 && s.contains("/")))
        }
        out = replaceMatches(opaque, in: out) { s in
            s.rangeOfCharacter(from: .decimalDigits) != nil && s.rangeOfCharacter(from: .letters) != nil
        }
        return out
    }

    private static func replaceMatches(_ re: NSRegularExpression, in text: String, when test: (String) -> Bool) -> String {
        var out = text
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() where test(ns.substring(with: m.range)) {
            out = (out as NSString).replacingCharacters(in: m.range, with: "[redacted]")
        }
        return out
    }

    /// True when a line holds (or points at) a secret. Such lines are never written to memory.
    public static func containsSecret(_ text: String) -> Bool {
        redact(text) != text || text.contains("[redacted]")
    }

    // MARK: Merge

    public struct MergeResult: Equatable, Sendable {
        public var text: String
        /// What was added or updated, for the "Memory updated" note.
        public var added: [String]
        public var changed: Bool
        public init(text: String, added: [String], changed: Bool) { self.text = text; self.added = added; self.changed = changed }
    }

    /// Files new facts under their topics. Duplicates are skipped, a fact that extends an old one replaces it,
    /// anything that looks like a secret is dropped, and the update never grows the file past `limit` bytes
    /// (a file that was already bigger is never made smaller than it was). Your intro text is never touched.
    public static func merge(_ text: String, facts: [Fact], condense: [Condense] = [], limit: Int = sizeCap) -> MergeResult {
        var doc = Doc(text)
        let tidied = doc.text
        var added: [String] = []

        // 1. Summaries the model wrote for old lines (only when they really replace two or more lines; never in the intro).
        for c in condense {
            let summary = clean(c.text)
            guard !summary.isEmpty, !containsSecret(summary) else { continue }
            let targets = Set(c.replaces.map(normalized))
            for si in doc.sections.indices.dropFirst() {
                let hits = doc.sections[si].entryIndexes.filter { targets.contains(normalized(entryText(doc.sections[si].lines[$0]))) }
                guard hits.count >= 2 else { continue }
                let first = hits[0]
                for i in hits.reversed() { doc.sections[si].lines.remove(at: i) }
                doc.sections[si].lines.insert("- " + summary, at: min(first, doc.sections[si].lines.count))
            }
        }

        // 2. New facts. Every old line is normalised once (a big file has thousands).
        struct Known { var si: Int; var li: Int; var norm: String; var words: Set<String> }
        func index() -> [Known] {
            doc.sections.indices.flatMap { si in
                doc.sections[si].entryIndexes.map { li -> Known in
                    let n = normalized(entryText(doc.sections[si].lines[li]))
                    return Known(si: si, li: li, norm: n, words: words(normalized: n))
                }
            }
        }
        var known = index()
        for fact in facts {
            let entry = clean(fact.text)
            guard entry.count >= 3, !containsSecret(entry) else { continue }
            let topic = canonicalTopic(fact.topic)
            let ne = normalized(entry), we = words(normalized: ne)
            var handled = false
            for k in known.indices {
                if isDuplicate(ne, we, known[k].norm, known[k].words) { handled = true; break }
                // Extending rewrites the old line, so it never reaches into your intro text.
                if known[k].si > 0, extends(normalized: ne, known[k].norm) {
                    let (si, li) = (known[k].si, known[k].li)
                    doc.sections[si].lines[li] = replacingEntryText(doc.sections[si].lines[li], with: entry)
                    known[k].norm = ne; known[k].words = we
                    added.append(entry); handled = true; break
                }
            }
            if !handled {
                let sectionCount = doc.sections.count
                doc.append(entry, to: topic)
                if doc.sections.count != sectionCount {
                    known = index()   // a new heading moved the sections after it (at most once per topic)
                } else if let si = doc.sectionIndex(topic) {
                    known.append(Known(si: si, li: doc.sections[si].lines.count - 1, norm: ne, words: we))
                }
                added.append(entry)
            }
        }

        // 3. Only the update's own growth is capped: never below what the file already held.
        let capped = cap(doc.text, limit: max(limit, tidied.utf8.count))
        // Compared with the file as this parser writes it, so tidied blank lines alone don't count as a change.
        return MergeResult(text: capped, added: added, changed: capped != tidied)
    }

    /// One line, no bullet, no Markdown heading, at most 280 characters.
    public static func clean(_ raw: String) -> String {
        var t = entryText(raw.replacingOccurrences(of: "\n", with: " "))
        while t.hasPrefix("#") { t.removeFirst() }
        t = t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if t.count > 280 { t = String(t.prefix(279)).trimmingCharacters(in: .whitespaces) + "…" }
        return t
    }

    // MARK: Size cap

    public static let earlierPrefix = "Earlier: "

    /// Keeps memory under `limit` bytes. Only the review's own topics (Preferences, Decisions, People, Projects,
    /// How I work, Notes) are ever shortened: the oldest lines in the biggest of them are folded into one short
    /// "Earlier: …" line; if that doesn't save room, the oldest line goes. Your intro text and your own headings
    /// are never touched, so a file that's big because of them stays as it is.
    public static func cap(_ text: String, limit: Int = sizeCap) -> String {
        guard text.utf8.count > limit else { return text }
        var doc = Doc(text)
        var total = doc.text.utf8.count
        guard total > limit else { return doc.text }
        var sizes = doc.sections.map(size)
        // Lines before this index in a section are already folded or blank: the scan for fresh lines starts here.
        var cursor = [Int](repeating: 0, count: doc.sections.count)
        let reviewable = doc.sections.indices.filter { doc.sections[$0].isReviewTopic }
        var emptied = Set<Int>()

        while true {
            while total > limit {
                guard let si = reviewable.filter({ !emptied.contains($0) }).max(by: { sizes[$0] < sizes[$1] }) else { break }
                var lines = doc.sections[si].lines
                // The four oldest lines not folded yet.
                var oldest: [Int] = []
                var i = cursor[si]
                while i < lines.count, oldest.count < 4 {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty, !entryText(t).hasPrefix(earlierPrefix) { oldest.append(i) }
                    else if oldest.isEmpty { cursor[si] = i + 1 }
                    i += 1
                }
                if oldest.count == 4 {
                    let parts = oldest.map { shorten(entryText(lines[$0]), to: 60) }
                    let folded = "- " + earlierPrefix + parts.joined(separator: "; ")
                    let before = oldest.reduce(0) { $0 + lines[$1].utf8.count + 1 }
                    if folded.utf8.count + 1 < before {
                        for j in oldest.reversed() { lines.remove(at: j) }
                        lines.insert(folded, at: min(oldest[0], lines.count))
                        cursor[si] = oldest[0] + 1
                        doc.sections[si].lines = lines
                        sizes[si] += folded.utf8.count + 1 - before
                        total += folded.utf8.count + 1 - before
                        continue
                    }
                }
                // Nothing worth folding: the oldest line in this section goes.
                guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
                    emptied.insert(si); continue
                }
                let gone = lines.remove(at: first).utf8.count + 1
                if first < cursor[si] { cursor[si] -= 1 }
                doc.sections[si].lines = lines
                sizes[si] -= gone
                total -= gone
                if !lines.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) { emptied.insert(si) }
            }
            // The running total is an estimate (blank lines are tidied on output): measure the real size.
            var d = doc
            for si in emptied.sorted(by: >) where d.sections[si].entryIndexes.isEmpty { d.sections.remove(at: si) }
            let real = d.text.utf8.count
            if real <= limit || real == total || reviewable.allSatisfy({ emptied.contains($0) }) { return d.text }
            total = real
        }
    }

    private static func size(_ s: Section) -> Int { s.lines.reduce(0) { $0 + $1.utf8.count + 1 } }

    /// The first clause of a line, cut at a word boundary.
    public static func shorten(_ s: String, to max: Int) -> String {
        var t = s
        if let cut = t.firstIndex(where: { ".;(".contains($0) }), t.distance(from: t.startIndex, to: cut) >= 12 { t = String(t[..<cut]) }
        guard t.count > max else { return t.trimmingCharacters(in: .whitespaces) }
        let head = String(t.prefix(max))
        let atWord = head.lastIndex(of: " ").map { String(head[..<$0]) } ?? head
        return atWord.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) + "…"
    }

    // MARK: Carrying a change across versions

    private struct Entry { var section: Int; var line: Int; var key: String }

    private static func key(_ line: String) -> String {
        let n = normalized(entryText(line))
        return n.isEmpty ? line.trimmingCharacters(in: .whitespaces) : n
    }

    private static func entries(_ d: Doc) -> [Entry] {
        d.sections.indices.flatMap { si in d.sections[si].entryIndexes.map { Entry(section: si, line: $0, key: key(d.sections[si].lines[$0])) } }
    }

    private static func counts(_ list: [Entry]) -> [String: Int] {
        var c: [String: Int] = [:]
        for e in list { c[e.key, default: 0] += 1 }
        return c
    }

    /// Makes the change from `base` to `changed` again on `target`: lines `changed` gained are added to `target`
    /// (under the same heading, after the same neighbour) and lines it lost are taken out of `target`.
    /// Everything else in `target` stays as it is. Undo uses it backwards (after → before, onto what's there now);
    /// the editor's Save uses it to carry what changed on disk while you edited onto your edit.
    /// `count` is how many lines it moved; 0 means nothing to do and `target` comes back untouched.
    public static func applyChanges(from base: String, to changed: String, onto target: String) -> (text: String, count: Int) {
        let baseDoc = Doc(base), changedDoc = Doc(changed)
        let baseEntries = entries(baseDoc), changedEntries = entries(changedDoc)
        let changedCounts = counts(changedEntries)

        // Multiset differences by line text (a line moved to another heading isn't a change).
        var left = counts(baseEntries)
        var plus: [Entry] = []
        for e in changedEntries {
            if left[e.key, default: 0] > 0 { left[e.key]! -= 1 } else { plus.append(e) }
        }
        left = changedCounts
        var minus: [String] = []
        for e in baseEntries {
            if left[e.key, default: 0] > 0 { left[e.key]! -= 1 } else { minus.append(e.key) }
        }

        var out = Doc(target)
        var count = 0
        var emptiedTitles = Set<String>()
        for k in minus {
            guard let e = entries(out).last(where: { $0.key == k }) else { continue }   // already gone
            out.sections[e.section].lines.remove(at: e.line)
            if out.sections[e.section].entryIndexes.isEmpty, let t = out.sections[e.section].title { emptiedTitles.insert(t.lowercased()) }
            count += 1
        }
        for e in plus {
            // Already there as often as the changed version has it.
            guard counts(entries(out))[e.key, default: 0] < changedCounts[e.key, default: 0] else { continue }
            let from = changedDoc.sections[e.section]
            let raw = from.lines[e.line].trimmingCharacters(in: .whitespaces)
            let si = from.title.map { out.ensureSection($0, heading: from.heading) } ?? 0
            // After the line that came before it, if that's still there; else at the top or bottom, as it was.
            let previous = from.entryIndexes.last { $0 < e.line }.map { key(from.lines[$0]) }
            var lines = out.sections[si].lines
            let filled: (String) -> Bool = { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if let previous, let at = lines.lastIndex(where: { filled($0) && key($0) == previous }) {
                lines.insert(raw, at: at + 1)
            } else if previous == nil {
                lines.insert(raw, at: lines.firstIndex(where: filled) ?? 0)
            } else {
                lines.insert(raw, at: (lines.lastIndex(where: filled) ?? -1) + 1)
            }
            out.sections[si].lines = lines
            count += 1
        }
        guard count > 0 else { return (target, 0) }
        // A heading the change took away goes once nothing is left under it.
        let kept = Set(changedDoc.sections.filter { !$0.entryIndexes.isEmpty }.compactMap { $0.title?.lowercased() })
        out.sections.removeAll { s in
            guard let t = s.title?.lowercased() else { return false }
            return s.entryIndexes.isEmpty && emptiedTitles.contains(t) && !kept.contains(t)
        }
        return (out.text, count)
    }

    /// Takes these lines (by their text) out of `text`: Undo for a note whose saved versions are gone.
    public static func removing(_ lines: [String], from text: String) -> (text: String, count: Int) {
        applyChanges(from: lines.map { "- " + $0 }.joined(separator: "\n"), to: "", onto: text)
    }

    // MARK: Model reply

    public struct Review: Decodable, Equatable, Sendable {
        public var facts: [Fact]?
        public var condense: [Condense]?

        public init(facts: [Fact]? = nil, condense: [Condense]? = nil) {
            self.facts = facts
            self.condense = condense
        }

        private enum CodingKeys: String, CodingKey { case facts, condense }

        /// One bad entry (no topic, no text) never throws the whole reply away.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard c.contains(.facts) || c.contains(.condense) else {
                throw DecodingError.dataCorruptedError(forKey: .facts, in: c, debugDescription: "Not a memory review")
            }
            facts = (try? c.decodeIfPresent([Lenient<LooseFact>].self, forKey: .facts))?.compactMap { $0.value?.fact }
            condense = (try? c.decodeIfPresent([Lenient<Condense>].self, forKey: .condense))?.compactMap(\.value)
        }
    }

    private struct LooseFact: Decodable {
        var topic: String?
        var text: String
        var fact: Fact { Fact(topic: topic ?? fallbackTopic, text: text) }
    }

    private struct Lenient<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    /// The JSON object in a model's reply (it may wrap it in prose or code fences, or say something after it).
    public static func parseReview(_ text: String) -> Review? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        if let r = try? JSONDecoder().decode(Review.self, from: Data(text[start...end].utf8)) { return r }
        // Otherwise each balanced {...} in turn.
        var i = start
        var tries = 0
        while i < text.endIndex, tries < 20 {
            if text[i] == "{", let close = balancedEnd(text, from: i) {
                tries += 1
                if let r = try? JSONDecoder().decode(Review.self, from: Data(text[i...close].utf8)) { return r }
            }
            i = text.index(after: i)
        }
        return nil
    }

    private static func balancedEnd(_ text: String, from start: String.Index) -> String.Index? {
        var depth = 0, inString = false, escaped = false
        var i = start
        while i < text.endIndex {
            let c = text[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 { return i }
            }
            i = text.index(after: i)
        }
        return nil
    }
}

// MARK: - Editor helpers

extension MemoryBook {
    /// Every heading a review files facts under, in file order (Preferences … How I work, then Notes).
    public static var allTopics: [String] { topics + [fallbackTopic] }

    /// One line in the bot editor's memory list.
    public struct OutlineEntry: Hashable, Identifiable, Sendable {
        public var position: LinePosition
        /// The line without its bullet.
        public var text: String
        public var id: String { "\(position.section):\(position.line)" }
    }

    /// One heading (or the intro text above the first heading, `title == nil`) and its lines.
    public struct OutlineTopic: Hashable, Identifiable, Sendable {
        public var section: Int
        public var title: String?
        /// One of the topics reviews write to (the rest are your own headings, never shortened by the size cap).
        public var isReviewTopic: Bool
        public var entries: [OutlineEntry]
        public var id: Int { section }
    }

    /// MEMORY.md as the editor shows it: each section with its non-blank lines. Positions are for `editLine`.
    public static func outline(_ text: String) -> [OutlineTopic] {
        let doc = Doc(text)
        return doc.sections.indices.compactMap { si in
            let s = doc.sections[si]
            let entries = s.entryIndexes.map { OutlineEntry(position: LinePosition(section: si, line: $0), text: entryText(s.lines[$0])) }
            if s.heading == nil && entries.isEmpty { return nil }
            return OutlineTopic(section: si, title: s.title, isReviewTopic: s.isReviewTopic, entries: entries)
        }
    }

    /// Adds a line you typed under `topic` (one of your own headings, or a review topic, created if missing).
    /// Same checks as a review (no duplicates, no secrets, one line), but never shortens anything to make room.
    public static func addEntry(_ raw: String, topic: String, to text: String) -> MergeResult {
        let entry = clean(raw)
        var doc = Doc(text)
        let tidied = doc.text
        guard entry.count >= 1, !containsSecret(entry),
              !doc.allEntries.contains(where: { isDuplicate($0, entry) }) else {
            return MergeResult(text: text, added: [], changed: false)
        }
        // A review topic keeps its usual spelling; anything else is a heading of your own.
        let trimmed = clean(topic)
        let target = trimmed.isEmpty ? fallbackTopic
            : allTopics.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame } ?? trimmed
        doc.append(entry, to: target)
        let out = doc.text
        return MergeResult(text: out, added: [entry], changed: out != tidied)
    }
}

// MARK: - Versions

/// The last versions of a bot's MEMORY.md, so a background update (or your own edit) can be undone.
/// Kept by the app outside the bot's folder (`<root>/.launchpad/memory/<bot>/history`), so the bot doesn't see them.
/// Versions a "Memory updated" note still points at are kept as well.
public enum MemoryHistory {
    public static let keep = 10

    /// What each change wrote, filed under the name of the version from before it, so Undo can take back just that change.
    public static func afterFolder(_ dir: URL) -> URL {
        dir.appendingPathComponent("after", isDirectory: true)
    }

    public struct Version: Identifiable, Hashable, Sendable {
        public var id: String { url.lastPathComponent }
        public let url: URL
        public let date: Date
    }

    private static func formatter(_ zone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = zone
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f
    }

    /// Plain ASCII, in UTC ("MEMORY-20261116-093000-123Z.md"), so names sort by time across time zones and clock changes.
    public static func name(for date: Date) -> String {
        "MEMORY-\(formatter(TimeZone(identifier: "UTC")!).string(from: date))Z.md"
    }

    /// When a version was saved, from its name. A name without the trailing Z is read as local time.
    public static func date(ofName name: String) -> Date? {
        guard name.hasPrefix("MEMORY-"), name.hasSuffix(".md") else { return nil }
        var stamp = String(name.dropFirst("MEMORY-".count).dropLast(".md".count))
        let utc = stamp.hasSuffix("Z")
        if utc { stamp.removeLast() }
        return formatter(utc ? TimeZone(identifier: "UTC")! : .current).date(from: stamp)
    }

    /// Saves `text` as a version and returns its name (nil if it couldn't be kept).
    /// `protecting`: versions a note still points at, which pruning leaves alone.
    @discardableResult
    public static func save(_ text: String, in dir: URL, now: Date = Date(), protecting: Set<String> = []) -> String? {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var stamp = now
        var name = name(for: stamp)
        // Two saves in the same millisecond never share a name.
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
            stamp = stamp.addingTimeInterval(0.001)
            name = self.name(for: stamp)
        }
        guard (try? Data(text.utf8).write(to: dir.appendingPathComponent(name), options: .atomic)) != nil else { return nil }
        prune(dir, protecting: protecting.union([name]))
        return name
    }

    public static func saveAfter(_ text: String, version: String, in dir: URL) {
        let after = afterFolder(dir)
        try? FileManager.default.createDirectory(at: after, withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: after.appendingPathComponent(version), options: .atomic)
    }

    public static func readAfter(_ version: String, in dir: URL) -> String? {
        (try? Data(contentsOf: afterFolder(dir).appendingPathComponent(version))).flatMap(MemoryBook.decode)
    }

    /// Newest first.
    public static func versions(_ dir: URL) -> [Version] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "md" && $0.lastPathComponent.hasPrefix("MEMORY-") }.map { url in
            Version(url: url, date: date(ofName: url.lastPathComponent)
                    ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.sorted { $0.date != $1.date ? $0.date > $1.date : $0.url.lastPathComponent > $1.url.lastPathComponent }
    }

    public static func read(_ name: String, in dir: URL) -> String? {
        (try? Data(contentsOf: dir.appendingPathComponent(name))).flatMap(MemoryBook.decode)
    }

    /// Removes one version (and what its change wrote).
    public static func remove(_ name: String, in dir: URL) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        try? FileManager.default.removeItem(at: afterFolder(dir).appendingPathComponent(name))
    }

    /// Keeps the newest `keep` versions plus any in `protecting`, and drops "after" files whose version is gone.
    public static func prune(_ dir: URL, protecting: Set<String> = []) {
        for old in versions(dir).dropFirst(keep) where !protecting.contains(old.id) {
            try? FileManager.default.removeItem(at: old.url)
        }
        let left = Set(versions(dir).map(\.id))
        let afters = (try? FileManager.default.contentsOfDirectory(atPath: afterFolder(dir).path)) ?? []
        for a in afters where !left.contains(a) { try? FileManager.default.removeItem(at: afterFolder(dir).appendingPathComponent(a)) }
    }
}
