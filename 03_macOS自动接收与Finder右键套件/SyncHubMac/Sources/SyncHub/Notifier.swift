// Notifier.swift — native banners via UserNotifications; clicking a "file received" banner reveals it in Finder.
import AppKit
import UserNotifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private var authorized = false
    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter crashes when not running from a proper .app bundle.
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func setUp() {
        guard let c = center else { return }
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound]) { ok, _ in self.authorized = ok }
    }

    /// `reveal`: file to select in Finder when the banner is clicked.
    func post(_ title: String, _ body: String, reveal: URL? = nil) {
        guard AppSettings.shared.notifications else { return }
        guard let c = center, authorized else { fallback(title, body); return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let r = reveal { content.userInfo = ["reveal": r.path] }
        c.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

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
        if let p = response.notification.request.content.userInfo["reveal"] as? String {
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
            }
        }
        completionHandler()
    }
}
