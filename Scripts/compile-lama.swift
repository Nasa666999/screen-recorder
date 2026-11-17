import CoreML
import Foundation

@main
struct CompileLaMa {
    /// 业务作用: 将校验后的模型编译为应用可直接加载的本地资源。
    /// 参数说明: 无。
    /// 返回: 成功时替换构建目录中的模型；编译失败时保留错误并停止构建。
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            throw NSError(domain: "请指定模型包与编译目标目录。", code: 1)
        }
        let compiled = try await MLModel.compileModel(at: URL(fileURLWithPath: CommandLine.arguments[1]))
        defer {
            try? FileManager.default.removeItem(at: compiled)
        }
        let destination = URL(fileURLWithPath: CommandLine.arguments[2])
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: compiled, to: destination)
    }
}
