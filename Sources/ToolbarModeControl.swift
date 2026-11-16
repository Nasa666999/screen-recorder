import AppKit

@MainActor
final class ToolbarModeControl: NSSegmentedControl {
    var hoverHints: [String] = [] {
        didSet {
            setAccessibilityHelp(hoverHints.joined(separator: "\n"))
            hideHint()
        }
    }
    private var hoverArea: NSTrackingArea?
    private var hintPanel: NSPanel?
    private var hoveredSegment: Int?
    private var pointerTimer: Timer?

    override var isEnabled: Bool {
        didSet {
            if !isEnabled {
                stopHoverHints()
            } else if window?.isVisible == true {
                startHoverHints()
            }
        }
    }

    /// 业务作用: 为浮动工具栏建立始终有效的局部悬停跟踪，不依赖系统 tooltip 的延迟与激活状态。
    /// 参数说明: 无。
    /// 返回: 只跟踪当前控件，不监听其他应用的鼠标事件。
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    /// 业务作用: 鼠标进入模式图标时立即呈现对应说明，不要求先点击或激活工具栏。
    /// 参数说明:
    /// - event: 当前控件内的鼠标进入事件。
    /// 返回: 提示只显示在工具栏附近，不改变所选录制模式。
    override func mouseEntered(with event: NSEvent) {
        startHoverHints()
        showHint(at: convert(event.locationInWindow, from: nil))
    }

    /// 业务作用: 鼠标在三个模式之间移动时同步更新提示。
    /// 参数说明:
    /// - event: 当前工具栏窗口的鼠标移动事件。
    /// 返回: 相同模式保持现有提示，切换图标时替换说明。
    override func mouseMoved(with event: NSEvent) {
        showHint(at: convert(event.locationInWindow, from: nil))
    }

    /// 业务作用: 鼠标离开图标后撤下提示，避免遮挡桌面操作。
    /// 参数说明:
    /// - event: 当前控件的鼠标离开事件。
    /// 返回: 说明不再占用屏幕空间。
    override func mouseExited(with event: NSEvent) {
        hideHint()
    }

    /// 业务作用: 保留系统分段控件的选择动作，并在点击结束后恢复当前图标的悬停说明。
    /// 参数说明:
    /// - event: 用户点击模式图标的事件。
    /// 返回: 点击仍只改变模式，提示窗口不参与选择或开始录制。
    override func mouseDown(with event: NSEvent) {
        stopHoverHints()
        super.mouseDown(with: event)
        startHoverHints()
        showHint(at: convert(event.locationInWindow, from: nil))
    }

    /// 业务作用: 控件离开原窗口时撤销提示归属，避免提示残留在旧桌面。
    /// 参数说明:
    /// - newWindow: 控件即将所属的工具栏窗口，移除时为空。
    /// 返回: 原窗口不再持有该控件的提示子窗口。
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow {
            stopHoverHints()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    /// 业务作用: 工具栏可见时定期复验控件内的指针，兼容分段控件内部视图未转交进入事件的情况。
    /// 参数说明: 无。
    /// 返回: 最多持有一个本地指针定时器，不申请全局输入监听权限。
    func startHoverHints() {
        guard isEnabled, window?.isVisible == true else {
            stopHoverHints()
            return
        }
        if pointerTimer == nil {
            let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshPointer()
                }
            }
            pointerTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        refreshPointer()
    }

    /// 业务作用: 工具栏关闭、开始录制或控件停用时归还指针取样资源。
    /// 参数说明: 无。
    /// 返回: 定时器停止，当前提示同时撤下。
    func stopHoverHints() {
        pointerTimer?.invalidate()
        pointerTimer = nil
        hideHint()
    }

    /// 业务作用: 以当前工具栏窗口的局部指针位置更新提示，鼠标按下或模态提示期间不遮挡操作。
    /// 参数说明: 无。
    /// 返回: 指针位于图标时显示对应说明，离开或窗口隐藏时自动清除。
    private func refreshPointer() {
        guard let window, window.isVisible, isEnabled else {
            stopHoverHints()
            return
        }
        guard NSEvent.pressedMouseButtons == 0, NSApp.modalWindow == nil else {
            hideHint()
            return
        }
        showHint(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    /// 业务作用: 撤下当前悬停说明，保持提示窗口不可接收输入。
    /// 参数说明: 无。
    /// 返回: 提示隐藏且解除父窗口关联，不影响工具栏和来源选择。
    func hideHint() {
        hoveredSegment = nil
        hintPanel?.orderOut(nil)
        if let hintPanel, let parent = hintPanel.parent {
            parent.removeChildWindow(hintPanel)
        }
    }

    /// 业务作用: 将当前指针对应的模式说明呈现在不拦截输入的浮动窗口中。
    /// 参数说明:
    /// - point: 模式控件内的局部指针位置。
    /// 返回: 有效且可操作的图标显示说明，越界、隐藏或停用时撤下提示。
    private func showHint(at point: CGPoint) {
        guard isEnabled, let window, window.isVisible,
            bounds.contains(point), bounds.width > 0,
            segmentCount > 0, hoverHints.count == segmentCount
        else {
            hideHint()
            return
        }
        let index = min(segmentCount - 1, Int((point.x - bounds.minX) / bounds.width * CGFloat(segmentCount)))
        if hoveredSegment == index, hintPanel?.isVisible == true, hintPanel?.parent === window {
            return
        }
        let text = hoverHints[index]
        let font = NSFont.systemFont(ofSize: 11)
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: 280, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let size = NSSize(
            width: ceil(measured.width) + 20,
            height: ceil(measured.height) + 16
        )
        if hintPanel == nil {
            let panel = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.title = "录制模式提示"
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            // 提示只用于阅读，不能吞掉图标或桌面的点击；采集过滤排除本应用窗口。
            panel.ignoresMouseEvents = true
            hintPanel = panel
        }
        guard let hintPanel else {
            return
        }
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = NSVisualEffectView.Material.toolTip
        effect.state = NSVisualEffectView.State.active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 7
        effect.layer?.masksToBounds = true
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = .labelColor
        label.frame = NSRect(
            x: 10,
            y: 8,
            width: size.width - 20,
            height: size.height - 16
        )
        effect.addSubview(label)
        hintPanel.contentView = effect
        hintPanel.setContentSize(size)
        hintPanel.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
        let segmentWidth = bounds.width / CGFloat(segmentCount)
        let anchor = convert(
            NSRect(
                x: bounds.minX + CGFloat(index) * segmentWidth, y: bounds.minY, width: segmentWidth,
                height: bounds.height),
            to: nil
        )
        let global = window.convertToScreen(anchor)
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let x = min(max(visible.minX + 8, global.midX - size.width / 2), visible.maxX - size.width - 8)
        var y = window.frame.minY - size.height - 8
        if y < visible.minY + 8 {
            y = window.frame.maxY + 8
        }
        hintPanel.setFrameOrigin(NSPoint(x: x, y: y))
        if hintPanel.parent !== window {
            hintPanel.parent?.removeChildWindow(hintPanel)
            window.addChildWindow(hintPanel, ordered: .above)
        }
        hoveredSegment = index
        hintPanel.orderFrontRegardless()
    }
}
