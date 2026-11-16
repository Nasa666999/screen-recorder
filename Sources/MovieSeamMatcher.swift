import AVFoundation
import Accelerate
import CoreGraphics

struct MovieSeamSuggestion: @unchecked Sendable {
    let leftID: UUID
    let rightID: UUID
    let leftEnd: CMTime
    let rightStart: CMTime
    let overlap: Double
    let audioScore: Double?
    let imageScore: Double
    let leftImage: CGImage
    let rightImage: CGImage

    /// 业务作用: 将已核对的接缝建议应用到相邻片段副本，保留两侧其余内容。
    /// 参数说明:
    /// - clips: 当前有序片段列表。
    /// 返回: 对应片段仍相邻且范围可用时返回新列表，过期建议不能改动计划。
    func applying(to clips: [MovieClip]) throws -> [MovieClip] {
        guard let left = clips.firstIndex(where: { $0.id == leftID }), left + 1 < clips.count,
            clips[left + 1].id == rightID, leftEnd > clips[left].range.start,
            leftEnd <= clips[left].range.end, rightStart >= clips[left + 1].range.start,
            rightStart < clips[left + 1].range.end
        else {
            throw RecorderError.message("接缝对应的片段已经变化，请重新识别。")
        }
        var result = clips
        result[left].range = CMTimeRange(
            start: clips[left].range.start,
            end: leftEnd
        )
        result[left + 1].range = CMTimeRange(
            start: rightStart,
            end: clips[left + 1].range.end
        )
        return result
    }
}

private struct SeamFeatures {
    let values: [Float]
    let dimensions: Int
    let rate: Double
    let energy: [Double]

    var count: Int {
        values.count / dimensions
    }

    /// 业务作用: 为有限边界样本建立快速相关性索引，不保存完整视频。
    /// 参数说明:
    /// - values: 按时间排列的固定维度特征。
    /// - dimensions: 每个特征包含的数值数量。
    /// - rate: 每秒的特征数量。
    /// 返回: 保存特征及其能量前缀和，便于比较不同长度的重叠范围。
    init(values: [Float], dimensions: Int, rate: Double) {
        self.values = values
        self.dimensions = dimensions
        self.rate = rate
        var energy = [Double](repeating: 0, count: values.count / dimensions + 1)
        for frame in 0..<energy.count - 1 {
            var sum: Float = 0
            values.withUnsafeBufferPointer {
                vDSP_svesq($0.baseAddress! + frame * dimensions, 1, &sum, vDSP_Length(dimensions))
            }
            energy[frame + 1] = energy[frame] + Double(sum)
        }
        self.energy = energy
    }

    /// 业务作用: 以归一化相关性比较两个边界窗口的同长内容，降低录制音量差异的影响。
    /// 参数说明:
    /// - other: 后段视频的边界特征。
    /// - a: 前段特征起点。
    /// - b: 后段特征起点。
    /// - count: 本次比较的特征帧数。
    /// 返回: 有能量的匹配分数；静音、纯空白或越界返回零。
    func similarity(to other: SeamFeatures, a: Int, b: Int, count: Int) -> Double {
        guard count > 0, a >= 0, b >= 0, a + count <= self.count, b + count <= other.count else {
            return 0
        }
        let denominator = sqrt((energy[a + count] - energy[a]) * (other.energy[b + count] - other.energy[b]))
        guard denominator > 1e-8 else {
            return 0
        }
        var dot: Float = 0
        values.withUnsafeBufferPointer { left in
            other.values.withUnsafeBufferPointer { right in
                vDSP_dotpr(
                    left.baseAddress! + a * dimensions, 1, right.baseAddress! + b * dimensions, 1, &dot,
                    vDSP_Length(count * dimensions))
            }
        }
        return Double(dot) / denominator
    }
}

private struct SeamWave {
    let samples: [Float]
    let sum: [Double]
    let energy: [Double]

    /// 业务作用: 为有限 PCM 窗口建立去直流的相关性索引，供精确接缝定位。
    /// 参数说明:
    /// - samples: 固定采样率的单声道边界音频。
    /// 返回: 保存波形及前缀和，内存只随固定搜索窗口增长。
    init(samples: [Float]) {
        self.samples = samples
        var sum = [Double](repeating: 0, count: samples.count + 1)
        var energy = sum
        for index in samples.indices {
            let value = Double(samples[index])
            sum[index + 1] = sum[index] + value
            energy[index + 1] = energy[index] + value * value
        }
        self.sum = sum
        self.energy = energy
    }

    /// 业务作用: 比较两个短音频块是否为相同内容，排除纯静音与音量增益的误导。
    /// 参数说明:
    /// - other: 后段的 PCM 窗口。
    /// - a: 前段采样起点。
    /// - b: 后段采样起点。
    /// - count: 比较的采样帧数。
    /// 返回: 去直流后的相关性绝对值，无法可靠比较时为零。
    func similarity(to other: SeamWave, a: Int, b: Int, count: Int) -> Double {
        guard count > 0, a >= 0, b >= 0, a + count <= samples.count, b + count <= other.samples.count else {
            return 0
        }
        let meanA = sum[a + count] - sum[a]
        let meanB = other.sum[b + count] - other.sum[b]
        let varianceA = energy[a + count] - energy[a] - meanA * meanA / Double(count)
        let varianceB = other.energy[b + count] - other.energy[b] - meanB * meanB / Double(count)
        guard min(varianceA, varianceB) / Double(count) > 1e-9 else {
            return 0
        }
        var dot: Float = 0
        samples.withUnsafeBufferPointer { left in
            other.samples.withUnsafeBufferPointer { right in
                vDSP_dotpr(left.baseAddress! + a, 1, right.baseAddress! + b, 1, &dot, vDSP_Length(count))
            }
        }
        return abs(Double(dot) - meanA * meanB / Double(count)) / sqrt(varianceA * varianceB)
    }
}

private struct SeamLag {
    let lag: Int
    let score: Double
}

private struct AudioSeamMatch {
    let lag: Int
    let begin: Int
    let end: Int
    let score: Double
}

enum MovieSeamMatcher {
    private static let audioRate = 8_000
    private static let featureRate = 20
    private static let searchSeconds = 180.0

    /// 业务作用: 对比前段结尾与后段开头，寻找可去重且没有明显跳变的共同内容。
    /// 参数说明:
    /// - left: 接缝前面的保留片段。
    /// - right: 接缝后面的保留片段。
    /// - progress: 有界搜索的进度与当前操作说明。
    /// 返回: 连续内容比对与画面复核支持的接缝建议；无重叠、重复模式或证据不足时不猜测剪切点。
    static func match(
        left: MovieClip, right: MovieClip, progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> MovieSeamSuggestion {
        try left.validate()
        try right.validate()
        let leftRange = CMTimeRange(
            start: max(
                left.range.start,
                left.range.end
                    - CMTime(
                        seconds: searchSeconds,
                        preferredTimescale: 48_000
                    )),
            end: left.range.end
        )
        let rightRange = CMTimeRange(
            start: right.range.start,
            end: min(
                right.range.end,
                right.range.start
                    + CMTime(
                        seconds: searchSeconds,
                        preferredTimescale: 48_000
                    ))
        )
        guard min(leftRange.duration.seconds, rightRange.duration.seconds) >= 3 else {
            throw RecorderError.message("自动对齐需要两侧至少各有三秒内容，请手动设置接缝。")
        }
        var boundary: BoundaryMatch?
        if left.source.info.audio != nil, right.source.info.audio != nil {
            boundary = try await audioMatch(
                left: left.source, leftRange: leftRange, right: right.source, rightRange: rightRange,
                progress: progress)
        }
        if boundary == nil {
            boundary = try await videoMatch(
                left: left.source, leftRange: leftRange, right: right.source, rightRange: rightRange,
                progress: progress)
        }
        guard let boundary else {
            throw RecorderError.message("没有找到可靠的共同内容，请手动选择接缝。")
        }
        let leftTime = boundary.left
        let rightTime = boundary.right
        try Task.checkCancellation()
        progress(0.85, "核对接缝前后的画面…")
        guard leftTime > left.range.start, leftTime < left.range.end,
            rightTime >= right.range.start, rightTime < right.range.end
        else {
            throw RecorderError.message("匹配位置超出了当前保留范围，请调整范围后重试。")
        }
        let visual = try await verifyImages(
            left: left.source, at: leftTime, right: right.source, at: rightTime)
        guard visual.score >= 0.75 else {
            throw RecorderError.message("声音可能相同，但接缝画面差异较大；请手动预览，避免错误去重。")
        }
        try left.validate()
        try right.validate()
        progress(1, "已找到共同内容，可以预览接缝")
        return MovieSeamSuggestion(
            leftID: left.id,
            rightID: right.id,
            leftEnd: leftTime,
            rightStart: rightTime,
            overlap: boundary.overlap,
            audioScore: boundary.audioScore,
            imageScore: visual.score,
            leftImage: visual.left,
            rightImage: visual.right
        )
    }

    private struct BoundaryMatch {
        let left: CMTime
        let right: CMTime
        let overlap: Double
        let audioScore: Double?
    }

    /// 业务作用: 从边界声音中寻找唯一且足够长的共同段落，避免把频谱相似当成相同内容。
    /// 参数说明:
    /// - left: 前段来源。
    /// - leftRange: 前段有限边界范围。
    /// - right: 后段来源。
    /// - rightRange: 后段有限边界范围。
    /// - progress: 声音识别进度。
    /// 返回: 可靠声音对应关系；静音或没有共同声音时交由画面判断，重复声音存在歧义时拒绝建议。
    private static func audioMatch(
        left: MovieSource, leftRange: CMTimeRange, right: MovieSource, rightRange: CMTimeRange,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> BoundaryMatch? {
        progress(0.02, "读取前段结尾的声音…")
        let a = try await wave(source: left, range: leftRange)
        progress(0.18, "读取后段开头的声音…")
        let b = try await wave(source: right, range: rightRange)
        progress(0.34, "寻找相同的声音段落…")
        guard let fa = try audioFeatures(a.samples), let fb = try audioFeatures(b.samples) else {
            return nil
        }
        let lags = try candidateLags(left: fa, right: fb, minimumSeconds: 3)
        let matches = try refinedAudioMatches(a: a, b: b, fa: fa, fb: fb, lags: lags, progress: progress)
        guard let best = matches.first, best.score >= 0.68 else {
            return nil
        }
        // 重复音乐或稳定背景音可能给出多个位置，不能把相似声音当成唯一的时间对应关系。
        if let second = matches.dropFirst().first(where: { abs($0.lag - best.lag) > audioRate }),
            best.score - second.score < 0.045
        {
            throw RecorderError.message("检测到多个相似段落，暂时不能确定唯一接缝。请预览后手动调整。")
        }
        let cut = quietCut(wave: b, begin: best.begin, end: best.end)
        let leftTime =
            leftRange.start
            + CMTime(
                value: Int64(cut + best.lag),
                timescale: Int32(audioRate)
            )
        let rightTime =
            rightRange.start
            + CMTime(
                value: Int64(cut),
                timescale: Int32(audioRate)
            )
        let overlap = Double(best.end - best.begin) / Double(audioRate)
        return BoundaryMatch(
            left: leftTime,
            right: rightTime,
            overlap: overlap,
            audioScore: best.score
        )
    }

    /// 业务作用: 在声音不能提供对应关系时，通过连续画面寻找唯一共同段落。
    /// 参数说明:
    /// - left: 前段来源。
    /// - leftRange: 前段有限边界范围。
    /// - right: 后段来源。
    /// - rightRange: 后段有限边界范围。
    /// - progress: 画面识别进度。
    /// 返回: 接近来源帧精度的对应关系；无共同内容、静止画面或多个近似位置时拒绝建议。
    private static func videoMatch(
        left: MovieSource, leftRange: CMTimeRange, right: MovieSource, rightRange: CMTimeRange,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> BoundaryMatch {
        progress(0.05, "读取边界画面，寻找重复段落…")
        let a = try await videoFeatures(source: left, range: leftRange) {
            progress($0 * 0.3 + 0.05, "分析前段结尾的画面…")
        }
        let b = try await videoFeatures(source: right, range: rightRange) {
            progress($0 * 0.3 + 0.35, "分析后段开头的画面…")
        }
        let lags = try candidateLags(left: a, right: b, minimumSeconds: 3)
        guard let best = lags.first, best.score > 0.94,
            lags.count < 2 || best.score - lags[1].score > 0.04
        else {
            throw RecorderError.message("仅凭画面未找到唯一的重复段落，静止或重复画面需要手动确认接缝。")
        }
        let beginB = max(0, -best.lag)
        let count = min(a.count - max(0, best.lag), b.count - beginB)
        let cutB = Double(beginB + count / 2) / b.rate
        let initialLeft =
            leftRange.start
            + CMTime(
                seconds: cutB + Double(best.lag) / a.rate,
                preferredTimescale: 48_000
            )
        let rightTime =
            rightRange.start
            + CMTime(
                seconds: cutB,
                preferredTimescale: 48_000
            )
        let leftTime = try await refineVideoTime(
            source: left, around: initialLeft, matching: right, at: rightTime)
        let overlap = Double(count) / a.rate
        return BoundaryMatch(
            left: leftTime,
            right: rightTime,
            overlap: overlap,
            audioScore: nil
        )
    }

    /// 业务作用: 只解码固定边界窗口的单声道声音，按原媒体时间放置采样。
    /// 参数说明:
    /// - source: 待比较的视频来源。
    /// - range: 最多三分钟的边界范围。
    /// 返回: 固定 8 kHz 的有限分析波形，不改变实际导出的声音或帧率。
    private static func wave(source: MovieSource, range: CMTimeRange) async throws -> SeamWave {
        guard let track = source.info.audio else {
            throw RecorderError.message("视频没有可比较的声音。")
        }
        let reader = try AVAssetReader(asset: source.asset)
        reader.timeRange = range
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: audioRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? RecorderError.message("无法读取边界声音。")
        }
        defer {
            reader.cancelReading()
        }
        var result = [Float](repeating: 0, count: Int(ceil(range.duration.seconds * Double(audioRate))))
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            try autoreleasepool {
                guard sample.numSamples > 0, sample.presentationTimeStamp.isNumeric,
                    let block = sample.dataBuffer
                else {
                    return
                }
                var values = [Float](repeating: 0, count: sample.numSamples)
                let status = values.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(
                        block,
                        atOffset: 0,
                        dataLength: min($0.count, CMBlockBufferGetDataLength(block)),
                        destination: $0.baseAddress!
                    )
                }
                guard status == noErr else {
                    throw RecorderError.message("无法解码边界声音。")
                }
                let start = Int(
                    ((sample.presentationTimeStamp - range.start).seconds * Double(audioRate)).rounded())
                let begin = max(0, start)
                let end = min(result.count, start + values.count)
                if begin < end {
                    result.replaceSubrange(begin..<end, with: values[(begin - start)..<(end - start)])
                }
            }
        }
        guard reader.status == .completed else {
            throw reader.error ?? RecorderError.message("边界声音读取不完整。")
        }
        return SeamWave(samples: result)
    }

    /// 业务作用: 将边界声音压缩成时间与频带特征，用于快速排除不相同的段落。
    /// 参数说明:
    /// - samples: 固定 8 kHz 的单声道 PCM。
    /// 返回: 每秒二十组归一化特征，活动声音不足三秒时不提供特征。
    private static func audioFeatures(_ samples: [Float]) throws -> SeamFeatures? {
        let size = 512
        let hop = audioRate / featureRate
        let frames = samples.count / hop
        let dimensions = 8
        guard let setup = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2)) else {
            throw RecorderError.message("无法建立声音比较。")
        }
        defer {
            vDSP_destroy_fftsetup(setup)
        }
        var window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        var real = window
        var imaginary = window
        var values = [Float](repeating: 0, count: frames * dimensions)
        var active = [Bool](repeating: false, count: frames)
        let bands = [3, 6, 12, 22, 42, 75, 125, 256]
        for frame in 0..<frames {
            if frame % 100 == 0 {
                try Task.checkCancellation()
            }
            let start = frame * hop
            var power: Float = 0
            for index in 0..<size {
                let sample = start + index < samples.count ? samples[start + index] : 0
                real[index] = sample * window[index]
                imaginary[index] = 0
                power += sample * sample
            }
            guard power / Float(size) > 1e-9 else {
                continue
            }
            active[frame] = true
            values[frame * dimensions] = log(max(power, 1e-12))
            real.withUnsafeMutableBufferPointer { r in
                imaginary.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(
                        realp: r.baseAddress!,
                        imagp: i.baseAddress!
                    )
                    vDSP_fft_zip(setup, &split, 1, 9, FFTDirection(FFT_FORWARD))
                }
            }
            for band in 0..<7 {
                var energy: Float = 0
                for bin in bands[band]..<bands[band + 1] {
                    energy += real[bin] * real[bin] + imaginary[bin] * imaginary[bin]
                }
                values[frame * dimensions + band + 1] = log(max(energy, 1e-12)) - log(max(power, 1e-12))
            }
        }
        let activeCount = active.filter { $0 }.count
        guard activeCount >= featureRate * 3 else {
            return nil
        }
        for dimension in 0..<dimensions {
            var sum = 0.0
            var square = 0.0
            for frame in 0..<frames where active[frame] {
                let value = Double(values[frame * dimensions + dimension])
                sum += value
                square += value * value
            }
            let mean = sum / Double(activeCount)
            let deviation = max(0.1, sqrt(max(0, square / Double(activeCount) - mean * mean)))
            for frame in 0..<frames where active[frame] {
                let index = frame * dimensions + dimension
                values[index] = Float(min(4, max(-4, (Double(values[index]) - mean) / deviation)))
            }
        }
        return SeamFeatures(
            values: values,
            dimensions: dimensions,
            rate: Double(featureRate)
        )
    }

    /// 业务作用: 在有限窗口中搜索内容对应的时间偏移，并保留相互独立的候选位置。
    /// 参数说明:
    /// - left: 前段结尾特征。
    /// - right: 后段开头特征。
    /// - minimumSeconds: 至少需要共同出现的内容时长。
    /// 返回: 分数最高且彼此相隔至少一秒的候选，避免把同一个峰重复计数。
    private static func candidateLags(left: SeamFeatures, right: SeamFeatures, minimumSeconds: Double) throws
        -> [SeamLag]
    {
        let minimum = Int(minimumSeconds * left.rate)
        var scores: [SeamLag] = []
        guard min(left.count, right.count) >= minimum else {
            return []
        }
        for lag in -(right.count - minimum)...(left.count - minimum) {
            if lag % 100 == 0 {
                try Task.checkCancellation()
            }
            let a = max(0, lag)
            let b = max(0, -lag)
            let count = min(left.count - a, right.count - b)
            let score =
                left.similarity(to: right, a: a, b: b, count: count) * min(1, Double(count) / (left.rate * 6))
            scores.append(
                SeamLag(
                    lag: lag,
                    score: score
                ))
        }
        scores.sort { $0.score > $1.score }
        var result: [SeamLag] = []
        for score in scores where !result.contains(where: { abs($0.lag - score.lag) < Int(left.rate) }) {
            result.append(score)
            if result.count == 8 {
                break
            }
        }
        return result
    }

    /// 业务作用: 以真实波形复核候选偏移，并定位可安全切换的连续共同段落。
    /// 参数说明:
    /// - a: 前段结尾波形。
    /// - b: 后段开头波形。
    /// - fa: 前段的快速特征。
    /// - fb: 后段的快速特征。
    /// - lags: 粗略对应关系。
    /// - progress: 后台匹配进度。
    /// 返回: 排除只有频谱相似的假匹配，按波形相关性排序的共同区间。
    private static func refinedAudioMatches(
        a: SeamWave, b: SeamWave, fa: SeamFeatures, fb: SeamFeatures, lags: [SeamLag],
        progress: @escaping @Sendable (Double, String) -> Void
    ) throws -> [AudioSeamMatch] {
        var matches: [AudioSeamMatch] = []
        let hop = audioRate / featureRate
        let block = audioRate * 2
        for (index, lag) in lags.enumerated() {
            try Task.checkCancellation()
            progress(
                0.4 + Double(index) / Double(max(1, lags.count)) * 0.4, "核对重叠声音 \(index + 1)/\(lags.count)…")
            let beginA = max(0, lag.lag)
            let beginB = max(0, -lag.lag)
            let count = min(fa.count - beginA, fb.count - beginB)
            let featureBlock = featureRate * 3
            guard count >= featureBlock else {
                continue
            }
            var anchors: [(Int, Double)] = []
            for offset in stride(from: 0, through: count - featureBlock, by: featureRate) {
                anchors.append(
                    (
                        beginB + offset,
                        fa.similarity(to: fb, a: beginA + offset, b: beginB + offset, count: featureBlock)
                    ))
            }
            anchors.sort { $0.1 > $1.1 }
            var bestLag = lag.lag * hop
            var bestScore = 0.0
            for anchor in anchors.prefix(2) {
                let bStart = anchor.0 * hop
                for shift in -960...960 {
                    if shift % 64 == 0 {
                        try Task.checkCancellation()
                    }
                    let candidate = lag.lag * hop + shift
                    let score = a.similarity(to: b, a: bStart + candidate, b: bStart, count: audioRate * 3)
                    if score > bestScore {
                        bestScore = score
                        bestLag = candidate
                    }
                }
            }
            guard bestScore >= 0.68 else {
                continue
            }
            let begin = max(0, -bestLag)
            let end = min(b.samples.count, a.samples.count - bestLag)
            var runStart: Int?
            var runScores: [Double] = []
            var bestRun: AudioSeamMatch?
            for offset in stride(from: begin, through: max(begin, end - block), by: audioRate) {
                let score = a.similarity(to: b, a: offset + bestLag, b: offset, count: block)
                if score >= 0.62 {
                    runStart = runStart ?? offset
                    runScores.append(score)
                    let run = AudioSeamMatch(
                        lag: bestLag,
                        begin: runStart!,
                        end: offset + block,
                        score: runScores.reduce(0, +) / Double(runScores.count)
                    )
                    if bestRun == nil || run.end - run.begin > bestRun!.end - bestRun!.begin {
                        bestRun = run
                    }
                } else {
                    runStart = nil
                    runScores.removeAll(keepingCapacity: true)
                }
            }
            if let bestRun, bestRun.score >= 0.68 {
                matches.append(bestRun)
            }
        }
        return matches.sorted { $0.score > $1.score }
    }

    /// 业务作用: 在已核对的共同段落内部选择较安静的位置，降低声音接缝的突变。
    /// 参数说明:
    /// - wave: 后段边界波形。
    /// - begin: 已核对共同内容的开始采样。
    /// - end: 已核对共同内容的结束采样。
    /// 返回: 避开区间边缘、倾向中部安静处的采样位置。
    private static func quietCut(wave: SeamWave, begin: Int, end: Int) -> Int {
        let center = (begin + end) / 2
        let margin = min(audioRate, (end - begin) / 4)
        var best = center
        var bestScore = Double.infinity
        for position in stride(from: begin + margin, through: end - margin, by: audioRate / 50) {
            let a = max(begin, position - 80)
            let b = min(end, position + 80)
            let energy = (wave.energy[b] - wave.energy[a]) / Double(max(1, b - a))
            let score = log(max(energy, 1e-12)) + Double(abs(position - center)) / Double(max(1, end - begin))
            if score < bestScore {
                bestScore = score
                best = position
            }
        }
        return best
    }

    /// 业务作用: 将一帧画面转换为小尺寸亮度特征，不保留完整分辨率缓存。
    /// 参数说明:
    /// - image: 解码后的来源画面。
    /// 返回: 去亮度偏移并归一化的中心画面特征，黑屏或纯色返回零向量。
    private static func imageFeature(_ image: CGImage) -> [Float] {
        let width = 32
        let height = 18
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { bytes in
            guard
                let context = CGContext(
                    data: bytes.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                )
            else {
                return
            }
            let rect = CGRect(
                x: Double(image.width) * 0.05,
                y: Double(image.height) * 0.05,
                width: Double(image.width) * 0.9,
                height: Double(image.height) * 0.9
            )
            context.interpolationQuality = .medium
            context.draw(
                image.cropping(to: rect) ?? image,
                in: CGRect(
                    x: 0,
                    y: 0,
                    width: width,
                    height: height
                ))
        }
        let mean = Float(pixels.reduce(0) { $0 + Int($1) }) / Float(pixels.count)
        let values = pixels.map { Float($0) - mean }
        let energy = sqrt(values.reduce(0) { $0 + $1 * $1 })
        return energy > 10 ? values.map { $0 / energy } : [Float](repeating: 0, count: pixels.count)
    }

    /// 业务作用: 为没有声音的视频建立有限边界的画面序列。
    /// 参数说明:
    /// - source: 视频来源。
    /// - range: 固定搜索范围。
    /// - progress: 画面读取进度。
    /// 返回: 每秒两帧的小尺寸特征，仅用于识别，不影响导出帧率。
    private static func videoFeatures(
        source: MovieSource, range: CMTimeRange, progress: @escaping (Double) -> Void
    ) async throws -> SeamFeatures {
        let generator = AVAssetImageGenerator(asset: source.asset)
        generator.maximumSize = CGSize(
            width: 96,
            height: 54
        )
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(
            seconds: 0.05,
            preferredTimescale: 600
        )
        defer {
            generator.cancelAllCGImageGeneration()
        }
        let count = Int(range.duration.seconds * 2)
        var values = [Float](repeating: 0, count: count * 576)
        let times = (0..<count).map {
            range.start
                + CMTime(
                    value: Int64($0),
                    timescale: 2
                )
        }
        var completed = 0
        for await result in generator.images(for: times) {
            try Task.checkCancellation()
            if case .success(let requested, let image, _) = result {
                let index = Int(((requested - range.start).seconds * 2).rounded())
                if index >= 0, index < count {
                    values.replaceSubrange((index * 576)..<((index + 1) * 576), with: imageFeature(image))
                }
            }
            completed += 1
            if completed % 8 == 0 {
                progress(Double(completed) / Double(count))
            }
        }
        return SeamFeatures(
            values: values,
            dimensions: 576,
            rate: 2
        )
    }

    /// 业务作用: 将纯画面粗略匹配细化到来源帧附近，避免按半秒精度直接拼接。
    /// 参数说明:
    /// - source: 前段视频。
    /// - time: 前段粗略对应时间。
    /// - matching: 后段视频。
    /// - otherTime: 后段对应的时间。
    /// 返回: 前段一秒邻域内画面最相似的实际帧时间。
    private static func refineVideoTime(
        source: MovieSource, around time: CMTime, matching: MovieSource, at otherTime: CMTime
    ) async throws -> CMTime {
        let reference = AVAssetImageGenerator(asset: matching.asset)
        reference.maximumSize = CGSize(
            width: 96,
            height: 54
        )
        reference.appliesPreferredTrackTransform = true
        reference.requestedTimeToleranceBefore = .zero
        reference.requestedTimeToleranceAfter = .zero
        let target = imageFeature(try await reference.image(at: otherTime).image)
        let generator = AVAssetImageGenerator(asset: source.asset)
        generator.maximumSize = CGSize(
            width: 96,
            height: 54
        )
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        defer {
            generator.cancelAllCGImageGeneration()
        }
        let rate = max(24, min(60, Double(source.info.frameRate)))
        var best = time
        var bestScore: Float = -1
        for index in -Int(rate / 2)...Int(rate / 2) {
            try Task.checkCancellation()
            let candidate =
                time
                + CMTime(
                    seconds: Double(index) / rate,
                    preferredTimescale: 60_000
                )
            guard candidate >= source.info.bounds.start, candidate < source.info.bounds.end else {
                continue
            }
            let frame = try await generator.image(at: candidate)
            let feature = imageFeature(frame.image)
            var dot: Float = 0
            vDSP_dotpr(feature, 1, target, 1, &dot, vDSP_Length(target.count))
            if dot > bestScore {
                bestScore = dot
                best = frame.actualTime
            }
        }
        return best
    }

    /// 业务作用: 对接缝邻域的多个对应画面复核，避免只凭相同背景音裁剪。
    /// 参数说明:
    /// - left: 前段来源。
    /// - leftTime: 前段拟结束时间。
    /// - right: 后段来源。
    /// - rightTime: 后段拟开始时间。
    /// 返回: 三个对应画面的中位相似度及接缝参考图。
    private static func verifyImages(
        left: MovieSource, at leftTime: CMTime, right: MovieSource, at rightTime: CMTime
    ) async throws -> (score: Double, left: CGImage, right: CGImage) {
        let a = AVAssetImageGenerator(asset: left.asset)
        let b = AVAssetImageGenerator(asset: right.asset)
        for generator in [a, b] {
            generator.maximumSize = CGSize(
                width: 320,
                height: 180
            )
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
        }
        defer {
            a.cancelAllCGImageGeneration()
            b.cancelAllCGImageGeneration()
        }
        var scores: [Double] = []
        var center: (CGImage, CGImage)?
        for offset in [-0.4, 0, 0.4] {
            try Task.checkCancellation()
            let timeA = max(
                left.info.bounds.start,
                min(
                    left.info.bounds.end
                        - CMTime(
                            seconds: 0.05,
                            preferredTimescale: 600
                        ),
                    leftTime
                        + CMTime(
                            seconds: offset,
                            preferredTimescale: 600
                        )))
            let timeB = max(
                right.info.bounds.start,
                min(
                    right.info.bounds.end
                        - CMTime(
                            seconds: 0.05,
                            preferredTimescale: 600
                        ),
                    rightTime
                        + CMTime(
                            seconds: offset,
                            preferredTimescale: 600
                        )))
            let imageA = try await a.image(at: timeA).image
            let imageB = try await b.image(at: timeB).image
            let fa = imageFeature(imageA)
            let fb = imageFeature(imageB)
            var dot: Float = 0
            vDSP_dotpr(fa, 1, fb, 1, &dot, vDSP_Length(fa.count))
            scores.append(Double(dot))
            if offset == 0 {
                center = (imageA, imageB)
            }
        }
        return (scores.sorted()[1], center!.0, center!.1)
    }
}
