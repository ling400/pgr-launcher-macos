import Foundation

// MARK: - 分片元数据（.part.meta）

/// 与 `.part` 配套的元数据：记录该分片属于哪个远端文件（md5+size）以及已收字节，
/// 重启后据此判断能否安全续传。
private struct CDNPartMeta: Codable {
    var dest: String
    var md5: String
    var size: Int64
    var received: Int64
}

private func writePartMeta(
    metaURL: URL,
    dest: String,
    received: Int64,
    expectedSize: Int64,
    expectedMD5: String
) throws {
    let meta = CDNPartMeta(dest: dest, md5: expectedMD5, size: expectedSize, received: received)
    let data = try JSONEncoder().encode(meta)
    try CDNFS.atomicWrite(data, to: metaURL)
}

private func readPartMeta(_ url: URL) -> CDNPartMeta? {
    guard let data = CDNFS.readData(url, maxBytes: 64 * 1024) else { return nil }
    return try? JSONDecoder().decode(CDNPartMeta.self, from: data)
}

// MARK: - 下载引擎

/// 并发下载引擎：
/// - 并发度可配置（默认 8，范围 4–16）；
/// - 每个文件写入 `<dest>.part`（+ `.part.meta`），支持 Range 断点续传；
/// - 失败自动切换 CDN + 指数退避重试（默认 4 次尝试）；
/// - 完成后流式 MD5 校验、临时文件原子移动；
/// - 取消时保留 `.part` / `.part.meta`，下次可续。
///
/// 一次性使用：一次 install/update 创建一个实例，`run` 结束后自动回收 URLSession。
final class CDNDownloadEngine: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// 计划中的单个文件（复用 `CDNDownloadItem`，便于编排层直接传入）。
    typealias Item = CDNDownloadItem

    /// 一次 `run` 的汇总结果：单文件最终失败不会中止整轮，失败项在最后汇总给调用方。
    struct RunResult: Sendable {
        struct Failure: Sendable {
            let dest: String
            let size: Int64
            let reason: String
        }

        var downloadedBytes: Int64
        var completedFiles: Int
        var failures: [Failure]

        var isSuccess: Bool { failures.isEmpty }
    }

    private enum ItemOutcome: Sendable {
        case success(bytes: Int64)
        case failure(dest: String, size: Int64, reason: String)
    }

    private let logger: Logger
    private let cdnRoots: [String]
    private let baseUrl: String
    /// 续传分片目录（appSupportDir/CDN/state/parts，不写入游戏目录）。
    private let partsDir: URL
    private let maxConcurrency: Int
    private let maxAttempts: Int
    private let reporter: CDNProgressReporter
    private let onFileCompleted: (@Sendable (Item) -> Void)?

    private let delegateQueue = OperationQueue()
    private let handlersLock = NSLock()
    private var handlers: [Int: _FileTaskHandler] = [:]
    private let counterLock = NSLock()
    private var completedFiles = 0
    private let shutdownLock = NSLock()
    private var didShutdown = false
    private var session: URLSession!

    init(
        logger: Logger,
        cdnRoots: [String],
        baseUrl: String,
        partsDir: URL,
        maxConcurrency: Int,
        maxAttempts: Int,
        reporter: CDNProgressReporter,
        onFileCompleted: (@Sendable (Item) -> Void)? = nil
    ) {
        self.logger = logger
        self.cdnRoots = cdnRoots.isEmpty ? [] : cdnRoots
        self.baseUrl = baseUrl
        self.partsDir = partsDir
        self.maxConcurrency = max(1, min(16, maxConcurrency))
        self.maxAttempts = max(1, maxAttempts)
        self.reporter = reporter
        self.onFileCompleted = onFileCompleted
        super.init()

        try? CDNFS.ensureDirectory(partsDir)
        delegateQueue.name = "pgr.cdn.download.delegate"
        delegateQueue.maxConcurrentOperationCount = 1
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 40
        configuration.timeoutIntervalForResource = 60 * 60 * 12
        configuration.httpMaximumConnectionsPerHost = max(16, self.maxConcurrency * 2)
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }

    deinit {
        shutdown()
    }

    // MARK: Run

    /// 并发下载所有条目。
    ///
    /// 单个文件在「最大尝试次数」后仍失败**不会中止整轮**：记录失败项后继续下载其他文件，
    /// 全部结束后由调用方汇总失败列表并抛错；已完成的文件与未完成文件的 `.part` 都保留，重新运行可续传。
    /// 仅任务取消（Task cancellation）会立即抛出 `CancellationError`。
    func run(items: [Item]) async throws -> RunResult {
        guard !items.isEmpty else {
            return RunResult(downloadedBytes: 0, completedFiles: 0, failures: [])
        }
        defer { shutdown() }

        let total = items.count
        var nextIndex = 0
        var downloadedBytes: Int64 = 0
        var completedFiles = 0
        var failures: [RunResult.Failure] = []

        try await withThrowingTaskGroup(of: ItemOutcome.self) { group in
            let initial = min(maxConcurrency, total)
            for index in 0..<initial {
                group.addTask { try await self.downloadItem(items[index]) }
            }
            nextIndex = initial

            while let outcome = try await group.next() {
                switch outcome {
                case .success(let bytes):
                    downloadedBytes += bytes
                    completedFiles += 1
                case .failure(let dest, let size, let reason):
                    failures.append(RunResult.Failure(dest: dest, size: size, reason: reason))
                }
                if nextIndex < total {
                    let index = nextIndex
                    nextIndex += 1
                    group.addTask { try await self.downloadItem(items[index]) }
                }
            }
        }

        if failures.isEmpty {
            CDNLog.info(logger, "本轮下载结束：全部 \(total) 个文件完成")
        } else {
            CDNLog.warn(logger, "本轮下载结束：成功 \(completedFiles)/\(total)，失败 \(failures.count)（重新运行可续传）")
        }
        return RunResult(downloadedBytes: downloadedBytes, completedFiles: completedFiles, failures: failures)
    }

    private func shutdown() {
        shutdownLock.lock()
        if didShutdown {
            shutdownLock.unlock()
            return
        }
        didShutdown = true
        shutdownLock.unlock()
        session?.invalidateAndCancel()
        handlersLock.lock()
        handlers.removeAll()
        handlersLock.unlock()
    }

    // MARK: Single file

    private func downloadItem(_ item: Item) async throws -> ItemOutcome {
        if Task.isCancelled { throw CancellationError() }
        let entry = item.entry
        let destURL = item.destURL
        try CDNFS.ensureDirectory(destURL.deletingLastPathComponent())
        reporter.setCurrentFile(destURL.lastPathComponent)

        if entry.size <= 0 {
            return try finalizeEmptyFile(entry: entry, destURL: destURL)
        }

        let partURLs = CDNParts.urls(destURL: destURL, partsDir: partsDir)
        let partURL = partURLs.part
        let metaURL = partURLs.meta
        var lastError: Error?

        for attempt in 0..<maxAttempts {
            if Task.isCancelled { throw CancellationError() }
            guard !cdnRoots.isEmpty else {
                throw CDNError.invalidConfig("没有可用的 CDN 地址")
            }
            let root = cdnRoots[attempt % cdnRoots.count]
            do {
                guard let url = CDNURL.fileURL(root: root, baseUrl: baseUrl, dest: entry.dest) else {
                    throw CDNError.invalidConfig("无法构造下载 URL：\(entry.dest)")
                }
                let progressBox = _ByteBox()
                let onBytes: @Sendable (Int64) -> Void = { [weak self] delta in
                    progressBox.add(delta)
                    self?.reporter.addBytes(delta)
                }
                try await fetchToPart(
                    url: url,
                    partURL: partURL,
                    metaURL: metaURL,
                    dest: entry.dest,
                    expectedSize: entry.size,
                    expectedMD5: entry.md5,
                    onBytes: onBytes
                )

                // 流式 MD5 校验（大文件内存恒定）
                let digest = try CDNMD5.file(partURL, isCancelled: { Task.isCancelled })
                guard digest.caseInsensitiveCompare(entry.md5) == .orderedSame else {
                    CDNFS.removeIfExists(partURL)
                    CDNFS.removeIfExists(metaURL)
                    throw CDNError.checksumMismatch(expected: entry.md5, actual: digest, file: entry.dest)
                }

                try CDNFS.moveReplacing(from: partURL, to: destURL)
                CDNFS.removeIfExists(metaURL)

                // 续传时磁盘上已有的前缀字节未计入本次 bytesDone，补齐差额。
                let reported = progressBox.value
                if reported < entry.size {
                    reporter.addBytes(entry.size - reported)
                }
                reporter.markFileDone()
                onFileCompleted?(item)

                let done = incrementCompleted()
                if done == 1 || done % 1000 == 0 {
                    CDNLog.info(logger, "下载进度：\(done) 个文件完成（\(entry.dest)）")
                }
                return .success(bytes: entry.size)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                let attemptNumber = attempt + 1
                if attemptNumber < maxAttempts {
                    let delay = backoffDelay(attempt: attempt, error: error)
                    CDNLog.warn(
                        logger,
                        "下载失败（第 \(attemptNumber)/\(maxAttempts) 次）\(entry.dest)：\(describe(error))；"
                        + "\(CDNFormat.duration(delay)) 后切换 CDN 重试")
                    try await CDNSleep.sleep(seconds: delay)
                } else {
                    CDNLog.error(logger, "下载失败（已达最大重试次数）\(entry.dest)：\(describe(error))")
                }
            }
        }
        let reason = lastError.map(describe) ?? "未知错误"
        return .failure(dest: entry.dest, size: entry.size, reason: "已尝试 \(maxAttempts) 次：\(reason)")
    }

    private func finalizeEmptyFile(entry: CDNManifestEntry, destURL: URL) throws -> ItemOutcome {
        let partURLs = CDNParts.urls(destURL: destURL, partsDir: partsDir)
        let partURL = partURLs.part
        let metaURL = partURLs.meta
        try Data().write(to: partURL, options: [.atomic])
        let digest = CDNMD5.hex(Data())
        guard digest.caseInsensitiveCompare(entry.md5) == .orderedSame else {
            CDNFS.removeIfExists(partURL)
            throw CDNError.checksumMismatch(expected: entry.md5, actual: digest, file: entry.dest)
        }
        try CDNFS.moveReplacing(from: partURL, to: destURL)
        CDNFS.removeIfExists(metaURL)
        reporter.markFileDone()
        onFileCompleted?(Item(entry: entry, destURL: destURL))
        _ = incrementCompleted()
        return .success(bytes: 0)
    }

    // MARK: Range 续传下载

    private func fetchToPart(
        url: URL,
        partURL: URL,
        metaURL: URL,
        dest: String,
        expectedSize: Int64,
        expectedMD5: String,
        onBytes: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let offset = try prepareResume(
            partURL: partURL,
            metaURL: metaURL,
            dest: dest,
            expectedSize: expectedSize,
            expectedMD5: expectedMD5)
        if offset >= expectedSize {
            // 分片已经完整（上次在移动前中断）；外层会做 MD5 校验后收尾。
            CDNLog.info(logger, "发现完整分片，直接校验收尾：\(dest)")
            return
        }
        if offset > 0 {
            CDNLog.info(
                logger,
                "断点续传：\(dest) 已有 \(CDNFormat.bytes(offset)) / \(CDNFormat.bytes(expectedSize))，发送 Range 请求")
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 40)
        request.setValue("PGRLauncher/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
        // 二进制资源禁止透明压缩，否则 Range 偏移会错乱。
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }

        let handler = _FileTaskHandler(
            partURL: partURL,
            metaURL: metaURL,
            destRelativePath: dest,
            expectedSize: expectedSize,
            expectedMD5: expectedMD5,
            requestedOffset: offset,
            onBytes: onBytes)
        let task = session.dataTask(with: request)
        let identifier = task.taskIdentifier
        registerHandler(handler, for: identifier)
        handler.attach(task: task)

        do {
            try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let shouldStart = handler.install(continuation: continuation)
                    if shouldStart {
                        task.resume()
                    }
                }
            }, onCancel: {
                handler.requestCancel()
            })
        } catch {
            unregisterHandler(identifier)
            throw error
        }
        unregisterHandler(identifier)
    }

    /// 同步注册/注销文件任务（放进同步方法，避免在 async 上下文直接使用 NSLock）。
    private func registerHandler(_ handler: _FileTaskHandler, for identifier: Int) {
        handlersLock.lock()
        handlers[identifier] = handler
        handlersLock.unlock()
    }

    private func unregisterHandler(_ identifier: Int) {
        handlersLock.lock()
        handlers.removeValue(forKey: identifier)
        handlersLock.unlock()
    }

    /// 检查 `.part` / `.part.meta`，返回可安全续传的字节偏移（0 = 从头下载）。
    private func prepareResume(
        partURL: URL,
        metaURL: URL,
        dest: String,
        expectedSize: Int64,
        expectedMD5: String
    ) throws -> Int64 {
        let partSize = CDNFS.size(partURL) ?? 0
        guard partSize > 0 else {
            CDNFS.removeIfExists(metaURL)
            try writePartMeta(metaURL: metaURL, dest: dest, received: 0,
                              expectedSize: expectedSize, expectedMD5: expectedMD5)
            return 0
        }
        if partSize > expectedSize {
            CDNFS.removeIfExists(partURL)
            CDNFS.removeIfExists(metaURL)
            try writePartMeta(metaURL: metaURL, dest: dest, received: 0,
                              expectedSize: expectedSize, expectedMD5: expectedMD5)
            return 0
        }
        if let meta = readPartMeta(metaURL),
           meta.md5.caseInsensitiveCompare(expectedMD5) == .orderedSame,
           meta.size == expectedSize {
            // 前后记录一致：安全续传。
            return min(partSize, expectedSize)
        }
        // .part 存在但元数据缺失/不匹配：若大小正好等于目标大小，MD5 通过则直接采用。
        if partSize == expectedSize,
           let digest = try? CDNMD5.file(partURL),
           digest.caseInsensitiveCompare(expectedMD5) == .orderedSame {
            return expectedSize
        }
        CDNFS.removeIfExists(partURL)
        CDNFS.removeIfExists(metaURL)
        try writePartMeta(metaURL: metaURL, dest: dest, received: 0,
                          expectedSize: expectedSize, expectedMD5: expectedMD5)
        return 0
    }

    // MARK: Retry policy

    private func backoffDelay(attempt: Int, error: Error) -> TimeInterval {
        var delay = min(8.0, 0.5 * pow(2.0, Double(attempt)))
        // 4xx（文件在该 CDN 上不存在）/ 分片冲突 / 校验失败：快速切换下一个 CDN，不长时间等待。
        if let cdnError = error as? CDNError {
            switch cdnError {
            case .httpStatus(let code, _) where (400..<500).contains(code):
                delay = min(delay, 0.5)
            case .rangeMismatch, .checksumMismatch:
                delay = min(delay, 0.5)
            default:
                break
            }
        }
        return delay + Double.random(in: 0...0.2)
    }

    private func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        if error is CancellationError { return "已取消" }
        return (error as NSError).localizedDescription
    }

    private func incrementCompleted() -> Int {
        counterLock.lock()
        defer { counterLock.unlock() }
        completedFiles += 1
        return completedFiles
    }

    // MARK: URLSessionDataDelegate（共享 session，按 taskIdentifier 路由）

    private func handler(for task: URLSessionTask) -> _FileTaskHandler? {
        handlersLock.lock()
        defer { handlersLock.unlock() }
        return handlers[task.taskIdentifier]
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let handler = handler(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        handler.didReceive(response: response, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handler = handler(for: dataTask) else { return }
        if let error = handler.didReceiveData(data) {
            handler.finish(.failure(error))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let identifier = task.taskIdentifier
        handlersLock.lock()
        let handler = handlers.removeValue(forKey: identifier)
        handlersLock.unlock()
        handler?.didComplete(error: error)
    }
}

// MARK: - 单文件任务状态

/// 一个下载任务的 URLSession 回调状态机（运行在串行 delegate queue 上，内部用锁保护字段）。
private final class _FileTaskHandler: @unchecked Sendable {
    private let partURL: URL
    private let metaURL: URL
    private let destRelativePath: String
    private let expectedSize: Int64
    private let expectedMD5: String
    private let requestedOffset: Int64
    private let onBytes: @Sendable (Int64) -> Void

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDataTask?
    private var fileHandle: FileHandle?
    private var finished = false
    private var cancelRequested = false
    private var responseOffset: Int64 = 0
    private var received: Int64 = 0
    private var lastMetaFlush: Int64 = 0
    private var started = false

    init(
        partURL: URL,
        metaURL: URL,
        destRelativePath: String,
        expectedSize: Int64,
        expectedMD5: String,
        requestedOffset: Int64,
        onBytes: @escaping @Sendable (Int64) -> Void
    ) {
        self.partURL = partURL
        self.metaURL = metaURL
        self.destRelativePath = destRelativePath
        self.expectedSize = expectedSize
        self.expectedMD5 = expectedMD5
        self.requestedOffset = requestedOffset
        self.onBytes = onBytes
    }

    func attach(task: URLSessionDataTask) {
        lock.lock()
        self.task = task
        let shouldCancel = cancelRequested
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    /// 返回 true 表示需要调用方 `resume()`；返回 false 表示已被取消并已 resume continuation。
    func install(continuation: CheckedContinuation<Void, Error>) -> Bool {
        lock.lock()
        if finished || cancelRequested {
            finished = true
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func requestCancel() {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        cancelRequested = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let handle = fileHandle
        fileHandle = nil
        let receivedSnapshot = received
        let startedSnapshot = started
        lock.unlock()

        try? handle?.close()
        switch result {
        case .success:
            try? FileManager.default.removeItem(at: metaURL)
        case .failure:
            // 保留 `.part` + `.part.meta` 以便下次续传。
            if startedSnapshot {
                try? writePartMeta(
                    metaURL: metaURL,
                    dest: destRelativePath,
                    received: receivedSnapshot,
                    expectedSize: expectedSize,
                    expectedMD5: expectedMD5)
            }
        }
        continuation?.resume(with: result)
    }

    // MARK: Delegate 回调（由引擎转发）

    func didReceive(response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        if finished {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        if cancelRequested {
            lock.unlock()
            finish(.failure(CancellationError()))
            completionHandler(.cancel)
            return
        }
        lock.unlock()

        guard let http = response as? HTTPURLResponse else {
            finish(.failure(CDNError.invalidResponse("非 HTTP 响应")))
            completionHandler(.cancel)
            return
        }

        var start: Int64 = 0
        switch http.statusCode {
        case 206:
            guard let header = http.value(forHTTPHeaderField: "Content-Range"),
                  let range = CDNParse.contentRange(header) else {
                finish(.failure(CDNError.invalidResponse("206 响应缺少 Content-Range")))
                completionHandler(.cancel)
                return
            }
            if expectedSize > 0, let rangeTotal = range.total, rangeTotal != expectedSize {
                finish(.failure(CDNError.incompleteFile(
                    expected: expectedSize, actual: rangeTotal, file: destRelativePath)))
                completionHandler(.cancel)
                return
            }
            start = range.start
            if start != requestedOffset {
                CDNFS.removeIfExists(partURL)
                CDNFS.removeIfExists(metaURL)
                finish(.failure(CDNError.rangeMismatch("请求偏移 \(requestedOffset)，服务器返回 \(start)")))
                completionHandler(.cancel)
                return
            }
        case 200:
            // 服务器忽略了 Range：从头写。
            start = 0
            let length = response.expectedContentLength
            if expectedSize > 0, length > 0, length != expectedSize {
                finish(.failure(CDNError.incompleteFile(
                    expected: expectedSize, actual: length, file: destRelativePath)))
                completionHandler(.cancel)
                return
            }
        case 416:
            let partSize = CDNFS.size(partURL) ?? 0
            if expectedSize > 0, partSize == expectedSize {
                finish(.success(()))
            } else {
                CDNFS.removeIfExists(partURL)
                CDNFS.removeIfExists(metaURL)
                finish(.failure(CDNError.rangeMismatch("HTTP 416 Range Not Satisfiable")))
            }
            completionHandler(.cancel)
            return
        default:
            finish(.failure(CDNError.httpStatus(
                http.statusCode,
                "GET \(http.url?.absoluteString ?? "")")))
            completionHandler(.cancel)
            return
        }

        do {
            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: partURL.path) {
                fileManager.createFile(atPath: partURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: partURL)
            if start == 0 {
                try handle.truncate(atOffset: 0)
            } else {
                let end = try handle.seekToEnd()
                if Int64(end) != start {
                    try handle.truncate(atOffset: UInt64(start))
                }
            }
            _ = try handle.seekToEnd()
            lock.lock()
            fileHandle = handle
            responseOffset = start
            received = 0
            lastMetaFlush = start
            started = true
            lock.unlock()
            try writePartMeta(
                metaURL: metaURL,
                dest: destRelativePath,
                received: start,
                expectedSize: expectedSize,
                expectedMD5: expectedMD5)
        } catch {
            finish(.failure(CDNError.fileWrite(error.localizedDescription)))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func didReceiveData(_ data: Data) -> Error? {
        lock.lock()
        if finished {
            lock.unlock()
            return nil
        }
        let handle = fileHandle
        lock.unlock()
        guard let handle else {
            return CDNError.fileWrite("文件句柄未就绪")
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            return CDNError.fileWrite(error.localizedDescription)
        }

        lock.lock()
        received += Int64(data.count)
        let absolute = responseOffset + received
        let shouldFlush = absolute - lastMetaFlush >= 8 * 1024 * 1024
        if shouldFlush { lastMetaFlush = absolute }
        lock.unlock()

        onBytes(Int64(data.count))
        if shouldFlush {
            try? writePartMeta(
                metaURL: metaURL,
                dest: destRelativePath,
                received: absolute,
                expectedSize: expectedSize,
                expectedMD5: expectedMD5)
        }
        return nil
    }

    func didComplete(error: Error?) {
        lock.lock()
        let alreadyFinished = finished
        let cancelled = cancelRequested
        let startedSnapshot = started
        let absolute = responseOffset + received
        let expected = expectedSize
        lock.unlock()
        if alreadyFinished { return }

        if let error {
            let nsError = error as NSError
            let isCancellation = cancelled
                || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
            finish(.failure(isCancellation ? (CancellationError() as Error) : error))
            return
        }
        guard startedSnapshot else {
            finish(.failure(CDNError.invalidResponse("未收到响应数据")))
            return
        }
        if expected > 0, absolute != expected {
            finish(.failure(CDNError.incompleteFile(
                expected: expected, actual: absolute, file: destRelativePath)))
            return
        }
        finish(.success(()))
    }
}

// MARK: - 小工具

private final class _ByteBox: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64 = 0

    func add(_ delta: Int64) {
        lock.lock()
        total += delta
        lock.unlock()
    }

    var value: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return total
    }
}
