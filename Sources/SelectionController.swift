import AppKit
import ScreenCaptureKit

final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }
}

@MainActor
final class SelectionController {
    var onSelection: ((CaptureSelection, Bool) -> Void)?
    var onCancel: (() -> Void)?
    var onInvalidSelection: (() -> Void)?
    private var panels: [NSPanel] = []

    /// 业务作用: 在各显示器建立本次选择层，不改变其他应用的窗口或权限。
    /// 参数说明:
    /// - mode: 当前选择的画面模式。
    /// - content: 系统当前允许采集的来源。
    /// - options: 区域记忆及目标显示器配置。
    /// 返回: 选择变化经回调交还工具栏，窗口和全屏点击可直接提交开始。
    func show(mode: CaptureMode, content: SCShareableContent, options: RecorderOptions) {
        hide()
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let orderedIDs =
            (CGWindowListCopyWindowInfo(
                .optionOnScreenOnly,
                kCGNullWindowID
            ) as? [[String: Any]] ?? [])
            .compactMap {
                $0[kCGWindowNumber as String] as? UInt32
            }
        let ranks = Dictionary(
            uniqueKeysWithValues: orderedIDs.enumerated().map {
                ($1, $0)
            })
        let windows = content.windows.filter {
            $0.isOnScreen && $0.windowLayer == 0 && $0.frame.width > 8 && $0.frame.height > 8
                && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
        }.sorted {
            (ranks[$0.windowID] ?? Int.max) < (ranks[$1.windowID] ?? Int.max)
        }
        for screen in NSScreen.screens {
            guard
                let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? NSNumber,
                let display = content.displays.first(where: {
                    $0.displayID == number.uint32Value
                })
            else {
                continue
            }
            let panel = SelectionPanel(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .floating
            panel.collectionBehavior = [.fullScreenAuxiliary]
            panel.acceptsMouseMovedEvents = true
            let view = SelectionView(
                frame: NSRect(
                    origin: .zero,
                    size: screen.frame.size
                ))
            view.mode = mode
            view.windows = windows
            view.screenFrame = screen.frame
            view.primaryHeight = primaryHeight
            view.onCancel = { [weak self] in
                self?.onCancel?()
            }
            view.onInvalidate = { [weak self] in
                self?.onInvalidSelection?()
            }
            view.onChange = { [weak self] rect, window, start in
                self?.onSelection?(
                    CaptureSelection(
                        display: display,
                        window: window,
                        region: rect
                    ), start)
            }
            if mode == .region, options.rememberSelection, options.savedDisplayID == display.displayID,
                let region = options.savedRegion
            {
                let local = NSRect(
                    x: region.minX,
                    y: screen.frame.height - region.maxY,
                    width: region.width,
                    height: region.height
                )
                if view.bounds.contains(local), local.width >= 8, local.height >= 8 {
                    view.region = local
                    onSelection?(
                        CaptureSelection(
                            display: display,
                            window: nil,
                            region: region
                        ), false)
                }
            }
            panel.contentView = view
            panel.orderFrontRegardless()
            panels.append(panel)
        }
    }

    /// 业务作用: 隐藏并释放选择层，使其不进入后续媒体采集。
    /// 参数说明: 无。
    /// 返回: 当前选择层全部退出显示。
    func hide() {
        for panel in panels {
            panel.orderOut(nil)
        }
        panels.removeAll()
    }
}

@MainActor
private final class SelectionView: NSView {
    var mode = CaptureMode.display
    var windows: [SCWindow] = []
    var screenFrame = NSRect.zero
    var primaryHeight: CGFloat = 0
    var region: NSRect?
    var onChange: ((CGRect?, SCWindow?, Bool) -> Void)?
    var onCancel: (() -> Void)?
    var onInvalidate: (() -> Void)?
    private var highlighted: SCWindow?
    private var origin = NSPoint.zero
    private var original = NSRect.zero
    private var handle = -1

    override var acceptsFirstResponder: Bool {
        true
    }

    /// 业务作用: 跟踪当前选择层上的鼠标，不建立全局输入监听。
    /// 参数说明: 无。
    /// 返回: 悬停可更新窗口高亮。
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.activeAlways, .mouseMoved, .inVisibleRect],
                owner: self
            ))
    }

    /// 业务作用: 绘制来源遮罩与区域控制点，明确实际录制边界。
    /// 参数说明:
    /// - dirtyRect: 需要重绘的视图范围。
    /// 返回: 高亮只属于选择过程，不构成录制内容。
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds)
        let selected: NSRect?
        if mode == .window, let window = highlighted {
            selected = localRect(window.frame)
        } else {
            selected = region
        }
        if let selected {
            path.appendRect(selected)
            path.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.22).setFill()
        path.fill()
        if let selected {
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selected)
            border.lineWidth = 2
            border.stroke()
            if mode == .region {
                for point in handles(selected) {
                    NSColor.white.setFill()
                    NSBezierPath(
                        ovalIn: NSRect(
                            x: point.x - 4,
                            y: point.y - 4,
                            width: 8,
                            height: 8
                        )
                    ).fill()
                }
                let text = "\(Int(selected.width)) × \(Int(selected.height))" as NSString
                text.draw(
                    at: NSPoint(
                        x: selected.minX + 8,
                        y: max(8, selected.minY - 25)
                    ),
                    withAttributes: [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
                        .foregroundColor: NSColor.white,
                    ])
            }
        }
    }

    /// 业务作用: 将系统顶部原点的窗口边界转换为当前屏幕的 Cocoa 局部坐标。
    /// 参数说明:
    /// - rect: ScreenCaptureKit 返回的窗口边界。
    /// 返回: 当前选择层坐标中的窗口矩形。
    private func localRect(_ rect: CGRect) -> NSRect {
        NSRect(
            x: rect.minX - screenFrame.minX,
            y: primaryHeight - rect.maxY - screenFrame.minY,
            width: rect.width,
            height: rect.height
        )
    }

    /// 业务作用: 生成八个调整点，统一绘制与命中范围。
    /// 参数说明:
    /// - rect: 当前选区。
    /// 返回: 从左下角开始的边缘与角点。
    private func handles(_ rect: NSRect) -> [NSPoint] {
        [
            NSPoint(
                x: rect.minX,
                y: rect.minY
            ),
            NSPoint(
                x: rect.midX,
                y: rect.minY
            ),
            NSPoint(
                x: rect.maxX,
                y: rect.minY
            ),
            NSPoint(
                x: rect.maxX,
                y: rect.midY
            ),
            NSPoint(
                x: rect.maxX,
                y: rect.maxY
            ),
            NSPoint(
                x: rect.midX,
                y: rect.maxY
            ),
            NSPoint(
                x: rect.minX,
                y: rect.maxY
            ),
            NSPoint(
                x: rect.minX,
                y: rect.midY
            ),
        ]
    }

    /// 业务作用: 按当前前后顺序高亮鼠标下的原始窗口。
    /// 参数说明:
    /// - event: 当前选择层的鼠标移动。
    /// 返回: 窗口选择不切换或激活目标应用。
    override func mouseMoved(with event: NSEvent) {
        guard mode == .window else {
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        highlighted = windows.first {
            localRect($0.frame).contains(point)
        }
        needsDisplay = true
    }

    /// 业务作用: 提交屏幕或窗口选择，或开始区域的创建与调整。
    /// 参数说明:
    /// - event: 用户主动点击事件。
    /// 返回: 屏幕和窗口模式提交开始，区域模式等待拖动完成。
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        origin = convert(event.locationInWindow, from: nil)
        if mode == .display {
            onChange?(nil, nil, true)
            return
        }
        if mode == .window {
            mouseMoved(with: event)
            if let highlighted {
                onChange?(nil, highlighted, true)
            }
            return
        }
        original = region ?? .zero
        onInvalidate?()
        handle = -1
        if let region {
            handle =
                handles(region).firstIndex {
                    hypot($0.x - origin.x, $0.y - origin.y) <= 12
                }
                ?? (region.contains(origin) ? 8 : -1)
        }
        if handle == -1 {
            region = NSRect(
                origin: origin,
                size: .zero
            )
        }
    }

    /// 业务作用: 调整同一显示器内的选区，禁止越界扩大录制范围。
    /// 参数说明:
    /// - event: 区域调整事件。
    /// 返回: 更新可见边界，不启动采集。
    override func mouseDragged(with event: NSEvent) {
        guard mode == .region else {
            return
        }
        let raw = convert(event.locationInWindow, from: nil)
        let point = NSPoint(
            x: min(bounds.maxX, max(0, raw.x)),
            y: min(bounds.maxY, max(0, raw.y))
        )
        if handle == 8 {
            region = NSRect(
                x: min(bounds.width - original.width, max(0, original.minX + point.x - origin.x)),
                y: min(bounds.height - original.height, max(0, original.minY + point.y - origin.y)),
                width: original.width,
                height: original.height
            )
        } else {
            var left = original.minX
            var right = original.maxX
            var bottom = original.minY
            var top = original.maxY
            if handle == -1 {
                left = origin.x
                right = point.x
                bottom = origin.y
                top = point.y
            } else {
                if [0, 6, 7].contains(handle) {
                    left = point.x
                }
                if [2, 3, 4].contains(handle) {
                    right = point.x
                }
                if [0, 1, 2].contains(handle) {
                    bottom = point.y
                }
                if [4, 5, 6].contains(handle) {
                    top = point.y
                }
            }
            region = NSRect(
                x: min(left, right),
                y: min(bottom, top),
                width: abs(right - left),
                height: abs(top - bottom)
            )
        }
        needsDisplay = true
    }

    /// 业务作用: 将区域转换为显示器内的顶部原点坐标，交还录制工具栏。
    /// 参数说明:
    /// - event: 用户结束调整事件。
    /// 返回: 合法区域可录制；过小区域仍保持不可开始。
    override func mouseUp(with event: NSEvent) {
        guard mode == .region, let region, region.width >= 8, region.height >= 8 else {
            return
        }
        onChange?(
            CGRect(
                x: region.minX,
                y: bounds.height - region.maxY,
                width: region.width,
                height: region.height
            ),
            nil, false)
    }

    /// 业务作用: 允许用户取消当前选择，不转发取消键到其他应用。
    /// 参数说明:
    /// - event: 当前选择界面的键盘事件。
    /// 返回: Escape 关闭选择层，其他按键按系统处理。
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }
}
