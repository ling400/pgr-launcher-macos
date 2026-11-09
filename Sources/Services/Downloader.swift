import Foundation
import CryptoKit

/// Resumable HTTP(S) downloader with progress reporting, mirror fallback and SHA-256 verification.
///
/// Data is streamed into `destination.part` and renamed to `destination` only after the
/// expected size / SHA-256 have been validated, so an interrupted download can always resume.
final class Downloader {
    let logger: Logger

    struct Progress {
        var received: Int64 = 0
        var total: Int64 = 0
        var bytesPerSecond: Int64 = 0
        var fraction: Double? {
            guard total > 0 else { return nil }
            return min(1.0, max(0.0, Double(received) / Double(total)))
        }
    }

    /// Internal error type used while negotiating multiple mirrors / attempts.
    enum DownloadError: LocalizedError {
        case invalidResponse
        case httpStatus(Int)
        case rangeNotSatisfiable
        case slowSource(String)
        case truncated(expected: Int64, actual: Int64)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "服务器返回了无效响应"
            case .httpStatus(let code): return "服务器返回 HTTP \(code)"
            case .rangeNotSatisfiable: return "服务器不支持断点续传"
            case .slowSource(let source): return "下载源速度过慢：\(source)"
            case .truncated(let expected, let actual): return "文件不完整：期望 \(expected) 字节，实际 \(actual) 字节"
            case .cancelled: return "下载已取消"
            }
        }
    }

    /// If a source is slower than this after `graceSeconds`, try the next mirror.
    struct SlowSourcePolicy {
        var graceSeconds: TimeInterval = 25
        var minimumBytesPerSecond: Int64 = 160_000
        /// Do not switch if we already have this fraction of the file (a slow tail is fine).
        var maxFractionBeforeSwitch: Double = 0.6
    }

    init(logger: Logger) {
        self.logger = logger
    }

    // MARK: Public API

    /// Single-URL variant (contract signature).
    @discardableResult
    func download(
        url: URL,
        to destination: URL,
        expectedSHA256: String? = nil,
        expectedSize: Int64? = nil,
        progress: @escaping @MainActor (Progress) -> Void
    ) async throws -> URL {
        try await download(
            candidates: [url],
            to: destination,
            expectedSHA256: expectedSHA256,
            expectedSize: expectedSize,
            progress: progress
        )
    }

    /// Download from the first working candidate. When multiple candidates are supplied the
    /// downloader switches to the next mirror if the current one is too slow or fails, resuming
    /// from the bytes already on disk.
    @discardableResult
    func download(
        candidates: [URL],
        to destination: URL,
        expectedSHA256: String? = nil,
        expectedSize: Int64? = nil,
        progress: @escaping @MainActor (Progress) -> Void
    ) async throws -> URL {
        guard !candidates.isEmpty else {
            throw LauncherError.downloadFailed("没有可用的下载地址")
        }
        try ServiceSupport.ensureDirectory(destination.deletingLastPathComponent())
        let fm = FileManager.default
        let partURL = destination.appendingPathExtension("part")

        if fm.fileExists(atPath: destination.path) {
            if validateExistingFile(destination, expectedSHA256: expectedSHA256, expectedSize: expectedSize) {
                ServiceSupport.logInfo(logger, "下载目标已存在且校验通过，跳过下载：\(destination.lastPathComponent)")
                report(progress, Progress(received: max(expectedSize ?? ServiceSupport.fileSize(destination) ?? 0, 1),
                                          total: expectedSize ?? ServiceSupport.fileSize(destination) ?? 1,
                                          bytesPerSecond: 0), force: true)
                return destination
            }
            ServiceSupport.logWarn(logger, "已存在的文件校验失败，将重新下载：\(destination.lastPathComponent)")
            ServiceSupport.removeIfExists(destination)
        }

        var lastError: Error = DownloadError.invalidResponse
        let useSlowSwitch = candidates.count > 1

        for (index, candidate) in candidates.enumerated() {
            let hasFallback = index < candidates.count - 1
            let policy: SlowSourcePolicy? = (useSlowSwitch && hasFallback) ? SlowSourcePolicy() : nil
            ServiceSupport.logInfo(logger, "开始下载 → \(candidate.absoluteString)")

            for attempt in 1...2 {
                if Task.isCancelled { throw LauncherError.cancelled }
                do {
                    let total = try await attemptDownload(
                        url: candidate,
                        partURL: partURL,
                        expectedSize: expectedSize,
                        slowPolicy: policy,
                        progress: progress
                    )
                    try finalize(
                        partURL: partURL,
                        destination: destination,
                        expectedSHA256: expectedSHA256,
                        expectedSize: expectedSize,
                        reportedTotal: total
                    )
                    ServiceSupport.logInfo(logger, "下载完成：\(destination.lastPathComponent)（\(ServiceSupport.humanBytes(ServiceSupport.fileSize(destination) ?? 0))）")
                    return destination
                } catch let error as DownloadError {
                    switch error {
                    case .cancelled:
                        throw LauncherError.cancelled
                    case .slowSource:
                        lastError = error
                        ServiceSupport.logWarn(logger, "\(error.localizedDescription)，尝试切换下载源")
                        break
                    case .rangeNotSatisfiable:
                        // The .part may already hold the complete file (some CDNs answer 416).
                        if let expectedSize, let partSize = ServiceSupport.fileSize(partURL), partSize == expectedSize {
                            ServiceSupport.logInfo(logger, "服务器返回 416，但本地分片已完整，继续校验")
                        } else {
                            lastError = error
                            ServiceSupport.removeIfExists(partURL)
                        }
                    default:
                        lastError = error
                    }
                    if case .slowSource = error { break }
                } catch let error as LauncherError {
                    switch error {
                    case .cancelled, .checksumMismatch:
                        // Deterministic failure: retrying the same source will not help.
                        throw error
                    default:
                        lastError = error
                    }
                } catch {
                    lastError = error
                }

                if case DownloadError.slowSource = lastError as? DownloadError ?? .invalidResponse {
                    break
                }
                if attempt == 1 {
                    ServiceSupport.logWarn(logger, "下载中断，重试（自动续传）：\(describe(lastError))")
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                } else {
                    break
                }
            }
            if Task.isCancelled { throw LauncherError.cancelled }
        }

        throw LauncherError.downloadFailed("所有下载源均失败：\(describe(lastError))")
    }

    // MARK: Verification helpers

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func validateExistingFile(_ url: URL, expectedSHA256: String?, expectedSize: Int64?) -> Bool {
        guard let size = ServiceSupport.fileSize(url), size > 0 else { return false }
        if let expectedSize, size != expectedSize { return false }
        if let expectedSHA256 {
            guard let digest = try? Downloader.sha256(of: url) else { return false }
            return digest.caseInsensitiveCompare(expectedSHA256) == .orderedSame
        }
        return true
    }

    private func finalize(
        partURL: URL,
        destination: URL,
        expectedSHA256: String?,
        expectedSize: Int64?,
        reportedTotal: Int64
    ) throws {
        let fm = FileManager.default
        guard let size = ServiceSupport.fileSize(partURL), size > 0 else {
            throw LauncherError.downloadFailed("下载文件为空")
        }
        if let expectedSize, size != expectedSize {
            ServiceSupport.removeIfExists(partURL)
            throw LauncherError.downloadFailed(
                "文件大小不符：期望 \(expectedSize) 字节，实际 \(size) 字节")
        }
        if reportedTotal > 0 && size != reportedTotal {
            ServiceSupport.removeIfExists(partURL)
            throw LauncherError.downloadFailed(
                "下载不完整：期望 \(reportedTotal) 字节，实际 \(size) 字节")
        }
        if let expectedSHA256 {
            let digest = try Downloader.sha256(of: partURL)
            guard digest.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
                ServiceSupport.removeIfExists(partURL)
                throw LauncherError.checksumMismatch(
                    "SHA-256 不匹配：期望 \(expectedSHA256)，实际 \(digest)")
            }
        }
        if fm.fileExists(atPath: destination.path) {
            try? fm.removeItem(at: destination)
        }
        try fm.moveItem(at: partURL, to: destination)
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func report(_ handler: @escaping @MainActor (Progress) -> Void, _ value: Progress, force: Bool = false) {
        let payload = value
        Task { @MainActor in
            handler(payload)
        }
    }

    // MARK: Single attempt

    private func attemptDownload(
        url: URL,
        partURL: URL,
        expectedSize: Int64?,
        slowPolicy: SlowSourcePolicy?,
        progress: @escaping @MainActor (Progress) -> Void
    ) async throws -> Int64 {
        let offset = ServiceSupport.fileSize(partURL) ?? 0
        if offset > 0 {
            ServiceSupport.logInfo(logger, "检测到未完成分片 \(ServiceSupport.humanBytes(offset))，尝试断点续传")
        }
        report(progress,
               Progress(received: offset, total: expectedSize ?? 0, bytesPerSecond: 0),
               force: true)

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("PGRLauncher/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60 * 60 * 12
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        let delegate = _DownloadDelegate(
            partURL: partURL,
            initialOffset: offset,
            expectedSize: expectedSize,
            slowPolicy: slowPolicy,
            logger: logger
        ) { p in
            progress(p)
        }
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        delegate.attach(task: task)
        defer { session.invalidateAndCancel() }

        if Task.isCancelled {
            throw DownloadError.cancelled
        }
        do {
            try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    delegate.install(continuation: continuation)
                    task.resume()
                }
            }, onCancel: {
                delegate.cancel()
            })
        } catch {
            if Task.isCancelled { throw DownloadError.cancelled }
            throw error
        }
        if Task.isCancelled { throw DownloadError.cancelled }
        return delegate.finalTotal
    }
}

// MARK: - URLSession delegate

private final class _DownloadDelegate: NSObject, URLSessionDataDelegate {
    private let partURL: URL
    private let initialOffset: Int64
    private let expectedSize: Int64?
    private let slowPolicy: Downloader.SlowSourcePolicy?
    private let logger: Logger
    private let report: @MainActor (Downloader.Progress) -> Void

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false
    private var cancelled = false
    private var fileHandle: FileHandle?
    private var task: URLSessionDataTask?
    private var responseOffset: Int64 = 0
    private var totalBytes: Int64 = 0
    private var receivedBytes: Int64 = 0
    private var lastReportAt = Date()
    private var lastReportAbs: Int64 = 0
    private var smoothedSpeed: Double = 0
    private var startedAt = Date()
    private var warnedSlow = false

    init(
        partURL: URL,
        initialOffset: Int64,
        expectedSize: Int64?,
        slowPolicy: Downloader.SlowSourcePolicy?,
        logger: Logger,
        report: @escaping @MainActor (Downloader.Progress) -> Void
    ) {
        self.partURL = partURL
        self.initialOffset = initialOffset
        self.expectedSize = expectedSize
        self.slowPolicy = slowPolicy
        self.logger = logger
        self.report = report
        super.init()
    }

    var finalTotal: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return totalBytes
    }

    func attach(task: URLSessionDataTask) {
        lock.lock()
        self.task = task
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { task.cancel() }
    }

    func install(continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if finished || cancelled {
            lock.unlock()
            continuation.resume(throwing: Downloader.DownloadError.cancelled)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    private func finish(_ result: Result<Void, Error>) {
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
        lock.unlock()

        try? handle?.close()
        continuation?.resume(with: result)
    }

    // URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if cancelled {
            finish(.failure(Downloader.DownloadError.cancelled))
            completionHandler(.cancel)
            return
        }
        guard let http = response as? HTTPURLResponse else {
            finish(.failure(Downloader.DownloadError.invalidResponse))
            completionHandler(.cancel)
            return
        }
        let status = http.statusCode
        var offset = initialOffset
        var total: Int64 = 0
        let contentLength = response.expectedContentLength

        switch status {
        case 206:
            if let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
               let totalPart = contentRange.split(separator: "/").last,
               let parsed = Int64(totalPart.trimmingCharacters(in: .whitespaces)) {
                total = parsed
            } else if contentLength > 0 {
                total = offset + contentLength
            }
        case 200:
            // Server ignored our Range header: restart the file from scratch.
            offset = 0
            total = contentLength > 0 ? contentLength : 0
            try? FileManager.default.removeItem(at: partURL)
        case 416:
            finish(.failure(Downloader.DownloadError.rangeNotSatisfiable))
            completionHandler(.cancel)
            return
        default:
            finish(.failure(Downloader.DownloadError.httpStatus(status)))
            completionHandler(.cancel)
            return
        }

        if total == 0, let expectedSize { total = expectedSize }
        responseOffset = offset
        totalBytes = total
        receivedBytes = 0

        do {
            if !FileManager.default.fileExists(atPath: partURL.path) {
                FileManager.default.createFile(atPath: partURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: partURL)
            let end = try handle.seekToEnd()
            if Int64(end) != offset {
                try handle.truncate(atOffset: UInt64(offset))
                _ = try handle.seekToEnd()
            }
            fileHandle = handle
        } catch {
            finish(.failure(error))
            completionHandler(.cancel)
            return
        }

        startedAt = Date()
        lastReportAt = startedAt
        lastReportAbs = offset
        smoothedSpeed = 0
        emitProgress(final: false)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if finished { return }
        do {
            try fileHandle?.write(contentsOf: data)
        } catch {
            finish(.failure(error))
            dataTask.cancel()
            return
        }
        receivedBytes += Int64(data.count)
        emitProgress(final: false)

        if let policy = slowPolicy, !warnedSlow {
            let elapsed = Date().timeIntervalSince(startedAt)
            let absolute = responseOffset + receivedBytes
            let fraction = totalBytes > 0 ? Double(absolute) / Double(totalBytes) : 1.0
            if elapsed > policy.graceSeconds,
               smoothedSpeed < Double(policy.minimumBytesPerSecond),
               fraction < policy.maxFractionBeforeSwitch {
                warnedSlow = true
                ServiceSupport.logWarn(
                    logger,
                    "下载速度仅 \(ServiceSupport.humanSpeed(Int64(smoothedSpeed)))，切换镜像")
                finish(.failure(Downloader.DownloadError.slowSource("低速")))
                dataTask.cancel()
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let nsError = error as NSError
            let isCancellation = cancelled
                || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
            if isCancellation {
                finish(.failure(Downloader.DownloadError.cancelled))
            } else {
                finish(.failure(error))
            }
            return
        }
        let absolute = responseOffset + receivedBytes
        if let expectedSize, absolute != expectedSize {
            finish(.failure(Downloader.DownloadError.truncated(expected: expectedSize, actual: absolute)))
            return
        }
        if totalBytes > 0 && absolute != totalBytes {
            finish(.failure(Downloader.DownloadError.truncated(expected: totalBytes, actual: absolute)))
            return
        }
        totalBytes = max(totalBytes, absolute)
        emitProgress(final: true)
        finish(.success(()))
    }

    private func emitProgress(final: Bool) {
        let now = Date()
        let absolute = responseOffset + receivedBytes
        let elapsed = now.timeIntervalSince(lastReportAt)
        if !final && elapsed < 0.35 && receivedBytes > 0 { return }
        let instant = elapsed > 0 ? Double(absolute - lastReportAbs) / elapsed : 0
        if smoothedSpeed <= 0 {
            smoothedSpeed = instant
        } else {
            smoothedSpeed = smoothedSpeed * 0.75 + instant * 0.25
        }
        if instant > 0, smoothedSpeed < instant * 0.2 { smoothedSpeed = instant }
        lastReportAt = now
        lastReportAbs = absolute
        let total = final ? max(totalBytes, absolute) : totalBytes
        let value = Downloader.Progress(
            received: absolute,
            total: total,
            bytesPerSecond: max(0, Int64(smoothedSpeed))
        )
        let handler = report
        Task { @MainActor in
            handler(value)
        }
    }
}
