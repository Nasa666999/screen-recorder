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
            button?.toolTip = stopAvailable ? "正在录制 · 点击停止（⌃Esc）" : "正在录制 · 点击此处停止"
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
            ? (stopAvailable ? "停止录制（⌃Esc）" : "停止快捷键被占用，请点击此处停止")
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
    private var windowMonitor: Timer?
    private var spaceObserver: NSObjectProtocol?

    /// 业务作用: 在实际录制来源上保留明显边框，窗口来源跟随原窗口且不拦截操作。
    /// 参数说明:
    /// - selection: 用户开始录制时冻结的来源。
    /// 返回: 显示器和区域保持固定范围；窗口仅在身份匹配且位于当前桌面时显示边框。
    func show(for selection: CaptureSelection) {
        hide()
        if let window = selection.window {
            // 窗口缺少所属进程时不能按显示器来源解释，否则提示范围会扩大到整个屏幕。
            guard let application = window.owningApplication else {
                return
            }
            let identifier = window.windowID
            let processID = application.processID
            makePanel(
                frame: CaptureGeometry.desktopWindowRect(
                    for: window.frame, primaryHeight: NSScreen.screens.first?.frame.height ?? 0))
            refreshWindow(identifier: identifier, processID: processID)
            // 只跟随已冻结的窗口身份；最小化或切换桌面时隐藏提示，不停止跨桌面的独立窗口采集。
            let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshWindow(identifier: identifier, processID: processID)
                }
            }
            windowMonitor = timer
            RunLoop.main.add(timer, forMode: .common)
            spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    // 桌面切换先撤下旧位置，再由当前窗口可见性证据恢复，避免在新桌面显示旧轮廓。
                    self?.panel?.orderOut(nil)
                }
            }
            return
        }
        guard
            let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                    == selection.display.displayID
            })
        else {
            // 显示器身份缺失时不能把提示放到另一块屏幕，采集层独立报告来源失效。
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
        makePanel(frame: frame)
        panel?.orderFrontRegardless()
    }

    /// 业务作用: 建立可穿透且不进入成片的统一边框窗口。
    /// 参数说明:
    /// - frame: 已转换为 AppKit 全局坐标的来源边界。
    /// 返回: 创建边框但暂不显示，调用方须先核实来源仍可见。
    private func makePanel(frame: CGRect) {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        // 提示不取得键盘或鼠标输入；显示器采集排除本应用，独立窗口采集只包含原窗口。
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
    }

    /// 业务作用: 依据原窗口的当前身份和可见性更新边框，拒绝复用同编号的其他窗口。
    /// 参数说明:
    /// - identifier: 开始录制时冻结的窗口编号。
    /// - processID: 原窗口所属进程。
    /// 返回: 原窗口可见时跟随位置，否则仅隐藏提示而不改变采集来源。
    private func refreshWindow(identifier: CGWindowID, processID: pid_t) {
        let entries = CGWindowListCopyWindowInfo(.optionIncludingWindow, identifier) as? [[String: Any]] ?? []
        guard
            let frame = Self.visibleWindowFrame(
                entries: entries, identifier: identifier, processID: processID,
                primaryHeight: NSScreen.screens.first?.frame.height ?? 0)
        else {
            // 窗口缺席、最小化或进程身份变化时，旧坐标不再具有提示原来源的依据。
            panel?.orderOut(nil)
            return
        }
        if panel?.frame != frame {
            panel?.setFrame(frame, display: true)
        }
        if panel?.isVisible != true {
            panel?.orderFrontRegardless()
        }
    }

    /// 业务作用: 从当前窗口证据解析可显示的原来源边界，身份不匹配时拒绝提示。
    /// 参数说明:
    /// - entries: Core Graphics 查询得到的窗口信息。
    /// - identifier: 已冻结的窗口编号。
    /// - processID: 已冻结的所属进程。
    /// - primaryHeight: 主显示器逻辑高度。
    /// 返回: 仅原窗口在当前桌面可见且具有有效尺寸时返回全局边界，否则返回空。
    static func visibleWindowFrame(
        entries: [[String: Any]], identifier: CGWindowID, processID: pid_t, primaryHeight: CGFloat
    ) -> CGRect? {
        guard
            let entry = entries.first(where: {
                ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == identifier
                    && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID
            }), (entry[kCGWindowIsOnscreen as String] as? Bool) == true,
            let bounds = entry[kCGWindowBounds as String] as? [String: Any],
            let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
            frame.width > 8, frame.height > 8,
            frame.origin.x.isFinite, frame.origin.y.isFinite,
            frame.width.isFinite, frame.height.isFinite
        else {
            return nil
        }
        return CaptureGeometry.desktopWindowRect(for: frame, primaryHeight: primaryHeight)
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
        windowMonitor?.invalidate()
        windowMonitor = nil
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
            self.spaceObserver = nil
        }
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
