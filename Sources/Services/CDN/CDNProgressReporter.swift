import Foundation

/// 进度聚合器：
/// - 汇总已完成文件数 / 字节数 / 当前文件；
/// - 用最近 2s 滑窗计算实时速度；
/// - 以 5Hz（≥ 需求 4Hz）在 MainActor 回调 `InstallProgress`，不阻塞主线程；
/// - `finish(...)` 保证最后一次回调是 100% 完成态。
final class CDNProgressReporter: @unchecked Sendable {
    private let handler: @MainActor (InstallProgress) -> Void
    private let lock = NSLock()

    private var phase = ""
    private var filesTotal = 0
    private var filesDone = 0
    private var bytesTotal: Int64 = 0
    private var bytesDone: Int64 = 0
    private var currentFile = ""
    private var samples: [(time: TimeInterval, bytes: Int64)] = []
    private var pumpTask: Task<Void, Never>?
    private var stopped = false

    init(handler: @escaping @MainActor (InstallProgress) -> Void) {
        self.handler = handler
    }

    // MARK: Lifecycle

    func start() {
        lock.lock()
        if stopped || pumpTask != nil {
            lock.unlock()
            return
        }
        samples = [(ProcessInfo.processInfo.systemUptime, 0)]
        lock.unlock()

        pumpTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 200_000_000) // 5Hz
                } catch {
                    return
                }
                guard let self else { return }
                await self.emit(final: false)
            }
        }
    }

    func stop() {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        stopped = true
        pumpTask?.cancel()
        pumpTask = nil
        lock.unlock()
    }

    /// 结束并强制发出一次完成态进度（`phase` / 计数可覆盖）。
    func finish(
        phase: String? = nil,
        filesDone: Int? = nil,
        filesTotal: Int? = nil,
        bytesDone: Int64? = nil,
        bytesTotal: Int64? = nil
    ) async {
        guard prepareFinish(
            phase: phase,
            filesDone: filesDone,
            filesTotal: filesTotal,
            bytesDone: bytesDone,
            bytesTotal: bytesTotal) else { return }
        await emit(final: true)
    }

    /// 同步部分：标记停止并发泵、覆盖最终计数。放在同步方法里避免在 async 上下文直接用 NSLock。
    private func prepareFinish(
        phase: String?,
        filesDone: Int?,
        filesTotal: Int?,
        bytesDone: Int64?,
        bytesTotal: Int64?
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if stopped { return false }
        stopped = true
        pumpTask?.cancel()
        pumpTask = nil
        if let phase { self.phase = phase }
        if let filesDone { self.filesDone = filesDone }
        if let filesTotal { self.filesTotal = filesTotal }
        if let bytesDone { self.bytesDone = bytesDone }
        if let bytesTotal { self.bytesTotal = bytesTotal }
        return true
    }

    // MARK: Updates

    func setPhase(_ phase: String, filesTotal: Int, bytesTotal: Int64) {
        lock.lock()
        self.phase = phase
        self.filesTotal = filesTotal
        self.filesDone = 0
        self.bytesTotal = bytesTotal
        self.bytesDone = 0
        self.currentFile = ""
        samples = [(ProcessInfo.processInfo.systemUptime, 0)]
        lock.unlock()
    }

    func addBytes(_ delta: Int64) {
        guard delta > 0 else { return }
        lock.lock()
        bytesDone += delta
        lock.unlock()
    }

    func setCurrentFile(_ name: String) {
        lock.lock()
        if currentFile != name { currentFile = name }
        lock.unlock()
    }

    func markFileDone() {
        lock.lock()
        filesDone += 1
        lock.unlock()
    }

    func setFilesDone(_ done: Int) {
        lock.lock()
        filesDone = done
        lock.unlock()
    }

    // MARK: Emit

    private func emit(final: Bool) async {
        let snapshot: InstallProgress? = {
            lock.lock()
            defer { lock.unlock() }
            if stopped && !final { return nil }

            var bytesPerSecond: Int64 = 0
            if final {
                bytesPerSecond = 0
            } else {
                let now = ProcessInfo.processInfo.systemUptime
                samples.append((now, bytesDone))
                samples.removeAll { now - $0.time > 2.0 }
                if samples.count > 128 {
                    samples.removeFirst(samples.count - 128)
                }
                if let first = samples.first, now - first.time > 0.05 {
                    bytesPerSecond = Int64((Double(bytesDone - first.bytes) / (now - first.time)).rounded())
                }
            }
            return InstallProgress(
                phase: phase,
                currentFile: currentFile,
                filesDone: filesDone,
                filesTotal: filesTotal,
                bytesDone: bytesDone,
                bytesTotal: bytesTotal,
                bytesPerSecond: max(0, bytesPerSecond)
            )
        }()
        guard let snapshot else { return }
        await MainActor.run {
            self.handler(snapshot)
        }
    }
}
