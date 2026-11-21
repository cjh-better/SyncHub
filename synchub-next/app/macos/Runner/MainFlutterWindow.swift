import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private(set) var flutterViewController: FlutterViewController?
  var suppressInitialShow: Bool = {
    let args = ProcessInfo.processInfo.arguments
    return args.contains("--minimized") || args.contains("--background")
  }()

  override func awakeFromNib() {
    let controller = FlutterViewController()
    self.flutterViewController = controller

    let windowFrame = self.frame
    self.contentViewController = controller
    self.setFrame(windowFrame, display: true)
    self.minSize = NSSize(width: 720, height: 500)
    self.title = "SyncHub"
    self.isReleasedWhenClosed = false
    self.delegate = self

    RegisterGeneratedPlugins(registry: controller)

    if let appDelegate = (NSApp.delegate as? AppDelegate) ?? AppDelegate.shared {
      appDelegate.attachFlutterWindow(self, controller: controller)
    }

    super.awakeFromNib()

    if suppressInitialShow {
      self.orderOut(nil)
    }
  }

  override func orderWindow(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    if suppressInitialShow && place != .out {
      return
    }
    super.orderWindow(place, relativeTo: otherWin)
  }

  override func makeKeyAndOrderFront(_ sender: Any?) {
    if suppressInitialShow {
      return
    }
    super.makeKeyAndOrderFront(sender)
  }

  override func orderFront(_ sender: Any?) {
    if suppressInitialShow {
      return
    }
    super.orderFront(sender)
  }

  func revealFromMenuBar() {
    suppressInitialShow = false
    NSApp.setActivationPolicy(.regular)
    super.makeKeyAndOrderFront(nil)
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

  func hideToMenuBar() {
    self.orderOut(nil)
    NSApp.setActivationPolicy(.accessory)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if AppDelegate.shared?.allowQuit == true {
      return true
    }
    hideToMenuBar()
    AppDelegate.shared?.notifyWindowHidden()
    return false
  }
}
