import Foundation

enum CaptureGeometry {
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
}
