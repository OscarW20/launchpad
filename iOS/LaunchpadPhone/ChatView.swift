import SwiftUI

struct ChatView: View {
    @Environment(MacLink.self) private var link
    let chatID: String
    @State private var draft = ""
    @State private var replyingTo: Message?
    @State private var sending = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    private var chat: ChatInfo? { link.state?.chats.first { $0.id == chatID } }
    private var list: [Message] {
        let all = link.messages[chatID] ?? []
        // In a group, whoever is still typing sits at the bottom, like on the Mac.
        guard chat?.isGroup == true else { return all }
        return all.filter { !$0.isStreaming } + all.filter(\.isStreaming)
    }
    private var working: Bool { chat?.working ?? false }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if list.isEmpty && link.messages[chatID] != nil { empty }
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, m in
                        let prev = i > 0 ? list[i - 1] : nil
                        let next = i + 1 < list.count ? list[i + 1] : nil
                        if prev.map({ !Calendar.current.isDate($0.date, inSameDayAs: m.date) }) ?? true {
                            Text(dayLabel(m.date)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.subtle)
                                .padding(.horizontal, 10).padding(.vertical, 4).background(Capsule().fill(Theme.field))
                                .padding(.vertical, 12)
                        }
                        MessageRow(message: m, chatID: chatID, isGroup: chat?.isGroup ?? false,
                                   firstInRun: !sameRun(prev, m), lastInRun: !sameRun(m, next),
                                   onReply: { replyingTo = $0; focused = true })
                            .padding(.top, sameRun(prev, m) ? 2 : 10)
                            .id(m.id)
                    }
                    Color.clear.frame(height: 8).id("bottom")
                }
                .padding(.horizontal, 12)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: list.last?.text) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: list.count) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
        }
        .background(Theme.canvas.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { composer }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let chat {
                    HStack(spacing: 8) {
                        ChatAvatar(chat: chat, size: 32)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(chat.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                            Text(status(chat)).font(.system(size: 12)).foregroundStyle(chat.typing.isEmpty ? Theme.subtle : Theme.accent).lineLimit(1)
                        }
                    }
                }
            }
            if working {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await link.stop(chatID) } } label: {
                        Label("Stop", systemImage: "stop.fill").labelStyle(.titleAndIcon)
                    }
                    .tint(.red)
                }
            }
        }
        .task {
            link.openThread = chatID
            await link.loadMessages(chatID)
            await link.markRead(chatID)
        }
        .onDisappear { if link.openThread == chatID { link.openThread = nil } }
        .onChange(of: list.count) { _, _ in Task { await link.markRead(chatID) } }
    }

    private func status(_ chat: ChatInfo) -> String {
        if let t = chat.typing.first { return chat.isGroup ? "\(t) is typing…" : "typing…" }
        if chat.isGroup { return "\(chat.members?.count ?? 0) bots" }
        return jobTitle(chat.role).isEmpty ? "online" : jobTitle(chat.role)
    }

    private var empty: some View {
        VStack(spacing: 12) {
            if let chat { ChatAvatar(chat: chat, size: 96) }
            Text(chat?.isGroup == true ? "Give the group a task" : "Say hi").font(.display(22, .bold)).foregroundStyle(Theme.ink)
            Text(chat?.isGroup == true ? "The lead picks it up and hands work to teammates. @mention anyone to talk to them directly." : "It remembers your chats and works on your Mac.")
                .font(.system(size: 15)).foregroundStyle(Theme.subtle).multilineTextAlignment(.center)
        }
        .padding(.vertical, 60).padding(.horizontal, 24)
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let problem {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text(problem).lineLimit(2)
                    Spacer()
                    Button { self.problem = nil } label: { Image(systemName: "xmark") }
                }
                .font(.system(size: 13)).foregroundStyle(Theme.danger)
                .padding(.horizontal, 16)
            }
            if working, replyingTo == nil {
                Label("Working. Anything you send now is a quick side question.", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 12)).foregroundStyle(Theme.subtle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
            }
            if let r = replyingTo {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 3, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Replying to \(r.author.name)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                        Text(r.text).font(.system(size: 13)).foregroundStyle(Theme.subtle).lineLimit(1)
                    }
                    Spacer()
                    Button { replyingTo = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.subtle) }
                }
                .padding(.horizontal, 16)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focused)
                    .font(.system(size: 17))
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.bubbleIn))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.line))
                Button { Task { await send() } } label: {
                    Image(systemName: "arrow.up").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 44, height: 44).background(Circle().fill(canSend ? Theme.accent : Theme.subtle.opacity(0.4)))
                }
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
            .padding(.horizontal, 12)
        }
        .padding(.top, 8).padding(.bottom, 6)
        .background(.bar)
    }

    private var placeholder: String {
        if working { return "Ask a quick side question" }
        return chat?.isGroup == true ? "Message the group · @mention to pick" : "Message \(chat?.name ?? "")"
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        draft = ""
        let reply = replyingTo?.id
        replyingTo = nil
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if working && reply == nil {
            problem = await link.askOnTheSide(text, in: chatID)
        } else {
            problem = await link.send(text, to: chatID, replyTo: reply)
        }
        if problem != nil { draft = text }
        sending = false
    }

    private func sameRun(_ a: Message?, _ b: Message?) -> Bool {
        guard let a, let b, a.author == b.author, a.author.kind != "system" else { return false }
        return b.date.timeIntervalSince(a.date) < 180
    }

    private func dayLabel(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return "Today" }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

struct MessageRow: View {
    @Environment(MacLink.self) private var link
    let message: Message
    let chatID: String
    let isGroup: Bool
    let firstInRun: Bool
    let lastInRun: Bool
    var onReply: (Message) -> Void

    var body: some View {
        switch message.author.kind {
        case "system":
            Text(message.text).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.subtle)
                .multilineTextAlignment(.center).padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(Theme.field)).frame(maxWidth: .infinity).padding(.vertical, 4)
        case "user":
            HStack { Spacer(minLength: 48); bubble(mine: true) }
        default:
            HStack(alignment: .top, spacing: 8) {
                Group {
                    if firstInRun { BotAvatar(emoji: message.author.emoji ?? "🤖", colour: message.author.colour, size: 30) } else { Color.clear }
                }
                .frame(width: 30, height: firstInRun ? 30 : 1)
                VStack(alignment: .leading, spacing: 4) {
                    if firstInRun {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(message.author.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                            let role = jobTitle(message.author.role)
                            if isGroup, !role.isEmpty {
                                Text(role).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Theme.accent.opacity(0.09)))
                            }
                            Text(message.date.formatted(date: .omitted, time: .shortened)).font(.system(size: 12)).foregroundStyle(Theme.subtle)
                        }
                    }
                    if message.steps > 0 { steps }
                    bubble(mine: false)
                    if let q = message.questions { QuestionCardView(card: q, chatID: chatID, messageID: message.id) }
                    if let a = message.approval { ApprovalCardView(approval: a, chatID: chatID, messageID: message.id) }
                    ForEach(message.cards ?? []) { LiveCardView(card: $0, chatID: chatID) }
                }
                Spacer(minLength: 28)
            }
        }
    }

    private var steps: some View {
        HStack(spacing: 6) {
            if message.isStreaming { ProgressView().controlSize(.mini) } else {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.accent.opacity(0.8))
            }
            Text(message.isStreaming ? (message.step ?? "Working") + "…" : "\(message.steps) step\(message.steps == 1 ? "" : "s")")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary).lineLimit(1)
        }
    }

    @ViewBuilder private func bubble(mine: Bool) -> some View {
        let typing = message.isStreaming && message.text.isEmpty
        let bare = !typing && message.text.isEmpty && message.deleted != true && message.gif == nil && message.poll == nil
            && message.files == nil && message.state != "failed" && (message.questions != nil || message.approval != nil || message.cards != nil)
        if !bare { fullBubble(mine: mine, typing: typing) }
    }

    @ViewBuilder private func fullBubble(mine: Bool, typing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if message.deleted == true {
                Label("This message was deleted", systemImage: "nosign").font(.system(size: 15).italic())
                    .foregroundStyle(mine ? Color.white.opacity(0.8) : Theme.subtle)
            } else if typing {
                TypingDots().padding(.vertical, 4)
            } else {
                if message.gif != nil { Label("GIF", systemImage: "photo").foregroundStyle(mine ? .white : Theme.subtle) }
                if let p = message.poll { Label("Poll: \(p)", systemImage: "chart.bar").foregroundStyle(mine ? .white : Theme.ink) }
                if !message.text.isEmpty {
                    MarkdownText(text: message.text, color: mine ? .white : Theme.ink, accent: mine ? .white : Theme.accent)
                }
                if let files = message.files {
                    ForEach(files, id: \.self) { f in
                        Label(f, systemImage: "doc").font(.system(size: 13, weight: .medium)).lineLimit(1)
                            .foregroundStyle(mine ? .white : Theme.secondary)
                    }
                }
                HStack(spacing: 4) {
                    Spacer(minLength: 0)
                    if message.state == "failed" { Label(message.error ?? "Didn’t finish", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                    Text(message.date.formatted(date: .omitted, time: .shortened))
                }
                .font(.system(size: 11)).foregroundStyle(mine ? Color.white.opacity(0.75) : Theme.subtle)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(mine ? Theme.bubbleMine : Theme.bubbleIn)
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(mine ? Color.clear : Theme.line))
        )
        .overlay(alignment: mine ? .bottomTrailing : .bottomLeading) {
            if let r = message.reactions, !r.isEmpty {
                HStack(spacing: 3) {
                    ForEach(r.sorted { $0.value > $1.value }, id: \.key) { e, n in Text(n > 1 ? "\(e) \(n)" : e).font(.system(size: 13)) }
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(Theme.bubbleIn).shadow(color: .black.opacity(0.08), radius: 3, y: 1))
                .offset(x: mine ? -10 : 10, y: 16)
            }
        }
        .padding(.bottom, (message.reactions?.isEmpty ?? true) ? 0 : 16)
        .contextMenu {
            Button { onReply(message) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
            Button { UIPasteboard.general.string = message.text } label: { Label("Copy", systemImage: "doc.on.doc") }
        }
    }

}

/// Paragraphs, headings, bullet and numbered lists, quotes and code, with inline bold, italics, links and code.
struct MarkdownText: View {
    let text: String
    var color: Color
    var accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                switch b {
                case .para(let t): inline(t)
                case .heading(let t): inline(t).font(.system(size: 17, weight: .bold))
                case .bullet(let t, let level):
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(level == 0 ? "•" : "◦").font(.system(size: 16, weight: .bold)).foregroundStyle(accent.opacity(0.85))
                        inline(t)
                    }
                    .padding(.leading, CGFloat(level) * 14)
                case .number(let n, let t):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(n).").font(.system(size: 16, weight: .semibold)).monospacedDigit().foregroundStyle(accent)
                        inline(t)
                    }
                case .quote(let t):
                    HStack(spacing: 8) { RoundedRectangle(cornerRadius: 2).fill(accent.opacity(0.5)).frame(width: 3); inline(t).opacity(0.85) }
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let t):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(t).font(.system(size: 13, design: .monospaced)).foregroundStyle(color).padding(10)
                    }
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color.opacity(0.08)))
                }
            }
        }
        .textSelection(.enabled)
    }

    enum Block { case para(String), heading(String), bullet(String, Int), number(String, String), quote(String), code(String) }

    private var blocks: [Block] {
        var out: [Block] = []
        var para: [String] = []
        var code: [String]?
        func flush() { if !para.isEmpty { out.append(.para(para.joined(separator: "\n"))); para = [] } }
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if code != nil {
                if t.hasPrefix("```") { out.append(.code(code!.joined(separator: "\n"))); code = nil } else { code!.append(line) }
                continue
            }
            if t.hasPrefix("```") { flush(); code = []; continue }
            if t.isEmpty { flush(); continue }
            let indent = (line.count - line.drop(while: { $0 == " " }).count) / 2
            if let r = t.range(of: #"^#{1,4}\s+"#, options: .regularExpression) { flush(); out.append(.heading(String(t[r.upperBound...]))); continue }
            if t.hasPrefix("> ") { flush(); out.append(.quote(String(t.dropFirst(2)))); continue }
            if let r = t.range(of: #"^[-*•]\s+"#, options: .regularExpression) { flush(); out.append(.bullet(String(t[r.upperBound...]), min(indent, 2))); continue }
            if let r = t.range(of: #"^\d{1,3}[.)]\s+"#, options: .regularExpression) {
                flush(); out.append(.number(String(t[..<r.upperBound].trimmingCharacters(in: .whitespaces).dropLast()), String(t[r.upperBound...]))); continue
            }
            para.append(t)
        }
        if let code { out.append(.code(code.joined(separator: "\n"))) }
        flush()
        return out
    }

    private func inline(_ t: String) -> some View {
        var a = (try? AttributedString(markdown: t, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(t)
        for run in a.runs where run.inlinePresentationIntent?.contains(.code) == true {
            a[run.range].font = .system(size: 15, design: .monospaced)
        }
        return Text(a).font(.system(size: 16)).lineSpacing(2).foregroundStyle(color).tint(accent)
            .fixedSize(horizontal: false, vertical: true)
    }
}
