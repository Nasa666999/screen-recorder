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
