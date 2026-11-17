import Foundation

/// Block-level markdown for chat bubbles. Inline styling (bold, links, `code`) is left to
/// the UI. Built to cope with half-finished text while a reply is still streaming.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String?, code: String)
    case list(ordered: Bool, items: [ListItem])
    case quote(String)
    case table(header: [String], rows: [[String]])
    case rule
}

public struct ListItem: Equatable, Sendable {
    public var indent: Int
    public var marker: String
    public var text: String
    public var checked: Bool?

    public init(indent: Int, marker: String, text: String, checked: Bool? = nil) {
        self.indent = indent
        self.marker = marker
        self.text = text
        self.checked = checked
    }
}

public enum MarkdownParser {
    public static func blocks(_ source: String) -> [MarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var i = 0

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph.removeAll()
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code (``` or ~~~). An unclosed fence runs to the end (still streaming).
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                i += 1 // skip closing fence
                blocks.append(.code(language: lang.isEmpty ? nil : lang, code: code.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                i += 1
                continue
            }

            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                i += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    quote.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
                continue
            }

            if trimmed.hasPrefix("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                let header = tableCells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix("|") else { break }
                    rows.append(tableCells(t))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            if let first = listItem(line) {
                flushParagraph()
                let ordered = first.ordered
                var items: [ListItem] = [first.item]
                i += 1
                while i < lines.count {
                    if let next = listItem(lines[i]), next.ordered == ordered || next.item.indent > 0 {
                        items.append(next.item)
                        i += 1
                    } else if !lines[i].trimmingCharacters(in: .whitespaces).isEmpty,
                              lines[i].hasPrefix("  "), !items.isEmpty {
                        // Continuation line of the previous item.
                        items[items.count - 1].text += " " + lines[i].trimmingCharacters(in: .whitespaces)
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.list(ordered: ordered, items: items))
                continue
            }

            paragraph.append(line)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    private static func parseHeading(_ t: String) -> MarkdownBlock? {
        guard t.hasPrefix("#") else { return nil }
        let level = t.prefix(while: { $0 == "#" }).count
        guard level <= 6 else { return nil }
        let rest = t.dropFirst(level)
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        return .heading(level: level, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ t: String) -> Bool {
        let compact = t.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let c = compact.first, "-*_".contains(c) else { return false }
        return compact.allSatisfy { $0 == c }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("|"), t.contains("-") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    private static func tableCells(_ t: String) -> [String] {
        var s = t
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func listItem(_ line: String) -> (ordered: Bool, item: ListItem)? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
        let t = line.trimmingCharacters(in: .whitespaces)
        for bullet in ["- ", "* ", "+ "] where t.hasPrefix(bullet) {
            var text = String(t.dropFirst(2))
            var checked: Bool?
            if text.hasPrefix("[ ] ") { checked = false; text = String(text.dropFirst(4)) }
            else if text.lowercased().hasPrefix("[x] ") { checked = true; text = String(text.dropFirst(4)) }
            return (false, ListItem(indent: indent / 2, marker: "•", text: text, checked: checked))
        }
        let digits = t.prefix(while: { $0.isNumber })
        if !digits.isEmpty, digits.count <= 3 {
            let rest = t.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return (true, ListItem(indent: indent / 2, marker: "\(digits).", text: String(rest.dropFirst(2))))
            }
        }
        return nil
    }
}
