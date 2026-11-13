import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 业务作用: 用统一的矢量图形生成应用图标，在各尺寸保持屏幕和录制标识清楚可辨。
/// 参数说明:
/// - size: 输出图像的像素边长。
/// 返回: 带透明外缘的 sRGB 图像；绘图资源不可用时抛错并停止生成。
func render(size: Int) throws -> CGImage {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else {
        throw CocoaError(.fileWriteUnknown)
    }
    let scale = CGFloat(size) / 1024
    context.scaleBy(x: scale, y: scale)
    let tile = CGRect(
        x: 64,
        y: 64,
        width: 896,
        height: 896
    )
    let background = CGPath(
        roundedRect: tile,
        cornerWidth: 196,
        cornerHeight: 196,
        transform: nil
    )
    let colors = [
        CGColor(
            srgbRed: 0.33,
            green: 0.83,
            blue: 0.95,
            alpha: 1
        ),
        CGColor(
            srgbRed: 0.56,
            green: 0.43,
            blue: 0.96,
            alpha: 1
        ),
    ]
    guard
        let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: colors as CFArray,
            locations: [0, 1]
        )
    else {
        throw CocoaError(.fileWriteUnknown)
    }
    context.saveGState()
    context.addPath(background)
    context.clip()
    context.drawLinearGradient(
        gradient,
        start: CGPoint(
            x: 512,
            y: tile.maxY
        ),
        end: CGPoint(
            x: 512,
            y: tile.minY
        ),
        options: []
    )
    context.restoreGState()

    context.setStrokeColor(
        CGColor(
            gray: 1,
            alpha: 1
        ))
    context.setLineWidth(32)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    let screen = CGPath(
        roundedRect: CGRect(
            x: 224,
            y: 368,
            width: 576,
            height: 368
        ),
        cornerWidth: 48,
        cornerHeight: 48,
        transform: nil
    )
    context.addPath(screen)
    context.strokePath()
    context.move(
        to: CGPoint(
            x: 512,
            y: 368
        ))
    context.addLine(
        to: CGPoint(
            x: 512,
            y: 280
        ))
    context.move(
        to: CGPoint(
            x: 400,
            y: 280
        ))
    context.addLine(
        to: CGPoint(
            x: 624,
            y: 280
        ))
    context.strokePath()

    context.setFillColor(
        CGColor(
            srgbRed: 1,
            green: 0.24,
            blue: 0.29,
            alpha: 1
        ))
    context.fillEllipse(
        in: CGRect(
            x: 432,
            y: 472,
            width: 160,
            height: 160
        ))
    guard let image = context.makeImage() else {
        throw CocoaError(.fileWriteUnknown)
    }
    return image
}

/// 业务作用: 将单个尺寸保存为系统图标工具可直接读取的 PNG。
/// 参数说明:
/// - image: 已绘制的图标图像。
/// - destination: 当前尺寸的目标文件位置。
/// 返回: PNG 完整写入；失败时停止，避免封装缺失尺寸的图标。
func save(_ image: CGImage, to destination: URL) throws {
    guard
        let writer = CGImageDestinationCreateWithURL(
            destination as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        )
    else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(writer, image, nil)
    guard CGImageDestinationFinalize(writer) else {
        throw CocoaError(.fileWriteUnknown)
    }
}

/// 业务作用: 从同一矢量来源生成 macOS 图标的标准尺寸与 Retina 尺寸。
/// 参数说明:
/// - directory: 供 iconutil 封装的图标目录。
/// 返回: 完整保存十个 PNG 文件，不访问其他项目或用户文件。
func generate(in directory: URL) throws {
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let suffix = scale == 2 ? "@2x" : ""
            let filename = "icon_\(size)x\(size)\(suffix).png"
            try save(render(size: size * scale), to: directory.appendingPathComponent(filename))
        }
    }
}

let directory = URL(
    fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.iconset",
    isDirectory: true
)
try generate(in: directory)
