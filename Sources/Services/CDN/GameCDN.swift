import Foundation

/// 官方 CDN 直连下载 / 更新引擎（Yaagl 风格，不依赖官方启动器）。
///
/// 流程：
/// 1. 拉取 `index.json`（主 URL → 备用 URL → 本地缓存回退），解析 `cdnList` / `baseUrl` / `indexFile` / `version`；
/// 2. 下载并校验 `indexFile.json`（~13.7MB、85k+ 文件），缓存到 `appSupportDir/CDN/cache/`；
/// 3. `install`：全量比对本地（缺失 / 大小不符 / 大小相同但 MD5 不符才重下）；
///    `update`：按新清单做 MD5 差异，只下载变更文件（旧版本多余文件保留，不删除）；
/// 4. 并发（默认 8）下载，单文件 Range 续传（`.part` + `.part.meta`）、失败切 CDN + 指数退避、
///    流式 MD5 校验、临时文件原子移动；
/// 5. 进度以 ≥4Hz 回调到 MainActor（`InstallProgress`），含实时速度（2s 滑窗）。
///
/// 对外接口见 `docs/CONTRACT.md`，由 `GameManager` 调用。
final class GameCDN: @unchecked Sendable {
    let logger: Logger
    let appSupportDir: URL

    private enum RunMode {
        case install
        case update
    }

    /// 诊断用：清单摘要（不下载游戏文件）。
    struct ManifestSummary: Sendable {
        var channelID: String
        var channelName: String
        var version: String
        var fileCount: Int
        var totalBytes: Int64
        var cdnRoots: [String]
        var fromCache: Bool
        var elapsed: TimeInterval
    }

    /// 安装完成标记文件名（GameManager 据此判断「完整安装」，避免 PGR.exe 先到位就被误判可启动）。
    static let installCompleteMarkerName = ".pgrlauncher-install-complete"

    /// 小文件阈值：小于该大小的文件走「高并发低带宽」通道（小文件阶段是延迟受限，8 并发会很慢）。
    static let smallFileThreshold: Int64 = 512 * 1024

    private struct CompletionMarker: Codable {
        var channel: String
        var channelName: String
        var version: String
        var manifestVersion: String
        var fileCount: Int
        var totalBytes: Int64
        var completedAt: String
    }

    private let cacheDir: URL
    private let stateDir: URL
    /// 断点续传分片目录（appSupportDir/CDN/state/parts，不写入游戏目录）。
    private let partsDir: URL
    private let concurrency: Int
    /// 小文件（< `smallFileThreshold`）下载并发；延迟受限，默认 32。
    private let smallFileConcurrency: Int
    private let maxAttempts: Int
    private let configLoader: CDNConfigLoader
    private let manifestStore: CDNManifestStore
    private let smallSession: URLSession

    /// 自测 / 诊断范围限制：仅当环境变量存在时生效，正常使用不受影响。
    /// - `PGR_CDN_TEST_MAX_FILES`：最多处理多少个文件
    /// - `PGR_CDN_TEST_MAX_BYTES`：清单计划总字节上限
    /// - `PGR_CDN_TEST_INCLUDE`：强制包含的 dest（逗号分隔，如 "PGR.exe,version.json"）
    private let testMaxFiles: Int?
    private let testMaxBytes: Int64?
    private let testIncludeDests: Set<String>?

    init(logger: Logger, appSupportDir: URL) {
        self.logger = logger
        self.appSupportDir = appSupportDir
        self.cacheDir = appSupportDir.appendingPathComponent("CDN/cache", isDirectory: true)
        self.stateDir = appSupportDir.appendingPathComponent("CDN/state", isDirectory: true)
        self.partsDir = CDNParts.directory(appSupportDir: appSupportDir)
        try? CDNFS.ensureDirectory(cacheDir)
        try? CDNFS.ensureDirectory(stateDir)
        try? CDNFS.ensureDirectory(partsDir)

        let environment = ProcessInfo.processInfo.environment
        self.concurrency = min(16, max(1, Int(environment["PGR_CDN_CONCURRENCY"] ?? "") ?? 8))
        self.smallFileConcurrency = min(64, max(4, Int(environment["PGR_CDN_SMALL_CONCURRENCY"] ?? "") ?? 32))
        let retries = min(8, max(1, Int(environment["PGR_CDN_RETRIES"] ?? "") ?? 3))
        self.maxAttempts = retries + 1
        self.testMaxFiles = (Int(environment["PGR_CDN_TEST_MAX_FILES"] ?? "")).flatMap { $0 > 0 ? $0 : nil }
        self.testMaxBytes = (Int64(environment["PGR_CDN_TEST_MAX_BYTES"] ?? "")).flatMap { $0 > 0 ? $0 : nil }
        if let list = environment["PGR_CDN_TEST_INCLUDE"], !list.isEmpty {
            let dests = list
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            self.testIncludeDests = dests.isEmpty ? nil : Set(dests)
        } else {
            self.testIncludeDests = nil
        }

        self.configLoader = CDNConfigLoader(logger: logger, cacheDir: cacheDir)
        self.manifestStore = CDNManifestStore(logger: logger, cacheDir: cacheDir)

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 20
        sessionConfiguration.timeoutIntervalForResource = 60
        sessionConfiguration.waitsForConnectivity = false
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.smallSession = URLSession(configuration: sessionConfiguration)

        if testMaxFiles != nil || testMaxBytes != nil || testIncludeDests != nil {
            CDNLog.warn(
                logger,
                "⚠️ 自测范围限制已启用（PGR_CDN_TEST_*）：maxFiles=\(testMaxFiles.map(String.init) ?? "-") "
                + "maxBytes=\(testMaxBytes.map(String.init) ?? "-") "
                + "include=\(testIncludeDests?.sorted().joined(separator: ",") ?? "-")")
        }
    }

    // MARK: - Public API

    /// 远端清单版本（`index.json` 的 `config.version`）。
    func remoteVersion(channel: GameChannel, configURLOverride: String?) async throws -> String {
        let remote = try await loadRemote(channel: channel, override: configURLOverride, needManifest: false)
        return remote.config.version
    }

    /// 全量安装：本地不存在 / 大小不符 / MD5 不符的文件才下载。
    func install(
        channel: GameChannel,
        gameDir: URL,
        configURLOverride: String?,
        progress: @escaping @MainActor (InstallProgress) -> Void
    ) async throws {
        try await run(
            mode: .install,
            channel: channel,
            gameDir: gameDir,
            configURLOverride: configURLOverride,
            progress: progress)
    }

    /// 增量更新：按最新清单的 MD5 差异只下载变更文件（不删除旧版本多余文件）。
    func update(
        channel: GameChannel,
        gameDir: URL,
        configURLOverride: String?,
        progress: @escaping @MainActor (InstallProgress) -> Void
    ) async throws {
        try await run(
            mode: .update,
            channel: channel,
            gameDir: gameDir,
            configURLOverride: configURLOverride,
            progress: progress)
    }

    /// 诊断用：只拉取配置 + 清单并返回摘要，不下载游戏文件。
    func manifestSummary(channel: GameChannel, configURLOverride: String?) async throws -> ManifestSummary {
        let startedAt = Date()
        let remote = try await loadRemote(channel: channel, override: configURLOverride, needManifest: true)
        guard let manifest = remote.manifest else {
            throw CDNError.manifestUnavailable("清单为空")
        }
        return ManifestSummary(
            channelID: channel.id,
            channelName: channel.displayName,
            version: remote.config.version,
            fileCount: manifest.entries.count,
            totalBytes: manifest.totalBytes,
            cdnRoots: remote.config.cdnRoots,
            fromCache: manifest.fromCache,
            elapsed: Date().timeIntervalSince(startedAt))
    }

    // MARK: - Orchestration

    private func run(
        mode: RunMode,
        channel: GameChannel,
        gameDir: URL,
        configURLOverride: String?,
        progress: @escaping @MainActor (InstallProgress) -> Void
    ) async throws {
        try CDNFS.ensureDirectory(gameDir)
        let reporter = CDNProgressReporter(handler: progress)
        reporter.start()
        let state = CDNInstallState(stateDir: stateDir, channelID: channel.id, logger: logger)
        let startedAt = Date()

        do {
            // 1. 配置 + 清单
            reporter.setPhase(mode == .install ? "获取版本清单…" : "检查更新…", filesTotal: 0, bytesTotal: 0)
            let remote = try await loadRemote(channel: channel, override: configURLOverride, needManifest: true)
            guard let manifest = remote.manifest else {
                throw CDNError.manifestUnavailable("清单为空")
            }

            // 2. 实际文件版本（<baseUrl>version.json，24B；config.version 与文件版本可能不同）
            let remoteGameVersion = await fetchGameVersion(config: remote.config)
            let localGameVersion = CDNVersion.readLocal(gameDir: gameDir)
            if mode == .update {
                if let remoteGameVersion, let localGameVersion {
                    if remoteGameVersion == localGameVersion {
                        CDNLog.info(logger, "版本检查：本地 \(localGameVersion)，远端 \(remoteGameVersion)（一致，继续比对文件）")
                    } else {
                        CDNLog.info(logger, "版本检查：发现新版本 本地 \(localGameVersion) → 远端 \(remoteGameVersion)")
                    }
                } else {
                    CDNLog.info(
                        logger,
                        "版本检查：本地 \(localGameVersion ?? "未知")，远端 \(remoteGameVersion ?? "未知")，按清单差异比对")
                }
            } else {
                CDNLog.info(
                    logger,
                    "开始安装：清单版本 \(remote.config.version)，文件版本 \(remoteGameVersion ?? "未知")，"
                    + "\(manifest.entries.count) 个文件 / \(CDNFormat.bytes(manifest.totalBytes))")
            }

            let scopedEntries = applyTestScope(manifest.entries)
            if scopedEntries.count != manifest.entries.count {
                CDNLog.warn(logger, "自测范围生效：仅处理 \(scopedEntries.count)/\(manifest.entries.count) 个文件")
            }

            // 3. 本地比对
            reporter.setPhase("校验本地文件…", filesTotal: scopedEntries.count, bytesTotal: 0)
            let plan = try await buildPlan(
                entries: scopedEntries,
                gameDir: gameDir,
                state: state,
                reporter: reporter)

            if plan.isEmpty {
                CDNParts.clear(partsDir)
                state.saveIfNeeded()
                state.markInstalled(
                    version: remote.config.version,
                    manifestMd5: remote.manifestMd5,
                    gameDir: gameDir,
                    files: manifest.entries.count,
                    bytes: manifest.totalBytes,
                    fileVersion: remoteGameVersion)
                let phase = mode == .install ? "完成" : "已是最新版本"
                if scopedEntries.count == manifest.entries.count {
                    writeCompletionMarker(
                        gameDir: gameDir,
                        channel: channel,
                        version: remoteGameVersion ?? remote.config.version,
                        manifestVersion: remote.config.version,
                        fileCount: manifest.entries.count,
                        totalBytes: manifest.totalBytes)
                }
                CDNLog.info(
                    logger,
                    "全部 \(scopedEntries.count) 个文件均已就绪，无需下载"
                    + "（总计 \(CDNFormat.duration(Date().timeIntervalSince(startedAt)))）")
                await reporter.finish(
                    phase: phase,
                    filesDone: scopedEntries.count,
                    filesTotal: scopedEntries.count,
                    bytesDone: 0,
                    bytesTotal: 0)
                return
            }

            // 4. 下载
            CDNLog.info(
                logger,
                "需要下载 \(plan.items.count) 个文件，共 \(CDNFormat.bytes(plan.totalBytes))"
                + "（已校验通过 \(plan.filesVerified) 个）")
            reporter.setPhase("下载游戏资源…", filesTotal: plan.items.count, bytesTotal: plan.totalBytes)
            try ensureDiskSpace(gameDir: gameDir, requiredBytes: plan.totalBytes)

            // 双通道：大文件走带宽通道（默认 8 并发），小文件走延迟通道（默认 32 并发），两路并行。
            let largeItems = plan.items.filter { $0.entry.size >= Self.smallFileThreshold }
            let smallItems = plan.items.filter { $0.entry.size < Self.smallFileThreshold }
            if !largeItems.isEmpty, !smallItems.isEmpty {
                CDNLog.info(
                    logger,
                    "并发策略：大文件 \(largeItems.count) 个 / "
                    + "\(CDNFormat.bytes(largeItems.reduce(Int64(0)) { $0 + $1.entry.size })) 走 \(concurrency) 并发；"
                    + "小文件 \(smallItems.count) 个 / "
                    + "\(CDNFormat.bytes(smallItems.reduce(Int64(0)) { $0 + $1.entry.size })) 走 \(smallFileConcurrency) 并发")
            }
            let onFileCompleted: @Sendable (CDNDownloadItem) -> Void = { item in
                if state.record(entry: item.entry, destURL: item.destURL) {
                    state.saveIfNeeded()
                }
            }
            func makeEngine(_ items: [CDNDownloadItem], limit: Int) -> CDNDownloadEngine {
                CDNDownloadEngine(
                    logger: logger,
                    cdnRoots: remote.config.cdnRoots,
                    baseUrl: remote.config.baseUrl,
                    partsDir: partsDir,
                    maxConcurrency: limit,
                    maxAttempts: maxAttempts,
                    reporter: reporter,
                    onFileCompleted: onFileCompleted)
            }

            let downloadStartedAt = Date()
            let result: CDNDownloadEngine.RunResult
            switch (largeItems.isEmpty, smallItems.isEmpty) {
            case (true, true):
                result = CDNDownloadEngine.RunResult(downloadedBytes: 0, completedFiles: 0, failures: [])
            case (false, true):
                result = try await makeEngine(largeItems, limit: concurrency).run(items: largeItems)
            case (true, false):
                result = try await makeEngine(smallItems, limit: smallFileConcurrency).run(items: smallItems)
            case (false, false):
                let largeEngine = makeEngine(largeItems, limit: concurrency)
                let smallEngine = makeEngine(smallItems, limit: smallFileConcurrency)
                async let largeRun = largeEngine.run(items: largeItems)
                async let smallRun = smallEngine.run(items: smallItems)
                let largeResult = try await largeRun
                let smallResult = try await smallRun
                result = CDNDownloadEngine.RunResult(
                    downloadedBytes: largeResult.downloadedBytes + smallResult.downloadedBytes,
                    completedFiles: largeResult.completedFiles + smallResult.completedFiles,
                    failures: largeResult.failures + smallResult.failures)
            }
            let downloadElapsed = max(0.001, Date().timeIntervalSince(downloadStartedAt))

            guard result.isSuccess else {
                // 单文件最终失败不中止整轮：已完成文件保留，失败项汇总抛错，重新运行续传。
                state.saveIfNeeded()
                let failedBytes = result.failures.reduce(Int64(0)) { $0 + $1.size }
                let completedBytes = max(0, plan.totalBytes - failedBytes)
                let examples = result.failures.prefix(6).map { "\($0.dest)：\($0.reason)" }
                CDNLog.error(
                    logger,
                    "本次\(mode == .install ? "安装" : "更新")有 \(result.failures.count)/\(plan.items.count) "
                    + "个文件下载失败，已完成的文件保留，可重新运行继续；示例：\(examples.joined(separator: "；"))")
                await reporter.finish(
                    phase: "下载未完成",
                    filesDone: result.completedFiles,
                    filesTotal: plan.items.count,
                    bytesDone: completedBytes,
                    bytesTotal: plan.totalBytes)
                throw CDNError.partialFailure(
                    failed: result.failures.count,
                    total: plan.items.count,
                    examples: Array(examples))
            }

            // 全部成功：清理续传分片，写安装标记
            CDNParts.clear(partsDir)
            state.saveIfNeeded()
            state.markInstalled(
                version: remote.config.version,
                manifestMd5: remote.manifestMd5,
                gameDir: gameDir,
                files: manifest.entries.count,
                bytes: manifest.totalBytes,
                fileVersion: remoteGameVersion)
            if scopedEntries.count == manifest.entries.count {
                writeCompletionMarker(
                    gameDir: gameDir,
                    channel: channel,
                    version: remoteGameVersion ?? remote.config.version,
                    manifestVersion: remote.config.version,
                    fileCount: manifest.entries.count,
                    totalBytes: manifest.totalBytes)
            }

            await reporter.finish(
                phase: "完成",
                filesDone: plan.items.count,
                filesTotal: plan.items.count,
                bytesDone: plan.totalBytes,
                bytesTotal: plan.totalBytes)
            CDNLog.info(
                logger,
                "游戏\(mode == .install ? "安装" : "更新")完成：下载 \(plan.items.count) 个文件 / "
                + "\(CDNFormat.bytes(result.downloadedBytes))，耗时 \(CDNFormat.duration(downloadElapsed))，"
                + "平均 \(CDNFormat.speed(Int64(Double(result.downloadedBytes) / downloadElapsed)))"
                + "；总计 \(CDNFormat.duration(Date().timeIntervalSince(startedAt)))")
        } catch is CancellationError {
            state.saveIfNeeded()
            reporter.stop()
            CDNLog.warn(logger, "CDN 下载已取消：已保留 .part 分片，下次可续传")
            throw CDNError.cancelled
        } catch {
            state.saveIfNeeded()
            reporter.stop()
            CDNLog.error(logger, "CDN 下载失败：\(describe(error))")
            throw error
        }
    }

    // MARK: - Remote resolution

    private struct ResolvedRemote {
        var config: CDNRemoteConfig
        var manifest: CDNManifest?
        var manifestMd5: String?
        var fromCache: Bool
    }

    private func loadRemote(
        channel: GameChannel,
        override: String?,
        needManifest: Bool
    ) async throws -> ResolvedRemote {
        let trimmedOverride = (override ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let configURLs: [String]
        if !trimmedOverride.isEmpty {
            configURLs = [trimmedOverride]
        } else {
            configURLs = [channel.configURL, channel.backupConfigURL]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }

        let loaded = try await configLoader.load(configURLs: configURLs, cacheKey: channel.id)
        var remote = ResolvedRemote(config: loaded.config, manifest: nil, manifestMd5: nil, fromCache: loaded.fromCache)
        if needManifest {
            let manifest = try await manifestStore.load(config: loaded.config, cacheKey: channel.id)
            remote.manifest = manifest
            remote.manifestMd5 = manifest.md5
        }
        return remote
    }

    /// 拉取 `<baseUrl>version.json`（24B）解析实际文件版本；失败返回 nil（不阻塞主流程）。
    private func fetchGameVersion(config: CDNRemoteConfig) async -> String? {
        for root in config.cdnRoots {
            guard let url = CDNURL.fileURL(root: root, baseUrl: config.baseUrl, dest: "version.json") else {
                continue
            }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("PGRLauncher/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await smallSession.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { continue }
                if let version = CDNVersion.parse(data) { return version }
            } catch is CancellationError {
                return nil
            } catch {
                continue
            }
        }
        return nil
    }

    // MARK: - Plan

    private func buildPlan(
        entries: [CDNManifestEntry],
        gameDir: URL,
        state: CDNInstallState,
        reporter: CDNProgressReporter
    ) async throws -> CDNDownloadPlan {
        var needsDownload: [CDNDownloadItem] = []
        var hashCandidates: [CDNDownloadItem] = []
        var verified = 0
        var scanned = 0

        // 统计只做 stat（约 85k 次系统调用，几百毫秒）；只有「大小相同」的文件才需要 MD5。
        for entry in entries {
            if Task.isCancelled { throw CancellationError() }
            guard let destURL = CDNFS.fileURL(gameDir: gameDir, dest: entry.dest) else {
                CDNLog.warn(logger, "清单路径不合法，已跳过：\(entry.dest)")
                continue
            }
            scanned += 1
            if scanned % 500 == 0 {
                reporter.setFilesDone(scanned)
                reporter.setCurrentFile(destURL.lastPathComponent)
            }
            if let size = CDNFS.size(destURL) {
                if size != entry.size {
                    needsDownload.append(CDNDownloadItem(entry: entry, destURL: destURL))
                } else if let mtime = CDNFS.mtime(destURL),
                          state.isVerified(dest: entry.dest, size: entry.size, mtime: mtime, md5: entry.md5) {
                    verified += 1
                } else {
                    hashCandidates.append(CDNDownloadItem(entry: entry, destURL: destURL))
                }
            } else {
                needsDownload.append(CDNDownloadItem(entry: entry, destURL: destURL))
            }
        }
        reporter.setFilesDone(scanned)

        if !hashCandidates.isEmpty {
            CDNLog.info(logger, "校验本地文件：\(hashCandidates.count) 个文件大小匹配，计算 MD5 确认…")
            reporter.setPhase("校验本地文件（MD5）…", filesTotal: hashCandidates.count, bytesTotal: 0)
            let mismatched = try await hashAndPickMismatched(hashCandidates, state: state, reporter: reporter)
            needsDownload.append(contentsOf: mismatched)
            verified += hashCandidates.count - mismatched.count
        }

        // 大文件优先，减少并发下载的尾部空转。
        needsDownload.sort { lhs, rhs in
            if lhs.entry.size != rhs.entry.size { return lhs.entry.size > rhs.entry.size }
            return lhs.entry.dest < rhs.entry.dest
        }
        let totalBytes = needsDownload.reduce(Int64(0)) { $0 + $1.entry.size }
        return CDNDownloadPlan(
            items: needsDownload,
            totalBytes: totalBytes,
            filesVerified: verified,
            filesTotal: entries.count)
    }

    /// 并发（最多 8 路）流式 MD5 校验，返回与清单 MD5 不符的条目。
    private func hashAndPickMismatched(
        _ candidates: [CDNDownloadItem],
        state: CDNInstallState,
        reporter: CDNProgressReporter
    ) async throws -> [CDNDownloadItem] {
        guard !candidates.isEmpty else { return [] }
        let workers = min(8, max(2, concurrency))
        var matches = [Bool](repeating: false, count: candidates.count)
        var nextIndex = 0

        try await withThrowingTaskGroup(of: (Int, Bool).self) { group in
            let initial = min(workers, candidates.count)
            for index in 0..<initial {
                group.addTask { try await self.hashCandidate(index: index, item: candidates[index]) }
            }
            nextIndex = initial
            while let (index, isMatch) = try await group.next() {
                matches[index] = isMatch
                reporter.markFileDone()
                if isMatch {
                    state.record(entry: candidates[index].entry, destURL: candidates[index].destURL)
                }
                if nextIndex < candidates.count {
                    let next = nextIndex
                    nextIndex += 1
                    group.addTask { try await self.hashCandidate(index: next, item: candidates[next]) }
                }
            }
        }

        var mismatched: [CDNDownloadItem] = []
        for (index, isMatch) in matches.enumerated() where !isMatch {
            mismatched.append(candidates[index])
        }
        return mismatched
    }

    private func hashCandidate(index: Int, item: CDNDownloadItem) async throws -> (Int, Bool) {
        if Task.isCancelled { throw CancellationError() }
        let digest = try CDNMD5.file(item.destURL, isCancelled: { Task.isCancelled })
        return (index, digest.caseInsensitiveCompare(item.entry.md5) == .orderedSame)
    }

    /// 自测范围限制（仅用于真实网络抽样安装测试；正常使用返回全部条目）。
    private func applyTestScope(_ entries: [CDNManifestEntry]) -> [CDNManifestEntry] {
        guard testMaxFiles != nil || testMaxBytes != nil || testIncludeDests != nil else {
            return entries
        }
        var included: [CDNManifestEntry] = []
        var includedDests = Set<String>()
        if let include = testIncludeDests {
            for entry in entries where include.contains(entry.dest) {
                included.append(entry)
                includedDests.insert(entry.dest)
            }
        }

        var result = included
        var usedBytes = included.reduce(Int64(0)) { $0 + $1.size }
        let maxBytes = testMaxBytes ?? Int64.max
        let maxFiles = testMaxFiles ?? Int.max
        let remaining = entries
            .filter { !includedDests.contains($0.dest) }
            .sorted { lhs, rhs in
                if lhs.size != rhs.size { return lhs.size < rhs.size }
                return lhs.dest < rhs.dest
            }
        for entry in remaining {
            if result.count >= maxFiles { break }
            if entry.size > 0, usedBytes + entry.size > maxBytes { continue }
            result.append(entry)
            usedBytes += entry.size
            if usedBytes >= maxBytes { break }
        }
        return result
    }

    // MARK: - Helpers

    /// 安装/更新**全部成功**后写入 <gameDir>/.pgrlauncher-install-complete。
    /// 中途取消或失败时不写、也不删除已有标记。
    /// （internal 以便自测/诊断直接验证完成标记的 JSON 格式）
    func writeCompletionMarker(
        gameDir: URL,
        channel: GameChannel,
        version: String,
        manifestVersion: String,
        fileCount: Int,
        totalBytes: Int64
    ) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let marker = CompletionMarker(
            channel: channel.id,
            channelName: channel.displayName,
            version: version,
            manifestVersion: manifestVersion,
            fileCount: fileCount,
            totalBytes: totalBytes,
            completedAt: formatter.string(from: Date()))
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(marker)
            let url = gameDir.appendingPathComponent(Self.installCompleteMarkerName)
            try CDNFS.atomicWrite(data, to: url)
            CDNLog.info(logger, "已写入安装完成标记：\(url.path)")
        } catch {
            CDNLog.warn(logger, "安装完成标记写入失败：\(error.localizedDescription)")
        }
    }

    /// 下载前检查磁盘空间（计划总字节 + 1.5GB 预留余量，避免 68GB 安装中途写满）。
    private func ensureDiskSpace(gameDir: URL, requiredBytes: Int64) throws {
        let reserve: Int64 = 1_500_000_000
        let needed = requiredBytes + reserve
        let values = try? gameDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else {
            CDNLog.warn(logger, "无法读取磁盘可用空间，跳过空间检查（需要 \(CDNFormat.bytes(needed))）")
            return
        }
        CDNLog.info(
            logger,
            "磁盘空间检查：本次需要 \(CDNFormat.bytes(needed))（含 1.5GB 余量），"
            + "当前可用 \(CDNFormat.bytes(available))")
        guard available >= needed else {
            throw CDNError.insufficientDisk(required: needed, available: available)
        }
    }

    private func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        if error is CancellationError { return "已取消" }
        return (error as NSError).localizedDescription
    }
}
