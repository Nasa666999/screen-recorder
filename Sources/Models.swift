import AVFoundation
import AppKit
import ScreenCaptureKit

enum CaptureMode: String, Codable, CaseIterable {
    case display
    case window
    case region

    var spaceHint: String {
        switch self {
        case .window:
            return "切换桌面后仍录原窗口"
        case .display, .region:
            return "随桌面切换；跨桌面固定录制请选窗口"
        }
    }

    var title: String {
        switch self {
        case .display:
            return "录制整个屏幕"
        case .window:
            return "录制窗口"
        case .region:
            return "录制所选区域"
        }
    }
}

enum Quality: String, Codable, CaseIterable {
    case automatic
    case standard
    case clear

    var title: String {
        switch self {
        case .automatic:
            return "自动"
        case .standard:
            return "标准（最长边 1920）"
        case .clear:
            return "清晰（最长边 3840）"
        }
    }
}

struct RecorderOptions: Codable {
    static var microphones: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }
    var mode = CaptureMode.display
    var systemAudio = true
    var audioApplicationBundleIDs: [String]?
    var microphoneID: String?
    var quality = Quality.automatic
    var frameRate = 0
    var countdown = 0
    var confirmBeforeRecording = false
    var hdr = false
    var showThumbnail = true
    var rememberSelection = true
    var showMouseClicks = false
    var directoryBookmark: Data?
    var savedDisplayID: UInt32?
    var savedRegion: CGRect?

    var systemAudioSummary: String {
        if !systemAudio {
            return "关闭"
        }
        if let applications = audioApplicationBundleIDs {
            return "仅所选应用（\(applications.count) 个，所有桌面）"
        }
        return "全部系统声音（所有桌面）"
    }

    /// 业务作用: 恢复用户主动选择的录制选项，损坏配置回到安全默认值。
    /// 参数说明: 无。
    /// 返回: 麦克风默认关闭且系统声音默认开启的有效配置。
    static func load() -> RecorderOptions {
        guard let data = UserDefaults.standard.data(forKey: "recorderOptions"),
            let options = try? JSONDecoder().decode(RecorderOptions.self, from: data)
        else {
            return RecorderOptions()
        }
        return options
    }

    /// 业务作用: 保存选项，不持久化窗口身份或开启新的采集。
    /// 参数说明: 无。
    /// 返回: 下次启动可恢复当前选项。
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "recorderOptions")
        }
    }
}

enum RecorderError: LocalizedError {
    case message(String)

    /// 业务作用: 保留系统错误的来源和编号，权限或编码失败时便于准确处理。
    /// 参数说明:
    /// - error: 系统或本应用返回的失败。
    /// 返回: 不包含额外媒体内容的错误描述。
    static func describe(_ error: Error) -> String {
        if let own = error as? RecorderError {
            return own.localizedDescription
        }
        let system = error as NSError
        return "\(system.localizedDescription)（\(system.domain) \(system.code)）"
    }

    var errorDescription: String? {
        switch self {
        case .message(let description):
            return description
        }
    }
}

struct CaptureSelection {
    let display: SCDisplay
    let window: SCWindow?
    let region: CGRect?

    var summary: String {
        if let window {
            return window.title ?? window.owningApplication?.applicationName ?? "所选窗口"
        }
        if let region {
            return "所选区域 \(Int(region.width)) × \(Int(region.height))"
        }
        return "整个屏幕"
    }
}

enum RecordingState: Equatable {
    case idle
    case selecting
    case preparing
    case countingDown(Int)
    case starting
    case recording
    case stopping
    case needsAttention

    var isBusy: Bool {
        switch self {
        case .idle, .selecting:
            return false
        default:
            return true
        }
    }
}
