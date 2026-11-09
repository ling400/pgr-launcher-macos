import Foundation
import Combine

/// Thread-safe logger that mirrors entries to memory (for the UI) and to a rotating log file.
final class Logger: ObservableObject {
    @Published private(set) var entries: [LogEntry] = []

    let logFileURL: URL
    private let queue = DispatchQueue(label: "pgrlauncher.logger")
    private var fileHandle: FileHandle?
    private let maxEntries = 2000

    init(appSupportDir: URL) {
        let logDir = appSupportDir.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        logFileURL = logDir.appendingPathComponent("launcher-\(formatter.string(from: Date())).log")
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: logFileURL)
        fileHandle?.seekToEndOfFile()
    }

    func log(_ level: LogLevel, _ message: String) {
        let entry = LogEntry(date: Date(), level: level, message: message)
        let line = "[\(Self.timestampFormatter.string(from: entry.date))] [\(level.rawValue.uppercased())] \(message)\n"
        queue.sync {
            entries.append(entry)
            if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
            if let data = line.data(using: .utf8) {
                fileHandle?.write(data)
            }
        }
        if let data = line.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }

    func info(_ message: String) { log(.info, message) }
    func warn(_ message: String) { log(.warn, message) }
    func error(_ message: String) { log(.error, message) }

    func clear() {
        queue.sync { entries.removeAll() }
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
