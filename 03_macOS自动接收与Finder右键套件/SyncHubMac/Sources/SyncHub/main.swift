// main.swift — SyncHub for macOS: menu-bar client for the SyncClipboard + SyncHub server.
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only (LSUIElement is also set in Info.plist)
app.run()
