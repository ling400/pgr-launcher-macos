import Foundation

// MARK: - index.json（游戏配置端点）

/// 解析后的远端游戏配置：版本、下载根路径、清单路径、CDN 列表。
struct CDNRemoteConfig: Sendable, Equatable {
    /// `config.version`，例如 "4.9.0"（注意：实际游戏文件里的版本号见 version.json 的 package_version）。
    var version: String
    /// 全量解压后大小（字节），仅用于展示。
    var totalSize: Int64
    /// 单文件下载根路径（相对 CDN 根），例如 "launcher/game/G148/.../zip/"。
    var baseUrl: String
    /// 清单文件路径（相对 CDN 根）。
    var indexFile: String
    /// 清单文件 MD5（index.json 里的 indexFileMd5，用于校验缓存）。
    var indexFileMd5: String?
    /// 可用 CDN 根（已去尾部 `/`、去重、保序）。
    var cdnRoots: [String]

    static func parse(data: Data, configURL: URL?) throws -> CDNRemoteConfig {
        let response: RawIndexResponse
        do {
            response = try JSONDecoder().decode(RawIndexResponse.self, from: data)
        } catch {
            throw CDNError.invalidConfig("index.json 解析失败：\(error.localizedDescription)")
        }
        guard let defaultValue = response.default else {
            throw CDNError.invalidConfig("index.json 缺少 default 字段")
        }
        guard let config = defaultValue.config else {
            throw CDNError.invalidConfig("index.json 缺少 default.config 字段")
        }
        guard let version = config.version?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty else {
            throw CDNError.invalidConfig("index.json 缺少 config.version")
        }
        guard let baseUrl = config.baseUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !baseUrl.isEmpty else {
            throw CDNError.invalidConfig("index.json 缺少 config.baseUrl")
        }
        guard let indexFile = config.indexFile?.trimmingCharacters(in: .whitespacesAndNewlines), !indexFile.isEmpty else {
            throw CDNError.invalidConfig("index.json 缺少 config.indexFile")
        }

        var roots = (defaultValue.cdnList ?? [])
            .compactMap { $0.url }
            .map { CDNURL.normalizedRoot($0) }
            .filter { !$0.isEmpty }
        if roots.isEmpty, let configURL, let host = configURL.host, let scheme = configURL.scheme {
            roots = ["\(scheme)://\(host)"]
        }
        guard !roots.isEmpty else {
            throw CDNError.invalidConfig("index.json 中没有可用的 cdnList")
        }
        var seen = Set<String>()
        roots = roots.filter { seen.insert($0).inserted }

        return CDNRemoteConfig(
            version: version,
            totalSize: config.size ?? 0,
            baseUrl: baseUrl,
            indexFile: indexFile,
            indexFileMd5: config.indexFileMd5?.lowercased(),
            cdnRoots: roots
        )
    }

    // 仅解码需要的字段，容忍 index.json 未来新增字段。
    private struct RawIndexResponse: Decodable {
        struct Node: Decodable {
            let url: String?
        }
        struct Config: Decodable {
            let version: String?
            let size: Int64?
            let baseUrl: String?
            let indexFile: String?
            let indexFileMd5: String?
        }
        struct Default: Decodable {
            let cdnList: [Node]?
            let config: Config?
        }
        let `default`: Default?
    }
}

// MARK: - indexFile.json（游戏文件清单）

/// 清单中的单个文件。
struct CDNManifestEntry: Sendable, Equatable {
    /// 相对游戏根目录的目标路径，例如 "PGR_Data/StreamingAssets/.../a.uab"。
    let dest: String
    /// 文件 MD5（小写 32 位）。
    let md5: String
    /// 文件大小（字节）。
    let size: Int64
}

/// 解析后的清单。
struct CDNManifest: Sendable {
    var entries: [CDNManifestEntry]
    var totalBytes: Int64
    var md5: String
    var fromCache: Bool
    var elapsed: TimeInterval

    static func parse(_ data: Data) throws -> CDNManifest {
        let raw: RawManifest
        do {
            raw = try JSONDecoder().decode(RawManifest.self, from: data)
        } catch {
            throw CDNError.invalidManifest("indexFile.json 解析失败：\(error.localizedDescription)")
        }
        var entries: [CDNManifestEntry] = []
        entries.reserveCapacity(raw.resource.count)
        var totalBytes: Int64 = 0
        for item in raw.resource {
            guard let dest = item.dest, !dest.isEmpty,
                  let md5 = item.md5, md5.count == 32 else { continue }
            let normalizedDest = dest.replacingOccurrences(of: "\\", with: "/")
            guard !normalizedDest.hasPrefix("/") else { continue }
            let size = item.size ?? 0
            entries.append(CDNManifestEntry(dest: normalizedDest, md5: md5.lowercased(), size: max(0, size)))
            totalBytes += max(0, size)
        }
        guard entries.count >= 100 else {
            throw CDNError.invalidManifest("清单文件数量异常：\(entries.count)")
        }
        return CDNManifest(
            entries: entries,
            totalBytes: totalBytes,
            md5: "",
            fromCache: false,
            elapsed: 0
        )
    }

    private struct RawManifest: Decodable {
        struct Item: Decodable {
            let dest: String?
            let md5: String?
            let size: Int64?
        }
        let resource: [Item]

        private enum CodingKeys: String, CodingKey {
            case resource
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.resource = (try? container.decode([Item].self, forKey: .resource)) ?? []
        }
    }
}

// MARK: - 安装计划

/// 计划中需要下载的一个文件（清单条目 + 本地目标 URL）。
struct CDNDownloadItem: Sendable {
    let entry: CDNManifestEntry
    let destURL: URL
}

/// 一次 install / update 需要下载的文件计划。
struct CDNDownloadPlan: Sendable {
    var items: [CDNDownloadItem]
    var totalBytes: Int64
    var filesVerified: Int
    var filesTotal: Int

    static let empty = CDNDownloadPlan(items: [], totalBytes: 0, filesVerified: 0, filesTotal: 0)

    var isEmpty: Bool { items.isEmpty }
}
