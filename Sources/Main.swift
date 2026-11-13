import AppKit

@main
enum ScreenRecorderMain {
  /// 业务作用: 启动单实例菜单栏录屏应用，不在启动时建立采集。
  /// 参数说明: 无。
  /// 返回: 运行应用事件循环，正常退出后结束进程。
  @MainActor static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppController()
    app.delegate = delegate
    withExtendedLifetime(delegate) {
      app.run()
    }
  }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
  private var statusItem: NSStatusItem!
  private var panel: NSPanel?

  /// 业务作用: 建立菜单栏入口，首次显示选择界面而不取得采集权限。
  /// 参数说明:
  /// - notification: 应用完成启动通知。
  /// 返回: 用户可从菜单栏进入录制工具。
  func applicationDidFinishLaunching(_ notification: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.image = NSImage(
      systemSymbolName: "record.circle", accessibilityDescription: "Screen Recorder")
    statusItem.button?.target = self
    statusItem.button?.action = #selector(showToolbar)
    showToolbar()
  }

  /// 业务作用: 响应再次打开应用，复用已有工具窗口。
  /// 参数说明:
  /// - sender: 当前应用。
  /// - flag: 系统报告的可见窗口状态。
  /// 返回: 已处理重新打开事件。
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    showToolbar()
    return true
  }

  /// 业务作用: 显示产品入口，尚未就绪时明确说明状态。
  /// 参数说明: 无。
  /// 返回: 显示非录制状态的工具窗口。
  @objc private func showToolbar() {
    if panel == nil {
      let window = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 460, height: 80), styleMask: [.titled, .closable],
        backing: .buffered, defer: false)
      window.title = "Screen Recorder"
      let label = NSTextField(labelWithString: "录制工具正在准备中，当前没有采集画面或声音。")
      label.frame = NSRect(x: 20, y: 25, width: 420, height: 24)
      window.contentView?.addSubview(label)
      window.center()
      panel = window
    }
    panel?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}
