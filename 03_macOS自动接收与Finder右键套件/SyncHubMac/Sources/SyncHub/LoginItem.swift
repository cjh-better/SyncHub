// LoginItem.swift — "登录时启动": SMAppService on macOS 13+, LaunchAgent plist fallback on macOS 12.
import Foundation
import ServiceManagement

enum LoginItem {
    static let agentLabel = "xyz.020814.synchub.app"
    static var agentURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    static func set(_ enabled: Bool) {
        #if compiler(>=5.7)   // SMAppService needs the macOS 13 SDK (Xcode 14 / CLT 14+)
        if #available(macOS 13.0, *) {
            do {
                if enabled { if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() } }
                else { try SMAppService.mainApp.unregister() }
                try? FileManager.default.removeItem(at: agentURL)   // don't double-register
                return
            } catch {
                NSLog("SyncHub: SMAppService failed (\(error)); using LaunchAgent fallback")
            }
        }
        #endif
        setAgent(enabled)
    }

    private static func setAgent(_ enabled: Bool) {
        let fm = FileManager.default
        guard enabled else { try? fm.removeItem(at: agentURL); return }
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
        ]
        try? fm.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? data.write(to: agentURL, options: .atomic)   // picked up by launchd at next login
        }
    }
}
