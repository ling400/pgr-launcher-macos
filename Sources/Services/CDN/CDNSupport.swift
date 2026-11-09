import Foundation
import CryptoKit

// MARK: - Errors

/// CDN 下载/更新过程中的错误（对 UI 暴露中文 `errorDescription`）。
enum CDNError: LocalizedError {
    case configUnavailable(String)
    case invalidConfig(String)
    case manifestUnavailable(String)
    case invalidManifest(String)
    case httpStatus(Int, String)
    case invalidResponse(String)
    case rangeMismatch(String)
    case incompleteFile(expected: Int64, actual: Int64, file: String)
    case checksumMismatch(expected: String, actual: String, file: String)
    case fileWrite(String)
    case fileFailed(dest: String, attempts: Int, reason: String)
    case insufficientDisk(required: Int64, available: Int64)
    case partialFailure(failed: Int, total: Int, examples: [String])
    case cancelled

    var errorDescription: String? {
        switch self {
        case .configUnavailable(let detail):
            return "无法获取游戏配置：\(detail)"
        case .invalidConfig(let detail):
            return "游戏配置无效：\(detail)"
        case .manifestUnavailable(let detail):
            return "无法获取游戏文件清单：\(detail)"
        case .invalidManifest(let detail):
            return "游戏文件清单无效：\(detail)"
        case .httpStatus(let code, let detail):
            return "服务器返回 HTTP \(code)（\(detail)）"
        case .invalidResponse(let detail):
            return "服务器响应无效：\(detail)"
        case .rangeMismatch(let detail):
            return "断点续传范围不匹配：\(detail)"
        case .incompleteFile(let expected, let actual, let file):
            return "文件不完整（\(file)）：期望 \(expected) 字节，实际 \(actual) 字节"
        case .checksumMismatch(let expected, let actual, let file):
            return "MD5 校验失败（\(file)）：期望 \(expected)，实际 \(actual)"
        case .fileWrite(let detail):
            return "写入文件失败：\(detail)"
        case .fileFailed(let dest, let attempts, let reason):
            return "下载失败（\(dest)，已尝试 \(attempts) 次）：\(reason)"
        case .insufficientDisk(let required, let available):
            return "磁盘空间不足：需要 \(CDNFormat.bytes(required))（含预留余量），可用 \(CDNFormat.bytes(available))"
        case .partialFailure(let failed, let total, let examples):
            let detail = examples.isEmpty ? "" : "：\(examples.joined(separator: "；"))"
            return "\(failed)/\(total) 个文件下载失败，其余文件已保存，可再次运行继续下载\(detail)"
        case .cancelled:
            return "已取消"
        }
    }
}

// MARK: - 文件系统工具

enum CDNFS {
    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// 直接走 POSIX `stat(2)`（比 FileManager.attributesOfItem 快一个数量级：85k 文件约 0.3s vs ~8s）。
    static func statInfo(_ url: URL) -> (size: Int64, mtime: Double)? {
        var info = Darwin.stat()
        let ok = url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return stat(path, &info) == 0
        }
        guard ok else { return nil }
        let mtime = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return (Int64(info.st_size), mtime)
    }

    static func size(_ url: URL) -> Int64? {
        statInfo(url)?.size
    }

    static func mtime(_ url: URL) -> Double? {
        statInfo(url)?.mtime
    }

    static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    static func removeIfExists(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func atomicWrite(_ data: Data, to url: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        try data.write(to: url, options: [.atomic])
    }

    static func readData(_ url: URL, maxBytes: Int = 32 * 1024 * 1024) -> Data? {
        guard let size = size(url), size >= 0, size <= Int64(maxBytes) else { return nil }
        return try? Data(contentsOf: url, options: [.mappedIfSafe])
    }

    /// 把 `indexFile.json` 中的 `dest`（相对游戏根目录）解析成本地文件 URL。
    /// 拒绝绝对路径 / 盘符 / `..`，保证不会逃逸出 `gameDir`。
    static func fileURL(gameDir: URL, dest: String) -> URL? {
        let normalized = dest.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.hasPrefix("/") else { return nil }
        if normalized.count >= 2 {
            let chars = Array(normalized.prefix(2))
            if chars[0].isLetter, chars[1] == ":" { return nil }
        }
        let components = normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty else { return nil }
        guard !components.contains("..") else { return nil }
        guard !components.contains(where: { $0.isEmpty || $0 == "." }) else { return nil }

        let url = gameDir.appendingPathComponent(normalized)
        let rootPath = gameDir.standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path
        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else { return nil }
        return url
    }

    /// 把下载完成的临时文件移动到最终路径（同卷 rename 原子替换；跨卷退化为「复制到目标目录临时文件 + 替换」）。
    static func moveReplacing(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        try ensureDirectory(destination.deletingLastPathComponent())
        do {
            if fileManager.fileExists(atPath: destination.path) {
                do {
                    _ = try fileManager.replaceItemAt(destination, withItemAt: source)
                } catch {
                    try? fileManager.removeItem(at: destination)
                    try fileManager.moveItem(at: source, to: destination)
                }
            } else {
                try fileManager.moveItem(at: source, to: destination)
            }
        } catch {
            // 跨卷（例如游戏装在外部硬盘）：先复制到目标目录再替换，最后删除源文件。
            let staging = destination.deletingLastPathComponent()
                .appendingPathComponent(".\(destination.lastPathComponent).cdn-staging")
            try? fileManager.removeItem(at: staging)
            do {
                try fileManager.copyItem(at: source, to: staging)
                if fileManager.fileExists(atPath: destination.path) {
                    try? fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: staging, to: destination)
                try? fileManager.removeItem(at: source)
            } catch {
                try? fileManager.removeItem(at: staging)
                throw error
            }
        }
        try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
    }

    /// 用于文件名安全化（缓存键）。
    static func sanitized(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.+"))
        return String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }
}

// MARK: - MD5（CryptoKit 流式计算）

enum CDNMD5 {
    static func hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 流式计算文件 MD5（大文件只读 1MB 块，内存占用恒定；支持取消）。
    static func file(_ url: URL, chunkSize: Int = 1 << 20, isCancelled: () -> Bool = { false }) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.MD5()
        while true {
            if isCancelled() { throw CancellationError() }
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 分片临时文件位置（放在 appSupportDir/CDN/state/parts，不污染游戏目录）

enum CDNHash {
    /// 稳定的短 key（文件路径 → 16 字节 hex），用于分片文件名。
    static func key(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum CDNParts {
    static func directory(appSupportDir: URL) -> URL {
        appSupportDir.appendingPathComponent("CDN/state/parts", isDirectory: true)
    }

    /// 分片文件与元数据路径（按目标绝对路径 hash，跨渠道/版本复用同一位置，靠 meta 的 md5+size 判断是否可续）。
    static func urls(destURL: URL, partsDir: URL) -> (part: URL, meta: URL) {
        let key = CDNHash.key(destURL.standardizedFileURL.path)
        return (
            partsDir.appendingPathComponent("\(key).part"),
            partsDir.appendingPathComponent("\(key).part.meta")
        )
    }

    /// 全部下载成功后清理续传分片（失败/取消时保留，供下次续传）。
    static func clear(_ partsDir: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: partsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

// MARK: - URL 拼接 / 编码

enum CDNURL {
    /// 去掉尾部 `/`，得到 CDN 根（例如 `https://zspms-volcdn-gamestarter.kurogame.net`）。
    static func normalizedRoot(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    static func joinPath(_ lhs: String, _ rhs: String) -> String {
        var a = lhs
        var b = rhs
        while a.hasPrefix("/") { a.removeFirst() }
        while b.hasPrefix("/") { b.removeFirst() }
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a.hasSuffix("/") ? a + b : a + "/" + b
    }

    static func percentEncodePath(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        // `%` 会引入非法转义；`?`/`#` 会截断路径。
        allowed.remove(charactersIn: "%#?")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    /// 单文件下载 URL = CDN 根 + config.baseUrl + indexFile 里的 dest。
    static func fileURL(root: String, baseUrl: String, dest: String) -> URL? {
        let normalizedRoot = normalizedRoot(root)
        let fullPath = joinPath(baseUrl, percentEncodePath(dest))
        guard let url = URL(string: normalizedRoot + "/" + fullPath) else { return nil }
        return url
    }

    /// 清单 / 配置类 URL（路径已含 baseUrl 时传空字符串）。
    static func url(root: String, path: String) -> URL? {
        let normalizedRoot = normalizedRoot(root)
        let encoded = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { percentEncodePath(String($0)) }
            .joined(separator: "/")
        guard !encoded.isEmpty else { return nil }
        return URL(string: normalizedRoot + "/" + encoded)
    }
}

// MARK: - 响应头解析

struct CDNContentRange: Equatable {
    var start: Int64
    var end: Int64
    var total: Int64?
}

enum CDNParse {
    /// 解析 `Content-Range: bytes 1000000-1999999/10144432`。
    static func contentRange(_ header: String) -> CDNContentRange? {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ")
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        let numbers = parts[1].split(separator: "/")
        guard numbers.count == 2 else { return nil }
        let range = numbers[0].split(separator: "-")
        guard range.count == 2,
              let start = Int64(range[0]),
              let end = Int64(range[1]) else { return nil }
        let total: Int64?
        if numbers[1] == "*" {
            total = nil
        } else {
            total = Int64(numbers[1])
        }
        return CDNContentRange(start: start, end: end, total: total)
    }
}

// MARK: - 格式化

enum CDNFormat {
    static func bytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(bytes) / 1024.0
        var index = 0
        while value >= 1024 && index < units.count - 1 {
            value /= 1024.0
            index += 1
        }
        return String(format: "%.2f %@", value, units[index])
    }

    static func speed(_ bytesPerSecond: Int64) -> String {
        bytes(max(0, bytesPerSecond)) + "/s"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return String(format: "%.0f ms", seconds * 1000) }
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        return String(format: "%.1f min", seconds / 60)
    }
}

// MARK: - 版本号解析（`{package_version:4.9.1}` 与标准 JSON 均兼容）

enum CDNVersion {
    static func parse(_ data: Data) -> String? {
        guard data.count <= 64 * 1024 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        if let regex = try? NSRegularExpression(
            pattern: "package_version\\s*[:=]\\s*\"?([0-9A-Za-z._+-]+)\"?"),
           let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text)),
           match.numberOfRanges > 1,
           let range = Range(match.range(at: 1), in: text) {
            return String(text[range])
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["package_version", "packageVersion", "version"] {
                if let value = object[key] as? String, !value.isEmpty { return value }
                if let value = object[key] as? NSNumber { return value.stringValue }
            }
        }
        if let regex = try? NSRegularExpression(pattern: "\\d+\\.\\d+(?:\\.\\d+){0,2}"),
           let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text)),
           let range = Range(match.range, in: text) {
            return String(text[range])
        }
        return nil
    }

    /// 读取本地 `gameDir/version.json` 里的 `package_version`。
    static func readLocal(gameDir: URL) -> String? {
        let url = gameDir.appendingPathComponent("version.json")
        guard let data = CDNFS.readData(url, maxBytes: 64 * 1024) else { return nil }
        return parse(data)
    }
}

// MARK: - 线程安全日志（后台线程统一转 MainActor，避免污染 @Published）

enum CDNLog {
    static func info(_ logger: Logger, _ message: String) { log(logger, .info, message) }
    static func warn(_ logger: Logger, _ message: String) { log(logger, .warn, message) }
    static func error(_ logger: Logger, _ message: String) { log(logger, .error, message) }

    private static func log(_ logger: Logger, _ level: LogLevel, _ message: String) {
        if Thread.isMainThread {
            logger.log(level, message)
        } else {
            DispatchQueue.main.async {
                logger.log(level, message)
            }
        }
    }
}

// MARK: - 可取消休眠

enum CDNSleep {
    static func sleep(seconds: TimeInterval) async throws {
        guard seconds > 0 else {
            if Task.isCancelled { throw CancellationError() }
            return
        }
        let nanoseconds = UInt64(min(seconds, 300) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}
