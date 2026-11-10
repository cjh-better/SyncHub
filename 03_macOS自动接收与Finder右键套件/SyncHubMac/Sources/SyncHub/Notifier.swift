// Notifier.swift — native banners via UserNotifications.
// Clicking a "file received / downloaded" banner opens that file (or shows it in Finder); any other banner opens the menu.
import AppKit
import UserNotifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter crashes when not running from a proper .app bundle.
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    /// Set by AppDelegate once the status item exists; taps that arrive earlier (app launched by a click) are queued.
    var onTap: ((NotificationTap) -> Void)? {
        didSet { if let h = onTap, !pending.isEmpty { let p = pending; pending = []; p.forEach(h) } }
    }
    private var pending: [NotificationTap] = []

    /// Must run before the app finishes launching (applicationWillFinishLaunching), otherwise the click that
    /// launched the app is never delivered to the delegate.
    func setUp() {
        guard let c = center else { return }
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// `file`: the local file a click should open.
    func post(_ title: String, _ body: String, file: URL? = nil) {
        guard AppSettings.shared.notifications else { return }
        guard let c = center else { fallback(title, body); return }
        // Ask for the current permission each time: 1.1.1 cached it once at launch, so banners posted before the
        // permission answer arrived (or after the user allowed SyncHub later in System Settings) fell back to
        // `osascript`, whose banners belong to Script Editor and can't be clicked through to SyncHub.
        c.getNotificationSettings { s in
            switch s.authorizationStatus {
            case .authorized, .provisional:
                self.add(c, title, body, file)
            case .notDetermined:
                c.requestAuthorization(options: [.alert, .sound]) { ok, _ in
                    if ok { self.add(c, title, body, file) } else { self.fallback(title, body) }
                }
            default:
                self.fallback(title, body)
            }
        }
    }

    private func add(_ c: UNUserNotificationCenter, _ title: String, _ body: String, _ file: URL?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = NotificationTap.userInfo(file: file)
        c.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Notifications switched off for SyncHub: still show text via AppleScript (not clickable).
    private func fallback(_ title: String, _ body: String) {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""]
        try? p.run()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let tap = NotificationTap.route(response.notification.request.content.userInfo)
        let isClick = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        DispatchQueue.main.async {
            if isClick {
                if let h = self.onTap { h(tap) } else { self.pending.append(tap) }
            }
            completionHandler()
        }
    }
}
