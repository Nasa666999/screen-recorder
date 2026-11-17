import AVFoundation
import CoreImage
import CoreML

struct MovieWatermarkRegion: Identifiable, @unchecked Sendable {
    let id: UUID
    var range: CMTimeRange
    // 显示画面的左上角为原点；比例坐标随窗口缩放保持不变。
    var rect: CGRect

    /// 业务作用: 保存一个固定位置及其生效时段，允许同一来源分时段更换位置。
    /// 参数说明:
    /// - range: 来源时间线上左闭右开的生效范围。
    /// - rect: 显示画面内的比例矩形，原点在左上角。
    /// 返回: 可随剪切计划复制并撤销的独立区域。
    init(range: CMTimeRange, rect: CGRect) {
        id = UUID()
        self.range = range
        self.rect = rect
    }

    /// 业务作用: 阻止越界时间或空白框进入像素处理。
    /// 参数说明:
    /// - bounds: 来源轨道的有效时间范围。
    /// 返回: 时间与位置均有效时成功，否则拒绝处理。
    func validate(within bounds: CMTimeRange) throws {
        guard range.isValid, range.start.isNumeric, range.duration.isNumeric,
            range.duration > .zero, range.start >= bounds.start, range.end <= bounds.end,
            rect.origin.x.isFinite, rect.origin.y.isFinite,
            rect.width.isFinite, rect.height.isFinite,
            rect.width > 0, rect.height > 0,
            rect.minX >= 0, rect.minY >= 0, rect.maxX <= 1, rect.maxY <= 1
        else {
            throw RecorderError.message("水印区域需要位于画面内，且生效时间必须位于来源视频内。")
        }
    }

    /// 业务作用: 将显示画面上的比例框映射回编码像素，保留竖屏和旋转来源的方位。
    /// 参数说明:
    /// - size: 编码视频的原始尺寸。
    /// - transform: 轨道的显示方向变换。
    /// 返回: Core Image 左下角坐标中的原始像素矩形。
    func pixelRect(size: CGSize, transform: CGAffineTransform) -> CGRect {
        let displayed = CGRect(origin: .zero, size: size).applying(transform)
        let visible = CGRect(
            x: displayed.minX + rect.minX * displayed.width,
            y: displayed.minY + rect.minY * displayed.height,
            width: rect.width * displayed.width,
            height: rect.height * displayed.height
        ).applying(transform.inverted())
        return CGRect(
            x: visible.minX, y: size.height - visible.maxY,
            width: visible.width, height: visible.height
        ).intersection(CGRect(origin: .zero, size: size)).integral
    }
}

struct MovieWatermarkInterval: @unchecked Sendable {
    let range: CMTimeRange
    let rect: CGRect
}

// 模型和中间像素仅由单个离线任务使用，不与录制媒体队列共享。
final class MovieInpainter {
    private let model: MLModel
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let edge: Int
    private let imageBuffer: CVPixelBuffer
    private let maskBuffer: CVPixelBuffer
    private let outputName: String

    /// 业务作用: 从应用随附资源加载本地补全模型，不把用户画面发送到网络。
    /// 参数说明: 无。
    /// 返回: 可重复处理有限画面块的模型；资源缺失或格式不符时明确失败。
    init() throws {
        guard let url = Bundle.main.url(forResource: "LaMa", withExtension: "mlmodelc") else {
            throw RecorderError.message("应用缺少本地补全模型，请安装包含 LaMa 模型的完整应用。")
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        model = try MLModel(contentsOf: url, configuration: configuration)
        guard let image = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint,
            let mask = model.modelDescription.inputDescriptionsByName["mask"]?.imageConstraint,
            image.pixelsWide == image.pixelsHigh, mask.pixelsWide == image.pixelsWide,
            mask.pixelsHigh == image.pixelsHigh,
            let output = model.modelDescription.outputDescriptionsByName.first(where: {
                $0.value.type == .image
            })?.key
        else {
            throw RecorderError.message("本地补全模型的输入格式不受支持。")
        }
        edge = image.pixelsWide
        outputName = output
        imageBuffer = try Self.buffer(width: edge, height: edge, format: image.pixelFormatType)
        maskBuffer = try Self.buffer(width: edge, height: edge, format: mask.pixelFormatType)
    }

    /// 业务作用: 创建可由 Core Image 与 Core ML 共用的有限像素缓冲。
    /// 参数说明:
    /// - width: 缓冲宽度。
    /// - height: 缓冲高度。
    /// - format: 模型或编码器要求的像素格式。
    /// 返回: 独立缓冲；内存不足时抛错。
    static func buffer(width: Int, height: Int, format: OSType = kCVPixelFormatType_32BGRA) throws
        -> CVPixelBuffer
    {
        var result: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, format,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result)
        guard status == kCVReturnSuccess, let result else {
            throw RecorderError.message("无法为画面补全分配像素缓冲。")
        }
        return result
    }

    /// 业务作用: 利用框周围的当前帧重建内容，仅替换框内及少量外扩边缘。
    /// 参数说明:
    /// - buffer: 当前原始画面。
    /// - rects: 当前时刻需要补全的原始像素区域。
    /// 返回: 独立的重建画面；其它画面区域保持原始像素，模型失败时抛错。
    func process(_ buffer: CVPixelBuffer, rects: [CGRect]) throws -> CVPixelBuffer {
        let canvas = CGRect(
            x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        var image = CIImage(cvPixelBuffer: buffer)
        var result = buffer
        // 每个框独立限定可变像素，不能用外接大矩形扩大多个框之间的处理区域。
        let regions = rects.map { $0.insetBy(dx: -4, dy: -4).intersection(canvas).integral }
        for rect in regions {
            try Task.checkCancellation()
            let side = min(max(rect.width, rect.height) * 3, max(canvas.width, canvas.height))
            let crop = CGRect(
                x: min(max(0, rect.midX - side / 2), max(0, canvas.width - side)),
                y: min(max(0, rect.midY - side / 2), max(0, canvas.height - side)),
                width: side, height: side
            )
            let scale = CGFloat(edge) / side
            // 分别平移再缩放，保证角落的掩码与输入图像使用完全相同的坐标。
            let patch = image.clampedToExtent().cropped(to: crop)
                .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let maskRect = CGRect(
                x: (rect.minX - crop.minX) * scale, y: (rect.minY - crop.minY) * scale,
                width: rect.width * scale, height: rect.height * scale)
            let mask = CIImage(color: .white).cropped(to: maskRect)
                .composited(over: CIImage(color: .black))
            let extent = CGRect(x: 0, y: 0, width: edge, height: edge)
            context.render(patch, to: imageBuffer, bounds: extent, colorSpace: colorSpace)
            context.render(mask, to: maskBuffer, bounds: extent, colorSpace: colorSpace)
            let features = try MLDictionaryFeatureProvider(dictionary: [
                "image": MLFeatureValue(pixelBuffer: imageBuffer),
                "mask": MLFeatureValue(pixelBuffer: maskBuffer),
            ])
            let prediction = try model.prediction(from: features)
            guard let generated = prediction.featureValue(for: outputName)?.imageBufferValue else {
                throw RecorderError.message("本地补全模型没有产生可用画面。")
            }
            let restored = CIImage(cvPixelBuffer: generated)
                .transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
                .transformed(by: CGAffineTransform(translationX: crop.minX, y: crop.minY))
            let feather = CIImage(color: .white).cropped(to: rect)
                .composited(over: CIImage(color: .black))
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.2])
                .cropped(to: rect.insetBy(dx: -2, dy: -2).intersection(canvas))
            image = restored.applyingFilter(
                "CIBlendWithMask",
                parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: feather])
            // 模型输出会复用内部存储，立即落入当前帧后再处理下一区域。
            let target = try Self.buffer(width: Int(canvas.width), height: Int(canvas.height))
            context.render(image, to: target, bounds: canvas, colorSpace: colorSpace)
            try preserveOutside(
                result, in: target, changed: rect.insetBy(dx: -2, dy: -2).intersection(canvas).integral)
            result = target
            image = CIImage(cvPixelBuffer: result)
        }
        return result
    }

    /// 业务作用: 保留补全框外的原始解码像素，避免颜色空间往返影响整幅画面。
    /// 参数说明:
    /// - source: 当前区域处理之前的画面。
    /// - target: 已写入重建结果的独立缓冲。
    /// - changed: 允许变化的 Core Image 像素范围，包含羽化边缘。
    /// 返回: 只有指定范围保留新像素；锁定失败时不交付当前帧。
    private func preserveOutside(_ source: CVPixelBuffer, in target: CVPixelBuffer, changed: CGRect) throws {
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else {
            throw RecorderError.message("无法读取补全框外的原始像素。")
        }
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard CVPixelBufferLockBaseAddress(target, []) == kCVReturnSuccess else {
            throw RecorderError.message("无法保留补全框外的原始像素。")
        }
        defer {
            CVPixelBufferUnlockBaseAddress(target, [])
        }
        guard let original = CVPixelBufferGetBaseAddress(source),
            let destination = CVPixelBufferGetBaseAddress(target)
        else {
            throw RecorderError.message("补全画面缺少可访问的像素。")
        }
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let lower = height - Int(changed.maxY)
        let upper = height - Int(changed.minY)
        for row in 0..<height {
            let from = original.advanced(by: row * CVPixelBufferGetBytesPerRow(source))
            let to = destination.advanced(by: row * CVPixelBufferGetBytesPerRow(target))
            if row < lower || row >= upper {
                memcpy(to, from, width * 4)
            } else {
                let left = Int(changed.minX) * 4
                let right = Int(changed.maxX) * 4
                memcpy(to, from, left)
                memcpy(to.advanced(by: right), from.advanced(by: right), width * 4 - right)
            }
        }
        CVBufferPropagateAttachments(source, target)
    }
}

enum MovieWatermarkProcessor {
    /// 业务作用: 将来源时间上的框映射到拼接时间线，只处理当前保留片段内的交集。
    /// 参数说明:
    /// - clips: 已排序、可包含剪切和分割的片段。
    /// 返回: 输出时间线的左闭右开时段；片段外的设置不生效。
    static func intervals(_ clips: [MovieClip]) -> [MovieWatermarkInterval] {
        var cursor = CMTime.zero
        var result: [MovieWatermarkInterval] = []
        for clip in clips {
            for region in clip.watermarks {
                let overlap = CMTimeRangeGetIntersection(region.range, otherRange: clip.range)
                if overlap.duration > .zero {
                    result.append(
                        MovieWatermarkInterval(
                            range: CMTimeRange(
                                start: cursor + overlap.start - clip.range.start, duration: overlap.duration),
                            rect: region.pixelRect(
                                size: clip.source.info.size, transform: clip.source.info.transform)))
                }
            }
            cursor = cursor + clip.range.duration
        }
        return result
    }

    /// 业务作用: 为预览和导出生成同一套补全画面，再接回原始声音时间线。
    /// 参数说明:
    /// - composition: 已按片段顺序建立的合成。
    /// - clips: 与合成一致的来源及水印时段。
    /// - destination: 本次独占的临时视频位置。
    /// - progress: 逐帧处理进度和用户说明。
    /// 返回: 无有效框时保留原合成；有框时返回重编码视频和原声音，不改动来源。
    static func prepare(
        _ composition: AVComposition, clips: [MovieClip], to destination: URL,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> AVComposition {
        let entries = intervals(clips)
        guard !entries.isEmpty else {
            return composition
        }
        try Task.checkCancellation()
        progress(0, "正在加载本地画面补全模型…")
        let model = try MovieInpainter()
        let duration = try await composition.load(.duration)
        guard let track = try await composition.loadTracks(withMediaType: .video).first else {
            throw RecorderError.message("没有可补全的视频轨道。")
        }
        let descriptions = try await track.load(.formatDescriptions)
        // 八位补全不能静默抹掉 HDR 的亮度和色域，遇到此来源要求先转换为 SDR。
        for description in descriptions {
            let extensions = CMFormatDescriptionGetExtensions(description) as NSDictionary?
            let transfer = extensions?[kCMFormatDescriptionExtension_TransferFunction] as? String
            guard transfer != (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String),
                transfer != (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
            else {
                throw RecorderError.message("画面补全目前支持 SDR 视频，请先把 HDR 来源转换为 SDR。")
            }
        }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        var scales = [duration.timescale, try await track.load(.naturalTimeScale)]
        for clip in clips {
            scales.append(contentsOf: [
                clip.range.start.timescale, clip.range.duration.timescale,
                try await clip.source.info.video.load(.naturalTimeScale),
            ])
        }
        let timeScale = try MovieTime.commonScale(scales)
        let reader = try AVAssetReader(asset: composition)
        reader.timeRange = CMTimeRange(start: .zero, duration: duration)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
        output.alwaysCopiesSampleData = true
        guard reader.canAdd(output) else {
            throw RecorderError.message("无法解码需要补全的画面。")
        }
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        writer.movieTimeScale = timeScale
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: max(6_000_000, Int(size.width * size.height * 4)),
                    AVVideoAllowFrameReorderingKey: false,
                ],
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
            ])
        input.transform = transform
        // 容器和视频轨道使用来源刻度的公倍数，不能使用默认的低精度刻度量化可变帧率。
        input.mediaTimeScale = timeScale
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ])
        guard writer.canAdd(input) else {
            throw RecorderError.message("无法为当前画布建立 HEVC 补全输出。")
        }
        writer.add(input)
        var finished = false
        defer {
            reader.cancelReading()
            if !finished {
                writer.cancelWriting()
            }
        }
        guard reader.startReading(), writer.startWriting() else {
            throw reader.error ?? writer.error ?? RecorderError.message("无法开始画面补全。")
        }
        writer.startSession(atSourceTime: .zero)
        var previous = CMTime.invalid
        var frames = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let time = sample.presentationTimeStamp
            guard time.isNumeric, !previous.isValid || time > previous,
                let pixels = sample.imageBuffer
            else {
                throw RecorderError.message("来源画面的播放时间不连续，未生成补全成品。")
            }
            let rects = entries.filter { time >= $0.range.start && time < $0.range.end }.map(\.rect)
            let processed = try autoreleasepool {
                try rects.isEmpty ? pixels : model.process(pixels, rects: rects)
            }
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                guard writer.status == .writing else {
                    throw writer.error ?? RecorderError.message("补全视频写入中断。")
                }
                try await Task.sleep(for: .milliseconds(2))
            }
            guard adaptor.append(processed, withPresentationTime: time) else {
                throw writer.error ?? RecorderError.message("补全画面未能写入。")
            }
            previous = time
            frames += 1
            progress(
                min(1, time.seconds / duration.seconds),
                "正在补全画面 · \(MovieTime.string(time)) / \(MovieTime.string(duration))")
        }
        guard reader.status == .completed, frames > 0 else {
            throw reader.error ?? RecorderError.message("补全画面读取未完成。")
        }
        try Task.checkCancellation()
        input.markAsFinished()
        writer.endSession(atSourceTime: duration)
        await writer.finishWriting()
        try Task.checkCancellation()
        guard writer.status == .completed else {
            throw writer.error ?? RecorderError.message("补全视频封装未完成。")
        }
        let rendered = AVURLAsset(url: destination)
        guard let video = try await rendered.loadTracks(withMediaType: .video).first,
            abs((try await rendered.load(.duration) - duration).seconds) < 0.1
        else {
            throw RecorderError.message("补全画面时长不完整，未生成成品。")
        }
        let result = composition.mutableCopy() as! AVMutableComposition
        for old in result.tracks(withMediaType: .video) {
            result.removeTrack(old)
        }
        guard
            let replacement = result.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else {
            throw RecorderError.message("无法将补全画面接回声音时间线。")
        }
        try replacement.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: video, at: .zero)
        replacement.preferredTransform = transform
        finished = true
        progress(1, "画面补全完成。")
        return result.copy() as! AVComposition
    }
}
