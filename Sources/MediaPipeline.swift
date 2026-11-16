import AVFoundation
import ScreenCaptureKit
import VideoToolbox

struct VideoSpecification {
    let width: Int
    let height: Int
    let hdr: Bool
    let frameRate: Int

    var framesPerSecond: Int {
        frameRate == 60 ? 60 : 30
    }

    /// 业务作用: 将采集时间量化到会话的固定帧格，防止高刷新率回调穿透录制帧率上限。
    /// 参数说明:
    /// - time: 当前画面的宿主时钟时间。
    /// - origin: 本次录制的视频与声音共同起点。
    /// 返回: 同一帧格内的画面使用相同时间戳，由写入管线只保留一帧。
    func frameTime(for time: CMTime, origin: CMTime) -> CMTime {
        origin
            + CMTimeConvertScale(
                max(.zero, time - origin),
                timescale: Int32(framesPerSecond),
                method: .roundHalfAwayFromZero
            )
    }

    /// 业务作用: 根据固定画布和帧率为长时间录制设置编码预算，兼顾细节与文件体积。
    /// 参数说明:
    /// - codec: 当前尺寸实际可用的硬件编码格式。
    /// 返回: 编码器的平均码率、预期帧率与关键帧间隔在会话内保持不变。
    func compressionSettings(for codec: AVVideoCodecType) -> [String: Any] {
        let pixels = Double(width) * Double(height)
        let scale = max(0.2, pixels / (1920 * 1080))
        let baseRate = codec == .hevc ? 3_500_000.0 : 5_000_000.0
        let rate = Int(baseRate * scale * (framesPerSecond == 60 ? 1.5 : 1) * (hdr ? 1.25 : 1))
        var settings: [String: Any] = [
            AVVideoAverageBitRateKey: rate,
            AVVideoExpectedSourceFrameRateKey: framesPerSecond,
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
            AVVideoAllowFrameReorderingKey: false,
        ]
        if hdr {
            settings[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel
        }
        return settings
    }

    /// 业务作用: 按实际输出尺寸选择可用的高效硬件编码器，降低文件体积而不降低画布分辨率。
    /// 参数说明: 无。
    /// 返回: 优先使用 HEVC，SDR 不可用时选择 H.264；HDR 只使用 HEVC，全部不可用时明确失败。
    func encoderCodec() throws -> AVVideoCodecType {
        guard let width = Int32(exactly: width), let height = Int32(exactly: height),
            width > 0, height > 0
        else {
            throw RecorderError.message("录制画面尺寸无效。")
        }
        let candidates: [(AVVideoCodecType, CMVideoCodecType)] =
            hdr
            ? [(.hevc, kCMVideoCodecType_HEVC)]
            : [(.hevc, kCMVideoCodecType_HEVC), (.h264, kCMVideoCodecType_H264)]
        let requirement =
            [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
            ] as CFDictionary
        for (codec, type) in candidates {
            var properties: CFDictionary?
            let status = VTCopySupportedPropertyDictionaryForEncoder(
                width: width,
                height: height,
                codecType: type,
                encoderSpecification: requirement,
                encoderIDOut: nil,
                supportedPropertiesOut: &properties
            )
            if status == noErr {
                return codec
            }
        }
        // 没有匹配的硬件编码器时不能偷偷改成软件编码、降低尺寸或把 HDR 标成 SDR。
        throw RecorderError.message("硬件编码器不支持当前 \(width) × \(height) 的录制规格，请选择 1080p 或调整格式。")
    }
}

// 混音与编码状态由媒体队列访问，输入预算由采集队列访问；回调在采集启动前设定。
final class MediaPipeline: @unchecked Sendable {
    let captureQueue = DispatchQueue(
        label: "com.nasa666999.screen-recorder.capture",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )
    let queue = DispatchQueue(
        label: "com.nasa666999.screen-recorder.media",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )
    var onStarted: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    private let location: RecordingLocation
    private let specification: VideoSpecification
    private let hasAudio: Bool
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var audio: AudioPipeline?
    private var preAudio: [(CMSampleBuffer, AudioSource)] = []
    private var ready = false
    private var accepting = true
    private var origin: CMTime?
    private var lastVideo: CMSampleBuffer?
    private var lastVideoTime = CMTime.invalid
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var failure: Error?
    private var blockedSince: CFTimeInterval?
    private var stopBoundary: CMTime?
    private let videoSlots = DispatchSemaphore(value: 3)
    private let audioSlots = DispatchSemaphore(value: 64)
    private let ingressByteLimit = 128 * 1024 * 1024
    private var pendingIngressBytes = 0
    private var ingressFailureScheduled = false

    /// 业务作用: 立即固定收尾时间，停止请求之后到达的画面不得越界写入。
    /// 参数说明:
    /// - time: 用户停止的宿主时钟时刻。
    /// 返回: 已排队的合法样本仍可在有限收尾阶段处理。
    func setStopBoundary(_ time: CMTime) {
        queue.async {
            self.stopBoundary = time
        }
    }

    /// 业务作用: 为单次录制建立串行媒体所有权，尚不创建编码器或采集。
    /// 参数说明:
    /// - location: 本会话持有的目录与临时文件。
    /// - specification: 已冻结的输出画布和色彩规格。
    /// - hasAudio: 是否创建一条混音音轨。
    /// 返回: 所有后续样本只在专用串行队列处理。
    init(location: RecordingLocation, specification: VideoSpecification, hasAudio: Bool) {
        self.location = location
        self.specification = specification
        self.hasAudio = hasAudio
    }

    /// 业务作用: 允许全部必需采集流就绪后才以首个完整视频帧开始文件。
    /// 参数说明: 无。
    /// 返回: 不同流不会分别建立独立起点。
    func allowStart() {
        queue.async {
            self.ready = true
        }
    }

    /// 业务作用: 从实时采集回调非阻塞地交付有限样本，编码或磁盘变慢不能无限占用采集缓冲。
    /// 参数说明:
    /// - sample: 当前采集样本，提交后由媒体队列持有至处理结束。
    /// - type: 视频、系统声音或麦克风。
    /// 返回: 最多排队三个视频和六十四个音频样本，合计不超过 128 MiB；视频拥塞丢帧，音频拥塞结束会话而不变速。
    func enqueue(_ sample: CMSampleBuffer, type: SCStreamOutputType) {
        dispatchPrecondition(condition: .onQueue(captureQueue))
        guard !ingressFailureScheduled else {
            return
        }
        let slots = type == .screen ? videoSlots : audioSlots
        let pixelBytes = sample.imageBuffer.map(CVPixelBufferGetDataSize) ?? 0
        let bytes = max(sample.totalSampleSize, pixelBytes)
        // 数量限制不能约束高分辨率单帧或异常大音频块，同时核对字节预算，不能让大样本穿透内存边界。
        guard bytes <= ingressByteLimit - pendingIngressBytes, slots.wait(timeout: .now()) == .success else {
            if bytes > ingressByteLimit || type != .screen {
                // 单个样本无法容纳或实时声音耗尽预算时明确结束，不能无限缓存或变速掩盖过载。
                ingressFailureScheduled = true
                let message =
                    bytes > ingressByteLimit
                    ? "单个媒体缓冲超过 128 MiB，无法在当前内存预算内录制，请缩小画面或调整分辨率。"
                    : "声音输入持续积压，录制已停止以保留已取得的内容。"
                queue.async {
                    self.fail(RecorderError.message(message))
                }
            }
            return
        }
        pendingIngressBytes += bytes
        queue.async {
            defer {
                slots.signal()
                self.captureQueue.async {
                    self.pendingIngressBytes -= bytes
                }
            }
            self.consume(sample, type: type)
        }
    }

    /// 业务作用: 在唯一媒体队列处理已取得输入预算的样本，保持编码与混音状态串行。
    /// 参数说明:
    /// - sample: 当前采集样本。
    /// - type: 视频、系统声音或麦克风。
    /// 返回: 无效或旧样本不写入；持续失败通知会话统一停止。
    func consume(_ sample: CMSampleBuffer, type: SCStreamOutputType) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard accepting, failure == nil, sample.isValid else {
            return
        }
        do {
            if type == .screen {
                if let stopBoundary, sample.presentationTimeStamp > stopBoundary {
                    return
                }
                let attachments =
                    CMSampleBufferGetSampleAttachmentsArray(
                        sample,
                        createIfNecessary: false
                    )
                    as? [[SCStreamFrameInfo: Any]]
                guard let raw = attachments?.first?[.status] as? Int,
                    let status = SCFrameStatus(rawValue: raw)
                else {
                    return
                }
                // 来源明确停止时结束录制；用户正常停止产生的末尾通知不能再变成采集失败。
                if status == .stopped, stopBoundary == nil {
                    throw RecorderError.message("原画面来源已停止采集。")
                }
                guard status == .complete,
                    sample.imageBuffer != nil, ready
                else {
                    return
                }
                if writer == nil {
                    try startWriter(sample)
                }
                guard let origin else {
                    return
                }
                let time = specification.frameTime(for: sample.presentationTimeStamp, origin: origin)
                guard time > lastVideoTime || !lastVideoTime.isValid else {
                    return
                }
                guard let videoInput, videoInput.isReadyForMoreMediaData else {
                    checkBackpressure()
                    return
                }
                let frame = try videoSample(sample, at: time)
                guard writer?.status == .writing, videoInput.append(frame) else {
                    throw writer?.error ?? RecorderError.message("视频写入失败。")
                }
                blockedSince = nil
                let firstFrame = lastVideo == nil
                lastVideo = frame
                lastVideoTime = time
                if firstFrame {
                    DispatchQueue.main.async { [weak self] in
                        self?.onStarted?()
                    }
                }
            } else {
                let source: AudioSource = type == .microphone ? .microphone : .system
                if let audio {
                    try audio.append(sample, source: source)
                } else if hasAudio {
                    preAudio.append((sample, source))
                    let threshold =
                        sample.presentationTimeStamp
                        - CMTime(
                            seconds: 0.5,
                            preferredTimescale: 48_000
                        )
                    preAudio.removeAll {
                        $0.0.presentationTimeStamp < threshold
                    }
                    if preAudio.count > 256 {
                        throw RecorderError.message("启动音频超过缓存上限。")
                    }
                }
            }
        } catch {
            fail(error)
        }
    }

    /// 业务作用: 为视频帧声明固定帧率对应的时间与持续时间，不复制像素或更改声音时间线。
    /// 参数说明:
    /// - sample: 已采集的画面或需要延长显示的末帧。
    /// - time: 该画面在本次录制帧格上的宿主时间。
    /// 返回: 共享原始像素且具有明确帧时长的样本，时间信息无法建立时抛错。
    private func videoSample(_ sample: CMSampleBuffer, at time: CMTime) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(specification.framesPerSecond)),
            presentationTimeStamp: time,
            decodeTimeStamp: .invalid
        )
        var copy: CMSampleBuffer?
        guard
            CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: sample,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleBufferOut: &copy
            ) == noErr, let copy
        else {
            throw RecorderError.message("无法建立固定帧率的视频时间线。")
        }
        return copy
    }

    /// 业务作用: 以实际首帧建立编码器与宿主时钟起点，音频不能另起一条时间轴。
    /// 参数说明:
    /// - firstVideo: 全部采集流就绪后的第一帧。
    /// 返回: 编码规格不可用时失败，不静默降低质量。
    private func startWriter(_ firstVideo: CMSampleBuffer) throws {
        // 在创建文件写入会话前核对硬件编码器能力，编码格式不改变用户选择的画布。
        let codec = try specification.encoderCodec()
        let writer = try AVAssetWriter(
            outputURL: location.temporaryURL,
            fileType: .mov
        )
        // 屏幕高刷新率仍表示实时播放，明确标记可避免播放器把录屏当作慢动作视频。
        let playbackIntent = AVMutableMetadataItem()
        playbackIntent.identifier = .quickTimeMetadataFullFrameRatePlaybackIntent
        playbackIntent.value = NSNumber(value: 1)
        playbackIntent.dataType = kCMMetadataBaseDataType_SInt8 as String
        writer.metadata = [playbackIntent]
        var settings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: specification.width,
            AVVideoHeightKey: specification.height,
            AVVideoCompressionPropertiesKey: specification.compressionSettings(for: codec),
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
            ],
        ]
        if specification.hdr {
            settings[AVVideoAllowWideColorKey] = true
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_SMPTE_ST_2084_PQ,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ]
        }
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw RecorderError.message("硬件编码器不支持当前尺寸或格式，请调整画质或格式。")
        }
        let video = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: settings,
            sourceFormatHint: firstVideo.formatDescription
        )
        video.expectsMediaDataInRealTime = true
        video.mediaTimeScale = 60_000
        video.preferredMediaChunkDuration = CMTime(seconds: 1, preferredTimescale: 600)
        guard writer.canAdd(video) else {
            throw RecorderError.message("无法添加视频轨道。")
        }
        writer.add(video)
        if hasAudio {
            let audioInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: AudioPipeline.sampleRate,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 192_000,
                ]
            )
            audioInput.expectsMediaDataInRealTime = true
            audioInput.preferredMediaChunkDuration = CMTime(seconds: 1, preferredTimescale: 48_000)
            guard writer.canAdd(audioInput) else {
                throw RecorderError.message("无法添加声音轨道。")
            }
            writer.add(audioInput)
            self.audioInput = audioInput
        }
        guard writer.startWriting() else {
            throw writer.error ?? RecorderError.message("无法开始写入 MOV。")
        }
        let origin = firstVideo.presentationTimeStamp
        writer.startSession(atSourceTime: origin)
        self.origin = origin
        self.writer = writer
        videoInput = video
        if hasAudio {
            let audio = AudioPipeline(origin: origin)
            self.audio = audio
            for (sample, source) in preAudio {
                try audio.append(sample, source: source)
            }
        }
        preAudio.removeAll()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        self.timer = timer
        timer.resume()
    }

    /// 业务作用: 以固定等待预算推进混音，并在静态画面时检查写入健康。
    /// 参数说明: 无。
    /// 返回: 声源缺席只补静音，真实写入异常进入统一停止。
    private func tick() {
        guard !stopped, failure == nil, let origin else {
            return
        }
        do {
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            let target =
                now
                - CMTime(
                    seconds: 0.2,
                    preferredTimescale: 48_000
                )
            try flushAudio(until: min(target, stopBoundary ?? target))
            if let videoInput, videoInput.isReadyForMoreMediaData {
                blockedSince = nil
            } else {
                checkBackpressure()
            }
            if now < origin {
                throw RecorderError.message("媒体宿主时钟发生异常变化。")
            }
        } catch {
            fail(error)
        }
    }

    /// 业务作用: 将已超过混音等待预算的音频区间送入唯一 AAC 轨道。
    /// 参数说明:
    /// - time: 本次允许写到的宿主时钟边界。
    /// 返回: 写入成功才前进游标，积压超过两秒时抛错。
    private func flushAudio(until time: CMTime) throws {
        guard let audio, let audioInput, let origin else {
            return
        }
        let limit = max(
            0, Int64((CMTimeGetSeconds(time - origin) * AudioPipeline.sampleRate).rounded(.down)))
        guard limit - audio.cursor <= 96_000 else {
            throw RecorderError.message("声音写入持续积压，录制已停止。")
        }
        while audio.cursor < limit, audioInput.isReadyForMoreMediaData {
            let count = Int(min(480, limit - audio.cursor))
            let sample = try audio.nextSample(count: count)
            guard audioInput.append(sample) else {
                throw writer?.error ?? RecorderError.message("声音写入失败。")
            }
            audio.advance(count)
        }
    }

    /// 业务作用: 对写入停滞设置有界等待，避免通过永久丢帧掩盖失败。
    /// 参数说明: 无。
    /// 返回: 两秒内不能恢复时通知会话结束。
    private func checkBackpressure() {
        let now = ProcessInfo.processInfo.systemUptime
        if let blockedSince, now - blockedSince > 2 {
            fail(RecorderError.message("视频编码或存储持续停滞，录制已停止。"))
        } else if blockedSince == nil {
            blockedSince = now
        }
    }

    /// 业务作用: 记录唯一媒体失败，不在采集回调内重入会话控制。
    /// 参数说明:
    /// - error: 本次录制不能继续的原因。
    /// 返回: 关闭新的媒体处理并异步请求统一停止。
    private func fail(_ error: Error) {
        guard failure == nil else {
            return
        }
        failure = error
        DispatchQueue.main.async { [weak self] in
            self?.onFailure?(error)
        }
    }

    /// 业务作用: 固定停止边界，排空有限媒体后完成封装，重复请求不重复结束。
    /// 参数说明:
    /// - time: 用户停止的宿主时钟时刻。
    /// - completion: 交回文件结果，采集释放由会话独立确认。
    /// 返回: 成品原子发布或保留失败产物；无首帧时不伪造视频。
    func finish(at time: CMTime, completion: @escaping (Result<URL?, Error>) -> Void) {
        queue.async {
            guard !self.stopped else {
                return
            }
            self.stopped = true
            self.accepting = false
            self.timer?.cancel()
            self.timer = nil
            self.preAudio.removeAll()
            guard let writer = self.writer, let origin = self.origin else {
                self.location.removeEmptyFile()
                DispatchQueue.main.async {
                    completion(.success(nil))
                }
                return
            }
            self.completeMedia(
                at: max(time, origin), deadline: ProcessInfo.processInfo.systemUptime + 7,
                completion: completion)
            _ = writer
        }
    }

    /// 业务作用: 在有界收尾期间等待写入就绪，补齐静态视频末帧与音频尾部。
    /// 参数说明:
    /// - time: 固定的媒体停止边界。
    /// - deadline: 不因重试而延长的排空期限。
    /// - completion: 文件最终处理结果。
    /// 返回: 不存在并发追加时才调用异步封装接口。
    private func completeMedia(
        at time: CMTime, deadline: CFTimeInterval, completion: @escaping (Result<URL?, Error>) -> Void
    ) {
        guard let writer else {
            return
        }
        do {
            if writer.status != .writing {
                throw writer.error ?? failure ?? RecorderError.message("写入器未处于有效写入状态。")
            }
            try flushAudio(until: time)
            let audioDone =
                audio == nil
                || audio!.cursor
                    >= Int64((CMTimeGetSeconds(time - origin!) * AudioPipeline.sampleRate).rounded(.down))
            let endFrame = CMTimeConvertScale(
                max(.zero, time - origin!),
                timescale: Int32(specification.framesPerSecond),
                method: .roundAwayFromZero
            )
            let tailTime =
                origin!
                + CMTime(
                    value: max(0, endFrame.value - 1),
                    timescale: endFrame.timescale
                )
            let needsTail = lastVideo != nil && tailTime > lastVideoTime
            if !audioDone || (needsTail && videoInput?.isReadyForMoreMediaData != true) {
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw RecorderError.message("停止后媒体仍无法写入，未完成视频已保留。")
                }
                queue.asyncAfter(deadline: .now() + .milliseconds(20)) {
                    self.completeMedia(at: time, deadline: deadline, completion: completion)
                }
                return
            }
            if needsTail, let lastVideo {
                // 末帧同样落在固定帧格上，不能用极短的尾帧让文件重新呈现高帧率特征。
                let copy = try videoSample(lastVideo, at: tailTime)
                guard videoInput?.append(copy) == true else {
                    throw writer.error ?? RecorderError.message("无法完成静态视频尾帧。")
                }
            }
            finalizeWriter(writer, at: time, completion: completion)
        } catch {
            fail(error)
            if writer.status == .writing {
                // 追加失败仍尽力封装已经取得的内容，取消写入可能丢弃整个文件。
                finalizeWriter(writer, at: time, completion: completion)
            } else {
                completeFile(.failure(error), completion: completion)
            }
        }
    }

    /// 业务作用: 关闭所有输入并验证封装产物，媒体失败与资源释放分别汇报。
    /// 参数说明:
    /// - writer: 已停止接收新样本的写入器。
    /// - time: 统一的停止边界。
    /// - completion: 最终文件结果。
    /// 返回: 文件有效且原子发布后才产生可分享成品，失败保留实际产物。
    private func finalizeWriter(
        _ writer: AVAssetWriter, at time: CMTime, completion: @escaping (Result<URL?, Error>) -> Void
    ) {
        lastVideo = nil
        writer.endSession(atSourceTime: time)
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        // 所有追加入口已关闭，封装完成以前不得移动或删除文件。
        writer.finishWriting {
            Task {
                let result: Result<URL?, Error>
                do {
                    guard writer.status == .completed else {
                        throw writer.error ?? RecorderError.message("MOV 封装失败，请检查所选目录中的未完成文件。")
                    }
                    let asset = AVURLAsset(url: self.location.temporaryURL)
                    let videos = try await asset.loadTracks(withMediaType: .video)
                    let audios = try await asset.loadTracks(withMediaType: .audio)
                    let duration = try await asset.load(.duration)
                    guard videos.count == 1, audios.count == (self.hasAudio ? 1 : 0), duration.isNumeric,
                        duration > .zero
                    else {
                        throw RecorderError.message("封装文件的轨道或时长无效，不发布为成品。")
                    }
                    result = .success(try self.location.publish())
                } catch {
                    result = .failure(error)
                }
                self.queue.async {
                    self.completeFile(result, completion: completion)
                }
            }
        }
    }

    /// 业务作用: 在唯一媒体队列释放编码资源后交付一次文件处理结果。
    /// 参数说明:
    /// - result: 成品位置或实际失败。
    /// - completion: 主线程上的会话回调。
    /// 返回: 文件结果不能代表其他采集流已经释放。
    private func completeFile(
        _ result: Result<URL?, Error>, completion: @escaping (Result<URL?, Error>) -> Void
    ) {
        audio = nil
        lastVideo = nil
        writer = nil
        videoInput = nil
        audioInput = nil
        DispatchQueue.main.async {
            completion(result)
        }
    }
}
