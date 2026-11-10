// ClipboardSync.swift — automatic two-way clipboard sync (NSPasteboard ⇄ SyncClipboard.json).
// The protocol / echo-guard logic is in ClipSyncCore.swift (Foundation-only, tested on Linux);
// this file only watches and writes the macOS pasteboard and drives the timers.
//
// Reading NSPasteboard needs no permission on macOS 12–26: changeCount is polled (it reveals nothing),
// and the contents are only read after it changes.
import AppKit

/// What the menu shows on its "剪贴板" line.
struct ClipStatus {
    enum Direction { case up, down, none }
    var time: Date?
    var direction: Direction = .none
    var text: String = "等待剪贴板变化…"
    var isError = false
}

/// Stores lastRemoteKey per server, so changing the server starts from a fresh baseline instead of
/// replaying a stale key (and never overwrites the clipboard on the first poll).
final class DefaultsClipState: ClipStateStore {
    private let d = UserDefaults.standard
    private let server: String
    init(server: String) { self.server = server }
    var lastRemoteKey: String? {
        get { d.string(forKey: "clipStateServer") == server ? d.string(forKey: "clipLastRemoteKey") : nil }
        set {
            d.set(server, forKey: "clipStateServer")
            if let v = newValue { d.set(v, forKey: "clipLastRemoteKey") } else { d.removeObject(forKey: "clipLastRemoteKey") }
        }
    }
    var lastRemoteContent: String? {
        get { d.string(forKey: "clipStateServer") == server ? d.string(forKey: "clipLastRemoteContent") : nil }
        set {
            d.set(server, forKey: "clipStateServer")
            if let v = newValue { d.set(v, forKey: "clipLastRemoteContent") } else { d.removeObject(forKey: "clipLastRemoteContent") }
        }
    }
}

final class ClipboardSync {
    static let localInterval: TimeInterval = 0.7
    static let remoteInterval: TimeInterval = 1.5

    /// Main thread: called whenever the status line changes.
    var onStatus: ((ClipStatus) -> Void)?
    private(set) var status = ClipStatus()
    private(set) var running = false

    private let settings = AppSettings.shared
    private let pb = NSPasteboard.general
    private var transport: SyncClipboardHTTP?
    private var engine: ClipSyncEngine?
    private var localTimer: Timer?
    private var generation = 0                 // bumps on stop/restart; stale callbacks are ignored
    private var lastChangeCount = 0
    private var ownChangeCount = -1            // changeCount produced by our own write of a remote value
    private var remoteBackoff = ClipBackoff(base: ClipboardSync.remoteInterval)
    private var pushBackoff = ClipBackoff(base: 2)
    private var pushRetryAt: Date?
    private var pollStartedAt: Date?

    // MARK: lifecycle

    /// (Re)start according to the current settings. Safe to call repeatedly (settings changed, wake, …).
    func restart() {
        let wasRunning = running
        stop()
        guard settings.clipSync else { setStatus(ClipStatus(text: "剪贴板同步：已关闭")); return }
        let cfg = settings.config
        guard !cfg.normalizedBase.isEmpty else { setStatus(ClipStatus(text: "尚未设置服务器", isError: true)); return }

        let t = SyncClipboardHTTP(config: cfg)
        let e = ClipSyncEngine(transport: t, state: DefaultsClipState(server: cfg.normalizedBase + "|" + cfg.username))
        e.pullImages = { AppSettings.shared.clipImages }
        #if DEBUG
        e.log = { NSLog("[SyncHub 剪贴板] %@", $0) }
        #endif
        transport = t; engine = e
        running = true
        // Turning on: don't push whatever was already on the clipboard. Plain restart (settings saved):
        // keep the counter so a copy made in the same instant is not lost.
        if !wasRunning { lastChangeCount = pb.changeCount }
        remoteBackoff.success(); pushBackoff.success(); pushRetryAt = nil
        if status.isError || status.time == nil { setStatus(ClipStatus(text: "剪贴板同步：已开启，等待变化…")) }

        let lt = Timer(timeInterval: ClipboardSync.localInterval, repeats: true) { [weak self] _ in self?.localTick() }
        lt.tolerance = 0.2
        RunLoop.main.add(lt, forMode: .common)
        localTimer = lt
        scheduleRemote(after: 0.3)
    }

    func stop() {
        generation += 1
        running = false
        localTimer?.invalidate(); localTimer = nil
        transport?.invalidate(); transport = nil
        engine = nil
        pollStartedAt = nil
    }

    // MARK: local → server

    private func localTick() {
        guard running, let engine = engine else { return }
        // Watchdog: a poll that never completes must not stop remote sync forever.
        if let s = pollStartedAt, Date().timeIntervalSince(s) > 150 { restart(); return }

        let cc = pb.changeCount
        let retryDue = pushRetryAt.map { Date() >= $0 } ?? false
        guard cc != lastChangeCount || retryDue else { return }
        lastChangeCount = cc
        pushRetryAt = nil
        if cc == ownChangeCount { return }          // our own write of a remote value

        let types = (pb.types ?? []).map { $0.rawValue }
        if ClipPasteboardRules.isPrivate(types) {
            setStatus(ClipStatus(time: Date(), text: "已跳过密码等隐私内容（不同步）")); return
        }
        // Copied files in Finder: use 发送文件 / Finder 右键; the clipboard only syncs text and images.
        if pb.availableType(from: [.fileURL]) != nil { return }

        let gen = generation
        if let text = pb.string(forType: .string) {
            engine.onLocalText(text) { [weak self] r in
                DispatchQueue.main.async { self?.pushed(r, gen: gen, what: "文字（\(text.count) 字）") }
            }
            return
        }
        guard settings.clipImages, let png = Self.pngData(pb) else { return }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd_HHmmss"
        let name = "IMG_\(f.string(from: Date())).png"
        engine.onLocalImage(name: name, data: png) { [weak self] r in
            DispatchQueue.main.async { self?.pushed(r, gen: gen, what: "图片（\(HubFormat.bytes(Int64(png.count)))）") }
        }
    }

    private func pushed(_ r: Result<ClipLocalResult, HubError>, gen: Int, what: String) {
        guard gen == generation else { return }
        switch r {
        case .success(.pushed):
            pushBackoff.success()
            setStatus(ClipStatus(time: Date(), direction: .up, text: "已发送\(what)"))
        case .success(.skipped(let reason)):
            if reason.contains("超过") { setStatus(ClipStatus(time: Date(), text: reason)) }
        case .failure(let e) where e.isCancelled:
            break
        case .failure(let e):
            pushBackoff.failure()
            pushRetryAt = Date().addingTimeInterval(pushBackoff.delay)   // re-read and push again later
            setStatus(ClipStatus(time: Date(), direction: .up, text: "发送失败：\(e.localizedDescription)（稍后重试）", isError: true))
        }
    }

    private static func pngData(_ pb: NSPasteboard) -> Data? {
        if let d = pb.data(forType: .png) { return d }
        if let t = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: t) {
            return rep.representation(using: .png, properties: [:])
        }
        return nil
    }

    // MARK: server → local

    private func scheduleRemote(after delay: TimeInterval) {
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, gen == self.generation, self.running else { return }
            self.pollRemote()
        }
    }

    private func pollRemote() {
        guard let engine = engine else { return }
        let gen = generation
        pollStartedAt = Date()
        engine.pollRemote { [weak self] r in
            DispatchQueue.main.async {
                guard let self = self, gen == self.generation else { return }
                self.pollStartedAt = nil
                switch r {
                case .success(let change):
                    self.remoteBackoff.success()
                    if let c = change { self.apply(c, engine: engine) }
                    else if self.status.isError && self.pushRetryAt == nil {
                        self.setStatus(ClipStatus(text: "剪贴板同步：已恢复连接"))
                    }
                case .failure(let e) where e.isCancelled:
                    break
                case .failure(let e):
                    self.remoteBackoff.failure()
                    self.setStatus(ClipStatus(time: Date(), direction: .down,
                                              text: "接收失败：\(e.localizedDescription)（\(Int(self.remoteBackoff.delay)) 秒后重试）",
                                              isError: true))
                }
                self.scheduleRemote(after: self.remoteBackoff.delay)
            }
        }
    }

    private func apply(_ c: ClipRemoteChange, engine: ClipSyncEngine) {
        switch c {
        case .text(let text, let hash):
            pb.clearContents()
            let ok = pb.setString(text, forType: .string)
            markOwnWrite()
            if ok { setStatus(ClipStatus(time: Date(), direction: .down, text: "已收到文字（\(text.count) 字）")) }
            else { engine.release(hash); setStatus(ClipStatus(time: Date(), direction: .down, text: "写入剪贴板失败", isError: true)) }
        case .image(_, let data, let key):
            guard let img = NSImage(data: data) else { engine.release(key); return }
            pb.clearContents()
            var ok = false
            let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
            if isPNG { ok = pb.setData(data, forType: .png) }
            else if let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t),
                    let png = rep.representation(using: .png, properties: [:]) { ok = pb.setData(png, forType: .png) }
            if let t = img.tiffRepresentation { ok = pb.setData(t, forType: .tiff) || ok }
            markOwnWrite()
            if ok { setStatus(ClipStatus(time: Date(), direction: .down, text: "已收到图片（\(HubFormat.bytes(Int64(data.count)))）")) }
            else { engine.release(key); setStatus(ClipStatus(time: Date(), direction: .down, text: "写入剪贴板失败", isError: true)) }
        }
    }

    private func markOwnWrite() {
        ownChangeCount = pb.changeCount
        lastChangeCount = ownChangeCount
    }

    private func setStatus(_ s: ClipStatus) {
        status = s
        onStatus?(s)
    }
}
