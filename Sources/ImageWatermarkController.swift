import AppKit
import UniformTypeIdentifiers

@MainActor
final class ImageWatermarkController: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
    NSTableViewDelegate
{
    var onChange: (() -> Void)?
    private(set) var hasWork = false
    private(set) var closed = false
    private var source: ImageWatermarkSource?
    private var regions: [CGRect] = []
    private var undoStates: [[CGRect]] = []
    private var redoStates: [[CGRect]] = []
    private var editing: Int?
    private var result: CGImage?
    private var resultRects: [CGRect] = []
    private var operation: Task<Void, Never>?
    private let canvas = MovieWatermarkCanvas()
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "正在读取图片…")
    private let detail = NSTextField(labelWithString: "拖框包含完整水印和少量边缘，可保存多个框。")
    private var controls: [NSButton] = []
    private let cancelButton = NSButton(title: "取消操作", target: nil, action: nil)

    /// 业务作用: 建立独立图片框选窗口，保留多个水印区域和撤销记录。
    /// 参数说明:
    /// - url: 用户主动选择的静态图片。
    /// 返回: 后台读取来源；尚未另存前，所有编辑仅保存在当前窗口。
    init(url: URL) {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let window = MovieWatermarkWindow(
            contentRect: NSRect(
                x: 0, y: 0, width: min(1080, visible.width - 60), height: min(780, visible.height - 60)),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "图片去水印 · \(url.lastPathComponent)"
        window.minSize = NSSize(width: 800, height: 580)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self
        window.onEscape = { [weak self] in
            guard let self else {
                return
            }
            if self.window?.styleMask.contains(.fullScreen) == true {
                self.window?.toggleFullScreen(nil)
            } else if self.hasWork {
                self.cancelWork()
            }
        }
        buildInterface()
        window.center()
        hasWork = true
        refresh()
        operation = Task(priority: .utility) { [weak self] in
            guard let self else {
                return
            }
            do {
                let opened = try await ImageWatermarkSource.open(url)
                try Task.checkCancellation()
                if !closed {
                    source = opened
                    canvas.mediaSize = CGSize(width: opened.image.width, height: opened.image.height)
                    display(opened.image)
                    detail.stringValue =
                        "\(opened.image.width) × \(opened.image.height) 像素 · 精细补全 · 拖框后可直接预览，多个框可分别保存。"
                    status.stringValue = "原图保持不变，补全结果另存为 PNG。"
                }
            } catch {
                show(error)
            }
            finishWork()
        }
    }

    /// 业务作用: 禁止在缺少来源访问的情况下恢复图片编辑窗口。
    /// 参数说明:
    /// - coder: 系统归档解码器。
    /// 返回: 始终拒绝归档初始化。
    required init?(coder: NSCoder) {
        nil
    }

    /// 业务作用: 显示图片编辑入口，不触发补全或写入文件。
    /// 参数说明: 无。
    /// 返回: 当前窗口成为主窗口。
    func present() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 业务作用: 创建统一受处理状态约束的图片操作按钮。
    /// 参数说明:
    /// - title: 用户看到的操作名称。
    /// - action: 控制器响应入口。
    /// 返回: 登记到可用性管理的按钮。
    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        controls.append(button)
        return button
    }

    /// 业务作用: 组合可最大化的图片画布、多框列表和预览保存操作。
    /// 参数说明: 无。
    /// 返回: 拖框仅改变草稿，模型推理和另存均需用户主动触发。
    private func buildInterface() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        window?.contentView = root
        detail.font = .systemFont(ofSize: 12)
        root.addArrangedSubview(detail)
        canvas.setAccessibilityLabel("图片水印框选画面")
        canvas.setAccessibilityHelp("在图片内拖动框选水印，保存框可处理多个位置。")
        canvas.onChange = { [weak self] in
            self?.result = nil
            self?.showOriginal()
        }
        root.addArrangedSubview(canvas)
        let actions = NSStackView(views: [
            button("新增框", action: #selector(newRegion)),
            button("保存框", action: #selector(saveRegion)),
            button("移除框", action: #selector(removeRegion)),
            button("撤销", action: #selector(undo)),
            button("重做", action: #selector(redo)),
            button("画面最大化", action: #selector(maximize)),
        ])
        actions.spacing = 8
        root.addArrangedSubview(actions)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("region"))
        column.width = 950
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 24
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.action = #selector(selectRegion)
        table.setAccessibilityLabel("图片水印区域列表")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        root.addArrangedSubview(scroll)
        status.font = .systemFont(ofSize: 12)
        status.maximumNumberOfLines = 2
        root.addArrangedSubview(status)
        cancelButton.target = self
        cancelButton.action = #selector(cancelWork)
        let output = NSStackView(views: [
            button("预览补全", action: #selector(preview)),
            button("显示原图", action: #selector(showOriginal)),
            button("另存 PNG…", action: #selector(export)), cancelButton,
        ])
        output.spacing = 10
        root.addArrangedSubview(output)
        for view in [detail, canvas, scroll, status] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true
        }
        canvas.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        canvas.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.heightAnchor.constraint(equalToConstant: 90).isActive = true
    }

    /// 业务作用: 汇总已保存框和当前草稿，使预览与另存使用完全一致的位置。
    /// 参数说明: 无。
    /// 返回: 当前编辑的已保存框被草稿替换，未保存新框只追加一次。
    private func effectiveRects() -> [CGRect] {
        var rects = regions
        if let rect = canvas.rect {
            if let editing {
                rects[editing] = rect
            } else if !rects.contains(rect) {
                rects.append(rect)
            }
        }
        return rects
    }

    /// 业务作用: 记录区域变更并清除不再匹配的补全结果。
    /// 参数说明:
    /// - rects: 新的已保存区域列表。
    /// 返回: 变更可以撤销，原图恢复到框选显示状态。
    private func commit(_ rects: [CGRect]) {
        guard rects != regions else {
            return
        }
        undoStates.append(regions)
        redoStates.removeAll()
        regions = rects
        resetSelection()
    }

    /// 业务作用: 重置区域选择并展示当前已保存的全部框。
    /// 参数说明: 无。
    /// 返回: 不再显示与旧区域对应的补全预览。
    private func resetSelection() {
        editing = nil
        canvas.rect = nil
        canvas.savedRects = regions
        table.reloadData()
        table.deselectAll(nil)
        result = nil
        showOriginal()
        refresh()
    }

    /// 业务作用: 开始一个独立的新区域草稿，保留已有水印框。
    /// 参数说明: 无。
    /// 返回: 下一次拖动不会覆盖已有区域。
    @objc private func newRegion() {
        resetSelection()
    }

    /// 业务作用: 将当前拖框保存到区域列表，选中条目时更新对应区域。
    /// 参数说明: 无。
    /// 返回: 空框不保存，超过区域上限时提示。
    @objc private func saveRegion() {
        guard let rect = canvas.rect else {
            status.stringValue = "请先在图片内拖框。"
            return
        }
        var rects = regions
        if let editing {
            rects[editing] = rect
        } else if rects.count < 64 {
            rects.append(rect)
        } else {
            status.stringValue = "每张图片最多保存 64 个框。"
            return
        }
        commit(rects)
        status.stringValue = "已保存 \(regions.count) 个区域。"
    }

    /// 业务作用: 载入点击条目的框，允许重画后保存替换。
    /// 参数说明: 无。
    /// 返回: 所选框成为橙色草稿，其余框继续显示。
    @objc private func selectRegion() {
        guard !hasWork, regions.indices.contains(table.selectedRow) else {
            return
        }
        editing = table.selectedRow
        canvas.rect = regions[table.selectedRow]
        canvas.savedRects = regions.enumerated().filter { $0.offset != editing }.map(\.element)
        showOriginal()
    }

    /// 业务作用: 移除所选已保存框，未保存草稿仅清空。
    /// 参数说明: 无。
    /// 返回: 已保存区域的移除可撤销。
    @objc private func removeRegion() {
        if let editing {
            var rects = regions
            rects.remove(at: editing)
            commit(rects)
        } else {
            resetSelection()
        }
    }

    /// 业务作用: 恢复上一次已保存区域列表。
    /// 参数说明: 无。
    /// 返回: 当前列表进入重做记录，旧预览失效。
    @objc private func undo() {
        guard let previous = undoStates.popLast() else {
            return
        }
        redoStates.append(regions)
        regions = previous
        resetSelection()
    }

    /// 业务作用: 重新应用最近撤销的区域列表。
    /// 参数说明: 无。
    /// 返回: 当前列表进入撤销记录，旧预览失效。
    @objc private func redo() {
        guard let next = redoStates.popLast() else {
            return
        }
        undoStates.append(regions)
        regions = next
        resetSelection()
    }

    /// 业务作用: 使用系统全屏放大图片框选画面。
    /// 参数说明: 无。
    /// 返回: 比例坐标不随窗口大小变化。
    @objc private func maximize() {
        window?.toggleFullScreen(nil)
    }

    /// 业务作用: 切换为原图以比较补全效果，同时恢复框线。
    /// 参数说明: 无。
    /// 返回: 保留已准备结果供另存复用，不覆盖来源。
    @objc private func showOriginal() {
        if let source {
            display(source.image)
        }
        canvas.showsOutline = true
    }

    /// 业务作用: 按完整像素尺寸更新显示，画布自行按窗口等比例缩放。
    /// 参数说明:
    /// - image: 来源或已补全图片。
    /// 返回: 显示缩放不改变保存尺寸或区域坐标。
    private func display(_ image: CGImage) {
        canvas.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// 业务作用: 生成当前全部水印框的精细补全预览。
    /// 参数说明: 无。
    /// 返回: 后台执行，可取消；结果与另存复用同一张图片。
    @objc private func preview() {
        process(destination: nil)
    }

    /// 业务作用: 让用户选择新的 PNG 路径，再准备并保存当前补全结果。
    /// 参数说明: 无。
    /// 返回: 取消选择不执行推理或写入，已有文件不能覆盖。
    @objc private func export() {
        guard let source, let window else {
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = source.url.deletingPathExtension().lastPathComponent + "-去水印.png"
        panel.directoryURL = source.url.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let destination = panel.url {
                self?.process(destination: destination)
            }
        }
    }

    /// 业务作用: 使用当前区域快照准备预览或另存，在取消和关闭后停止发布。
    /// 参数说明:
    /// - destination: 新 PNG 路径，为空时只生成预览。
    /// 返回: 相同区域复用已准备结果；后台结束后通知应用可安全退出。
    private func process(destination: URL?) {
        guard !hasWork, let source else {
            return
        }
        let rects = effectiveRects()
        guard !rects.isEmpty else {
            status.stringValue = "请先在图片内框选水印。"
            return
        }
        hasWork = true
        status.stringValue = "正在精细补全图片…"
        refresh()
        operation = Task(priority: .utility) { [weak self] in
            guard let self else {
                return
            }
            do {
                let image: CGImage
                if let result, resultRects == rects {
                    image = result
                } else {
                    image = try await ImageWatermarkRenderer.render(source, rects: rects)
                }
                try Task.checkCancellation()
                if let destination {
                    try await ImageWatermarkRenderer.export(source, image: image, to: destination)
                }
                if !closed {
                    result = image
                    resultRects = rects
                    display(image)
                    canvas.showsOutline = false
                    status.stringValue =
                        destination.map { "已另存：\($0.lastPathComponent)" } ?? "补全预览已准备，可显示原图比较或另存 PNG。"
                }
            } catch {
                show(error)
            }
            finishWork()
        }
        onChange?()
    }

    /// 业务作用: 取消本窗口后台处理，保留原始图片和已确认的编辑设置。
    /// 参数说明: 无。
    /// 返回: 实际任务结束后才解除忙碌状态和释放临时输出。
    @objc func cancelWork() {
        operation?.cancel()
    }

    /// 业务作用: 显示当前窗口的处理结果，关闭后的窗口不再接收迟到提示。
    /// 参数说明:
    /// - error: 来源、模型、取消或保存失败。
    /// 返回: 错误只更新说明，不将未完成内容当作成品。
    private func show(_ error: Error) {
        guard !closed else {
            return
        }
        status.stringValue = error is CancellationError ? "操作已取消，原图保持不变。" : error.localizedDescription
    }

    /// 业务作用: 后台工作彻底结束后恢复交互，并通知应用重新核对退出条件。
    /// 参数说明: 无。
    /// 返回: 已关闭的窗口可释放，运行中的窗口重新可编辑。
    private func finishWork() {
        operation = nil
        hasWork = false
        refresh()
        onChange?()
    }

    /// 业务作用: 忙碌期间禁止编辑输入，保留取消入口。
    /// 参数说明: 无。
    /// 返回: 不允许旧区域快照与新编辑交叉保存。
    private func refresh() {
        for control in controls {
            control.isEnabled = source != nil && !hasWork
            if control.action == #selector(undo), undoStates.isEmpty {
                control.isEnabled = false
            } else if control.action == #selector(redo), redoStates.isEmpty {
                control.isEnabled = false
            }
        }
        table.isEnabled = !hasWork
        canvas.isEnabled = source != nil && !hasWork
        cancelButton.isHidden = !hasWork
    }

    /// 业务作用: 关闭时取消未完成推理和保存，不提前释放仍在使用的来源。
    /// 参数说明:
    /// - notification: 窗口关闭事件。
    /// 返回: 应用等待后台工作清理后再释放控制器。
    func windowWillClose(_ notification: Notification) {
        closed = true
        cancelWork()
        onChange?()
    }

    /// 业务作用: 为区域列表提供已保存框数量。
    /// 参数说明:
    /// - tableView: 当前区域列表。
    /// 返回: 不包含尚未保存的拖框草稿。
    func numberOfRows(in tableView: NSTableView) -> Int {
        regions.count
    }

    /// 业务作用: 展示区域在来源图片中的比例位置与大小。
    /// 参数说明:
    /// - tableView: 当前区域列表。
    /// - tableColumn: 列表中的区域说明列。
    /// - row: 待显示的区域序号。
    /// 返回: 来源尺寸变化前可稳定识别的区域说明。
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let rect = regions[row]
        return NSTextField(
            labelWithString:
                "\(row + 1).  位置 \(Int(rect.minX * 100))%, \(Int(rect.minY * 100))%    大小 \(Int(rect.width * 100))% × \(Int(rect.height * 100))%"
        )
    }
}
