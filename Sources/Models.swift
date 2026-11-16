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
            return "自动（原始分辨率）"
        case .standard:
            return "标准（1080p）"
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
    var quality = Quality.standard
    var qualityIsExplicit: Bool?
    var frameRate = 30
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
    /// 返回: 默认使用 1080p、固定 30 fps、麦克风关闭且系统声音开启；用户明确选择的原始分辨率仍可保留。
    static func load() -> RecorderOptions {
        guard let data = UserDefaults.standard.data(forKey: "recorderOptions"),
            var options = try? JSONDecoder().decode(RecorderOptions.self, from: data)
        else {
            return RecorderOptions()
        }
        var changed = false
        if options.quality == .automatic, options.qualityIsExplicit != true {
            // 未明确选择原始分辨率时采用 1080p，避免保存的默认值继续把高分辨率来源交给编码器。
            options.quality = .standard
            options.qualityIsExplicit = false
            changed = true
        }
        if ![30, 60].contains(options.frameRate) {
            // 旧的自动帧率不能随高刷新率屏幕升到 120 fps，后续会话固定使用明确的帧率。
            options.frameRate = 30
            changed = true
        }
        if changed {
            options.save()
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
