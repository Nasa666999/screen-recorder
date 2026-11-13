import AppKit
import Darwin

final class RecordingLocation {
    let directory: URL
    let temporaryURL: URL
    private let scoped: Bool

    /// 业务作用: 为一次录制持有目标目录授权与唯一的未完成文件位置。
    /// 参数说明:
    /// - bookmark: 用户选择的目录引用，空值表示桌面。
    /// 返回: 目录不可用或空间不足时抛错，不更换用户保存位置。
    init(bookmark: Data?) throws {
        if let bookmark {
            var stale = false
            directory = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                bookmarkDataIsStale: &stale
            )
            if stale {
                throw RecorderError.message("保存目录授权已失效，请重新选择保存位置。")
            }
        } else {
            directory = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        }
        scoped = directory.startAccessingSecurityScopedResource()
        temporaryURL = directory.appendingPathComponent(
            ".ScreenRecorder-\(UUID().uuidString).partial.mov")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
            isDirectory.boolValue, FileManager.default.isWritableFile(atPath: directory.path)
        else {
            if scoped {
                directory.stopAccessingSecurityScopedResource()
            }
            throw RecorderError.message("保存目录不可写，请重新选择保存位置。")
        }
        do {
            let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let available = values.volumeAvailableCapacityForImportantUsage, available < 256 * 1024 * 1024
            {
                throw RecorderError.message("保存位置剩余空间不足 256 MB，请先释放空间。")
            }
        } catch {
            if scoped {
                directory.stopAccessingSecurityScopedResource()
            }
            throw error
        }
    }

    /// 业务作用: 目录不再被录制或成品操作使用时归还访问授权。
    /// 参数说明: 无。
    /// 返回: 结束本对象实际取得的安全作用域访问。
    deinit {
        if scoped {
            directory.stopAccessingSecurityScopedResource()
        }
    }

    /// 业务作用: 在同一文件系统原子发布成品，竞争产生的同名文件也不覆盖。
    /// 参数说明: 无。
    /// 返回: 已发布文件的位置；失败保留未完成位置供用户处理。
    func publish() throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "Screen Recording \(formatter.string(from: Date()))"
        for index in 0..<10_000 {
            let suffix = index == 0 ? "" : " \(index)"
            let destination = directory.appendingPathComponent("\(base)\(suffix).mov")
            // 独占重命名关闭检查与发布之间的竞争窗口，已有文件始终保留。
            if renamex_np(temporaryURL.path, destination.path, UInt32(RENAME_EXCL)) == 0 {
                return destination
            }
            if errno != EEXIST {
                throw RecorderError.message("视频已封装，但发布失败：\(String(cString: strerror(errno)))。未完成文件保留在所选目录。")
            }
        }
        throw RecorderError.message("同名文件过多，视频保留在所选目录的未完成位置。")
    }

    /// 业务作用: 只移除从未写入有效媒体的本次空产物。
    /// 参数说明: 无。
    /// 返回: 清理成功或文件原本不存在；非空文件保留。
    func removeEmptyFile() {
        let size = (try? temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size == 0 {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
    }
}
