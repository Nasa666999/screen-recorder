import AVFoundation
import AppKit

@MainActor
final class MovieWatermarkController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
    NSWindowDelegate
{
    private let clip: MovieClip
    private var regions: [MovieWatermarkRegion]
    private let onApply: ([MovieWatermarkRegion]) -> Void
    private var editing: Int?
    private var frameTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var frameID = UUID()
    private var originalFrame: CGImage?
    private let canvas = MovieWatermarkCanvas()
    private let table = NSTableView()
    private let start = NSTextField()
    private let end = NSTextField()
    private let slider = NSSlider()
    private let position = NSTextField(labelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "在画面上拖框，包含完整水印和少量边缘，再保存生效时段。")
    private var controls: [NSControl] = []
    private var finished = false

    /// 业务作用: 在独立窗口编辑当前片段的水印位置和来源时间，不立即改变剪辑计划。
    /// 参数说明:
    /// - clip: 当前选中的片段与已有补全设置。
    /// - onApply: 用户确认后接收完整设置，并由剪辑窗口保存撤销记录。
    /// 返回: 草稿只保存在窗口内，取消时原计划不变。
    init(clip: MovieClip, onApply: @escaping ([MovieWatermarkRegion]) -> Void) {
        self.clip = clip
        regions = clip.watermarks
        self.onApply = onApply
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let window = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0, width: min(1080, screen.width - 60), height: min(760, screen.height - 60)),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "分时段去水印 · \(clip.source.url.lastPathComponent)"
        window.minSize = NSSize(width: 850, height: 650)
        window.isReleasedWhenClosed = false
        window.delegate = self
        buildInterface()
        newRegion()
    }

    /// 业务作用: 禁止从不含来源访问的归档创建水印编辑窗口。
    /// 参数说明:
    /// - coder: 系统归档解码器。
    /// 返回: 始终拒绝归档初始化。
    required init?(coder: NSCoder) {
        nil
    }

    /// 业务作用: 创建受单帧推理忙碌状态约束的操作按钮。
    /// 参数说明:
    /// - title: 用户看到的操作名称。
    /// - action: 当前控制器的操作入口。
    /// 返回: 已登记可用性管理的按钮。
    private func button(_ title: String, action: Selector) -> NSButton {
        let result = NSButton(title: title, target: self, action: action)
        result.bezelStyle = .rounded
        controls.append(result)
        return result
    }

    /// 业务作用: 组合可缩放框选画面、来源定位和独立时间段列表。
    /// 参数说明: 无。
    /// 返回: 多个时段可用不同框，同时生效的时段可包含多个位置。
    private func buildInterface() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        window?.contentView = root
        let hint = NSTextField(
            wrappingLabelWithString:
                "拖动框选水印，可按时段更换位置；同一时段可保存多个框。时间以来源视频为准，剪切后自动取交集。")
        hint.font = .systemFont(ofSize: 12)
        root.addArrangedSubview(hint)
        canvas.setAccessibilityLabel("水印框选画面")
        canvas.setAccessibilityHelp("按住鼠标左键拖动，框住水印。重新拖动可更换当前框。")
        canvas.onChange = { [weak self] in
            self?.restoreOriginal()
        }
        root.addArrangedSubview(canvas)
        slider.minValue = clip.range.start.seconds
        slider.maxValue = clip.range.end.seconds
        slider.target = self
        slider.action = #selector(scrub)
        slider.isContinuous = true
        slider.setAccessibilityLabel("水印画面播放位置")
        controls.append(slider)
        position.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let locate = NSStackView(views: [position, slider])
        locate.spacing = 12
        root.addArrangedSubview(locate)
        for field in [start, end] {
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            field.widthAnchor.constraint(equalToConstant: 118).isActive = true
            controls.append(field)
        }
        start.setAccessibilityLabel("水印生效起点")
        end.setAccessibilityLabel("水印生效终点")
        let timing = NSStackView(views: [
            NSTextField(labelWithString: "生效"), start, NSTextField(labelWithString: "至"), end,
            button("当前位置为起点", action: #selector(markStart)),
            button("当前位置为终点", action: #selector(markEnd)),
        ])
        timing.spacing = 8
        root.addArrangedSubview(timing)
        let actions = NSStackView(views: [
            button("保存时段", action: #selector(saveRegion)),
            button("新增时段", action: #selector(newRegion)),
            button("移除时段", action: #selector(removeRegion)),
            button("预览当前帧", action: #selector(previewFrame)),
            button("显示原画面", action: #selector(restoreOriginal)),
        ])
        actions.spacing = 8
        root.addArrangedSubview(actions)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("watermark"))
        column.width = 900
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 26
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(selectRegion)
        table.setAccessibilityLabel("水印时段列表")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        root.addArrangedSubview(scroll)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 2
        root.addArrangedSubview(status)
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views: [cancel, button("应用到片段", action: #selector(apply))])
        footer.spacing = 10
        root.addArrangedSubview(footer)
        for view in [hint, canvas, locate, scroll, status] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true
        }
        canvas.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 108).isActive = true
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true
    }

    /// 业务作用: 把输入字段和当前框解析为可执行的补全时段。
    /// 参数说明: 无。
    /// 返回: 完整有效的草稿；未框选或越界时给出明确错误。
    private func draft() throws -> MovieWatermarkRegion {
        guard let rect = canvas.rect, let lower = parsedTime(start.stringValue),
            let upper = parsedTime(end.stringValue)
        else {
            throw RecorderError.message("请先拖框，并填写有效的生效起止时间。")
        }
        let range = try MovieTime.selectionRange(start: lower, end: upper, within: clip.source.info.bounds)
        var result = editing.map { regions[$0] } ?? MovieWatermarkRegion(range: range, rect: rect)
        result.range = range
        result.rect = rect
        try result.validate(within: clip.source.info.bounds)
        return result
    }

    /// 业务作用: 对未改动的时间文本保留来源刻度，避免毫秒显示把合法末端舍入到来源外。
    /// 参数说明:
    /// - text: 生效时间字段的当前内容。
    /// 返回: 匹配现有边界时返回精确值，其它输入按编辑时间格式解析。
    private func parsedTime(_ text: String) -> CMTime? {
        let current = editing.map { [regions[$0].range.start, regions[$0].range.end] } ?? []
        let candidates =
            current + [
                clip.range.start, clip.range.end, clip.source.info.bounds.start, clip.source.info.bounds.end,
            ]
        return candidates.first(where: { MovieTime.string($0) == text }) ?? MovieTime.parse(text)
    }

    /// 业务作用: 保存或更新当前草稿，防止选择同一时段时不断产生重复条目。
    /// 参数说明: 无。
    /// 返回: 有效草稿更新列表，非法草稿不改变已有时段。
    @objc private func saveRegion() {
        do {
            try storeDraft()
            status.stringValue = "时段已保存。水印换位置时点击“新增时段”，再设置时间和拖框。"
        } catch {
            status.stringValue = error.localizedDescription
        }
    }

    /// 业务作用: 将当前草稿写入本窗口的设置副本。
    /// 参数说明: 无。
    /// 返回: 设置列表与选择同步；超过区域预算或输入无效时抛错。
    private func storeDraft() throws {
        let region = try draft()
        if let editing {
            regions[editing] = region
        } else {
            guard regions.count < 64 else {
                throw RecorderError.message("单片段最多保存 64 个水印时段，请移除不再使用的设置。")
            }
            regions.append(region)
            editing = regions.count - 1
        }
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: editing!), byExtendingSelection: false)
    }

    /// 业务作用: 为另一个位置或后续时段建立空白草稿，不改变已保存设置。
    /// 参数说明: 无。
    /// 返回: 默认从上一时段结束处开始，可自行输入其它时间。
    @objc private func newRegion() {
        guard previewTask == nil else {
            return
        }
        let next = regions.last?.range.end ?? clip.range.start
        let lower = next < clip.range.end ? max(next, clip.range.start) : clip.range.start
        editing = nil
        table.deselectAll(nil)
        canvas.rect = nil
        start.stringValue = MovieTime.string(lower)
        end.stringValue = MovieTime.string(clip.range.end)
        // 毫秒文本仅用于显示；未修改的来源末端在解析时恢复为真实边界。
        slider.doubleValue = lower.seconds
        loadFrame()
    }

    /// 业务作用: 选择已有时段并在其起点展示同一位置的框。
    /// 参数说明: 无。
    /// 返回: 字段和画面反映所选设置，重画后可覆盖保存。
    @objc private func selectRegion() {
        guard previewTask == nil, regions.indices.contains(table.selectedRow) else {
            return
        }
        editing = table.selectedRow
        let region = regions[table.selectedRow]
        start.stringValue = MovieTime.string(region.range.start)
        end.stringValue = MovieTime.string(region.range.end)
        canvas.rect = region.rect
        slider.doubleValue = min(
            clip.range.end.seconds, max(clip.range.start.seconds, region.range.start.seconds))
        loadFrame()
    }

    /// 业务作用: 从草稿中移除一个已保存时段。
    /// 参数说明: 无。
    /// 返回: 其它时段保留；最终应用仍可在剪辑窗口撤销。
    @objc private func removeRegion() {
        guard previewTask == nil, let editing else {
            return
        }
        regions.remove(at: editing)
        table.reloadData()
        newRegion()
    }

    /// 业务作用: 使用定位滑块刷新用于框选的来源画面。
    /// 参数说明: 无。
    /// 返回: 旧请求失效，不会覆盖较新的定位结果。
    @objc private func scrub() {
        loadFrame()
    }

    /// 业务作用: 把当前来源位置作为水印生效起点。
    /// 参数说明: 无。
    /// 返回: 仅更新草稿字段。
    @objc private func markStart() {
        start.stringValue = MovieTime.string(CMTime(seconds: slider.doubleValue, preferredTimescale: 48_000))
    }

    /// 业务作用: 把当前来源位置作为水印生效终点。
    /// 参数说明: 无。
    /// 返回: 仅更新草稿字段。
    @objc private func markEnd() {
        end.stringValue = MovieTime.string(CMTime(seconds: slider.doubleValue, preferredTimescale: 48_000))
    }

    /// 业务作用: 异步解码当前画面，保持窗口在拖动定位时可响应。
    /// 参数说明: 无。
    /// 返回: 只接纳最后一次定位的画面，关闭后不再发布图像。
    private func loadFrame() {
        frameTask?.cancel()
        originalFrame = nil
        frameID = UUID()
        let request = frameID
        let time = min(
            clip.range.end - CMTime(value: 1, timescale: 48_000),
            CMTime(seconds: slider.doubleValue, preferredTimescale: 48_000))
        position.stringValue = "来源位置 \(MovieTime.string(time))"
        let source = clip.source
        canvas.isEnabled = false
        frameTask = Task { [weak self] in
            do {
                let generator = AVAssetImageGenerator(asset: source.asset)
                generator.appliesPreferredTrackTransform = true
                let result = try await generator.image(at: time)
                try Task.checkCancellation()
                guard let self, !finished, frameID == request else {
                    return
                }
                originalFrame = result.image
                canvas.image = NSImage(cgImage: result.image, size: .zero)
                canvas.isEnabled = true
            } catch {
                guard let self, !finished, frameID == request, !(error is CancellationError) else {
                    return
                }
                status.stringValue = "画面读取失败：\(error.localizedDescription)"
            }
        }
    }

    /// 业务作用: 用本地模型预览当前帧的所有有效框及正在绘制的框。
    /// 参数说明: 无。
    /// 返回: 推理完成后显示补全画面，不保存视频也不改动原文件。
    @objc private func previewFrame() {
        guard previewTask == nil, let originalFrame else {
            return
        }
        do {
            let pending = try draft()
            let time = min(
                clip.range.end - CMTime(value: 1, timescale: 48_000),
                CMTime(seconds: slider.doubleValue, preferredTimescale: 48_000))
            guard time >= pending.range.start, time < pending.range.end else {
                throw RecorderError.message("当前位置不在当前生效时段内，请先定位到该时段再预览。")
            }
            var active = regions.enumerated().filter {
                $0.offset != editing && time >= $0.element.range.start && time < $0.element.range.end
            }.map { $0.element.rect }
            active.append(pending.rect)
            let rects = active
            setBusy(true)
            status.stringValue = "正在本地补全当前帧…"
            previewTask = Task { [weak self] in
                do {
                    let result = try await MovieWatermarkFrame.render(originalFrame, rects: rects)
                    try Task.checkCancellation()
                    guard let self, !finished else {
                        return
                    }
                    canvas.image = NSImage(cgImage: result, size: .zero)
                    canvas.showsOutline = false
                    status.stringValue = "当前帧补全预览。整段效果请应用后点击“预览全部”；运动纹理可能出现时序变化。"
                } catch {
                    if let self, !finished {
                        status.stringValue =
                            error is CancellationError ? "单帧预览已取消。" : error.localizedDescription
                    }
                }
                guard let self else {
                    return
                }
                previewTask = nil
                setBusy(false)
            }
        } catch {
            status.stringValue = error.localizedDescription
        }
    }

    /// 业务作用: 返回原画面和框线，便于比较重建区域或重新框选。
    /// 参数说明: 无。
    /// 返回: 不修改已保存的水印设置。
    @objc private func restoreOriginal() {
        if let originalFrame {
            canvas.image = NSImage(cgImage: originalFrame, size: .zero)
        }
        canvas.showsOutline = true
    }

    /// 业务作用: 在模型工作期间关闭会改变输入的操作，保留取消出口。
    /// 参数说明:
    /// - busy: 是否正在处理单帧。
    /// 返回: 不允许将旧结果发布为新草稿的预览。
    private func setBusy(_ busy: Bool) {
        controls.forEach { $0.isEnabled = !busy }
        table.isEnabled = !busy
        canvas.isEnabled = !busy
    }

    /// 业务作用: 将本窗口的完整设置交给剪辑计划，并自动保存仍在编辑的有效框。
    /// 参数说明: 无。
    /// 返回: 成功时关闭窗口；字段非法时保留草稿供继续修改。
    @objc private func apply() {
        do {
            if canvas.rect != nil {
                try storeDraft()
            }
            onApply(regions)
            dismiss()
        } catch {
            status.stringValue = error.localizedDescription
        }
    }

    /// 业务作用: 丢弃当前窗口的草稿并终止未完成的单帧工作。
    /// 参数说明: 无。
    /// 返回: 剪辑计划不变。
    @objc private func cancel() {
        dismiss()
    }

    /// 业务作用: 统一结束模态窗口并阻止后台结果再次更新视图。
    /// 参数说明: 无。
    /// 返回: 归还父窗口操作权，原媒体保持不变。
    private func dismiss() {
        finished = true
        frameTask?.cancel()
        previewTask?.cancel()
        if let window, let parent = window.sheetParent {
            parent.endSheet(window)
        }
        window?.orderOut(nil)
    }

    /// 业务作用: 将标题栏关闭转为丢弃草稿，与取消按钮保持一致。
    /// 参数说明:
    /// - sender: 发起关闭的窗口。
    /// 返回: 结束当前 sheet，不触发来源文件操作。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss()
        return false
    }

    /// 业务作用: 为水印列表提供独立时段数。
    /// 参数说明:
    /// - tableView: 当前设置列表。
    /// 返回: 已保存的时段数量。
    func numberOfRows(in tableView: NSTableView) -> Int {
        regions.count
    }

    /// 业务作用: 显示时段边界和水印位置，便于区分多个相近设置。
    /// 参数说明:
    /// - tableView: 当前设置列表。
    /// - tableColumn: 当前显示列。
    /// - row: 需要展示的时段索引。
    /// 返回: 来源时间与画面百分比位置说明。
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let region = regions[row]
        return NSTextField(
            labelWithString:
                "\(row + 1).  \(MovieTime.string(region.range.start)) – \(MovieTime.string(region.range.end))    位置 \(Int(region.rect.minX * 100))%, \(Int(region.rect.minY * 100))%    大小 \(Int(region.rect.width * 100))% × \(Int(region.rect.height * 100))%"
        )
    }
}

enum MovieWatermarkFrame {
    /// 业务作用: 在主线程之外生成单帧补全预览，复用视频使用的像素重建流程。
    /// 参数说明:
    /// - image: 已按来源方向显示的当前帧。
    /// - rects: 左上角为原点的比例框。
    /// 返回: 重建后的完整画面；取消或模型失败时抛错。
    static func render(_ image: CGImage, rects: [CGRect]) async throws -> CGImage {
        try Task.checkCancellation()
        let size = CGSize(width: image.width, height: image.height)
        let context = CIContext(options: [.cacheIntermediates: false])
        let buffer = try MovieInpainter.buffer(width: image.width, height: image.height)
        let bounds = CGRect(origin: .zero, size: size)
        context.render(
            CIImage(cgImage: image), to: buffer, bounds: bounds,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let model = try MovieInpainter()
        let pixels = rects.map {
            MovieWatermarkRegion(range: .zero, rect: $0).pixelRect(size: size, transform: .identity)
        }
        let output = try model.process(buffer, rects: pixels)
        try Task.checkCancellation()
        guard let result = context.createCGImage(CIImage(cvPixelBuffer: output), from: bounds) else {
            throw RecorderError.message("无法显示补全画面。")
        }
        return result
    }
}

@MainActor
final class MovieWatermarkCanvas: NSView {
    var image: NSImage? {
        didSet {
            needsDisplay = true
        }
    }
    var rect: CGRect? {
        didSet {
            needsDisplay = true
        }
    }
    var showsOutline = true {
        didSet {
            needsDisplay = true
        }
    }
    var isEnabled = true
    var onChange: (() -> Void)?
    private var anchor: NSPoint?
    override var isFlipped: Bool { true }

    private var imageRect: CGRect {
        guard let image, image.size.width > 0, image.size.height > 0 else {
            return .zero
        }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width,
            height: size.height)
    }

    /// 业务作用: 绘制等比例来源画面和明确的水印处理边界。
    /// 参数说明:
    /// - dirtyRect: 系统要求刷新的范围。
    /// 返回: 留黑区域不属于可选画面，框线不进入补全视频。
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        image?.draw(
            in: imageRect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        guard showsOutline, let rect else {
            return
        }
        let visible = CGRect(
            x: imageRect.minX + rect.minX * imageRect.width,
            y: imageRect.minY + rect.minY * imageRect.height,
            width: rect.width * imageRect.width, height: rect.height * imageRect.height)
        NSColor.systemOrange.withAlphaComponent(0.18).setFill()
        visible.fill()
        NSColor.white.setStroke()
        let outer = NSBezierPath(rect: visible)
        outer.lineWidth = 3
        outer.stroke()
        NSColor.systemOrange.setStroke()
        outer.lineWidth = 1.5
        outer.stroke()
    }

    /// 业务作用: 仅在真实视频画面内开始一次水印框选。
    /// 参数说明:
    /// - event: 鼠标左键按下事件。
    /// 返回: 留黑区域和忙碌状态不启动框选。
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard isEnabled, imageRect.contains(point) else {
            return
        }
        onChange?()
        anchor = point
    }

    /// 业务作用: 拖动时将框限制在显示画面内并保存比例坐标。
    /// 参数说明:
    /// - event: 当前拖动位置。
    /// 返回: 框的尺寸和位置不受窗口缩放影响。
    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, let anchor else {
            return
        }
        let image = imageRect
        let point = convert(event.locationInWindow, from: nil)
        let x = min(image.maxX, max(image.minX, point.x))
        let y = min(image.maxY, max(image.minY, point.y))
        guard abs(x - anchor.x) >= 2, abs(y - anchor.y) >= 2 else {
            return
        }
        rect = CGRect(
            x: (min(x, anchor.x) - image.minX) / image.width,
            y: (min(y, anchor.y) - image.minY) / image.height,
            width: abs(x - anchor.x) / image.width, height: abs(y - anchor.y) / image.height)
    }

    /// 业务作用: 结束当前拖动，保留有效框供保存或重新绘制。
    /// 参数说明:
    /// - event: 鼠标左键释放事件。
    /// 返回: 释放后移动鼠标不会继续改变区域。
    override func mouseUp(with event: NSEvent) {
        anchor = nil
    }
}
