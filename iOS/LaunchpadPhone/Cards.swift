import SwiftUI

/// Questions a bot asked as tappable choices. Your picks go back to it as your next message.
struct QuestionCardView: View {
    @Environment(MacLink.self) private var link
    let card: Message.Questions
    let chatID: String
    let messageID: String
    @State private var picks: [Int: Set<String>] = [:]
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(card.items.enumerated()), id: \.offset) { i, item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.text).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                    if card.answered {
                        Text(card.answers?[safe: i] ?? "Answered").font(.system(size: 14)).foregroundStyle(Theme.subtle)
                    } else {
                        FlowChoices(options: item.options, selected: picks[i] ?? []) { option in
                            var set = picks[i] ?? []
                            if item.multi {
                                if set.contains(option) { set.remove(option) } else { set.insert(option) }
                            } else {
                                set = [option]
                            }
                            picks[i] = set
                        }
                    }
                }
            }
            if !card.answered {
                if let problem { Text(problem).font(.system(size: 13)).foregroundStyle(Theme.danger) }
                Button {
                    Task { await send() }
                } label: {
                    if busy { ProgressView() } else { Text("Send answers") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || !complete)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.bubbleIn))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line))
    }

    private var complete: Bool { card.items.indices.allSatisfy { !(picks[$0] ?? []).isEmpty } }

    private func send() async {
        busy = true
        defer { busy = false }
        let answers = card.items.enumerated().map { i, item in
            item.options.filter { (picks[i] ?? []).contains($0) }.joined(separator: ", ")
        }
        problem = await link.answer(chatID, message: messageID, answers: answers)
    }
}

/// Wrapping row of choice chips.
struct FlowChoices: View {
    let options: [String]
    let selected: Set<String>
    let tap: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(options, id: \.self) { option in
                Button { tap(option) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: selected.contains(option) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(option) ? Theme.accent : Theme.subtle)
                        Text(option).font(.system(size: 15)).foregroundStyle(Theme.ink).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(selected.contains(option) ? Theme.soft : Theme.field))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// "Can I do this?" from a bot (asked in its reply): Approve or Decline.
struct ApprovalCardView: View {
    @Environment(MacLink.self) private var link
    let approval: Message.Approval
    let chatID: String
    let messageID: String
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Asks to: \(approval.action)", systemImage: "hand.raised.fill")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
            switch approval.status {
            case "approved": Text("Approved").foregroundStyle(.green)
            case "declined": Text("Declined").foregroundStyle(Theme.subtle)
            default:
                HStack {
                    Button("Approve") { Task { problem = await link.answer(chatID, message: messageID, approve: true) } }
                        .buttonStyle(.borderedProminent)
                    Button("Decline", role: .destructive) { Task { problem = await link.answer(chatID, message: messageID, approve: false) } }
                        .buttonStyle(.bordered)
                }
                if let problem { Text(problem).font(.system(size: 13)).foregroundStyle(Theme.danger) }
            }
        }
        .font(.system(size: 14))
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.bubbleIn))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line))
    }
}

/// A live approval card from the safety guard: the bot is waiting for your answer.
struct LiveCardView: View {
    @Environment(MacLink.self) private var link
    let card: Message.Card
    let chatID: String
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(card.title, systemImage: "lock.shield.fill")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.subtle)
            Text(card.tool).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
            if !card.detail.isEmpty {
                Text(card.detail).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.ink)
                    .lineLimit(8).textSelection(.enabled)
            }
            switch card.state {
            case "pending":
                HStack {
                    Button("Approve") { answer("approve") }.buttonStyle(.borderedProminent)
                    Button("Decline", role: .destructive) { answer("deny") }.buttonStyle(.bordered)
                    if card.canAlways {
                        Button("Always") { answer("always") }.buttonStyle(.bordered)
                    }
                }
                if let problem { Text(problem).font(.system(size: 13)).foregroundStyle(Theme.danger) }
            case "approved": Text("Approved").font(.system(size: 14)).foregroundStyle(.green)
            case "always": Text("Always allowed").font(.system(size: 14)).foregroundStyle(.green)
            case "denied": Text("Declined").font(.system(size: 14)).foregroundStyle(Theme.subtle)
            default: Text("Expired").font(.system(size: 14)).foregroundStyle(Theme.subtle)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.bubbleIn))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(card.state == "pending" ? Theme.accent : Theme.line))
    }

    private func answer(_ decision: String) {
        Task { problem = await link.answer(chatID, card: card.id, decision: decision) }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
