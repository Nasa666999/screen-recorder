import AVFoundation
import CoreMedia

enum AudioSource: Hashable {
    case system
    case microphone
}

private struct AudioChunk {
    let start: Int64
    let left: [Float]
    let right: [Float]

    var end: Int64 {
        start + Int64(left.count)
    }
}

final class AudioPipeline {
    static let sampleRate: Double = 48_000
    private let origin: CMTime
    private var converters: [AudioSource: AVAudioConverter] = [:]
    private var chunks: [AudioSource: [AudioChunk]] = [:]
    private var lateFrames: [AudioSource: Int64] = [:]
    private var receivedEnd: [AudioSource: Int64] = [:]
    private(set) var cursor: Int64 = 0
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 2,
        interleaved: false
    )!
    private let fileFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 2,
        interleaved: true
    )!

    /// 业务作用: 建立与视频共享起点的有界音频时间线。
    /// 参数说明:
    /// - origin: 首个有效视频样本的宿主时钟时间。
    /// 返回: 所有声源以同一时间基准转换和混音。
    init(origin: CMTime) {
        self.origin = origin
    }

    /// 业务作用: 将单个来源的实际 PCM 格式转换到固定输出规格。
    /// 参数说明:
    /// - sample: ScreenCaptureKit 提供的宿主时钟音频样本。
    /// - source: 系统声音或用户指定麦克风。
    /// 返回: 样本进入有界队列；单块超过两秒、格式无效、积压或持续迟到异常时抛错。
    func append(_ sample: CMSampleBuffer, source: AudioSource) throws {
        guard let description = sample.formatDescription, sample.numSamples > 0 else {
            throw RecorderError.message("采集音频格式无效。")
        }
        let inputFormat = AVAudioFormat(cmAudioFormatDescription: description)
        guard inputFormat.sampleRate.isFinite, inputFormat.sampleRate > 0 else {
            throw RecorderError.message("采集音频采样率无效。")
        }
        // 先限制单块时长再分配 PCM 和转换缓冲，异常大样本不能在排队前占用大量内存。
        guard Double(sample.numSamples) / inputFormat.sampleRate <= 2 else {
            throw RecorderError.message("单个音频样本超过两秒，无法在实时缓存预算内处理。")
        }
        let count = AVAudioFrameCount(sample.numSamples)
        guard
            let input = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: count
            )
        else {
            throw RecorderError.message("无法分配音频缓冲。")
        }
        input.frameLength = count
        guard
            CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sample,
                at: 0,
                frameCount: Int32(count),
                into: input.mutableAudioBufferList
            ) == noErr
        else {
            throw RecorderError.message("无法读取采集音频。")
        }
        let converter: AVAudioConverter
        if let existing = converters[source], existing.inputFormat == inputFormat {
            converter = existing
        } else {
            guard
                let created = AVAudioConverter(
                    from: inputFormat,
                    to: outputFormat
                )
            else {
                throw RecorderError.message("所选音频设备格式无法转换。")
            }
            // 不预留跨块前导样本，使样本起点保持在采集提供的公共时间线上。
            created.primeMethod = .none
            if inputFormat.channelCount == 1 {
                created.channelMap = [0, 0]
            }
            converter = created
            converters[source] = created
        }
        let capacity =
            AVAudioFrameCount(ceil(Double(count) * Self.sampleRate / inputFormat.sampleRate)) + 256
        guard
            let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: capacity
            )
        else {
            throw RecorderError.message("无法分配转换后的音频缓冲。")
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied {
                state.pointee = .noDataNow
                return nil
            }
            supplied = true
            state.pointee = .haveData
            return input
        }
        guard status != .error, error == nil, let channels = output.floatChannelData else {
            throw error ?? RecorderError.message("音频格式转换失败。") as NSError
        }
        let length = Int(output.frameLength)
        guard length > 0 else {
            return
        }
        let start = Int64(
            (CMTimeGetSeconds(sample.presentationTimeStamp - origin) * Self.sampleRate).rounded())
        let end = start + Int64(length)
        if end <= 0 {
            return
        }
        let late = max(0, min(cursor, end) - max(0, start))
        lateFrames[source] = late > 0 ? (lateFrames[source] ?? 0) + late : 0
        guard (lateFrames[source] ?? 0) < 24_000 else {
            throw RecorderError.message("所选声音持续迟到，无法保持完整音频，录制已停止。")
        }
        let first = max(0, max(start, max(cursor, receivedEnd[source] ?? 0)))
        let skip = Int(first - start)
        guard skip < length else {
            return
        }
        // 同一来源重叠或重复的采样区间只消费一次，不能把重复回调当作第二声源。
        let chunk = AudioChunk(
            start: first,
            left: Array(
                UnsafeBufferPointer(
                    start: channels[0] + skip,
                    count: length - skip
                )),
            right: Array(
                UnsafeBufferPointer(
                    start: channels[1] + skip,
                    count: length - skip
                ))
        )
        receivedEnd[source] = chunk.end
        chunks[source, default: []].append(chunk)
        let queued = chunks[source, default: []].reduce(0) {
            $0 + max(0, $1.end - max(cursor, $1.start))
        }
        guard queued <= 96_000 else {
            throw RecorderError.message("音频队列超过两秒，无法继续可靠录制。")
        }
    }

    /// 业务作用: 生成指定区间的单条混音轨，缺席声源补零而不移动其他声音。
    /// 参数说明:
    /// - count: 本次输出的采样帧数。
    /// 返回: 与视频共享宿主时钟的双声道浮点 PCM 样本。
    func nextSample(count: Int) throws -> CMSampleBuffer {
        var interleaved = [Float](repeating: 0, count: count * 2)
        let limit = cursor + Int64(count)
        for source in Array(chunks.keys) {
            for chunk in chunks[source, default: []] {
                let begin = max(cursor, chunk.start)
                let end = min(limit, chunk.end)
                if begin < end {
                    for frame in begin..<end {
                        let destination = Int(frame - cursor) * 2
                        let offset = Int(frame - chunk.start)
                        interleaved[destination] += chunk.left[offset]
                        interleaved[destination + 1] += chunk.right[offset]
                    }
                }
            }
        }
        for index in interleaved.indices {
            let value = interleaved[index]
            interleaved[index] = value.isFinite ? min(1, max(-1, value)) : 0
        }
        var description: CMAudioFormatDescription?
        guard
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: fileFormat.streamDescription,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &description
            ) == noErr
        else {
            throw RecorderError.message("无法建立音轨格式。")
        }
        let byteCount = interleaved.count * MemoryLayout<Float>.size
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
            throw RecorderError.message("无法建立音轨数据块。")
        }
        let copyStatus = interleaved.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard copyStatus == noErr else {
            throw RecorderError.message("无法复制音轨数据。")
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(
                value: 1,
                timescale: 48_000
            ),
            presentationTimeStamp: origin
                + CMTime(
                    value: cursor,
                    timescale: 48_000
                ),
            decodeTimeStamp: .invalid
        )
        var size = MemoryLayout<Float>.size * 2
        var sample: CMSampleBuffer?
        guard
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: block,
                formatDescription: description,
                sampleCount: count,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &size,
                sampleBufferOut: &sample
            ) == noErr,
            let sample
        else {
            throw RecorderError.message("无法建立混音样本。")
        }
        return sample
    }

    /// 业务作用: 仅在写入器接受样本后推进音频时间线并释放已消费数据。
    /// 参数说明:
    /// - count: 已成功写入的采样帧数。
    /// 返回: 已写区间不再接受迟到样本。
    func advance(_ count: Int) {
        cursor += Int64(count)
        for source in Array(chunks.keys) {
            chunks[source]?.removeAll {
                $0.end <= cursor
            }
        }
    }
}
