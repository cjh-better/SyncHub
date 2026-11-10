// SettingsWindow.swift — server, account (Keychain), auto-receive folder, launch at login.
import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    var onClose: () -> Void

    @State private var server = ""
    @State private var user = ""
    @State private var pass = ""
    @State private var autoReceive = true
    @State private var dir = ""
    @State private var notify = true
    @State private var login = true
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?
    @State private var client: HubClient?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if settings.isFirstRun {
                HStack(spacing: 10) {
                    Image(systemName: "hand.wave").foregroundColor(.accentColor)
                    Text("欢迎使用 SyncHub。确认服务器信息后点「保存」，之后它会常驻菜单栏，自动接收其他设备发来的文件。")
                        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
                .padding(.bottom, 16)
            }

            section("服务器") {
                row("地址") { TextField("https://020814.xyz", text: $server).textFieldStyle(.roundedBorder) }
                row("用户名") { TextField("可选，服务器开启 Basic 认证时填写", text: $user).textFieldStyle(.roundedBorder) }
                row("密码") { SecureField("保存在「钥匙串」中", text: $pass).textFieldStyle(.roundedBorder) }
                row("") {
                    HStack(spacing: 8) {
                        Button(testing ? "正在测试…" : "测试连接", action: test).disabled(testing)
                        if let r = testResult {
                            Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(r.ok ? Color(red: 0.14, green: 0.54, blue: 0.24) : .red)
                            Text(r.text).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(2)
                        }
                    }
                }
            }

            section("自动接收") {
                row("") { Toggle("自动下载其他设备发来的文件", isOn: $autoReceive) }
                row("保存到") {
                    HStack(spacing: 8) {
                        Text((dir as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("更改…", action: chooseDir)
                        Button {
                            NSWorkspace.shared.open(URL(fileURLWithPath: (dir as NSString).expandingTildeInPath))
                        } label: { Image(systemName: "folder") }.help("在 Finder 中打开")
                    }
                }
            }

            section("通用") {
                row("") { Toggle("登录时自动启动", isOn: $login) }
                row("") { Toggle("收到文件或发送完成时显示通知", isOn: $notify) }
            }

            HStack {
                Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
                Button("取消") { onClose() }.keyboardShortcut(.cancelAction)
                Button("保存", action: save).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .padding(20)
        .frame(width: 480)
        .onAppear(perform: load)
    }

    @ViewBuilder private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary).padding(.bottom, 6)
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.black.opacity(0.08), lineWidth: 1))
            .padding(.bottom, 16)
    }

    @ViewBuilder private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.system(size: 12)).frame(width: 52, alignment: .trailing)
            content()
        }
    }

    private func load() {
        server = settings.serverURL; user = settings.username; pass = settings.password
        autoReceive = settings.autoReceive; dir = settings.receiveDir
        notify = settings.notifications; login = settings.launchAtLogin
    }

    private func test() {
        testing = true; testResult = nil
        let c = HubClient(config: HubConfig(baseURL: server, username: user.trimmingCharacters(in: .whitespaces),
                                            password: pass, device: settings.deviceName))
        client = c
        c.listItems(limit: 500) { r in
            DispatchQueue.main.async {
                testing = false
                switch r {
                case .success(let items): testResult = (true, "连接成功，云端共有 \(items.count) 个项目")
                case .failure(let e): testResult = (false, e.localizedDescription)
                }
                c.invalidate(); client = nil
            }
        }
    }

    private func chooseDir() {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true
        p.prompt = "选择"
        p.directoryURL = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        if p.runModal() == .OK, let u = p.url { dir = u.path }
    }

    private func save() {
        let loginChanged = login != settings.launchAtLogin
        settings.serverURL = server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AppSettings.defaultServer : server
        settings.username = user
        settings.autoReceive = autoReceive
        settings.receiveDir = dir
        settings.notifications = notify
        settings.launchAtLogin = login
        settings.save(password: pass)
        if loginChanged || settings.isFirstRun { LoginItem.set(login) }
        settings.markFirstRunDone()
        onClose()
    }
}

final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 480),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "SyncHub 设置"
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .aqua)
            w.delegate = self
            window = w
        }
        // Fresh view each time so fields reload from saved settings.
        let host = NSHostingView(rootView: SettingsView(settings: AppSettings.shared, onClose: { [weak self] in
            self?.window?.close()
        }))
        window?.contentView = host
        window?.setContentSize(host.fittingSize)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
