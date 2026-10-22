import Foundation

/// 应用日志的落盘位置与权限。
///
/// 不写 /tmp: 日志含逐字符注入路径, 那是用户剪贴板内容的衍生数据。
/// /tmp 是世界可读、且任何账户都能预先占位的目录 —— 把它放在那里, 等于把
/// 敲进堡垒机的口令留给本机所有账户, 而且文件会一直留着。
/// 改为 ~/Library/Logs 下的 0600 文件: 只有当前用户能读, 位置也符合 macOS 惯例。
enum TypeLog {

    private static let logsDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs", isDirectory: true)

    /// 主日志: ~/Library/Logs/TypeClip.log
    static let path = logsDirectory.appendingPathComponent("TypeClip.log").path

    /// KeyDiag 输出(内容只有 v1~v8 标记, 不涉剪贴板): ~/Library/Logs/TypeClip-keydiag.log
    static let diagPath = logsDirectory.appendingPathComponent("TypeClip-keydiag.log").path

    /// 旧版本位置, 仅用于提示用户老日志还在这儿。
    static let legacyPath = "/tmp/typeclip-type.log"

    /// 覆盖写, 并强制 0600。
    @discardableResult
    static func write(_ body: String) -> Bool {
        guard let data = body.data(using: .utf8) else { return false }
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            // atomic 写入会按 umask 生成一个新文件(通常 0644), 所以写完再收紧。
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return true
        } catch {
            return false
        }
    }

    /// 追加一行到诊断日志(KeyDiag 用), 同样强制 0600。
    static func appendDiag(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        do {
            try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
            if let handle = FileHandle(forWritingAtPath: diagPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try data.write(to: URL(fileURLWithPath: diagPath), options: .atomic)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: diagPath)
        } catch {
            // 诊断日志写不进去不影响诊断本身(还有 stdout 与 NSLog 两条路)。
        }
    }
}
