import AVFoundation

// 预览持有来源访问和临时媒体，播放器切换项目后才归还这些资源。
final class MoviePreview: @unchecked Sendable {
    let asset: AVComposition
    let joins: [CMTime]
    private let plan: [MovieClip]
    private let adjustment: MovieAudioAdjustment
    private let mediaDirectory: URL?

    /// 业务作用: 将预览合成、来源访问和临时媒体绑定为同一播放生命周期。
    /// 参数说明:
    /// - asset: 已应用当前画面补全与音量设置的只读合成。
    /// - joins: 完整计划中各片段的连接位置。
    /// - plan: 保持来源文件访问有效的片段快照。
    /// - adjustment: 准备此预览时使用的声音设置。
    /// - mediaDirectory: 本次预览独占的临时媒体目录，没有像素或声音处理时可为空。
    /// 返回: 预览释放前保持临时媒体可读，不发布成品视频。
    private init(
        asset: AVComposition, joins: [CMTime], plan: [MovieClip], adjustment: MovieAudioAdjustment,
        mediaDirectory: URL?
    ) {
        self.asset = asset
        self.joins = joins
        self.plan = plan
        self.adjustment = adjustment
        self.mediaDirectory = mediaDirectory
    }

    /// 业务作用: 使用与导出相同的画面补全及音量处理准备完整预览。
    /// 参数说明:
    /// - plan: 用户当前确认的有序片段快照。
    /// - adjustment: 本次预览使用的音量模式及倍数。
    /// - progress: 媒体准备期间的进度与说明。
    /// 返回: 可交给播放器的合成及临时资源；失败或取消清理本次目录，来源不改动。
    static func prepare(
        _ plan: [MovieClip], adjustment: MovieAudioAdjustment,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> MoviePreview {
        try Task.checkCancellation()
        let composition = try await MovieEditExporter.compose(plan)
        try Task.checkCancellation()
        let inpainting = !MovieWatermarkProcessor.intervals(plan).isEmpty
        let enhancing = adjustment != .original && composition.hasAudio
        guard inpainting || enhancing else {
            return MoviePreview(
                asset: composition.asset, joins: composition.joins, plan: plan, adjustment: adjustment,
                mediaDirectory: nil)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ScreenRecorder-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var transferred = false
        defer {
            // 媒体尚未交给播放器时，取消和失败都必须清理本次独占目录。
            if !transferred {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        let video = try await MovieWatermarkProcessor.prepare(
            composition.asset, clips: plan, to: directory.appendingPathComponent("video.mov")
        ) { value, message in
            progress(value * (enhancing ? 0.85 : 1), message)
        }
        let asset = try await MovieAudioEnhancer.prepare(
            asset: video, adjustment: adjustment,
            audioURL: directory.appendingPathComponent("audio.m4a")
        ) { value, message in
            progress((inpainting ? 0.85 : 0) + value * (inpainting ? 0.15 : 1), message)
        }
        try Task.checkCancellation()
        for clip in plan {
            try clip.source.validate()
        }
        let preview = MoviePreview(
            asset: asset, joins: composition.joins, plan: plan, adjustment: adjustment,
            mediaDirectory: directory)
        transferred = true
        return preview
    }

    /// 业务作用: 仅在来源、顺序、剪切、框选时段和声音设置全部相同时复用已准备的媒体。
    /// 参数说明:
    /// - clips: 本次预览或导出的计划。
    /// - adjustment: 本次声音设置。
    /// 返回: 完全一致时可直接使用当前预览；任何编辑变化都要求重新处理。
    func matches(_ clips: [MovieClip], adjustment: MovieAudioAdjustment) -> Bool {
        guard adjustment == self.adjustment, clips.count == plan.count else {
            return false
        }
        return zip(clips, plan).allSatisfy { left, right in
            left.id == right.id && left.source === right.source && left.range == right.range
                && left.watermarks.count == right.watermarks.count
                && zip(left.watermarks, right.watermarks).allSatisfy {
                    $0.id == $1.id && $0.range == $1.range && $0.rect == $1.rect && $0.quality == $1.quality
                }
        }
    }

    /// 业务作用: 在播放器不再使用预览后清理该预览独占的媒体资源。
    /// 参数说明: 无。
    /// 返回: 移除本次临时目录，不修改来源文件或已导出视频。
    deinit {
        if let mediaDirectory {
            try? FileManager.default.removeItem(at: mediaDirectory)
        }
    }
}
