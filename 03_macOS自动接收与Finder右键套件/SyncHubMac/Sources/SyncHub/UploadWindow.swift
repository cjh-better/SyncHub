// UploadWindow.swift — flat, light progress window (white surface, hairline dividers, single blue accent).
import AppKit
import SwiftUI
import Combine

struct UploadListView: View {
    @ObservedObject var manager: UploadManager
    var close: () -> Void

    private var active: Int { manager.jobs.filter { $0.isActive }.count }
    private var failed: Int { manager.jobs.filter { $0.isFailed }.count }
    private var done: Int { manager.jobs.filter { $0.phase == .done }.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)).frame(width: 32, height: 32)
                    Image(systemName: active > 0 ? "arrow.up" : (failed > 0 ? "exclamationmark" : "checkmark"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(failed > 0 && active == 0 ? .red : .accentColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text("手机和 Windows 会自动接收").font(.system(size: 11)).foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(manager.jobs) { job in
                        UploadRow(job: job, manager: manager)
                        Divider().padding(.leading, 60)
                    }
                }
            }
            .frame(height: CGFloat(min(max(manager.jobs.count, 1), 5)) * 64)
            Divider()
            HStack {
                Text(footer).font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
                if active > 0 {
                    Button("全部取消") { manager.cancelAll() }
                }
                Button(active > 0 ? "后台发送" : "完成") { close() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 440)
        .background(Color(NSColor.textBackgroundColor))
    }

    private var title: String {
        if active > 0 { return "正在发送 \(active) 个项目" }
        if failed > 0 { return "\(failed) 个项目发送失败" }
        return done > 0 ? "已全部发送" : "发送到 SyncHub"
    }
    private var footer: String {
        let n = manager.jobs.count
        if active > 0 { return "\(done)/\(n) · 总进度 \(Int(manager.totalFraction * 100))%" }
        return failed > 0 ? "可点击 ↻ 重试" : "窗口将自动关闭"
    }
}

struct UploadRow: View {
    @ObservedObject var job: UploadJob
    let manager: UploadManager

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: job.source.path))
                .resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(job.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    if job.size > 0 {
                        Text(HubFormat.bytes(job.size)).font(.system(size: 11)).foregroundColor(.secondary)
                    }
                }
                if job.phase == .uploading || job.phase == .preparing {
                    ProgressView(value: job.phase == .preparing ? 0 : job.fraction)
                        .progressViewStyle(.linear)
                }
                Text(status).font(.system(size: 11)).foregroundColor(statusColor).lineLimit(1)
            }
            actionButton.frame(width: 20)
        }
        .padding(.horizontal, 16).frame(height: 63)
    }

    @ViewBuilder private var actionButton: some View {
        switch job.phase {
        case .waiting, .uploading, .preparing:
            Button { manager.cancel(job) } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                .buttonStyle(.plain).help("取消")
        case .failed, .cancelled:
            Button { manager.retry(job) } label: { Image(systemName: "arrow.clockwise").foregroundColor(.accentColor) }
                .buttonStyle(.plain).help("重试")
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundColor(Color(red: 0.14, green: 0.54, blue: 0.24))
        }
    }

    private var status: String {
        switch job.phase {
        case .preparing: return "正在压缩文件夹…"
        case .waiting: return "等待中"
        case .uploading:
            var s = "\(Int(job.fraction * 100))% · \(HubFormat.bytes(job.sent)) / \(HubFormat.bytes(job.size))"
            if job.speed > 0 {
                s += String(format: " · %.1f MB/s", job.speed / 1_048_576)
                let left = Double(job.size - job.sent) / job.speed
                if left >= 1 { s += left < 60 ? " · 剩余 \(Int(left)) 秒" : " · 剩余 \(Int(left / 60)) 分钟" }
            }
            return s
        case .done: return "已发送"
        case .failed(let m): return m
        case .cancelled: return "已取消"
        }
    }
    private var statusColor: Color {
        switch job.phase {
        case .failed: return Color(red: 0.84, green: 0, blue: 0.08)
        case .done: return Color(red: 0.14, green: 0.54, blue: 0.24)
        default: return .secondary
        }
    }
}

final class UploadWindowController: NSObject, NSWindowDelegate {
    static let shared = UploadWindowController()
    private var window: NSPanel?
    private var host: NSHostingView<UploadListView>?
    private var bag = Set<AnyCancellable>()
    private var autoCloseWork: DispatchWorkItem?
    let manager = UploadManager.shared

    func show() {
        if window == nil {
            let view = UploadListView(manager: manager, close: { [weak self] in self?.close() })
            let host = NSHostingView(rootView: view)
            let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 200),
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
            w.title = "发送到 SyncHub"
            w.isFloatingPanel = true
            w.hidesOnDeactivate = false
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .aqua)          // light, like the web UI
            w.contentView = host
            w.delegate = self
            self.host = host
            self.window = w
            manager.$jobs.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.fit() }.store(in: &bag)
            w.center()
        }
        fit()
        window?.orderFrontRegardless()
        window?.makeKey()
    }

    private func fit() {
        guard let w = window, let host = host else { return }
        let size = host.fittingSize
        guard size.height > 0, abs(w.frame.height - size.height) > 1 || abs(w.frame.width - size.width) > 1 else { return }
        var f = w.frame
        f.origin.y += f.height - size.height
        f.size = size
        w.setFrame(f, display: true, animate: false)
    }

    /// Called whenever a job finishes: auto-close 1.5 s after everything succeeded (same as Windows popup).
    func jobFinished() {
        autoCloseWork?.cancel()
        let jobs = manager.jobs
        guard !jobs.isEmpty, jobs.allSatisfy({ $0.phase == .done }) else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.manager.jobs.allSatisfy({ $0.phase == .done }) else { return }
            if let w = self.window, w.isVisible, NSMouseInRect(NSEvent.mouseLocation, w.frame, false) { return }
            self.close()
        }
        autoCloseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    func close() { window?.orderOut(nil); manager.clearFinished() }

    func windowWillClose(_ notification: Notification) { manager.clearFinished() }
}
