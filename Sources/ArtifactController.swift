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
    var onEdit: ((URL) -> Void)?
    private var deleted = false
    private var leases = 0
    private var identity: NSObject?
    private var modifiedAt: Date?
    private var fileSize: Int?
    private var thumbnail: NSPanel?
    private var preview: NSWindow?
    private var playerView: AVPlayerView?
    private var picker: NSSharingServicePicker?

    var hasWork: Bool {
        leases > 0
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
        try? rememberIdentity()
    }

    /// 业务作用: 显示短暂的录后缩略图，最多解码一帧而非载入整个视频。
    /// 参数说明: 无。
    /// 返回: 点击预览、拖动复制，超时仅隐藏入口，不删除文件。
    func showThumbnail() {
        let frame = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let panel = NSPanel(
            contentRect: NSRect(
                x: frame.maxX - 224,
                y: frame.minY + 24,
                width: 200,
                height: 126
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let button = ArtifactThumbnail(
            frame: NSRect(
                x: 0,
                y: 0,
                width: 200,
                height: 126
            ))
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
                generator.maximumSize = CGSize(
                    width: 400,
                    height: 252
                )
                generator.appliesPreferredTrackTransform = true
                guard let result = try? await generator.image(at: .zero) else {
                    return nil
                }
                return NSImage(
                    cgImage: result.image,
                    size: .zero
                )
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
            let values = try? url.resourceValues(forKeys: [
                .fileResourceIdentifierKey, .contentModificationDateKey, .fileSizeKey,
            ]),
            let current = values.fileResourceIdentifier as? NSObject,
            identity.isEqual(current), values.contentModificationDate == modifiedAt,
            values.fileSize == fileSize
        else {
            issue("视频已移动、修改、删除或被其他文件替换，请在 Finder 中查看。")
            return false
        }
        return true
    }

    /// 业务作用: 记录当前成品身份和内容状态，避免录后操作使用外部已经改变的成品。
    /// 参数说明: 无。
    /// 返回: 文件元数据可读时更新快照；无法读取时抛错供调用者说明。
    private func rememberIdentity() throws {
        let values = try url.resourceValues(forKeys: [
            .fileResourceIdentifierKey, .contentModificationDateKey, .fileSizeKey,
        ])
        identity = values.fileResourceIdentifier as? NSObject
        modifiedAt = values.contentModificationDate
        fileSize = values.fileSize
    }

    /// 业务作用: 打开应用内原生视频预览，不转交外部播放器。
    /// 参数说明: 无。
    /// 返回: 可播放、打开剪辑、分享或删除已完成文件。
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
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 800,
                height: 510
            ),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
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
            ("剪辑与拼接", #selector(edit)), ("分享", #selector(share(_:))),
            ("移到废纸篓", #selector(trash)), ("完成", #selector(done)),
        ]
        for descriptor in descriptors {
            let button = NSButton(
                title: descriptor.0,
                target: self,
                action: descriptor.1
            )
            actions.addArrangedSubview(button)
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

    /// 业务作用: 将录制成品交给独立的非破坏性剪辑窗口。
    /// 参数说明: 无。
    /// 返回: 暂停当前播放并打开剪辑，所有导出均另存新文件。
    @objc private func edit() {
        guard !hasWork, validate() else {
            return
        }
        playerView?.player?.pause()
        onEdit?(url)
    }

    /// 业务作用: 在分享完成或取消前持有成品，避免分享链接指向被删除的文件。
    /// 参数说明:
    /// - sender: 分享按钮，用于定位系统分享菜单。
    /// 返回: 分享期间拒绝删除同一文件。
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
    /// 返回: 取消不阻止之后剪辑或删除。
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

    /// 业务作用: 区分缩略图点击与主动拖动，不让按钮内部跟踪吞掉拖动事件。
    /// 参数说明:
    /// - event: 用户在缩略图按下鼠标的事件。
    /// 返回: 点击打开预览，拖动只提供已完成文件。
    override func mouseDown(with event: NSEvent) {
        guard let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else {
            return
        }
        if next.type == .leftMouseDragged {
            mouseDragged(with: next)
        } else {
            performClick(nil)
        }
    }

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
