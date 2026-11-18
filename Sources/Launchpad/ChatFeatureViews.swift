#if os(macOS)
import SwiftUI
import AppKit
import QuickLook
import LaunchpadCore

// MARK: - Reactions

struct ReactionsBar: View {
    @Environment(AppModel.self) private var model
    let message: ChatMessage
    let chatId: String

    var body: some View {
        let reactions = ChatOps.reactions(of: message)
        if !reactions.isEmpty {
            HStack(spacing: 4) {
                ForEach(reactions, id: \.emoji) { r in
                    let mine = r.who.contains(ChatOps.you)
                    Button {
                        model.toggleReaction(r.emoji, on: message.id, in: chatId)
                    } label: {
                        HStack(spacing: 3) {
                            Text(r.emoji)
                            if r.who.count > 1 { Text("\(r.who.count)").font(.caption2.monospacedDigit()) }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(mine ? Theme.accent.opacity(0.18) : Theme.field, in: Capsule())
                        .overlay(Capsule().strokeBorder(mine ? Theme.accent.opacity(0.5) : Theme.line))
                    }
                    .buttonStyle(.plain)
                    .help(r.who.map { $0 == ChatOps.you ? "You" : (model.bot($0)?.name ?? $0) }.joined(separator: ", "))
                }
            }
        }
    }
}

/// A row of quick reactions, for menus.
enum QuickReactions {
    static let all = ["👍", "❤️", "😂", "🎉", "👀", "🙏", "✅", "🤔"]
}

// MARK: - GIFs

/// An animated GIF (SwiftUI's AsyncImage only shows the first frame).
struct AnimatedImage: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.animates = true
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        load(into: view)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {}

    private func load(into view: NSImageView) {
        let url = self.url
        Task {
            guard let loaded = try? await URLSession.shared.data(from: url), let image = NSImage(data: loaded.0) else { return }
            await MainActor.run { view.image = image }
        }
    }
}

struct GifView: View {
    let gif: GifRef

    var body: some View {
        let width = min(260, max(80, gif.width))
        let height = gif.width > 0 ? width * gif.height / gif.width : 180
        Group {
            if let url = URL(string: gif.url) {
                AnimatedImage(url: url)
            } else {
                Color.clear
            }
        }
        .frame(width: width, height: height)
        .background(Theme.field)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help(gif.title ?? "GIF")
    }
}

struct GifPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let chatId: String
    @State private var query = ""
    @State private var results: [GiphySearch.Result] = []
    @State private var searching = false
    @State private var hasKey = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if hasKey {
                TextField("Search GIPHY", text: $query)
                    .textFieldStyle(PillFieldStyle())
                    .onSubmit(search)
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(110), spacing: 6), count: 3), spacing: 6) {
                        ForEach(results) { r in
                            Button {
                                model.sendGif(r.gif, in: chatId)
                                dismiss()
                            } label: {
                                AsyncImage(url: URL(string: r.gif.preview ?? r.gif.url)) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    Theme.field
                                }
                                .frame(width: 110, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .help(r.gif.title ?? "GIF")
                        }
                    }
                }
                .frame(height: 260)
                .overlay {
                    if searching { ProgressView() }
                    else if results.isEmpty { Text("Search for a GIF to send.").foregroundStyle(Theme.secondary) }
                }
                Text("Powered by GIPHY").font(.caption2).foregroundStyle(Theme.secondary)
            } else {
                Label("Add a GIPHY API key in Settings to send GIFs.", systemImage: "key")
                    .foregroundStyle(Theme.secondary)
                Button("Open Settings") {
                    model.section = .settings
                    dismiss()
                }
            }
        }
        .padding(12)
        .frame(width: 360)
        .onAppear { hasKey = model.hasGiphyKey }
    }

    private func search() {
        let q = query
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        searching = true
        Task {
            let found = await model.searchGifs(q)
            results = found
            searching = false
        }
    }
}

// MARK: - Plan card

struct PlanCardView: View {
    @Environment(AppModel.self) private var model
    let card: PlanCard
    let messageId: String
    let chatId: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Plan", systemImage: "list.bullet.clipboard")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accentText)
            Text(card.message).font(.body.weight(.medium))
            if !card.steps.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(card.steps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(i + 1).").monospacedDigit().foregroundStyle(Theme.secondary)
                            InlineText(step)
                        }
                    }
                }
            }
            switch card.state {
            case .waiting:
                HStack(spacing: 10) {
                    Button { model.answerPlan(messageId, in: chatId, start: true) } label: { Label("Start", systemImage: "play.fill") }
                        .buttonStyle(PillButtonStyle())
                        .controlSize(.large)
                    Button { model.answerPlan(messageId, in: chatId, start: false) } label: { Label("Cancel", systemImage: "xmark") }
                        .buttonStyle(SoftButtonStyle())
                        .controlSize(.large)
                    if card.autoStart != nil {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            if let left = card.secondsLeft(now: context.date) {
                                Text(left > 0 ? "Starts by itself in \(left)s" : "Starting…")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(Theme.secondary)
                            }
                        }
                    }
                }
            case .started:
                Label("Started", systemImage: "play.circle.fill").foregroundStyle(Theme.success).font(.callout.weight(.medium))
            case .cancelled:
                Label("Cancelled", systemImage: "xmark.circle.fill").foregroundStyle(Theme.secondary).font(.callout.weight(.medium))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: Theme.Space.l, radius: 22)
    }
}

// MARK: - Question card

struct QuestionCardView: View {
    @Environment(AppModel.self) private var model
    let card: QuestionCard
    let messageId: String
    let chatId: String
    @State private var picked: [Int: Set<String>] = [:]
    @State private var other: [Int: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(card.items.count == 1 ? "Question" : "Questions", systemImage: "questionmark.bubble")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accentText)
            ForEach(Array(card.items.enumerated()), id: \.offset) { i, item in
                VStack(alignment: .leading, spacing: 6) {
                    InlineText(item.text).font(.body.weight(.medium))
                    if card.answered {
                        Text(card.answers?[safe: i] ?? "").foregroundStyle(Theme.accentText)
                    } else {
                        FlowRow(spacing: 6) {
                            ForEach(item.options, id: \.self) { option in
                                let on = picked[i, default: []].contains(option)
                                Button { toggle(option, at: i, multi: item.multi) } label: {
                                    Text(option)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(on ? Color.white : Theme.accentText)
                                        .padding(.horizontal, 14)
                                        .frame(height: 30)
                                        .background(on ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.accentSoft), in: Capsule())
                                        .contentShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        TextField(item.options.isEmpty ? "Your answer" : "Or say something else", text: Binding(
                            get: { other[i] ?? "" }, set: { other[i] = $0 }))
                            .textFieldStyle(PillFieldStyle())
                    }
                }
            }
            if !card.answered {
                Button("Send answers") { model.answerQuestions(messageId, in: chatId, answers: answers) }
                    .buttonStyle(PillButtonStyle())
                    .controlSize(.large)
                    .disabled(answers.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: Theme.Space.l, radius: 22)
    }

    private var answers: [String] {
        card.items.indices.map { i in
            let typed = (other[i] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !typed.isEmpty { return typed }
            let item = card.items[i]
            return item.options.filter { picked[i, default: []].contains($0) }.joined(separator: ", ")
        }
    }

    private func toggle(_ option: String, at i: Int, multi: Bool) {
        var set = picked[i, default: []]
        if set.contains(option) { set.remove(option) } else {
            if !multi { set.removeAll() }
            set.insert(option)
        }
        picked[i] = set
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Lays chips out in rows that wrap.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { y += row + spacing; x = 0; row = 0 }
            x += s.width + spacing
            widest = max(widest, x - spacing)
            row = max(row, s.height)
        }
        return CGSize(width: min(width, widest), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { y += row + spacing; x = bounds.minX; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            row = max(row, s.height)
        }
    }
}

// MARK: - Polls

struct PollView: View {
    @Environment(AppModel.self) private var model
    let poll: Poll
    let messageId: String
    let chatId: String
    var canVote = true

    var body: some View {
        let counts = poll.counts
        let total = max(1, counts.reduce(0, +))
        VStack(alignment: .leading, spacing: 8) {
            Label("Poll", systemImage: "chart.bar")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accentText)
            Text(poll.question).font(.body.weight(.medium))
            ForEach(Array(poll.options.enumerated()), id: \.offset) { i, option in
                let voters = poll.voters(i)
                Button {
                    model.vote(messageId, in: chatId, option: i)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Image(systemName: poll.votes[ChatOps.you] == i ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(poll.votes[ChatOps.you] == i ? Theme.accent : .secondary)
                            Text(option)
                            Spacer()
                            Text("\(counts[i])").monospacedDigit().foregroundStyle(Theme.secondary)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.line)
                                Capsule().fill(Theme.accent)
                                    .frame(width: geo.size.width * CGFloat(counts[i]) / CGFloat(total))
                            }
                        }
                        .frame(height: 6)
                        if !voters.isEmpty {
                            Text(voters.map(name).joined(separator: ", ")).font(.caption).foregroundStyle(Theme.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canVote)
            }
            if let reasons = poll.reasons, !reasons.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(reasons.keys.sorted(), id: \.self) { who in
                        Text("\(name(who)): \(reasons[who] ?? "")").font(.caption).foregroundStyle(Theme.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
        .card(padding: Theme.Space.l, radius: 22)
    }

    private func name(_ id: String) -> String { id == ChatOps.you ? "You" : (model.bot(id)?.name ?? id) }
}

struct NewPollSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let chatId: String
    @State private var question = ""
    @State private var options = ["", ""]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Question", text: $question, prompt: Text("What should we build next?"))
                Section("Options") {
                    ForEach(options.indices, id: \.self) { i in
                        TextField("Option \(i + 1)", text: $options[i])
                    }
                    if options.count < Poll.maxOptions {
                        Button("Add option") { options.append("") }
                    }
                }
            }
            .themedForm()
            HStack {
                Text("The bots vote and say why.").font(.caption).foregroundStyle(Theme.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start Poll") {
                    model.startPoll(in: chatId, question: question, options: options)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(PillButtonStyle())
                .disabled(ChatOps.makePoll(question: question, options: options) == nil)
            }
            .padding(Theme.Space.l)
        }
        .frame(width: 440, height: 420)
        .sheetBackground()
    }
}

// MARK: - Files

/// Files that came with a message, or that a bot mentioned: click for Quick Look.
struct FileChips: View {
    let urls: [URL]
    @State private var preview: URL?

    var body: some View {
        FlowRow(spacing: 6) {
            ForEach(urls, id: \.self) { url in
                Button { preview = url } label: {
                    HStack(spacing: 5) {
                        if Attachments.isImage(url.path), let image = NSImage(contentsOf: url) {
                            Image(nsImage: image).resizable().scaledToFill()
                                .frame(width: 22, height: 22)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        } else {
                            Image(systemName: FileMentions.icon(for: url))
                        }
                        Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.callout)
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.field, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.line))
                }
                .buttonStyle(.plain)
                .help(url.path)
                .contextMenu {
                    Button("Open") { SystemActions.open(url) }
                    Button("Show in Finder") { SystemActions.reveal(url) }
                }
            }
        }
        .quickLookPreview($preview, in: urls)
    }
}

/// Files a bot's reply mentions that exist in its folder or workspace.
struct FileMentionChips: View {
    @Environment(AppModel.self) private var model
    let message: ChatMessage
    let chatId: String
    @State private var found: [URL] = []

    var body: some View {
        Group {
            if !found.isEmpty { FileChips(urls: found) }
        }
        .task(id: message.text) {
            guard message.status != .streaming, let meta = model.chat(chatId) else { return }
            let roots = FileMentions.roots(for: meta, botId: message.botId, paths: model.paths)
            let text = message.text
            found = await Task.detached(priority: .utility) { FileMentions.find(in: text, roots: roots) }.value
        }
    }
}

// MARK: - To-do list

struct TodoListView: View {
    let items: [TodoItem]

    var body: some View {
        let done = items.filter { $0.status == .completed }.count
        VStack(alignment: .leading, spacing: 4) {
            Label("To-do · \(done) of \(items.count) done", systemImage: "checklist")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accentText)
            ForEach(items) { item in
                HStack(spacing: 6) {
                    switch item.status {
                    case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.successFill)
                    case .inProgress: Image(systemName: "circle.dotted.circle").foregroundStyle(Theme.accent)
                    case .pending: Image(systemName: "circle").foregroundStyle(Theme.secondary)
                    }
                    Text(item.label)
                        .strikethrough(item.status == .completed)
                        .foregroundStyle(item.status == .completed ? .secondary : .primary)
                        .fontWeight(item.status == .inProgress ? .medium : .regular)
                }
                .font(.callout)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 10)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Message menu

struct MessageMenu: View {
    @Environment(AppModel.self) private var model
    let message: ChatMessage
    let chatId: String
    @Binding var editing: Bool

    var body: some View {
        let others = model.bots.filter { $0.id != message.botId }
        Menu("React") {
            ForEach(QuickReactions.all, id: \.self) { e in
                Button(e) { model.toggleReaction(e, on: message.id, in: chatId) }
            }
        }
        Button(message.pinned == true ? "Unpin" : "Pin") { model.togglePin(message.id, in: chatId) }
        Button(message.saved == true ? "Remove from Saved" : "Save for Later") { model.toggleSave(message.id, in: chatId) }
        Button("Copy Text") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.text, forType: .string)
        }
        .disabled(message.text.isEmpty)
        Divider()
        if message.role == .user {
            Button("Edit…") { editing = true }.disabled(message.text.isEmpty)
        }
        Menu("Forward to") {
            ForEach(model.chats.filter { $0.id != chatId }) { c in
                Button(c.title) { model.forward(message.id, from: chatId, to: c.id) }
            }
        }
        if message.role == .bot, !others.isEmpty {
            Menu("Ask for Review") {
                ForEach(others) { b in
                    Button("\(b.emoji) \(b.name)") { model.askForReview(message.id, in: chatId, reviewer: b.id) }
                }
            }
            .disabled(model.isRunning(chatId))
        }
        Button("Branch from Here") { model.branch(chatId, from: message.id) }
        Button("Save as Skill…") { model.teachSkill(from: chatId, endingAt: message.id) }
            .disabled(model.isRunning(chatId))
        Divider()
        Button("Delete", role: .destructive) { model.deleteMessage(message.id, in: chatId) }
    }
}

struct EditMessageSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let message: ChatMessage
    let chatId: String
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit message").font(Theme.rounded(.title3, weight: .bold))
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(Theme.Space.s)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).strokeBorder(Theme.line))
            Text("The bot isn't asked again; earlier versions are kept.").font(.caption).foregroundStyle(Theme.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.editMessage(message.id, in: chatId, to: text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(PillButtonStyle())
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 480, height: 300)
        .sheetBackground()
        .onAppear { text = message.text }
    }
}

// MARK: - Pinned and saved

struct PinnedBar: View {
    @Environment(AppModel.self) private var model
    let chatId: String

    var body: some View {
        let pinned = ChatOps.pinned(model.messages(for: chatId))
        if !pinned.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "pin.fill").foregroundStyle(Theme.accentText)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(pinned) { m in
                            Button { model.jump(to: m.id, in: chatId) } label: {
                                Text(ChatOps.summary(m))
                                    .lineLimit(1)
                                    .frame(maxWidth: 240)
                                    .foregroundStyle(Theme.accentText)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Theme.accentSoft, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .contextMenu { Button("Unpin") { model.togglePin(m.id, in: chatId) } }
                        }
                    }
                }
            }
            .font(.callout)
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.s)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
    }
}

struct SavedMessagesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var saved: [(chatId: String, message: ChatMessage)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Saved messages").font(Theme.rounded(.title2, weight: .bold))
            if saved.isEmpty {
                EmptyState(symbol: "bookmark", title: "Nothing saved yet", message: "Right-click a message and choose Save for Later.")
            } else {
                List {
                    ForEach(saved, id: \.message.id) { item in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(model.authorName(item.message)) in \(model.chat(item.chatId)?.title ?? "a chat") · \(item.message.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(Theme.secondary)
                                Text(ChatOps.summary(item.message)).lineLimit(3)
                            }
                            Spacer()
                            Button("Open") {
                                model.jump(to: item.message.id, in: item.chatId)
                                dismiss()
                            }
                            Button {
                                model.toggleSave(item.message.id, in: item.chatId)
                                saved = model.savedMessages()
                            } label: { Image(systemName: "bookmark.slash") }
                                .buttonStyle(.borderless)
                                .help("Remove from Saved")
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 560, height: 520)
        .sheetBackground()
        .onAppear { saved = model.savedMessages() }
    }
}

// MARK: - ⌘K

struct QuickSwitcherSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection = 0
    @State private var items: [SwitcherItem] = []
    @State private var chats: [(meta: ChatMeta, messages: [ChatMessage])] = []
    /// Search every workspace, not just this one. Only offered once you have more than General.
    @State private var everywhere = false
    @FocusState private var focused: Bool

    var body: some View {
        let results = Array(QuickSearch.search(query, items: items, chats: chats, name: model.authorName).prefix(40))
        let center = WorkspaceCenter.shared
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField(center.isInUse && !everywhere ? "Search \(center.current.name): chats, bots, pages, messages…"
                                                         : "Jump to a chat, bot, page or message…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { open(results) }
                    .onKeyPress(.downArrow) { selection = min(selection + 1, max(0, results.count - 1)); return .handled }
                    .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
                    .onChange(of: query) { selection = 0 }
                if center.isInUse {
                    Toggle("All workspaces", isOn: $everywhere)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .fixedSize()
                        .help("Search every workspace instead of only \(center.current.name)")
                        .onChange(of: everywhere) { reload() }
                }
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, item in
                        HStack(spacing: 10) {
                            Image(systemName: symbol(item.kind)).foregroundStyle(Theme.secondary).frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title).lineLimit(1)
                                if !item.detail.isEmpty {
                                    Text(item.detail).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            // Which workspace, when you're searching them all: two bots can share a name.
                            if everywhere, let wsId = model.workspaceId(of: item), let ws = center.workspace(wsId) {
                                HStack(spacing: 4) {
                                    WorkspaceTile(workspace: ws, size: 18)
                                    Text(ws.name).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                                }
                                .accessibilityLabel("In \(ws.name)")
                            }
                        }
                        .padding(.vertical, 2)
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                                .fill(i == selection ? Theme.accentSoft : Color.clear)
                                .padding(.horizontal, 6)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { selection = i; open(results) }
                        .id(i)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onChange(of: selection) { proxy.scrollTo(selection) }
            }
        }
        .frame(width: 560, height: 420)
        .sheetBackground()
        .onAppear {
            reload()
            focused = true
        }
        .onExitCommand { dismiss() }
    }

    private func reload() {
        items = model.switcherItems(allWorkspaces: everywhere)
        chats = model.switcherChats(allWorkspaces: everywhere)
        selection = 0
    }

    private func open(_ results: [SwitcherItem]) {
        guard results.indices.contains(selection) else { return }
        let item = results[selection]
        dismiss()
        model.open(item)
    }

    private func symbol(_ kind: SwitcherItem.Kind) -> String {
        switch kind {
        case .chat: return "bubble.left"
        case .bot: return "face.smiling"
        case .group: return "person.3"
        case .page: return "sidebar.left"
        case .action: return "bolt"
        case .message: return "text.quote"
        }
    }
}

// MARK: - Context ring and threads

struct ContextRing: View {
    let usage: ContextUsage

    var body: some View {
        let colour = usage.isNearlyFull ? Theme.warning : Theme.accent
        ZStack {
            Circle().stroke(Theme.line, lineWidth: 3)
            Circle().trim(from: 0, to: usage.fraction)
                .stroke(colour, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 16, height: 16)
        .help("Memory for this chat: \(usage.summary)\(usage.isEstimated ? " (estimated)" : "")"
              + (usage.isNearlyFull ? ". Nearly full: Compact summarises the older messages. Launchpad does this by itself when auto-compact is on (Settings › Long chats)." : ""))
    }
}

struct ThreadMenu: View {
    @Environment(AppModel.self) private var model
    let chatId: String

    var body: some View {
        let running = model.isRunning(chatId)
        let last = model.messages(for: chatId).last { $0.role != .notice }
        CircleMenu(symbol: "text.bubble", help: running ? "Wait until the reply finishes" : "New thread, compact, branch or past threads") {
            Button("New Thread") { model.newThread(chatId) }
                .help("Put this conversation aside and start fresh")
            Button("Compact") { model.compactChat(chatId, manual: true) }
                .disabled(CompactionCenter.shared.compacting.contains(chatId))
                .help("Summarise the older messages and keep the latest; every message stays on screen")
            Button("Branch from Here") { if let last { model.branch(chatId, from: last.id) } }
                .disabled(last == nil)
            Divider()
            Button("Past Threads…") { model.pastThreadsChatId = chatId }
        }
        .disabled(running)
    }
}

struct PastThreadsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let chatId: String
    @State private var open: String?

    var body: some View {
        let threads = model.pastThreads(chatId)
        VStack(alignment: .leading, spacing: 12) {
            Text("Past threads").font(Theme.rounded(.title2, weight: .bold))
            Text("Earlier conversations in \(model.chat(chatId)?.title ?? "this chat"). Reopening one puts the current conversation aside.")
                .foregroundStyle(Theme.secondary)
            if threads.isEmpty {
                EmptyState(symbol: "text.bubble", title: "No past threads", message: "Start a New Thread from the Thread menu and the current one is kept here.")
            } else {
                List {
                    ForEach(threads) { t in
                        DisclosureGroup(isExpanded: Binding(get: { open == t.id }, set: { open = $0 ? t.id : nil })) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(model.threads.messages(chatId, thread: t.id).filter { $0.role != .notice }) { m in
                                    Text("\(model.authorName(m)): \(ChatOps.summary(m))").lineLimit(3).font(.callout)
                                }
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.title).lineLimit(1)
                                    Text("\(t.messageCount) messages · \(t.startedAt.formatted(date: .abbreviated, time: .shortened)) to \(t.archivedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption).foregroundStyle(Theme.secondary)
                                }
                                Spacer()
                                Button("Reopen") {
                                    model.reopenThread(t.id, in: chatId)
                                    dismiss()
                                }
                                .disabled(model.isRunning(chatId))
                                Button(role: .destructive) { model.deleteThread(t.id, in: chatId) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                                    .help("Delete this thread")
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 600, height: 520)
        .sheetBackground()
    }
}

// MARK: - Activity

struct ActivityFeedView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let events = model.activity.recent(60)
        VStack(alignment: .leading, spacing: 8) {
            Text("Activity").font(Theme.rounded(.headline, weight: .bold))
            if events.isEmpty {
                Text("What your bots do shows up here while Launchpad is open.").foregroundStyle(Theme.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(events) { e in
                            HStack(alignment: .top, spacing: 8) {
                                AvatarView(bot: model.bot(e.botId), size: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(e.text).font(.callout).lineLimit(2)
                                    Text("\(model.chat(e.chatId)?.title ?? "") · \(TimeLabel.clock(e.date))")
                                        .font(.caption2).foregroundStyle(Theme.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { if model.chat(e.chatId) != nil { model.show(chat: e.chatId) } }
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 340, height: 380, alignment: .topLeading)
    }
}
#endif
