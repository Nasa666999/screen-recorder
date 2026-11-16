import AVFoundation

// 预览持有来源访问和临时声音，播放器切换项目后才归还这些资源。
final class MoviePreview: @unchecked Sendable {
    let asset: AVComposition
    let joins: [CMTime]
    private let plan: [MovieClip]
    private let audioDirectory: URL?

    /// 业务作用: 将预览合成、来源访问和临时声音绑定为同一播放生命周期。
    /// 参数说明:
    /// - asset: 已应用当前音量设置的只读合成。
    /// - joins: 完整计划中各片段的连接位置。
    /// - plan: 保持来源文件访问有效的片段快照。
    /// - audioDirectory: 本次预览独占的临时声音目录，原音量或无声计划可为空。
    /// 返回: 预览释放前保持临时声音可读，不创建成品视频。
    private init(asset: AVComposition, joins: [CMTime], plan: [MovieClip], audioDirectory: URL?) {
        self.asset = asset
        self.joins = joins
        self.plan = plan
        self.audioDirectory = audioDirectory
    }

    /// 业务作用: 使用与导出相同的音量处理准备完整预览，保留原视频数据与连接位置。
    /// 参数说明:
    /// - plan: 用户当前确认的有序片段快照。
    /// - adjustment: 本次预览使用的音量模式及倍数。
    /// - progress: 声音准备期间的进度与说明。
    /// 返回: 可交给播放器的合成与声音资源；失败或取消清理本次目录，来源不改动。
    static func prepare(
        _ plan: [MovieClip], adjustment: MovieAudioAdjustment,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> MoviePreview {
        try Task.checkCancellation()
        let composition = try await MovieEditExporter.compose(plan)
        try Task.checkCancellation()
        guard adjustment != .original, composition.hasAudio else {
            return MoviePreview(
                asset: composition.asset, joins: composition.joins, plan: plan, audioDirectory: nil)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ScreenRecorder-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var transferred = false
        defer {
            // 声音尚未交给播放器时，取消和失败都必须清理本次独占目录。
            if !transferred {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        let asset = try await MovieAudioEnhancer.prepare(
            asset: composition.asset, adjustment: adjustment,
            audioURL: directory.appendingPathComponent("audio.m4a"), progress: progress)
        try Task.checkCancellation()
        for clip in plan {
            try clip.source.validate()
        }
        let preview = MoviePreview(
            asset: asset, joins: composition.joins, plan: plan, audioDirectory: directory)
        transferred = true
        return preview
    }

    /// 业务作用: 在播放器不再使用预览后清理该预览独占的声音资源。
    /// 参数说明: 无。
    /// 返回: 移除本次临时目录，不修改来源文件或已导出视频。
    deinit {
        if let audioDirectory {
            try? FileManager.default.removeItem(at: audioDirectory)
        }
    }
}
