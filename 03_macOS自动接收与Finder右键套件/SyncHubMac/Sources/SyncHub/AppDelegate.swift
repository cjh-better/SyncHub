// AppDelegate.swift — status item, menu, auto-receive timer, Finder / URL-scheme / Services entry points.
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, NSDraggingDestination {
    private let settings = AppSettings.shared
    private let uploads = UploadManager.shared
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    private var client: HubClient?
    private var receiver: HubAutoReceiver!
    private var pollTimer: Timer?
    private var heartbeatTimer: Timer?
    private let clipSync = ClipboardSync()

    // connection state shown in the menu header
    private var connected: Bool?
    private var lastSync: Date?
    private var lastError: String?
    private var recent: [HubItem] = []
    private var recentFetchedAt = Date.distantPast
    private var storage: HubStorage?              // last known server disk usage (cached; never blocks the menu)
    private var storageFetchedAt = Date.distantPast
    private var storageLoading = false
    private var downloading = 0
    private var dragHighlight = false
    private var pendingOpen: [URL] = []
    private var launched = false

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only one copy may sync: a second instance (e.g. another SyncHub.app elsewhere on disk) would see the
        // first one's clipboard writes as local copies and PUT them straight back to the server.
        if let id = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: id)
               .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }) {
            NSLog("SyncHub: already running (pid \(other.processIdentifier)); this copy quits")
            other.activate(options: [])
            NSApp.terminate(nil)
            return
        }
        Notifier.shared.setUp()

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SyncHub", isDirectory: true)
        receiver = HubAutoReceiver(
            stateURL: support.appendingPathComponent("receiver_state.json"),
            legacyStateURL: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".synchub/last_id.txt"),
            clientProvider: { [weak self] in self?.currentClient() },
            directoryProvider: { AppSettings.shared.receiveURL })
        receiver.onReceived = { [weak self] item, url in
            DispatchQueue.main.async { self?.didReceive(item, at: url) }
        }
        receiver.onPoll = { [weak self] r in DispatchQueue.main.async { self?.record(r.map { _ in () }) } }

        uploads.clientProvider = { [weak self] in self?.currentClient() }
        uploads.onChange = { [weak self] in self?.updateIcon() }
        uploads.onJobFinished = { [weak self] job in self?.uploadFinished(job) }

        clipSync.onStatus = { [weak self] _ in
            guard let self = self else { return }
            if self.menuIsOpen { self.rebuildMenu() }
        }

        setUpStatusItem()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged(_:)),
                                               name: .settingsChanged, object: nil)
        restartTimers()
        clipSync.restart()
        // After sleep the network may be gone for a while; restart so polling resumes at the normal rate.
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake(_:)),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        refreshRecent(force: true)
        refreshStorage(force: true)
        launched = true
        if !pendingOpen.isEmpty { handle(pendingOpen); pendingOpen = [] }
        if settings.isFirstRun { SettingsWindowController.shared.show() }
    }

    /// Double-clicking the app while it runs opens Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show(); return false
    }

    /// Files from Finder Quick Action / `open -a SyncHub file…`, and synchub:// URLs.
    func application(_ application: NSApplication, open urls: [URL]) {
        if launched { handle(urls) } else { pendingOpen += urls }
    }

    private func handle(_ urls: [URL]) {
        var files = urls.filter { $0.isFileURL }
        for u in urls where u.scheme?.lowercased() == "synchub" {
            let action = (u.host ?? u.path).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let q = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? []
            switch action {
            case "send": files += q.filter { $0.name == "path" }.compactMap { $0.value }.map { URL(fileURLWithPath: $0) }
            case "clipboard": sendClipboard(nil)
            case "settings": openSettings(nil)
            case "web": openWeb(nil)
            default: break
            }
        }
        if !files.isEmpty { send(files) }
    }

    // MARK: client / timers

    private let clientLock = NSLock()
    /// Also called from the receiver's background queue, hence the lock.
    private func currentClient() -> HubClient? {
        clientLock.lock(); defer { clientLock.unlock() }
        if let c = client { return c }
        let cfg = settings.config
        guard !cfg.normalizedBase.isEmpty else { return nil }
        client = HubClient(config: cfg)
        return client
    }

    @objc private func settingsChanged(_ n: Notification) {
        clientLock.lock()
        client?.invalidate(); client = nil          // running uploads keep their own session and finish
        clientLock.unlock()
        connected = nil; lastError = nil
        restartTimers(); refreshRecent(force: true)
        storage = nil; refreshStorage(force: true)
        clipSync.restart()
    }

    @objc private func didWake(_ n: Notification) { clipSync.restart() }

    private func restartTimers() {
        pollTimer?.invalidate(); pollTimer = nil
        heartbeatTimer?.invalidate()
        if settings.autoReceive {
            let t = Timer(timeInterval: settings.pollSeconds, target: self, selector: #selector(pollTick(_:)),
                          userInfo: nil, repeats: true)
            t.tolerance = 0.5
            RunLoop.main.add(t, forMode: .common)
            pollTimer = t
            receiver.pollOnce()
        }
        // Keeps the "connected / last sync" line honest even with auto-receive off.
        let hb = Timer(timeInterval: 60, target: self, selector: #selector(heartbeatTick(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(hb, forMode: .common)
        heartbeatTimer = hb
        updateIcon()
    }

    @objc private func pollTick(_ t: Timer) { receiver.pollOnce() }
    @objc private func heartbeatTick(_ t: Timer) { if !settings.autoReceive { refreshRecent(force: true) } }

    private func record(_ r: Result<Void, HubError>) {
        let before = (connected, lastError)
        switch r {
        case .success: connected = true; lastSync = Date(); lastError = nil
        case .failure(let e) where e.isCancelled: break
        case .failure(let e): connected = false; lastError = e.localizedDescription
        }
        updateIcon()
        if menuIsOpen && (before.0 != connected || before.1 != lastError) { rebuildMenu() }
    }

    // MARK: status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        if let b = statusItem.button {
            b.imagePosition = .imageLeft
            b.toolTip = "SyncHub 跨端传输 — 可把文件拖到这里发送"
            // Drag & drop onto the menu-bar icon: the status bar window forwards dragging to its delegate.
            b.window?.registerForDraggedTypes([.fileURL])
            b.window?.delegate = self
        }
        updateIcon()
        rebuildMenu()
    }

    private func updateIcon() {
        guard let b = statusItem?.button else { return }
        let active = uploads.activeJobs
        let symbol: String
        if dragHighlight { symbol = "tray.and.arrow.up.fill" }
        else if !active.isEmpty { symbol = "arrow.up.circle" }
        else if downloading > 0 { symbol = "arrow.down.circle" }
        else if connected == false { symbol = "exclamationmark.arrow.triangle.2.circlepath" }
        else { symbol = "arrow.up.arrow.down.circle" }
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "SyncHub")
        img?.isTemplate = true
        b.image = img
        b.appearsDisabled = !settings.autoReceive && !settings.clipSync && active.isEmpty && !dragHighlight
        b.title = active.isEmpty ? "" : " \(Int(uploads.totalFraction * 100))%"
        b.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    }

    // MARK: drag onto status item (NSWindowDelegate receives NSDraggingDestination calls)

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(sender).isEmpty else { return [] }
        dragHighlight = true; statusItem.button?.highlight(true); updateIcon()
        return .copy
    }
    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { fileURLs(sender).isEmpty ? [] : .copy }
    func draggingExited(_ sender: NSDraggingInfo?) { endDrag() }
    func draggingEnded(_ sender: NSDraggingInfo) { endDrag() }
    func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        endDrag()
        guard !urls.isEmpty else { return false }
        send(urls)
        return true
    }
    private func endDrag() {
        guard dragHighlight else { return }
        dragHighlight = false; statusItem.button?.highlight(false); updateIcon()
    }

    // MARK: menu

    private var menuIsOpen = false
    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        rebuildMenu()
        refreshRecent(force: Date().timeIntervalSince(recentFetchedAt) > 3)
        refreshStorage(force: false)
    }
    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }

    private func refreshRecent(force: Bool) {
        guard force, let c = currentClient() else { return }
        recentFetchedAt = Date()
        c.listItems(limit: 12) { [weak self] r in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if case .success(let items) = r { self.recent = items }
                self.record(r.map { _ in () })
                self.rebuildMenu()
            }
        }
    }

    /// Cached GET /api/hub/storage: at most every 30 s (on menu open), or forced after an upload / settings change.
    private func refreshStorage(force: Bool) {
        guard !storageLoading, force || Date().timeIntervalSince(storageFetchedAt) > 30,
              let c = currentClient() else { return }
        storageLoading = true
        c.storage { [weak self] r in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.storageLoading = false
                self.storageFetchedAt = Date()
                if case .success(let s) = r, s != self.storage {
                    self.storage = s
                    if self.menuIsOpen { self.rebuildMenu() }
                }
            }
        }
    }

    /// "存储 已用 10.6 GB / 58.9 GB · 剩余 45.3 GB" — small grey line; orange / red when the disk is nearly full.
    private func storageTitle(_ s: HubStorage) -> NSAttributedString {
        let color: NSColor = s.usedFraction >= 0.95 ? .systemRed : (s.usedFraction >= 0.85 ? .systemOrange : .secondaryLabelColor)
        return NSAttributedString(string: s.menuLine, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: color])
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let header = NSMenuItem()
        header.view = headerView()
        menu.addItem(header)
        if let s = storage {
            let st = NSMenuItem(title: s.menuLine, action: nil, keyEquivalent: "")
            st.isEnabled = false
            st.attributedTitle = storageTitle(s)
            if let h = s.hubBytes { st.toolTip = "SyncHub 占用 \(HubStorage.fmt(h)) · 已用 \(Int((s.usedFraction * 100).rounded()))%" }
            menu.addItem(st)
        }

        let auto = item("自动接收文件", #selector(toggleAutoReceive(_:)))
        auto.state = settings.autoReceive ? .on : .off
        menu.addItem(auto)
        let clip = item("同步剪贴板", #selector(toggleClipSync(_:)))
        clip.state = settings.clipSync ? .on : .off
        clip.toolTip = "在 Mac、Windows、手机之间自动同步复制的文字\(settings.clipImages ? "和图片" : "")"
        menu.addItem(clip)
        if settings.clipSync {
            let st = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            st.isEnabled = false
            st.attributedTitle = clipStatusTitle(clipSync.status)
            menu.addItem(st)
        }
        menu.addItem(item("打开接收文件夹", #selector(openReceiveFolder(_:)), symbol: "folder"))
        if !uploads.jobs.isEmpty {
            menu.addItem(item("显示发送进度", #selector(showUploads(_:)), symbol: "arrow.up.circle"))
        }

        menu.addItem(.separator())
        let sec = NSMenuItem(title: "最近项目", action: nil, keyEquivalent: "")
        sec.isEnabled = false
        menu.addItem(sec)
        if recent.isEmpty {
            let e = NSMenuItem(title: connected == false ? "无法获取（见上方错误）" : "暂无项目", action: nil, keyEquivalent: "")
            e.isEnabled = false
            menu.addItem(e)
        }
        for it in recent.prefix(8) {
            let mi = NSMenuItem(title: it.displayName, action: #selector(openRecent(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = it
            mi.attributedTitle = recentTitle(it)
            mi.toolTip = it.isFile ? "点击下载并打开（按住 ⌥ 改为在 Finder 中显示）" : "点击复制到剪贴板（按住 ⌥ 在网页中查看）"
            menu.addItem(mi)
            let alt = NSMenuItem(title: "", action: #selector(openRecentAlt(_:)), keyEquivalent: "")
            alt.target = self
            alt.representedObject = it
            alt.attributedTitle = recentTitle(it, alt: true)
            alt.isAlternate = true
            alt.keyEquivalentModifierMask = .option
            menu.addItem(alt)
        }
        menu.addItem(item("在网页中查看全部…", #selector(openWeb(_:)), symbol: "safari"))

        menu.addItem(.separator())
        let sendFile = item("发送文件…", #selector(sendFiles(_:)), symbol: "doc.badge.plus")
        sendFile.keyEquivalent = "o"
        menu.addItem(sendFile)
        let sendClip = item("发送剪贴板", #selector(sendClipboard(_:)), symbol: "doc.on.clipboard")
        sendClip.keyEquivalent = "v"; sendClip.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(sendClip)
        menu.addItem(item("打开 SyncHub 网页", #selector(openWeb(_:)), symbol: "globe"))

        menu.addItem(.separator())
        let s = item("设置…", #selector(openSettings(_:)))
        s.keyEquivalent = ","
        menu.addItem(s)
        let q = NSMenuItem(title: "退出 SyncHub", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(q)
    }

    private func item(_ title: String, _ sel: Selector, symbol: String? = nil) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        m.target = self
        if let s = symbol { m.image = symbolImage(s) }
        return m
    }

    private func symbolImage(_ name: String) -> NSImage? {
        let i = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        i?.isTemplate = true
        return i
    }

    private func recentTitle(_ it: HubItem, alt: Bool = false) -> NSAttributedString {
        var name = it.displayName
        if name.count > 34 { name = String(name.prefix(22)) + "…" + String(name.suffix(10)) }
        if alt { name = (it.isFile ? "在 Finder 中显示：" : "在网页中查看：") + name }
        let s = NSMutableAttributedString(string: name, attributes: [.font: NSFont.menuFont(ofSize: 13)])
        var meta: [String] = []
        if it.pinned == true { meta.append("置顶") }
        if it.starred == true { meta.append("★ 收藏") }
        meta.append(it.fromDevice ?? "")
        if it.isFile, let sz = it.size { meta.append(HubFormat.bytes(sz)) }
        meta.append(HubFormat.relative(it.createdAt))
        if let r = HubFormat.remaining(it.remainingSeconds), (it.remainingSeconds ?? 0) < 12 * 3600 { meta.append(r) }
        s.append(NSAttributedString(string: "\n" + meta.filter { !$0.isEmpty }.joined(separator: " · "),
                                    attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                 .foregroundColor: NSColor.secondaryLabelColor]))
        return s
    }

    /// Small grey line under "同步剪贴板": "12:03:11 ↑ 已发送文字（23 字）", red on errors.
    private func clipStatusTitle(_ st: ClipStatus) -> NSAttributedString {
        var parts: [String] = []
        if let t = st.time {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            parts.append(f.string(from: t))
        }
        switch st.direction {
        case .up: parts.append("↑")
        case .down: parts.append("↓")
        case .none: break
        }
        var text = st.text
        if text.count > 40 { text = String(text.prefix(39)) + "…" }
        parts.append(text)
        return NSAttributedString(string: "      " + parts.joined(separator: " "),
                                  attributes: [.font: NSFont.systemFont(ofSize: 11),
                                               .foregroundColor: st.isError ? NSColor.systemRed : NSColor.secondaryLabelColor])
    }

    private func headerView() -> NSView {
        let host = NSHostingView(rootView: MenuHeader(
            connected: connected, server: URL(string: settings.config.normalizedBase)?.host ?? settings.serverURL,
            lastSync: lastSync, error: lastError, autoReceive: settings.autoReceive,
            uploading: uploads.activeJobs.count, progress: uploads.totalFraction, downloading: downloading))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 52)
        return host
    }

    // MARK: actions

    @objc func toggleAutoReceive(_ sender: Any?) {
        settings.setAutoReceive(!settings.autoReceive)
    }

    @objc func toggleClipSync(_ sender: Any?) {
        settings.setClipSync(!settings.clipSync)
    }

    @objc func openReceiveFolder(_ sender: Any?) {
        let u = settings.receiveURL
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        NSWorkspace.shared.open(u)
    }

    @objc func showUploads(_ sender: Any?) { UploadWindowController.shared.show() }

    @objc func openWeb(_ sender: Any?) {
        if let u = settings.config.webURL { NSWorkspace.shared.open(u) }
    }

    @objc func openSettings(_ sender: Any?) { SettingsWindowController.shared.show() }

    @objc func sendFiles(_ sender: Any?) {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = true; p.allowsMultipleSelection = true
        p.prompt = "发送"; p.message = "选择要发送到手机和 Windows 的文件（文件夹会自动压缩为 zip）"
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK { send(p.urls) }
    }

    private func send(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        uploads.enqueue(urls)
        UploadWindowController.shared.show()
        updateIcon()
    }

    /// Files → upload; image → PNG upload; text → /api/hub/text (also updates the shared clipboard).
    @objc func sendClipboard(_ sender: Any?) {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            send(urls); return
        }
        let png = pb.data(forType: .png) ?? pb.data(forType: .tiff).flatMap {
            NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
        }
        if let png = png {
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd_HHmmss"
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("synchub-clip-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("剪贴板图片_\(f.string(from: Date())).png")
            do { try png.write(to: file) } catch { Notifier.shared.post("发送失败", "无法保存剪贴板图片"); return }
            uploads.enqueue([file], temporary: true)
            UploadWindowController.shared.show()
            return
        }
        if let text = pb.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sendText(text); return
        }
        Notifier.shared.post("剪贴板为空", "没有可发送的文字、图片或文件")
    }

    private func sendText(_ text: String) {
        guard let c = currentClient() else { openSettings(nil); return }
        c.postText(text) { [weak self] r in
            DispatchQueue.main.async {
                switch r {
                case .success:
                    let preview = text.count > 40 ? String(text.prefix(40)) + "…" : text
                    Notifier.shared.post("✅ 文字已发送", preview)
                    self?.refreshRecent(force: true)
                case .failure(let e):
                    Notifier.shared.post("文字发送失败", e.localizedDescription)
                }
                self?.record(r.map { _ in () })
            }
        }
    }

    /// Services menu: "发送到 SyncHub" for selected text in any app (declared in Info.plist NSServices).
    @objc func sendText(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        if let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            send(urls); return
        }
        guard let s = pboard.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error.pointee = "没有选中文字" as NSString; return
        }
        sendText(s)
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        guard let it = sender.representedObject as? HubItem else { return }
        if it.isFile { fetch(it, reveal: false) }
        else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(it.text ?? "", forType: .string)
            Notifier.shared.post("已复制到剪贴板", String((it.text ?? "").prefix(60)))
        }
    }

    @objc func openRecentAlt(_ sender: NSMenuItem) {
        guard let it = sender.representedObject as? HubItem else { return }
        if it.isFile { fetch(it, reveal: true) } else { openWeb(nil) }
    }

    /// Download a recent file into the receive folder (reuse an identical existing copy), then open / reveal.
    private func fetch(_ it: HubItem, reveal: Bool) {
        let dir = settings.receiveURL
        let name = HubFormat.safeFilename(it.filename ?? "", fallback: "file_\(it.id)")
        let existing = dir.appendingPathComponent(name)
        let finish: (URL) -> Void = { u in
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([u]) } else { NSWorkspace.shared.open(u) }
        }
        if let sz = it.size, sz > 0,
           ((try? FileManager.default.attributesOfItem(atPath: existing.path))?[.size] as? NSNumber)?.int64Value == sz {
            finish(existing); return
        }
        guard let c = currentClient() else { return }
        downloading += 1; updateIcon()
        c.download(item: it) { [weak self] r in
            DispatchQueue.main.async {
                self?.downloading -= 1; self?.updateIcon()
                switch r {
                case .success(let tmp):
                    do {
                        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        let dest = HubFormat.uniqueURL(in: dir, filename: name)
                        try FileManager.default.moveItem(at: tmp, to: dest)
                        finish(dest)
                    } catch {
                        Notifier.shared.post("下载失败", error.localizedDescription)
                    }
                case .failure(let e):
                    Notifier.shared.post("下载失败", e.localizedDescription)
                }
            }
        }
    }

    // MARK: events

    private func didReceive(_ item: HubItem, at url: URL) {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        Notifier.shared.post("📥 已收到来自 \(item.fromDevice ?? "其他设备") 的文件",
                             "\(url.lastPathComponent)（\(HubFormat.bytes(size))）· 点击在 Finder 中显示",
                             reveal: url)
        refreshRecent(force: true)
    }

    private func uploadFinished(_ job: UploadJob) {
        updateIcon()
        if menuIsOpen { rebuildMenu() }
        UploadWindowController.shared.jobFinished()
        switch job.phase {
        case .done:
            if uploads.activeJobs.isEmpty {
                let n = uploads.jobs.filter { $0.phase == .done }.count
                Notifier.shared.post("✅ 发送完成", n > 1 ? "\(n) 个文件已发送到手机与 Windows" : "\(job.name)（\(HubFormat.bytes(job.size))）已发送")
            }
            refreshRecent(force: true)
            refreshStorage(force: true)
            record(.success(()))
        case .failed(let m):
            Notifier.shared.post("发送失败：\(job.name)", m)
            UploadWindowController.shared.show()
        default: break
        }
    }
}

/// Header row at the top of the menu: status dot, server, last sync / errors.
struct MenuHeader: View {
    let connected: Bool?
    let server: String
    let lastSync: Date?
    let error: String?
    let autoReceive: Bool
    let uploading: Int
    let progress: Double
    let downloading: Int

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(dot).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(line1).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(line2).font(.system(size: 11)).foregroundColor(error == nil ? .secondary : .red).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(width: 300, height: 52, alignment: .leading)
    }

    private var dot: Color {
        switch connected {
        case .some(true): return Color(red: 0.2, green: 0.78, blue: 0.35)
        case .some(false): return .red
        case .none: return Color.gray.opacity(0.5)
        }
    }
    private var line1: String {
        switch connected {
        case .some(true): return "已连接 · \(server)"
        case .some(false): return "连接失败 · \(server)"
        case .none: return "正在连接 \(server)…"
        }
    }
    private var line2: String {
        if uploading > 0 { return "正在发送 \(uploading) 个项目 · \(Int(progress * 100))%" }
        if downloading > 0 { return "正在下载…" }
        if let e = error { return e }
        var parts: [String] = []
        if let d = lastSync {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            parts.append("上次同步 \(f.string(from: d))")
        }
        parts.append(autoReceive ? "自动接收：开" : "自动接收：关")
        return parts.joined(separator: " · ")
    }
}
