import SwiftUI

struct ChatListView: View {
    @Environment(MacLink.self) private var link
    @State private var filter = "All"
    @State private var search = ""
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                if let error = link.lastError {
                    Label(error, systemImage: "wifi.exclamationmark")
                        .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                        .listRowBackground(Theme.soft)
                }
                Section {
                    Picker("", selection: $filter) {
                        ForEach(["All", "Unread", "Bots", "Groups"], id: \.self) { Text($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
                }
                Section {
                    ForEach(visible) { row($0) }
                }
                if link.state == nil && link.lastError == nil {
                    HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.canvas.ignoresSafeArea())
            .navigationTitle("Chats")
            .searchable(text: $search, prompt: "Search chats")
            .refreshable { await link.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: link.connected ? "laptopcomputer" : "laptopcomputer.trianglebadge.exclamationmark")
                    }
                    .accessibilityLabel("Your Mac")
                }
            }
            .navigationDestination(for: String.self) { id in ChatView(chatID: id) }
            .sheet(isPresented: $showSettings) { MacSheet() }
        }
    }

    private var visible: [ChatInfo] {
        var list = link.state?.chats ?? []
        switch filter {
        case "Unread": list = list.filter { $0.unread > 0 }
        case "Bots": list = list.filter { !$0.isGroup }
        case "Groups": list = list.filter(\.isGroup)
        default: break
        }
        if !search.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(search) || ($0.last?.text.localizedCaseInsensitiveContains(search) ?? false) } }
        return list.sorted { a, b in
            if a.isGroup != b.isGroup, a.last == nil || b.last == nil { return a.isGroup }
            return a.lastDate > b.lastDate
        }
    }

    private func row(_ chat: ChatInfo) -> some View {
        NavigationLink(value: chat.id) {
            HStack(spacing: 12) {
                ChatAvatar(chat: chat, size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(chat.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                            .layoutPriority(1)
                        let tag = chat.isGroup ? "Group" : jobTitle(chat.role)
                        if !tag.isEmpty {
                            Text(tag).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary).lineLimit(1)
                                .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(Theme.accent.opacity(0.09)))
                        }
                        Spacer(minLength: 4)
                        if chat.last != nil {
                            Text(shortTime(chat.lastDate)).font(.system(size: 13))
                                .foregroundStyle(chat.unread > 0 ? Theme.accent : Theme.subtle)
                        }
                    }
                    HStack(alignment: .top) {
                        Group {
                            if let typer = chat.typing.first {
                                Text(chat.isGroup ? "\(typer) is typing…" : "typing…").foregroundStyle(Theme.accent)
                            } else if let last = chat.last {
                                Text(chat.isGroup && last.from != "You" ? "\(last.from): \(last.text)" : last.text).foregroundStyle(Theme.subtle)
                            } else {
                                Text(chat.isGroup ? "\(chat.members?.count ?? 0) bots · No messages yet" : "No messages yet").foregroundStyle(Theme.subtle)
                            }
                        }
                        .font(.system(size: 15)).lineLimit(2)
                        Spacer(minLength: 4)
                        if chat.unread > 0 {
                            Text("\(chat.unread)").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 7).frame(minWidth: 22, minHeight: 22).background(Capsule().fill(Theme.accent))
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .listRowBackground(Theme.bubbleIn)
    }
}

/// Which Mac this phone is paired with, and a way out.
struct MacSheet: View {
    @Environment(MacLink.self) private var link
    @Environment(\.dismiss) private var dismiss
    @State private var confirm = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "laptopcomputer").font(.system(size: 26)).foregroundStyle(Theme.accent)
                            .frame(width: 52, height: 52).background(Circle().fill(Theme.soft))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(link.macName.isEmpty ? "Your Mac" : link.macName).font(.system(size: 18, weight: .semibold))
                            Label(link.connected ? "Connected" : "Not reachable right now", systemImage: "circle.fill")
                                .labelStyle(StatusLabel(on: link.connected))
                        }
                    }
                    .padding(.vertical, 6)
                } footer: {
                    Text("Your bots run on this Mac. Keep Launchpad open there with Mobile switched on, on the same Wi-Fi or Tailscale.")
                }
                Section {
                    Button("Disconnect this phone", role: .destructive) { confirm = true }
                }
            }
            .navigationTitle("Your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Disconnect from \(link.macName)?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) { link.unpair(); dismiss() }
            } message: { Text("You can pair again with a new code from your Mac.") }
        }
        .presentationDetents([.medium])
    }
}

struct StatusLabel: LabelStyle {
    let on: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 7)).foregroundStyle(on ? Color.green : Color.orange)
            configuration.title.font(.system(size: 14)).foregroundStyle(Theme.subtle)
        }
    }
}
