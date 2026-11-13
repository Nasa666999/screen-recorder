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

@MainActor
final class PixelMagnifier {
    private var task: Task<Void, Never>?

    /// 业务作用: 在选择区域时读取鼠标附近的原始像素，不建立录音或持续录制流。
    /// 参数说明:
    /// - display: 选择层对应的显示器。
    /// - applications: 必须从放大画面排除的本应用身份。
    /// - bounds: 显示器的局部逻辑范围。
    /// - point: 获取当前需要放大的控制点；鼠标离开选择层时为空。
    /// - receive: 接收带采样位置的像素图，失败时不展示旧像素冒充当前位置。
    /// 返回: 每个选择层同时最多一个截图请求，约每秒十次；图像只保留在选择界面的内存中。
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
        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())
        let side = min(21, width, height)
        task = Task {
            while !Task.isCancelled {
                if let position = point() {
                    let pixelX = min(width - 1, max(0, Int(floor(position.x * scale))))
                    let pixelY = min(height - 1, max(0, Int(floor((bounds.height - position.y) * scale))))
                    let left = min(width - side, max(0, pixelX - side / 2))
                    let top = min(height - side, max(0, pixelY - side / 2))
                    let configuration = SCStreamConfiguration()
                    configuration.sourceRect = CGRect(
                        x: CGFloat(left) / scale,
                        y: CGFloat(top) / scale,
                        width: CGFloat(side) / scale,
                        height: CGFloat(side) / scale
                    )
                    configuration.width = side
                    configuration.height = side
                    configuration.pixelFormat = kCVPixelFormatType_32BGRA
                    configuration.captureResolution = .best
                    configuration.showsCursor = false
                    configuration.capturesAudio = false
                    configuration.captureMicrophone = false
                    do {
                        let image = try await SCScreenshotManager.captureImage(
                            contentFilter: filter, configuration: configuration)
                        // 选择结束后的异步回调不能重建放大镜，也不把前一个位置的像素标成当前位置。
                        guard !Task.isCancelled else {
                            return
                        }
                        // 原始像素与网格必须一一对应，平台改变输出尺寸时不能继续声称可逐像素定位。
                        guard image.width == side, image.height == side else {
                            throw RecorderError.message("放大镜像素尺寸不匹配")
                        }
                        if point() == position {
                            receive(
                                .success(
                                    MagnifierSample(
                                        image: image,
                                        point: position,
                                        pixelX: pixelX,
                                        pixelY: pixelY,
                                        cropX: left,
                                        cropY: top
                                    )))
                        }
                    } catch {
                        if !Task.isCancelled {
                            receive(.failure(error))
                        }
                        return
                    }
                }
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
            }
        }
    }

    /// 业务作用: 选择结束立即停止后续截图，不让迟到的像素进入新的录制过程。
    /// 参数说明: 无。
    /// 返回: 正在返回的单次截图会被丢弃，之后不再读取屏幕。
    func stop() {
        task?.cancel()
        task = nil
    }
}
