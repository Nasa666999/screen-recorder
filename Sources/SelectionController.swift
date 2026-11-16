import AppKit
import ScreenCaptureKit

final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }
}

@MainActor
final class SelectionController {
    var onSelection: ((CaptureSelection) -> Void)?
    var onCancel: (() -> Void)?
    var onInvalidSelection: (() -> Void)?
    private var panels: [NSPanel] = []
    private var regionEditors: [RegionInteractionController] = []

    var isVisible: Bool {
        panels.contains {
            $0.isVisible
        }
    }

    /// 业务作用: 在各显示器建立本次选择层，不改变其他应用的窗口或权限。
    /// 参数说明:
    /// - mode: 当前选择的画面模式。
    /// - content: 系统当前允许采集的来源。
    /// - options: 区域记忆及目标显示器配置。
    /// 返回: 至少建立一个显示器选择层时返回真；点击只发布来源选择，开始录制由工具栏独立处理。
    func show(mode: CaptureMode, content: SCShareableContent, options: RecorderOptions) -> Bool {
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
        let applications = content.applications.filter {
            $0.processID == ProcessInfo.processInfo.processIdentifier
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
            // 完全透明的高亮内部会让 WindowServer 把点击交给原窗口，保留低透明度背景承接来源选择。
            panel.backgroundColor = NSColor.black.withAlphaComponent(0.01)
            panel.ignoresMouseEvents = false
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.fullScreenAuxiliary]
            panel.acceptsMouseMovedEvents = true
            let view = SelectionView(
                frame: NSRect(
                    origin: .zero,
                    size: screen.frame.size
                ))
            view.mode = mode
            view.displayID = display.displayID
            view.windows = windows
            view.screenFrame = screen.frame
            view.primaryHeight = primaryHeight
            view.pixelScale = CGFloat(
                SCContentFilter(
                    display: display,
                    excludingWindows: []
                ).pointPixelScale)
            view.onCancel = { [weak self] in
                self?.onCancel?()
            }
            view.onInvalidate = { [weak self] in
                self?.onInvalidSelection?()
            }
            view.onChange = { [weak self] rect, window in
                self?.onSelection?(
                    CaptureSelection(
                        display: display,
                        window: window,
                        region: rect
                    ))
            }
            if mode == .region, options.rememberSelection, options.savedDisplayID == display.displayID,
                let region = options.savedRegion
            {
                let region = CaptureGeometry.alignedSourceRect(region, scale: view.pixelScale)
                let local = NSRect(
                    x: region.minX,
                    y: screen.frame.height - region.maxY,
                    width: region.width,
                    height: region.height
                )
                if view.bounds.contains(local), local.width >= 8, local.height >= 8 {
                    view.region = local
                    view.isRegionCommitted = true
                    onSelection?(
                        CaptureSelection(
                            display: display,
                            window: nil,
                            region: region
                        ))
                }
            }
            panel.contentView = view
            if mode == .region {
                view.setAccessibilityElement(true)
                view.setAccessibilityRole(.group)
                view.setAccessibilityLabel("录制区域选择")
                view.setAccessibilityHelp("拖动选择区域；方向键移动一个像素，Shift 移动十个像素，Option 调整边缘。")
                view.configureMagnifier(display: display, applications: applications)
            }
            panel.orderFrontRegardless()
            panels.append(panel)
            if mode == .region {
                let editor = RegionInteractionController(overlay: panel, view: view)
                regionEditors.append(editor)
                editor.update()
            }
        }
        return !panels.isEmpty
    }

    /// 业务作用: 在各显示器同步用户已选定的来源，让鼠标移向录制按钮时仍能核对边界。
    /// 参数说明:
    /// - source: 当前选择流程内明确选定的来源，不跨关闭或桌面切换复用。
    /// 返回: 只更新选择边框，不隐藏选择层或开始采集。
    func setSelection(_ source: CaptureSelection) {
        for panel in panels {
            guard let view = panel.contentView as? SelectionView else {
                continue
            }
            view.selectedWindow = source.window
            view.selectedDisplay = source.display.displayID == view.displayID
            view.needsDisplay = true
        }
    }

    /// 业务作用: 响应用户明确的重新框选请求，暂时恢复绘制新区域所需的鼠标接收范围。
    /// 参数说明: 无。
    /// 返回: 清除当前区域并停用录制入口，直到新的有效选区完成；不开始录制。
    func beginRegionSelection() {
        for panel in panels {
            (panel.contentView as? SelectionView)?.resetRegionSelection()
        }
    }

    /// 业务作用: 隐藏并释放选择层，使其不进入后续媒体采集。
    /// 参数说明: 无。
    /// 返回: 当前选择层全部退出显示。
    func hide() {
        for editor in regionEditors {
            editor.hide()
        }
        regionEditors.removeAll()
        for panel in panels {
            (panel.contentView as? SelectionView)?.stopMagnifier()
            panel.orderOut(nil)
        }
        panels.removeAll()
    }
}

@MainActor
private final class RegionInteractionController {
    private weak var overlay: NSPanel?
    private weak var view: SelectionView?
    private var control: NSPanel?

    /// 业务作用: 将已完成选区的鼠标接收范围收缩到选区及控制点，不拦截框外桌面点击。
    /// 参数说明:
    /// - overlay: 负责绘制选区的显示器窗口。
    /// - view: 保存当前选区与调整状态的视图。
    /// 返回: 选区状态变化只更新对应的局部输入窗口。
    init(overlay: NSPanel, view: SelectionView) {
        self.overlay = overlay
        self.view = view
        view.onRegionUpdate = { [weak self] in
            self?.update()
        }
    }

    /// 业务作用: 区分首次框选和已选定状态，完成后让全屏绘制层穿透并保留框内拖动与控制点缩放。
    /// 参数说明: 无。
    /// 返回: 框外正常操作桌面；框内左键拖动整体，控制点调整大小。
    func update() {
        guard let overlay, let view else {
            hide()
            return
        }
        // 已选定来源不再拥有整个桌面的输入，只在选区及控制点范围接收拖动，框外交给原桌面应用。
        overlay.ignoresMouseEvents = view.isRegionCommitted
        overlay.backgroundColor = view.isRegionCommitted ? .clear : NSColor.black.withAlphaComponent(0.01)
        view.needsDisplay = true
        if !view.isRegionCommitted {
            control?.orderOut(nil)
            return
        }
        // 松开鼠标后不继续读取桌面像素；再次拖动边框时才恢复放大镜。
        if !view.isDraggingRegion {
            view.stopMagnifier()
        }
        guard let region = view.region, region.width >= 8, region.height >= 8 else {
            // 调整过程中可以短暂经过零尺寸，不销毁正在接收拖动的窗口；结束时恢复有效区域。
            return
        }
        let local = CaptureGeometry.regionInteractionFrame(for: region, in: view.bounds)
        guard !local.isNull, !local.isEmpty else {
            return
        }
        if control == nil {
            control = makeControl()
        }
        let global = NSRect(
            origin: overlay.convertPoint(toScreen: local.origin),
            size: local.size
        )
        if control?.frame != global {
            control?.setFrame(global, display: true)
        }
        if control?.isVisible != true {
            control?.orderFrontRegardless()
        }
    }

    /// 业务作用: 建立覆盖选区及控制点的本地鼠标入口，保留框内整体拖动和键盘操作。
    /// 参数说明: 无。
    /// 返回: 不激活被框住的应用，鼠标事件只交给当前选区，不重新发送到其他应用。
    private func makeControl() -> NSPanel {
        let panel = SelectionPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "调整录制区域"
        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.01)
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary]
        let input = RegionInteractionView(frame: .zero)
        input.toolTip = "拖动选区移动，拖动控制点调整大小"
        input.onMouse = { [weak self] event in
            guard let self, let view = self.view, let overlay = self.overlay,
                let source = event.window
            else {
                return
            }
            let global = source.convertPoint(toScreen: event.locationInWindow)
            let point = view.convert(overlay.convertPoint(fromScreen: global), from: nil)
            switch event.type {
            case .leftMouseDown:
                view.beginRegionDrag(at: point, existingOnly: true)
            case .leftMouseDragged:
                view.dragRegion(to: point)
            case .leftMouseUp:
                view.finishRegionDrag()
                self.update()
            default:
                break
            }
        }
        input.onKey = { [weak self] event in
            self?.view?.keyDown(with: event)
        }
        panel.contentView = input
        return panel
    }

    /// 业务作用: 选择取消、模式变化或开始录制时撤下选区输入窗口。
    /// 参数说明: 无。
    /// 返回: 不残留阻挡桌面操作的局部窗口。
    func hide() {
        control?.orderOut(nil)
        control = nil
    }
}

@MainActor
private final class RegionInteractionView: NSView {
    var onMouse: ((NSEvent) -> Void)?
    var onKey: ((NSEvent) -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    /// 业务作用: 当前桌面应用处于前台时，第一次点击选区即可移动整体或调整控制点。
    /// 参数说明:
    /// - event: 点击选区或控制点的本地鼠标事件。
    /// 返回: 接收首次点击，不要求先激活工具栏。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    /// 业务作用: 为可拖动选区显示手形光标，框外保持原桌面应用的光标。
    /// 参数说明: 无。
    /// 返回: 光标提示仅覆盖当前选区输入窗口。
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    /// 业务作用: 锁定本次选区拖动的接收视图，使移动后仍能接收完整鼠标序列。
    /// 参数说明:
    /// - event: 选区内或控制点上的按下事件。
    /// 返回: 选区开始调整，后续拖动不会交给被框住的应用。
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onMouse?(event)
    }

    /// 业务作用: 将当前鼠标位置交给原选区调整，输入窗口移动后仍使用全局坐标换算。
    /// 参数说明:
    /// - event: 当前拖动事件。
    /// 返回: 更新同一个选区，不建立新的选择层。
    override func mouseDragged(with event: NSEvent) {
        onMouse?(event)
    }

    /// 业务作用: 结束选区调整并发布新的有效区域，框外继续接收桌面操作。
    /// 参数说明:
    /// - event: 当前拖动序列的松开事件。
    /// 返回: 本次鼠标序列完整结束，不触发录制。
    override func mouseUp(with event: NSEvent) {
        onMouse?(event)
    }

    /// 业务作用: 边框取得键盘焦点时保留像素移动和取消操作。
    /// 参数说明:
    /// - event: 当前边框收到的键盘事件。
    /// 返回: 仅更新或取消当前选区，不监听其他应用的键盘输入。
    override func keyDown(with event: NSEvent) {
        onKey?(event)
    }
}

@MainActor
private final class SelectionView: NSView {
    var mode = CaptureMode.display
    var displayID: CGDirectDisplayID = 0
    var selectedDisplay = false
    var selectedWindow: SCWindow?
    var windows: [SCWindow] = []
    var screenFrame = NSRect.zero
    var primaryHeight: CGFloat = 0
    var pixelScale: CGFloat = 1
    var region: NSRect?
    var onChange: ((CGRect?, SCWindow?) -> Void)?
    var onCancel: (() -> Void)?
    var onInvalidate: (() -> Void)?
    var onRegionUpdate: (() -> Void)?
    var isRegionCommitted = false
    private(set) var isDraggingRegion = false
    private var highlighted: SCWindow?
    private var origin = NSPoint.zero
    private var original = NSRect.zero
    private var handle = -1
    private let magnifier = PixelMagnifier()
    private var pointer: NSPoint?
    private var magnifierSample: MagnifierSample?
    private var magnifierUnavailable = false
    private var magnifierSource: (SCDisplay, [SCRunningApplication])?

    override var acceptsFirstResponder: Bool {
        true
    }

    /// 业务作用: 让来源选择层的首次点击直接选择来源，避免只激活应用而吞掉用户选择。
    /// 参数说明:
    /// - event: 点击来源选择层的鼠标事件。
    /// 返回: 允许当前选择层处理首次点击，不激活被录窗口。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
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
                options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                owner: self
            ))
    }

    /// 业务作用: 区域选择使用十字光标提示像素定位，不改变系统光标大小设置。
    /// 参数说明: 无。
    /// 返回: 光标只在本选择视图内改变。
    override func resetCursorRects() {
        super.resetCursorRects()
        if mode == .region {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    /// 业务作用: 保存本轮选区可用的放大镜来源，打开工具栏或移动到桌面内容时不读取屏幕像素。
    /// 参数说明:
    /// - display: 当前选择层对应的显示器。
    /// - applications: 应从像素图排除的本应用身份。
    /// 返回: 只保留来源元数据，实际拖动区域或边框时才开始取样。
    func configureMagnifier(display: SCDisplay, applications: [SCRunningApplication]) {
        magnifierSource = (display, applications)
    }

    /// 业务作用: 在用户明确开始拖动选区时开启附近像素取样，不把桌面自由操作当作采集请求。
    /// 参数说明: 无。
    /// 返回: 当前拖动期间可更新原始像素缓存，缺少本轮来源时不建立截图任务。
    private func startMagnifier() {
        guard let (display, applications) = magnifierSource else {
            return
        }
        magnifier.start(
            display: display, applications: applications, bounds: bounds,
            point: { [weak self] in
                self?.pointer
            },
            receive: { [weak self] result in
                guard let self else {
                    return
                }
                switch result {
                case .success(let sample):
                    self.magnifierSample = sample
                    self.magnifierUnavailable = false
                case .failure:
                    self.magnifierSample = nil
                    self.magnifierUnavailable = true
                }
                self.needsDisplay = true
            })
    }

    /// 业务作用: 关闭选区时清除像素数据和截图任务，不把放大镜带入录制状态。
    /// 参数说明: 无。
    /// 返回: 当前视图不再读取或持有屏幕像素。
    func stopMagnifier() {
        magnifier.stop()
        magnifierSample = nil
        pointer = nil
    }

    /// 业务作用: 用明暗双层轮廓绘制来源边界与区域控制点，使选区在不同桌面底色上保持可辨认。
    /// 参数说明:
    /// - dirtyRect: 需要重绘的视图范围。
    /// 返回: 高亮只属于选择过程，不构成录制内容。
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds)
        let selected: NSRect?
        if mode == .window, let window = selectedWindow ?? highlighted {
            selected = localRect(window.frame)
        } else if mode == .display, selectedDisplay {
            selected = bounds.insetBy(dx: 2, dy: 2)
        } else {
            selected = region
        }
        if let selected {
            path.appendRect(selected)
            path.windingRule = .evenOdd
        }
        if mode != .region || !isRegionCommitted {
            NSColor.black.withAlphaComponent(0.22).setFill()
            path.fill()
        }
        if let selected {
            let border = NSBezierPath(rect: selected)
            // 同时保留深浅轮廓，底色或窗口内容变化时仍可辨认边界，不需要持续读取桌面像素。
            NSColor.black.setStroke()
            border.lineWidth = 4
            border.stroke()
            NSColor.white.setStroke()
            border.lineWidth = 2
            border.stroke()
            if mode == .region {
                for point in handles(selected) {
                    let control = NSBezierPath(
                        ovalIn: NSRect(
                            x: point.x - 4,
                            y: point.y - 4,
                            width: 8,
                            height: 8
                        ))
                    NSColor.white.setFill()
                    control.fill()
                    NSColor.black.setStroke()
                    control.lineWidth = 2
                    control.stroke()
                }
                drawRegionSize(for: selected)
            }
        }
        if mode == .region, isDraggingRegion, let pointer {
            drawMagnifier(at: pointer)
        }
    }

    /// 业务作用: 在选区附近显示具有独立深色底的像素尺寸，避免文字与浅色桌面混在一起。
    /// 参数说明:
    /// - selected: 当前显示器局部坐标中的实际选区。
    /// 返回: 尺寸标签限制在显示器内；没有容纳空间时不遮盖整个选择层。
    private func drawRegionSize(for selected: NSRect) {
        let text =
            "\(Int((selected.width * pixelScale).rounded())) × \(Int((selected.height * pixelScale).rounded())) px"
            as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attributes)
        let size = NSSize(
            width: ceil(textSize.width) + 12,
            height: ceil(textSize.height) + 6
        )
        guard bounds.width >= size.width + 16, bounds.height >= size.height + 16 else {
            return
        }
        let below = selected.minY - size.height - 8
        let frame = NSRect(
            x: min(max(bounds.minX + 8, selected.minX + 8), bounds.maxX - size.width - 8),
            y: min(
                max(bounds.minY + 8, below >= bounds.minY + 8 ? below : selected.maxY + 8),
                bounds.maxY - size.height - 8
            ),
            width: size.width,
            height: size.height
        )
        NSColor.black.withAlphaComponent(0.9).setFill()
        let background = NSBezierPath(
            roundedRect: frame,
            xRadius: 5,
            yRadius: 5
        )
        background.fill()
        NSColor.white.withAlphaComponent(0.8).setStroke()
        background.lineWidth = 1
        background.stroke()
        text.draw(
            at: NSPoint(
                x: frame.minX + 6,
                y: frame.minY + 3
            ),
            withAttributes: attributes
        )
    }

    /// 业务作用: 逐像素放大控制点附近的真实画面，并标明实际像素坐标和采样状态。
    /// 参数说明:
    /// - point: 已对齐物理像素的当前控制点。
    /// 返回: 放大镜避开屏幕边缘，无匹配采样时显示等待而不使用旧位置画面。
    private func drawMagnifier(at point: NSPoint) {
        let zoom: CGFloat = 7
        let side: CGFloat = 21 * zoom
        let size = NSSize(
            width: side + 20,
            height: side + 58
        )
        let x = point.x + size.width + 26 < bounds.maxX ? point.x + 26 : point.x - size.width - 26
        let y = point.y + size.height + 26 < bounds.maxY ? point.y + 26 : point.y - size.height - 26
        let frame = NSRect(
            x: min(max(8, x), max(8, bounds.width - size.width - 8)),
            y: min(max(8, y), max(8, bounds.height - size.height - 8)),
            width: size.width,
            height: size.height
        )
        NSColor.black.withAlphaComponent(0.92).setFill()
        NSBezierPath(
            roundedRect: frame,
            xRadius: 10,
            yRadius: 10
        ).fill()
        NSColor.white.withAlphaComponent(0.8).setStroke()
        NSBezierPath(
            roundedRect: frame.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 10,
            yRadius: 10
        ).stroke()
        let imageRect = NSRect(
            x: frame.minX + 10,
            y: frame.maxY - side - 10,
            width: side,
            height: side
        )
        if let sample = magnifierSample, sample.point == point {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.imageInterpolation = .none
            NSImage(
                cgImage: sample.image,
                size: NSSize(
                    width: 21,
                    height: 21
                )
            ).draw(in: imageRect)
            NSGraphicsContext.restoreGraphicsState()
            let grid = NSBezierPath()
            for index in 0...21 {
                let offset = CGFloat(index) * zoom
                grid.move(
                    to: NSPoint(
                        x: imageRect.minX + offset,
                        y: imageRect.minY
                    ))
                grid.line(
                    to: NSPoint(
                        x: imageRect.minX + offset,
                        y: imageRect.maxY
                    ))
                grid.move(
                    to: NSPoint(
                        x: imageRect.minX,
                        y: imageRect.minY + offset
                    ))
                grid.line(
                    to: NSPoint(
                        x: imageRect.maxX,
                        y: imageRect.minY + offset
                    ))
            }
            NSColor.white.withAlphaComponent(0.25).setStroke()
            grid.lineWidth = 0.5
            grid.stroke()
            let reticle = NSRect(
                x: imageRect.minX + CGFloat(sample.pixelX - sample.cropX) * zoom,
                y: imageRect.maxY - CGFloat(sample.pixelY - sample.cropY + 1) * zoom,
                width: zoom,
                height: zoom
            )
            let crosshair = NSBezierPath(rect: reticle)
            NSColor.black.setStroke()
            crosshair.lineWidth = 3
            crosshair.stroke()
            NSColor.systemRed.setStroke()
            crosshair.lineWidth = 1.5
            crosshair.stroke()
        } else {
            let text = magnifierUnavailable ? "放大镜暂不可用" : "正在读取像素…"
            (text as NSString).draw(
                at: NSPoint(
                    x: imageRect.minX + 15,
                    y: imageRect.midY - 6
                ),
                withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white])
        }
        let xPixel = Int((point.x * pixelScale).rounded())
        let yPixel = Int(((bounds.height - point.y) * pixelScale).rounded())
        let label = "X \(xPixel)   Y \(yPixel) px\n方向键 1px · ⇧ 10px"
        (label as NSString).draw(
            at: NSPoint(
                x: frame.minX + 10,
                y: frame.minY + 7
            ),
            withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.white,
            ])
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
        let point = convert(event.locationInWindow, from: nil)
        if mode == .region {
            pointer = CaptureGeometry.snappedPoint(point, in: bounds, scale: pixelScale)
            if let pointer {
                magnifier.update(at: pointer)
            }
        } else if mode == .window {
            highlighted = windows.first {
                localRect($0.frame).contains(point)
            }
        }
        needsDisplay = true
    }

    /// 业务作用: 鼠标进入选择层时立即显示其下的窗口或像素位置，不等待额外移动。
    /// 参数说明:
    /// - event: 当前跟踪区域的进入事件。
    /// 返回: 新显示的选择层具有与当前鼠标一致的高亮。
    override func mouseEntered(with event: NSEvent) {
        mouseMoved(with: event)
    }

    /// 业务作用: 鼠标离开选择层后暂停像素读取，不在工具栏或其他显示器上留下放大镜。
    /// 参数说明:
    /// - event: 当前跟踪区域的离开事件。
    /// 返回: 当前放大镜消失，重新进入后由鼠标位置恢复。
    override func mouseExited(with event: NSEvent) {
        pointer = nil
        needsDisplay = true
    }

    /// 业务作用: 选定屏幕或窗口，或开始区域的创建与调整，所有模式均等待独立的录制动作。
    /// 参数说明:
    /// - event: 用户主动点击事件。
    /// 返回: 屏幕和窗口模式只发布所选来源，区域模式等待拖动完成；重复点击不开始录制。
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        origin = CaptureGeometry.snappedPoint(
            convert(event.locationInWindow, from: nil), in: bounds, scale: pixelScale)
        pointer = origin
        if mode == .display {
            onChange?(nil, nil)
            return
        }
        if mode == .window {
            mouseMoved(with: event)
            if let highlighted {
                onChange?(nil, highlighted)
            }
            return
        }
        beginRegionDrag(at: origin, existingOnly: false)
    }

    /// 业务作用: 开始绘制新区域或调整既有边框，保持选区内外的桌面操作范围不变。
    /// 参数说明:
    /// - point: 当前显示器局部坐标中的拖动起点。
    /// - existingOnly: 是否仅允许移动或调整既有区域。
    /// 返回: 暂停录制入口；已选定区域只通过选区局部输入窗口接收本次拖动。
    func beginRegionDrag(at point: NSPoint, existingOnly: Bool) {
        guard mode == .region, !existingOnly || region != nil else {
            return
        }
        startMagnifier()
        origin = CaptureGeometry.snappedPoint(point, in: bounds, scale: pixelScale)
        pointer = origin
        magnifier.update(at: origin)
        original = region ?? .zero
        isDraggingRegion = true
        onInvalidate?()
        handle = -1
        if let region {
            handle =
                handles(region).firstIndex {
                    hypot($0.x - origin.x, $0.y - origin.y) <= 12
                }
                ?? (existingOnly || region.contains(origin) ? 8 : -1)
        }
        if handle == -1 {
            region = NSRect(
                origin: origin,
                size: .zero
            )
        }
        needsDisplay = true
        onRegionUpdate?()
    }

    /// 业务作用: 调整同一显示器内的选区，禁止越界扩大录制范围。
    /// 参数说明:
    /// - event: 区域调整事件。
    /// 返回: 更新可见边界，不启动采集。
    override func mouseDragged(with event: NSEvent) {
        dragRegion(to: convert(event.locationInWindow, from: nil))
    }

    /// 业务作用: 根据当前显示器中的鼠标位置移动或缩放原区域，不将拖动交给桌面应用。
    /// 参数说明:
    /// - point: 由当前输入窗口换算得到的显示器局部位置。
    /// 返回: 更新可见选区和局部输入位置，尚未完成的区域不会用于录制。
    func dragRegion(to point: NSPoint) {
        guard mode == .region, isDraggingRegion else {
            return
        }
        let point = CaptureGeometry.snappedPoint(point, in: bounds, scale: pixelScale)
        pointer = point
        magnifier.update(at: point)
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
        onRegionUpdate?()
    }

    /// 业务作用: 将区域转换为显示器内的顶部原点坐标，交还录制工具栏。
    /// 参数说明:
    /// - event: 用户结束调整事件。
    /// 返回: 合法区域可录制；过小区域仍保持不可开始。
    override func mouseUp(with event: NSEvent) {
        finishRegionDrag()
    }

    /// 业务作用: 结束当前拖动并将全屏选择层改为鼠标穿透，后续保留框内拖动和控制点调整。
    /// 参数说明: 无。
    /// 返回: 有效选区发布后可正常操作框外桌面；调整退化为无效尺寸时保留原有效区域。
    func finishRegionDrag() {
        guard mode == .region, isDraggingRegion else {
            return
        }
        isDraggingRegion = false
        if let region, region.width >= 8, region.height >= 8 {
            isRegionCommitted = true
        } else if isRegionCommitted {
            // 已有区域调整到零尺寸时保留原范围，不能留下不可录制且无法重新抓取的边框。
            region = original
        }
        publishRegion()
        onRegionUpdate?()
        needsDisplay = true
    }

    /// 业务作用: 用户明确重新框选时恢复首次绘制状态，取消旧区域的录制资格。
    /// 参数说明: 无。
    /// 返回: 桌面临时进入框选状态，完成有效拖动后再次恢复鼠标穿透。
    func resetRegionSelection() {
        guard mode == .region else {
            return
        }
        isRegionCommitted = false
        isDraggingRegion = false
        region = nil
        pointer = nil
        stopMagnifier()
        onInvalidate?()
        onRegionUpdate?()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    /// 业务作用: 发布合法的像素对齐选区，同时让辅助功能读出边界和实际像素尺寸。
    /// 参数说明: 无。
    /// 返回: 合法区域恢复录制入口；过小区域不会被当成有效来源。
    private func publishRegion() {
        guard mode == .region, let region, region.width >= 8, region.height >= 8 else {
            return
        }
        setAccessibilityValue(
            "X \(Int((region.minX * pixelScale).rounded()))，Y \(Int(((bounds.height - region.maxY) * pixelScale).rounded()))，宽 \(Int((region.width * pixelScale).rounded())) 像素，高 \(Int((region.height * pixelScale).rounded())) 像素"
        )
        onChange?(
            CGRect(
                x: region.minX,
                y: bounds.height - region.maxY,
                width: region.width,
                height: region.height
            ),
            nil)
        onRegionUpdate?()
    }

    /// 业务作用: 允许用户取消当前选择，不转发取消键到其他应用。
    /// 参数说明:
    /// - event: 当前选择界面的键盘事件。
    /// 返回: Escape 关闭选择层；方向键按物理像素移动，Option 调整右侧及上侧边缘。
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else if mode == .region, var region, [123, 124, 125, 126].contains(event.keyCode) {
            let step: CGFloat = (event.modifierFlags.contains(.shift) ? 10 : 1) / pixelScale
            let dx: CGFloat = event.keyCode == 123 ? -step : (event.keyCode == 124 ? step : 0)
            let dy: CGFloat = event.keyCode == 125 ? -step : (event.keyCode == 126 ? step : 0)
            if event.modifierFlags.contains(.option) {
                region.size.width = max(8, min(bounds.maxX - region.minX, region.width + dx))
                region.size.height = max(8, min(bounds.maxY - region.minY, region.height + dy))
            } else {
                region.origin.x = min(bounds.maxX - region.width, max(0, region.minX + dx))
                region.origin.y = min(bounds.maxY - region.height, max(0, region.minY + dy))
            }
            self.region = region
            publishRegion()
            needsDisplay = true
        } else {
            super.keyDown(with: event)
        }
    }
}
