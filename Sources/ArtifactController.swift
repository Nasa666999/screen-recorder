import AVKit
import AppKit

@MainActor
final class ArtifactController: NSObject, NSWindowDelegate,
  @preconcurrency NSSharingServicePickerDelegate,
  NSSharingServiceDelegate
{
  let id = UUID()
  let url: URL
  private let location: RecordingLocation
  var onChange: (() -> Void)?
  private(set) var busy = false
  private var deleted = false
  private var leases = 0
  private var identity: NSObject?
  private var thumbnail: NSPanel?
  private var preview: NSWindow?
  private var playerView: AVPlayerView?
  private var picker: NSSharingServicePicker?
  private var exporter: AVAssetExportSession?
  private var buttons: [NSButton] = []
  private var temporaryURL: URL?

  var hasWork: Bool {
    busy || leases > 0
  }

  var hasVisibleUI: Bool {
    thumbnail?.isVisible == true || preview?.isVisible == true
  }

  /// 业务作用: 独立持有成品身份与目录访问，不依赖后续录制会话。
  /// 参数说明:
  /// - url: 已完成封装并发布的文件。
  /// - location: 该文件所属目录的授权持有者。
  /// 返回: 录后操作始终针对这一成品。
  init(url: URL, location: RecordingLocation) {
    self.url = url
    self.location = location
    super.init()
    identity =
      try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
      as? NSObject
  }

  /// 业务作用: 显示短暂的录后缩略图，最多解码一帧而非载入整个视频。
  /// 参数说明: 无。
  /// 返回: 点击预览、拖动复制，超时仅隐藏入口，不删除文件。
  func showThumbnail() {
    let frame = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
    let panel = NSPanel(
      contentRect: NSRect(x: frame.maxX - 224, y: frame.minY + 24, width: 200, height: 126),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .floating
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    let button = ArtifactThumbnail(frame: NSRect(x: 0, y: 0, width: 200, height: 126))
    button.artifact = self
    button.imageScaling = .scaleProportionallyUpOrDown
    button.bezelStyle = .regularSquare
    button.title = "查看录制"
    button.target = self
    button.action = #selector(showPreview)
    button.toolTip = "点击预览，拖动复制视频"
    panel.contentView = button
    thumbnail = panel
    panel.orderFrontRegardless()
    let url = self.url
    Task {
      let image = await Task.detached { () -> NSImage? in
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.maximumSize = CGSize(width: 400, height: 252)
        generator.appliesPreferredTrackTransform = true
        guard let result = try? await generator.image(at: .zero) else {
          return nil
        }
        return NSImage(cgImage: result.image, size: .zero)
      }.value
      if let image {
        button.image = image
        button.title = ""
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
      self?.thumbnail?.orderOut(nil)
      self?.onChange?()
    }
  }

  /// 业务作用: 复验成品仍是本应用原文件，拒绝对同路径的陌生文件操作。
  /// 参数说明: 无。
  /// 返回: 身份一致返回真；失效、移动或删除后拒绝继续操作。
  private func validate() -> Bool {
    guard !deleted, let identity,
      let current = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey])
        .fileResourceIdentifier as? NSObject,
      identity.isEqual(current)
    else {
      issue("视频已移动、删除或被其他文件替换，请在 Finder 中查看。")
      return false
    }
    return true
  }

  /// 业务作用: 打开应用内原生视频预览，不转交外部播放器。
  /// 参数说明: 无。
  /// 返回: 可播放、修剪、分享或删除已完成文件。
  @objc func showPreview() {
    guard validate() else {
      return
    }
    thumbnail?.orderOut(nil)
    if let preview {
      preview.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 510),
      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
    )
    window.title = url.lastPathComponent
    window.isReleasedWhenClosed = false
    window.delegate = self
    let root = NSView()
    let player = AVPlayerView()
    player.player = AVPlayer(url: url)
    player.controlsStyle = .inline
    player.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(player)
    let actions = NSStackView()
    actions.orientation = .horizontal
    actions.spacing = 12
    actions.translatesAutoresizingMaskIntoConstraints = false
    let descriptors: [(String, Selector)] = [
      ("修剪", #selector(trim)), ("分享", #selector(share(_:))),
      ("移到废纸篓", #selector(trash)), ("完成", #selector(done)),
    ]
    buttons = descriptors.map {
      let button = NSButton(title: $0.0, target: self, action: $0.1)
      actions.addArrangedSubview(button)
      return button
    }
    root.addSubview(actions)
    window.contentView = root
    NSLayoutConstraint.activate([
      player.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      player.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      player.topAnchor.constraint(equalTo: root.topAnchor),
      player.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -12),
      actions.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      actions.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
      actions.heightAnchor.constraint(equalToConstant: 32),
    ])
    playerView = player
    preview = window
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  /// 业务作用: 用 AVKit 的原生修剪交互选择范围，提交后才写入独立临时文件。
  /// 参数说明: 无。
  /// 返回: 原文件在导出和身份复验成功前保持不变。
  @objc private func trim() {
    guard !hasWork, validate(), let playerView, playerView.canBeginTrimming else {
      return
    }
    setBusy(true)
    playerView.beginTrimming { [weak self] result in
      Task { @MainActor in
        guard let self else {
          return
        }
        guard result == .okButton, let item = playerView.player?.currentItem else {
          self.setBusy(false)
          return
        }
        let start = item.reversePlaybackEndTime
        let end =
          item.forwardPlaybackEndTime.isNumeric ? item.forwardPlaybackEndTime : item.duration
        await self.exportTrim(range: CMTimeRange(start: start, end: end))
      }
    }
  }

  /// 业务作用: 先完整导出修剪结果，协同复验身份后原子替换本成品。
  /// 参数说明:
  /// - range: 用户在原生修剪界面确认的有效时间范围。
  /// 返回: 失败保留原件；不允许迟到操作恢复已删除的文件。
  private func exportTrim(range: CMTimeRange) async {
    let temporary = url.deletingLastPathComponent().appendingPathComponent(
      ".ScreenRecorder-trim-\(UUID().uuidString).mov")
    temporaryURL = temporary
    defer {
      exporter = nil
      temporaryURL = nil
      try? FileManager.default.removeItem(at: temporary)
      setBusy(false)
    }
    do {
      guard range.isValid, range.duration > .zero,
        let exporter = AVAssetExportSession(
          asset: AVURLAsset(url: url), presetName: AVAssetExportPresetPassthrough)
      else {
        throw RecorderError.message("当前视频无法无损修剪。")
      }
      self.exporter = exporter
      exporter.timeRange = range
      try await exporter.export(to: temporary, as: .mov)
      let asset = AVURLAsset(url: temporary)
      guard try await asset.load(.duration) > .zero else {
        throw RecorderError.message("修剪结果无有效时长，原视频已保留。")
      }
      guard validate(), leases == 0 else {
        return
      }
      var coordinationError: NSError?
      var replacementError: Error?
      NSFileCoordinator().coordinate(
        writingItemAt: url, options: .forReplacing, error: &coordinationError
      ) { coordinated in
        guard validate() else {
          replacementError = RecorderError.message("文件身份变化，原视频不作替换。")
          return
        }
        do {
          _ = try FileManager.default.replaceItemAt(coordinated, withItemAt: temporary)
        } catch {
          replacementError = error
        }
      }
      if let error = coordinationError ?? replacementError as NSError? {
        throw error
      }
      identity =
        try url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        as? NSObject
      playerView?.player?.replaceCurrentItem(with: AVPlayerItem(url: url))
    } catch {
      issue("修剪未提交，原文件保留：\(error.localizedDescription)")
    }
  }

  /// 业务作用: 在分享完成或取消前持有成品，避免分享链接指向被删除的文件。
  /// 参数说明:
  /// - sender: 分享按钮，用于定位系统分享菜单。
  /// 返回: 分享期间拒绝修剪或删除同一文件。
  @objc private func share(_ sender: NSButton) {
    guard !hasWork, validate() else {
      return
    }
    leases += 1
    let picker = NSSharingServicePicker(items: [url])
    picker.delegate = self
    self.picker = picker
    picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
  }

  /// 业务作用: 把选中的分享服务绑定到同一访问租约。
  /// 参数说明:
  /// - sharingServicePicker: 当前分享菜单。
  /// - service: 用户选择的系统分享服务。
  /// - items: 已完成的录制文件。
  /// 返回: 当前成品控制器负责结束访问租约。
  func sharingServicePicker(
    _ sharingServicePicker: NSSharingServicePicker, delegateFor service: NSSharingService,
    sharingItems items: [Any]
  ) -> NSSharingServiceDelegate? {
    self
  }

  /// 业务作用: 用户取消分享菜单时立即释放访问租约。
  /// 参数说明:
  /// - sharingServicePicker: 当前分享菜单。
  /// - service: 用户选择的服务，取消时为空。
  /// 返回: 取消不阻止之后修剪或删除。
  func sharingServicePicker(
    _ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?
  ) {
    if service == nil {
      endLease()
    }
  }

  /// 业务作用: 分享完成后归还文件访问，不删除源视频。
  /// 参数说明:
  /// - sharingService: 已完成的系统服务。
  /// - items: 已分享文件。
  /// 返回: 允许后续破坏性操作。
  func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
    endLease()
  }

  /// 业务作用: 分享失败后归还文件访问并保留成品。
  /// 参数说明:
  /// - sharingService: 当前系统服务。
  /// - items: 尝试分享的文件。
  /// - error: 系统分享错误。
  /// 返回: 源文件保持不变。
  func sharingService(
    _ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error
  ) {
    endLease()
    issue(error.localizedDescription)
  }

  /// 业务作用: 为用户主动拖动建立文件访问保护。
  /// 参数说明: 无。
  /// 返回: 文件有效且无冲突操作时取得拖动许可。
  func beginDrag() -> Bool {
    guard !hasWork, validate() else {
      return false
    }
    leases += 1
    return true
  }

  /// 业务作用: 归还分享或拖动持有的访问保护。
  /// 参数说明: 无。
  /// 返回: 不存在访问者时恢复成品修改权限。
  func endLease() {
    leases = max(0, leases - 1)
    picker = nil
    onChange?()
  }

  /// 业务作用: 仅将身份一致的本成品移到废纸篓，操作可由用户恢复。
  /// 参数说明: 无。
  /// 返回: 成功关闭当前成品界面；失败保留文件和界面。
  @objc private func trash() {
    guard !hasWork, validate() else {
      return
    }
    do {
      playerView?.player?.pause()
      try FileManager.default.trashItem(at: url, resultingItemURL: nil)
      deleted = true
      done()
    } catch {
      issue(error.localizedDescription)
    }
  }

  /// 业务作用: 关闭成品界面并停止回放，不删除已经保存的视频。
  /// 参数说明: 无。
  /// 返回: 成品操作结束，后续录制不受影响。
  @objc private func done() {
    guard !hasWork else {
      return
    }
    playerView?.player?.pause()
    preview?.close()
    thumbnail?.orderOut(nil)
    onChange?()
  }

  /// 业务作用: 防止导出或分享期间关闭成品所有者。
  /// 参数说明:
  /// - sender: 用户请求关闭的预览窗口。
  /// 返回: 没有进行中操作时允许关闭。
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    !hasWork
  }

  /// 业务作用: 关闭预览时释放视频回放，不保留后台音频。
  /// 参数说明:
  /// - notification: 当前预览窗口的关闭通知。
  /// 返回: 成品文件继续保存在用户目录。
  func windowWillClose(_ notification: Notification) {
    playerView?.player?.pause()
    playerView?.player = nil
    playerView = nil
    preview = nil
    onChange?()
  }

  /// 业务作用: 更新成品操作门禁，所有破坏性按钮统一禁用。
  /// 参数说明:
  /// - value: 是否存在修剪交互或导出。
  /// 返回: 新录制可独立运行，同一成品操作不可重入。
  private func setBusy(_ value: Bool) {
    busy = value
    for button in buttons {
      button.isEnabled = !value
    }
    onChange?()
  }

  /// 业务作用: 向用户报告成品操作失败，不将失败描述为保存成功。
  /// 参数说明:
  /// - message: 当前操作的实际失败原因。
  /// 返回: 原成品保留，用户可处理错误。
  private func issue(_ message: String) {
    let alert = NSAlert()
    alert.messageText = "Screen Recorder"
    alert.informativeText = message
    alert.runModal()
  }
}

@MainActor
private final class ArtifactThumbnail: NSButton, NSDraggingSource {
  weak var artifact: ArtifactController?

  /// 业务作用: 将已经完成的文件作为复制操作交给拖放目标。
  /// 参数说明:
  /// - event: 用户在缩略图上的主动拖动。
  /// 返回: 拖动完成前维持成品访问，源文件不自动移动或删除。
  override func mouseDragged(with event: NSEvent) {
    guard let artifact, artifact.beginDrag() else {
      return
    }
    let item = NSDraggingItem(pasteboardWriter: artifact.url as NSURL)
    item.setDraggingFrame(bounds, contents: image)
    beginDraggingSession(with: [item], event: event, source: self)
  }

  /// 业务作用: 限定拖放为复制，防止外部目标隐式删除源成品。
  /// 参数说明:
  /// - session: 当前系统拖动会话。
  /// - context: 拖放所在应用范围。
  /// 返回: 仅允许复制文件。
  func draggingSession(
    _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    .copy
  }

  /// 业务作用: 拖动结束后解除对成品的访问保护。
  /// 参数说明:
  /// - session: 已结束拖动会话。
  /// - screenPoint: 最终屏幕位置。
  /// - operation: 系统实际执行的拖动操作。
  /// 返回: 同一成品可继续修剪或删除。
  func draggingSession(
    _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
  ) {
    artifact?.endLease()
  }
}
