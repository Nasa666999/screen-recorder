import AVFoundation
import AppKit
import ScreenCaptureKit

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
    private var modes: NSSegmentedControl!
    private var recordButton: NSButton!
    private var caption: NSTextField!
    private var selected: CaptureSelection?
    private var availableSources: SCShareableContent?
    private var sourceRequest: UUID?
    private var artifacts: [ArtifactController] = []
    private var observers: [NSObjectProtocol] = []
    private var keyMonitor: Any?
    private var invocationAvailable = false
    private var stopAvailable = true
    private var quitting = false

    /// 业务作用: 建立原生入口和事件路由，启动时不获取画面或声音。
    /// 参数说明:
    /// - notification: 应用启动完成通知。
    /// 返回: 用户可主动显示工具栏或开始选择。
    func applicationDidFinishLaunching(_ notification: Notification) {
        let appMenu = NSMenu()
        let rootItem = NSMenuItem()
        let applicationMenu = NSMenu()
        let quitItem = NSMenuItem(
            title: "退出 Screen Recorder",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        applicationMenu.addItem(quitItem)
        rootItem.submenu = applicationMenu
        appMenu.addItem(rootItem)
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
        selection.onSelection = { [weak self] source, start in
            guard let self else {
                return
            }
            self.selected = source
            self.caption.stringValue = source.summary
            self.recordButton.isEnabled = true
            if self.options.rememberSelection, let rect = source.region {
                self.options.savedDisplayID = source.display.displayID
                self.options.savedRegion = rect
                self.options.save()
            }
            if start {
                self.beginRecording()
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

    /// 业务作用: 构建可拖动的系统式悬浮工具栏，不添加默认确认页。
    /// 参数说明: 无。
    /// 返回: 三种录制模式共享同一个开始入口。
    private func buildToolbar() {
        panel = SelectionPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 496,
                height: 90
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let effect = NSVisualEffectView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: 496,
                height: 90
            ))
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        let close = NSButton(
            image: NSImage(
                systemSymbolName: "xmark",
                accessibilityDescription: "关闭"
            )!,
            target: self,
            action: #selector(closeToolbar)
        )
        close.frame = NSRect(
            x: 12,
            y: 42,
            width: 32,
            height: 32
        )
        close.bezelStyle = .texturedRounded
        effect.addSubview(close)
        modes = NSSegmentedControl(
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
            y: 42,
            width: 190,
            height: 32
        )
        modes.segmentStyle = .rounded
        modes.selectedSegment = CaptureMode.allCases.firstIndex(of: options.mode) ?? 0
        for index in 0..<3 {
            modes.setWidth(58, forSegment: index)
            modes.setToolTip(
                CaptureMode.allCases[index].title + "：" + CaptureMode.allCases[index].spaceHint,
                forSegment: index)
        }
        effect.addSubview(modes)
        let optionsButton = NSPopUpButton(
            frame: NSRect(
                x: 260,
                y: 42,
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
            y: 42,
            width: 106,
            height: 32
        )
        effect.addSubview(recordButton)
        caption = NSTextField(labelWithString: "")
        caption.frame = NSRect(
            x: 16,
            y: 12,
            width: 464,
            height: 20
        )
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.lineBreakMode = .byTruncatingMiddle
        effect.addSubview(caption)
        panel.contentView = effect
        restoreToolbarPosition()
    }

    /// 业务作用: 首次把工具栏放在当前屏幕底部中央，之后恢复用户拖动保存的位置。
    /// 参数说明: 无。
    /// 返回: 非可调整大小的工具栏恢复固定尺寸，并开始自动保存窗口位置。
    private func restoreToolbarPosition() {
        let restored = panel.setFrameUsingName(toolbarFrameName, force: true)
        panel.setContentSize(
            NSSize(
                width: 496,
                height: 90
            ))
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

    /// 业务作用: 从应用或菜单栏恢复工具栏，空闲不查询画面。
    /// 参数说明: 无。
    /// 返回: 窗口恢复到用户保存的可见位置，首次启动位于当前屏幕底部中央。
    @objc private func showToolbar() {
        ensureToolbarVisible()
        if engine.state.isBusy {
            caption.stringValue = engine.state == .stopping ? "正在完成保存与释放…" : "当前录制会话 · 点击停止"
            recordButton.title = "停止"
            recordButton.isEnabled = engine.state != .stopping
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        caption.stringValue = selected?.summary ?? options.mode.title
        caption.stringValue += " · " + options.mode.spaceHint
        recordButton.isEnabled = options.mode == .display || selected != nil
        if !invocationAvailable {
            caption.stringValue += " · ⌘⇧5 被占用，可用菜单栏打开"
        }
        caption.toolTip = caption.stringValue
    }

    /// 业务作用: 关闭本次选择并撤销异步来源查询，不退出应用。
    /// 参数说明: 无。
    /// 返回: 迟到来源结果不能重新显示选择层。
    @objc private func closeToolbar() {
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
        let request = UUID()
        sourceRequest = request
        recordButton.isEnabled = false
        caption.stringValue = "正在获取可录制来源…"
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
                    selection.show(mode: options.mode, content: content, options: options)
                    caption.stringValue = options.mode == .region ? "拖动框选区域，然后点击录制" : "点击要录制的屏幕或窗口"
                    recordButton.isEnabled = options.mode == .display || selected != nil
                    panel.orderFrontRegardless()
                }
            } catch {
                guard sourceRequest == request else {
                    return
                }
                selection.hide()
                availableSources = nil
                recordButton.isEnabled = true
                caption.stringValue = "请检查权限后重新选择"
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
                "\(selected.summary)\n\(options.mode.spaceHint)\n画质：\(options.quality.title)，帧率：\(options.frameRate == 0 ? "自动" : String(options.frameRate))\n系统声音：\(options.systemAudioSummary)\n麦克风：\(microphone)"
            alert.addButton(withTitle: "开始")
            alert.addButton(withTitle: "返回")
            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }
        }
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
            caption.stringValue = "\(seconds) 秒后开始录制 · Esc 取消"
            recordButton.title = "取消"
            recordButton.isEnabled = true
            panel.makeKeyAndOrderFront(nil)
        case .starting, .recording, .stopping, .needsAttention:
            panel.orderOut(nil)
        case .selecting:
            recordButton.title = "录制"
            showToolbar()
        case .idle:
            recordButton.title = "录制"
            recordButton.isEnabled = true
        case .preparing:
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
        artifacts.append(artifact)
        artifact.showThumbnail()
    }

    /// 业务作用: 每次展开选项时反映真实设备与已保存设置。
    /// 参数说明:
    /// - menu: 用户正在打开的选项菜单。
    /// 返回: 只在用户主动选择时改变设置。
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "选项", action: nil, keyEquivalent: "")
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
        for value in [0, 30, 60] {
            addOption(
                value == 0 ? "自动" : "\(value) fps", value: "fps:\(value)",
                checked: options.frameRate == value, to: rate)
        }
        let timer = submenu("倒计时", in: menu)
        for value in [0, 5, 10] {
            addOption(
                value == 0 ? "无" : "\(value) 秒", value: "timer:\(value)",
                checked: options.countdown == value, to: timer)
        }
        let format = submenu("格式", in: menu)
        addOption("SDR（H.264，兼容性最好）", value: "sdr", checked: !options.hdr, to: format)
        addOption("HDR（HEVC）", value: "hdr", checked: options.hdr, to: format)
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
    /// 返回: 可选择全部、指定应用或关闭，不改变麦克风及系统播放设备。
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
        var identifiers = Set(options.audioApplicationBundleIDs ?? [])
        var names: [String: String] = [:]
        for application in NSWorkspace.shared.runningApplications {
            guard application.activationPolicy == .regular,
                application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                let identifier = application.bundleIdentifier
            else {
                continue
            }
            identifiers.insert(identifier)
            names[identifier] = application.localizedName ?? identifier
        }
        for identifier in identifiers where names[identifier] == nil {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                names[identifier] = url.deletingPathExtension().lastPathComponent + "（未运行）"
            } else {
                names[identifier] = identifier + "（未运行）"
            }
        }
        for identifier in identifiers.sorted(by: {
            (names[$0] ?? $0).localizedStandardCompare(names[$1] ?? $1) == .orderedAscending
        }) {
            addOption(
                names[identifier] ?? identifier, value: "audio-app:" + identifier,
                checked: options.audioApplicationBundleIDs?.contains(identifier) == true, to: applications)
        }
        audio.addItem(.separator())
        let scope = NSMenuItem(
            title: "应用过滤包含该应用在其它桌面的声音",
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
                beginRecording()
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
                options.quality = Quality(rawValue: String(value.dropFirst(8))) ?? .automatic
            } else if value.hasPrefix("fps:") {
                options.frameRate = Int(value.dropFirst(4)) ?? 0
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
        {
            return .terminateNow
        }
        quitting = true
        if engine.state.isBusy {
            engine.stop()
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
            })
        {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }
}
