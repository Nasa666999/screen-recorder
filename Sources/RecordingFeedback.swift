import AppKit
import ScreenCaptureKit

@MainActor
final class RecordingStatusIndicator {
    private var timer: Timer?
    private weak var button: NSStatusBarButton?
    private var bright = true

    /// 业务作用: 让菜单栏准确区分正在录制、正在收尾和空闲状态，只有实际录制时闪烁红点。
    /// 参数说明:
    /// - state: 当前录制会话状态。
    /// - button: 本应用的菜单栏入口。
    /// - stopAvailable: 专用停止快捷键是否可用。
    /// 返回: 状态变化立即反映到图标和辅助功能说明，不改变点击停止行为。
    func update(_ state: RecordingState, button: NSStatusBarButton?, stopAvailable: Bool) {
        self.button = button
        if state == .recording {
            button?.setAccessibilityLabel("正在录制，点击停止")
            button?.toolTip = stopAvailable ? "正在录制 · 点击停止（⌃⌘Esc）" : "正在录制 · 点击此处停止"
            if timer == nil {
                bright = true
                paint()
                let timer = Timer(
                    timeInterval: 0.6,
                    repeats: true
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else {
                            return
                        }
                        self.bright.toggle()
                        self.paint()
                    }
                }
                self.timer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
            return
        }
        stop()
        let label = state.isBusy ? "停止录制" : "Screen Recorder"
        button?.image = NSImage(
            systemSymbolName: state.isBusy ? "stop.circle.fill" : "record.circle",
            accessibilityDescription: label
        )
        button?.setAccessibilityLabel(label)
        button?.toolTip =
            state.isBusy
            ? (stopAvailable ? "停止录制（⌃⌘Esc）" : "停止快捷键被占用，请点击此处停止")
            : "显示录制工具"
    }

    /// 业务作用: 结束红点动画，避免停止后仍向用户呈现正在采集的状态。
    /// 参数说明: 无。
    /// 返回: 不再保留菜单栏动画定时器。
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 业务作用: 绘制保留红色的小圆点，亮暗两态都能在菜单栏中辨认。
    /// 参数说明:
    /// - bright: 是否绘制闪烁周期中的明亮状态。
    /// 返回: 非模板图像，系统菜单栏主题不会把红色替换为单色。
    static func image(bright: Bool) -> NSImage {
        let image = NSImage(
            size: NSSize(
                width: 18,
                height: 18
            ),
            flipped: false
        ) { _ in
            NSColor.systemRed.withAlphaComponent(bright ? 1 : 0.25).setFill()
            NSBezierPath(
                ovalIn: NSRect(
                    x: 5,
                    y: 5,
                    width: 8,
                    height: 8
                )
            ).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// 业务作用: 只更新当前菜单栏入口的闪烁相位，不创建新的状态项。
    /// 参数说明: 无。
    /// 返回: 点击命中范围保持不变，仅圆点亮度变化。
    private func paint() {
        button?.image = Self.image(bright: bright)
    }
}

@MainActor
final class RecordingBorderController {
    private var panel: NSPanel?
    private var view: RecordingBorderView?

    /// 业务作用: 在全屏或区域录制的实际来源上保留明显边框，不拦截被录应用的操作。
    /// 参数说明:
    /// - selection: 用户开始录制时冻结的来源。
    /// 返回: 显示器来源出现边框；独立窗口不使用固定桌面坐标冒充跟随边框。
    func show(for selection: CaptureSelection) {
        hide()
        guard selection.window == nil,
            let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                    == selection.display.displayID
            })
        else {
            return
        }
        let filter = SCContentFilter(
            display: selection.display,
            excludingWindows: []
        )
        let source = CaptureGeometry.alignedSourceRect(
            selection.region
                ?? CGRect(
                    origin: .zero,
                    size: filter.contentRect.size
                ),
            scale: CGFloat(filter.pointPixelScale)
        )
        let frame = CaptureGeometry.desktopRect(for: source, screen: screen.frame)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        // 显示器来源随当前 Space 改变，边框也只在该显示器提示；鼠标穿透且采集过滤排除本应用。
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none
        let view = RecordingBorderView(
            frame: NSRect(
                origin: .zero,
                size: frame.size
            ))
        panel.contentView = view
        self.panel = panel
        self.view = view
        panel.orderFrontRegardless()
    }

    /// 业务作用: 在开始前和正式录制时显示不同提示，避免把准备阶段描述为已录制。
    /// 参数说明:
    /// - recording: 是否已成功写入首帧并进入录制状态。
    /// 返回: 只更新提示文字，不改变冻结的采集范围。
    func setRecording(_ recording: Bool) {
        view?.recording = recording
        view?.needsDisplay = true
    }

    /// 业务作用: 停止、取消或来源失败时撤销本次录制边框。
    /// 参数说明: 无。
    /// 返回: 不留下遮罩、交互窗口或后台动画。
    func hide() {
        panel?.orderOut(nil)
        panel = nil
        view = nil
    }
}

@MainActor
final class RecordingBorderView: NSView {
    var recording = false

    /// 业务作用: 用高对比的边框标出采集内缘，画面中央保持透明。
    /// 参数说明:
    /// - dirtyRect: 当前需要重绘的区域。
    /// 返回: 黑白衬线和红色边框在明暗背景上均可辨认。
    override func draw(_ dirtyRect: NSRect) {
        let border = NSBezierPath(rect: bounds.insetBy(dx: 2.5, dy: 2.5))
        NSColor.black.withAlphaComponent(0.85).setStroke()
        border.lineWidth = 5
        border.stroke()
        NSColor.white.setStroke()
        border.lineWidth = 4
        border.stroke()
        NSColor.systemRed.setStroke()
        border.lineWidth = 2.5
        border.stroke()
        if bounds.width >= 110, bounds.height >= 45 {
            let badge = NSRect(
                x: 8,
                y: bounds.height - 27,
                width: 90,
                height: 20
            )
            NSColor.black.withAlphaComponent(0.8).setFill()
            NSBezierPath(
                roundedRect: badge,
                xRadius: 5,
                yRadius: 5
            ).fill()
            let text = recording ? "● 正在录制" : "准备录制"
            (text as NSString).draw(
                at: NSPoint(
                    x: badge.minX + 8,
                    y: badge.minY + 3
                ),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.white,
                ]
            )
        }
    }
}
