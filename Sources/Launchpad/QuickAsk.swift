#if os(macOS)
import SwiftUI
import AppKit
import Carbon.HIToolbox
import LaunchpadCore

/// Quick Ask: press ⌃⌥B anywhere to message any bot or group from a floating bar, Spotlight-style.
@MainActor
final class QuickAsk {
    static let shared = QuickAsk()
    static let enabledKey = MacPrefs.quickAsk
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    private var panel: QuickAskPanel?
    private weak var model: AppModel?
    private var hotKey: EventHotKeyRef?
    private var handlerInstalled = false

    func install(model: AppModel) {
        self.model = model
        setEnabled(Self.enabled)
    }

    /// Registers (or removes) the global ⌃⌥B hot key.
    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        guard on else { return }
        if !handlerInstalled {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { QuickAsk.shared.toggle() } }
                return noErr
            }, 1, &type, nil, nil)
            handlerInstalled = true
        }
        let id = EventHotKeyID(signature: OSType(0x4C50_5141), id: 1) // "LPQA"
        RegisterEventHotKey(UInt32(kVK_ANSI_B), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }

    func toggle() {
        if let panel, panel.isVisible { close() } else { show() }
    }

    func show() {
        guard let model else { return }
        let panel = self.panel ?? QuickAskPanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: QuickAskView(close: { [weak self] in self?.close() })
            .environment(model)
            .tint(Theme.accent))
        panel.setContentSize(NSSize(width: 700, height: 460))
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: f.midX - 350, y: f.maxY - f.height * 0.16))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
        panel?.contentView = nil
    }
}

/// A borderless floating panel that can take typing without bringing Launchpad's windows forward.
final class QuickAskPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 700, height: 460), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        MainActor.assumeIsolated { QuickAsk.shared.close() }
    }
}

private struct QuickAskView: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void
    @State private var text = ""
    @State private var target: Routine.Target?
    @State private var sent: (chatId: String, messageId: String)?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: MenuBarIcon.image)
                    .renderingMode(.template)
                    .foregroundStyle(Theme.accent)
                TextField(sent == nil ? "Ask your team anything…" : "Ask a follow-up…", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .focused($focused)
                    .onSubmit(send)
                targetMenu
            }
            .padding(.horizontal, 16)
            .frame(height: 58)
            if let sent {
                Divider()
                replies(sent)
            }
            Divider()
            HStack {
                Text("⌃⌥B to open or close · Return to send · Esc to close")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                Spacer()
                if let sent {
                    Button("Open Chat") {
                        model.show(chat: sent.chatId)
                        MainWindow.bringForward()
                        close()
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 640)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.canvas))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
        .padding(30)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear {
            if target == nil { target = model.defaultQuickAskTarget }
            focused = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = true }
        }
        .onExitCommand(perform: close)
    }

    private var targetMenu: some View {
        Menu {
            if !model.bots.isEmpty {
                Section("Bots") {
                    ForEach(model.bots) { b in
                        Button("\(b.emoji) \(b.name)") { pick(.bot(b.id)) }
                    }
                }
            }
            if !model.groups.isEmpty {
                Section("Groups") {
                    ForEach(model.groups) { g in
                        Button(g.displayName) { pick(.group(g.id)) }
                    }
                }
            }
        } label: {
            Text(targetLabel)
                .lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .help("Who to ask")
    }

    private var targetLabel: String {
        switch target {
        case .bot(let id)?: return model.bot(id).map { "\($0.emoji) \($0.name)" } ?? "Pick a bot"
        case .group(let id)?: return model.group(id)?.displayName ?? "Pick a group"
        case nil: return model.bots.isEmpty ? "No bots yet" : "Pick a bot"
        }
    }

    private func pick(_ t: Routine.Target) {
        if t != target { sent = nil }
        target = t
        focused = true
    }

    @ViewBuilder private func replies(_ s: (chatId: String, messageId: String)) -> some View {
        let replies = model.replies(after: s.messageId, in: s.chatId)
        let working = model.isRunning(s.chatId)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if working && replies.allSatisfy({ $0.text.isEmpty }) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(WorkSummary.line(for: replies.last)).foregroundStyle(Theme.secondary)
                    }
                }
                ForEach(replies) { r in
                    if !r.text.isEmpty || r.failure != nil {
                        VStack(alignment: .leading, spacing: 4) {
                            if replies.count > 1 || model.chat(s.chatId)?.kind == .group {
                                Text(model.authorName(r)).font(.caption.weight(.bold)).foregroundStyle(Theme.secondary)
                            }
                            Text(markdown(r.text.isEmpty ? (r.failure?.message ?? "") : r.text))
                                .foregroundStyle(r.status == .failed ? Theme.failure : Color.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if let reason = Attention.reason(r) {
                        Label("\(reason). Open the chat to answer.", systemImage: "hand.raised.fill")
                            .font(.callout)
                            .foregroundStyle(Theme.warning)
                    }
                }
            }
            .padding(16)
        }
        .frame(maxHeight: 300)
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    private func send() {
        guard let target, let out = model.quickAsk(text, to: target) else { return }
        sent = out
        text = ""
    }
}
#endif
