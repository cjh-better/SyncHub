// TextViewerWindow.swift — small window showing a text item in full (selectable), with 复制全部 / 关闭.
import AppKit

final class TextViewerWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [Int: TextViewerWindowController] = [:]   // one window per item; kept alive while shown

    static func show(_ item: HubItem) {
        if let w = open[item.id] { w.present(); return }
        let c = TextViewerWindowController(item: item)
        open[item.id] = c
        c.present()
    }

    private let item: HubItem
    private let text: String

    private init(item: HubItem) {
        self.item = item
        self.text = item.text ?? ""
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        w.title = "查看全文"
        w.minSize = NSSize(width: 360, height: 220)
        w.isReleasedWhenClosed = false
        w.hidesOnDeactivate = false
        w.level = .floating
        super.init(window: w)
        w.delegate = self
        build(in: w)
        w.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build(in w: NSWindow) {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        w.contentView = root

        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.isSelectable = true
            tv.isRichText = false
            tv.drawsBackground = false
            tv.font = NSFont.systemFont(ofSize: 13)
            tv.textColor = .labelColor
            tv.textContainerInset = NSSize(width: 14, height: 12)
            tv.string = text
        }

        let sep = NSBox(); sep.boxType = .separator

        var meta: [String] = []
        if let d = item.fromDevice, !d.isEmpty { meta.append("来自 \(d)") }
        let rel = HubFormat.relative(item.createdAt)
        if !rel.isEmpty { meta.append(rel) }
        meta.append("\(text.count) 字")
        let info = NSTextField(labelWithString: meta.joined(separator: " · "))
        info.font = NSFont.systemFont(ofSize: 11)
        info.textColor = .secondaryLabelColor
        info.lineBreakMode = .byTruncatingTail

        let copy = NSButton(title: "复制全部", target: self, action: #selector(copyAll(_:)))
        copy.bezelStyle = .rounded
        copy.keyEquivalent = "\r"
        let close = NSButton(title: "关闭", target: self, action: #selector(closeWin(_:)))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"

        for v in [scroll, sep, info, copy, close] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            sep.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            sep.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            copy.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 10),
            copy.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            copy.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            close.centerYAnchor.constraint(equalTo: copy.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: copy.leadingAnchor, constant: -8),
            info.centerYAnchor.constraint(equalTo: copy.centerYAnchor),
            info.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            info.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -12),
        ])
    }

    private func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func copyAll(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        (sender as? NSButton)?.title = "已复制"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak sender] in (sender as? NSButton)?.title = "复制全部" }
    }

    @objc private func closeWin(_ sender: Any?) { window?.performClose(nil) }

    func windowWillClose(_ notification: Notification) {
        TextViewerWindowController.open[item.id] = nil
    }
}
