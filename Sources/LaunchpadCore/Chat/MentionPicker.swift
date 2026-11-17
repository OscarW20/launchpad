import Foundation

/// The @-mention picker in a group chat's composer: what's being typed, who it matches, and what picking one writes.
/// The view is `MentionList` in the app; this part has no UI.
public enum MentionPicker {
    /// The handle being typed at the end of `draft` ("hey @fro" gives "fro", a lone "@" gives ""), or nil when
    /// the draft doesn't end in one. The "@" must start a word, so "me@example" and "@@" don't count.
    public static func query(in draft: String) -> String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        let typed = draft[draft.index(after: at)...]
        guard typed.allSatisfy(isHandleCharacter) else { return nil }
        if at > draft.startIndex {
            // Same rule as `GroupPlan.mentions`: not straight after a word, another "@" or a dot.
            let before = draft[draft.index(before: at)]
            if before.isLetter || before.isNumber || before == "_" || before == "@" || before == "." { return nil }
        }
        return String(typed)
    }

    /// The members that match `query` by id or name, in group order: those that start with it first, then those
    /// that contain it. An empty query lists everyone.
    public static func candidates(for query: String, among members: [Bot]) -> [Bot] {
        let q = query.lowercased()
        guard !q.isEmpty else { return members }
        var starts: [Bot] = []
        var contains: [Bot] = []
        for bot in members {
            let name = bot.name.lowercased()
            let keys = [bot.id.lowercased(), name, name.replacingOccurrences(of: " ", with: ""), Slug.make(name)]
            if keys.contains(where: { $0.hasPrefix(q) }) {
                starts.append(bot)
            } else if keys.contains(where: { $0.contains(q) }) {
                contains.append(bot)
            }
        }
        return starts + contains
    }

    /// `draft` with the handle being typed replaced by "@id " (unchanged when nothing is being typed).
    public static func insert(_ id: String, into draft: String) -> String {
        guard let query = query(in: draft) else { return draft }
        return String(draft.dropLast(query.count + 1)) + "@\(id) "
    }

    private static func isHandleCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "-"
    }
}
