#if os(macOS)
import SwiftUI
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import LaunchpadCore

// Create ticket: select text in any app, then right-click › Services › "Create ticket with Claude" or press ⌃⌥T, and a
// panel drafts and files a Jira ticket. The settings, prompt and result checks are in LaunchpadCore (Tickets/);
// this file is the macOS side: the Service, the hotkey, reading the selection, and following the run.

// MARK: - Service

/// Receives "Create ticket with Claude" from the Services menu (`NSServices` in Info.plist, message `createTicket`).
/// The selected text arrives on the pasteboard, so this needs no extra permission.
final class TicketServiceProvider: NSObject {
    static let shared = TicketServiceProvider()

    @objc func createTicket(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let text = pasteboard.string(forType: .string) ?? ""
        let front = NSWorkspace.shared.frontmostApplication
        let app = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front
        MainActor.assumeIsolated {
            TicketCenter.shared.receive(Capture(text: text, app: app?.localizedName, window: SelectionReader.windowTitle(of: app)))
        }
    }
}

/// What was captured, before the panel opens.
struct Capture {
    var text: String
    var app: String?
    var window: String?
    /// The hotkey was used but Launchpad isn't allowed to read other apps' selections.
    var needsAccessibility = false
}

// MARK: - Reading the selection (hotkey)

/// The hotkey has no pasteboard to read, so it asks the app in front for its selected text: through Accessibility
/// when that's allowed (the selection, nothing else touched), else by pressing ⌘C and putting your clipboard back.
/// Both need "Accessibility" in System Settings, so without it the panel opens empty and says why.
@MainActor
enum SelectionReader {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func capture(from app: NSRunningApplication?) async -> Capture {
        let name = app?.localizedName
        guard trusted else { return Capture(text: "", app: name, window: nil, needsAccessibility: true) }
        var text = app.flatMap { selectedText(pid: $0.processIdentifier) }
        if text?.isEmpty ?? true { text = await copySelection() }
        return Capture(text: text ?? "", app: name, window: windowTitle(of: app))
    }

    /// The window's title, when Accessibility is allowed. Best effort: nothing needs it.
    static func windowTitle(of app: NSRunningApplication?) -> String? {
        guard trusted, let pid = app?.processIdentifier else { return nil }
        let element = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
    }

    private static func selectedText(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// ⌘C, read, and put the clipboard back as it was.
    private static func copySelection() async -> String? {
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        // The hotkey's own ⌃ and ⌥ are still down: wait for them, or the copy arrives as ⌃⌥⌘C.
        for _ in 0..<50 where !NSEvent.modifierFlags.intersection([.control, .option]).isEmpty {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let before = board.changeCount
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
        var text: String?
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if board.changeCount != before { text = board.string(forType: .string); break }
        }
        if board.changeCount != before {
            board.clearContents()
            let items = saved.map { entries -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in entries { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { board.writeObjects(items) }
        }
        return text
    }
}

// MARK: - The panel

/// A floating panel that takes typing without bringing Launchpad's windows forward (like Quick Ask's).
final class TicketPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 660, height: 560), styleMask: [.borderless, .nonactivatingPanel],
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
        MainActor.assumeIsolated { TicketCenter.shared.closePanel() }
    }
}

// MARK: - State

/// What's being typed in the panel, and the run it started.
@MainActor
@Observable
final class TicketPanelState {
    var selection: String
    var note = ""
    var assigneeId: String?
    let sourceApp: String?
    let sourceWindow: String?
    let needsAccessibility: Bool
    /// The ticket's chat, once it has one, so a retry stays in it.
    var chatId: String?
    var run: TicketRun?
    /// A problem with the last thing pressed (the import failed, the prompt couldn't be built).
    var error: String?

    init(_ capture: Capture, assigneeId: String?) {
        selection = capture.text
        sourceApp = capture.app
        sourceWindow = capture.window
        needsAccessibility = capture.needsAccessibility
        self.assigneeId = assigneeId
    }
}

/// One attempt to file a ticket. Followed by the center, not the panel, so closing the panel doesn't lose the result.
@MainActor
@Observable
final class TicketRun {
    enum Phase: Equatable {
        case working
        case done(TicketResult, duplicate: Bool)
        case failed(String)
    }

    let chatId: String
    let messageId: String
    let botId: String
    let settings: TicketSettings
    var phase: Phase = .working

    init(chatId: String, messageId: String, botId: String, settings: TicketSettings) {
        self.chatId = chatId
        self.messageId = messageId
        self.botId = botId
        self.settings = settings
    }
}

// MARK: - The center

@MainActor
@Observable
final class TicketCenter {
    static let shared = TicketCenter()
    static let enabledKey = "ticketHotKey"
    static let letterKey = "ticketHotKeyLetter"
    static let botKey = "ticketBot"
    static let assigneeKey = "ticketLastAssignee"
    private static let signature = OSType(0x4C50_544B) // "LPTK"

    private(set) var settings = TicketSettings()
    private(set) weak var model: AppModel?
    private(set) var draft: TicketPanelState?
    private var panel: TicketPanel?
    private var store: TicketSettingsStore?
    private var hotKey: EventHotKeyRef?
    private var handlerInstalled = false
    private var pending: Capture?
    /// Chats with a ticket being filed now: the only place "File without asking" lets the Jira create call through.
    private var activeChats = Set<String>()

    static var hotkeyEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static var hotkeyLetter: String { TicketHotkey.normalised(UserDefaults.standard.string(forKey: letterKey)) }

    func install(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        store = TicketSettingsStore(paths: model.paths)
        settings = store?.load() ?? TicketSettings()
        registerHotKey()
        NSUpdateDynamicServices()
        if let capture = pending {
            pending = nil
            receive(capture)
        }
    }

    // MARK: Settings

    func update(_ change: (inout TicketSettings) -> Void) {
        var next = settings
        change(&next)
        next.maxSelectionCharacters = min(max(next.maxSelectionCharacters, TicketSettings.selectionLimits.lowerBound),
                                          TicketSettings.selectionLimits.upperBound)
        settings = next
        do { try store?.save(next) } catch { model?.alertMessage = "Couldn't save the ticket settings: \(error.localizedDescription)" }
    }

    /// The bots that can file a ticket: Claude bots with the Jira connector.
    var candidateBots: [Bot] {
        guard let model else { return [] }
        return TicketConnector.bots(model.bots, groups: model.groups, connectors: model.connectors)
    }

    var chosenBot: Bot? {
        TicketConnector.choose(preferred: UserDefaults.standard.string(forKey: Self.botKey), from: candidateBots)
    }

    var problems: [TicketProblem] {
        TicketProblem.check(settings: settings, jiraConnected: chosenBot != nil, skillInstalled: model?.skill(settings.skillId) != nil)
    }

    /// The Always-allow entries a run in this chat gets: the Jira create call, in "File without asking" mode only.
    func guardAllowances(forChat chatId: String) -> [String] {
        activeChats.contains(chatId) ? TicketGuard.allowances(for: settings) : []
    }

    // MARK: Hotkey

    func registerHotKey() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        guard Self.hotkeyEnabled else { return }
        if !handlerInstalled {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard id.signature == TicketCenter.signature else { return OSStatus(eventNotHandledErr) }
                DispatchQueue.main.async { MainActor.assumeIsolated { TicketCenter.shared.hotKeyPressed() } }
                return noErr
            }, 1, &type, nil, nil)
            handlerInstalled = true
        }
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        RegisterEventHotKey(TicketHotkey.keyCode(for: Self.hotkeyLetter), UInt32(controlKey | optionKey), id,
                            GetApplicationEventTarget(), 0, &hotKey)
    }

    private func hotKeyPressed() {
        let front = NSWorkspace.shared.frontmostApplication
        let app = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front
        Task { receive(await SelectionReader.capture(from: app)) }
    }

    // MARK: Panel

    /// A selection arrived (from the Service or the hotkey): open the panel with it.
    func receive(_ capture: Capture) {
        guard model != nil else {
            pending = capture   // the Service started the app: show it once the app is ready
            return
        }
        let remembered = UserDefaults.standard.string(forKey: Self.assigneeKey)
        let draft = TicketPanelState(capture, assigneeId: settings.assignee(id: remembered)?.id)
        self.draft = draft
        present(draft)
    }

    private func present(_ draft: TicketPanelState) {
        guard let model else { return }
        let panel = self.panel ?? TicketPanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: TicketPanelView(draft: draft, close: { [weak self] in self?.closePanel() })
            .environment(model)
            .tint(Theme.accent))
        panel.setContentSize(NSSize(width: 660, height: 560))
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: f.midX - 330, y: f.maxY - f.height * 0.1))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func closePanel() {
        panel?.orderOut(nil)
        panel?.contentView = nil
    }

    // MARK: Filing

    /// Hands the ticket to a bot (a chat of its own, so the work is there to see) and follows it to the end.
    func file(_ draft: TicketPanelState) {
        guard let model else { return }
        if let run = draft.run {
            // Only a failed attempt can be tried again; a ticket that's being filed or was filed isn't filed twice.
            guard case .failed = run.phase else { return }
        }
        draft.error = nil
        let assignee = settings.assignee(id: draft.assigneeId)
        UserDefaults.standard.set(assignee?.id ?? "", forKey: Self.assigneeKey)
        let request = TicketRequest(selectedText: draft.selection, sourceApp: draft.sourceApp, sourceWindow: draft.sourceWindow,
                                    note: draft.note, assignee: assignee)
        let built: TicketDraft
        do { built = try TicketPrompt.build(request: request, settings: settings, skill: model.skill(settings.skillId)) } catch {
            draft.error = error.localizedDescription
            return
        }
        guard let bot = chosenBot else {
            draft.error = TicketProblem.jiraNotConnected.message
            return
        }
        let chatId: String
        if let existing = draft.chatId {
            chatId = existing
        } else {
            do {
                var meta = try model.chatStore.createChat(with: bot)
                meta.title = TicketPrompt.chatTitle(built.preview)
                try model.chatStore.save(meta)
                model.reloadChats()
                chatId = meta.id
            } catch {
                draft.error = "Couldn't start a chat for the ticket: \(error.localizedDescription)"
                return
            }
            draft.chatId = chatId
        }
        let message = ChatMessage(role: .user, text: TicketPrompt.chatText(built.preview, assignee: assignee))
        let run = TicketRun(chatId: chatId, messageId: message.id, botId: bot.id, settings: settings)
        draft.run = run
        activeChats.insert(chatId)   // before the run starts: the guard's rules are written as it begins
        model.submit(message, prompt: built.prompt, to: chatId)
        follow(run)
    }

    private func follow(_ run: TicketRun) {
        Task { [weak self] in
            var quiet = 0
            while let self, let model = self.model {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if model.isRunning(run.chatId) { quiet = 0; continue }
                let reply = model.replies(after: run.messageId, in: run.chatId).last { $0.role == .bot }
                if let reply, reply.status != .streaming {
                    self.finish(run, reply: reply)
                    return
                }
                quiet += 1
                if quiet >= 8 {
                    self.finish(run, phase: .failed("\(model.bot(run.botId)?.name ?? "The bot") didn't reply, so no ticket was created. Open the chat to see why."))
                    return
                }
            }
        }
    }

    private func finish(_ run: TicketRun, reply: ChatMessage) {
        switch reply.status {
        case .failed:
            finish(run, phase: .failed(reply.failure?.message ?? "The bot's run failed, so no ticket was created."))
        case .stopped:
            finish(run, phase: .failed("The run was stopped, so no ticket was created."))
        default:
            switch TicketOutcome.parse(reply: reply.text, settings: run.settings) {
            case .created(let result): finish(run, phase: .done(result, duplicate: false))
            case .duplicate(let result): finish(run, phase: .done(result, duplicate: true))
            case .failed(let why): finish(run, phase: .failed(why))
            }
        }
    }

    private func finish(_ run: TicketRun, phase: TicketRun.Phase) {
        activeChats.remove(run.chatId)
        run.phase = phase
        // Only a real key and link count: copy it and say so, once.
        if case .done(let result, let duplicate) = phase {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.url.absoluteString, forType: .string)
            Notifier.shared.postTicket(result, duplicate: duplicate)
        }
    }
}
#endif
