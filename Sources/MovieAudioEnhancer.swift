import AVFoundation
import Accelerate

// 音量选项只改变声音采样，预览与导出的画面始终使用来源的压缩数据。
enum MovieAudioAdjustment: Sendable, Equatable {
    case original
    case double
    case quadruple
    case automatic
    case custom(Float)

    /// 业务作用: 将预览与导出选项转换为线性采样增益，自动模式提供允许的最大增益。
    /// 参数说明: 无。
    /// 返回: 固定模式返回所选倍数，自动模式返回 24 dB 对应的增益上限。
    var requestedGain: Float {
        switch self {
        case .original:
            return 1
        case .double:
            return 2
        case .quadruple:
            return 4
        case .automatic:
            return pow(10, 24 / 20)
        case .custom(let value):
            return value
        }
    }

    /// 业务作用: 让明确选择的放大倍数作用于普通采样，以局部软限幅约束过高峰值。
    /// 参数说明: 无。
    /// 返回: 两倍、四倍与自定义使用软限幅；原音量和自动模式不施加局部限幅。
    var usesLimiter: Bool {
        switch self {
        case .double, .quadruple, .custom:
            return true
        case .original, .automatic:
            return false
        }
    }
}

enum MovieAudioEnhancer {
    private static let sampleRate = 48_000
    private static let channels = 2

    /// 业务作用: 按所选倍数或自动峰值策略生成独立音轨，保留视频轨道原数据。
    /// 参数说明:
    /// - asset: 已按用户范围拼接的只读合成。
    /// - adjustment: 用户选择的增大音量方式。
    /// - audioURL: 本次导出专用的临时 M4A 位置。
    /// - progress: 峰值检查与声音写入的进度和说明。
    /// 返回: 固定倍数对普通采样生效并限制过高峰值；自动模式无需增益时返回原合成，失败不修改来源。
    static func prepare(
        asset: AVComposition, adjustment: MovieAudioAdjustment, audioURL: URL,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> AVComposition {
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard adjustment != .original, !tracks.isEmpty else {
            return asset
        }
        guard adjustment.requestedGain.isFinite, (1...100).contains(adjustment.requestedGain) else {
            throw RecorderError.message("声音放大倍数需为 1 到 100，可输入小数。")
        }
        let gain: Float
        if adjustment.usesLimiter {
            // 明确选择的倍数不能因单个瞬时峰值而退回原音量；过高采样在写入时单独软限幅。
            gain = adjustment.requestedGain
        } else {
            let peak = try await peak(asset: asset, tracks: tracks, duration: duration, progress: progress)
            // 自动模式采用全片固定增益并预留两分贝，不因放大而引入局部限幅。
            let safe = peak > 0.000001 ? pow(Float(10), -2 / 20) / peak : 1
            gain = max(1, min(adjustment.requestedGain, safe))
        }
        guard gain > 1.001 else {
            progress(1, "声音峰值已接近上限或没有有效声音，保留原音量。")
            return asset
        }
        let db = 20 * log10(gain)
        let message = String(format: "正在放大声音 +%.1f dB，画面保持原画质…", db)
        try await render(
            asset: asset, tracks: tracks, duration: duration, gain: gain,
            limiting: adjustment.usesLimiter, to: audioURL
        ) { progress(0.3 + $0 * 0.7, message) }
        try Task.checkCancellation()
        let audioAsset = AVURLAsset(url: audioURL)
        guard let enhanced = try await audioAsset.loadTracks(withMediaType: .audio).first,
            let videoSource = try await asset.loadTracks(withMediaType: .video).first,
            let copy = asset.mutableCopy() as? AVMutableComposition
        else {
            throw RecorderError.message("无法读取增强后的声音轨道。")
        }
        for track in copy.tracks(withMediaType: .audio) {
            copy.removeTrack(track)
        }
        guard
            let audio = copy.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else {
            throw RecorderError.message("无法建立增强后的声音轨道。")
        }
        let bounds = try await enhanced.load(.timeRange)
        guard bounds.start <= .zero,
            bounds.end >= duration
                - CMTime(
                    value: 1,
                    timescale: 100
                )
        else {
            throw RecorderError.message("增强后的声音时长不完整，未发布成品。")
        }
        try audio.insertTimeRange(
            CMTimeRange(
                start: .zero,
                duration: min(duration, bounds.end)
            ), of: enhanced, at: .zero)
        guard try await videoSource.load(.timeRange).duration == duration else {
            throw RecorderError.message("声音处理不能改变视频时间线。")
        }
        progress(1, String(format: "声音已统一放大 +%.1f dB，正在封装新视频…", db))
        return copy.copy() as! AVComposition
    }

    /// 业务作用: 建立固定格式的离线声音读取器，让空音轨段按原时间线表现为静音。
    /// 参数说明:
    /// - asset: 只读合成。
    /// - tracks: 合成中的声音轨道。
    /// - duration: 本次输出的完整视频时长。
    /// 返回: 已启动的双声道 Float32 读取器，每次只交付一个有限音频块。
    private static func reader(
        asset: AVAsset, tracks: [AVAssetTrack], duration: CMTime
    ) throws -> (AVAssetReader, AVAssetReaderAudioMixOutput) {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: .zero,
            duration: duration
        )
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: tracks,
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw RecorderError.message("当前声音轨道无法进行音量处理。")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? RecorderError.message("无法开始读取声音。")
        }
        return (reader, output)
    }

    /// 业务作用: 按固定内存上限复制可处理的声音块，拒绝异常格式或非有限采样。
    /// 参数说明:
    /// - sample: 系统离线解码得到的一个声音块。
    /// 返回: 至多两秒的双声道浮点采样，不保留已消费的块。
    private static func samples(_ sample: CMSampleBuffer) throws -> [Float] {
        guard sample.numSamples > 0, sample.numSamples <= sampleRate * 2,
            let format = sample.formatDescription,
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
            asbd.mChannelsPerFrame == UInt32(channels), asbd.mBytesPerFrame == 8,
            asbd.mSampleRate == Double(sampleRate), let block = sample.dataBuffer,
            CMBlockBufferGetDataLength(block) == sample.numSamples * channels * MemoryLayout<Float>.size
        else {
            throw RecorderError.message("声音块格式或大小超出处理范围。")
        }
        var values = [Float](repeating: 0, count: sample.numSamples * channels)
        let status = values.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(
                block,
                atOffset: 0,
                dataLength: $0.count,
                destination: $0.baseAddress!
            )
        }
        guard status == noErr, values.allSatisfy({ $0.isFinite }) else {
            throw RecorderError.message("声音采样不可读取或包含异常数值。")
        }
        return values
    }

    /// 业务作用: 扫描完整拼接声音的最大峰值，计算不会突然削顶的统一增益依据。
    /// 参数说明:
    /// - asset: 当前只读合成。
    /// - tracks: 原始声音轨道。
    /// - duration: 完整输出时长。
    /// - progress: 峰值扫描进度。
    /// 返回: 全部声道的最大绝对峰值，扫描只保留一个声音块。
    private static func peak(
        asset: AVAsset, tracks: [AVAssetTrack], duration: CMTime,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> Float {
        let (reader, output) = try reader(asset: asset, tracks: tracks, duration: duration)
        defer {
            reader.cancelReading()
        }
        var peak: Float = 0
        var last = -1.0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            try autoreleasepool {
                let values = try samples(sample)
                var value: Float = 0
                vDSP_maxmgv(values, 1, &value, vDSP_Length(values.count))
                peak = max(peak, value)
            }
            let value = sample.presentationTimeStamp.seconds / duration.seconds
            if value - last >= 0.01 {
                progress(min(0.3, max(0, value) * 0.3), "正在检查声音峰值，避免放大后爆音…")
                last = value
            }
        }
        guard reader.status == .completed else {
            throw reader.error ?? RecorderError.message("声音峰值检查未完成。")
        }
        return peak
    }

    /// 业务作用: 在来源声音块的有效范围内施加固定增益，保留原时间对应关系。
    /// 参数说明:
    /// - sample: 原始解码声音块。
    /// - gain: 用户选择或由完整峰值扫描约束的固定增益。
    /// - limiting: 是否对指定倍数产生的过高峰值软限幅。
    /// - offset: 当前块中已由更早声音覆盖的帧数。
    /// - count: 仍位于输出时间范围内的采样帧数。
    /// - time: 本块在输出时间线上的开始位置。
    /// 返回: 独立存储且没有重叠范围的新 PCM 块。
    private static func amplified(
        _ sample: CMSampleBuffer, gain: Float, limiting: Bool, offset: Int, count: Int, at time: CMTime
    ) throws -> CMSampleBuffer {
        let source = try samples(sample)
        var values = Array(source[(offset * channels)..<((offset + count) * channels)])
        for index in values.indices {
            let value = values[index] * gain
            if limiting, abs(value) > 0.55 {
                // 常规采样保持指定倍数，峰值平滑收敛并为 AAC 编码留出余量，避免直接截断声音。
                let ceiling: Float = 0.6309573
                let headroom = ceiling - 0.55
                let magnitude = 0.55 + headroom * tanh((abs(value) - 0.55) / headroom)
                values[index] = value.sign == .minus ? -magnitude : magnitude
            } else {
                values[index] = value
            }
        }
        guard let format = sample.formatDescription else {
            throw RecorderError.message("声音块缺少格式信息。")
        }
        return try pcmSample(values: values, format: format, at: time)
    }

    /// 业务作用: 将有限 PCM 数组封装为独立样本，不改写系统共享缓存。
    /// 参数说明:
    /// - values: 按帧交错排列的双声道 Float32 采样。
    /// - format: 对应的固定 48 kHz 双声道格式。
    /// - time: 本块在完整合成时间线上的开始位置。
    /// 返回: 可交给离线 AAC 编码器的独立声音样本。
    private static func pcmSample(
        values: [Float], format: CMAudioFormatDescription, at time: CMTime
    ) throws -> CMSampleBuffer {
        let byteCount = values.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: byteCount,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: byteCount,
                flags: 0,
                blockBufferOut: &block
            ) == noErr, let block
        else {
            throw RecorderError.message("无法建立增强声音的数据块。")
        }
        let status = values.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(
                value: 1,
                timescale: Int32(sampleRate)
            ),
            presentationTimeStamp: time,
            decodeTimeStamp: .invalid
        )
        var size = channels * MemoryLayout<Float>.size
        var result: CMSampleBuffer?
        guard status == noErr,
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: block,
                formatDescription: format,
                sampleCount: values.count / channels,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &size,
                sampleBufferOut: &result
            ) == noErr, let result
        else {
            throw RecorderError.message("无法创建增强声音的样本。")
        }
        return result
    }

    /// 业务作用: 等待离线编码器接收单个声音块，不继续解码并积压后续数据。
    /// 参数说明:
    /// - sample: 已处理的有限声音样本。
    /// - input: 当前 AAC 输入。
    /// - writer: 当前离线写入器。
    /// 返回: 样本已被接收；取消或写入失败时抛错，等待不阻塞主线程。
    private static func append(
        _ sample: CMSampleBuffer, input: AVAssetWriterInput, writer: AVAssetWriter
    ) async throws {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard writer.status == .writing else {
                throw writer.error ?? RecorderError.message("增强声音写入中断。")
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        try Task.checkCancellation()
        guard input.append(sample) else {
            throw writer.error ?? RecorderError.message("增强声音样本未能写入。")
        }
    }

    /// 业务作用: 用有限静音块覆盖真实的空白时间，防止 AAC 起始延迟或尾部空段改变音画时长。
    /// 参数说明:
    /// - cursor: 尚未写入的第一帧位置，成功后推进。
    /// - end: 本段空白结束位置。
    /// - format: 固定输出声音格式。
    /// - input: 当前 AAC 输入。
    /// - writer: 当前离线写入器。
    /// 返回: 按原时间位置写入静音，不移动其后的声音，内存与空白时长无关。
    private static func silence(
        cursor: inout Int64, until end: Int64, format: CMAudioFormatDescription,
        input: AVAssetWriterInput, writer: AVAssetWriter
    ) async throws {
        while cursor < end {
            let count = min(4096, Int(end - cursor))
            let sample = try pcmSample(
                values: [Float](repeating: 0, count: count * channels), format: format,
                at: CMTime(
                    value: cursor,
                    timescale: Int32(sampleRate)
                ))
            try await append(sample, input: input, writer: writer)
            cursor += Int64(count)
        }
    }

    /// 业务作用: 流式写入增强 AAC 音轨，在磁盘或编码器繁忙时等待而不堆积 PCM。
    /// 参数说明:
    /// - asset: 原始拼接合成。
    /// - tracks: 需要增强的声音轨道。
    /// - duration: 与视频保持一致的音轨时长。
    /// - gain: 全片固定增益。
    /// - limiting: 是否对指定倍数产生的过高峰值应用软限幅。
    /// - destination: 本次专用临时声音文件。
    /// - progress: 音轨写入进度。
    /// 返回: 完整封装的 AAC 音轨；失败或取消终止写入，由上层清理临时文件。
    private static func render(
        asset: AVAsset, tracks: [AVAssetTrack], duration: CMTime, gain: Float, limiting: Bool,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let (reader, output) = try reader(asset: asset, tracks: tracks, duration: duration)
        let writer = try AVAssetWriter(
            outputURL: destination,
            fileType: .m4a
        )
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: 192_000,
            ]
        )
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw RecorderError.message("无法建立增强声音的 AAC 输出。")
        }
        writer.add(input)
        var finished = false
        defer {
            reader.cancelReading()
            if !finished {
                writer.cancelWriting()
            }
        }
        guard writer.startWriting() else {
            throw writer.error ?? RecorderError.message("无法开始写入增强声音。")
        }
        writer.startSession(atSourceTime: .zero)
        var last = -1.0
        var cursor: Int64 = 0
        let total = Int64((duration.seconds * Double(sampleRate)).rounded(.up))
        var lastFormat: CMAudioFormatDescription?
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard sample.presentationTimeStamp.isNumeric, let format = sample.formatDescription else {
                throw RecorderError.message("声音块缺少有效的播放时间或格式。")
            }
            lastFormat = format
            let start = Int64((sample.presentationTimeStamp.seconds * Double(sampleRate)).rounded())
            // 空白只能在原时间位置补齐；不能把首个有声块平移到零点，或让多次导出积累音画偏移。
            try await silence(
                cursor: &cursor, until: min(total, max(cursor, start)), format: format,
                input: input, writer: writer)
            let offset = Int(max(0, cursor - start))
            let count = min(sample.numSamples - offset, Int(total - cursor))
            if count > 0 {
                let processed = try autoreleasepool {
                    try amplified(
                        sample, gain: gain, limiting: limiting, offset: offset, count: count,
                        at: CMTime(
                            value: cursor,
                            timescale: Int32(sampleRate)
                        ))
                }
                try await append(processed, input: input, writer: writer)
                cursor += Int64(count)
            }
            let value = Double(cursor) / Double(total)
            if value - last >= 0.01 {
                progress(min(1, max(0, value)))
                last = value
            }
        }
        guard reader.status == .completed, let format = lastFormat else {
            throw reader.error ?? RecorderError.message("增强声音读取未完成。")
        }
        try await silence(
            cursor: &cursor, until: total, format: format, input: input, writer: writer)
        try Task.checkCancellation()
        input.markAsFinished()
        writer.endSession(atSourceTime: duration)
        await writer.finishWriting()
        try Task.checkCancellation()
        guard writer.status == .completed else {
            throw writer.error ?? RecorderError.message("增强声音封装未完成。")
        }
        finished = true
    }
}
