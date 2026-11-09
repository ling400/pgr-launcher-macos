import Foundation

/// 下载 / 校验 / 缓存游戏清单（indexFile.json，约 13.7MB、~85k 个文件）。
///
/// 缓存文件：`<cacheDir>/manifest-<channel>-<version>-<indexFileMd5>.json`。
/// 命中缓存时先做 MD5 校验（可用 `indexFileMd5`）再解析，避免使用被截断的缓存。
final class CDNManifestStore: @unchecked Sendable {
    private let logger: Logger
    private let cacheDir: URL
    private let session: URLSession

    init(logger: Logger, cacheDir: URL) {
        self.logger = logger
        self.cacheDir = cacheDir
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 10 * 60
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    func load(config: CDNRemoteConfig, cacheKey: String) async throws -> CDNManifest {
        let startedAt = Date()
        let safeChannel = CDNFS.sanitized(cacheKey)
        let safeVersion = CDNFS.sanitized(config.version)
        let md5Key = config.indexFileMd5?.lowercased()
        let fileName = "manifest-\(safeChannel)-\(safeVersion)-\(md5Key ?? "nomd5").json"
        let cacheURL = cacheDir.appendingPathComponent(fileName)

        if let cached = loadFromCache(cacheURL: cacheURL, expectedMd5: md5Key, startedAt: startedAt) {
            pruneOldManifests(keeping: cacheURL, channelKey: safeChannel)
            return cached
        }

        var errors: [String] = []
        for round in 1...2 {
            if round > 1 {
                CDNLog.warn(logger, "清单下载失败，1s 后重试（\(errors.count) 次失败）")
                try await CDNSleep.sleep(seconds: 1.0)
            }
            for root in config.cdnRoots {
                if Task.isCancelled { throw CancellationError() }
                guard let url = CDNURL.url(root: root, path: config.indexFile) else {
                    errors.append("\(root)：无法构造清单 URL")
                    continue
                }
                do {
                    let data = try await fetch(url)
                    let digest = CDNMD5.hex(data)
                    if let expected = md5Key, digest.caseInsensitiveCompare(expected) != .orderedSame {
                        errors.append("\(root)：清单 MD5 不匹配（期望 \(expected)，实际 \(digest)）")
                        CDNLog.warn(logger, "清单 MD5 不匹配：\(root)（期望 \(expected)，实际 \(digest)）")
                        continue
                    }
                    let manifest = try CDNManifest.parse(data)
                    try? CDNFS.atomicWrite(data, to: cacheURL)
                    let elapsed = Date().timeIntervalSince(startedAt)
                    var result = manifest
                    result.md5 = digest
                    result.fromCache = false
                    result.elapsed = elapsed
                    CDNLog.info(
                        logger,
                        "游戏清单已下载：\(result.entries.count) 个文件，\(CDNFormat.bytes(result.totalBytes))，"
                        + "\(CDNFormat.bytes(Int64(data.count))) 清单（\(CDNFormat.duration(elapsed))）")
                    pruneOldManifests(keeping: cacheURL, channelKey: safeChannel)
                    return result
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let reason = describe(error)
                    errors.append("\(root)：\(reason)")
                    CDNLog.warn(logger, "清单下载失败：\(root) → \(reason)")
                }
            }
        }

        // 把缓存里同版本（md5 可能不同）的旧清单作为最后兜底？不使用：版本不同会导致文件计划错误。
        throw CDNError.manifestUnavailable(errors.joined(separator: "；"))
    }

    // MARK: Cache

    private func loadFromCache(cacheURL: URL, expectedMd5: String?, startedAt: Date) -> CDNManifest? {
        guard let size = CDNFS.size(cacheURL), size > 1024 else { return nil }
        guard let data = CDNFS.readData(cacheURL, maxBytes: 64 * 1024 * 1024) else { return nil }
        if let expected = expectedMd5 {
            let digest = CDNMD5.hex(data)
            guard digest.caseInsensitiveCompare(expected) == .orderedSame else {
                CDNLog.warn(logger, "清单缓存校验失败（MD5 不匹配），重新下载：\(cacheURL.lastPathComponent)")
                CDNFS.removeIfExists(cacheURL)
                return nil
            }
        }
        do {
            var manifest = try CDNManifest.parse(data)
            manifest.md5 = expectedMd5 ?? CDNMD5.hex(data)
            manifest.fromCache = true
            manifest.elapsed = Date().timeIntervalSince(startedAt)
            CDNLog.info(
                logger,
                "游戏清单已就绪（缓存）：\(manifest.entries.count) 个文件，\(CDNFormat.bytes(manifest.totalBytes))，"
                + "\(CDNFormat.duration(manifest.elapsed))")
            return manifest
        } catch {
            CDNLog.warn(logger, "清单缓存无效，重新下载：\(cacheURL.lastPathComponent)")
            CDNFS.removeIfExists(cacheURL)
            return nil
        }
    }

    /// 每个渠道最多保留 2 份清单缓存（每份约 13.7MB）。
    private func pruneOldManifests(keeping current: URL, channelKey: String) {
        let prefix = "manifest-\(channelKey)-"
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }
        let manifests = files
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0 != current }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return left > right
            }
        for old in manifests.dropFirst(1) {
            CDNFS.removeIfExists(old)
        }
    }

    // MARK: Network

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.setValue("PGRLauncher/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CDNError.invalidResponse("非 HTTP 响应（\(url.absoluteString)）")
        }
        guard http.statusCode == 200 else {
            throw CDNError.httpStatus(http.statusCode, "GET \(url.absoluteString)")
        }
        guard data.count > 1024 else {
            throw CDNError.invalidResponse("清单响应过小（\(data.count) 字节）")
        }
        return data
    }

    private func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        if error is CancellationError { return "已取消" }
        return (error as NSError).localizedDescription
    }
}
