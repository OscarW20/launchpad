import SwiftUI

@main
struct LaunchpadPhoneApp: App {
    @State private var link = MacLink()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            Group {
                if link.isPaired { ChatListView() } else { PairView() }
            }
            .environment(link)
            .tint(Theme.accent)
            .onChange(of: phase) { _, p in
                if p == .active { link.start() } else if p == .background { link.pause() }
            }
            .task {
                #if DEBUG
                // Test hook: launch with -autopair <url> <code> to pair without typing (simulator runs).
                let args = ProcessInfo.processInfo.arguments
                if let i = args.firstIndex(of: "-autopair"), args.count > i + 2, let url = URL(string: args[i + 1]) {
                    try? await link.pair(with: url, code: args[i + 2])
                }
                #endif
                link.start()
            }
        }
    }
}

/// A bot's emoji on its colour, as on the Mac.
struct BotAvatar: View {
    let emoji: String
    let colour: String?
    var size: CGFloat = 44

    init(bot: BotInfo?, size: CGFloat = 44) {
        emoji = bot?.emoji ?? "🤖"
        colour = bot?.colour
        self.size = size
    }

    init(emoji: String, colour: String?, size: CGFloat = 44) {
        self.emoji = emoji
        self.colour = colour
        self.size = size
    }

    var body: some View {
        ZStack {
            Circle().fill(colour.map { Color(hex: $0).opacity(0.28) } ?? Theme.field)
            Text(emoji).font(.system(size: size * 0.52))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Group photo: the lead and one member overlapping, like iMessage.
struct GroupAvatar: View {
    @Environment(MacLink.self) private var link
    let chat: ChatInfo
    var size: CGFloat = 52

    var body: some View {
        let members = chat.members ?? []
        let a = link.bot(members.first), b = link.bot(members.dropFirst().first)
        if members.count < 2 {
            BotAvatar(emoji: chat.emoji, colour: a?.colour, size: size)
        } else {
            ZStack(alignment: .topLeading) {
                BotAvatar(bot: a, size: size * 0.68)
                BotAvatar(bot: b, size: size * 0.68)
                    .background(Circle().fill(Theme.canvas).padding(-2.5))
                    .offset(x: size * 0.32, y: size * 0.32)
            }
            .frame(width: size, height: size, alignment: .topLeading)
        }
    }
}

struct ChatAvatar: View {
    let chat: ChatInfo
    var size: CGFloat = 52
    var body: some View {
        if chat.isGroup { GroupAvatar(chat: chat, size: size) } else { BotAvatar(emoji: chat.emoji, colour: chat.colour, size: size) }
    }
}

/// "Design lead · Figma" -> "Design lead".
func jobTitle(_ role: String?) -> String {
    guard var r = role?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty else { return "" }
    for sep in [" · ", " - ", " — ", ",", "."] { if let i = r.range(of: sep) { r = String(r[..<i.lowerBound]) } }
    return r.count > 26 ? String(r.prefix(24)) + "…" : r
}

func shortTime(_ d: Date) -> String {
    if Calendar.current.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
    if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
    return d.formatted(.dateTime.day().month(.abbreviated))
}
