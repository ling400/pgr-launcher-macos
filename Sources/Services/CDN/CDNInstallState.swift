import Foundation

/// 本地状态缓存：
/// - `verified`：记录「dest → (size, mtime, md5)」，用于跳过重复 MD5 校验（68GB 游戏不可能每次更新都全量重算）；
/// - `installed`：记录上次成功安装的清单版本 / manifest MD5（仅用于版本文案与诊断）。
final class CDNInstallState: @unchecked Sendable {
    struct Record: Codable {
        var size: Int64
        var mtime: Double
        var md5: String
    }

    struct InstalledMarker: Codable {
        var version: String
        var manifestMd5: String?
        var gameDir: String
        var files: Int
        var bytes: Int64
        var fileVersion: String?
        var installedAt: Double
    }

    private let logger: Logger
    private let recordsURL: URL
    private let markerURL: URL
    private let lock = NSLock()
    private var records: [String: Record] = [:]
    private var dirty = false
    /// 上次落盘时间 / 文件数阈值：每 ~4000 条或 30s 增量保存一次，避免进程被硬杀时丢失校验进度。
    private var lastSaveAt = Date()

    init(stateDir: URL, channelID: String, logger: Logger) {
        self.logger = logger
        let safeChannel = CDNFS.sanitized(channelID)
        self.recordsURL = stateDir.appendingPathComponent("\(safeChannel)-verified.json")
        self.markerURL = stateDir.appendingPathComponent("\(safeChannel)-installed.json")
        try? CDNFS.ensureDirectory(stateDir)
        if let data = CDNFS.readData(recordsURL, maxBytes: 64 * 1024 * 1024),
           let decoded = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = decoded
            CDNLog.info(logger, "本地校验缓存已加载：\(decoded.count) 条")
        }
    }

    // MARK: Verified records

    func isVerified(dest: String, size: Int64, mtime: Double, md5: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let record = records[dest] else { return false }
        return record.size == size
            && record.md5.caseInsensitiveCompare(md5) == .orderedSame
            && abs(record.mtime - mtime) < 0.001
    }

    /// 记录一个已校验文件；返回 true 表示建议立即调用 `saveIfNeeded()` 落盘。
    @discardableResult
    func record(entry: CDNManifestEntry, destURL: URL) -> Bool {
        guard let size = CDNFS.size(destURL), let mtime = CDNFS.mtime(destURL) else { return false }
        lock.lock()
        records[entry.dest] = Record(size: size, mtime: mtime, md5: entry.md5)
        dirty = true
        let now = Date()
        let due = records.count % 4000 == 0 || now.timeIntervalSince(lastSaveAt) >= 30
        if due { lastSaveAt = now }
        lock.unlock()
        return due
    }

    // MARK: Installed marker

    func markInstalled(
        version: String,
        manifestMd5: String?,
        gameDir: URL,
        files: Int,
        bytes: Int64,
        fileVersion: String?
    ) {
        let marker = InstalledMarker(
            version: version,
            manifestMd5: manifestMd5,
            gameDir: gameDir.path,
            files: files,
            bytes: bytes,
            fileVersion: fileVersion,
            installedAt: Date().timeIntervalSince1970)
        if let data = try? JSONEncoder().encode(marker) {
            try? CDNFS.atomicWrite(data, to: markerURL)
        }
    }

    func installedMarker() -> InstalledMarker? {
        guard let data = CDNFS.readData(markerURL, maxBytes: 64 * 1024) else { return nil }
        return try? JSONDecoder().decode(InstalledMarker.self, from: data)
    }

    // MARK: Persist

    func saveIfNeeded(force: Bool = false) {
        lock.lock()
        if !dirty && !force {
            lock.unlock()
            return
        }
        let snapshot = records
        let wasDirty = dirty
        dirty = false
        lastSaveAt = Date()
        lock.unlock()
        guard wasDirty || force else { return }
        do {
            let data = try JSONEncoder().encode(snapshot)
            try CDNFS.atomicWrite(data, to: recordsURL)
            if wasDirty {
                CDNLog.info(logger, "本地校验缓存已保存：\(snapshot.count) 条（\(CDNFormat.bytes(Int64(data.count)))）")
            }
        } catch {
            CDNLog.warn(logger, "本地校验缓存写入失败：\(error.localizedDescription)")
        }
    }
}
