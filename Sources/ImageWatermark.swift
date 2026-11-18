import AppKit
import CoreMedia
import Darwin
import ImageIO
import UniformTypeIdentifiers

final class ImageWatermarkSource: @unchecked Sendable {
    let url: URL
    let identity: MovieFileIdentity
    let image: CGImage
    private let scoped: Bool

    /// 业务作用: 将已解码图片与来源访问绑定，处理和保存期间持续复验原文件。
    /// 参数说明:
    /// - url: 用户主动选择的图片。
    /// - identity: 导入时的文件身份。
    /// - image: 已应用显示方向、未缩小的图片。
    /// - scoped: 本次是否取得安全作用域访问。
    /// 返回: 不修改来源文件，最后一个引用释放时归还访问。
    private init(url: URL, identity: MovieFileIdentity, image: CGImage, scoped: Bool) {
        self.url = url
        self.identity = identity
        self.image = image
        self.scoped = scoped
    }

    /// 业务作用: 在后台解码静态 SDR 图片，按来源方向提供完整像素供框选与补全。
    /// 参数说明:
    /// - url: 本地 PNG、JPEG、HEIC 或 TIFF 图片。
    /// 返回: 保留原始显示尺寸；多帧、高位深、超大或不可读图片明确拒绝。
    static func open(_ url: URL) async throws -> ImageWatermarkSource {
        try Task.checkCancellation()
        guard url.isFileURL else {
            throw RecorderError.message("请先将图片保存到本机。")
        }
        let url = url.standardizedFileURL
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            let identity = try MovieFileIdentity.read(url)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                CGImageSourceGetCount(source) == 1,
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? Int,
                let height = properties[kCGImagePropertyPixelHeight] as? Int,
                width > 0, height > 0, width <= 100_000_000 / height
            else {
                throw RecorderError.message("请选择不超过一亿像素的单帧图片。")
            }
            // 模型只接受八位 SDR，不能在用户不知情时压缩 HDR 或高位深图片的颜色。
            guard (properties[kCGImagePropertyDepth] as? Int ?? 8) <= 8,
                let image = CGImageSourceCreateThumbnailAtIndex(
                    source, 0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                        kCGImageSourceShouldCacheImmediately: true,
                    ] as CFDictionary),
                image.bitsPerComponent <= 8,
                !CGColorSpaceUsesExtendedRange(image.colorSpace ?? CGColorSpaceCreateDeviceRGB()),
                image.colorSpace?.isHDR() != true
            else {
                throw RecorderError.message("图片补全目前支持八位 SDR，请先将来源转换为八位 PNG 或 JPEG。")
            }
            try Task.checkCancellation()
            try identity.validate(url)
            return ImageWatermarkSource(url: url, identity: identity, image: image, scoped: scoped)
        } catch {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
            throw error
        }
    }

    /// 业务作用: 结束本次图片来源的安全作用域访问，不改动图片内容。
    /// 参数说明: 无。
    /// 返回: 所有处理和保存引用释放后归还来源访问。
    deinit {
        if scoped {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

enum ImageWatermarkRenderer {
    /// 业务作用: 使用视频的精细模型补全图片，只把选中区域的新颜色合回原始图片。
    /// 参数说明:
    /// - source: 本次保持访问和身份快照的图片。
    /// - rects: 左上角为原点的比例框，按用户保存顺序处理。
    /// 返回: 保持显示尺寸、RGB 色彩空间和原透明度的图片；来源改变或取消时失败。
    static func render(_ source: ImageWatermarkSource, rects: [CGRect]) async throws -> CGImage {
        try Task.checkCancellation()
        try source.identity.validate(source.url)
        guard !rects.isEmpty, rects.count <= 64 else {
            throw RecorderError.message("请框选至少一个水印，每张图片最多保存 64 个框。")
        }
        for rect in rects {
            try MovieWatermarkRegion(
                range: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1)), rect: rect
            )
            .validate(within: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1)))
        }
        let original = source.image
        let rendered = try await MovieWatermarkFrame.render(original, rects: rects)
        let colorSpace =
            original.colorSpace?.model == .rgb
            ? original.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        let before = try bitmap(original, colorSpace: colorSpace)
        let after = try bitmap(rendered, colorSpace: colorSpace)
        guard let originalData = before.data?.assumingMemoryBound(to: UInt8.self),
            let renderedData = after.data?.assumingMemoryBound(to: UInt8.self)
        else {
            throw RecorderError.message("图片缺少可访问的像素。")
        }
        let bounds = CGRect(x: 0, y: 0, width: original.width, height: original.height)
        for rect in rects {
            try Task.checkCancellation()
            let pixels = CGRect(
                x: rect.minX * bounds.width, y: rect.minY * bounds.height,
                width: rect.width * bounds.width, height: rect.height * bounds.height
            ).integral.insetBy(dx: -6, dy: -6).intersection(bounds).integral
            // 模型使用 sRGB，回写前转换回来源 RGB 色彩空间；框外和原透明度不能随之改变。
            for y in Int(pixels.minY)..<Int(pixels.maxY) {
                for x in Int(pixels.minX)..<Int(pixels.maxX) {
                    let a = originalData.advanced(by: y * before.bytesPerRow + x * 4)
                    let b = renderedData.advanced(by: y * after.bytesPerRow + x * 4)
                    let alpha = Int(a[3])
                    let paintedAlpha = Int(b[3])
                    guard alpha > 0, paintedAlpha > 0 else {
                        continue
                    }
                    for channel in 0..<3 {
                        a[channel] = UInt8(
                            min(alpha, (Int(b[channel]) * alpha + paintedAlpha / 2) / paintedAlpha))
                    }
                }
            }
        }
        try Task.checkCancellation()
        try source.identity.validate(source.url)
        guard let result = before.makeImage() else {
            throw RecorderError.message("无法生成补全图片。")
        }
        return result
    }

    /// 业务作用: 为颜色合成创建一致的八位预乘 BGRA 表示，保留来源的 RGB 色彩空间。
    /// 参数说明:
    /// - image: 待转换的完整图片。
    /// - colorSpace: 最终图片使用的 RGB 色彩空间。
    /// 返回: 独立可写像素；分配失败时不继续补全。
    static func bitmap(_ image: CGImage, colorSpace: CGColorSpace) throws -> CGContext {
        guard
            let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else {
            throw RecorderError.message("无法分配图片像素缓冲。")
        }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context
    }

    /// 业务作用: 将用户确认的补全结果另存为无损 PNG，避免覆盖原图或已有文件。
    /// 参数说明:
    /// - source: 保存前需要复验的原始图片。
    /// - image: 已准备好的完整补全结果。
    /// - destination: 用户选择的新 PNG 路径。
    /// 返回: 临时图片完成封装和身份复验后原子发布；失败或取消清理本次临时文件。
    static func export(_ source: ImageWatermarkSource, image: CGImage, to destination: URL) async throws {
        try Task.checkCancellation()
        try source.identity.validate(source.url)
        guard destination.isFileURL, destination.pathExtension.lowercased() == "png",
            destination.resolvingSymlinksInPath() != source.url.resolvingSymlinksInPath(),
            !FileManager.default.fileExists(atPath: destination.path)
        else {
            throw RecorderError.message("请另选一个未使用的 PNG 文件名，原图和已有文件不会覆盖。")
        }
        let scoped = destination.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                destination.stopAccessingSecurityScopedResource()
            }
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".ScreenRecorder-image-\(UUID().uuidString).png")
        defer {
            try? FileManager.default.removeItem(at: temporary)
        }
        guard
            let writer = CGImageDestinationCreateWithURL(
                temporary as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            throw RecorderError.message("无法创建 PNG 输出。")
        }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else {
            throw RecorderError.message("PNG 图片保存未完成。")
        }
        try Task.checkCancellation()
        try source.identity.validate(source.url)
        // 来源复验和 PNG 封装都完成后才发布；排他改名阻止文件选择后的同名竞争。
        guard renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw RecorderError.message("目标文件已存在或无法写入，请选择其他位置或文件名。")
        }
    }
}
