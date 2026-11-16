import AppKit
import ScreenCaptureKit

struct MagnifierSample {
    let image: CGImage
    let point: CGPoint
    let pixelX: Int
    let pixelY: Int
    let cropX: Int
    let cropY: Int
}

struct MagnifierRegion {
    let pixelX: Int
    let pixelY: Int
    let rect: CGRect

    /// 业务作用: 以控制点为中心确定原始像素范围，屏幕边缘只平移取样框而不放大像素。
    /// 参数说明:
    /// - point: 选择视图内以左下角为原点的控制点。
    /// - bounds: 当前显示器的局部逻辑范围。
    /// - scale: 每个逻辑点对应的物理像素数。
    /// - side: 需要读取的最大像素边长。
    /// 返回: 显示器像素范围有效时返回顶部原点的整数像素框，否则返回空。
    static func around(point: CGPoint, bounds: CGRect, scale: CGFloat, side: Int) -> MagnifierRegion? {
        guard scale.isFinite, scale > 0, bounds.width.isFinite, bounds.height.isFinite,
            bounds.width > 0, bounds.height > 0, point.x.isFinite, point.y.isFinite, side > 0
        else {
            return nil
        }
        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())
        let side = min(side, width, height)
        guard side > 0 else {
            return nil
        }
        let pixelX = min(width - 1, max(0, Int(floor((point.x - bounds.minX) * scale))))
        let pixelY = min(height - 1, max(0, Int(floor((bounds.maxY - point.y) * scale))))
        return MagnifierRegion(
            pixelX: pixelX,
            pixelY: pixelY,
            rect: CGRect(
                x: min(width - side, max(0, pixelX - side / 2)),
                y: min(height - side, max(0, pixelY - side / 2)),
                width: side,
                height: side
            )
        )
    }
}

struct MagnifierSnapshot {
    let image: CGImage
    let rect: CGRect
    let bounds: CGRect
    let scale: CGFloat

    /// 业务作用: 在不创建图像的情况下判断缓存是否完整覆盖当前像素网格。
    /// 参数说明:
    /// - point: 当前需要显示的控制点。
    /// 返回: 图像尺寸和覆盖范围均有效时返回当前取样框，否则返回空并等待新截图。
    func sampleRegion(at point: CGPoint) -> MagnifierRegion? {
        guard let region = MagnifierRegion.around(point: point, bounds: bounds, scale: scale, side: 21),
            image.width == Int(rect.width), image.height == Int(rect.height), rect.contains(region.rect)
        else {
            return nil
        }
        return region
    }

    /// 业务作用: 从附近的原始像素缓存同步裁出当前控制点，鼠标移动后仍使用实际对应的坐标。
    /// 参数说明:
    /// - point: 当前需要显示的控制点，可与截图发起位置不同。
    /// 返回: 缓存完整覆盖当前位置的像素网格时返回样本；移出缓存时返回空，不挪用其他位置的图像。
    func sample(at point: CGPoint) -> MagnifierSample? {
        guard let region = sampleRegion(at: point),
            let crop = image.cropping(to: region.rect.offsetBy(dx: -rect.minX, dy: -rect.minY))
        else {
            return nil
        }
        return MagnifierSample(
            image: crop,
            point: point,
            pixelX: region.pixelX,
            pixelY: region.pixelY,
            cropX: Int(region.rect.minX),
            cropY: Int(region.rect.minY)
        )
    }
}

@MainActor
final class PixelMagnifier {
    private var task: Task<Void, Never>?
    private var snapshot: MagnifierSnapshot?
    private var receive: ((Result<MagnifierSample, Error>) -> Void)?

    /// 业务作用: 在选择区域时读取鼠标附近的原始像素，不建立录音或持续录制流。
    /// 参数说明:
    /// - display: 选择层对应的显示器。
    /// - applications: 必须从放大画面排除的本应用身份。
    /// - bounds: 显示器的局部逻辑范围。
    /// - point: 获取当前需要放大的控制点；鼠标离开选择层时为空。
    /// - receive: 接收带采样位置的像素图，失败时不展示旧像素冒充当前位置。
    /// 返回: 同时最多一个截图请求，定时刷新或移出缓存时读取附近最多 512×512 原始像素；不缓存完整桌面。
    func start(
        display: SCDisplay, applications: [SCRunningApplication], bounds: CGRect,
        point: @escaping () -> CGPoint?, receive: @escaping (Result<MagnifierSample, Error>) -> Void
    ) {
        stop()
        // 排除自身才能读取被遮罩覆盖前的内容，身份不足时不启动会产生递归画面的截图。
        guard !applications.isEmpty else {
            receive(.failure(RecorderError.message("放大镜暂不可用")))
            return
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: applications,
            exceptingWindows: []
        )
        let scale = CGFloat(filter.pointPixelScale)
        self.receive = receive
        let configuration = SCStreamConfiguration()
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.captureResolution = .best
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.captureMicrophone = false
        task = Task {
            var nextCapture = ContinuousClock.now
            while !Task.isCancelled {
                if let position = point() {
                    if snapshot?.sampleRegion(at: position) != nil, ContinuousClock.now < nextCapture {
                        do {
                            try await Task.sleep(for: .milliseconds(16))
                        } catch {
                            return
                        }
                        continue
                    }
                    guard
                        let region = MagnifierRegion.around(
                            point: position, bounds: bounds, scale: scale, side: 512)
                    else {
                        receive(.failure(RecorderError.message("放大镜像素范围不可用")))
                        return
                    }
                    // 截图耗时计入刷新间隔；移动越出缓存时直接读取最新位置，不额外等待固定冷却时间。
                    nextCapture = ContinuousClock.now.advanced(by: .milliseconds(100))
                    configuration.sourceRect = CGRect(
                        x: region.rect.minX / scale,
                        y: region.rect.minY / scale,
                        width: region.rect.width / scale,
                        height: region.rect.height / scale
                    )
                    configuration.width = Int(region.rect.width)
                    configuration.height = Int(region.rect.height)
                    do {
                        let image = try await SCScreenshotManager.captureImage(
                            contentFilter: filter, configuration: configuration)
                        // 选择结束后的异步回调不能重建缓存，也不能进入下一轮选择。
                        guard !Task.isCancelled else {
                            return
                        }
                        // 原始像素与网格必须一一对应，平台改变输出尺寸时不能继续声称可逐像素定位。
                        guard image.width == configuration.width, image.height == configuration.height else {
                            throw RecorderError.message("放大镜像素尺寸不匹配")
                        }
                        snapshot = MagnifierSnapshot(
                            image: image,
                            rect: region.rect,
                            bounds: bounds,
                            scale: scale
                        )
                        // 请求期间鼠标可以继续移动，只要缓存覆盖最新位置就裁取该位置，不要求鼠标静止。
                        if let current = point() {
                            update(at: current)
                        }
                    } catch {
                        if !Task.isCancelled {
                            snapshot = nil
                            receive(.failure(error))
                        }
                        return
                    }
                }
                do {
                    try await Task.sleep(for: .milliseconds(16))
                } catch {
                    return
                }
            }
        }
    }

    /// 业务作用: 鼠标移动时立即从小范围缓存更新放大图，选择交互不等待新截图。
    /// 参数说明:
    /// - point: 当前像素对齐的控制点。
    /// 返回: 缓存覆盖时同步发布精确位置的样本，否则等待正在进行的截图，不显示错误位置的像素。
    func update(at point: CGPoint) {
        if let sample = snapshot?.sample(at: point) {
            receive?(.success(sample))
        }
    }

    /// 业务作用: 选择结束立即停止后续截图，不让迟到的像素进入新的录制过程。
    /// 参数说明: 无。
    /// 返回: 正在返回的单次截图会被丢弃，释放像素缓存和接收入口，之后不再读取屏幕。
    func stop() {
        task?.cancel()
        task = nil
        snapshot = nil
        receive = nil
    }
}
