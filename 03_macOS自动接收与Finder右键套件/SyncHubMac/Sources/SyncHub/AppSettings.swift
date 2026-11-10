// AppSettings.swift — persisted preferences. Password lives only in the macOS Keychain.
import Foundation
import Combine

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    static let defaultServer = "https://020814.xyz"
    static let defaultReceiveDir = (NSHomeDirectory() as NSString).appendingPathComponent("Desktop/跨端传输文件")

    private let d = UserDefaults.standard
    private enum K {
        static let server = "serverURL", user = "username", auto = "autoReceive", dir = "receiveDir"
        static let notify = "notifications", login = "launchAtLogin", firstRun = "didFirstRun", interval = "pollSeconds"
        static let clip = "clipSync", clipImages = "clipImages", clipFiles = "clipFiles", autoSend = "autoSendFolder"
    }

    @Published var serverURL: String
    @Published var username: String
    @Published var autoReceive: Bool
    @Published var receiveDir: String
    @Published var notifications: Bool
    @Published var launchAtLogin: Bool
    /// Automatic two-way clipboard sync with Windows / Android (SyncClipboard.json). On by default.
    @Published var clipSync: Bool
    /// Also sync copied images / screenshots (only when clipSync is on).
    @Published var clipImages: Bool
    /// Also sync files copied in Finder (one file ≤ 100 MB → Windows clipboard; several files / a folder → sent).
    @Published var clipFiles: Bool
    /// Automatically send new files placed in the transfer folder (receiveDir) to the other devices.
    @Published var autoSendFolder: Bool
    /// Cached in memory so the 3-second poll never hits the Keychain.
    private(set) var password: String

    let deviceName = "Mac"          // matches the old receiver: uploads from=Mac, auto-pull device=mac
    var pollSeconds: TimeInterval { max(2, d.double(forKey: K.interval)) }

    private init() {
        let d = UserDefaults.standard
        d.register(defaults: [K.server: AppSettings.defaultServer, K.user: "", K.auto: true,
                              K.dir: AppSettings.defaultReceiveDir, K.notify: true, K.login: true, K.interval: 3.0,
                              K.clip: true, K.clipImages: true, K.clipFiles: true, K.autoSend: true])
        let user = d.string(forKey: K.user) ?? ""
        serverURL = d.string(forKey: K.server) ?? AppSettings.defaultServer
        username = user
        autoReceive = d.bool(forKey: K.auto)
        receiveDir = d.string(forKey: K.dir) ?? AppSettings.defaultReceiveDir
        notifications = d.bool(forKey: K.notify)
        launchAtLogin = d.bool(forKey: K.login)
        clipSync = d.bool(forKey: K.clip)
        clipImages = d.bool(forKey: K.clipImages)
        clipFiles = d.bool(forKey: K.clipFiles)
        autoSendFolder = d.bool(forKey: K.autoSend)
        password = user.isEmpty ? "" : (Keychain.read(account: user) ?? "")
    }

    var isFirstRun: Bool { !d.bool(forKey: K.firstRun) }
    func markFirstRunDone() { d.set(true, forKey: K.firstRun) }

    var receiveURL: URL { URL(fileURLWithPath: (receiveDir as NSString).expandingTildeInPath, isDirectory: true) }

    var config: HubConfig {
        HubConfig(baseURL: serverURL, username: username, password: password, device: deviceName)
    }

    /// Save everything; password goes to the Keychain (old entry removed if the username changed).
    func save(password newPassword: String?) {
        let oldUser = d.string(forKey: K.user) ?? ""
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        username = user
        d.set(serverURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: K.server)
        d.set(user, forKey: K.user)
        d.set(autoReceive, forKey: K.auto)
        d.set(receiveDir, forKey: K.dir)
        d.set(notifications, forKey: K.notify)
        d.set(launchAtLogin, forKey: K.login)
        d.set(clipSync, forKey: K.clip)
        d.set(clipImages, forKey: K.clipImages)
        d.set(clipFiles, forKey: K.clipFiles)
        d.set(autoSendFolder, forKey: K.autoSend)
        if !oldUser.isEmpty && oldUser != user { Keychain.delete(account: oldUser) }
        if let p = newPassword {
            if user.isEmpty { password = "" }
            else { _ = Keychain.save(account: user, password: p); password = p }
        } else if user != oldUser {
            password = user.isEmpty ? "" : (Keychain.read(account: user) ?? "")
        }
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
    }

    func setAutoReceive(_ on: Bool) {
        autoReceive = on; d.set(on, forKey: K.auto)
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
    }

    /// Menu toggle; AppDelegate restarts the folder watcher itself (no full settings reload needed).
    func setAutoSendFolder(_ on: Bool) {
        autoSendFolder = on; d.set(on, forKey: K.autoSend)
    }

    func setClipSync(_ on: Bool) {
        clipSync = on; d.set(on, forKey: K.clip)
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
    }
}

extension Notification.Name {
    static let settingsChanged = Notification.Name("SyncHubSettingsChanged")
}
