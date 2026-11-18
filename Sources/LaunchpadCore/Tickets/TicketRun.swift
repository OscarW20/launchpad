import Foundation

// The small decisions the Create ticket panel and hotkey make, kept here so they can be tested without the app.

/// The global hotkey for Create ticket: ⌃⌥ and a letter.
public enum TicketHotkey {
    public static let defaultLetter = "T"
    public static let modifiers = "⌃⌥"

    /// The letters you can pick, with their macOS virtual key codes. B is left out: Quick Ask already has ⌃⌥B.
    public static let keyCodes: [String: UInt32] = [
        "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7, "C": 8, "V": 9, "Q": 12, "W": 13, "E": 14,
        "R": 15, "Y": 16, "T": 17, "O": 31, "U": 32, "I": 34, "P": 35, "L": 37, "J": 38, "K": 40, "N": 45, "M": 46,
    ]

    public static var letters: [String] { keyCodes.keys.sorted() }

    /// A saved letter that can still be used (any case), or the default.
    public static func normalised(_ letter: String?) -> String {
        let l = letter?.trimmingCharacters(in: .whitespaces).uppercased() ?? ""
        return keyCodes[l] != nil ? l : defaultLetter
    }

    public static func keyCode(for letter: String?) -> UInt32 { keyCodes[normalised(letter)] ?? 17 }

    /// "⌃⌥T"
    public static func label(for letter: String?) -> String { modifiers + normalised(letter) }
}

/// Which connector is Jira, and which bots can file a ticket with it.
public enum TicketConnector {
    /// The Atlassian connector (Jira & Confluence), by its id or by its address.
    public static func isJira(_ connector: Connector) -> Bool {
        if connector.id == TicketGuard.serverKey { return true }
        guard let host = connector.url.flatMap({ URL(string: $0)?.host?.lowercased() }) else { return false }
        return host == "atlassian.com" || host.hasSuffix(".atlassian.com")
    }

    /// Bots that have the Jira connector (their own or a group's) and are Claude bots. Only a Claude bot runs behind
    /// the permission guard, which is what makes "Ask me first" real: a Codex bot's rules are only instructions.
    public static func bots(_ bots: [Bot], groups: [BotGroup], connectors: [Connector]) -> [Bot] {
        bots.filter { bot in
            bot.engine == .claude
                && MCPConfig.effective(for: bot, groups: groups, all: connectors).contains(where: isJira)
        }
    }

    /// The bot to use: the one picked if it still can, else the first that can.
    public static func choose(preferred: String?, from candidates: [Bot]) -> Bot? {
        candidates.first { $0.id == preferred } ?? candidates.first
    }
}

extension TicketPrompt {
    /// One line naming the ticket, for the chat's title: the start of your note, else of the selected text.
    public static func chatTitle(_ preview: TicketPreview, limit: Int = 60) -> String {
        let source = preview.note.isEmpty ? preview.selection : preview.note
        let line = source.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let flat = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !flat.isEmpty else { return "Ticket" }
        return "Ticket: " + (flat.count > limit ? String(flat.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…" : flat)
    }

    /// What your message in the ticket's chat says: short, so a long selection doesn't fill the chat. The bot gets the
    /// full prompt (`build`), not this.
    public static func chatText(_ preview: TicketPreview, assignee: TicketAssignee?, excerpt: Int = 400) -> String {
        var lines = ["Create a Jira ticket" + (preview.sourceApp.map { " from text selected in \($0)" } ?? "") + "."]
        if let assignee { lines.append("Assign to: \(assignee.name)") }
        if !preview.note.isEmpty { lines.append("Note: \(preview.note)") }
        if !preview.selection.isEmpty {
            let shown = preview.selection.count > excerpt ? String(preview.selection.prefix(excerpt)) + "…" : preview.selection
            let size = preview.truncated ? "\(preview.selection.count) of \(preview.originalCharacters) characters" : "\(preview.selection.count) characters"
            lines.append("")
            lines.append("Selected text (\(size)):")
            lines.append(contentsOf: shown.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 })
        }
        return lines.joined(separator: "\n")
    }
}
