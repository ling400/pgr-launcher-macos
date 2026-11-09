import Foundation

/// Small helpers shared by the service layer (process spawning, formatting, file helpers).
enum ServiceSupport {
    // MARK: Formatting

    static func humanBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(bytes) / 1024.0
        var index = 0
        while value >= 1024 && index < units.count - 1 {
            value /= 1024.0
            index += 1
        }
        return String(format: "%.1f %@", value, units[index])
    }

    static func humanSpeed(_ bytesPerSecond: Int64) -> String {
        humanBytes(max(0, bytesPerSecond)) + "/s"
    }

    static func remainingTime(bytesRemaining: Int64, bytesPerSecond: Int64) -> String? {
        guard bytesRemaining > 0, bytesPerSecond > 0 else { return nil }
        let seconds = Double(bytesRemaining) / Double(bytesPerSecond)
        if seconds < 60 { return String(format: "剩余 %.0f 秒", seconds) }
        if seconds < 3600 { return String(format: "剩余 %.0f 分", seconds / 60) }
        return String(format: "剩余 %.1f 小时", seconds / 3600)
    }

    // MARK: Paths

    /// Convert a local mac path to the `Z:` drive path wine understands.
    static func windowsPath(for url: URL) -> String {
        "Z:" + url.standardizedFileURL.path.replacingOccurrences(of: "/", with: "\\")
    }

    static func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func fileSize(_ url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attrs[.size] as? NSNumber else { return nil }
        return number.int64Value
    }

    static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    static func removeIfExists(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Copy `source` over `destination`, moving any existing file to `<name>.bak` first (Yaagl-style).
    static func backupAndCopy(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            let backup = destination.appendingPathExtension("bak")
            if !fm.fileExists(atPath: backup.path) {
                try? fm.removeItem(at: backup)
                try fm.moveItem(at: destination, to: backup)
            } else {
                try? fm.removeItem(at: destination)
            }
        }
        try fm.copyItem(at: source, to: destination)
    }

    /// Overwrite `destination` with `source`, replacing any existing file (no backup).
    static func copyReplacing(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            try? fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
    }

    static func tail(of url: URL, maxLines: Int = 40, maxBytes: Int = 128 * 1024) -> String? {
        guard let size = fileSize(url), size > 0 else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let offset = max(0, size - Int64(maxBytes))
        do {
            try handle.seek(toOffset: UInt64(offset))
            let data = try handle.readToEnd() ?? Data()
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            return lines.suffix(maxLines).joined(separator: "\n")
        } catch {
            return nil
        }
    }

    // MARK: Logging (safe from any thread)

    static func logInfo(_ logger: Logger, _ message: String) {
        log(logger, level: .info, message)
    }

    static func logWarn(_ logger: Logger, _ message: String) {
        log(logger, level: .warn, message)
    }

    static func logError(_ logger: Logger, _ message: String) {
        log(logger, level: .error, message)
    }

    private static func log(_ logger: Logger, level: LogLevel, _ message: String) {
        if Thread.isMainThread {
            logger.log(level, message)
        } else {
            DispatchQueue.main.async {
                logger.log(level, message)
            }
        }
    }

    // MARK: Process execution

    /// Run a process to completion and return its exit status.
    /// `timeout` is the wall-clock limit before the child is asked to terminate.
    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        logFile: URL? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        var logHandle: FileHandle?
        if let logFile {
            try? ensureDirectory(logFile.deletingLastPathComponent())
            if !FileManager.default.fileExists(atPath: logFile.path) {
                FileManager.default.createFile(atPath: logFile.path, contents: nil)
            }
            let handle = try? FileHandle(forWritingTo: logFile)
            handle?.seekToEndOfFile()
            logHandle = handle
            process.standardOutput = handle ?? FileHandle.nullDevice
            process.standardError = handle ?? FileHandle.nullDevice
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        let status: Int32
        do {
            status = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                if let timeout {
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                        if process.isRunning {
                            process.terminate()
                        }
                    }
                }
            }
        } catch {
            try? logHandle?.close()
            throw error
        }
        try? logHandle?.close()
        return status
    }

    /// Synchronously run a short-lived process and capture its combined output.
    static func capture(executable: URL, arguments: [String], environment: [String: String]? = nil, timeout: TimeInterval = 15) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 2)
            return (-1, "超时")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
