import Foundation
import AppKit

// MARK: - Formatting

enum PGRFormat {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useMB, .useGB]
        f.includesUnit = true
        f.isAdaptive = true
        return f
    }()

    static func bytes(_ value: Int64) -> String {
        byteFormatter.string(fromByteCount: max(0, value))
    }

    static func speed(_ bytesPerSecond: Int64?) -> String? {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return nil }
        return "\(byteFormatter.string(fromByteCount: bytesPerSecond))/s"
    }

    static func percent(_ fraction: Double) -> String {
        let clamped = min(max(fraction, 0), 1)
        let value = clamped * 100
        if value >= 100 { return "100%" }
        if value >= 10 { return String(format: "%.1f%%", value) }
        return String(format: "%.2f%%", value)
    }

    static func fraction(_ value: Double) -> String {
        String(format: "%.0f%%", min(max(value, 0), 1) * 100)
    }

    /// "约 42 秒" / "约 2 分 13 秒" / "约 1 小时 04 分".
    static func remaining(seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "计算中…" }
        let total = Int(seconds.rounded())
        if total < 60 { return "约 \(max(total, 1)) 秒" }
        if total < 3600 {
            let m = total / 60
            let s = total % 60
            return s == 0 ? "约 \(m) 分钟" : "约 \(m) 分 \(s) 秒"
        }
        let h = total / 3600
        let m = (total % 3600) / 60
        return String(format: "约 %d 小时 %02d 分", h, m)
    }

    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func dateTime(_ date: Date) -> String {
        dateTimeFormatter.string(from: date)
    }

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    static func logLine(_ entry: LogEntry) -> String {
        "[\(dateTime(entry.date))] [\(entry.level.rawValue.uppercased())] \(entry.message)"
    }
}

// MARK: - Small AppKit bridges (kept tiny and UI-only)

enum PGRSystem {
    /// Reveal a file in Finder when it exists, otherwise open its parent folder.
    static func reveal(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    static func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Native directory picker used by the settings page.
    static func chooseDirectory(startingAt url: URL?, message: String = "选择游戏安装目录") -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = message
        if let url {
            panel.directoryURL = url
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Available capacity (bytes) of the volume backing `url`, walking up to an existing ancestor.
    static func availableDiskSpace(at url: URL) -> Int64? {
        var probe = url
        var hops = 0
        while !FileManager.default.fileExists(atPath: probe.path), hops < 12 {
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path { break }
            probe = parent
            hops += 1
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    static func truncatePath(_ path: String, maxLength: Int = 58) -> String {
        guard path.count > maxLength else { return path }
        let head = path.prefix(maxLength / 2)
        let tail = path.suffix(maxLength / 2)
        return "\(head)…\(tail)"
    }
}
