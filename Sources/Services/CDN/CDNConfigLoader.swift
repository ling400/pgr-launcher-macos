import Foundation

/// 拉取游戏配置（index.json）：主 URL + 备用 URL，超时/失败重试，全部失败时回退到本地缓存。
final class CDNConfigLoader: @unchecked Sendable {
    struct Loaded {
        var config: CDNRemoteConfig
        var fromCache: Bool
        var source: String
        var elapsed: TimeInterval
    }

    private let logger: Logger
    private let cacheDir: URL
    private let session: URLSession

    init(logger: Logger, cacheDir: URL) {
        self.logger = logger
        self.cacheDir = cacheDir
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    /// `configURLs` 已按优先级排序（override → channel.configURL → backupConfigURL）。
    func load(configURLs: [String], cacheKey: String) async throws -> Loaded {
        let startedAt = Date()
        let cacheURL = cacheDir.appendingPathComponent("\(CDNFS.sanitized(cacheKey))-index.json")
        var errors: [String] = []

        for round in 1...2 {
            if round > 1 {
                CDNLog.warn(logger, "配置获取失败，1s 后重试（\(errors.count) 次失败）")
                try await CDNSleep.sleep(seconds: 1.0)
            }
            for rawURL in configURLs {
                if Task.isCancelled { throw CancellationError() }
                guard let url = URL(string: rawURL), url.scheme != nil, url.host != nil else {
                    errors.append("无效 URL：\(rawURL)")
                    continue
                }
                do {
                    let data = try await fetch(url)
                    let config = try CDNRemoteConfig.parse(data: data, configURL: url)
                    try? CDNFS.atomicWrite(data, to: cacheURL)
                    let elapsed = Date().timeIntervalSince(startedAt)
                    CDNLog.info(
                        logger,
                        "远端配置已获取：版本 \(config.version)，\(config.cdnRoots.count) 个 CDN，"
                        + "来源 \(url.host ?? url.absoluteString)（\(CDNFormat.duration(elapsed))）")
                    return Loaded(config: config, fromCache: false, source: url.absoluteString, elapsed: elapsed)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let reason = describe(error)
                    errors.append("\(rawURL)：\(reason)")
                    CDNLog.warn(logger, "配置地址失败：\(rawURL) → \(reason)")
                }
            }
        }

        // 网络不可用时回退到上次成功缓存的配置（离线也能显示版本 / 继续用已缓存清单）。
        if let data = CDNFS.readData(cacheURL, maxBytes: 4 * 1024 * 1024),
           let config = try? CDNRemoteConfig.parse(data: data, configURL: nil) {
            let elapsed = Date().timeIntervalSince(startedAt)
            CDNLog.warn(logger, "所有配置地址均失败，使用本地缓存配置（版本 \(config.version)）")
            return Loaded(config: config, fromCache: true, source: "cache", elapsed: elapsed)
        }
        throw CDNError.configUnavailable(errors.joined(separator: "；"))
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("PGRLauncher/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CDNError.invalidResponse("非 HTTP 响应（\(url.absoluteString)）")
        }
        guard http.statusCode == 200 else {
            throw CDNError.httpStatus(http.statusCode, "GET \(url.absoluteString)")
        }
        guard !data.isEmpty else {
            throw CDNError.invalidResponse("空响应（\(url.absoluteString)）")
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
