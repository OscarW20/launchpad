#if os(macOS)
import SwiftUI
import AppKit
import IOKit.pwr_mgt
import UserNotifications
import LaunchpadCore

// Small Mac pieces the features share: the resource bundle, the menu bar icon, the main window, keeping the Mac
// awake while bots work, and notifications you can reply to.

// MARK: - Resources

/// The app's resource bundle: inside Launchpad.app (scripts/make-app.sh copies it to Contents/Resources), or
/// SwiftPM's own next to the binary when run with `swift run`.
enum AppResources {
    static let bundle: Bundle = {
        let name = "Launchpad_Launchpad.bundle"
        for base in [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap({ $0 }) {
            let url = base.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path), let b = Bundle(url: url) { return b }
        }
        return Bundle.module
    }()

    static func url(_ name: String, _ ext: String, in folder: String) -> URL? {
        bundle.url(forResource: name, withExtension: ext, subdirectory: folder)
    }
}

/// The menu bar icon: Resources/Brand/MenuBarIcon.png and @2x as one template image (adapts to light and dark).
@MainActor
enum MenuBarIcon {
    static let image: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        for name in ["MenuBarIcon", "MenuBarIcon@2x"] {
            if let url = AppResources.url(name, "png", in: "Brand"), let data = try? Data(contentsOf: url),
               let rep = NSBitmapImageRep(data: data) {
                rep.size = size
                image.addRepresentation(rep)
            }
        }
        if image.representations.isEmpty, let symbol = NSImage(systemSymbolName: "paperplane", accessibilityDescription: "Launchpad") {
            symbol.isTemplate = true
            return symbol
        }
        image.isTemplate = true
        return image
    }()
}

// MARK: - The main window

/// Finds the main window again (Quick Ask, the menu bar and notifications bring it forward), or reopens it.
@MainActor
enum MainWindow {
    static weak var window: NSWindow?
    static var openWindow: OpenWindowAction?

    static func bringForward() {
        NSApp.activate(ignoringOtherApps: true)
        if let window, window.isVisible || window.isMiniaturized {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else if let openWindow {
            // Closed (the menu bar keeps Launchpad running): open it again.
            openWindow(id: "main")
        } else {
            window?.makeKeyAndOrderFront(nil)
        }
    }
}

/// Hands the hosting NSWindow to `found` once the view is in a window.
struct WindowReader: NSViewRepresentable {
    let found: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let found = self.found
        DispatchQueue.main.async { MainActor.assumeIsolated { if let w = view.window { found(w) } } }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let found = self.found
        DispatchQueue.main.async { MainActor.assumeIsolated { if let w = nsView.window { found(w) } } }
    }
}

// MARK: - Preferences

enum MacPrefs {
    static let menuBar = "showMenuBarIcon"
    static let quickAsk = "quickAskHotKey"
    static let keepAwake = "keepAwakeWhileWorking"
    static let notify = "notifyInBackground"
    static var showsMenuBar: Bool { UserDefaults.standard.object(forKey: menuBar) as? Bool ?? true }
}

// MARK: - Keep awake

/// Keeps the Mac from going to sleep while a bot works, so long jobs finish (the screen can still dim and lock).
@MainActor
enum Awake {
    private static var assertion: IOPMAssertionID = 0
    static let key = MacPrefs.keepAwake
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
    /// Holding the Mac awake right now.
    static var isHolding: Bool { assertion != 0 }

    static func update(working: Bool) {
        if working && enabled {
            guard assertion == 0 else { return }
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "Launchpad: a bot is working" as CFString, &id)
            if result == kIOReturnSuccess { assertion = id }
        } else if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }
}

// MARK: - Notifications

/// "Scout replied" / "Scout needs your OK" while Launchpad is in the background, with a Reply field that sends
/// straight to that chat. Only inside the .app bundle: `swift run` has no bundle to post from.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    static let category = "launchpad.reply"
    static let enabledKey = MacPrefs.notify
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// Notifications need a real app bundle.
    static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    weak var model: AppModel?
    private var installed = false

    @MainActor
    func install(model: AppModel) {
        self.model = model
        guard Self.available, !installed else { return }
        installed = true
        let reply = UNTextInputNotificationAction(identifier: "reply", title: "Reply", options: [],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        let open = UNNotificationAction(identifier: "open", title: "Open", options: [.foreground])
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [reply, open],
                                                                 intentIdentifiers: [], options: [])])
        center.delegate = self
        if Self.enabled { requestPermission() }
    }

    func requestPermission() {
        guard Self.available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Posts only while Launchpad isn't the app in front.
    @MainActor
    func post(_ notice: ReplyNotice, chatId: String) {
        guard Self.available, Self.enabled, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        content.categoryIdentifier = Self.category
        content.threadIdentifier = chatId
        content.userInfo = ["chatId": chatId]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    /// A ticket was filed: says so (even with Launchpad in front, since you're usually in another app) and opens the
    /// ticket when clicked. Only Create ticket calls this, with a link it has checked.
    @MainActor
    func postTicket(_ result: TicketResult, duplicate: Bool) {
        guard Self.available, Self.enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = duplicate ? "Already in Jira: \(result.key)" : "Ticket created: \(result.key)"
        content.body = "The link is on your clipboard. Click to open it."
        content.sound = .default
        content.userInfo = ["ticketURL": result.url.absoluteString]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { _ in }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let link = response.notification.request.content.userInfo["ticketURL"] as? String,
           let url = URL(string: link), url.scheme == "https" {
            if response.actionIdentifier != UNNotificationDismissActionIdentifier { NSWorkspace.shared.open(url) }
            completionHandler()
            return
        }
        let chatId = response.notification.request.content.userInfo["chatId"] as? String
        let text = (response as? UNTextInputNotificationResponse)?.userText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let chatId, let model = self.model {
                    if action == "reply" {
                        if !text.isEmpty { model.replyFromNotification(text, chatId: chatId) }
                    } else if action != UNNotificationDismissActionIdentifier {
                        model.show(chat: chatId)
                        MainWindow.bringForward()
                    }
                }
                completionHandler()
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
#endif
