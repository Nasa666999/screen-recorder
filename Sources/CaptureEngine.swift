import AVFoundation
import AppKit
import ScreenCaptureKit

private final class StreamBridge: NSObject, SCStreamOutput, SCStreamDelegate {
    let media: MediaPipeline
    var onStop: ((SCStream, Error) -> Void)?

    /// 业务作用: 将单条采集流绑定本会话的媒体队列。
    /// 参数说明:
    /// - media: 本会话独占的写入管线。
    /// 返回: 不跨会话共享媒体数据。
    init(media: MediaPipeline) {
        self.media = media
    }

    /// 业务作用: 直接在注册的媒体队列交付采集样本，不二次积压回调。
    /// 参数说明:
    /// - stream: 样本所属的采集流。
    /// - sampleBuffer: 当前媒体数据。
    /// - type: 视频、系统音频或麦克风类型。
    /// 返回: 管线按统一时间线接受或拒绝样本。
    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        media.consume(sampleBuffer, type: type)
    }

    /// 业务作用: 将系统终止采集通知交回控制层，由其统一结束其他流。
    /// 参数说明:
    /// - stream: 已被系统停止的流。
    /// - error: 停止原因。
    /// 返回: 不在媒体回调中执行重入的停止或封装。
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.onStop?(stream, error)
        }
    }
}

private final class StreamHandle {
    enum State {
        case pending
        case starting
        case running
        case stopping
        case released
    }

    let stream: SCStream
    let bridge: StreamBridge
    var state = State.pending

    /// 业务作用: 保持流和委托的共同生命周期，显式记录启动与释放情况。
    /// 参数说明:
    /// - stream: 本会话创建的采集流。
    /// - bridge: 对应委托与媒体转发对象。
    /// 返回: 初始未取得采集资源。
    init(stream: SCStream, bridge: StreamBridge) {
        self.stream = stream
        self.bridge = bridge
    }
}

@MainActor
private final class CaptureSession {
    let id = UUID()
    let pipeline: MediaPipeline
    let location: RecordingLocation
    var handles: [StreamHandle] = []
    var stopped = false
    var fileResult: Result<URL?, Error>?
    var reason: String?
    var reportedTimeout = false
    var fileReported = false
    var activity: NSObjectProtocol?
    var monitor: Timer?

    /// 业务作用: 隔离一次录制的控制权、文件结果与资源释放结果。
    /// 参数说明:
    /// - pipeline: 独立媒体管线。
    /// - location: 持续有效的目录访问。
    /// 返回: 新会话不能接收其他会话的迟到回调。
    init(pipeline: MediaPipeline, location: RecordingLocation) {
        self.pipeline = pipeline
        self.location = location
    }
}

@MainActor
final class CaptureEngine {
    var onState: ((RecordingState) -> Void)?
    var onSaved: ((URL, RecordingLocation) -> Void)?
    var onIssue: ((String) -> Void)?
    var onReleased: (() -> Void)?
    var onExitReadinessChanged: (() -> Void)?
    private(set) var state = RecordingState.idle {
        didSet {
            onState?(state)
        }
    }
    private var session: CaptureSession?
    private var preparationID: UUID?

    var canTerminate: Bool {
        guard let session else {
            return true
        }
        return session.stopped && session.fileResult != nil
    }

    /// 业务作用: 请求屏幕访问并查询当前有效的可选来源，不建立录制流。
    /// 参数说明: 无。
    /// 返回: 授权拒绝时抛错，允许用户返回选择界面再次主动开始。
    func sources() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            let system = error as NSError
            // 框架的实际授权结果是取得来源的依据，其他采集 API 的预检不能代替它。
            if system.domain == SCStreamErrorDomain && system.code == -3801 {
                throw RecorderError.message("请在系统设置的“隐私与安全性 → 屏幕与系统音频录制”中允许 Screen Recorder，然后重新打开选择界面。")
            }
            throw error
        }
    }

    /// 业务作用: 复验用户选择、权限和输出目录，冻结设置后开始有限倒计时。
    /// 参数说明:
    /// - selection: 用户主动选定的固定来源。
    /// - options: 当前录制设置的快照。
    /// 返回: 失败回到可选择状态，不自动替换来源或声音设备。
    func start(selection: CaptureSelection, options: RecorderOptions) {
        guard !state.isBusy else {
            return
        }
        let request = UUID()
        preparationID = request
        state = .preparing
        Task {
            do {
                if let microphoneID = options.microphoneID {
                    var allowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                    if !allowed {
                        allowed = await AVCaptureDevice.requestAccess(for: .audio)
                    }
                    guard preparationID == request else {
                        return
                    }
                    guard allowed else {
                        throw RecorderError.message("麦克风未获授权。请关闭麦克风后重新开始，或在系统设置中授权。")
                    }
                    guard
                        RecorderOptions.microphones.contains(where: {
                            $0.uniqueID == microphoneID
                        })
                    else {
                        throw RecorderError.message("所选麦克风已断开，请重新选择设备。")
                    }
                }
                let bookmark = options.directoryBookmark
                let location = try await Task.detached {
                    try RecordingLocation(bookmark: bookmark)
                }.value
                guard preparationID == request else {
                    return
                }
                for seconds in stride(from: options.countdown, through: 1, by: -1) {
                    state = .countingDown(seconds)
                    try await Task.sleep(for: .seconds(1))
                    guard preparationID == request else {
                        return
                    }
                }
                let content = try await sources()
                guard preparationID == request else {
                    return
                }
                try begin(selection: selection, options: options, content: content, location: location)
            } catch {
                guard preparationID == request else {
                    return
                }
                preparationID = nil
                state = .selecting
                onIssue?(RecorderError.describe(error))
            }
        }
    }

    /// 业务作用: 根据有效来源建立最多两条流，窗口系统声音不收窄到所属应用。
    /// 参数说明:
    /// - selection: 用户选择的来源身份与局部区域。
    /// - options: 冻结后的设置。
    /// - content: 启动前重新查询的可采集来源。
    /// - location: 已验证的目标目录。
    /// 返回: 所有流就绪且首帧写入后才进入录制；五秒总期限覆盖每次启动等待。
    private func begin(
        selection: CaptureSelection, options: RecorderOptions, content: SCShareableContent,
        location: RecordingLocation
    ) throws {
        guard
            let display = content.displays.first(where: {
                $0.displayID == selection.display.displayID
            })
        else {
            throw RecorderError.message("来源显示器已断开，请重新选择。")
        }
        let ownApps = content.applications.filter {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }
        let displayFilter = SCContentFilter(
            display: display,
            excludingApplications: ownApps,
            exceptingWindows: []
        )
        let videoFilter: SCContentFilter
        if let oldWindow = selection.window {
            guard
                let window = content.windows.first(where: {
                    $0.windowID == oldWindow.windowID
                        && $0.owningApplication?.processID == oldWindow.owningApplication?.processID
                })
            else {
                throw RecorderError.message("所选窗口已失效，请重新选择。")
            }
            videoFilter = SCContentFilter(desktopIndependentWindow: window)
        } else {
            videoFilter = displayFilter
        }
        if options.hdr && options.showMouseClicks {
            throw RecorderError.message("当前公开采集能力不能在 HDR 管线上显示鼠标点按，请明确关闭其中一项后重新开始。")
        }
        let configuration =
            options.hdr
            ? SCStreamConfiguration(preset: .captureHDRRecordingPreservedSDRHDR10)
            : SCStreamConfiguration()
        if !options.hdr {
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
        }
        var rect = videoFilter.contentRect
        if let region = selection.region {
            let available = CGRect(
                origin: .zero,
                size: displayFilter.contentRect.size
            )
            guard available.contains(region), region.width >= 8, region.height >= 8 else {
                throw RecorderError.message("显示器布局已变化，选区不再有效，请重新框选。")
            }
            let scale = CGFloat(videoFilter.pointPixelScale)
            let left = ceil(region.minX * scale) / scale
            let top = ceil(region.minY * scale) / scale
            let aligned = CGRect(
                x: left,
                y: top,
                width: floor(region.maxX * scale) / scale - left,
                height: floor(region.maxY * scale) / scale - top
            )
            configuration.sourceRect = aligned
            rect = aligned
        }
        let pixelScale = CGFloat(videoFilter.pointPixelScale)
        var width = rect.width * pixelScale
        var height = rect.height * pixelScale
        if options.quality != .automatic {
            let long: CGFloat = options.quality == .standard ? 1920 : 3840
            let short: CGFloat = options.quality == .standard ? 1080 : 2160
            let ratio = min(1, min(long / max(width, height), short / min(width, height)))
            width *= ratio
            height *= ratio
        }
        configuration.width = max(2, Int(width.rounded(.down)) / 2 * 2)
        configuration.height = max(2, Int(height.rounded(.down)) / 2 * 2)
        configuration.minimumFrameInterval =
            options.frameRate == 0
            ? .zero
            : CMTime(
                value: 1,
                timescale: Int32(options.frameRate)
            )
        configuration.queueDepth = 3
        configuration.captureResolution = .best
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showMouseClicks = options.showMouseClicks
        configuration.capturesAudio = options.systemAudio && selection.window == nil
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.captureMicrophone = options.microphoneID != nil
        configuration.microphoneCaptureDeviceID = options.microphoneID
        let pipeline = MediaPipeline(
            location: location,
            specification: VideoSpecification(
                width: configuration.width,
                height: configuration.height,
                hdr: options.hdr,
                frameRate: options.frameRate
            ),
            hasAudio: options.systemAudio || options.microphoneID != nil
        )
        let session = CaptureSession(
            pipeline: pipeline,
            location: location
        )
        try addStream(
            filter: videoFilter, configuration: configuration, screen: true,
            audio: configuration.capturesAudio, microphone: configuration.captureMicrophone,
            session: session)
        if selection.window != nil, options.systemAudio {
            let audioConfiguration = SCStreamConfiguration()
            audioConfiguration.width = 2
            audioConfiguration.height = 2
            audioConfiguration.minimumFrameInterval = CMTime(
                seconds: 1,
                preferredTimescale: 60
            )
            audioConfiguration.queueDepth = 3
            audioConfiguration.capturesAudio = true
            audioConfiguration.excludesCurrentProcessAudio = true
            audioConfiguration.sampleRate = 48_000
            audioConfiguration.channelCount = 2
            audioConfiguration.captureMicrophone = false
            try addStream(
                filter: displayFilter, configuration: audioConfiguration, screen: false, audio: true,
                microphone: false, session: session)
        }
        self.session = session
        preparationID = nil
        state = .starting
        session.activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "用户主动录制屏幕")
        pipeline.onStarted = { [weak self, weak session] in
            guard let self, let session, self.session === session, !session.stopped else {
                return
            }
            self.state = .recording
        }
        pipeline.onFailure = { [weak self, weak session] error in
            guard let self, let session, self.session === session else {
                return
            }
            self.stop(
                reason:
                    "当前输出 \(configuration.width) × \(configuration.height) 无法继续：\(RecorderError.describe(error))。可调整画质、帧率或格式后重试。"
            )
        }
        for handle in session.handles {
            Task {
                guard !session.stopped else {
                    handle.state = .released
                    settle(session)
                    return
                }
                handle.state = .starting
                do {
                    try await handle.stream.startCapture()
                    guard handle.state != .released else {
                        return
                    }
                    handle.state = .running
                    // 停止请求撤销继续录制的权威，迟到启动也必须立即释放。
                    if session.stopped {
                        release(handle, session: session)
                    } else if session.handles.allSatisfy({
                        $0.state == .running
                    }) {
                        pipeline.allowStart()
                    }
                } catch {
                    handle.state = .released
                    if self.session === session {
                        stop(reason: "采集启动失败：\(error.localizedDescription)")
                        settle(session)
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak session] in
            guard let self, let session, self.session === session, !session.stopped,
                self.state != .recording
            else {
                return
            }
            self.stop(reason: "五秒内未完成采集启动与有效首帧写入。")
        }
        let watchedDisplayID = display.displayID
        let watchedWindowID = selection.window?.windowID
        let watchedPID = selection.window?.owningApplication?.processID
        session.monitor = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) {
            [weak self, weak session] _ in
            Task { @MainActor in
                guard let self, let session, self.session === session, !session.stopped else {
                    return
                }
                // 显示器和窗口身份失效时立即结束，不把失效来源替换为桌面或同名窗口。
                if CGDisplayIsOnline(watchedDisplayID) == 0 {
                    self.stop(reason: "来源显示器已断开。")
                    return
                }
                if let watchedWindowID {
                    let info =
                        CGWindowListCopyWindowInfo(
                            .optionIncludingWindow,
                            watchedWindowID
                        )
                        as? [[String: Any]]
                    let exists =
                        info?.contains(where: {
                            ($0[kCGWindowNumber as String] as? UInt32) == watchedWindowID
                                && ($0[kCGWindowOwnerPID as String] as? Int32)
                                    == watchedPID
                        }) == true
                    if !exists {
                        self.stop(reason: "原始窗口已关闭或无法复验其身份。")
                    }
                }
            }
        }
    }

    /// 业务作用: 将采集输出与系统停止通知绑定到本会话，保持委托存活。
    /// 参数说明:
    /// - filter: 当前流的画面与应用过滤范围。
    /// - configuration: 当前流的采集规格。
    /// - screen: 是否接收视频。
    /// - audio: 是否接收系统声音。
    /// - microphone: 是否接收麦克风。
    /// - session: 当前会话。
    /// 返回: 输出注册失败直接抛错，不启动不完整的拓扑。
    private func addStream(
        filter: SCContentFilter, configuration: SCStreamConfiguration, screen: Bool, audio: Bool,
        microphone: Bool, session: CaptureSession
    ) throws {
        let bridge = StreamBridge(media: session.pipeline)
        let stream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: bridge
        )
        let handle = StreamHandle(
            stream: stream,
            bridge: bridge
        )
        if screen {
            try stream.addStreamOutput(bridge, type: .screen, sampleHandlerQueue: session.pipeline.queue)
        }
        if audio {
            try stream.addStreamOutput(bridge, type: .audio, sampleHandlerQueue: session.pipeline.queue)
        }
        if microphone {
            try stream.addStreamOutput(
                bridge, type: .microphone, sampleHandlerQueue: session.pipeline.queue)
        }
        bridge.onStop = { [weak self, weak session, weak handle] _, error in
            guard let self, let session, let handle, self.session === session else {
                return
            }
            handle.state = .released
            self.stop(reason: session.stopped ? nil : "系统已停止采集：\(error.localizedDescription)")
            self.settle(session)
        }
        session.handles.append(handle)
    }

    /// 业务作用: 幂等地固定媒体边界，停止所有流并独立等待文件处理结果。
    /// 参数说明:
    /// - reason: 来源或设备中断原因，正常停止为空。
    /// 返回: 释放不确认时保留异常状态，禁止创建新的采集会话。
    func stop(reason: String? = nil) {
        preparationID = nil
        guard let session else {
            state = .selecting
            return
        }
        guard !session.stopped else {
            if session.reason == nil {
                session.reason = reason
            }
            return
        }
        session.stopped = true
        session.reason = reason
        session.monitor?.invalidate()
        session.monitor = nil
        if let activity = session.activity {
            ProcessInfo.processInfo.endActivity(activity)
            session.activity = nil
        }
        state = .stopping
        let boundary = CMClockGetTime(CMClockGetHostTimeClock())
        session.pipeline.setStopBoundary(boundary)
        for handle in session.handles {
            if handle.state == .pending {
                handle.state = .released
            } else if handle.state == .running {
                release(handle, session: session)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak session] in
            guard let self, let session, self.session === session else {
                return
            }
            session.pipeline.finish(at: boundary) { [weak self, weak session] result in
                guard let self, let session, self.session === session else {
                    return
                }
                session.fileResult = result
                self.settle(session)
                self.onExitReadinessChanged?()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak session] in
            guard let self, let session, self.session === session else {
                return
            }
            session.reportedTimeout = true
            self.state = .needsAttention
            let released = session.handles.allSatisfy {
                $0.state == .released
            }
            let fileText = session.fileResult == nil ? "文件处理仍未结束" : "文件处理已有结果"
            self.onIssue?("停止已超过十秒，\(fileText)，\(released ? "采集已释放" : "采集会话尚未确认释放")。暂不能开始新录制；不会重启系统服务。")
        }
    }

    /// 业务作用: 请求释放已经启动的流，不把发出请求当成释放成功。
    /// 参数说明:
    /// - handle: 已取得采集资源的流。
    /// - session: 资源所属会话。
    /// 返回: 成功回执更新释放状态，失败保留占用直到系统回执或进程退出。
    private func release(_ handle: StreamHandle, session: CaptureSession) {
        guard handle.state == .running else {
            return
        }
        handle.state = .stopping
        Task {
            do {
                try await handle.stream.stopCapture()
                handle.state = .released
            } catch {
                session.reason = session.reason ?? "采集释放未确认：\(error.localizedDescription)"
            }
            settle(session)
        }
    }

    /// 业务作用: 汇总互不覆盖的文件结果与采集释放结果，迟到回执只解除资源占用。
    /// 参数说明:
    /// - session: 可能刚收到文件或停止回调的会话。
    /// 返回: 文件处理结束且全部流释放后才恢复可录制状态。
    private func settle(_ session: CaptureSession) {
        guard self.session === session, let result = session.fileResult else {
            return
        }
        let released = session.handles.allSatisfy {
            $0.state == .released
        }
        guard released else {
            return
        }
        if let activity = session.activity {
            ProcessInfo.processInfo.endActivity(activity)
            session.activity = nil
        }
        self.session = nil
        state = .idle
        switch result {
        case .success(let url):
            if let url {
                onSaved?(url, session.location)
            }
        case .failure(let error):
            onIssue?("保存未完成：\(error.localizedDescription)")
        }
        if let reason = session.reason {
            onIssue?(reason)
        }
        onReleased?()
    }
}
