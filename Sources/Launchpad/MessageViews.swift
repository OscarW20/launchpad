#if os(macOS)
import SwiftUI
import AppKit
import Combine
import LaunchpadCore

struct MessageRow: View {
    @Environment(AppModel.self) private var model
    let message: ChatMessage
    let chatId: String
    var activeStep: Step? = nil
    /// Still streaming: no menu yet.
    var isLive = false
    @State private var editing = false

    var body: some View {
        content
            .contextMenu {
                if !isLive && message.role != .notice && message.deleted != true {
                    MessageMenu(message: message, chatId: chatId, editing: $editing)
                }
            }
            .sheet(isPresented: $editing) { EditMessageSheet(message: message, chatId: chatId) }
    }

    @ViewBuilder private var content: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 80)
                VStack(alignment: .trailing, spacing: 4) {
                    if let from = message.forwardedFrom {
                        Label("Forwarded from \(from)", systemImage: "arrowshape.turn.up.right")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if message.deleted == true {
                        DeletedBubble()
                    } else {
                        if !message.text.isEmpty {
                            Text(message.text)
                                .textSelection(.enabled)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(message.isSide == true ? Theme.raised : Theme.userBubble,
                                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        if let gif = message.gif { GifView(gif: gif) }
                        if let poll = message.poll { PollView(poll: poll, messageId: message.id, chatId: chatId) }
                        if let files = message.attachments, !files.isEmpty {
                            FileChips(urls: files.map { URL(fileURLWithPath: $0) })
                        }
                        ReactionsBar(message: message, chatId: chatId)
                    }
                    MessageMeta(message: message, alignment: .trailing)
                }
            }
        case .notice:
            HStack {
                Spacer()
                VStack(spacing: 6) {
                    Label(message.text, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if let action = message.noticeAction {
                        switch action {
                        case .continueGroup:
                            if message.id == model.messages(for: chatId).last?.id {
                                Button("Keep going") { model.perform(action, chatId: chatId) }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .disabled(model.isRunning(chatId))
                            }
                        case .undoMemory:
                            Button("Undo") { model.undoMemoryUpdate(noticeId: message.id, chatId: chatId) }
                                .controlSize(.small)
                        }
                    }
                }
                Spacer()
            }
        case .bot:
            BotMessageView(message: message, chatId: chatId, activeStep: activeStep)
        }
    }
}

struct DeletedBubble: View {
    var body: some View {
        Label("This message was deleted", systemImage: "trash")
            .font(.callout.italic())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4])))
    }
}

/// Time, plus edited / pinned / saved / side-question marks.
struct MessageMeta: View {
    let message: ChatMessage
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        HStack(spacing: 5) {
            if message.isSide == true { Text("Side question").fontWeight(.medium) }
            if message.pinned == true { Image(systemName: "pin.fill") }
            if message.saved == true { Image(systemName: "bookmark.fill") }
            Text(TimeLabel.clock(message.createdAt))
            if ChatOps.isEdited(message) { Text("· edited") }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
}

struct BotMessageView: View {
    @Environment(AppModel.self) private var model
    let message: ChatMessage
    let chatId: String
    let activeStep: Step?

    var body: some View {
        let bot = model.bot(message.botId)
        let live = message.status == .streaming
        HStack(alignment: .top, spacing: 10) {
            AvatarView(bot: bot, size: 30)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(bot?.name ?? "Bot")
                        .font(Theme.rounded(.subheadline, weight: .semibold))
                    MessageMeta(message: message)
                    if message.status == .stopped {
                        Pill(text: "Stopped", symbol: "stop.circle")
                    }
                }

                if message.deleted == true {
                    DeletedBubble()
                } else {
                    if let todos = message.todos, !todos.isEmpty {
                        TodoListView(items: todos)
                    }

                    if !message.steps.isEmpty {
                        StepsView(steps: message.steps, isLive: live)
                    }

                    if !message.text.isEmpty {
                        MarkdownView(text: message.text)
                    }

                    if let gif = message.gif { GifView(gif: gif) }
                    if let plan = message.plan { PlanCardView(card: plan, messageId: message.id, chatId: chatId) }
                    if let questions = message.questions {
                        QuestionCardView(card: questions, messageId: message.id, chatId: chatId)
                    }
                    if let poll = message.poll { PollView(poll: poll, messageId: message.id, chatId: chatId) }

                    if live {
                        TypingIndicator(label: activeStep.map { StepLabel.describe($0).text } ?? (message.text.isEmpty ? "Thinking…" : nil))
                    } else if !message.text.isEmpty {
                        FileMentionChips(message: message, chatId: chatId)
                    }

                    if let failure = message.failure {
                        FailureCard(failure: failure)
                    }

                    if let cards = message.liveApprovals {
                        ForEach(cards) { card in
                            LiveApprovalCardView(card: card, chatId: chatId, botId: message.botId)
                        }
                    }

                    if let approval = message.approval {
                        ApprovalCard(request: approval, messageId: message.id, chatId: chatId)
                    }

                    if !live, message.snapshot != nil, !(message.changedFiles ?? []).isEmpty {
                        ReplyChangesBar(message: message, chatId: chatId)
                    }
                    ReactionsBar(message: message, chatId: chatId)
                }
            }
            .padding(12)
            .background(message.isSide == true ? Theme.raised.opacity(0.5) : Theme.surface,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.border))
            Spacer(minLength: 40)
        }
    }
}

// MARK: - Steps

struct StepsView: View {
    let steps: [Step]
    let isLive: Bool
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(steps) { step in
                    StepRow(step: step)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                Text(summary)
                if isLive && steps.contains(where: { $0.status == .running }) {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.raised.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var summary: String {
        let n = steps.count
        let failed = steps.filter { $0.status == .failed }.count
        var s = "\(n) step\(n == 1 ? "" : "s")"
        if failed > 0 { s += " · \(failed) didn't work" }
        return s
    }
}

struct StepRow: View {
    let step: Step
    @State private var expanded = false

    var body: some View {
        if hasMore {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 6) {
                    if let detail = step.detail {
                        StepTextBox(title: "Input", text: detail)
                    }
                    if let output = step.output {
                        StepTextBox(title: "Result", text: output)
                    }
                }
                .padding(.leading, 22)
                .padding(.top, 4)
            } label: {
                label
                    .contentShape(Rectangle())
                    .onTapGesture { expanded.toggle() }
            }
        } else {
            label
        }
    }

    private var hasMore: Bool { step.detail != nil || step.output != nil }

    private var label: some View {
        let described = StepLabel.describe(step)
        return HStack(spacing: 6) {
            statusIcon
                .frame(width: 14)
            Image(systemName: described.icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            InlineText(described.text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.callout)
        .help(step.title)
    }

    @ViewBuilder private var statusIcon: some View {
        switch step.status {
        case .running:
            ProgressView().controlSize(.mini)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.failure)
        case .stopped:
            Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }

}

struct StepTextBox: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            .padding(8)
            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - Typing indicator

struct TypingIndicator: View {
    let label: String?
    @State private var phase = 0
    private let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 6, height: 6)
                        .opacity(phase == i ? 1 : 0.3)
                }
            }
            if let label {
                InlineText(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .onReceive(timer) { _ in phase = (phase + 1) % 3 }
    }
}

// MARK: - Approval card

struct ApprovalCard: View {
    @Environment(AppModel.self) private var model
    let request: ApprovalRequest
    let messageId: String
    let chatId: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Needs your OK")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    InlineText(request.action)
                        .font(.body.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            switch request.status {
            case .pending:
                HStack(spacing: 10) {
                    Button {
                        model.respond(to: messageId, in: chatId, approve: true)
                    } label: {
                        Label("Approve", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        model.respond(to: messageId, in: chatId, approve: false)
                    } label: {
                        Label("Decline", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.regular)
                .disabled(model.isRunning(chatId))
            case .approved:
                Label("Approved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.success)
                    .font(.callout.weight(.medium))
            case .declined:
                Label("Declined", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.callout.weight(.medium))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.accent.opacity(0.35)))
    }
}

// MARK: - Failure card

struct FailureCard: View {
    @Environment(AppModel.self) private var model
    let failure: RunFailure
    @State private var showDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(Theme.warning)
                if let action = failure.action {
                    Button {
                        model.perform(action)
                    } label: {
                        Text(failure.message)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in
                        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                } else {
                    Text(failure.message)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 12) {
                if let action = failure.action {
                    Button(action.label) { model.perform(action) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                if failure.detail != nil {
                    Button(showDetail ? "Hide details" : "Show details") { showDetail.toggle() }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
            }
            if showDetail, let detail = failure.detail {
                Text(detail)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var icon: String {
        switch failure.kind {
        case .signedOut: return "person.crop.circle.badge.exclamationmark"
        case .cliMissing: return "shippingbox"
        case .usageLimit: return "hourglass"
        case .network: return "wifi.exclamationmark"
        case .overloaded: return "tortoise"
        case .sessionLost: return "arrow.counterclockwise"
        case .unknown: return "exclamationmark.triangle"
        }
    }
}

// MARK: - Markdown

struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownParser.blocks(text).enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case let .heading(level, text):
            InlineText(text)
                .font(level == 1 ? Theme.rounded(.title2, weight: .bold)
                      : level == 2 ? Theme.rounded(.title3, weight: .bold)
                      : Theme.rounded(.headline, weight: .semibold))
                .padding(.top, 4)
        case .paragraph(let text):
            InlineText(text)
                .fixedSize(horizontal: false, vertical: true)
        case let .code(language, code):
            CodeBlockView(language: language, code: code)
        case let .list(_, items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let checked = item.checked {
                            Image(systemName: checked ? "checkmark.square.fill" : "square")
                                .foregroundStyle(checked ? AnyShapeStyle(Theme.success) : AnyShapeStyle(.secondary))
                        } else {
                            Text(item.marker)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        InlineText(item.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.indent) * 16)
                }
            }
        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.accent.opacity(0.5))
                    .frame(width: 3)
                InlineText(text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
        case let .table(header, rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        ForEach(header.indices, id: \.self) { i in
                            InlineText(header[i]).fontWeight(.semibold)
                        }
                    }
                    Divider()
                    ForEach(rows.indices, id: \.self) { r in
                        GridRow {
                            ForEach(rows[r].indices, id: \.self) { c in
                                InlineText(rows[r][c])
                            }
                        }
                    }
                }
                .padding(10)
            }
            .background(Theme.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .rule:
            Divider()
        }
    }
}

/// Inline markdown: **bold**, _italic_, `code` and [links](https://…).
struct InlineText: View {
    let source: String

    init(_ source: String) {
        self.source = source
    }

    var body: some View {
        Text(Self.attributed(source))
    }

    static func attributed(_ s: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
    }
}

struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .font(.system(.caption, design: .monospaced))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(Theme.codeMuted)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(Theme.codeText)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
#endif
