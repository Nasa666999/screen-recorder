import AVFoundation
import CoreImage
import CoreML

enum MovieInpaintingConcurrency: Int, CaseIterable, Sendable {
    case automatic = 0
    case single = 1
    case two = 2
    case four = 4

    static let preferenceKey = "movieEditor.inpaintingConcurrency"

    /// 业务作用: 在界面区分自动测量与手动任务上限，不提供质量档位。
    /// 参数说明: 无。
    /// 返回: 仅描述并发调度方式的菜单文字。
    var title: String {
        switch self {
        case .automatic:
            return "并发：自动测量"
        case .single:
            return "并发：最多 1 路"
        case .two:
            return "并发：最多 2 路"
        case .four:
            return "并发：最多 4 路"
        }
    }

    /// 业务作用: 读取只影响任务调度的偏好，所有并发数使用同一精细模型。
    /// 参数说明: 无。
    /// 返回: 未设置或值不受支持时自动测量，不改变画面补全算法。
    static func selected() -> Self {
        Self(rawValue: UserDefaults.standard.integer(forKey: preferenceKey)) ?? .automatic
    }
}

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

struct MovieDecodedFrame: @unchecked Sendable {
    let sample: CMSampleBuffer
}

struct MovieProcessedFrame: @unchecked Sendable {
    let pixels: CVPixelBuffer
    let time: CMTime
}

// 每个任务独占模型和输入缓冲，同一任务内按来源顺序处理自己的连续小段。
final class MovieInpaintingWorker: @unchecked Sendable {
    private let model: MovieInpainter

    /// 业务作用: 为一个处理任务建立独立模型上下文，避免并发改写模型输入缓冲。
    /// 参数说明: 无。
    /// 返回: 加载完整精度模型；资源不可用或已取消时停止准备。
    init() throws {
        try Task.checkCancellation()
        model = try MovieInpainter()
    }

    /// 业务作用: 顺序重建分配给本任务的连续帧段，不直接写入公共编码器。
    /// 参数说明:
    /// - frames: 一个有限小段的来源画面。
    /// - intervals: 完整拼接时间线上的区域设置。
    /// 返回: 结果保持段内帧顺序，原始时间戳不变；取消或推理失败时抛错。
    func process(_ frames: [MovieDecodedFrame], intervals: [MovieWatermarkInterval]) throws
        -> [MovieProcessedFrame]
    {
        var result: [MovieProcessedFrame] = []
        for frame in frames {
            try Task.checkCancellation()
            let sample = frame.sample
            guard let pixels = sample.imageBuffer else {
                throw RecorderError.message("来源画面缺少可用像素。")
            }
            let time = sample.presentationTimeStamp
            let active = intervals.filter { time >= $0.range.start && time < $0.range.end }
            let processed = try autoreleasepool {
                try model.process(pixels, rects: active.map(\.rect))
            }
            result.append(MovieProcessedFrame(pixels: processed, time: time))
        }
        return result
    }

    /// 业务作用: 用同一帧和当前精细补全路径测量调度吞吐量，不发布测量画面。
    /// 参数说明:
    /// - frame: 有限缓存内的一个来源画面。
    /// - rect: 当前计划中的一个真实补全框。
    /// - count: 本任务顺序执行的测量次数。
    /// 返回: 测量结束释放中间画面；取消或模型失败时抛错。
    func measure(_ frame: MovieDecodedFrame, rect: CGRect, count: Int) throws {
        guard let pixels = frame.sample.imageBuffer else {
            throw RecorderError.message("来源画面缺少可用像素。")
        }
        for _ in 0..<count {
            try Task.checkCancellation()
            try autoreleasepool {
                _ = try model.process(pixels, rects: [rect])
            }
        }
    }
}

// 单个消费者依次取帧，解码端最多只领先一帧，不能按视频长度积压像素。
final class MovieFrameDecoder: @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var pending: Task<MovieDecodedFrame?, Never>?

    /// 业务作用: 在独立任务预取下一帧，让解码与当前帧的模型计算重叠。
    /// 参数说明:
    /// - reader: 本次独占的离线读取器。
    /// - output: 已启动的原始画面输出，只允许一个预取任务访问。
    /// 返回: 最多持有一个预取帧，不改变来源的帧顺序。
    init(reader: AVAssetReader, output: AVAssetReaderTrackOutput) {
        self.reader = reader
        self.output = output
        schedule()
    }

    /// 业务作用: 交付已预取的画面，并在消费者开始计算前启动下一次解码。
    /// 参数说明: 无。
    /// 返回: 按来源顺序交付一帧，读到末端返回空，取消不交付迟到画面。
    func next() async throws -> CMSampleBuffer? {
        try Task.checkCancellation()
        let frame = await pending?.value
        try Task.checkCancellation()
        if frame != nil {
            schedule()
        } else {
            pending = nil
        }
        return frame?.sample
    }

    /// 业务作用: 取消尚未交付的预取，阻止关闭后继续读取来源。
    /// 参数说明: 无。
    /// 返回: 读取器停止，已交付帧由消费者正常释放。
    func cancel() {
        pending?.cancel()
        reader.cancelReading()
        pending = nil
    }

    /// 业务作用: 创建唯一的下一帧解码任务，不与同一输出的其它读取并发。
    /// 参数说明: 无。
    /// 返回: 解码等待不占用模型处理所在的执行线程。
    private func schedule() {
        let output = output
        pending = Task.detached(priority: .utility) {
            guard !Task.isCancelled, let sample = output.copyNextSampleBuffer() else {
                return nil
            }
            return MovieDecodedFrame(sample: sample)
        }
    }
}

// 模型和中间像素仅由单个离线任务使用，不与录制媒体队列共享。
final class MovieInpainter {
    private let model: MLModel
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let edge: Int
    private let imageBuffer: CVPixelBuffer
    private let maskBuffer: CVPixelBuffer
    private let localURL: URL?
    private var localModel: MLModel?
    private var localOrigin: MLMultiArray?
    /// 业务作用: 从应用随附资源加载本地精细补全模型，不把用户画面发送到网络。
    /// 参数说明: 无。
    /// 返回: 使用固定的 800×800 全精度模型；资源缺失或格式不符时明确失败。
    init() throws {
        guard let url = Bundle.main.url(forResource: "LaMa", withExtension: "mlmodelc") else {
            throw RecorderError.message("应用缺少本地补全模型，请安装包含 LaMa 模型的完整应用。")
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        configuration.allowLowPrecisionAccumulationOnGPU = false
        model = try MLModel(contentsOf: url, configuration: configuration)
        let inputs = model.modelDescription.inputDescriptionsByName
        guard let image = inputs["image"]?.imageConstraint,
            let mask = inputs["mask"]?.imageConstraint,
            image.pixelsWide == 800, image.pixelsHigh == 800,
            mask.pixelsWide == 800, mask.pixelsHigh == 800
        else {
            throw RecorderError.message("本地精细补全模型的输入格式不受支持。")
        }
        edge = 800
        imageBuffer = try Self.buffer(width: edge, height: edge, format: image.pixelFormatType)
        maskBuffer = try Self.buffer(width: edge, height: edge, format: mask.pixelFormatType)
        localURL = Bundle.main.url(forResource: "LocalLaMa", withExtension: "mlmodelc")
    }

    /// 业务作用: 将完整输入与全局特征保留，只省去不会影响选区的末端重建计算。
    /// 参数说明:
    /// - maskRect: 八百像素模型输入中的左下角掩码位置。
    /// - scale: 来源像素映射到模型输入的比例，用于保留羽化与采样边缘。
    /// 返回: 保持八百像素输出栅格的模型画面；范围不足时执行完整重建。
    private func predict(maskRect: CGRect, scale: CGFloat) throws -> CVPixelBuffer {
        var values = [
            "image": MLFeatureValue(pixelBuffer: imageBuffer),
            "mask": MLFeatureValue(pixelBuffer: maskBuffer),
        ]
        let selected: MLModel
        let position: (top: Int, left: Int)?
        if let localURL, let window = localWindow(maskRect: maskRect, scale: scale) {
            if localModel == nil {
                let configuration = MLModelConfiguration()
                configuration.computeUnits = .cpuAndGPU
                configuration.allowLowPrecisionAccumulationOnGPU = false
                let loaded = try MLModel(contentsOf: localURL, configuration: configuration)
                guard
                    loaded.modelDescription.inputDescriptionsByName["image"]?.imageConstraint?.pixelsWide
                        == 800,
                    loaded.modelDescription.inputDescriptionsByName["mask"]?.imageConstraint?.pixelsHigh
                        == 800,
                    loaded.modelDescription.outputDescriptionsByName["output"]?.imageConstraint?.pixelsWide
                        == 384,
                    loaded.modelDescription.outputDescriptionsByName["output"]?.imageConstraint?.pixelsHigh
                        == 384
                else {
                    throw RecorderError.message("局部重建模型的输入或输出格式不受支持。")
                }
                let position = try MLMultiArray(shape: [2], dataType: .int32)
                localModel = loaded
                localOrigin = position
            }
            localOrigin![0] = NSNumber(value: window.top)
            localOrigin![1] = NSNumber(value: window.left)
            values["origin"] = MLFeatureValue(multiArray: localOrigin!)
            selected = localModel!
            position = (window.top, window.left)
        } else {
            // 任何所需像素超出安全窗口时保留完整末端，不能以缺少依赖边缘换取速度。
            selected = model
            position = nil
        }
        let features = try MLDictionaryFeatureProvider(dictionary: values)
        let prediction = try selected.prediction(from: features)
        guard let result = prediction.featureValue(for: "output")?.imageBufferValue else {
            throw RecorderError.message("本地补全模型没有产生可用画面。")
        }
        if let position {
            return try placeLocal(result, top: position.top * 8, left: position.left * 8)
        }
        return result
    }

    /// 业务作用: 把局部输出放回完整模型栅格，保持原有像素采样相位与混合变换。
    /// 参数说明:
    /// - pixels: 本次局部重建的独立输出。
    /// - top: 完整模型画面内从顶部开始的像素行。
    /// - left: 完整模型画面内从左侧开始的像素列。
    /// 返回: 当前任务独占的完整栅格；像素不可读写或格式不一致时停止本帧。
    private func placeLocal(_ pixels: CVPixelBuffer, top: Int, left: Int) throws -> CVPixelBuffer {
        guard CVPixelBufferGetWidth(pixels) == 384, CVPixelBufferGetHeight(pixels) == 384,
            CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA,
            CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess
        else {
            throw RecorderError.message("无法读取局部重建像素。")
        }
        defer {
            CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        }
        guard CVPixelBufferLockBaseAddress(imageBuffer, []) == kCVReturnSuccess else {
            throw RecorderError.message("无法写入完整补全栅格。")
        }
        defer {
            CVPixelBufferUnlockBaseAddress(imageBuffer, [])
        }
        guard let source = CVPixelBufferGetBaseAddress(pixels),
            let target = CVPixelBufferGetBaseAddress(imageBuffer)
        else {
            throw RecorderError.message("补全栅格缺少可访问的像素。")
        }
        for row in 0..<384 {
            memcpy(
                target.advanced(by: (top + row) * CVPixelBufferGetBytesPerRow(imageBuffer) + left * 4),
                source.advanced(by: row * CVPixelBufferGetBytesPerRow(pixels)), 384 * 4)
        }
        return imageBuffer
    }

    /// 业务作用: 为局部重建选择对齐八像素的窗口，并验证全部选区依赖都在其中。
    /// 参数说明:
    /// - maskRect: 完整模型输入中的掩码范围。
    /// - scale: 来源与模型的像素比例。
    /// 返回: 可保真处理时返回模型网格位置及左下角原点，否则要求完整重建。
    private func localWindow(maskRect: CGRect, scale: CGFloat) -> (top: Int, left: Int, origin: CGPoint)? {
        let full = CGRect(x: 0, y: 0, width: 800, height: 800)
        let left = min(52, max(0, Int(((maskRect.midX - 192) / 8).rounded())))
        let top = min(52, max(0, Int(((800 - maskRect.midY - 192) / 8).rounded())))
        let origin = CGPoint(x: left * 8, y: 800 - top * 8 - 384)
        let window = CGRect(origin: origin, size: CGSize(width: 384, height: 384))
        // 三层步长二的三像素转置卷积与七像素输出卷积具有有限依赖，保留三十二像素边缘。
        // 与完整画面重合的边界沿用同一反射填充，内部新边界则不能影响任何混合采样。
        let safe = CGRect(
            x: window.minX == 0 ? 0 : window.minX + 32,
            y: window.minY == 0 ? 0 : window.minY + 32,
            width: window.width - (window.minX == 0 ? 0 : 32) - (window.maxX == 800 ? 0 : 32),
            height: window.height - (window.minY == 0 ? 0 : 32) - (window.maxY == 800 ? 0 : 32))
        let required = maskRect.insetBy(dx: -2 * scale - 2, dy: -2 * scale - 2).intersection(full)
        guard safe.contains(required) else {
            return nil
        }
        return (top, left, origin)
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
            let generated = try predict(maskRect: maskRect, scale: scale)
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
    /// 业务作用: 为连续帧段分配独立模型，自动模式按本机实测吞吐量选择并发数。
    /// 参数说明:
    /// - concurrency: 用户指定的调度方式，不影响模型、精度或逐帧算法。
    /// - maximum: 由像素缓存、物理内存和处理器数量共同限制的任务上限。
    /// - duration: 短视频省略测量，避免测量时间超过处理收益。
    /// - frame: 所有候选并发数共用的测量画面。
    /// - rect: 所有候选共用的真实补全位置。
    /// - progress: 模型加载与吞吐量测量的用户说明。
    /// 返回: 独立模型任务，执行自动测量时已预热；测量画面不进入输出，取消或模型失败时抛错。
    private static func selectWorkers(
        concurrency: MovieInpaintingConcurrency, maximum: Int, duration: CMTime,
        frame: MovieDecodedFrame, rect: CGRect,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> [MovieInpaintingWorker] {
        let automatic = concurrency == .automatic
        let limit = automatic ? (duration.seconds >= 30 ? maximum : 1) : min(maximum, concurrency.rawValue)
        let candidates = [1, 2, 4].filter { $0 <= limit }
        let count = automatic ? candidates.last! : limit
        let workers = try (0..<count).map { _ in
            try MovieInpaintingWorker()
        }
        guard automatic, count > 1 else {
            return workers
        }
        progress(0, "正在测量精细补全并发数…")
        // 先预热每个独立模型，再以相同画面和相同总工作量比较，避免冷启动偏向某一路。
        for worker in workers {
            try worker.measure(frame, rect: rect, count: 1)
        }
        var selected = 1
        var best = Double.infinity
        for lanes in candidates {
            try Task.checkCancellation()
            let began = Date()
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<lanes {
                    let worker = workers[index]
                    group.addTask {
                        try worker.measure(frame, rect: rect, count: count / lanes)
                    }
                }
                try await group.waitForAll()
            }
            let elapsed = Date().timeIntervalSince(began)
            // 共享 GPU 可能使更多任务更慢；只有超过测量波动的收益才增加并发。
            if elapsed < best * 0.9 {
                best = elapsed
                selected = lanes
            }
            progress(0, "正在测量精细补全并发数 · \(lanes) 路 · \(String(format: "%.1f", Double(count) / elapsed)) 帧/秒")
        }
        return Array(workers.prefix(selected))
    }

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
        let concurrency = MovieInpaintingConcurrency.selected()
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
        // 帧缓存预算同时计入输入、输出和一个预取帧；模型工作内存不计入这个像素预算。
        let bytesPerFrame = max(1, Int(size.width) * Int(size.height) * 4)
        let frameBudget = max(1, (192 * 1024 * 1024 / bytesPerFrame - 1) / 2)
        let memoryLanes = max(1, Int(ProcessInfo.processInfo.physicalMemory / (4 * 1024 * 1024 * 1024)))
        let maximumLanes = min(4, frameBudget, memoryLanes, ProcessInfo.processInfo.activeProcessorCount)
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
        let decoder = MovieFrameDecoder(reader: reader, output: output)
        defer {
            decoder.cancel()
        }
        var pendingFirst = try await decoder.next()
        let workers: [MovieInpaintingWorker]
        do {
            guard let first = pendingFirst else {
                throw reader.error ?? RecorderError.message("来源视频没有可用画面。")
            }
            workers = try await selectWorkers(
                concurrency: concurrency, maximum: maximumLanes, duration: duration,
                frame: MovieDecodedFrame(sample: first), rect: entries[0].rect, progress: progress)
        }
        let laneCount = workers.count
        let batchSize = min(4, max(1, frameBudget / laneCount))
        let began = Date()
        var previous = CMTime.invalid
        var frames = 0
        var exhausted = false
        while !exhausted {
            var batches: [[MovieDecodedFrame]] = []
            for _ in 0..<laneCount {
                var batch: [MovieDecodedFrame] = []
                for _ in 0..<batchSize {
                    let next: CMSampleBuffer?
                    if let first = pendingFirst {
                        next = first
                        pendingFirst = nil
                    } else {
                        next = try await decoder.next()
                    }
                    guard let sample = next else {
                        exhausted = true
                        break
                    }
                    let time = sample.presentationTimeStamp
                    guard time.isNumeric, !previous.isValid || time > previous else {
                        throw RecorderError.message("来源画面的播放时间不连续，未生成补全成品。")
                    }
                    previous = time
                    batch.append(MovieDecodedFrame(sample: sample))
                }
                batches.append(batch)
            }
            let processed = try await withThrowingTaskGroup(of: (Int, [MovieProcessedFrame]).self) { group in
                for index in batches.indices where !batches[index].isEmpty {
                    let batch = batches[index]
                    let worker = workers[index]
                    group.addTask {
                        (index, try worker.process(batch, intervals: entries))
                    }
                }
                var ordered = [[MovieProcessedFrame]](repeating: [], count: laneCount)
                for try await (index, result) in group {
                    ordered[index] = result
                }
                return ordered
            }
            // 任务完成先后不能决定写入顺序，统一按来源段号和段内帧号交付唯一编码器。
            for batch in processed {
                for frame in batch {
                    try Task.checkCancellation()
                    while !input.isReadyForMoreMediaData {
                        try Task.checkCancellation()
                        guard writer.status == .writing else {
                            throw writer.error ?? RecorderError.message("补全视频写入中断。")
                        }
                        try await Task.sleep(for: .milliseconds(2))
                    }
                    guard adaptor.append(frame.pixels, withPresentationTime: frame.time) else {
                        throw writer.error ?? RecorderError.message("补全画面未能写入。")
                    }
                    frames += 1
                    progress(
                        min(1, frame.time.seconds / duration.seconds),
                        "正在补全画面 · \(MovieTime.string(frame.time)) / \(MovieTime.string(duration)) · \(laneCount) 路 · \(String(format: "%.1f", Double(frames) / max(0.001, Date().timeIntervalSince(began)))) 帧/秒"
                    )
                }
            }
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
