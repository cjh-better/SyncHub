import Carbon
import Cocoa
import FlutterMacOS
import Security
import ServiceManagement
import UserNotifications

// MARK: - Keychain Store ("synchub/secure")

private enum SyncHubKeychain {
  static let defaultService = "xyz.synchub.secure"

  private static func baseQuery(service: String, account: String) -> [String: Any] {
    return [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  static func read(account: String, service: String = defaultService) -> String? {
    guard !account.isEmpty else { return nil }
    var query = baseQuery(service: service, account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var out: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &out)
    guard status == errSecSuccess, let data = out as? Data else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  static func write(account: String, value: String, service: String = defaultService) -> OSStatus {
    guard !account.isEmpty else { return errSecParam }
    let data = Data(value.utf8)
    let query = baseQuery(service: service, account: account)
    let updateAttrs: [String: Any] = [
      kSecValueData as String: data,
    ]
    let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
    if updateStatus == errSecSuccess {
      return errSecSuccess
    }
    if updateStatus != errSecItemNotFound {
      SecItemDelete(query as CFDictionary)
    }
    var addQuery = query
    addQuery[kSecValueData as String] = data
    addQuery[kSecAttrLabel as String] = "SyncHub (\(account))"
    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    return SecItemAdd(addQuery as CFDictionary, nil)
  }

  @discardableResult
  static func delete(account: String, service: String = defaultService) -> OSStatus {
    guard !account.isEmpty else { return errSecSuccess }
    let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
    return status == errSecItemNotFound ? errSecSuccess : status
  }

  @discardableResult
  static func deleteAll(service: String = defaultService) -> OSStatus {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
    ]
    let status = SecItemDelete(query as CFDictionary)
    return status == errSecItemNotFound ? errSecSuccess : status
  }
}

// MARK: - Login Item Manager (SMAppService on macOS 13+ with LaunchAgent fallback)

private enum SyncHubLoginItem {
  static let agentLabel = "xyz.synchub.synchub.app"

  static var agentURL: URL {
    return URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
  }

  static func isEnabled() -> Bool {
    #if compiler(>=5.7)
    if #available(macOS 13.0, *) {
      if SMAppService.mainApp.status == .enabled {
        return true
      }
    }
    #endif
    return FileManager.default.fileExists(atPath: agentURL.path)
  }

  @discardableResult
  static func setEnabled(_ enabled: Bool) -> Bool {
    #if compiler(>=5.7)
    if #available(macOS 13.0, *) {
      do {
        if enabled {
          if SMAppService.mainApp.status != .enabled {
            try SMAppService.mainApp.register()
          }
        } else {
          let st = SMAppService.mainApp.status
          if st == .enabled || st == .requiresApproval {
            try SMAppService.mainApp.unregister()
          }
        }
        try? FileManager.default.removeItem(at: agentURL)
        return isEnabled()
      } catch {
        NSLog("SyncHub: SMAppService failed (\(error)); falling back to LaunchAgent plist")
      }
    }
    #endif
    return setLaunchAgent(enabled)
  }

  private static func setLaunchAgent(_ enabled: Bool) -> Bool {
    let fm = FileManager.default
    guard enabled else {
      try? fm.removeItem(at: agentURL)
      return false
    }
    let plist: [String: Any] = [
      "Label": agentLabel,
      "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath, "--args", "--minimized"],
      "RunAtLoad": true,
      "LimitLoadToSessionType": "Aqua",
    ]
    do {
      try fm.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      try data.write(to: agentURL, options: .atomic)
      return true
    } catch {
      NSLog("SyncHub: failed writing LaunchAgent plist: \(error)")
      return false
    }
  }
}

// MARK: - Notification Manager (UNUserNotificationCenter + osascript fallback)

private final class SyncHubNotificationManager: NSObject, UNUserNotificationCenterDelegate {
  static let shared = SyncHubNotificationManager()

  private var center: UNUserNotificationCenter? {
    return Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
  }

  var onClick: ((String) -> Void)? {
    didSet {
      if let handler = onClick, !pendingPaths.isEmpty {
        let queued = pendingPaths
        pendingPaths.removeAll()
        queued.forEach(handler)
      }
    }
  }
  private var pendingPaths: [String] = []

  func setUp() {
    guard let c = center else { return }
    c.delegate = self
    c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
  }

  func post(title: String, body: String, path: String?) {
    guard let c = center else {
      fallbackOsascript(title: title, body: body)
      return
    }
    c.getNotificationSettings { settings in
      switch settings.authorizationStatus {
      case .authorized, .provisional:
        self.enqueue(center: c, title: title, body: body, path: path)
      case .notDetermined:
        c.requestAuthorization(options: [.alert, .sound]) { granted, _ in
          if granted {
            self.enqueue(center: c, title: title, body: body, path: path)
          } else {
            self.fallbackOsascript(title: title, body: body)
          }
        }
      default:
        self.fallbackOsascript(title: title, body: body)
      }
    }
  }

  private func enqueue(center: UNUserNotificationCenter, title: String, body: String, path: String?) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    if let p = path, !p.isEmpty {
      content.userInfo = ["path": p]
    }
    let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    center.add(req, withCompletionHandler: nil)
  }

  private func fallbackOsascript(title: String, body: String) {
    func esc(_ s: String) -> String {
      return s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    proc.arguments = ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""]
    try? proc.run()
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if #available(macOS 11.0, *) {
      completionHandler([.banner, .list, .sound])
    } else {
      completionHandler([.alert, .sound])
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let info = response.notification.request.content.userInfo
    let path = (info["path"] as? String) ?? (info["file"] as? String) ?? (info["reveal"] as? String) ?? ""
    let isDefaultTap = response.actionIdentifier == UNNotificationDefaultActionIdentifier
    DispatchQueue.main.async {
      if isDefaultTap {
        if let handler = self.onClick {
          handler(path)
        } else {
          self.pendingPaths.append(path)
        }
      }
      completionHandler()
    }
  }
}

// MARK: - Self-Installing Finder Quick Action

private enum SyncHubQuickActionInstaller {
  static let workflowName = "发送到跨端传输中心"
  static let legacyWorkflowName = "📲 发送到跨端传输 (Windows与手机)"

  static func ensureInstalledAsync() {
    DispatchQueue.global(qos: .utility).async {
      installOrUpdateIfNeeded()
    }
  }

  private static func installOrUpdateIfNeeded() {
    let fm = FileManager.default
    let servicesDir = URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent("Library/Services", isDirectory: true)

    let legacyURL = servicesDir.appendingPathComponent("\(legacyWorkflowName).workflow", isDirectory: true)
    var removedLegacy = false
    if fm.fileExists(atPath: legacyURL.path) {
      try? fm.removeItem(at: legacyURL)
      removedLegacy = true
    }

    let workflowContents = servicesDir
      .appendingPathComponent("\(workflowName).workflow", isDirectory: true)
      .appendingPathComponent("Contents", isDirectory: true)
    let infoURL = workflowContents.appendingPathComponent("Info.plist")
    let wflowURL = workflowContents.appendingPathComponent("document.wflow")

    let commandScript = """
    if [ -d "/Applications/SyncHub.app" ]; then
      open -a "/Applications/SyncHub.app" "$@"
    elif [ -d "$HOME/Applications/SyncHub.app" ]; then
      open -a "$HOME/Applications/SyncHub.app" "$@"
    else
      open -b xyz.synchub.synchub "$@"
    fi
    """

    let alreadyCurrent: Bool = {
      guard fm.fileExists(atPath: infoURL.path),
            let existingData = try? Data(contentsOf: wflowURL),
            let existingText = String(data: existingData, encoding: .utf8) else {
        return false
      }
      return existingText.contains("xyz.synchub.synchub") && existingText.contains("/Applications/SyncHub.app")
    }()

    var wroteWorkflow = false
    if !alreadyCurrent {
      do {
        try fm.createDirectory(at: workflowContents, withIntermediateDirectories: true)

        let infoPlist: [String: Any] = [
          "NSServices": [
            [
              "NSIconName": "NSActionTemplate",
              "NSMenuItem": ["default": workflowName],
              "NSMessage": "runWorkflowAsService",
              "NSRequiredContext": ["NSApplicationIdentifier": "com.apple.finder"],
              "NSSendFileTypes": ["public.item"],
            ] as [String: Any]
          ]
        ]

        let docWflow: [String: Any] = [
          "AMApplicationBuild": "523",
          "AMApplicationVersion": "2.10",
          "AMDocumentVersion": "2",
          "actions": [
            [
              "action": [
                "AMAccepts": [
                  "Container": "List",
                  "Optional": true,
                  "Types": ["com.apple.cocoa.string"],
                ] as [String: Any],
                "AMActionVersion": "2.0.3",
                "AMApplication": ["Automator"],
                "AMParameterProperties": [
                  "COMMAND_STRING": [String: Any](),
                  "CheckedForUserDefaultShell": [String: Any](),
                  "inputMethod": [String: Any](),
                  "shell": [String: Any](),
                  "source": [String: Any](),
                ] as [String: Any],
                "AMProvides": [
                  "Container": "List",
                  "Types": ["com.apple.cocoa.string"],
                ] as [String: Any],
                "ActionBundlePath": "/System/Library/Automator/Run Shell Script.action",
                "ActionName": "Run Shell Script",
                "ActionParameters": [
                  "COMMAND_STRING": commandScript,
                  "CheckedForUserDefaultShell": true,
                  "inputMethod": 1,
                  "shell": "/bin/bash",
                  "source": "",
                ] as [String: Any],
                "BundleIdentifier": "com.apple.RunShellScript",
                "CFBundleVersion": "2.0.3",
                "CanShowSelectedItemsWhenRun": false,
                "CanShowWhenRun": true,
                "Class Name": "RunShellScriptAction",
                "InputUUID": "5B0E6C1E-3D5A-4C1F-9C7E-0A1B2C3D4E01",
                "OutputUUID": "5B0E6C1E-3D5A-4C1F-9C7E-0A1B2C3D4E02",
                "UUID": "5B0E6C1E-3D5A-4C1F-9C7E-0A1B2C3D4E03",
                "isViewVisible": 1,
              ] as [String: Any]
            ] as [String: Any]
          ],
          "connectors": [String: Any](),
          "workflowMetaData": [
            "applicationBundleIDsByPath": [String: Any](),
            "applicationPaths": [Any](),
            "inputTypeIdentifier": "com.apple.Automator.fileSystemObject",
            "outputTypeIdentifier": "com.apple.Automator.nothing",
            "presentationMode": 15,
            "processesInput": 0,
            "serviceInputTypeIdentifier": "com.apple.Automator.fileSystemObject",
            "serviceOutputTypeIdentifier": "com.apple.Automator.nothing",
            "serviceProcessesInput": 0,
            "systemImageName": "NSActionTemplate",
            "useAutomaticInputType": 0,
            "workflowTypeIdentifier": "com.apple.Automator.servicesMenu",
          ] as [String: Any],
        ]

        let infoData = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
        try infoData.write(to: infoURL, options: .atomic)

        let wflowData = try PropertyListSerialization.data(fromPropertyList: docWflow, format: .xml, options: 0)
        try wflowData.write(to: wflowURL, options: .atomic)
        wroteWorkflow = true
      } catch {
        NSLog("SyncHub: failed installing Finder Quick Action: \(error)")
      }
    }

    // Register current app bundle with LaunchServices so `open -b xyz.synchub.synchub` works immediately.
    let lsreg = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    if fm.isExecutableFile(atPath: lsreg) {
      let reg = Process()
      reg.executableURL = URL(fileURLWithPath: lsreg)
      reg.arguments = ["-f", Bundle.main.bundlePath]
      reg.standardOutput = FileHandle.nullDevice
      reg.standardError = FileHandle.nullDevice
      try? reg.run()
      reg.waitUntilExit()
    }

    if wroteWorkflow || removedLegacy {
      let pbs = "/System/Library/CoreServices/pbs"
      if fm.isExecutableFile(atPath: pbs) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pbs)
        proc.arguments = ["-update"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
      }
    }
  }
}

// MARK: - Clipboard Rules & Helpers

private enum SyncHubClipboard {
  static let concealedTypes: Set<String> = [
    "org.nspasteboard.ConcealedType",
    "org.nspasteboard.TransientType",
    "org.nspasteboard.AutoGeneratedType",
    "com.agilebits.onepassword",
    "com.smileonmymac.textexpander",
    "de.petermaurer.TransientPasteboardType",
    "com.typeit4me.clipping",
    "net.antelle.keeweb",
    "Pasteboard generator type",
  ]

  static func isConcealed(_ pasteboard: NSPasteboard = .general) -> Bool {
    let rawTypes = (pasteboard.types ?? []).map { $0.rawValue }
    for t in rawTypes {
      if concealedTypes.contains(t) {
        return true
      }
      let lower = t.lowercased()
      if lower.contains("concealed")
        || lower.contains("onepassword")
        || lower.contains("textexpander")
        || lower.contains("transientpasteboard") {
        return true
      }
    }
    return false
  }

  static func readFiles(_ pasteboard: NSPasteboard = .general) -> [String] {
    guard pasteboard.availableType(from: [.fileURL]) != nil else {
      return []
    }
    let urls = (pasteboard.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]
    ) as? [URL]) ?? []
    return urls.map { $0.path }
  }

  static func readImagePNG(_ pasteboard: NSPasteboard = .general, allowFileIcon: Bool = false) -> Data? {
    if !allowFileIcon && !readFiles(pasteboard).isEmpty {
      return nil
    }
    if let png = pasteboard.data(forType: .png), !png.isEmpty {
      return png
    }
    if let tiff = pasteboard.data(forType: .tiff),
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]),
       !png.isEmpty {
      return png
    }
    return nil
  }

  static func writeImage(_ data: Data, to pasteboard: NSPasteboard = .general) -> Bool {
    guard !data.isEmpty, let image = NSImage(data: data) else {
      return false
    }
    pasteboard.clearContents()
    var ok = false
    let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
    if isPNG {
      ok = pasteboard.setData(data, forType: .png)
    } else if let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) {
      ok = pasteboard.setData(png, forType: .png)
    }
    if let tiff = image.tiffRepresentation {
      ok = pasteboard.setData(tiff, forType: .tiff) || ok
    }
    return ok
  }
}

// MARK: - Tray State Models

private struct TrayPeerDevice {
  let id: String
  let name: String
  let platform: String
  let online: Bool
}

private struct TrayRecentItem {
  let rawId: Any
  let idText: String
  let title: String
  let subtitle: String
  let path: String?
}

private struct TrayStateSnapshot {
  var connected: Bool? = nil
  var onlineCount: Int = 0
  var statusLine: String = ""
  var detailLine: String = ""
  var tooltip: String = "SyncHub — 拖拽文件到此图标即可跨端发送"
  var isUploading: Bool = false
  var isDownloading: Bool = false
  var progress: Double = 0.0
  var autoReceive: Bool = true
  var clipSync: Bool = true
  var launchAtLogin: Bool = SyncHubLoginItem.isEnabled()
  var devices: [TrayPeerDevice] = []
  var recentItems: [TrayRecentItem] = []

  static func from(dictionary dict: [String: Any], fallbackLaunchAtLogin: Bool) -> TrayStateSnapshot {
    var snap = TrayStateSnapshot()
    snap.connected = dict["connected"] as? Bool
    if let tip = dict["tooltip"] as? String, !tip.isEmpty {
      snap.tooltip = tip
    }

    if let devs = (dict["devices"] as? [[String: Any]]) ?? (dict["peers"] as? [[String: Any]]) {
      snap.devices = devs.compactMap { d in
        let isSelf = (d["isSelf"] as? Bool) ?? (d["self"] as? Bool) ?? false
        if isSelf { return nil }
        let rawId = (d["id"] as? String) ?? (d["deviceId"] as? String) ?? (d["device_id"] as? String) ?? ""
        guard !rawId.isEmpty else { return nil }
        let name = (d["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? rawId
        let platform = (d["platform"] as? String) ?? ""
        let online = (d["online"] as? Bool) ?? false
        return TrayPeerDevice(id: rawId, name: name, platform: platform, online: online)
      }
    }

    if let n = (dict["onlineCount"] as? NSNumber)?.intValue ?? (dict["online_count"] as? NSNumber)?.intValue {
      snap.onlineCount = n
    } else {
      snap.onlineCount = snap.devices.filter { $0.online }.count
    }

    if let u = dict["uploading"] as? Bool {
      snap.isUploading = u
    } else if let uCount = (dict["uploading"] as? NSNumber)?.intValue ?? (dict["uploadingCount"] as? NSNumber)?.intValue {
      snap.isUploading = uCount > 0
    } else if (dict["state"] as? String) == "uploading" || (dict["direction"] as? String) == "send" {
      snap.isUploading = true
    }

    if let dl = dict["downloading"] as? Bool {
      snap.isDownloading = dl
    } else if let dlCount = (dict["downloading"] as? NSNumber)?.intValue ?? (dict["downloadingCount"] as? NSNumber)?.intValue {
      snap.isDownloading = dlCount > 0
    } else if (dict["state"] as? String) == "downloading" || (dict["direction"] as? String) == "recv" {
      snap.isDownloading = true
    }

    if let rawProgress = (dict["progress"] as? NSNumber)?.doubleValue {
      let normalized = rawProgress > 1.0 && rawProgress <= 100.0 ? (rawProgress / 100.0) : rawProgress
      snap.progress = min(1.0, max(0.0, normalized))
    }

    snap.statusLine = (dict["statusText"] as? String) ?? (dict["status"] as? String) ?? ""
    snap.detailLine = (dict["detailText"] as? String) ?? (dict["transferText"] as? String) ?? (dict["subtitle"] as? String) ?? ""

    if let ar = (dict["autoReceive"] as? Bool) ?? (dict["autoAccept"] as? Bool) ?? (dict["auto_accept"] as? Bool) {
      snap.autoReceive = ar
    }
    if let cs = (dict["clipSync"] as? Bool) ?? (dict["clipboardSync"] as? Bool) ?? (dict["syncClipboard"] as? Bool) {
      snap.clipSync = cs
    }
    if let ll = (dict["launchAtLogin"] as? Bool) ?? (dict["autoStart"] as? Bool) {
      snap.launchAtLogin = ll
    } else {
      snap.launchAtLogin = fallbackLaunchAtLogin
    }

    if let recents = (dict["recentItems"] as? [[String: Any]]) ?? (dict["recent"] as? [[String: Any]]) {
      snap.recentItems = recents.prefix(8).compactMap { r in
        let rawId: Any
        let idStr: String
        if let s = (r["id"] as? String) ?? (r["itemId"] as? String) {
          guard !s.isEmpty else { return nil }
          rawId = s
          idStr = s
        } else if let n = (r["id"] as? NSNumber) ?? (r["itemId"] as? NSNumber),
                  CFGetTypeID(n) != CFBooleanGetTypeID() {
          rawId = NSNumber(value: n.int64Value)
          idStr = n.stringValue
        } else {
          return nil
        }
        let title = (r["title"] as? String)
          ?? (r["label"] as? String)
          ?? (r["filename"] as? String)
          ?? (r["name"] as? String)
          ?? idStr
        var subtitle = (r["subtitle"] as? String) ?? (r["meta"] as? String) ?? ""
        if subtitle.isEmpty {
          var parts: [String] = []
          if let peer = (r["peer"] as? String) ?? (r["fromDevice"] as? String), !peer.isEmpty {
            parts.append(peer)
          }
          if let sz = (r["sizeText"] as? String), !sz.isEmpty {
            parts.append(sz)
          } else if let bytes = (r["size"] as? NSNumber)?.int64Value, bytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
          }
          if let timeText = (r["timeText"] as? String) ?? (r["updated"] as? String), !timeText.isEmpty {
            parts.append(timeText)
          }
          subtitle = parts.joined(separator: " · ")
        }
        let path = (r["path"] as? String)
        return TrayRecentItem(rawId: rawId, idText: idStr, title: title, subtitle: subtitle, path: path)
      }
    }

    return snap
  }
}

// MARK: - Global Carbon Hotkey Callback (⇧⌘V)

private let kSyncHubHotKeySignature: OSType = 0x5348_5542  // 'SHUB'
private let kSyncHubHotKeyID: UInt32 = 1

private let syncHubCarbonHotKeyCallback: EventHandlerUPP = { (_, eventRef, _) -> OSStatus in
  guard let eventRef = eventRef else {
    return OSStatus(eventNotHandledErr)
  }
  var hkID = EventHotKeyID()
  let status = GetEventParameter(
    eventRef,
    EventParamName(kEventParamDirectObject),
    EventParamType(typeEventHotKeyID),
    nil,
    numericCast(MemoryLayout<EventHotKeyID>.size),
    nil,
    &hkID
  )
  if status == noErr && hkID.signature == kSyncHubHotKeySignature && hkID.id == kSyncHubHotKeyID {
    DispatchQueue.main.async {
      AppDelegate.shared?.triggerSendClipboard()
    }
    return noErr
  }
  return OSStatus(eventNotHandledErr)
}

// MARK: - AppDelegate

@main
class AppDelegate: FlutterAppDelegate, NSMenuDelegate, NSWindowDelegate, NSDraggingDestination {
  static weak var shared: AppDelegate?

  private(set) var allowQuit: Bool = false
  private let isMinimizedLaunch: Bool = {
    let args = ProcessInfo.processInfo.arguments
    return args.contains("--minimized") || args.contains("--background")
  }()

  private weak var flutterWin: MainFlutterWindow?
  private var secureChannel: FlutterMethodChannel?
  private var desktopChannel: FlutterMethodChannel?
  private var channelsAttached = false
  private var dartReady = false
  private var hasLaunched = false

  // Startup buffers flushed on `ready`
  private var pendingStartupEvents: [[String: Any]] = []
  private var pendingCallbacks: [(method: String, arguments: Any?)] = []

  // Status Bar & Menu
  private var statusItem: NSStatusItem?
  private let statusMenu = NSMenu()
  private var dragHighlight = false
  private var trayState = TrayStateSnapshot()
  private var pendingDropPaths: [String] = []
  private var statusMenuDirty = true
  private var lastClipboardChangeCount: Int = -1
  private var pasteboardCoalescedTimer: Timer?
  private var menuCache: [String: Any] = [
    "status": "idle",
    "updated_at": ProcessInfo.processInfo.systemUptime,
  ]

  // Global Hotkey refs
  private var hotKeyRef: EventHotKeyRef?
  private var hotKeyHandlerRef: EventHandlerRef?
  private var lastClipboardTriggerAt: TimeInterval = 0

  override init() {
    super.init()
    AppDelegate.shared = self
    captureInitialCliArguments()
  }

  // MARK: NSApplicationDelegate Lifecycle

  override func applicationWillFinishLaunching(_ notification: Notification) {
    super.applicationWillFinishLaunching(notification)
    if isMinimizedLaunch {
      NSApp.setActivationPolicy(.accessory)
    }
    SyncHubNotificationManager.shared.setUp()
    SyncHubNotificationManager.shared.onClick = { [weak self] path in
      guard let self = self else { return }
      if path.isEmpty {
        self.showMainWindow()
      }
      self.dispatchToDart("onNotificationClick", arguments: ["path": path])
    }
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // 1. Single-instance enforcement
    if let bundleId = Bundle.main.bundleIdentifier {
      let selfPid = ProcessInfo.processInfo.processIdentifier
      if let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        .first(where: { $0.processIdentifier != selfPid && !$0.isTerminated }) {
        NSLog("SyncHub: existing instance running (pid \(other.processIdentifier)); activating and exiting.")
        var forwardTargets: [String] = []
        for ev in pendingStartupEvents {
          if let kind = ev["kind"] as? String {
            if kind == "files", let paths = ev["paths"] as? [String] {
              forwardTargets.append(contentsOf: paths)
            } else if kind == "url", let u = ev["url"] as? String {
              forwardTargets.append(u)
            }
          }
        }
        if !forwardTargets.isEmpty {
          let proc = Process()
          proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
          proc.arguments = ["-b", bundleId] + forwardTargets
          try? proc.run()
        } else {
          #if compiler(>=5.9)
          if #available(macOS 14.0, *) {
            other.activate()
          } else {
            other.activate(options: [.activateIgnoringOtherApps])
          }
          #else
          other.activate(options: [.activateIgnoringOtherApps])
          #endif
        }
        allowQuit = true
        NSApp.terminate(nil)
        return
      }
    }

    // 2. Ensure Flutter channels are wired if awakeFromNib ran before delegate assignment
    if let win = mainFlutterWindow as? MainFlutterWindow,
       let controller = win.flutterViewController {
      attachFlutterWindow(win, controller: controller)
    }

    // 3. Wire application menu "Preferences…" (⌘,) item
    wireApplicationMenuPreferences()

    // 4. Status bar icon, NSServices, Global ⇧⌘V hotkey, Finder Quick Action
    setUpStatusItem()
    NSApp.servicesProvider = self
    NSUpdateDynamicServices()
    registerGlobalHotKey()
    SyncHubQuickActionInstaller.ensureInstalledAsync()

    // 5. Window visibility according to `--minimized`
    if isMinimizedLaunch {
      (mainFlutterWindow as? MainFlutterWindow)?.hideToMenuBar()
    } else {
      (mainFlutterWindow as? MainFlutterWindow)?.revealFromMenuBar()
    }

    // 6. Sleep / Wake, Screen Sleep / Wake, and app activation observers
    let wsCenter = NSWorkspace.shared.notificationCenter
    wsCenter.addObserver(
      self,
      selector: #selector(workspaceWillSleep(_:)),
      name: NSWorkspace.willSleepNotification,
      object: nil
    )
    wsCenter.addObserver(
      self,
      selector: #selector(workspaceDidWake(_:)),
      name: NSWorkspace.didWakeNotification,
      object: nil
    )
    wsCenter.addObserver(
      self,
      selector: #selector(workspaceScreensDidSleep(_:)),
      name: NSWorkspace.screensDidSleepNotification,
      object: nil
    )
    wsCenter.addObserver(
      self,
      selector: #selector(workspaceScreensDidWake(_:)),
      name: NSWorkspace.screensDidWakeNotification,
      object: nil
    )
    wsCenter.addObserver(
      self,
      selector: #selector(workspaceAppActivated(_:)),
      name: NSWorkspace.didActivateApplicationNotification,
      object: nil
    )

    lastClipboardChangeCount = NSPasteboard.general.changeCount
    startPasteboardObserver()

    hasLaunched = true
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    showMainWindow()
    return true
  }

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    allowQuit = true
    stopPasteboardObserver()
    unregisterGlobalHotKey()
    return .terminateNow
  }

  override func applicationWillTerminate(_ notification: Notification) {
    stopPasteboardObserver()
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    unregisterGlobalHotKey()
  }

  override func application(_ application: NSApplication, open urls: [URL]) {
    super.application(application, open: urls)
    handleIncomingURLs(urls)
  }

  // MARK: - Sleep / Wake & Coalesced NSPasteboard Observer (App Nap Friendly)

  private func startPasteboardObserver() {
    guard pasteboardCoalescedTimer == nil else { return }
    let t = Timer(timeInterval: 1.2, repeats: true) { [weak self] _ in
      self?.checkPasteboardChangeCount()
    }
    // High timer tolerance allows macOS kernel Timer Coalescing & App Nap when backgrounded.
    t.tolerance = 0.6
    RunLoop.main.add(t, forMode: .common)
    pasteboardCoalescedTimer = t
  }

  private func stopPasteboardObserver() {
    pasteboardCoalescedTimer?.invalidate()
    pasteboardCoalescedTimer = nil
  }

  private func checkPasteboardChangeCount() {
    let cc = NSPasteboard.general.changeCount
    if cc != lastClipboardChangeCount {
      lastClipboardChangeCount = cc
      dispatchToDart("clipboard_changed", arguments: ["changeCount": cc])
    }
  }

  @objc private func workspaceWillSleep(_ note: Notification) {
    NSLog("SyncHub: NSWorkspace.willSleepNotification -> system_event sleep")
    stopPasteboardObserver()
    dispatchToDart("system_event", arguments: ["event": "sleep"])
  }

  @objc private func workspaceDidWake(_ note: Notification) {
    NSLog("SyncHub: NSWorkspace.didWakeNotification -> system_event wake")
    startPasteboardObserver()
    checkPasteboardChangeCount()
    dispatchToDart("system_event", arguments: ["event": "wake"])
  }

  @objc private func workspaceScreensDidSleep(_ note: Notification) {
    stopPasteboardObserver()
  }

  @objc private func workspaceScreensDidWake(_ note: Notification) {
    startPasteboardObserver()
    checkPasteboardChangeCount()
  }

  @objc private func workspaceAppActivated(_ note: Notification) {
    checkPasteboardChangeCount()
  }

  // MARK: Window Management

  private func activateApplication() {
    #if compiler(>=5.9)
    if #available(macOS 14.0, *) {
      NSApp.activate()
    } else {
      NSApp.activate(ignoringOtherApps: true)
    }
    #else
    NSApp.activate(ignoringOtherApps: true)
    #endif
  }

  func showMainWindow() {
    if let win = (flutterWin ?? (mainFlutterWindow as? MainFlutterWindow)) {
      win.revealFromMenuBar()
    } else {
      NSApp.setActivationPolicy(.regular)
      mainFlutterWindow?.makeKeyAndOrderFront(nil)
      activateApplication()
    }
  }

  func hideMainWindow() {
    if let win = (flutterWin ?? (mainFlutterWindow as? MainFlutterWindow)) {
      win.hideToMenuBar()
    } else {
      mainFlutterWindow?.orderOut(nil)
      NSApp.setActivationPolicy(.accessory)
    }
  }

  func notifyWindowHidden() {
    if dartReady {
      desktopChannel?.invokeMethod("onWindowVisibilityChanged", arguments: ["visible": false])
    }
  }

  private func wireApplicationMenuPreferences() {
    guard let appMenu = self.applicationMenu else { return }
    for item in appMenu.items where item.keyEquivalent == "," {
      item.title = "设置…"
      item.target = self
      item.action = #selector(menuOpenSettings(_:))
      item.isEnabled = true
    }
  }

  // MARK: CLI & URL Handling

  private func captureInitialCliArguments() {
    let rawArgs = Array(CommandLine.arguments.dropFirst())
    guard !rawArgs.isEmpty else { return }

    var cleaned: [String] = []
    var skipNext = false
    for arg in rawArgs {
      if skipNext {
        skipNext = false
        continue
      }
      if arg == "-NSDocumentRevisionsDebugMode" {
        skipNext = true
        continue
      }
      if arg.hasPrefix("-psn_") || arg == "--minimized" || arg == "--background" {
        continue
      }
      if arg.hasPrefix("--observatory") || arg.hasPrefix("--vm-service")
        || arg.hasPrefix("--enable-dart") || arg.hasPrefix("--dart-flags") {
        continue
      }
      cleaned.append(arg)
    }

    guard !cleaned.isEmpty else { return }

    let hasActionFlags = cleaned.contains { $0.hasPrefix("-") }
    if hasActionFlags {
      pendingStartupEvents.append(["kind": "cli", "args": cleaned])
      return
    }

    var cliFiles: [String] = []
    var fallbackCli: [String] = []
    for arg in cleaned {
      if arg.lowercased().hasPrefix("synchub://") {
        pendingStartupEvents.append(["kind": "url", "url": arg])
      } else if FileManager.default.fileExists(atPath: arg) {
        cliFiles.append(arg)
      } else {
        fallbackCli.append(arg)
      }
    }

    if !cliFiles.isEmpty {
      pendingStartupEvents.append(["kind": "files", "paths": cliFiles])
    }
    if !fallbackCli.isEmpty {
      pendingStartupEvents.append(["kind": "cli", "args": fallbackCli])
    }
  }

  private func handleIncomingURLs(_ urls: [URL]) {
    guard !urls.isEmpty else { return }
    var filePaths = urls.filter { $0.isFileURL }.map { $0.path }
    var customURLs: [URL] = []

    for u in urls where !u.isFileURL {
      if u.scheme?.lowercased() == "synchub" {
        let action = (u.host ?? u.path)
          .lowercased()
          .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let queryItems = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if action == "send" {
          let paths = queryItems.filter { $0.name == "path" }.compactMap { $0.value }.filter { !$0.isEmpty }
          filePaths.append(contentsOf: paths)
        } else {
          customURLs.append(u)
        }
      } else {
        customURLs.append(u)
      }
    }

    if !dartReady {
      if !filePaths.isEmpty {
        pendingStartupEvents.append(["kind": "files", "paths": filePaths])
      }
      for u in customURLs {
        pendingStartupEvents.append(["kind": "url", "url": u.absoluteString])
      }
      return
    }

    if !filePaths.isEmpty {
      forwardDroppedFiles(filePaths, allowDevicePicker: false)
    }
    for u in customURLs {
      handleRuntimeSchemeURL(u)
    }
  }

  private func handleRuntimeSchemeURL(_ url: URL) {
    let action = (url.host ?? url.path)
      .lowercased()
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    switch action {
    case "clipboard":
      triggerSendClipboard()
    case "settings":
      showMainWindow()
      dispatchToDart("onTrayAction", arguments: ["action": "openSettings"])
    case "web":
      dispatchToDart("onTrayAction", arguments: ["action": "openWebHub"])
    case "open", "window":
      showMainWindow()
      dispatchToDart("onTrayAction", arguments: ["action": "openWindow"])
    default:
      dispatchToDart("onOpenUrl", arguments: ["kind": "url", "url": url.absoluteString])
    }
  }

  // MARK: Flutter MethodChannels Setup

  func attachFlutterWindow(_ window: MainFlutterWindow, controller: FlutterViewController) {
    self.flutterWin = window
    guard !channelsAttached else { return }
    channelsAttached = true

    let messenger = controller.engine.binaryMessenger

    let secure = FlutterMethodChannel(name: "synchub/secure", binaryMessenger: messenger)
    secure.setMethodCallHandler { [weak self] call, result in
      self?.handleSecureCall(call, result: result)
    }
    self.secureChannel = secure

    let desktop = FlutterMethodChannel(name: "synchub/desktop", binaryMessenger: messenger)
    desktop.setMethodCallHandler { [weak self] call, result in
      self?.handleDesktopCall(call, result: result)
    }
    self.desktopChannel = desktop
  }

  private func dispatchToDart(_ method: String, arguments: Any?) {
    if dartReady, let channel = desktopChannel {
      channel.invokeMethod(method, arguments: arguments)
    } else {
      pendingCallbacks.append((method: method, arguments: arguments))
    }
  }

  // MARK: "synchub/secure" Handler

  private func handleSecureCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let dict = call.arguments as? [String: Any]
    let service = (dict?["service"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? SyncHubKeychain.defaultService
    let key = (call.arguments as? String)
      ?? (dict?["key"] as? String)
      ?? (dict?["account"] as? String)
      ?? ""

    switch call.method {
    case "read":
      guard !key.isEmpty else {
        result(nil)
        return
      }
      result(SyncHubKeychain.read(account: key, service: service))

    case "write":
      guard !key.isEmpty else {
        result(FlutterError(code: "INVALID_ARGS", message: "Missing key for keychain write", details: nil))
        return
      }
      let rawValue = dict?["value"] ?? dict?["password"] ?? dict?["data"]
      if rawValue == nil || rawValue is NSNull {
        SyncHubKeychain.delete(account: key, service: service)
        result(true)
        return
      }
      guard let value = rawValue as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "Keychain value must be a String", details: nil))
        return
      }
      let status = SyncHubKeychain.write(account: key, value: value, service: service)
      if status == errSecSuccess {
        result(true)
      } else {
        result(FlutterError(code: "KEYCHAIN_ERROR", message: "SecItem write failed with OSStatus \(status)", details: status))
      }

    case "delete":
      if key.isEmpty {
        result(true)
        return
      }
      let status = SyncHubKeychain.delete(account: key, service: service)
      if status == errSecSuccess {
        result(true)
      } else {
        result(FlutterError(code: "KEYCHAIN_ERROR", message: "SecItemDelete failed with OSStatus \(status)", details: status))
      }

    case "deleteAll", "clear":
      SyncHubKeychain.deleteAll(service: service)
      result(true)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: "synchub/desktop" Handler

  private func handleDesktopCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let dict = call.arguments as? [String: Any]

    switch call.method {
    case "ready":
      dartReady = true
      let flushedEvents = pendingStartupEvents
      pendingStartupEvents.removeAll()

      let includeLegacy = (dict?["migrateLegacy"] as? Bool)
        ?? (dict?["includeLegacy"] as? Bool)
        ?? false
      let readLegacyKeychain = (dict?["readLegacyKeychain"] as? Bool) ?? false

      if includeLegacy {
        result([
          "platform": "macos",
          "minimized": isMinimizedLaunch,
          "launchAtLogin": SyncHubLoginItem.isEnabled(),
          "events": flushedEvents,
          "legacy": Self.migrateLegacyMacState(readLegacyKeychain: readLegacyKeychain),
        ] as [String: Any])
      } else {
        result(flushedEvents)
      }

      // Flush any callbacks (e.g. NSServices or Notification tap) that arrived before Dart became ready
      if !pendingCallbacks.isEmpty {
        let queued = pendingCallbacks
        pendingCallbacks.removeAll()
        DispatchQueue.main.async { [weak self] in
          for item in queued {
            self?.desktopChannel?.invokeMethod(item.method, arguments: item.arguments)
          }
        }
      }

    case "migrateLegacyMacState":
      let readKC = (dict?["readLegacyKeychain"] as? Bool) ?? false
      result(Self.migrateLegacyMacState(readLegacyKeychain: readKC))

    case "showWindow":
      showMainWindow()
      result(true)

    case "hideWindow":
      hideMainWindow()
      result(true)

    case "isWindowVisible":
      result(mainFlutterWindow?.isVisible ?? false)

    case "quit", "exit":
      allowQuit = true
      result(true)
      DispatchQueue.main.async {
        NSApp.terminate(nil)
      }

    case "setAllowQuit":
      let allow = (call.arguments as? Bool) ?? (dict?["allow"] as? Bool) ?? true
      allowQuit = allow
      result(allowQuit)

    case "updateTrayState":
      if let stateDict = dict {
        trayState = TrayStateSnapshot.from(dictionary: stateDict, fallbackLaunchAtLogin: trayState.launchAtLogin)
        let st = trayState.isUploading ? "uploading" : (trayState.isDownloading ? "downloading" : (trayState.connected == true ? "connected" : "idle"))
        menuCache["status"] = st
        menuCache["updated_at"] = ProcessInfo.processInfo.systemUptime
        updateStatusItemAppearance()
        statusMenuDirty = true
      }
      result(true)

    case "getMenuCache":
      result(menuCache)

    case "notify":
      let title = (dict?["title"] as? String) ?? "SyncHub"
      let body = (dict?["body"] as? String) ?? (dict?["message"] as? String) ?? ""
      let path = (dict?["path"] as? String) ?? (dict?["file"] as? String)
      SyncHubNotificationManager.shared.post(title: title, body: body, path: path)
      result(true)

    case "getLaunchAtLogin":
      let enabled = SyncHubLoginItem.isEnabled()
      trayState.launchAtLogin = enabled
      result(enabled)

    case "setLaunchAtLogin":
      let requested = (call.arguments as? Bool)
        ?? (dict?["enabled"] as? Bool)
        ?? (dict?["value"] as? Bool)
        ?? false
      let actual = SyncHubLoginItem.setEnabled(requested)
      trayState.launchAtLogin = actual
      rebuildStatusMenu()
      result(actual)

    case "getClipboardChangeCount":
      result(NSPasteboard.general.changeCount)

    case "isConcealedClipboard", "isClipboardPrivate":
      result(SyncHubClipboard.isConcealed())

    case "readClipboard":
      if SyncHubClipboard.isConcealed() {
        result(["type": "private"])
        return
      }
      let files = SyncHubClipboard.readFiles()
      if !files.isEmpty {
        result(["type": "files", "paths": files])
        return
      }
      if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
        result(["type": "text", "text": text])
        return
      }
      if let png = SyncHubClipboard.readImagePNG(allowFileIcon: false) {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        let fileName = "IMG_\(fmt.string(from: Date())).png"
        result([
          "type": "image",
          "bytes": FlutterStandardTypedData(bytes: png),
          "fileName": fileName,
        ])
        return
      }
      result(nil)

    case "readClipboardFiles":
      result(SyncHubClipboard.readFiles())

    case "readClipboardImage":
      let allowIcon = (dict?["allowFileIcon"] as? Bool) ?? false
      if let png = SyncHubClipboard.readImagePNG(allowFileIcon: allowIcon) {
        result(FlutterStandardTypedData(bytes: png))
      } else {
        result(nil)
      }

    case "writeClipboardImage":
      let imgData: Data?
      if let typed = call.arguments as? FlutterStandardTypedData {
        imgData = typed.data
      } else if let typed = dict?["bytes"] as? FlutterStandardTypedData {
        imgData = typed.data
      } else if let uint8List = dict?["bytes"] as? [UInt8] {
        imgData = Data(uint8List)
      } else {
        imgData = nil
      }
      guard let data = imgData else {
        result(false)
        return
      }
      result(SyncHubClipboard.writeImage(data))

    case "readClipboardText":
      result(NSPasteboard.general.string(forType: .string))

    case "writeClipboardText":
      let text = (call.arguments as? String) ?? (dict?["text"] as? String) ?? ""
      let pb = NSPasteboard.general
      pb.clearContents()
      result(pb.setString(text, forType: .string))

    case "writeClipboardFiles":
      let paths = (call.arguments as? [String]) ?? (dict?["paths"] as? [String]) ?? []
      let urls = paths.map { NSURL(fileURLWithPath: $0) }
      let pb = NSPasteboard.general
      pb.clearContents()
      result(pb.writeObjects(urls))

    case "revealInFinder", "showInFolder":
      let path = (call.arguments as? String) ?? (dict?["path"] as? String) ?? ""
      result(Self.revealInFinder(path: path))

    case "openPath", "openFile":
      let path = (call.arguments as? String) ?? (dict?["path"] as? String) ?? ""
      result(Self.openLocalPathSafely(path: path))

    case "openUrl":
      let urlStr = (call.arguments as? String) ?? (dict?["url"] as? String) ?? ""
      if let u = URL(string: urlStr) {
        result(NSWorkspace.shared.open(u))
      } else {
        result(false)
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: Legacy macOS Migration Helper

  static func migrateLegacyMacState(readLegacyKeychain: Bool = false) -> [String: Any] {
    let fm = FileManager.default
    let home = NSHomeDirectory()

    // 1. ~/Library/Application Support/SyncHub/receiver_state.json
    let supportStateURL = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("SyncHub/receiver_state.json")
    var stateLastId = 0
    if let data = try? Data(contentsOf: supportStateURL),
       let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
       let num = (json["last_id"] as? NSNumber)?.intValue {
      stateLastId = num
    }

    // 2. ~/.synchub/last_id.txt & ~/.synchub/config
    let dotDir = URL(fileURLWithPath: home).appendingPathComponent(".synchub", isDirectory: true)
    let dotLastIdURL = dotDir.appendingPathComponent("last_id.txt")
    var dotLastId = 0
    if let text = try? String(contentsOf: dotLastIdURL, encoding: .utf8),
       let parsed = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
      dotLastId = parsed
    }

    var shellConfig: [String: String] = [:]
    let dotConfigURL = dotDir.appendingPathComponent("config")
    if let cfgText = try? String(contentsOf: dotConfigURL, encoding: .utf8) {
      for line in cfgText.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
        let k = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
        var v = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
          v = String(v.dropFirst().dropLast())
        }
        shellConfig[k] = v
      }
    }

    // 3. Optional pre-migrated snapshot written by scripts/build_mac.sh --install
    let appSupportBundleURL = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("xyz.synchub.synchub/legacy_migration.json")
    var installerSnapshot: [String: Any] = [:]
    if let snapData = try? Data(contentsOf: appSupportBundleURL),
       let snapObj = (try? JSONSerialization.jsonObject(with: snapData)) as? [String: Any] {
      installerSnapshot = snapObj
    }

    // 4. UserDefaults(suiteName: "xyz.020814.synchub")
    let legacySuite = UserDefaults(suiteName: "xyz.020814.synchub")
    let suiteDict = legacySuite?.persistentDomain(forName: "xyz.020814.synchub") ?? [:]

    let hasLegacy = fm.fileExists(atPath: supportStateURL.path)
      || fm.fileExists(atPath: dotLastIdURL.path)
      || fm.fileExists(atPath: dotConfigURL.path)
      || !suiteDict.isEmpty
      || !installerSnapshot.isEmpty

    let snapLastId = (installerSnapshot["last_id"] as? NSNumber)?.intValue ?? 0
    let lastId = max(stateLastId, max(dotLastId, snapLastId))

    let serverURL = (suiteDict["serverURL"] as? String)
      ?? (installerSnapshot["server_url"] as? String)
      ?? shellConfig["SYNCHUB_SERVER"]
      ?? ""
    let username = (suiteDict["username"] as? String)
      ?? (installerSnapshot["username"] as? String)
      ?? shellConfig["SYNCHUB_USER"]
      ?? ""
    let rawRecvDir = (suiteDict["receiveDir"] as? String)
      ?? (installerSnapshot["recv_dir"] as? String)
      ?? shellConfig["SYNCHUB_RECV_DIR"]
      ?? (home as NSString).appendingPathComponent("Desktop/跨端传输文件")
    let receiveDir = (rawRecvDir as NSString).expandingTildeInPath

    var out: [String: Any] = [
      "found": hasLegacy,
      "lastId": lastId,
      "last_id": lastId,
      "serverUrl": serverURL,
      "server_url": serverURL,
      "username": username,
      "receiveDir": receiveDir,
      "recv_dir": receiveDir,
      "autoReceive": (suiteDict["autoReceive"] as? Bool) ?? true,
      "clipSync": (suiteDict["clipSync"] as? Bool) ?? true,
      "clipImages": (suiteDict["clipImages"] as? Bool) ?? true,
      "clipFiles": (suiteDict["clipFiles"] as? Bool) ?? true,
      "autoSendFolder": (suiteDict["autoSendFolder"] as? Bool) ?? true,
      "notifications": (suiteDict["notifications"] as? Bool) ?? true,
      "launchAtLogin": (suiteDict["launchAtLogin"] as? Bool) ?? false,
    ]

    if readLegacyKeychain && !username.isEmpty {
      if let pw = SyncHubKeychain.read(account: username, service: "xyz.020814.synchub") {
        out["password"] = pw
      }
    }
    return out
  }

  // MARK: Safe Local File Reveal / Open

  private static let revealOnlyExtensions: Set<String> = [
    "command", "tool", "sh", "bash", "zsh", "csh", "ksh", "terminal",
    "scpt", "scptd", "applescript", "workflow", "action", "jar", "app", "pkg",
  ]

  private static func revealInFinder(path: String) -> Bool {
    guard !path.isEmpty else { return false }
    let fm = FileManager.default
    let url = URL(fileURLWithPath: path)
    if fm.fileExists(atPath: url.path) {
      NSWorkspace.shared.activateFileViewerSelecting([url])
      return true
    }
    let parent = url.deletingLastPathComponent()
    var isDir: ObjCBool = false
    if fm.fileExists(atPath: parent.path, isDirectory: &isDir), isDir.boolValue {
      return NSWorkspace.shared.open(parent)
    }
    return false
  }

  private static func openLocalPathSafely(path: String) -> Bool {
    guard !path.isEmpty else { return false }
    let fm = FileManager.default
    let url = URL(fileURLWithPath: path)
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
      return revealInFinder(path: path)
    }
    if isDir.boolValue {
      return NSWorkspace.shared.open(url)
    }
    if revealOnlyExtensions.contains(url.pathExtension.lowercased()) || !fm.isReadableFile(atPath: url.path) {
      NSWorkspace.shared.activateFileViewerSelecting([url])
      return true
    }
    if NSWorkspace.shared.urlForApplication(toOpen: url) != nil && NSWorkspace.shared.open(url) {
      return true
    }
    NSWorkspace.shared.activateFileViewerSelecting([url])
    return true
  }

  // MARK: Global ⇧⌘V Hotkey Registration

  private func registerGlobalHotKey() {
    guard hotKeyRef == nil else { return }
    var eventSpec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    let handlerStatus = InstallEventHandler(
      GetApplicationEventTarget(),
      syncHubCarbonHotKeyCallback,
      1,
      &eventSpec,
      nil,
      &hotKeyHandlerRef
    )
    if handlerStatus != noErr {
      NSLog("SyncHub: InstallEventHandler failed with status \(handlerStatus)")
    }

    let hkID = EventHotKeyID(signature: kSyncHubHotKeySignature, id: kSyncHubHotKeyID)
    let regStatus = RegisterEventHotKey(
      UInt32(kVK_ANSI_V),
      UInt32(cmdKey | shiftKey),
      hkID,
      GetApplicationEventTarget(),
      0,
      &hotKeyRef
    )
    if regStatus != noErr {
      NSLog("SyncHub: RegisterEventHotKey(⇧⌘V) failed with status \(regStatus)")
    }
  }

  private func unregisterGlobalHotKey() {
    if let ref = hotKeyRef {
      UnregisterEventHotKey(ref)
      hotKeyRef = nil
    }
    if let handler = hotKeyHandlerRef {
      RemoveEventHandler(handler)
      hotKeyHandlerRef = nil
    }
  }

  func triggerSendClipboard() {
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastClipboardTriggerAt > 0.15 else { return }
    lastClipboardTriggerAt = now
    dispatchToDart("onTrayAction", arguments: ["action": "sendClipboard"])
  }

  // MARK: NSServices Handler ("发送到 SyncHub")

  @objc func sendText(
    _ pboard: NSPasteboard,
    userData: String?,
    error: AutoreleasingUnsafeMutablePointer<NSString?>
  ) {
    if let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
       !urls.isEmpty {
      let paths = urls.map { $0.path }
      forwardDroppedFiles(paths, allowDevicePicker: false)
      return
    }
    let raw = pboard.string(forType: .string)
      ?? pboard.string(forType: NSPasteboard.PasteboardType("NSStringPboardType"))
    guard let text = raw, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      error.pointee = "没有选中的文字或文件" as NSString
      return
    }
    dispatchToDart("onServiceText", arguments: ["text": text])
  }

  // MARK: Status Bar Icon & Menu

  private func ensureStatusBarDragRegistration() {
    guard let button = statusItem?.button, let win = button.window else { return }
    win.registerForDraggedTypes([.fileURL])
    if win.delegate !== self {
      win.delegate = self
    }
  }

  private func setUpStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusMenu.delegate = self
    statusMenu.autoenablesItems = false
    item.menu = statusMenu

    if let button = item.button {
      button.imagePosition = .imageLeft
      button.toolTip = "SyncHub — 拖拽文件到此图标即可跨端发送"
      button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    }

    self.statusItem = item
    ensureStatusBarDragRegistration()
    DispatchQueue.main.async { [weak self] in
      self?.ensureStatusBarDragRegistration()
    }
    updateStatusItemAppearance()
    rebuildStatusMenu()
  }

  private func updateStatusItemAppearance() {
    guard let button = statusItem?.button else { return }
    ensureStatusBarDragRegistration()

    let symbolName: String
    var titleText = ""

    if dragHighlight {
      symbolName = "tray.and.arrow.up.fill"
    } else if trayState.isUploading {
      symbolName = "arrow.up.circle"
      let pct = Int((trayState.progress * 100.0).rounded())
      titleText = " \(pct)%"
    } else if trayState.isDownloading {
      symbolName = "arrow.down.circle"
      if trayState.progress > 0 {
        let pct = Int((trayState.progress * 100.0).rounded())
        titleText = " \(pct)%"
      }
    } else if trayState.connected == false {
      symbolName = "exclamationmark.arrow.triangle.2.circlepath"
    } else {
      symbolName = "arrow.up.arrow.down.circle"
    }

    let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "SyncHub")
      ?? NSImage(systemSymbolName: "exclamationmark.arrow.circlepath", accessibilityDescription: "SyncHub")
      ?? NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "SyncHub")
    img?.isTemplate = true
    button.image = img
    if img == nil && titleText.isEmpty {
      button.title = "SyncHub"
    } else {
      button.title = titleText
    }
    button.toolTip = trayState.tooltip
    button.appearsDisabled = (!trayState.autoReceive && !trayState.clipSync
      && !trayState.isUploading && !trayState.isDownloading && !dragHighlight)
  }

  func menuWillOpen(_ menu: NSMenu) {
    if menu === statusMenu {
      trayState.launchAtLogin = SyncHubLoginItem.isEnabled()
      if statusMenuDirty {
        rebuildStatusMenu()
        statusMenuDirty = false
      }
      let cc = NSPasteboard.general.changeCount
      if cc != lastClipboardChangeCount {
        lastClipboardChangeCount = cc
        dispatchToDart("clipboard_changed", arguments: ["changeCount": cc])
      }
    }
  }

  private func rebuildStatusMenu() {
    statusMenu.removeAllItems()

    // 1. Status row
    let statusRow = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    statusRow.isEnabled = false
    statusRow.attributedTitle = buildStatusAttributedTitle()
    statusMenu.addItem(statusRow)
    statusMenu.addItem(.separator())

    // 2. 打开 SyncHub 主窗口
    statusMenu.addItem(makeMenuItem(
      title: "打开 SyncHub 主窗口",
      action: #selector(menuShowMainWindow(_:)),
      symbol: "macwindow"
    ))
    statusMenu.addItem(.separator())

    // 3. 发送文件… (⌘O) + per-device quick items
    let sendFileItem = makeMenuItem(
      title: "发送文件…",
      action: #selector(menuSendFiles(_:)),
      keyEquivalent: "o",
      modifiers: [.command],
      symbol: "doc.badge.plus"
    )
    statusMenu.addItem(sendFileItem)

    for dev in trayState.devices {
      let devTitle = dev.online ? "发送到 \(dev.name)…" : "发送到 \(dev.name)（离线队列）…"
      let devItem = makeMenuItem(
        title: devTitle,
        action: #selector(menuSendToDevice(_:)),
        symbol: symbolForPlatform(dev.platform)
      )
      devItem.representedObject = dev.id
      statusMenu.addItem(devItem)
    }

    // 4. 发送剪贴板 (⇧⌘V)
    let sendClipItem = makeMenuItem(
      title: "发送剪贴板",
      action: #selector(menuSendClipboard(_:)),
      keyEquivalent: "v",
      modifiers: [.command, .shift],
      symbol: "doc.on.clipboard"
    )
    statusMenu.addItem(sendClipItem)
    statusMenu.addItem(.separator())

    // 5. 最近项目 submenu (up to 8 items + ⌥ / ⌘ alternate items)
    let recentRoot = makeMenuItem(
      title: "最近项目",
      action: nil,
      symbol: "clock.arrow.circlepath"
    )
    let recentSubmenu = NSMenu(title: "最近项目")
    recentSubmenu.autoenablesItems = false

    if trayState.recentItems.isEmpty {
      let empty = NSMenuItem(title: "暂无最近项目", action: nil, keyEquivalent: "")
      empty.isEnabled = false
      recentSubmenu.addItem(empty)
    } else {
      let hint = NSMenuItem(title: "", action: nil, keyEquivalent: "")
      hint.isEnabled = false
      hint.attributedTitle = NSAttributedString(
        string: "按住 ⌥ 在 Finder 中显示 · 按住 ⌘ 复制路径",
        attributes: [
          .font: NSFont.systemFont(ofSize: 11),
          .foregroundColor: NSColor.tertiaryLabelColor,
        ]
      )
      recentSubmenu.addItem(hint)
      recentSubmenu.addItem(.separator())

      for recent in trayState.recentItems.prefix(8) {
        let primary = NSMenuItem(title: recent.title, action: #selector(menuOpenRecent(_:)), keyEquivalent: "")
        primary.target = self
        primary.representedObject = ["itemId": recent.rawId, "modifier": "none"] as [String: Any]
        primary.attributedTitle = buildRecentAttributedTitle(recent, prefix: "")
        primary.toolTip = "点击打开\n⌥ 在 Finder 中显示 · ⌘ 复制路径"
        recentSubmenu.addItem(primary)

        let optAlt = NSMenuItem(title: "在 Finder 中显示", action: #selector(menuOpenRecent(_:)), keyEquivalent: "")
        optAlt.target = self
        optAlt.isAlternate = true
        optAlt.keyEquivalentModifierMask = [.option]
        optAlt.representedObject = ["itemId": recent.rawId, "modifier": "alt"] as [String: Any]
        optAlt.attributedTitle = buildRecentAttributedTitle(recent, prefix: "在 Finder 中显示 · ")
        recentSubmenu.addItem(optAlt)

        let cmdAlt = NSMenuItem(title: "复制路径", action: #selector(menuOpenRecent(_:)), keyEquivalent: "")
        cmdAlt.target = self
        cmdAlt.isAlternate = true
        cmdAlt.keyEquivalentModifierMask = [.command]
        cmdAlt.representedObject = ["itemId": recent.rawId, "modifier": "cmd"] as [String: Any]
        cmdAlt.attributedTitle = buildRecentAttributedTitle(recent, prefix: "复制路径 · ")
        recentSubmenu.addItem(cmdAlt)
      }
    }
    recentRoot.submenu = recentSubmenu
    statusMenu.addItem(recentRoot)

    // 6. 打开接收文件夹, 打开云端收藏网页
    statusMenu.addItem(makeMenuItem(
      title: "打开接收文件夹",
      action: #selector(menuOpenReceiveFolder(_:)),
      symbol: "folder"
    ))
    statusMenu.addItem(makeMenuItem(
      title: "打开云端收藏网页",
      action: #selector(menuOpenCloudWeb(_:)),
      symbol: "globe"
    ))
    statusMenu.addItem(.separator())

    // 7. Checkable toggles: 自动接收文件, 同步剪贴板, 开机自动启动
    let autoRecvItem = makeMenuItem(title: "自动接收文件", action: #selector(menuToggleAutoReceive(_:)))
    autoRecvItem.state = trayState.autoReceive ? .on : .off
    statusMenu.addItem(autoRecvItem)

    let clipSyncItem = makeMenuItem(title: "同步剪贴板", action: #selector(menuToggleClipSync(_:)))
    clipSyncItem.state = trayState.clipSync ? .on : .off
    statusMenu.addItem(clipSyncItem)

    let loginItem = makeMenuItem(title: "开机自动启动", action: #selector(menuToggleLaunchAtLogin(_:)))
    loginItem.state = trayState.launchAtLogin ? .on : .off
    statusMenu.addItem(loginItem)

    statusMenu.addItem(.separator())

    // 8. 设置… (⌘,), 退出 SyncHub (⌘Q)
    statusMenu.addItem(makeMenuItem(
      title: "设置…",
      action: #selector(menuOpenSettings(_:)),
      keyEquivalent: ",",
      modifiers: [.command],
      symbol: "gearshape"
    ))
    statusMenu.addItem(makeMenuItem(
      title: "退出 SyncHub",
      action: #selector(menuQuitApp(_:)),
      keyEquivalent: "q",
      modifiers: [.command]
    ))
  }

  private func buildStatusAttributedTitle() -> NSAttributedString {
    let dotColor: NSColor
    let headline: String

    if !trayState.statusLine.isEmpty {
      headline = trayState.statusLine
      dotColor = trayState.connected == true
        ? .systemGreen
        : (trayState.connected == false ? .systemRed : .secondaryLabelColor)
    } else if trayState.isUploading {
      let pct = Int((trayState.progress * 100.0).rounded())
      headline = "正在发送 · \(pct)%"
      dotColor = .systemBlue
    } else if trayState.isDownloading {
      let pct = Int((trayState.progress * 100.0).rounded())
      headline = trayState.progress > 0 ? "正在接收 · \(pct)%" : "正在接收文件…"
      dotColor = .systemBlue
    } else if trayState.connected == true {
      headline = "已连接 · \(trayState.onlineCount) 台设备在线"
      dotColor = .systemGreen
    } else if trayState.connected == false {
      headline = "连接断开 · 正在重连"
      dotColor = .systemOrange
    } else {
      headline = "正在连接 SyncHub…"
      dotColor = .secondaryLabelColor
    }

    let out = NSMutableAttributedString(
      string: "● ",
      attributes: [
        .font: NSFont.systemFont(ofSize: 11, weight: .bold),
        .foregroundColor: dotColor,
      ]
    )
    out.append(NSAttributedString(
      string: headline,
      attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
        .foregroundColor: NSColor.labelColor,
      ]
    ))

    if !trayState.detailLine.isEmpty {
      out.append(NSAttributedString(
        string: "\n   " + trayState.detailLine,
        attributes: [
          .font: NSFont.systemFont(ofSize: 11),
          .foregroundColor: NSColor.secondaryLabelColor,
        ]
      ))
    }
    return out
  }

  private func buildRecentAttributedTitle(_ item: TrayRecentItem, prefix: String) -> NSAttributedString {
    var cleanTitle = item.title.replacingOccurrences(of: "\n", with: " ")
    if cleanTitle.count > 36 {
      cleanTitle = String(cleanTitle.prefix(24)) + "…" + String(cleanTitle.suffix(10))
    }
    let result = NSMutableAttributedString(
      string: prefix + cleanTitle,
      attributes: [
        .font: NSFont.menuFont(ofSize: 13),
        .foregroundColor: NSColor.labelColor,
      ]
    )
    if !item.subtitle.isEmpty {
      result.append(NSAttributedString(
        string: "\n" + item.subtitle,
        attributes: [
          .font: NSFont.systemFont(ofSize: 11),
          .foregroundColor: NSColor.secondaryLabelColor,
        ]
      ))
    }
    return result
  }

  private func makeMenuItem(
    title: String,
    action: Selector?,
    keyEquivalent: String = "",
    modifiers: NSEvent.ModifierFlags = [.command],
    symbol: String? = nil
  ) -> NSMenuItem {
    let mi = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
    if action != nil {
      mi.target = self
    }
    if !keyEquivalent.isEmpty {
      mi.keyEquivalentModifierMask = modifiers
    }
    if let sym = symbol, let img = NSImage(systemSymbolName: sym, accessibilityDescription: nil) {
      img.isTemplate = true
      mi.image = img
    }
    return mi
  }

  private func symbolForPlatform(_ platform: String) -> String {
    switch platform.lowercased() {
    case "windows":
      return "desktopcomputer"
    case "macos", "mac":
      return "laptopcomputer"
    case "android", "ios":
      return "iphone"
    default:
      return "paperplane"
    }
  }

  // MARK: Menu Actions

  @objc private func menuShowMainWindow(_ sender: Any?) {
    showMainWindow()
    dispatchToDart("onTrayAction", arguments: ["action": "openWindow"])
  }

  @objc private func menuSendFiles(_ sender: Any?) {
    activateApplication()
    dispatchToDart("onTrayAction", arguments: ["action": "sendFiles"])
  }

  @objc private func menuSendToDevice(_ sender: NSMenuItem) {
    guard let deviceId = sender.representedObject as? String, !deviceId.isEmpty else { return }
    activateApplication()
    dispatchToDart("onTrayAction", arguments: ["action": "sendToDevice", "deviceId": deviceId])
  }

  @objc private func menuSendClipboard(_ sender: Any?) {
    triggerSendClipboard()
  }

  @objc private func menuOpenRecent(_ sender: NSMenuItem) {
    guard let rep = sender.representedObject as? [String: Any],
          let itemId = rep["itemId"] else {
      return
    }
    var modifier = (rep["modifier"] as? String) ?? "none"
    if modifier == "none" {
      let flags = NSEvent.modifierFlags
      if flags.contains(.option) {
        modifier = "alt"
      } else if flags.contains(.command) {
        modifier = "cmd"
      }
    }
    dispatchToDart("onTrayAction", arguments: [
      "action": "openRecent",
      "itemId": itemId,
      "modifier": modifier,
    ])
  }

  @objc private func menuOpenReceiveFolder(_ sender: Any?) {
    dispatchToDart("onTrayAction", arguments: ["action": "openRecvDir"])
  }

  @objc private func menuOpenCloudWeb(_ sender: Any?) {
    dispatchToDart("onTrayAction", arguments: ["action": "openWebHub"])
  }

  @objc private func menuToggleAutoReceive(_ sender: Any?) {
    let next = !trayState.autoReceive
    trayState.autoReceive = next
    updateStatusItemAppearance()
    rebuildStatusMenu()
    dispatchToDart("onTrayAction", arguments: [
      "action": "toggleAutoAccept",
      "enabled": next,
      "value": next,
    ])
  }

  @objc private func menuToggleClipSync(_ sender: Any?) {
    let next = !trayState.clipSync
    trayState.clipSync = next
    updateStatusItemAppearance()
    rebuildStatusMenu()
    dispatchToDart("onTrayAction", arguments: [
      "action": "toggleClipSync",
      "enabled": next,
      "value": next,
    ])
  }

  @objc private func menuToggleLaunchAtLogin(_ sender: Any?) {
    let next = !trayState.launchAtLogin
    let actual = SyncHubLoginItem.setEnabled(next)
    trayState.launchAtLogin = actual
    rebuildStatusMenu()
    dispatchToDart("onTrayAction", arguments: [
      "action": "toggleLaunchAtLogin",
      "enabled": actual,
      "value": actual,
    ])
  }

  @objc private func menuOpenSettings(_ sender: Any?) {
    showMainWindow()
    dispatchToDart("onTrayAction", arguments: ["action": "openSettings"])
  }

  @objc private func menuQuitApp(_ sender: Any?) {
    allowQuit = true
    if dartReady, let channel = desktopChannel {
      channel.invokeMethod("onTrayAction", arguments: ["action": "quit"])
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
      NSApp.terminate(nil)
    }
  }

  // MARK: Drag-and-Drop onto Status Bar Icon

  private func extractDraggedFileURLs(_ info: NSDraggingInfo) -> [URL] {
    return (info.draggingPasteboard.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]
    ) as? [URL]) ?? []
  }

  func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard !extractDraggedFileURLs(sender).isEmpty else { return [] }
    dragHighlight = true
    statusItem?.button?.highlight(true)
    updateStatusItemAppearance()
    return .copy
  }

  func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    return extractDraggedFileURLs(sender).isEmpty ? [] : .copy
  }

  func draggingExited(_ sender: NSDraggingInfo?) {
    clearDragHighlight()
  }

  func draggingEnded(_ sender: NSDraggingInfo) {
    clearDragHighlight()
  }

  func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    return !extractDraggedFileURLs(sender).isEmpty
  }

  func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let urls = extractDraggedFileURLs(sender)
    clearDragHighlight()
    guard !urls.isEmpty else { return false }
    let paths = urls.map { $0.path }
    forwardDroppedFiles(paths, allowDevicePicker: true)
    return true
  }

  private func clearDragHighlight() {
    guard dragHighlight else { return }
    dragHighlight = false
    statusItem?.button?.highlight(false)
    updateStatusItemAppearance()
  }

  private func forwardDroppedFiles(_ paths: [String], allowDevicePicker: Bool) {
    guard !paths.isEmpty else { return }
    if allowDevicePicker, let button = statusItem?.button {
      pendingDropPaths = paths
      DispatchQueue.main.async { [weak self] in
        self?.presentDropTargetPicker(under: button)
      }
      return
    }
    dispatchToDart("onDroppedFiles", arguments: [
      "paths": paths,
      "deviceId": NSNull(),
    ])
  }

  private func presentDropTargetPicker(under button: NSStatusBarButton) {
    let paths = pendingDropPaths
    guard !paths.isEmpty else { return }

    let picker = NSMenu(title: "选择发送目标")
    picker.autoenablesItems = false

    let headerTitle = paths.count == 1
      ? "发送「\((paths[0] as NSString).lastPathComponent)」到："
      : "发送 \(paths.count) 个项目到："
    let header = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
    header.isEnabled = false
    picker.addItem(header)
    picker.addItem(.separator())

    if !trayState.devices.isEmpty {
      for dev in trayState.devices {
        let label = dev.online ? dev.name : "\(dev.name)（离线队列）"
        let mi = makeMenuItem(
          title: label,
          action: #selector(dropTargetDeviceSelected(_:)),
          symbol: symbolForPlatform(dev.platform)
        )
        mi.representedObject = dev.id
        picker.addItem(mi)
      }
      picker.addItem(.separator())
    }

    let cloudStarItem = makeMenuItem(
      title: "存到云端收藏（永久保留）",
      action: #selector(dropTargetCloudSelected(_:)),
      symbol: "icloud.and.arrow.up"
    )
    picker.addItem(cloudStarItem)

    let cloudTempItem = makeMenuItem(
      title: "发送到云端中转（72 小时）",
      action: #selector(dropTargetCloudTempSelected(_:)),
      symbol: "clock.arrow.circlepath"
    )
    picker.addItem(cloudTempItem)

    picker.addItem(.separator())
    let mainWinItem = makeMenuItem(
      title: "在主窗口中选择…",
      action: #selector(dropTargetOpenMainWindowSelected(_:)),
      symbol: "macwindow"
    )
    picker.addItem(mainWinItem)

    let anchorY = button.isFlipped ? button.bounds.maxY + 2 : button.bounds.minY - 2
    picker.popUp(positioning: nil, at: NSPoint(x: 0, y: anchorY), in: button)
  }

  @objc private func dropTargetDeviceSelected(_ sender: NSMenuItem) {
    let paths = pendingDropPaths
    pendingDropPaths.removeAll()
    guard !paths.isEmpty, let deviceId = sender.representedObject as? String else { return }
    dispatchToDart("onDroppedFiles", arguments: [
      "paths": paths,
      "deviceId": deviceId,
    ])
  }

  @objc private func dropTargetCloudSelected(_ sender: NSMenuItem) {
    let paths = pendingDropPaths
    pendingDropPaths.removeAll()
    guard !paths.isEmpty else { return }
    dispatchToDart("onDroppedFiles", arguments: [
      "paths": paths,
      "deviceId": NSNull(),
      "cloud": true,
      "star": true,
    ])
  }

  @objc private func dropTargetCloudTempSelected(_ sender: NSMenuItem) {
    let paths = pendingDropPaths
    pendingDropPaths.removeAll()
    guard !paths.isEmpty else { return }
    dispatchToDart("onDroppedFiles", arguments: [
      "paths": paths,
      "deviceId": NSNull(),
      "cloud": true,
      "star": false,
    ])
  }

  @objc private func dropTargetOpenMainWindowSelected(_ sender: NSMenuItem) {
    let paths = pendingDropPaths
    pendingDropPaths.removeAll()
    guard !paths.isEmpty else { return }
    showMainWindow()
    dispatchToDart("onDroppedFiles", arguments: [
      "paths": paths,
      "deviceId": NSNull(),
    ])
  }
}
