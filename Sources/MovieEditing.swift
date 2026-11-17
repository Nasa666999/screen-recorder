import AVFoundation
import AppKit
import Darwin

struct MovieFileIdentity {
    let identifier: NSObject
    let modified: Date
    let size: Int

    /// 业务作用: 固定剪辑来源的文件身份与内容状态，避免同路径文件被替换后继续导出。
    /// 参数说明:
    /// - url: 用户选择的视频文件。
    /// 返回: 普通文件的身份快照；元数据不完整或文件不可读时抛错。
    static func read(_ url: URL) throws -> MovieFileIdentity {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey, .fileResourceIdentifierKey, .contentModificationDateKey, .fileSizeKey,
        ])
        guard values.isRegularFile == true,
            let identifier = values.fileResourceIdentifier as? NSObject,
            let modified = values.contentModificationDate, let size = values.fileSize, size > 0
        else {
            throw RecorderError.message("无法读取视频文件的身份与大小：\(url.lastPathComponent)")
        }
        return MovieFileIdentity(
            identifier: identifier,
            modified: modified,
            size: size
        )
    }

    /// 业务作用: 将当前来源与导入快照比较，阻止旧剪辑范围应用到变化后的内容。
    /// 参数说明:
    /// - url: 需要重新读取身份的来源位置。
    /// 返回: 文件身份、修改时间与大小均一致时成功，否则要求重新导入。
    func validate(_ url: URL) throws {
        let current = try Self.read(url)
        guard current.identifier.isEqual(identifier), current.modified == modified, current.size == size
        else {
            throw RecorderError.message("来源视频已移动、修改或替换，请重新导入：\(url.lastPathComponent)")
        }
    }
}

struct MovieMediaInfo {
    let video: AVAssetTrack
    let audio: AVAssetTrack?
    let bounds: CMTimeRange
    let size: CGSize
    let transform: CGAffineTransform
    let codec: FourCharCode
    let frameRate: Float
}

// 来源在初始化后保持只读；AVFoundation 读取与文件身份复验可以在后台执行。
final class MovieSource: @unchecked Sendable {
    let url: URL
    let asset: AVURLAsset
    let info: MovieMediaInfo
    let identity: MovieFileIdentity
    private let scoped: Bool

    /// 业务作用: 持有一个已加载的剪辑来源及其目录访问，不把整部媒体读入内存。
    /// 参数说明:
    /// - url: 来源文件位置。
    /// - asset: 用于按需读取和直接拼接的媒体资产。
    /// - info: 已加载的视频轨道、声音轨道和原始画布规格。
    /// - identity: 导入时的文件身份快照。
    /// - scoped: 是否实际取得系统安全作用域访问。
    /// 返回: 来源可以被多个剪辑片段共享，最后一个引用释放后归还访问。
    private init(
        url: URL, asset: AVURLAsset, info: MovieMediaInfo, identity: MovieFileIdentity, scoped: Bool
    ) {
        self.url = url
        self.asset = asset
        self.info = info
        self.identity = identity
        self.scoped = scoped
    }

    /// 业务作用: 加载用户选择的视频元数据，拒绝无法明确保留原始视频轨道的输入。
    /// 参数说明:
    /// - url: 用户导入或从录后预览打开的视频。
    /// 返回: 单视频轨道、至多一条声音轨道的有效来源；读取期间改变文件也会失败。
    static func open(_ url: URL) async throws -> MovieSource {
        guard url.isFileURL else {
            throw RecorderError.message("请先将视频保存为本地文件再导入。")
        }
        let url = url.standardizedFileURL
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            let identity = try MovieFileIdentity.read(url)
            let asset = AVURLAsset(url: url)
            let videos = try await asset.loadTracks(withMediaType: .video)
            let audios = try await asset.loadTracks(withMediaType: .audio)
            guard videos.count == 1, audios.count <= 1 else {
                throw RecorderError.message("当前剪辑支持一条视频轨道和至多一条声音轨道：\(url.lastPathComponent)")
            }
            let video = videos[0]
            let bounds = try await video.load(.timeRange)
            let size = try await video.load(.naturalSize)
            let transform = try await video.load(.preferredTransform)
            let frameRate = try await video.load(.nominalFrameRate)
            let descriptions = try await video.load(.formatDescriptions)
            guard bounds.isValid, bounds.duration.isNumeric, bounds.duration > .zero,
                size.width > 0, size.height > 0, let description = descriptions.first,
                try await asset.load(.isComposable)
            else {
                throw RecorderError.message("视频没有可剪辑的有效画面：\(url.lastPathComponent)")
            }
            try identity.validate(url)
            return MovieSource(
                url: url,
                asset: asset,
                info: MovieMediaInfo(
                    video: video,
                    audio: audios.first,
                    bounds: bounds,
                    size: size,
                    transform: transform,
                    codec: CMFormatDescriptionGetMediaSubType(description),
                    frameRate: frameRate
                ),
                identity: identity,
                scoped: scoped
            )
        } catch {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
            throw error
        }
    }

    /// 业务作用: 归还来源实际取得的目录访问，不删除或修改来源文件。
    /// 参数说明: 无。
    /// 返回: 最后一个片段释放来源后结束安全作用域访问。
    deinit {
        if scoped {
            url.stopAccessingSecurityScopedResource()
        }
    }

    /// 业务作用: 分析、预览和导出前复验来源，拒绝使用已经变化的旧时间范围。
    /// 参数说明: 无。
    /// 返回: 文件身份、修改时间与大小一致时成功，否则抛错并要求重新导入。
    func validate() throws {
        // 已有编辑范围只能解释原来的内容，来源变动后不能把它们套用到新的文件。
        try identity.validate(url)
    }

    var frameRateDescription: String {
        info.frameRate > 0 ? String(format: "%.3g fps", info.frameRate) : "可变帧率"
    }
}

struct MovieClip: Identifiable, @unchecked Sendable {
    let id: UUID
    let source: MovieSource
    var range: CMTimeRange
    var watermarks: [MovieWatermarkRegion]

    /// 业务作用: 在来源上创建非破坏性的保留范围，多段可以共享同一个文件。
    /// 参数说明:
    /// - source: 已导入且持有访问权的视频。
    /// - range: 本片段保留的来源时间范围，空值表示完整视频。
    /// - watermarks: 以来源时间和显示画面坐标保存的补全区域。
    /// 返回: 新片段拥有独立列表身份，不复制视频数据。
    init(source: MovieSource, range: CMTimeRange? = nil, watermarks: [MovieWatermarkRegion] = []) {
        id = UUID()
        self.source = source
        self.range = range ?? source.info.bounds
        self.watermarks = watermarks
    }

    /// 业务作用: 在指定播放位置把一个保留范围分为连续的两段。
    /// 参数说明:
    /// - time: 来源视频时间线上的切分点。
    /// 返回: 两段按原顺序覆盖原范围；端点或越界切分会失败。
    func split(at time: CMTime) throws -> [MovieClip] {
        guard time.isNumeric, time > range.start, time < range.end else {
            throw RecorderError.message("请把播放位置移到片段内部再分割。")
        }
        let left = try MovieTime.selectionRange(start: range.start, end: time, within: source.info.bounds)
        let right = try MovieTime.selectionRange(start: left.end, end: range.end, within: source.info.bounds)
        return [
            MovieClip(
                source: source,
                range: left,
                watermarks: watermarks
            ),
            MovieClip(
                source: source,
                range: right,
                watermarks: watermarks
            ),
        ]
    }

    /// 业务作用: 从片段中删除选区，保留选区前后的有效段落。
    /// 参数说明:
    /// - selection: 本片段内需要删去的来源范围。
    /// 返回: 按原时间顺序返回零到两段，来源文件保持不变。
    func removing(_ selection: CMTimeRange) throws -> [MovieClip] {
        guard selection.isValid, selection.duration > .zero, selection.start >= range.start,
            selection.end <= range.end
        else {
            throw RecorderError.message("删除范围必须位于当前片段内。")
        }
        var result: [MovieClip] = []
        if selection.start > range.start {
            result.append(
                MovieClip(
                    source: source,
                    range: try MovieTime.selectionRange(
                        start: range.start, end: selection.start, within: source.info.bounds),
                    watermarks: watermarks
                ))
        }
        if selection.end < range.end {
            result.append(
                MovieClip(
                    source: source,
                    range: try MovieTime.selectionRange(
                        start: selection.end, end: range.end, within: source.info.bounds),
                    watermarks: watermarks
                ))
        }
        return result
    }

    /// 业务作用: 在合成之前验证保留范围和来源状态，阻止空片段或过期计划进入输出。
    /// 参数说明: 无。
    /// 返回: 来源有效且范围完全位于视频轨道内时成功，否则抛错。
    func validate() throws {
        try source.validate()
        guard range.isValid, range.start.isNumeric, range.duration.isNumeric, range.duration > .zero,
            range.start >= source.info.bounds.start, range.end <= source.info.bounds.end
        else {
            throw RecorderError.message("片段范围无效：\(source.url.lastPathComponent)")
        }
        for region in watermarks {
            try region.validate(within: source.info.bounds)
        }
    }

    var estimatedBytes: Double {
        Double(source.identity.size) * range.duration.seconds / source.info.bounds.duration.seconds
    }
}

// 合成完成后发布不可变副本，后台导出与主线程预览不能同时修改轨道。
struct MovieComposition: @unchecked Sendable {
    let asset: AVComposition
    let joins: [CMTime]
    let hasAudio: Bool
}

enum MovieEditExporter {
    /// 业务作用: 按列表顺序直接连接来源轨道，保持各段原始帧时序和压缩数据。
    /// 参数说明:
    /// - clips: 已确认保留的有序片段。
    /// 返回: 可预览和无重编码导出的合成；画布、方向或编码不兼容时明确失败。
    static func compose(_ clips: [MovieClip]) async throws -> MovieComposition {
        guard let first = clips.first else {
            throw RecorderError.message("请先添加需要剪辑的视频。")
        }
        let composition = AVMutableComposition()
        guard
            let video = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else {
            throw RecorderError.message("无法创建拼接视频轨道。")
        }
        video.preferredTransform = first.source.info.transform
        let hasAudio = clips.contains { $0.source.info.audio != nil }
        let audio =
            hasAudio
            ? composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        var cursor = CMTime.zero
        var joins: [CMTime] = []
        for (index, clip) in clips.enumerated() {
            try Task.checkCancellation()
            try clip.validate()
            let info = clip.source.info
            // 保留原始视频数据时不能靠重新缩放或旋转掩盖不兼容的轨道，帧率不同则仍可保留各段时序。
            guard info.size == first.source.info.size, info.transform == first.source.info.transform,
                info.codec == first.source.info.codec
            else {
                throw RecorderError.message(
                    "保留原画质拼接要求视频的尺寸、方向和编码一致；帧率可以不同。请检查：\(clip.source.url.lastPathComponent)")
            }
            if index > 0 {
                joins.append(cursor)
            }
            try video.insertTimeRange(clip.range, of: info.video, at: cursor)
            if let audio {
                let audioBounds = try await info.audio?.load(.timeRange)
                let intersection = audioBounds.map { CMTimeRangeGetIntersection($0, otherRange: clip.range) }
                if let sourceAudio = info.audio, let intersection, intersection.duration > .zero {
                    let leading = intersection.start - clip.range.start
                    if leading > .zero {
                        audio.insertEmptyTimeRange(
                            CMTimeRange(
                                start: cursor,
                                duration: leading
                            ))
                    }
                    try audio.insertTimeRange(intersection, of: sourceAudio, at: cursor + leading)
                    let trailing = clip.range.end - intersection.end
                    if trailing > .zero {
                        audio.insertEmptyTimeRange(
                            CMTimeRange(
                                start: cursor + clip.range.duration - trailing,
                                duration: trailing
                            ))
                    }
                } else {
                    audio.insertEmptyTimeRange(
                        CMTimeRange(
                            start: cursor,
                            duration: clip.range.duration
                        ))
                }
            }
            cursor = cursor + clip.range.duration
        }
        return MovieComposition(
            asset: composition.copy() as! AVComposition,
            joins: joins,
            hasAudio: hasAudio
        )
    }

    /// 业务作用: 导出新的 MOV 文件，按计划补全画面、调整声音且不覆盖任何已有文件。
    /// 参数说明:
    /// - clips: 用户确认的有序保留范围。
    /// - destination: 用户选择的新文件位置。
    /// - audioAdjustment: 导出时的音量处理方式，默认保留原始声音。
    /// - preparedPreview: 可选的完整预览，仅在计划与声音设置完全一致时复用媒体。
    /// - progress: 导出进度回调，运行在后台任务中。
    /// - audioProgress: 声音检查与处理期间的用户说明。
    /// 返回: 完整验证并独占发布后返回目标位置；失败或取消只清理本次临时文件。
    static func export(
        _ clips: [MovieClip], to destination: URL,
        audioAdjustment: MovieAudioAdjustment = .original,
        preparedPreview: MoviePreview? = nil,
        progress: @escaping @Sendable (Double) -> Void,
        audioProgress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> URL {
        let destination = destination.standardizedFileURL
        guard !FileManager.default.fileExists(atPath: destination.path),
            !clips.contains(where: { $0.source.url == destination })
        else {
            throw RecorderError.message("请使用新的文件名，导出不会覆盖已有视频。")
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".ScreenRecorder-edit-\(UUID().uuidString).partial.mov")
        let audioURL = destination.deletingLastPathComponent().appendingPathComponent(
            ".ScreenRecorder-audio-\(UUID().uuidString).m4a")
        let videoURL = destination.deletingLastPathComponent().appendingPathComponent(
            ".ScreenRecorder-inpaint-\(UUID().uuidString).mov")
        defer {
            try? FileManager.default.removeItem(at: temporary)
            try? FileManager.default.removeItem(at: audioURL)
            try? FileManager.default.removeItem(at: videoURL)
        }
        let composition = try await compose(clips)
        let enhanced = audioAdjustment != .original && composition.hasAudio
        let inpainting = !MovieWatermarkProcessor.intervals(clips).isEmpty
        let reusable = preparedPreview?.matches(clips, adjustment: audioAdjustment) == true
        let videoWeight = inpainting && !reusable ? 0.85 : 0.0
        let audioWeight = enhanced && !reusable ? (inpainting ? 0.10 : 0.65) : 0.0
        let asset: AVComposition
        if reusable, let preparedPreview {
            // 持有预览直到导出结束，防止临时媒体在封装期间被播放器切换释放。
            asset = preparedPreview.asset
            audioProgress("正在使用已确认的预览画面与声音封装新视频…")
        } else {
            let video = try await MovieWatermarkProcessor.prepare(
                composition.asset, clips: clips, to: videoURL
            ) { value, message in
                progress(value * videoWeight)
                audioProgress(message)
            }
            asset = try await MovieAudioEnhancer.prepare(
                asset: video, adjustment: audioAdjustment, audioURL: audioURL
            ) { value, message in
                progress(videoWeight + value * audioWeight)
                audioProgress(message)
            }
        }
        guard
            let exporter = AVAssetExportSession(
                asset: asset,
                presetName: AVAssetExportPresetPassthrough
            )
        else {
            throw RecorderError.message("当前片段无法保留原始视频数据导出。")
        }
        guard await exporter.compatibleFileTypes.contains(.mov) else {
            throw RecorderError.message("这些片段无法直接拼接为 MOV，原视频保持不变。")
        }
        exporter.metadata = try await clips[0].source.asset.load(.metadata)
        let monitor = Task {
            for await state in exporter.states(updateInterval: 0.2) {
                if case .exporting(let value) = state {
                    progress(
                        videoWeight + audioWeight + value.fractionCompleted * (1 - videoWeight - audioWeight))
                }
            }
        }
        defer {
            monitor.cancel()
        }
        try await exporter.export(to: temporary, as: .mov)
        try Task.checkCancellation()
        let result = AVURLAsset(url: temporary)
        let duration = try await result.load(.duration)
        let expected = clips.reduce(CMTime.zero) { $0 + $1.range.duration }
        let videos = try await result.loadTracks(withMediaType: .video)
        let audios = try await result.loadTracks(withMediaType: .audio)
        guard duration.isNumeric, abs((duration - expected).seconds) < 0.1,
            videos.count == 1, audios.count == (composition.hasAudio ? 1 : 0),
            try await result.load(.isPlayable)
        else {
            throw RecorderError.message("导出结果的轨道或时长不完整，未发布为成品。")
        }
        for clip in clips {
            try clip.source.validate()
        }
        try Task.checkCancellation()
        // 验证与取消检查完成后才发布；独占重命名可阻止导出期间出现的同名文件被覆盖。
        guard renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw RecorderError.message("新视频未能保存：\(String(cString: strerror(errno)))。请选择新的文件名或位置。")
        }
        progress(1)
        return destination
    }
}

enum MovieTime {
    /// 业务作用: 为重编码选择能精确表达来源帧和剪切边界的公共时间刻度。
    /// 参数说明:
    /// - scales: 所有来源、剪切范围与合成使用的有效刻度。
    /// 返回: 不超过媒体格式上限的最小公倍数；无法无损组合时明确拒绝。
    static func commonScale(_ scales: [CMTimeScale]) throws -> CMTimeScale {
        var result: Int64 = 1
        for scale in scales {
            guard scale > 0 else {
                throw RecorderError.message("来源包含无效的媒体时间刻度。")
            }
            var a = result
            var b = Int64(scale)
            while b != 0 {
                (a, b) = (b, a % b)
            }
            let next = (result / a) * Int64(scale)
            guard next <= Int64(Int32.max) else {
                throw RecorderError.message("这些来源的时间精度无法组合为同一补全视频，请分别处理来源。")
            }
            result = next
        }
        return CMTimeScale(result)
    }

    /// 业务作用: 将播放位置和来源边界放到同一编辑刻度，避免时间范围运算把合法末端舍入到来源之外。
    /// 参数说明:
    /// - start: 已限定在来源内的选区起点，可以来自播放器的纳秒时间线。
    /// - end: 已限定在来源内的选区终点。
    /// - bounds: 来源视频的有效时间范围，决定需要保留的末端精度。
    /// 返回: 起止点使用同一刻度且位于来源内的非空范围；非法或不足一个刻度的范围抛错。
    static func selectionRange(start: CMTime, end: CMTime, within bounds: CMTimeRange) throws -> CMTimeRange {
        guard bounds.isValid, bounds.start.isNumeric, bounds.end.isNumeric,
            start.isNumeric, end.isNumeric, start >= bounds.start, end <= bounds.end, end > start
        else {
            throw RecorderError.message("选区需要位于视频范围内，且终点晚于起点。")
        }
        // 来源末端的刻度倍数能精确保留末端，至少 48 kHz 则避免整数秒来源把剪切位置量化得过粗。
        let base = Int64(bounds.end.timescale)
        let scale = Int32(base * max(1, (48_000 + base - 1) / base))
        let lower = CMTimeConvertScale(bounds.start, timescale: scale, method: .roundTowardPositiveInfinity)
        let upper = CMTimeConvertScale(bounds.end, timescale: scale, method: .roundTowardNegativeInfinity)
        let normalizedStart = max(
            lower, CMTimeConvertScale(start, timescale: scale, method: .roundHalfAwayFromZero))
        let normalizedEnd = min(
            upper, CMTimeConvertScale(end, timescale: scale, method: .roundHalfAwayFromZero))
        guard normalizedEnd > normalizedStart else {
            throw RecorderError.message("选区过短，请至少保留一个有效时间刻度。")
        }
        return CMTimeRange(start: normalizedStart, end: normalizedEnd)
    }

    /// 业务作用: 将来源或合成时间显示为可编辑的时分秒。
    /// 参数说明:
    /// - time: 媒体时间。
    /// 返回: 毫秒精度的时间文本，不改变实际保留范围的精度。
    static func string(_ time: CMTime) -> String {
        guard time.isNumeric else {
            return "00:00.000"
        }
        let milliseconds = max(0, Int64((time.seconds * 1000).rounded()))
        let hours = milliseconds / 3_600_000
        let minutes = milliseconds / 60_000 % 60
        let seconds = milliseconds / 1000 % 60
        return hours > 0
            ? String(format: "%02lld:%02lld:%02lld.%03lld", hours, minutes, seconds, milliseconds % 1000)
            : String(format: "%02lld:%02lld.%03lld", minutes, seconds, milliseconds % 1000)
    }

    /// 业务作用: 解析剪辑界面的秒数或时分秒输入，拒绝负值与无效时间。
    /// 参数说明:
    /// - text: 秒、分秒或时分秒文本，允许小数秒。
    /// 返回: 有效的媒体时间；无法解释的输入返回空。
    static func parse(_ text: String) -> CMTime? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(
            separator: ":", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 3 else {
            return nil
        }
        var seconds = 0.0
        for (index, part) in parts.enumerated() {
            guard let number = Double(part), number.isFinite, number >= 0,
                index == 0 || number < 60
            else {
                return nil
            }
            seconds = seconds * 60 + number
        }
        guard seconds < 7 * 24 * 3600 else {
            return nil
        }
        return CMTime(value: Int64((seconds * 48_000).rounded()), timescale: 48_000)
    }
}
