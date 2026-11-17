import AVKit
import AppKit
import UniformTypeIdentifiers

@MainActor
final class MovieEditorController: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
    NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate
{
    var onChange: (() -> Void)?
    private(set) var hasWork = false
    private(set) var closed = false
    private var clips: [MovieClip] = []
    private var undoHistory: [[MovieClip]] = []
    private var redoHistory: [[MovieClip]] = []
    private var selection = CMTimeRange.zero
    private var suggestion: MovieSeamSuggestion?
    private var operation: Task<Void, Never>?
    private var operationID = UUID()
    private var closing = false
    private var previewingComposition = false
    private var preparedPreview: MoviePreview?
    private var watermarkEditor: MovieWatermarkController?
    private let player = AVPlayer()
    private var timeObserver: Any?
    private let table = NSTableView()
    private let playerView = AVPlayerView()
    private let startField = NSTextField(string: "00:00.000")
    private let endField = NSTextField(string: "00:00.000")
    private let startSlider = NSSlider()
    private let endSlider = NSSlider()
    private let sourceLabel = NSTextField(labelWithString: "添加视频开始剪辑")
    private let playheadLabel = NSTextField(labelWithString: "播放位置 00:00.000")
    private let summaryLabel = NSTextField(wrappingLabelWithString: "按列表顺序拼接 · 导出保留源帧率")
    private let statusLabel = NSTextField(wrappingLabelWithString: "选择片段，标记起止位置，再保留或删除选区。")
    private let seamLabel = NSTextField(wrappingLabelWithString: "选择第二段或后续片段，可与上一段自动对齐。")
    private let leftImage = NSImageView()
    private let rightImage = NSImageView()
    private let progress = NSProgressIndicator()
    private let audioAdjustment = NSPopUpButton()
    private let audioMultiplier = NSTextField(string: "4")
    private var controls: [NSControl] = []
    private var undoButton: NSButton!
    private var redoButton: NSButton!
    private var matchButton: NSButton!
    private var applyButton: NSButton!
    private var seamPreviewButton: NSButton!
    private var cancelButton: NSButton!
    private var exportButton: NSButton!

    /// 业务作用: 建立独立剪辑窗口，编辑范围与录制会话互不修改。
    /// 参数说明: 无。
    /// 返回: 提供片段列表、原生播放、非破坏性剪切与新文件导出入口。
    init() {
        let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: min(1120, screen.width - 80),
                height: min(820, screen.height - 80)
            ),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.title = "剪辑与拼接"
        window.minSize = NSSize(
            width: 940,
            height: 730
        )
        window.isReleasedWhenClosed = false
        window.delegate = self
        buildInterface()
        window.center()
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(
                value: 1,
                timescale: 10
            ), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.playheadLabel.stringValue =
                    "\(self?.previewingComposition == true ? "拼接预览" : "播放位置") \(MovieTime.string(time))"
            }
        }
    }

    /// 业务作用: 拒绝从界面归档恢复不完整的剪辑状态。
    /// 参数说明:
    /// - coder: 系统归档解码器。
    /// 返回: 剪辑窗口只由明确的来源与程序化布局创建。
    required init?(coder: NSCoder) {
        nil
    }

    /// 业务作用: 显示剪辑窗口并按需加载来源，不自动导出或改变原文件。
    /// 参数说明:
    /// - urls: 从录后预览或 Finder 打开的来源，可为空。
    /// 返回: 窗口可操作，给定来源在后台读入。
    func present(urls: [URL] = []) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !urls.isEmpty {
            importMovies(urls)
        }
    }

    /// 业务作用: 创建有文本说明的剪辑按钮，统一登记忙碌门禁。
    /// 参数说明:
    /// - title: 用户看到的操作名称。
    /// - action: 当前窗口负责执行的动作。
    /// 返回: 在分析、导出或导入期间自动禁用的原生按钮。
    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(
            title: title,
            target: self,
            action: action
        )
        button.bezelStyle = .rounded
        controls.append(button)
        return button
    }

    /// 业务作用: 构建片段列表、播放区与接缝建议区，保持常用操作直接可见。
    /// 参数说明: 无。
    /// 返回: 不包含帧率重选或隐式画质转换选项。
    private func buildInterface() {
        guard let window else {
            return
        }
        let root = NSView()
        window.contentView = root
        let sidebar = NSStackView()
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 10
        let heading = NSTextField(labelWithString: "片段 · 按列表顺序拼接")
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        sidebar.addArrangedSubview(heading)
        sidebar.addArrangedSubview(button("添加视频…", action: #selector(chooseFiles)))
        sidebar.addArrangedSubview(button("分时段去水印…", action: #selector(editWatermarks)))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clip"))
        column.width = 274
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 56
        table.style = .inset
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(selectClip)
        table.registerForDraggedTypes([.fileURL])
        let clipMenu = NSMenu()
        clipMenu.delegate = self
        clipMenu.autoenablesItems = false
        let clipActions: [(String, Selector)] = [
            ("播放片段", #selector(playSelectedClip)),
            ("上移", #selector(moveClipUp)),
            ("下移", #selector(moveClipDown)),
            ("移除", #selector(removeClip)),
            ("撤销", #selector(undoEdit)),
            ("重做", #selector(redoEdit)),
        ]
        for (index, entry) in clipActions.enumerated() {
            if index == 3 || index == 4 {
                clipMenu.addItem(.separator())
            }
            let item = NSMenuItem(title: entry.0, action: entry.1, keyEquivalent: "")
            item.target = self
            if entry.1 == #selector(removeClip) {
                item.toolTip = "从拼接列表移除此片段，可撤销；原视频文件保留。"
            }
            clipMenu.addItem(item)
        }
        table.menu = clipMenu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addArrangedSubview(scroll)
        let order = NSStackView(views: [
            button("上移", action: #selector(moveClipUp)),
            button("下移", action: #selector(moveClipDown)),
            button("移除", action: #selector(removeClip)),
        ])
        order.spacing = 8
        sidebar.addArrangedSubview(order)
        undoButton = button("撤销", action: #selector(undoEdit))
        undoButton.keyEquivalent = "z"
        undoButton.keyEquivalentModifierMask = [.command]
        redoButton = button("重做", action: #selector(redoEdit))
        redoButton.keyEquivalent = "z"
        redoButton.keyEquivalentModifierMask = [.command, .shift]
        let history = NSStackView(views: [undoButton, redoButton])
        history.spacing = 8
        sidebar.addArrangedSubview(history)
        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        sidebar.addArrangedSubview(summaryLabel)
        let workspace = NSStackView()
        workspace.orientation = .vertical
        workspace.alignment = .leading
        workspace.spacing = 10
        sourceLabel.font = .systemFont(ofSize: 12, weight: .medium)
        workspace.addArrangedSubview(sourceLabel)
        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.videoGravity = .resizeAspect
        workspace.addArrangedSubview(playerView)
        let playback = NSStackView(views: [
            button("当前片段", action: #selector(showSelectedClip)),
            button("◀ 一帧", action: #selector(stepBackward)),
            button("一帧 ▶", action: #selector(stepForward)),
            playheadLabel,
        ])
        playback.spacing = 8
        playheadLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        workspace.addArrangedSubview(playback)
        for field in [startField, endField] {
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: 116).isActive = true
            controls.append(field)
        }
        startField.setAccessibilityLabel("选区起点")
        endField.setAccessibilityLabel("选区终点")
        for slider in [startSlider, endSlider] {
            slider.minValue = 0
            slider.maxValue = 1
            slider.target = self
            controls.append(slider)
            slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        }
        startSlider.action = #selector(startChanged)
        startSlider.setAccessibilityLabel("调整选区起点")
        endSlider.action = #selector(endChanged)
        endSlider.setAccessibilityLabel("调整选区终点")
        let startRow = NSStackView(views: [
            button("设为起点", action: #selector(markStart)), startField, startSlider,
        ])
        let endRow = NSStackView(views: [
            button("设为终点", action: #selector(markEnd)), endField, endSlider,
        ])
        startRow.spacing = 8
        endRow.spacing = 8
        workspace.addArrangedSubview(startRow)
        workspace.addArrangedSubview(endRow)
        let edits = NSStackView(views: [
            button("保留选区", action: #selector(keepSelection)),
            button("删除选区", action: #selector(deleteSelection)),
            button("播放处分割", action: #selector(splitClip)),
            button("预览全部", action: #selector(previewAll)),
        ])
        edits.spacing = 8
        workspace.addArrangedSubview(edits)
        audioAdjustment.addItems(withTitles: [
            "保持原音量", "放大 2 倍", "放大 4 倍", "自动放大（防爆音）", "自定义倍数",
        ])
        audioAdjustment.target = self
        audioAdjustment.action = #selector(audioModeChanged)
        audioAdjustment.setAccessibilityLabel("预览与导出音量")
        audioAdjustment.toolTip = "两倍、四倍和自定义按所选倍数放大，对过高峰值软限幅；自动模式按整片峰值计算增益。预览全部、试听接缝与导出均生效；当前片段播放原声音。"
        audioMultiplier.setAccessibilityLabel("声音放大倍数")
        audioMultiplier.widthAnchor.constraint(equalToConstant: 64).isActive = true
        audioMultiplier.toolTip = "输入 1 到 100 倍，可使用小数。针对当前导入视频的声音放大。"
        controls.append(audioAdjustment)
        controls.append(audioMultiplier)
        let audioRow = NSStackView(views: [
            NSTextField(labelWithString: "预览 / 导出音量"), audioAdjustment,
            audioMultiplier, NSTextField(labelWithString: "倍"),
        ])
        audioRow.spacing = 8
        workspace.addArrangedSubview(audioRow)
        let seamBox = NSBox()
        seamBox.title = "接缝对齐"
        let seamContent = NSStackView()
        seamContent.orientation = .vertical
        seamContent.alignment = .leading
        seamContent.spacing = 8
        seamLabel.font = .systemFont(ofSize: 11)
        seamLabel.maximumNumberOfLines = 3
        seamContent.addArrangedSubview(seamLabel)
        let images = NSStackView(views: [leftImage, rightImage])
        images.spacing = 12
        for image in [leftImage, rightImage] {
            image.imageScaling = .scaleProportionallyUpOrDown
            image.widthAnchor.constraint(equalToConstant: 150).isActive = true
            image.heightAnchor.constraint(equalToConstant: 72).isActive = true
        }
        seamContent.addArrangedSubview(images)
        matchButton = button("与上一段自动对齐", action: #selector(matchSeam))
        seamPreviewButton = button("试听接缝", action: #selector(previewSeam))
        applyButton = button("采用建议", action: #selector(applySuggestion))
        let seamActions = NSStackView(views: [matchButton, seamPreviewButton, applyButton])
        seamActions.spacing = 8
        seamContent.addArrangedSubview(seamActions)
        seamBox.contentView = seamContent
        workspace.addArrangedSubview(seamBox)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        workspace.addArrangedSubview(statusLabel)
        let footer = NSStackView()
        footer.spacing = 10
        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 1
        progress.isIndeterminate = false
        progress.isHidden = true
        cancelButton = NSButton(
            title: "取消操作",
            target: self,
            action: #selector(cancelWork)
        )
        cancelButton.isHidden = true
        exportButton = button("导出新视频…", action: #selector(exportMovie))
        exportButton.keyEquivalent = "s"
        exportButton.keyEquivalentModifierMask = [.command]
        footer.addArrangedSubview(progress)
        footer.addArrangedSubview(cancelButton)
        footer.addArrangedSubview(exportButton)
        workspace.addArrangedSubview(footer)
        for view in [sidebar, workspace] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            sidebar.widthAnchor.constraint(equalToConstant: 282),
            workspace.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 16),
            workspace.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            workspace.topAnchor.constraint(equalTo: sidebar.topAnchor),
            workspace.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: sidebar.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 230),
            summaryLabel.widthAnchor.constraint(equalTo: sidebar.widthAnchor),
            playerView.widthAnchor.constraint(equalTo: workspace.widthAnchor),
            playerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 190),
            startRow.widthAnchor.constraint(equalTo: workspace.widthAnchor),
            endRow.widthAnchor.constraint(equalTo: workspace.widthAnchor),
            seamBox.widthAnchor.constraint(equalTo: workspace.widthAnchor),
            seamBox.heightAnchor.constraint(equalToConstant: 160),
            statusLabel.widthAnchor.constraint(equalTo: workspace.widthAnchor),
            footer.widthAnchor.constraint(equalTo: workspace.widthAnchor),
            progress.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        refreshControls()
    }

    /// 业务作用: 通过系统文件选择器添加多个本地视频，不要求从新录制开始。
    /// 参数说明: 无。
    /// 返回: 确认后按选择顺序追加片段，取消保留当前计划。
    @objc func chooseFiles() {
        guard !hasWork, let window else {
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "添加视频"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else {
                return
            }
            self?.importMovies(panel.urls)
        }
    }

    /// 业务作用: 在后台加载一批来源，全部有效后一次追加，失败不改变已有片段。
    /// 参数说明:
    /// - urls: 用户选择或拖入的文件。
    /// 返回: 追加操作可撤销，原视频不发生写入。
    private func importMovies(_ urls: [URL]) {
        guard !hasWork, !urls.isEmpty else {
            return
        }
        beginWork("正在读取视频…")
        operation = Task(priority: .utility) { [weak self] in
            guard let self else {
                return
            }
            defer {
                finishWork()
            }
            do {
                var additions: [MovieClip] = []
                for (index, url) in urls.enumerated() {
                    try Task.checkCancellation()
                    let source = try await MovieSource.open(url)
                    additions.append(MovieClip(source: source))
                    progress.doubleValue = Double(index + 1) / Double(urls.count)
                }
                try Task.checkCancellation()
                commit(clips + additions, selecting: clips.count + additions.count - 1)
                statusLabel.stringValue = "已添加 \(additions.count) 段视频。按列表顺序拼接，原文件不变。"
            } catch {
                report(error)
            }
        }
    }

    /// 业务作用: 提供片段列表的当前条目数量。
    /// 参数说明:
    /// - tableView: 当前剪辑列表。
    /// 返回: 仅包含仍在计划中的片段数量。
    func numberOfRows(in tableView: NSTableView) -> Int {
        clips.count
    }

    /// 业务作用: 显示每个片段的来源、保留范围和原始帧率，便于检查顺序。
    /// 参数说明:
    /// - tableView: 当前片段列表。
    /// - tableColumn: 文件信息列。
    /// - row: 片段序号。
    /// 返回: 原生可访问的列表单元格，不加载视频帧。
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard clips.indices.contains(row) else {
            return nil
        }
        let clip = clips[row]
        let cell = NSTableCellView()
        let title = NSTextField(labelWithString: "\(row + 1). \(clip.source.url.lastPathComponent)")
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        title.frame = NSRect(
            x: 6,
            y: 30,
            width: 252,
            height: 18
        )
        let detail = NSTextField(
            labelWithString:
                "\(MovieTime.string(clip.range.start)) – \(MovieTime.string(clip.range.end))\n\(clip.source.frameRateDescription)"
        )
        detail.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.frame = NSRect(
            x: 6,
            y: 2,
            width: 252,
            height: 29
        )
        cell.addSubview(title)
        cell.addSubview(detail)
        cell.textField = title
        return cell
    }

    /// 业务作用: 在键盘或鼠标选择片段后恢复对应来源预览。
    /// 参数说明:
    /// - notification: 片段列表的选择变化。
    /// 返回: 切换不改变剪辑范围或其他片段。
    func tableViewSelectionDidChange(_ notification: Notification) {
        selectClip()
    }

    /// 业务作用: 让右键或双指菜单作用于实际点击的片段，复用底部移除按钮的可撤销行为。
    /// 参数说明:
    /// - menu: 片段列表即将显示的上下文菜单。
    /// 返回: 有效行成为当前选中片段，各项操作按边界启用；空白区域或任务进行期间不改变计划。
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === table.menu else {
            return
        }
        let row = table.clickedRow
        let hasTarget = !hasWork && clips.indices.contains(row)
        for item in menu.items where !item.isSeparatorItem {
            switch item.action {
            case #selector(moveClipUp):
                item.isEnabled = hasTarget && row > 0
            case #selector(moveClipDown):
                item.isEnabled = hasTarget && row + 1 < clips.count
            case #selector(undoEdit):
                item.isEnabled = !hasWork && !undoHistory.isEmpty
            case #selector(redoEdit):
                item.isEnabled = !hasWork && !redoHistory.isEmpty
            default:
                item.isEnabled = hasTarget
            }
        }
        // 空白处不能沿用旧选中行，忙碌期间也不能改变已冻结的播放或导出计划。
        guard hasTarget else {
            return
        }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    /// 业务作用: 接受 Finder 拖入的本地文件，拒绝忙碌期间改变导出计划。
    /// 参数说明:
    /// - tableView: 接收拖入的片段列表。
    /// - info: 系统拖放内容。
    /// - row: 拖入位置。
    /// - dropOperation: 系统建议的插入方式。
    /// 返回: 可以导入本地文件时只允许复制来源引用。
    func tableView(
        _ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        !hasWork
            && info.draggingPasteboard.canReadObject(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            ? .copy : []
    }

    /// 业务作用: 将已确认的文件拖入转换为非破坏性导入操作。
    /// 参数说明:
    /// - tableView: 当前片段列表。
    /// - info: 包含本地文件 URL 的拖放数据。
    /// - row: 系统建议的落点。
    /// - dropOperation: 系统的落点类型。
    /// 返回: 成功发起导入时为真，来源文件不移动。
    func tableView(
        _ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard !hasWork,
            let urls = info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty
        else {
            return false
        }
        importMovies(urls)
        return true
    }

    private var selectedIndex: Int? {
        clips.indices.contains(table.selectedRow) ? table.selectedRow : nil
    }

    /// 业务作用: 显示当前片段的来源与保留范围，供标记和逐帧查看。
    /// 参数说明: 无。
    /// 返回: 停止之前的预览，播放位置回到当前片段起点。
    @objc private func selectClip() {
        guard !hasWork, let index = selectedIndex else {
            refreshControls()
            return
        }
        let clip = clips[index]
        selection = clip.range
        player.pause()
        previewingComposition = false
        let item = AVPlayerItem(asset: clip.source.asset)
        item.reversePlaybackEndTime = clip.range.start
        item.forwardPlaybackEndTime = clip.range.end
        player.replaceCurrentItem(with: item)
        preparedPreview = nil
        player.seek(to: clip.range.start, toleranceBefore: .zero, toleranceAfter: .zero)
        sourceLabel.stringValue =
            "\(clip.source.url.lastPathComponent) · \(Int(clip.source.info.size.width)) × \(Int(clip.source.info.size.height)) · \(clip.source.frameRateDescription)"
            + (clip.watermarks.isEmpty ? "" : " · \(clip.watermarks.count) 个水印时段")
        for slider in [startSlider, endSlider] {
            slider.minValue = clip.range.start.seconds
            slider.maxValue = clip.range.end.seconds
        }
        updateSelectionFields()
        clearSuggestion()
        refreshControls()
    }

    /// 业务作用: 从拼接预览返回当前来源，避免把合成时间误当作来源剪切时间。
    /// 参数说明: 无。
    /// 返回: 恢复来源预览与片段范围。
    @objc private func showSelectedClip() {
        selectClip()
    }

    /// 业务作用: 从上下文菜单播放实际选中的来源片段，沿用当前片段的保留范围。
    /// 参数说明: 无。
    /// 返回: 空闲且存在选中片段时开始原声音播放，不改变拼接计划。
    @objc private func playSelectedClip() {
        guard !hasWork, selectedIndex != nil else {
            return
        }
        selectClip()
        player.play()
    }

    /// 业务作用: 同步选区滑块和时间字段，不把标记立即写入片段计划。
    /// 参数说明: 无。
    /// 返回: 用户可以继续预览，再明确选择保留或删除选区。
    private func updateSelectionFields() {
        startField.stringValue = MovieTime.string(selection.start)
        endField.stringValue = MovieTime.string(selection.end)
        startSlider.doubleValue = selection.start.seconds
        endSlider.doubleValue = selection.end.seconds
    }

    /// 业务作用: 验证并更新待操作的选区，拒绝空范围与片段外的时间。
    /// 参数说明:
    /// - start: 来源时间线上的起点。
    /// - end: 来源时间线上的终点。
    /// - seek: 是否定位播放位置以查看边界。
    /// 返回: 有效标记按来源末端精度进入界面，非法输入保留原标记并说明原因。
    private func setSelection(start: CMTime, end: CMTime, seek: CMTime? = nil) {
        guard let index = selectedIndex, !hasWork else {
            return
        }
        let clip = clips[index]
        let start = max(clip.range.start, start)
        let end = min(clip.range.end, end)
        guard start.isNumeric, end.isNumeric, end > start else {
            statusLabel.stringValue = "终点需要晚于起点，并位于当前片段内。"
            updateSelectionFields()
            return
        }
        if previewingComposition {
            selectClip()
        }
        do {
            selection = try MovieTime.selectionRange(start: start, end: end, within: clip.source.info.bounds)
        } catch {
            report(error)
            updateSelectionFields()
            return
        }
        if let seek {
            player.pause()
            player.seek(to: seek, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        updateSelectionFields()
    }

    /// 业务作用: 将播放位置标为选区开始，供删除前导内容或截取片段。
    /// 参数说明: 无。
    /// 返回: 仅更新标记，不修改来源或计划。
    @objc private func markStart() {
        guard !previewingComposition else {
            selectClip()
            return
        }
        setSelection(start: player.currentTime(), end: selection.end)
    }

    /// 业务作用: 将播放位置标为选区结束，供删除末尾内容或截取片段。
    /// 参数说明: 无。
    /// 返回: 仅更新标记，不修改来源或计划。
    @objc private func markEnd() {
        guard !previewingComposition else {
            selectClip()
            return
        }
        setSelection(start: selection.start, end: player.currentTime())
    }

    /// 业务作用: 拖动起点滑块时定位相应画面以便检查边界。
    /// 参数说明: 无。
    /// 返回: 选区仍需用户执行保留或删除才进入计划。
    @objc private func startChanged() {
        let time = CMTime(
            seconds: startSlider.doubleValue,
            preferredTimescale: 48_000
        )
        setSelection(start: time, end: selection.end, seek: time)
    }

    /// 业务作用: 拖动终点滑块时定位相应画面以便检查边界。
    /// 参数说明: 无。
    /// 返回: 选区仍需用户执行保留或删除才进入计划。
    @objc private func endChanged() {
        let time = CMTime(
            seconds: endSlider.doubleValue,
            preferredTimescale: 48_000
        )
        setSelection(start: selection.start, end: time, seek: time)
    }

    /// 业务作用: 接受手动输入的剪切时间，并在非法格式时恢复已有标记。
    /// 参数说明:
    /// - notification: 起止时间字段结束编辑的通知。
    /// 返回: 有效输入更新选区，导出帧率与来源保持不变。
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let start = MovieTime.parse(startField.stringValue),
            let end = MovieTime.parse(endField.stringValue)
        else {
            statusLabel.stringValue = "请输入秒数、分:秒或时:分:秒，可包含小数秒。"
            updateSelectionFields()
            return
        }
        setSelection(start: start, end: end)
    }

    /// 业务作用: 在原生播放器中向后查看一帧，不重新计算来源帧率。
    /// 参数说明: 无。
    /// 返回: 播放暂停并移动到前一幅实际画面。
    @objc private func stepBackward() {
        player.pause()
        player.currentItem?.step(byCount: -1)
    }

    /// 业务作用: 在原生播放器中向前查看一帧，不插入或重采样画面。
    /// 参数说明: 无。
    /// 返回: 播放暂停并移动到下一幅实际画面。
    @objc private func stepForward() {
        player.pause()
        player.currentItem?.step(byCount: 1)
    }

    /// 业务作用: 提交一个可撤销的片段计划，清除不再适用的接缝建议。
    /// 参数说明:
    /// - next: 下一份有序保留范围。
    /// - index: 提交后希望选中的片段。
    /// 返回: 原计划进入有限撤销历史，来源文件不写入。
    private func commit(_ next: [MovieClip], selecting index: Int) {
        undoHistory.append(clips)
        if undoHistory.count > 100 {
            undoHistory.removeFirst()
        }
        redoHistory.removeAll()
        clips = next
        reloadPlan(selecting: index)
    }

    /// 业务作用: 重建列表与总时长，选择变化后恢复正确的来源预览。
    /// 参数说明:
    /// - index: 期望选中的片段序号，超界时限制到现有列表。
    /// 返回: 空计划释放播放器，非空计划显示对应来源。
    private func reloadPlan(selecting index: Int) {
        table.reloadData()
        clearSuggestion()
        let total = clips.reduce(CMTime.zero) { $0 + $1.range.duration }
        let bytes = clips.reduce(0.0) { $0 + $1.estimatedBytes }
        let inpainting = !MovieWatermarkProcessor.intervals(clips).isEmpty
        summaryLabel.stringValue =
            "\(clips.count) 个片段 · 总时长 \(MovieTime.string(total))\n"
            + (inpainting
                ? "画面补全 · HEVC 重编码 · 保留帧时序"
                : "预计约 \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) · 保留源帧率")
        if clips.isEmpty {
            player.pause()
            player.replaceCurrentItem(with: nil)
            preparedPreview = nil
            table.deselectAll(nil)
            sourceLabel.stringValue = "添加视频开始剪辑"
        } else {
            table.selectRowIndexes(
                IndexSet(integer: min(max(0, index), clips.count - 1)), byExtendingSelection: false)
            if !hasWork {
                selectClip()
            }
        }
        refreshControls()
    }

    /// 业务作用: 把当前片段缩为已标记范围，保留操作可撤销。
    /// 参数说明: 无。
    /// 返回: 计划保留选区，来源文件不修改。
    @objc private func keepSelection() {
        guard !hasWork, let index = selectedIndex else {
            return
        }
        var next = clips
        next[index].range = selection
        commit(next, selecting: index)
    }

    /// 业务作用: 删除当前标记范围，可从视频中间剪掉一段。
    /// 参数说明: 无。
    /// 返回: 选区前后成为相邻片段，操作可撤销。
    @objc private func deleteSelection() {
        guard !hasWork, let index = selectedIndex else {
            return
        }
        do {
            let remainder = try clips[index].removing(selection)
            var next = clips
            next.replaceSubrange(index...index, with: remainder)
            commit(next, selecting: index)
        } catch {
            report(error)
        }
    }

    /// 业务作用: 在当前来源播放位置分割片段，便于独立删除或重新排序。
    /// 参数说明: 无。
    /// 返回: 原范围分为连续两段，未改变源帧时序。
    @objc private func splitClip() {
        guard !hasWork, !previewingComposition, let index = selectedIndex else {
            return
        }
        do {
            var next = clips
            next.replaceSubrange(index...index, with: try clips[index].split(at: player.currentTime()))
            commit(next, selecting: index + 1)
        } catch {
            report(error)
        }
    }

    /// 业务作用: 将当前片段向前移动一位，明确决定拼接顺序。
    /// 参数说明: 无。
    /// 返回: 已在首位时不改变计划。
    @objc private func moveClipUp() {
        guard !hasWork, let index = selectedIndex, index > 0 else {
            return
        }
        var next = clips
        next.swapAt(index, index - 1)
        commit(next, selecting: index - 1)
    }

    /// 业务作用: 将当前片段向后移动一位，明确决定拼接顺序。
    /// 参数说明: 无。
    /// 返回: 已在末位时不改变计划。
    @objc private func moveClipDown() {
        guard !hasWork, let index = selectedIndex, index + 1 < clips.count else {
            return
        }
        var next = clips
        next.swapAt(index, index + 1)
        commit(next, selecting: index + 1)
    }

    /// 业务作用: 从输出计划移除当前片段，不移动或删除原文件。
    /// 参数说明: 无。
    /// 返回: 移除可以撤销，其他片段保留顺序。
    @objc private func removeClip() {
        guard !hasWork, let index = selectedIndex else {
            return
        }
        var next = clips
        next.remove(at: index)
        commit(next, selecting: index)
    }

    /// 业务作用: 恢复上一份编辑计划，允许撤回剪切、去重与排序。
    /// 参数说明: 无。
    /// 返回: 有历史时恢复片段列表，不写入来源文件。
    @objc private func undoEdit() {
        guard !hasWork, let previous = undoHistory.popLast() else {
            return
        }
        redoHistory.append(clips)
        clips = previous
        reloadPlan(selecting: table.selectedRow)
        statusLabel.stringValue = "已撤销上一步编辑。水印设置、剪切范围和片段顺序均以当前计划为准。"
    }

    /// 业务作用: 重做最近撤回的编辑计划。
    /// 参数说明: 无。
    /// 返回: 只有尚未进行新编辑的撤销记录可以重做。
    @objc private func redoEdit() {
        guard !hasWork, let next = redoHistory.popLast() else {
            return
        }
        undoHistory.append(clips)
        clips = next
        reloadPlan(selecting: table.selectedRow)
        statusLabel.stringValue = "已重做上一步编辑。"
    }

    /// 业务作用: 预览当前完整拼接计划，提交导出前检查顺序和声音。
    /// 参数说明: 无。
    /// 返回: 按当前音量设置播放非破坏性的合成，所有源视频保持不变。
    @objc private func previewAll() {
        preview(clips, seam: nil)
    }

    /// 业务作用: 为选中片段打开可拖框的分时段水印设置，将确认结果纳入撤销历史。
    /// 参数说明: 无。
    /// 返回: 确认后更新当前片段；取消或来源选择失效时保留原计划。
    @objc private func editWatermarks() {
        guard !hasWork, watermarkEditor == nil, let index = selectedIndex, window != nil else {
            return
        }
        player.pause()
        let id = clips[index].id
        let editor = MovieWatermarkController(clip: clips[index]) { [weak self] regions in
            guard let self, clips.indices.contains(index), clips[index].id == id else {
                return
            }
            var next = clips
            next[index].watermarks = regions
            commit(next, selecting: index)
            statusLabel.stringValue =
                regions.isEmpty
                ? "当前片段已关闭画面补全。"
                : "已设置 \(regions.count) 个水印时段。点击“预览全部”检查补全画面与声音，再导出。"
        }
        watermarkEditor = editor
        editor.onClose = { [weak self] in
            self?.watermarkEditor = nil
            self?.refreshControls()
            if let self, !closed {
                window?.makeKeyAndOrderFront(nil)
            }
        }
        refreshControls()
        editor.showWindow(nil)
        editor.window?.makeKeyAndOrderFront(nil)
    }

    /// 业务作用: 按当前水印与音量设置播放完整计划或接缝，复用与导出相同的媒体处理。
    /// 参数说明:
    /// - plan: 用于本次预览的片段副本。
    /// - seam: 需要查看的接缝序号，空值表示完整预览。
    /// 返回: 媒体准备完成后播放合成；取消或失败不开始播放，临时媒体由预览生命周期清理。
    private func preview(_ plan: [MovieClip], seam: Int?) {
        guard !hasWork, !plan.isEmpty else {
            return
        }
        let adjustment: MovieAudioAdjustment
        do {
            adjustment = try selectedAudioAdjustment()
        } catch {
            report(error)
            return
        }
        beginWork("正在准备预览…")
        let request = operationID
        operation = Task(priority: .utility) { [weak self] in
            guard let self else {
                return
            }
            defer {
                finishWork(restoreSource: false)
            }
            do {
                let preview: MoviePreview
                if let cached = preparedPreview, cached.matches(plan, adjustment: adjustment) {
                    for clip in plan {
                        try clip.validate()
                    }
                    preview = cached
                } else {
                    preview = try await MoviePreview.prepare(plan, adjustment: adjustment) {
                        [weak self] value, message in
                        Task { @MainActor in
                            guard let self, self.operationID == request, self.hasWork else {
                                return
                            }
                            self.progress.doubleValue = value
                            self.statusLabel.stringValue = message
                        }
                    }
                }
                try Task.checkCancellation()
                let item = AVPlayerItem(asset: preview.asset)
                var start = CMTime.zero
                if let seam, preview.joins.indices.contains(seam) {
                    let join = preview.joins[seam]
                    start = max(
                        .zero,
                        join
                            - CMTime(
                                seconds: 3,
                                preferredTimescale: 600
                            ))
                    item.reversePlaybackEndTime = start
                    item.forwardPlaybackEndTime = min(
                        try await preview.asset.load(.duration),
                        join
                            + CMTime(
                                seconds: 3,
                                preferredTimescale: 600
                            ))
                }
                player.pause()
                previewingComposition = true
                player.replaceCurrentItem(with: item)
                preparedPreview = preview
                await player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
                // 关闭或取消可能发生在异步定位期间；失效的预览不能在清理前重新发声。
                try Task.checkCancellation()
                player.play()
                statusLabel.stringValue =
                    seam == nil
                    ? "正在按当前水印和音量设置预览全部。点击“当前片段”返回来源画面。"
                    : "正在按当前音量试听接缝前后三秒。确认连贯后可采用建议。"
            } catch {
                report(error)
            }
        }
    }

    /// 业务作用: 对当前片段与上一段进行有限边界的自动识别，不立即改动剪辑范围。
    /// 参数说明: 无。
    /// 返回: 可靠建议显示两侧画面与时间，证据不足时保留原计划。
    @objc private func matchSeam() {
        guard !hasWork, let index = selectedIndex, index > 0 else {
            return
        }
        let left = clips[index - 1]
        let right = clips[index]
        clearSuggestion()
        beginWork("正在识别接缝…")
        let request = operationID
        operation = Task(priority: .utility) { [weak self] in
            guard let self else {
                return
            }
            defer {
                finishWork(restoreSource: false)
            }
            do {
                let result = try await MovieSeamMatcher.match(left: left, right: right) {
                    [weak self] value, message in
                    Task { @MainActor in
                        guard let self, self.operationID == request, self.hasWork else {
                            return
                        }
                        self.progress.doubleValue = value
                        self.statusLabel.stringValue = message
                    }
                }
                try Task.checkCancellation()
                suggestion = result
                leftImage.image = NSImage(
                    cgImage: result.leftImage,
                    size: .zero
                )
                rightImage.image = NSImage(
                    cgImage: result.rightImage,
                    size: .zero
                )
                seamLabel.stringValue =
                    "\(result.audioScore == nil ? "画面对应" : "音画对应") · 共同内容约 \(String(format: "%.1f", result.overlap)) 秒。建议前段结束于 \(MovieTime.string(result.leftEnd))，后段从 \(MovieTime.string(result.rightStart)) 开始。"
                statusLabel.stringValue = "已找到接缝建议。先试听，再采用；还可以撤销。"
            } catch {
                report(error)
                seamLabel.stringValue = error is CancellationError ? "识别已取消。" : error.localizedDescription
            }
        }
    }

    /// 业务作用: 试听建议接缝，尚无建议时试听当前相邻片段的原始接点。
    /// 参数说明: 无。
    /// 返回: 只改变预览，不修改实际输出计划。
    @objc private func previewSeam() {
        guard let index = selectedIndex, index > 0 else {
            return
        }
        do {
            preview(try suggestion?.applying(to: clips) ?? clips, seam: index - 1)
        } catch {
            report(error)
        }
    }

    /// 业务作用: 把已试听的接缝建议提交为可撤销的剪辑范围。
    /// 参数说明: 无。
    /// 返回: 两侧仅保留连续内容，原视频仍不改变。
    @objc private func applySuggestion() {
        guard !hasWork, let suggestion, let index = selectedIndex else {
            return
        }
        do {
            commit(try suggestion.applying(to: clips), selecting: index)
            statusLabel.stringValue = "已采用接缝建议，可预览全部或撤销。"
        } catch {
            report(error)
        }
    }

    /// 业务作用: 清除与旧片段范围关联的识别结果，防止过期建议被重复应用。
    /// 参数说明: 无。
    /// 返回: 接缝参考图和采用按钮回到未识别状态。
    private func clearSuggestion() {
        suggestion = nil
        leftImage.image = nil
        rightImage.image = nil
        seamLabel.stringValue = "选择第二段或后续片段，可与上一段自动对齐。"
    }

    /// 业务作用: 选择新输出文件位置，导出保持源帧率与编码的 MOV。
    /// 参数说明: 无。
    /// 返回: 确认后后台导出，取消不改变当前计划。
    @objc private func exportMovie() {
        guard !hasWork, let first = clips.first, let window else {
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.directoryURL = first.source.url.deletingLastPathComponent()
        do {
            panel.nameFieldStringValue = try RecordingLocation.suggestedFileName(
                in: first.source.url.deletingLastPathComponent())
        } catch {
            report(error)
            return
        }
        panel.canCreateDirectories = true
        panel.prompt = "导出新视频"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url else {
                return
            }
            self?.startExport(to: destination)
        }
    }

    /// 业务作用: 对当前计划创建独立导出，完成后提供新文件位置而不覆盖来源。
    /// 参数说明:
    /// - destination: 保存面板确认的新文件位置。
    /// 返回: 完成、取消或失败都会解除忙碌门禁，文件成功发布后才报告完成。
    private func startExport(to destination: URL) {
        let plan = clips
        let adjustment: MovieAudioAdjustment
        do {
            adjustment = try selectedAudioAdjustment()
        } catch {
            report(error)
            return
        }
        let preview = preparedPreview
        beginWork(
            MovieWatermarkProcessor.intervals(plan).isEmpty
                ? "正在导出新视频，保留源帧率和画质…"
                : "正在准备画面补全与新视频导出…")
        let request = operationID
        operation = Task(priority: .utility) { [weak self] in
            guard let self else {
                return
            }
            let scoped = destination.startAccessingSecurityScopedResource()
            defer {
                if scoped {
                    destination.stopAccessingSecurityScopedResource()
                }
                finishWork(restoreSource: false)
            }
            do {
                let url = try await MovieEditExporter.export(
                    plan, to: destination, audioAdjustment: adjustment, preparedPreview: preview,
                    progress: { [weak self] value in
                        Task { @MainActor in
                            guard let self, self.operationID == request, self.hasWork else {
                                return
                            }
                            self.progress.doubleValue = value
                        }
                    },
                    audioProgress: { [weak self] message in
                        Task { @MainActor in
                            guard let self, self.operationID == request, self.hasWork else {
                                return
                            }
                            self.statusLabel.stringValue = message
                        }
                    }
                )
                statusLabel.stringValue = "已导出：\(url.path)"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                report(error)
            }
        }
    }

    /// 业务作用: 为预览与导出读取同一份音量设置，阻止无效自定义倍数进入声音处理。
    /// 参数说明: 无。
    /// 返回: 当前选中的音量模式；自定义值非有限数或不在 1 到 100 倍时抛错。
    private func selectedAudioAdjustment() throws -> MovieAudioAdjustment {
        switch audioAdjustment.indexOfSelectedItem {
        case 1:
            return .double
        case 2:
            return .quadruple
        case 3:
            return .automatic
        case 4:
            guard let value = Float(audioMultiplier.stringValue), value.isFinite,
                (1...100).contains(value)
            else {
                throw RecorderError.message("声音放大倍数需为 1 到 100，可输入小数。")
            }
            return .custom(value)
        default:
            return .original
        }
    }

    /// 业务作用: 在后台任务开始前冻结界面计划，避免导出和编辑相互覆盖。
    /// 参数说明:
    /// - message: 当前操作的用户说明。
    /// 返回: 仅取消操作保留可用，录制会话不受影响。
    private func beginWork(_ message: String) {
        player.pause()
        hasWork = true
        operationID = UUID()
        progress.doubleValue = 0
        progress.isHidden = false
        cancelButton.isHidden = false
        statusLabel.stringValue = message
        refreshControls()
        onChange?()
    }

    /// 业务作用: 在后台任务和临时文件处理结束后恢复编辑入口。
    /// 参数说明:
    /// - restoreSource: 是否恢复当前片段预览，保留拼接预览时为假。
    /// 返回: 迟到进度不能改变新任务，待关闭窗口可安全结束。
    private func finishWork(restoreSource: Bool = true) {
        hasWork = false
        operation = nil
        operationID = UUID()
        progress.isHidden = true
        cancelButton.isHidden = true
        if restoreSource {
            selectClip()
        }
        refreshControls()
        onChange?()
        if closing {
            window?.close()
        }
    }

    /// 业务作用: 取消导入、预览声音准备、识别或导出，让原文件与已发布成品保持完整。
    /// 参数说明: 无。
    /// 返回: 由任务结束回调完成临时文件清理与门禁解除。
    @objc func cancelWork() {
        operation?.cancel()
        if hasWork {
            statusLabel.stringValue = "正在取消并清理临时输出…"
        }
    }

    /// 业务作用: 只在选择自定义声音增益时开放倍数输入，避免将无效字段用于预览或导出。
    /// 参数说明: 无。
    /// 返回: 输入框与当前预览及导出音量模式保持一致。
    @objc private func audioModeChanged() {
        refreshControls()
    }

    /// 业务作用: 按当前计划和任务状态统一更新按钮，阻止过期范围参与剪切。
    /// 参数说明: 无。
    /// 返回: 无片段、无上一段或无建议时对应动作不可用。
    private func refreshControls() {
        let available = !hasWork && watermarkEditor == nil
        for control in controls {
            control.isEnabled = available
        }
        table.isEnabled = available
        undoButton?.isEnabled = available && !undoHistory.isEmpty
        redoButton?.isEnabled = available && !redoHistory.isEmpty
        matchButton?.isEnabled = available && (selectedIndex ?? 0) > 0
        seamPreviewButton?.isEnabled = available && (selectedIndex ?? 0) > 0
        applyButton?.isEnabled = available && suggestion != nil
        exportButton?.isEnabled = available && !clips.isEmpty
        audioMultiplier.isEnabled = available && audioAdjustment.indexOfSelectedItem == 4
        for control in [startField, endField, startSlider, endSlider] as [NSControl] {
            control.isEnabled = available && selectedIndex != nil
        }
    }

    /// 业务作用: 以内联状态报告实际失败，取消操作不作为媒体损坏处理。
    /// 参数说明:
    /// - error: 当前操作返回的原因。
    /// 返回: 编辑计划和原文件均保留，用户可继续调整。
    private func report(_ error: Error) {
        statusLabel.stringValue =
            error is CancellationError ? "操作已取消，原视频和编辑计划保留。" : error.localizedDescription
    }

    /// 业务作用: 关闭期间先取消未完成任务，防止临时输出遗留或迟到发布。
    /// 参数说明:
    /// - sender: 用户请求关闭的剪辑窗口。
    /// 返回: 空闲时立即关闭，忙碌时等待清理完成再关闭。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if hasWork {
            closing = true
            cancelWork()
            return false
        }
        return true
    }

    /// 业务作用: 关闭剪辑界面时释放播放器与时间观察，不让后台预览继续发声。
    /// 参数说明:
    /// - notification: 窗口已经关闭的通知。
    /// 返回: 控制器可由应用释放，原文件继续保留。
    func windowWillClose(_ notification: Notification) {
        closed = true
        watermarkEditor?.close()
        player.pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        player.replaceCurrentItem(with: nil)
        preparedPreview = nil
        onChange?()
    }
}
