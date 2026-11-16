import Foundation

enum CaptureGeometry {
    /// 业务作用: 将选中的窗口表面映射到系统实际采集的合成窗口内，避免把相邻工具栏一并录入。
    /// 参数说明:
    /// - window: 用户选中的原窗口表面在屏幕中的边界。
    /// - filter: 独立窗口过滤器实际返回的全局采集边界。
    /// - scale: 采集过滤器的物理像素比例。
    /// 返回: 相对于实际采集边界的像素对齐范围；选中内容不在实际来源内时返回空，不能扩大来源。
    static func windowSourceRect(window: CGRect, filter: CGRect, scale: CGFloat) -> CGRect? {
        let chosen = window
        guard filter.contains(chosen), chosen.width >= 8, chosen.height >= 8 else {
            return nil
        }
        return alignedSourceRect(chosen.offsetBy(dx: -filter.minX, dy: -filter.minY), scale: scale)
    }

    /// 业务作用: 将来源像素按所选画质缩放为编码画布，保持比例并避免放大较小来源。
    /// 参数说明:
    /// - pixels: 当前来源的原始物理像素尺寸。
    /// - quality: 用户选择的 1080p、清晰或原始分辨率策略。
    /// 返回: 长短边符合画质上限且向下对齐为偶数的输出尺寸，原始分辨率策略不施加缩放上限。
    static func encodedSize(for pixels: CGSize, quality: Quality) -> CGSize {
        var width = pixels.width
        var height = pixels.height
        if quality != .automatic {
            let long: CGFloat = quality == .standard ? 1920 : 3840
            let short: CGFloat = quality == .standard ? 1080 : 2160
            let ratio = min(1, min(long / max(width, height), short / min(width, height)))
            width *= ratio
            height *= ratio
        }
        return CGSize(
            width: max(2, Int(width.rounded(.down)) / 2 * 2),
            height: max(2, Int(height.rounded(.down)) / 2 * 2)
        )
    }

    /// 业务作用: 将选区控制点对齐到显示器的物理像素，避免高密度屏幕上的半像素边界。
    /// 参数说明:
    /// - point: 选择视图内的鼠标位置。
    /// - bounds: 当前显示器的逻辑范围。
    /// - scale: 每个逻辑点对应的物理像素数。
    /// 返回: 位于显示器范围内、落在像素边界上的控制点。
    static func snappedPoint(_ point: CGPoint, in bounds: CGRect, scale: CGFloat) -> CGPoint {
        let scale = max(1, scale)
        return CGPoint(
            x: min(bounds.maxX, max(bounds.minX, (point.x * scale).rounded() / scale)),
            y: min(bounds.maxY, max(bounds.minY, (point.y * scale).rounded() / scale))
        )
    }

    /// 业务作用: 统一选区提示和媒体裁剪的像素边界，不把选区之外的像素写入文件。
    /// 参数说明:
    /// - rect: 显示器内以左上角为原点的逻辑选区。
    /// - scale: 来源过滤器报告的物理像素比例。
    /// 返回: 向内对齐物理像素的选区，提示边框和采集使用同一范围。
    static func alignedSourceRect(_ rect: CGRect, scale: CGFloat) -> CGRect {
        let scale = max(1, scale)
        let left = ceil(rect.minX * scale) / scale
        let top = ceil(rect.minY * scale) / scale
        return CGRect(
            x: left,
            y: top,
            width: max(0, floor(rect.maxX * scale) / scale - left),
            height: max(0, floor(rect.maxY * scale) / scale - top)
        )
    }

    /// 业务作用: 把固定的采集区域映射为桌面上的提示边框，正确处理显示器偏移和上下原点差异。
    /// 参数说明:
    /// - source: 显示器内以左上角为原点的逻辑选区。
    /// - screen: 对应显示器在 AppKit 中的全局范围。
    /// 返回: 可直接用于提示窗口的全局坐标。
    static func desktopRect(for source: CGRect, screen: CGRect) -> CGRect {
        CGRect(
            x: screen.minX + source.minX,
            y: screen.maxY - source.maxY,
            width: source.width,
            height: source.height
        )
    }

    /// 业务作用: 将窗口的全局顶部原点边界映射到 AppKit 桌面，保持跨显示器移动时的提示位置。
    /// 参数说明:
    /// - frame: Core Graphics 返回的窗口全局边界。
    /// - primaryHeight: 主显示器的逻辑高度，用于统一两套坐标原点。
    /// 返回: 与原窗口同尺寸的 AppKit 全局边界，不裁剪跨显示器窗口。
    static func desktopWindowRect(for frame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: frame.minX,
            y: primaryHeight - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    /// 业务作用: 将鼠标接收范围限制在选区及其控制点，框内可拖动整体，框外继续操作桌面。
    /// 参数说明:
    /// - region: 显示器局部坐标中的已选区域。
    /// - bounds: 当前显示器的局部范围。
    /// 返回: 选区向外扩展六个逻辑点后的局部命中范围，始终限制在当前显示器内。
    static func regionInteractionFrame(for region: CGRect, in bounds: CGRect) -> CGRect {
        region.insetBy(dx: -6, dy: -6).intersection(bounds)
    }
}
