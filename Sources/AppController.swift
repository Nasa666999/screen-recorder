import AVFoundation
import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let engine = CaptureEngine()
    private let selection = SelectionController()
    private let recordingIndicator = RecordingStatusIndicator()
    private let recordingBorder = RecordingBorderController()
    private let hotKeys = HotKeys()
    private var options = RecorderOptions.load()
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private let toolbarFrameName = "ScreenRecorderToolbar"
    private let toolbarSize = NSSize(
        width: 496,
        height: 56
    )
    private var modes: ToolbarModeControl!
    private var recordButton: NSButton!
    private var selected: CaptureSelection?
    private var availableSources: SCShareableContent?
    private var sourceRequest: UUID?
    private var artifacts: [ArtifactController] = []
    private var editors: [MovieEditorController] = []
    private var imageEditors: [ImageWatermarkController] = []
    private var observers: [NSObjectProtocol] = []
    private var keyMonitor: Any?
    private var invocationAvailable = false
    private var stopAvailable = true
    private var quitting = false

    /// 业务作用: 建立原生入口和事件路由，恢复来源选择但不开始媒体录制。
    /// 参数说明:
    /// - notification: 应用启动完成通知。
    /// 返回: 用户可主动显示工具栏或开始选择。
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let identifiers = options.audioApplicationBundleIDs {
            let supported = Set(AudioApplicationCatalog.discover(selected: identifiers).map(\.identifier))
            let retained = identifiers.filter { supported.contains($0) }
            if retained != identifiers {
                // 去掉不再提供的来源时保留“仅所选应用”模式；空范围必须要求重新选择，不能扩大为全系统采音。
                options.audioApplicationBundleIDs = retained
                options.save()
            }
        }
        let appMenu = NSMenu()
        let rootItem = NSMenuItem()
        let applicationMenu = NSMenu()
        let editItem = NSMenuItem(
            title: "剪辑与拼接…",
            action: #selector(openEditor),
            keyEquivalent: "o"
        )
        editItem.target = self
        applicationMenu.addItem(editItem)
        let imageItem = applicationMenu.addItem(
            withTitle: "图片去水印…", action: #selector(openImage), keyEquivalent: "")
        imageItem.target = self
        applicationMenu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "退出 Screen Recorder",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        applicationMenu.addItem(quitItem)
        rootItem.submenu = applicationMenu
        appMenu.addItem(rootItem)
        let editMenu = NSMenu(title: "编辑")
        let textActions: [(String, Selector, String)] = [
            ("剪切", #selector(NSText.cut(_:)), "x"),
            ("复制", #selector(NSText.copy(_:)), "c"),
            ("粘贴", #selector(NSText.paste(_:)), "v"),
            ("全选", #selector(NSText.selectAll(_:)), "a"),
        ]
        for (title, action, key) in textActions {
            editMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        appMenu.addItem(editMenuItem)
        NSApp.mainMenu = appMenu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        buildToolbar()
        engine.onState = { [weak self] state in
            self?.update(state)
        }
        engine.onIssue = { [weak self] message in
            self?.issue(message)
        }
        engine.onSaved = { [weak self] url, location in
            self?.saved(url, location: location)
        }
        engine.onReleased = { [weak self] in
            self?.finishQuitIfPossible()
        }
        engine.onExitReadinessChanged = { [weak self] in
            self?.finishQuitIfPossible()
        }
        selection.onInvalidSelection = { [weak self] in
            self?.selected = nil
            self?.recordButton.isEnabled = false
        }
        selection.onSelection = { [weak self] source in
            guard let self else {
                return
            }
            self.selected = source
            self.selection.setSelection(source)
            self.setToolbarHint(source.summary)
            self.recordButton.isEnabled = true
            if self.options.rememberSelection, let rect = source.region {
                self.options.savedDisplayID = source.display.displayID
                self.options.savedRegion = rect
                self.options.save()
            }
        }
        selection.onCancel = { [weak self] in
            self?.closeToolbar()
        }
        hotKeys.onInvoke = { [weak self] in
            self?.showToolbar()
        }
        hotKeys.onStop = { [weak self] in
            self?.engine.stop()
        }
        invocationAvailable = hotKeys.registerInvocation()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else {
                return event
            }
            guard let self,
                self.panel.isVisible || self.engine.state == .preparing || self.engine.state == .starting
            else {
                return event
            }
            Task { @MainActor in
                if self.engine.state == .starting || self.engine.state == .preparing {
                    self.engine.stop()
                } else if case .countingDown = self.engine.state {
                    self.engine.stop()
                } else if self.panel.isVisible {
                    self.closeToolbar()
                }
            }
            return nil
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(
            center.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else {
                        return
                    }
                    // 切换桌面撤销尚未完成的选择，迟到查询不能在新桌面铺开遮罩；已经开始的录制保留。
                    self.sourceRequest = nil
                    self.availableSources = nil
                    self.selection.hide()
                    self.modes.stopHoverHints()
                    if !self.engine.state.isBusy {
                        self.panel.orderOut(nil)
                    }
                }
            })
        for name in [
            NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        if self?.engine.state.isBusy == true {
                            self?.engine.stop(reason: "系统进入睡眠、锁定或切换用户，当前录制已结束。")
                        }
                    }
                })
        }
        observers.append(
            NotificationCenter.default.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main
            ) { [weak self] notification in
                Task { @MainActor in
                    guard let self, let device = notification.object as? AVCaptureDevice,
                        device.uniqueID == self.options.microphoneID, self.engine.state.isBusy
                    else {
                        return
                    }
                    self.engine.stop(reason: "所选麦克风已断开。")
                }
            })
        update(.idle)
        showToolbar()
    }

    /// 业务作用: 构建单行悬浮工具栏，将选择说明放在图标悬停提示中。
    /// 参数说明: 无。
    /// 返回: 三种录制模式共享同一个开始入口。
    private func buildToolbar() {
        panel = SelectionPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: toolbarSize.width,
                height: toolbarSize.height
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let effect = NSVisualEffectView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: toolbarSize.width,
                height: toolbarSize.height
            ))
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        let close = NSButton(
            image: NSImage(
                systemSymbolName: "xmark",
                accessibilityDescription: "退出 Screen Recorder"
            )!,
            target: self,
            action: #selector(quit)
        )
        close.frame = NSRect(
            x: 12,
            y: 12,
            width: 32,
            height: 32
        )
        close.bezelStyle = .texturedRounded
        close.toolTip = "退出 Screen Recorder"
        effect.addSubview(close)
        modes = ToolbarModeControl(
            images: [
                NSImage(
                    systemSymbolName: "display",
                    accessibilityDescription: "录制整个屏幕"
                )!,
                NSImage(
                    systemSymbolName: "macwindow",
                    accessibilityDescription: "录制窗口"
                )!,
                NSImage(
                    systemSymbolName: "viewfinder",
                    accessibilityDescription: "录制所选区域"
                )!,
            ],
            trackingMode: .selectOne,
            target: self,
            action: #selector(modeChanged)
        )
        modes.frame = NSRect(
            x: 54,
            y: 12,
            width: 190,
            height: 32
        )
        modes.segmentStyle = .rounded
        modes.selectedSegment = CaptureMode.allCases.firstIndex(of: options.mode) ?? 0
        for index in 0..<3 {
            modes.setWidth(58, forSegment: index)
        }
        modes.hoverHints = CaptureMode.allCases.map(modeToolTip(for:))
        effect.addSubview(modes)
        let optionsButton = NSPopUpButton(
            frame: NSRect(
                x: 260,
                y: 12,
                width: 98,
                height: 32
            ),
            pullsDown: true
        )
        let menu = NSMenu()
        menu.delegate = self
        optionsButton.menu = menu
        optionsButton.addItem(withTitle: "选项")
        effect.addSubview(optionsButton)
        recordButton = NSButton(
            title: "录制",
            target: self,
            action: #selector(recordClicked)
        )
        recordButton.bezelStyle = .rounded
        recordButton.frame = NSRect(
            x: 374,
            y: 12,
            width: 106,
            height: 32
        )
        effect.addSubview(recordButton)
        panel.contentView = effect
        restoreToolbarPosition()
    }

    /// 业务作用: 为录制模式图标提供按需出现的选择说明与跨桌面行为提示。
    /// 参数说明:
    /// - mode: 鼠标悬停的录制模式。
    /// 返回: 用于图标浮动提示及辅助功能的模式说明，不占用额外工具栏行。
    private func modeToolTip(for mode: CaptureMode) -> String {
        let instruction: String
        switch mode {
        case .display:
            instruction = "单击选择屏幕，再点击录制"
        case .window:
            instruction = "单击选择窗口，再点击录制"
        case .region:
            instruction = "拖动框选区域，再点击录制；框内可拖动移动，控制点调整大小"
        }
        return mode.title + "：" + instruction + "\n" + mode.spaceHint
    }

    /// 业务作用: 将当前来源或会话状态提供给录制按钮的悬停提示与辅助功能。
    /// 参数说明:
    /// - hint: 当前选择、等待阶段或失败后的操作说明。
    /// 返回: 提示保持可查询，不增加常驻文字行或改变录制状态。
    private func setToolbarHint(_ hint: String) {
        recordButton.toolTip = hint
        recordButton.setAccessibilityHelp(hint)
    }

    /// 业务作用: 首次把工具栏放在当前屏幕底部中央，之后恢复用户拖动保存的位置。
    /// 参数说明: 无。
    /// 返回: 非可调整大小的工具栏恢复固定尺寸，并开始自动保存窗口位置。
    private func restoreToolbarPosition() {
        let restored = panel.setFrameUsingName(toolbarFrameName, force: true)
        panel.setContentSize(toolbarSize)
        if !restored {
            let screen =
                NSScreen.screens.first {
                    $0.frame.contains(NSEvent.mouseLocation)
                } ?? NSScreen.screens[0]
            panel.setFrameOrigin(
                NSPoint(
                    x: screen.visibleFrame.midX - panel.frame.width / 2,
                    y: screen.visibleFrame.minY + 40
                ))
        }
        ensureToolbarVisible()
        panel.setFrameAutosaveName(toolbarFrameName)
    }

    /// 业务作用: 在显示器布局或分辨率改变后保持工具栏可见，不把默认原点当成已保存位置。
    /// 参数说明: 无。
    /// 返回: 保留用户位置；仅在越界时限制到有效显示器的安全范围。
    private func ensureToolbarVisible() {
        let screens = NSScreen.screens
        var target =
            screens.first {
                $0.frame.contains(NSEvent.mouseLocation)
            } ?? screens[0]
        var largestArea: CGFloat = 0
        for screen in screens {
            let overlap = screen.visibleFrame.intersection(panel.frame)
            if !overlap.isNull, !overlap.isEmpty {
                let area = overlap.width * overlap.height
                if area > largestArea {
                    largestArea = area
                    target = screen
                }
            }
        }
        let safe = target.visibleFrame.insetBy(dx: 12, dy: 12)
        let maximumX = max(safe.minX, safe.maxX - panel.frame.width)
        let maximumY = max(safe.minY, safe.maxY - panel.frame.height)
        panel.setFrameOrigin(
            NSPoint(
                x: min(maximumX, max(safe.minX, panel.frame.minX)),
                y: min(maximumY, max(safe.minY, panel.frame.minY))
            ))
    }

    /// 业务作用: 将菜单栏左键作为录制入口或停止入口，右键提供明确退出。
    /// 参数说明: 无。
    /// 返回: 重复停止交给会话幂等处理。
    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(
                withTitle: engine.state.isBusy ? "停止录制" : "显示录制工具", action: #selector(primaryAction),
                keyEquivalent: "")
            menu.addItem(withTitle: "重试注册调用快捷键", action: #selector(retryHotKey), keyEquivalent: "")
            menu.addItem(withTitle: "剪辑与拼接…", action: #selector(openEditor), keyEquivalent: "o")
            menu.addItem(withTitle: "图片去水印…", action: #selector(openImage), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出 Screen Recorder", action: #selector(quit), keyEquivalent: "q")
            for item in menu.items {
                item.target = self
            }
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            primaryAction()
        }
    }

    /// 业务作用: 根据采集状态执行主入口，空闲时不触发停止。
    /// 参数说明: 无。
    /// 返回: 忙碌会话停止，空闲会话显示工具栏。
    @objc private func primaryAction() {
        if engine.state.isBusy {
            engine.stop()
        } else {
            showToolbar()
        }
    }

    /// 业务作用: 用户解除系统绑定后重试注册，不主动覆盖系统设置。
    /// 参数说明: 无。
    /// 返回: 明确告知调用快捷键是否可用。
    @objc private func retryHotKey() {
        invocationAvailable = hotKeys.registerInvocation()
        issue(invocationAvailable ? "调用快捷键 ⌘⇧5 已注册。" : "⌘⇧5 仍被占用。请先在系统设置中关闭系统截屏工具的对应绑定；菜单栏仍可使用。")
    }

    /// 业务作用: 响应用户打开请求，恢复当前桌面的来源选择而不自动开始录制。
    /// 参数说明: 无。
    /// 返回: 空闲时可直接选择屏幕、窗口或区域；忙碌时只显示当前会话。
    @objc private func showToolbar() {
        presentToolbar()
        if !engine.state.isBusy, !selection.isVisible, sourceRequest == nil {
            // 关闭工具栏或切换桌面后不能继续使用旧窗口快照，重新打开只恢复选择权限。
            selected = nil
            availableSources = nil
            chooseSource(startDisplayImmediately: false)
        }
    }

    /// 业务作用: 呈现工具栏和当前会话状态，失败返回时不重放来源查询或开始请求。
    /// 参数说明: 无。
    /// 返回: 窗口恢复到已保存的可见位置，采集权限与录制状态保持不变。
    private func presentToolbar() {
        ensureToolbarVisible()
        if engine.state.isBusy {
            setToolbarHint(engine.state == .stopping ? "正在完成保存与释放…" : "当前录制会话 · 点击停止")
            recordButton.title = "停止"
            recordButton.isEnabled = engine.state != .stopping
            panel.makeKeyAndOrderFront(nil)
            modes.startHoverHints()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        panel.makeKeyAndOrderFront(nil)
        modes.startHoverHints()
        NSApp.activate(ignoringOtherApps: true)
        var hint = selected?.summary ?? modeToolTip(for: options.mode)
        recordButton.isEnabled = options.mode == .display || selected != nil
        if !invocationAvailable {
            hint += " · ⌘⇧5 被占用，可用菜单栏打开"
        }
        setToolbarHint(hint)
    }

    /// 业务作用: 关闭本次选择并撤销异步来源查询，不退出应用。
    /// 参数说明: 无。
    /// 返回: 迟到来源结果不能重新显示选择层。
    @objc private func closeToolbar() {
        modes.stopHoverHints()
        panel.saveFrame(usingName: toolbarFrameName)
        sourceRequest = nil
        availableSources = nil
        selection.hide()
        if engine.state.isBusy && engine.state != .recording && engine.state != .stopping {
            engine.stop()
        }
        panel.orderOut(nil)
    }

    /// 业务作用: 切换录制模式后重新选择当前来源，不复用旧窗口标识。
    /// 参数说明: 无。
    /// 返回: 仅在用户主动选择时请求系统画面访问。
    @objc private func modeChanged() {
        guard !engine.state.isBusy else {
            return
        }
        options.mode = CaptureMode.allCases[modes.selectedSegment]
        options.save()
        selected = nil
        availableSources = nil
        chooseSource(startDisplayImmediately: false)
    }

    /// 业务作用: 异步查询来源并建立选择层，查询期间不建立录制流。
    /// 参数说明:
    /// - startDisplayImmediately: 已按录制按钮时是否直接使用工具栏所在屏幕。
    /// 返回: 拒绝授权仍停在选择界面，不自动重放开始请求。
    private func chooseSource(startDisplayImmediately: Bool) {
        // 先撤下旧选择层，避免异步查询期间仍能点击上一次模式的来源。
        selection.hide()
        let request = UUID()
        sourceRequest = request
        recordButton.isEnabled = false
        setToolbarHint("正在获取可录制来源…")
        Task {
            do {
                let content = try await engine.sources()
                guard sourceRequest == request, !engine.state.isBusy else {
                    return
                }
                availableSources = content
                if options.mode == .display, startDisplayImmediately {
                    let screen = panel.screen ?? NSScreen.main!
                    let id =
                        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                        .uint32Value
                    guard
                        let display = content.displays.first(where: {
                            $0.displayID == id
                        })
                    else {
                        throw RecorderError.message("来源显示器不可用。")
                    }
                    selected = CaptureSelection(
                        display: display,
                        window: nil,
                        region: nil
                    )
                    beginRecording()
                } else {
                    guard selection.show(mode: options.mode, content: content, options: options) else {
                        throw RecorderError.message("当前桌面没有可用显示器，请重新打开录制工具。")
                    }
                    if options.mode == .display {
                        let screenID =
                            (panel.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                            as? NSNumber)?.uint32Value
                        if let display = content.displays.first(where: {
                            $0.displayID == screenID
                        }) {
                            selected = CaptureSelection(
                                display: display,
                                window: nil,
                                region: nil
                            )
                            if let selected {
                                selection.setSelection(selected)
                            }
                        }
                    }
                    sourceRequest = nil
                    setToolbarHint(selected?.summary ?? modeToolTip(for: options.mode))
                    recordButton.isEnabled = options.mode == .display || selected != nil
                    panel.orderFrontRegardless()
                }
            } catch {
                guard sourceRequest == request else {
                    return
                }
                sourceRequest = nil
                selection.hide()
                availableSources = nil
                recordButton.isEnabled = true
                setToolbarHint("请检查权限后重新选择")
                issue(RecorderError.describe(error))
            }
        }
    }

    /// 业务作用: 将用户明确的开始或倒计时取消动作转交控制层。
    /// 参数说明: 无。
    /// 返回: 不因连续点击而建立多个采集会话。
    @objc private func recordClicked() {
        if engine.state.isBusy {
            engine.stop()
            return
        }
        if selected == nil {
            chooseSource(startDisplayImmediately: true)
        } else {
            beginRecording()
        }
    }

    /// 业务作用: 冻结用户选择并按需显示确认，隐藏工具界面后准备采集。
    /// 参数说明: 无。
    /// 返回: 默认没有额外确认页；拒绝确认保持当前选择。
    private func beginRecording() {
        guard let selected, !engine.state.isBusy else {
            return
        }
        if options.confirmBeforeRecording {
            let alert = NSAlert()
            alert.messageText = "开始录制？"
            let microphone =
                RecorderOptions.microphones.first {
                    $0.uniqueID == options.microphoneID
                }?.localizedName
                ?? "无"
            alert.informativeText =
                "\(selected.summary)\n\(options.mode.spaceHint)\n画质：\(options.quality.title)，帧率：\(options.frameRate) fps\n系统声音：\(options.systemAudioSummary)\n麦克风：\(microphone)"
            alert.addButton(withTitle: "开始")
            alert.addButton(withTitle: "返回")
            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }
        }
        modes.stopHoverHints()
        sourceRequest = nil
        selection.hide()
        // 提示边框在选择层撤下时接续显示，采集过滤始终排除本应用窗口，边框不写入成品。
        recordingBorder.show(for: selected)
        panel.orderOut(nil)
        engine.start(selection: selected, options: options)
    }

    /// 业务作用: 从单一会话状态更新菜单栏和取消入口，不自行宣告保存成功。
    /// 参数说明:
    /// - state: 控制层发布的当前状态。
    /// 返回: 只有忙碌阶段持有停止热键。
    private func update(_ state: RecordingState) {
        stopAvailable = hotKeys.setStopEnabled(state.isBusy)
        recordingIndicator.update(state, button: statusItem.button, stopAvailable: stopAvailable)
        switch state {
        case .recording:
            recordingBorder.setRecording(true)
        case .idle, .selecting, .stopping, .needsAttention:
            recordingBorder.hide()
        case .preparing, .countingDown, .starting:
            recordingBorder.setRecording(false)
        }
        modes.isEnabled = !state.isBusy
        switch state {
        case .countingDown(let seconds):
            setToolbarHint("\(seconds) 秒后开始录制 · Esc 取消")
            recordButton.title = "\(seconds) 秒 · 取消"
            recordButton.isEnabled = true
            panel.makeKeyAndOrderFront(nil)
        case .starting, .recording, .stopping, .needsAttention:
            panel.orderOut(nil)
        case .selecting:
            recordButton.title = "录制"
            // 启动失败只恢复可操作入口，必须由用户重新选择，不能自动重复权限请求。
            presentToolbar()
        case .idle:
            recordButton.title = "录制"
            recordButton.isEnabled = true
        case .preparing:
            setToolbarHint("正在准备录制…")
            recordButton.isEnabled = false
        }
    }

    /// 业务作用: 为完成文件建立独立录后控制器，新录制不替换旧成品身份。
    /// 参数说明:
    /// - url: 已发布的 MOV 文件。
    /// - location: 成品目录授权。
    /// 返回: 关闭缩略图选项时直接保留文件，不显示成功弹窗。
    private func saved(_ url: URL, location: RecordingLocation) {
        guard options.showThumbnail else {
            return
        }
        let artifact = ArtifactController(
            url: url,
            location: location
        )
        artifact.onChange = { [weak self] in
            self?.artifacts.removeAll {
                !$0.hasVisibleUI && !$0.hasWork
            }
            self?.finishQuitIfPossible()
        }
        artifact.onEdit = { [weak self] url in
            self?.presentEditor(urls: [url])
        }
        artifacts.append(artifact)
        artifact.showThumbnail()
    }

    /// 业务作用: 打开独立剪辑入口，按需选择多个本地视频。
    /// 参数说明: 无。
    /// 返回: 录制空闲时收起选择层，剪辑窗口不改动录制配置。
    @objc private func openEditor() {
        presentEditor(urls: [])
    }

    /// 业务作用: 主动选择静态图片，进入独立的多区域去水印窗口。
    /// 参数说明: 无。
    /// 返回: 取消选择不读取图片，视频录制与剪辑计划不改变。
    @objc private func openImage() {
        guard !quitting else {
            return
        }
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        picker.canChooseFiles = true
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = true
        picker.prompt = "打开图片"
        NSApp.activate(ignoringOtherApps: true)
        if picker.runModal() == .OK {
            for url in picker.urls {
                presentImage(url: url)
            }
        }
    }

    /// 业务作用: 持有图片窗口直到后台处理和保存清理完毕。
    /// 参数说明:
    /// - url: 用户明确选择的图片来源。
    /// 返回: 原图片保持不变，退出应用时等待当前图片工作结束。
    private func presentImage(url: URL) {
        guard !quitting else {
            return
        }
        if !engine.state.isBusy {
            closeToolbar()
        }
        let editor = ImageWatermarkController(url: url)
        editor.onChange = { [weak self] in
            self?.imageEditors.removeAll { $0.closed && !$0.hasWork }
            self?.finishQuitIfPossible()
        }
        imageEditors.append(editor)
        editor.present()
    }

    /// 业务作用: 持有剪辑窗口直到后台工作清理完毕，避免应用退出打断文件发布。
    /// 参数说明:
    /// - urls: 已明确打开的视频来源，空数组表示从窗口内添加。
    /// 返回: 显示新的独立剪辑计划，原文件始终保留。
    private func presentEditor(urls: [URL]) {
        guard !quitting else {
            return
        }
        if !engine.state.isBusy {
            closeToolbar()
        }
        let editor = MovieEditorController()
        editor.onChange = { [weak self] in
            self?.editors.removeAll { $0.closed && !$0.hasWork }
            self?.finishQuitIfPossible()
        }
        editors.append(editor)
        editor.present(urls: urls)
    }

    /// 业务作用: 将 Finder 主动打开的图片和电影分别交给对应编辑窗口。
    /// 参数说明:
    /// - application: 接收文件打开事件的当前应用。
    /// - urls: 用户选择由本应用打开的媒体文件。
    /// 返回: 图片分别编辑，视频按给定顺序进入同一计划，无法读取时由对应界面说明。
    func application(_ application: NSApplication, open urls: [URL]) {
        var movies: [URL] = []
        for url in urls {
            if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
                type.conforms(to: .image)
            {
                presentImage(url: url)
            } else {
                movies.append(url)
            }
        }
        if !movies.isEmpty {
            presentEditor(urls: movies)
        }
    }

    /// 业务作用: 每次展开选项时反映真实设备与已保存设置。
    /// 参数说明:
    /// - menu: 用户正在打开的选项菜单。
    /// 返回: 只在用户主动选择时改变设置。
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "选项", action: nil, keyEquivalent: "")
        let editorItem = menu.addItem(
            withTitle: "剪辑与拼接…", action: #selector(openEditor), keyEquivalent: "o")
        editorItem.target = self
        let imageItem = menu.addItem(withTitle: "图片去水印…", action: #selector(openImage), keyEquivalent: "")
        imageItem.target = self
        menu.addItem(.separator())
        if options.mode == .region, selection.isVisible {
            addOption("重新框选区域", value: "region:reset", checked: false, to: menu)
        }
        if options.mode == .window, let content = availableSources {
            let windows = submenu("选择录制窗口", in: menu)
            for window in content.windows
            where window.isOnScreen && window.windowLayer == 0
                && window.frame.width > 8 && window.frame.height > 8
                && window.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
            {
                let application = window.owningApplication?.applicationName ?? "应用"
                addOption(
                    application + " · " + (window.title ?? "未命名窗口"), value: "window:\(window.windowID)",
                    checked: selected?.window?.windowID == window.windowID, to: windows)
            }
        }
        populateAudioMenu(in: menu)
        let microphone = submenu("麦克风", in: menu)
        addOption("无", value: "mic:", checked: options.microphoneID == nil, to: microphone)
        for device in RecorderOptions.microphones {
            addOption(
                device.localizedName, value: "mic:\(device.uniqueID)",
                checked: options.microphoneID == device.uniqueID, to: microphone)
        }
        let quality = submenu("画质", in: menu)
        for value in Quality.allCases {
            addOption(
                value.title, value: "quality:\(value.rawValue)", checked: options.quality == value,
                to: quality)
        }
        let rate = submenu("帧率", in: menu)
        for value in [30, 60] {
            addOption(
                "\(value) fps", value: "fps:\(value)",
                checked: options.frameRate == value, to: rate)
        }
        let timer = submenu("倒计时", in: menu)
        for value in [0, 5, 10] {
            addOption(
                value == 0 ? "无" : "\(value) 秒", value: "timer:\(value)",
                checked: options.countdown == value, to: timer)
        }
        let format = submenu("格式", in: menu)
        addOption("SDR（标准动态范围）", value: "sdr", checked: !options.hdr, to: format)
        addOption("HDR（高动态范围）", value: "hdr", checked: options.hdr, to: format)
        menu.addItem(.separator())
        addOption("保存到桌面", value: "desktop", checked: options.directoryBookmark == nil, to: menu)
        addOption("其他保存位置…", value: "directory", checked: options.directoryBookmark != nil, to: menu)
        addOption("录制前确认", value: "confirm", checked: options.confirmBeforeRecording, to: menu)
        addOption("显示浮动缩略图", value: "thumbnail", checked: options.showThumbnail, to: menu)
        addOption("记住上次所选内容", value: "remember", checked: options.rememberSelection, to: menu)
        addOption("显示鼠标点按", value: "clicks", checked: options.showMouseClicks, to: menu)
        menu.addItem(.separator())
        addOption("恢复默认设置", value: "reset", checked: false, to: menu)
    }

    /// 业务作用: 保留全系统声音默认值，同时让用户明确限定应用级音频范围。
    /// 参数说明:
    /// - menu: 录制选项所属菜单。
    /// 返回: 按用途列出已安装的浏览器、媒体和通讯应用及运行状态，不改变麦克风及系统播放设备。
    private func populateAudioMenu(in menu: NSMenu) {
        let audio = submenu("系统声音", in: menu)
        addOption(
            "全部系统声音（所有桌面）", value: "audio:all",
            checked: options.systemAudio && options.audioApplicationBundleIDs == nil, to: audio)
        addOption(
            "仅所选应用（所有桌面）", value: "audio:selected",
            checked: options.systemAudio && options.audioApplicationBundleIDs != nil, to: audio)
        addOption("关闭", value: "audio:off", checked: !options.systemAudio, to: audio)
        let applications = submenu("选择应用（可多选）", in: audio)
        let choices = AudioApplicationCatalog.discover(selected: options.audioApplicationBundleIDs ?? [])
        for group in AudioApplicationGroup.allCases {
            let entries = choices.filter { $0.group == group }
            guard !entries.isEmpty else {
                continue
            }
            if !applications.items.isEmpty {
                applications.addItem(.separator())
            }
            let heading = NSMenuItem(title: group.rawValue, action: nil, keyEquivalent: "")
            heading.isEnabled = false
            applications.addItem(heading)
            for entry in entries {
                addOption(
                    entry.name + (entry.isRunning ? "" : "（未运行）"), value: "audio-app:" + entry.identifier,
                    checked: options.audioApplicationBundleIDs?.contains(entry.identifier) == true,
                    to: applications)
            }
        }
        audio.addItem(.separator())
        let scope = NSMenuItem(
            title: "应用过滤包含其它桌面的声音；未运行应用需先打开",
            action: nil,
            keyEquivalent: ""
        )
        scope.isEnabled = false
        audio.addItem(scope)
    }

    /// 业务作用: 建立系统式分组选项，避免增加独立的必经配置页面。
    /// 参数说明:
    /// - title: 当前设置组名称。
    /// - menu: 上级菜单。
    /// 返回: 供具体选项填充的子菜单。
    private func submenu(_ title: String, in menu: NSMenu) -> NSMenu {
        let item = NSMenuItem(
            title: title,
            action: nil,
            keyEquivalent: ""
        )
        let child = NSMenu(title: title)
        item.submenu = child
        menu.addItem(item)
        return child
    }

    /// 业务作用: 把已保存值映射为可见选中态，所有变更经过同一入口。
    /// 参数说明:
    /// - title: 用户可见的设置名称。
    /// - value: 应用内部选项标识。
    /// - checked: 当前是否选中。
    /// - menu: 所属菜单。
    /// 返回: 新选项反映当前设置而不主动采集。
    private func addOption(_ title: String, value: String, checked: Bool, to menu: NSMenu) {
        let item = NSMenuItem(
            title: title,
            action: #selector(optionChosen(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = value
        item.state = checked ? .on : .off
        menu.addItem(item)
    }

    /// 业务作用: 应用用户主动选择的设置，麦克风设备和目录不可静默替换。
    /// 参数说明:
    /// - sender: 用户选择的菜单项。
    /// 返回: 设置持久化，当前录制的冻结快照不改变。
    @objc private func optionChosen(_ sender: NSMenuItem) {
        guard !engine.state.isBusy, let value = sender.representedObject as? String else {
            return
        }
        switch value {
        case "audio:all":
            options.systemAudio = true
            options.audioApplicationBundleIDs = nil
        case "audio:selected":
            options.systemAudio = true
            if options.audioApplicationBundleIDs == nil {
                options.audioApplicationBundleIDs = []
            }
        case "audio:off":
            options.systemAudio = false
        case "confirm":
            options.confirmBeforeRecording.toggle()
        case "thumbnail":
            options.showThumbnail.toggle()
        case "remember":
            options.rememberSelection.toggle()
            if !options.rememberSelection {
                options.savedRegion = nil
                options.savedDisplayID = nil
            }
        case "clicks":
            if options.hdr {
                issue("HDR 与鼠标点按显示不能同时启用，请先选择 SDR。")
                return
            }
            options.showMouseClicks.toggle()
        case "hdr":
            if options.showMouseClicks {
                issue("请先关闭鼠标点按显示，再选择 HDR。")
                return
            }
            options.hdr = true
        case "sdr":
            options.hdr = false
        case "desktop":
            options.directoryBookmark = nil
        case "directory":
            let picker = NSOpenPanel()
            picker.canChooseFiles = false
            picker.canChooseDirectories = true
            picker.allowsMultipleSelection = false
            picker.prompt = "选择保存位置"
            if picker.runModal() == .OK, let url = picker.url {
                do {
                    options.directoryBookmark = try url.bookmarkData(
                        options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                } catch {
                    issue(error.localizedDescription)
                }
            }
        case "region:reset":
            selection.beginRegionSelection()
            setToolbarHint(modeToolTip(for: .region))
        case "reset":
            options = RecorderOptions()
            selected = nil
            selection.hide()
            modes.selectedSegment = 0
        default:
            if value.hasPrefix("window:") {
                // 菜单快照只用于本轮选择；来源失效时要求重选，不能换用其他窗口或整个屏幕。
                guard let identifier = UInt32(value.dropFirst("window:".count)),
                    let content = availableSources,
                    let window = content.windows.first(where: {
                        $0.windowID == identifier
                    }),
                    let display = content.displays.first(where: {
                        $0.frame.intersects(window.frame)
                    })
                else {
                    issue("窗口来源已失效，请重新选择。")
                    return
                }
                selected = CaptureSelection(
                    display: display,
                    window: window,
                    region: nil
                )
                if let selected {
                    selection.setSelection(selected)
                    setToolbarHint(selected.summary)
                    recordButton.isEnabled = true
                }
                return
            } else if value.hasPrefix("audio-app:") {
                let identifier = String(value.dropFirst("audio-app:".count))
                var selected = Set(options.audioApplicationBundleIDs ?? [])
                if selected.contains(identifier) {
                    selected.remove(identifier)
                } else {
                    selected.insert(identifier)
                }
                options.audioApplicationBundleIDs = selected.sorted()
                options.systemAudio = true
            } else if value.hasPrefix("mic:") {
                let id = String(value.dropFirst(4))
                options.microphoneID = id.isEmpty ? nil : id
                if let device = RecorderOptions.microphones.first(where: {
                    $0.uniqueID == id
                }),
                    device.transportType == kAudioDeviceTransportTypeBluetooth
                        || device.transportType == kAudioDeviceTransportTypeBluetoothLE
                {
                    issue("使用蓝牙耳机麦克风可能改变耳机音质，并影响跨设备使用。仅录系统声音时可选择“无”。")
                }
            } else if value.hasPrefix("quality:") {
                options.quality = Quality(rawValue: String(value.dropFirst(8))) ?? .standard
                options.qualityIsExplicit = true
            } else if value.hasPrefix("fps:") {
                options.frameRate = Int(value.dropFirst(4)) == 60 ? 60 : 30
            } else if value.hasPrefix("timer:") {
                options.countdown = Int(value.dropFirst(6)) ?? 0
            }
        }
        options.save()
    }

    /// 业务作用: 报告实际权限、采集或保存失败，提供正常系统设置入口。
    /// 参数说明:
    /// - message: 当前失败或待处理原因。
    /// 返回: 用户确认后仍须主动开始下一次录制。
    private func issue(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Screen Recorder"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        let permissionFailure =
            message.contains("系统设置")
            && (message.contains("屏幕") || message.contains("麦克风"))
        if permissionFailure {
            alert.addButton(withTitle: "打开系统设置")
        }
        if alert.runModal() == .alertSecondButtonReturn {
            let pane =
                message.contains("麦克风") && !message.contains("屏幕")
                ? "Privacy_Microphone" : "Privacy_ScreenCapture"
            NSWorkspace.shared.open(
                URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
        }
    }

    /// 业务作用: 用户再次打开应用时复用工具栏，避免另建采集实例。
    /// 参数说明:
    /// - sender: 当前应用。
    /// - flag: 系统报告的可见窗口状态。
    /// 返回: 已处理重新打开请求。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showToolbar()
        return true
    }

    /// 业务作用: 退出时释放本应用的提示窗口、选择图像和菜单栏动画。
    /// 参数说明:
    /// - notification: 系统即将终止应用的通知。
    /// 返回: 不留下需要用户手动清理的录制提示。
    func applicationWillTerminate(_ notification: Notification) {
        selection.hide()
        recordingBorder.hide()
        recordingIndicator.stop()
    }

    /// 业务作用: 用户主动退出时交给统一的应用终止流程。
    /// 参数说明: 无。
    /// 返回: 录制文件处理不会被直接进程退出打断。
    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// 业务作用: 退出前等待本应用的录制和成品写入，不结束其他系统服务。
    /// 参数说明:
    /// - sender: 请求退出的应用。
    /// 返回: 无写入时退出，否则等完成回调再答复系统。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        panel.saveFrame(usingName: toolbarFrameName)
        if engine.canTerminate
            && !artifacts.contains(where: {
                $0.hasWork
            })
            && !editors.contains(where: { $0.hasWork })
            && !imageEditors.contains(where: { $0.hasWork })
        {
            return .terminateNow
        }
        quitting = true
        if engine.state.isBusy {
            engine.stop()
        }
        // 取消导出后必须等临时文件清理完毕，不能在取消请求发出时直接结束进程。
        for editor in editors where editor.hasWork {
            editor.cancelWork()
        }
        for editor in imageEditors where editor.hasWork {
            editor.cancelWork()
        }
        return .terminateLater
    }

    /// 业务作用: 只在会话和成品写入均结束后兑现待处理退出请求。
    /// 参数说明: 无。
    /// 返回: 写入仍在运行时等待；文件处理结束后允许用户退出，由进程结束归还本应用尚未确认的采集资源。
    private func finishQuitIfPossible() {
        if quitting, engine.canTerminate,
            !artifacts.contains(where: {
                $0.hasWork
            }), !editors.contains(where: { $0.hasWork }), !imageEditors.contains(where: { $0.hasWork })
        {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }
}
