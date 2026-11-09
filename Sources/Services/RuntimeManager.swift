import Foundation

// MARK: - Runtime catalog

/// Pinned wine + DXMT releases (same combination Yaagl HSR uses on this machine).
enum WineRuntimeCatalog {
    struct Distro {
        let id: String
        let displayName: String
        let remoteURL: URL
        let sha256: String?
        let expectedSize: Int64?
        let archiveFileName: String
        /// Directory inside the archive that becomes `Runtime/wine`.
        let archiveRoot: String
    }

    struct DXMTPackage {
        let version: String
        let remoteURL: URL
        let sha256: String?
        let expectedSize: Int64?
        let archiveFileName: String
        /// Directory inside the archive holding `x86_64-windows` / `x86_64-unix`.
        let archiveRoot: String
    }

    static let wineCrossover = Distro(
        id: "wine-crossover-11.0-1-signed",
        displayName: "Wine 11.0 (Crossover 11.0-1, signed)",
        remoteURL: URL(string:
            "https://github.com/yaagl/anime-game-wine/releases/download/wine-crossover-11.0-1-signed/wine-crossover-11.0-1-osx64-signed.tar.xz")!,
        sha256: "89fa7e90fb626523a90d5867a03c6be785d017176739c6320a3b86c7838c3a35",
        expectedSize: 456_021_524,
        archiveFileName: "wine-crossover-11.0-1-osx64-signed.tar.xz",
        archiveRoot: "wine"
    )

    static let dxmt = DXMTPackage(
        version: "0.80",
        remoteURL: URL(string:
            "https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz")!,
        sha256: "8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d",
        expectedSize: 18_681_669,
        archiveFileName: "dxmt-v0.80-builtin.tar.gz",
        archiveRoot: "v0.80"
    )

    /// FineWine compatibility modules (CrossOver 26.3 + DW-Proton ACE/Rosetta patches).
    /// Without these the PGR client crashes with `virtual_setup_exception stack overflow`
    /// right after loading PGRBase.dll, so they are mandatory for actually launching the game.
    struct FineWinePatch {
        let version: String
        let remoteURL: URL
        let sha256: String
        let expectedSize: Int64
        let archiveFileName: String
        let archiveRoot: String
    }

    static let fineWine = FineWinePatch(
        version: "1.4.3",
        remoteURL: URL(string:
            "https://github.com/stoicswe/Endfield_FineWine/releases/download/1.4.3/endfield-wine-modules.tar.gz")!,
        sha256: "d71b61275e98a65cab95626f33baa842567c63f8483a6b963a4031de862da2e2",
        expectedSize: 4_278_321,
        archiveFileName: "endfield-wine-modules.tar.gz",
        archiveRoot: "endfield-wine-modules"
    )

    /// Fallback mirrors for GitHub releases (mainland China GitHub is often <100 KB/s).
    static let mirrorPrefixes = [
        "https://gh-proxy.com/",
        "https://ghfast.top/"
    ]

    static func candidateURLs(for remoteURL: URL) -> [URL] {
        var urls = [remoteURL]
        let host = (remoteURL.host ?? "").lowercased()
        if host.contains("github.com") || host.contains("githubusercontent.com") {
            for prefix in mirrorPrefixes {
                if let mirrored = URL(string: prefix + remoteURL.absoluteString) {
                    urls.append(mirrored)
                }
            }
        }
        return urls
    }
}

// MARK: - Errors

enum LauncherError: LocalizedError {
    case downloadFailed(String)
    case checksumMismatch(String)
    case extractionFailed(String)
    case processFailed(String)
    case missingRuntime
    case missingPrefix
    case cancelled

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let msg): return "下载失败：\(msg)"
        case .checksumMismatch(let msg): return "校验失败：\(msg)"
        case .extractionFailed(let msg): return "解压失败：\(msg)"
        case .processFailed(let msg): return "进程失败：\(msg)"
        case .missingRuntime: return "Wine 运行时尚未安装"
        case .missingPrefix: return "Wine 容器尚未初始化，请先准备运行环境"
        case .cancelled: return "已取消"
        }
    }
}

// MARK: - Runtime manager

/// Owns the Wine distribution + DXMT render layer + the Windows bottle (WINEPREFIX).
final class RuntimeManager {
    let appSupportDir: URL
    let logger: Logger
    private let downloader: Downloader

    // MARK: Paths

    var runtimeRoot: URL { appSupportDir.appendingPathComponent("Runtime", isDirectory: true) }
    var downloadsDir: URL { runtimeRoot.appendingPathComponent("downloads", isDirectory: true) }
    var wineRoot: URL { runtimeRoot.appendingPathComponent("wine", isDirectory: true) }
    var wineBinary: URL { wineRoot.appendingPathComponent("bin/wine") }
    var wineserverBinary: URL { wineRoot.appendingPathComponent("bin/wineserver") }
    var dxmtRoot: URL { runtimeRoot.appendingPathComponent("dxmt", isDirectory: true) }
    var finewineRoot: URL { runtimeRoot.appendingPathComponent("finewine", isDirectory: true) }
    var fineWineMarkerURL: URL { runtimeRoot.appendingPathComponent("FineWine.version") }
    var logsDir: URL { appSupportDir.appendingPathComponent("logs", isDirectory: true) }
    var installedMarkerURL: URL { runtimeRoot.appendingPathComponent("runtime-installed.txt") }

    init(appSupportDir: URL, logger: Logger) {
        self.appSupportDir = appSupportDir
        self.logger = logger
        self.downloader = Downloader(logger: logger)
    }

    // MARK: State

    func isInstalled() -> Bool {
        FileManager.default.isExecutableFile(atPath: wineBinary.path)
            && FileManager.default.fileExists(atPath: wineserverBinary.path)
    }

    func isPrefixInitialized(at prefix: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: prefix.appendingPathComponent("system.reg").path)
            && fm.fileExists(atPath: prefix.appendingPathComponent("drive_c/windows/system32").path)
    }

    /// Best-effort wine version string, e.g. "wine-11.0".
    func wineVersion() -> String {
        guard FileManager.default.isExecutableFile(atPath: wineBinary.path) else { return "未安装" }
        let result = ServiceSupport.capture(
            executable: wineBinary,
            arguments: ["--version"],
            environment: baseEnvironment(prefix: nil),
            timeout: 20
        )
        guard result.status == 0 else {
            ServiceSupport.logWarn(logger, "读取 Wine 版本失败（退出码 \(result.status)）：\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            return "未安装"
        }
        let lines = result.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        for line in lines {
            if let range = line.range(of: "wine-[0-9]") {
                let tail = line[range.lowerBound...]
                let token = tail.split(separator: " ").first.map(String.init) ?? String(tail)
                return token
            }
            if line.lowercased().hasPrefix("wine") { return line }
        }
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未安装" : trimmed
    }

    // MARK: Install

    /// Download + verify + extract wine and DXMT, then install DXMT into the wine tree.
    func install(progress: @escaping @MainActor (TaskProgress) -> Void) async throws {
        try ServiceSupport.ensureDirectory(downloadsDir)
        try ServiceSupport.ensureDirectory(logsDir)

        let distro = WineRuntimeCatalog.wineCrossover
        let archiveURL = downloadsDir.appendingPathComponent(distro.archiveFileName)
        if archiveIsValid(archiveURL, sha256: distro.sha256, expectedSize: distro.expectedSize) {
            ServiceSupport.logInfo(logger, "复用已下载的 Wine 运行时包：\(archiveURL.lastPathComponent)")
            await report(progress, TaskProgress(title: "下载 Wine 运行时", detail: "使用已下载的安装包", fraction: 1))
        } else {
            ServiceSupport.logInfo(logger, "下载 Wine 运行时：\(distro.displayName)")
            await report(progress, TaskProgress(title: "下载 Wine 运行时", detail: "正在连接下载源…", fraction: 0))
            try await downloadArchive(
                remoteURL: distro.remoteURL,
                destination: archiveURL,
                sha256: distro.sha256,
                expectedSize: distro.expectedSize,
                title: "下载 Wine 运行时",
                progress: progress
            )
        }

        await report(progress, TaskProgress(title: "校验 Wine 运行时", detail: "SHA-256 校验中…", fraction: nil))
        if let sha = distro.sha256 {
            let digest = try Downloader.sha256(of: archiveURL)
            guard digest.caseInsensitiveCompare(sha) == .orderedSame else {
                throw LauncherError.checksumMismatch("Wine 归档 SHA-256 不匹配：\(digest)")
            }
        }

        await report(progress, TaskProgress(title: "解压 Wine 运行时", detail: "正在解压 456 MB 归档，可能需要 1-2 分钟…", fraction: nil))
        try extractWineArchive(archiveURL, distro: distro)

        // FineWine compatibility modules (CrossOver 26.3 + DW-Proton ACE/Rosetta patches).
        // Mandatory: without them the PGR client crashes right after loading PGRBase.dll.
        let fineWine = WineRuntimeCatalog.fineWine
        let fineWineArchiveURL = downloadsDir.appendingPathComponent(fineWine.archiveFileName)
        if isFineWineInstalled() {
            ServiceSupport.logInfo(logger, "FineWine 补丁模块已安装（v\(fineWine.version)），跳过")
            await report(progress, TaskProgress(
                title: "安装 FineWine 兼容模块",
                detail: "已安装 v\(fineWine.version)（CrossOver 26.3, ACE/Rosetta 修复）",
                fraction: 1))
        } else {
            if archiveIsValid(fineWineArchiveURL, sha256: fineWine.sha256, expectedSize: fineWine.expectedSize) {
                ServiceSupport.logInfo(logger, "复用已下载的 FineWine 模块包")
                await report(progress, TaskProgress(title: "下载 FineWine 兼容模块", detail: "使用已下载的安装包", fraction: 1))
            } else {
                ServiceSupport.logInfo(logger, "下载 FineWine 兼容模块 v\(fineWine.version)…")
                await report(progress, TaskProgress(title: "下载 FineWine 兼容模块", detail: "正在连接下载源…", fraction: 0))
                try await downloadArchive(
                    remoteURL: fineWine.remoteURL,
                    destination: fineWineArchiveURL,
                    sha256: fineWine.sha256,
                    expectedSize: fineWine.expectedSize,
                    title: "下载 FineWine 兼容模块",
                    progress: progress
                )
            }
            let fineWineDigest = try Downloader.sha256(of: fineWineArchiveURL)
            guard fineWineDigest.caseInsensitiveCompare(fineWine.sha256) == .orderedSame else {
                throw LauncherError.checksumMismatch("FineWine 模块归档 SHA-256 不匹配：\(fineWineDigest)")
            }
            await report(progress, TaskProgress(title: "解压 FineWine 兼容模块", detail: "正在解压模块归档…", fraction: nil))
            try extractFineWineArchive(fineWineArchiveURL)
            await report(progress, TaskProgress(
                title: "安装 FineWine 兼容模块",
                detail: "覆盖 kernel32 / ntdll / winemac / wineserver（原文件备份为 .bak）…",
                fraction: nil))
            let applied = try applyFineWineModules()
            if applied {
                ServiceSupport.logInfo(logger, "FineWine 补丁模块已安装（CrossOver 26.3, ACE/Rosetta 修复）v\(fineWine.version)")
            }
        }

        let dxmt = WineRuntimeCatalog.dxmt
        let dxmtArchiveURL = downloadsDir.appendingPathComponent(dxmt.archiveFileName)
        if archiveIsValid(dxmtArchiveURL, sha256: dxmt.sha256, expectedSize: dxmt.expectedSize) {
            ServiceSupport.logInfo(logger, "复用已下载的 DXMT 包：\(dxmtArchiveURL.lastPathComponent)")
            await report(progress, TaskProgress(title: "下载 DXMT", detail: "使用已下载的安装包", fraction: 1))
        } else {
            ServiceSupport.logInfo(logger, "下载 DXMT v\(dxmt.version)…")
            await report(progress, TaskProgress(title: "下载 DXMT", detail: "正在连接下载源…", fraction: 0))
            try await downloadArchive(
                remoteURL: dxmt.remoteURL,
                destination: dxmtArchiveURL,
                sha256: dxmt.sha256,
                expectedSize: dxmt.expectedSize,
                title: "下载 DXMT",
                progress: progress
            )
        }
        if let sha = dxmt.sha256 {
            let digest = try Downloader.sha256(of: dxmtArchiveURL)
            guard digest.caseInsensitiveCompare(sha) == .orderedSame else {
                throw LauncherError.checksumMismatch("DXMT 归档 SHA-256 不匹配：\(digest)")
            }
        }

        await report(progress, TaskProgress(title: "解压 DXMT", detail: "正在解压渲染层…", fraction: nil))
        try extractTarGz(dxmtArchiveURL, to: dxmtRoot)

        await report(progress, TaskProgress(title: "安装 DXMT", detail: "复制到 Wine 目录（原文件备份为 .bak）…", fraction: nil))
        try installDXMT(wineRoot: wineRoot, prefix: nil)

        removeQuarantine()
        writeInstalledMarker()
        await report(progress, TaskProgress(
            title: "Wine 运行时安装完成",
            detail: "Wine 11.0 + FineWine v\(fineWine.version) + DXMT v\(dxmt.version)",
            fraction: 1))
        ServiceSupport.logInfo(logger, "Wine 运行时安装完成：\(wineRoot.path)")
    }

    func uninstall() throws {
        let fm = FileManager.default
        for url in [wineRoot, dxmtRoot, finewineRoot] {
            if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
        }
        ServiceSupport.removeIfExists(installedMarkerURL)
        ServiceSupport.removeIfExists(fineWineMarkerURL)
        ServiceSupport.logInfo(logger, "已卸载 Wine 运行时（保留下载缓存）")
    }

    // MARK: Prefix

    /// Create (or reuse) a wine prefix, apply Windows 10 and install the DXMT DLLs into system32.
    func initializePrefix(
        at prefix: URL,
        progress: @escaping @MainActor (TaskProgress) -> Void
    ) async throws {
        guard isInstalled() else { throw LauncherError.missingRuntime }
        try ServiceSupport.ensureDirectory(prefix)
        try ServiceSupport.ensureDirectory(logsDir)
        let env = baseEnvironment(prefix: prefix)
        let winebootLog = logsDir.appendingPathComponent("wineboot.log")

        if isPrefixInitialized(at: prefix) {
            ServiceSupport.logInfo(logger, "Wine 容器已存在，跳过重复初始化：\(prefix.path)")
            await report(progress, TaskProgress(title: "初始化 Wine 容器", detail: "复用已有容器", fraction: 1))
        } else {
            ServiceSupport.logInfo(logger, "创建 Wine 容器：\(prefix.path)")
            await report(progress, TaskProgress(title: "初始化 Wine 容器", detail: "创建容器（wineboot -u），首次可能需要几十秒…", fraction: nil))
            let status = try await runAndWait(
                wineArguments: ["wineboot", "-u"],
                env: env,
                logFile: winebootLog,
                timeout: 300
            )
            guard status == 0 else {
                throw LauncherError.processFailed(
                    "wineboot 初始化失败（退出码 \(status)），日志：\(winebootLog.path)")
            }
        }

        // Set the Windows version to 10 (some games refuse Windows 7).
        await report(progress, TaskProgress(title: "初始化 Wine 容器", detail: "设置 Windows 10 兼容模式…", fraction: nil))
        _ = try? await runAndWait(
            wineArguments: ["winecfg", "-v", "win10"],
            env: env,
            logFile: logsDir.appendingPathComponent("winecfg.log"),
            timeout: 120
        )

        await report(progress, TaskProgress(title: "初始化 Wine 容器", detail: "安装 DXMT 到 system32…", fraction: nil))
        try installDXMTIntoPrefix(prefix)
        await waitUntilServerExits(env: env, timeout: 120)

        guard isPrefixInitialized(at: prefix) else {
            throw LauncherError.processFailed("Wine 容器创建失败，请查看日志：\(winebootLog.path)")
        }
        await report(progress, TaskProgress(title: "初始化 Wine 容器", detail: "完成", fraction: 1))
        ServiceSupport.logInfo(logger, "Wine 容器初始化完成：\(prefix.path)")
    }

    // MARK: Registry

    func setRetina(_ enabled: Bool, prefix: URL) async throws {
        try await regAdd(
            key: "HKCU\\Software\\Wine\\Mac Driver",
            value: "RetinaMode",
            data: enabled ? "y" : "n",
            prefix: prefix
        )
    }

    func setLeftCommandIsCtrl(_ enabled: Bool, prefix: URL) async throws {
        try await regAdd(
            key: "HKCU\\Software\\Wine\\Mac Driver",
            value: "LeftCommandIsCtrl",
            data: enabled ? "y" : "n",
            prefix: prefix
        )
    }

    func regAdd(key: String, value: String, data: String, prefix: URL) async throws {
        guard isInstalled() else { throw LauncherError.missingRuntime }
        guard isPrefixInitialized(at: prefix) else { throw LauncherError.missingPrefix }
        let logURL = logsDir.appendingPathComponent("wine-registry.log")
        let environment = baseEnvironment(prefix: prefix)
        let status = try await runAndWait(
            wineArguments: [
                "reg", "add", key, "/v", value, "/t", "REG_SZ", "/d", data, "/f"
            ],
            env: environment,
            logFile: logURL,
            timeout: 60
        )
        guard status == 0 else {
            throw LauncherError.processFailed(
                "写入注册表失败（退出码 \(status)）：\(key)\\\(value)，日志：\(logURL.path)")
        }
        ServiceSupport.logInfo(logger, "注册表已写入：\(key)\\\(value)=\(data)")
        await waitUntilServerExits(env: environment, timeout: 60)
    }

    // MARK: DXMT

    /// Install DXMT DLLs into the wine tree (and optionally the prefix system32).
    func installDXMT(wineRoot: URL? = nil, prefix: URL? = nil) throws {
        let targetWineRoot = wineRoot ?? self.wineRoot
        let sourceRoot = dxmtRoot.appendingPathComponent(WineRuntimeCatalog.dxmt.archiveRoot)
        let sourceWinDir = sourceRoot.appendingPathComponent("x86_64-windows")
        let sourceUnixDir = sourceRoot.appendingPathComponent("x86_64-unix")
        let targetWinDir = targetWineRoot.appendingPathComponent("lib/wine/x86_64-windows")
        let targetUnixDir = targetWineRoot.appendingPathComponent("lib/wine/x86_64-unix")

        let fm = FileManager.default
        guard fm.fileExists(atPath: sourceWinDir.path) else {
            throw LauncherError.extractionFailed("DXMT 解压目录不存在：\(sourceWinDir.path)")
        }
        try ServiceSupport.ensureDirectory(targetWinDir)
        try ServiceSupport.ensureDirectory(targetUnixDir)

        for file in ["d3d10core.dll", "d3d11.dll", "dxgi.dll", "winemetal.dll", "nvngx.dll"] {
            let source = sourceWinDir.appendingPathComponent(file)
            guard fm.fileExists(atPath: source.path) else {
                throw LauncherError.extractionFailed("DXMT 归档缺少 \(file)")
            }
            try ServiceSupport.backupAndCopy(from: source, to: targetWinDir.appendingPathComponent(file))
        }
        let winemetalSO = sourceUnixDir.appendingPathComponent("winemetal.so")
        guard fm.fileExists(atPath: winemetalSO.path) else {
            throw LauncherError.extractionFailed("DXMT 归档缺少 winemetal.so")
        }
        try ServiceSupport.backupAndCopy(from: winemetalSO, to: targetUnixDir.appendingPathComponent("winemetal.so"))

        if let prefix {
            try installDXMTIntoPrefix(prefix)
        }
        ServiceSupport.logInfo(logger, "DXMT 已安装到 \(targetWineRoot.path)")
    }

    /// Copy the DXMT DLLs that must live next to the game into the prefix system32.
    func installDXMTIntoPrefix(_ prefix: URL) throws {
        let sourceWinDir = dxmtRoot
            .appendingPathComponent(WineRuntimeCatalog.dxmt.archiveRoot)
            .appendingPathComponent("x86_64-windows")
        let system32 = prefix.appendingPathComponent("drive_c/windows/system32")
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourceWinDir.path) else {
            throw LauncherError.extractionFailed("DXMT 尚未解压，无法安装到 container")
        }
        try ServiceSupport.ensureDirectory(system32)
        for file in ["winemetal.dll", "nvngx.dll"] {
            let source = sourceWinDir.appendingPathComponent(file)
            guard fm.fileExists(atPath: source.path) else {
                throw LauncherError.extractionFailed("DXMT 归档缺少 \(file)")
            }
            try ServiceSupport.copyReplacing(from: source, to: system32.appendingPathComponent(file))
        }
        ServiceSupport.logInfo(logger, "DXMT DLL 已复制到容器 system32")
    }

    // MARK: FineWine compatibility modules

    /// Windows DLLs/EXEs shipped by the FineWine patch (CrossOver 26.3 + DW-Proton ACE/Rosetta fixes).
    static let fineWineWindowsModules = [
        "kernel32.dll", "dwmapi.dll", "ntoskrnl.exe", "wineboot.exe", "rundll32.exe", "lsass.exe"
    ]
    static let fineWineUnixModules = ["ntdll.so", "winemac.so"]

    /// True when the marker matches the pinned FineWine version and every module is in place.
    func isFineWineInstalled() -> Bool {
        let fm = FileManager.default
        guard let marker = try? String(contentsOf: fineWineMarkerURL, encoding: .utf8),
              marker.contains(WineRuntimeCatalog.fineWine.version) else {
            return false
        }
        let windowsDir = wineRoot.appendingPathComponent("lib/wine/x86_64-windows")
        let unixDir = wineRoot.appendingPathComponent("lib/wine/x86_64-unix")
        for file in Self.fineWineWindowsModules
            where !fm.fileExists(atPath: windowsDir.appendingPathComponent(file).path) {
            return false
        }
        for file in Self.fineWineUnixModules
            where !fm.fileExists(atPath: unixDir.appendingPathComponent(file).path) {
            return false
        }
        return fm.isExecutableFile(atPath: wineserverBinary.path)
    }

    /// Overlay the FineWine modules onto the extracted wine tree (originals are kept as `.bak`).
    @discardableResult
    func applyFineWineModules() throws -> Bool {
        let fm = FileManager.default
        let sourceRoot = finewineRoot.appendingPathComponent(WineRuntimeCatalog.fineWine.archiveRoot)
        guard fm.fileExists(atPath: sourceRoot.path) else {
            throw LauncherError.extractionFailed("FineWine 模块尚未解压：\(sourceRoot.path)")
        }
        if isFineWineInstalled() {
            ServiceSupport.logInfo(logger, "FineWine 模块已是 v\(WineRuntimeCatalog.fineWine.version)，无需重复覆盖")
            return false
        }

        let windowsDir = wineRoot.appendingPathComponent("lib/wine/x86_64-windows")
        let unixDir = wineRoot.appendingPathComponent("lib/wine/x86_64-unix")
        try ServiceSupport.ensureDirectory(windowsDir)
        try ServiceSupport.ensureDirectory(unixDir)

        for file in Self.fineWineWindowsModules {
            let source = sourceRoot.appendingPathComponent(file)
            guard fm.fileExists(atPath: source.path) else {
                throw LauncherError.extractionFailed("FineWine 归档缺少 \(file)")
            }
            try ServiceSupport.backupAndCopy(from: source, to: windowsDir.appendingPathComponent(file))
        }
        for file in Self.fineWineUnixModules {
            let source = sourceRoot.appendingPathComponent(file)
            guard fm.fileExists(atPath: source.path) else {
                throw LauncherError.extractionFailed("FineWine 归档缺少 \(file)")
            }
            try ServiceSupport.backupAndCopy(from: source, to: unixDir.appendingPathComponent(file))
        }

        let wineserverSource = sourceRoot.appendingPathComponent("wineserver")
        guard fm.fileExists(atPath: wineserverSource.path) else {
            throw LauncherError.extractionFailed("FineWine 归档缺少 wineserver")
        }
        try ServiceSupport.backupAndCopy(from: wineserverSource, to: wineserverBinary)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wineserverBinary.path)

        // Optional: MoltenVK (only used by the D3DMetal backend; harmless together with DXMT).
        let moltenVK = sourceRoot.appendingPathComponent("libMoltenVK.dylib")
        if fm.fileExists(atPath: moltenVK.path) {
            try? ServiceSupport.backupAndCopy(
                from: moltenVK,
                to: wineRoot.appendingPathComponent("lib/libMoltenVK.dylib"))
        }

        let marker = """
        version=\(WineRuntimeCatalog.fineWine.version)
        sha256=\(WineRuntimeCatalog.fineWine.sha256)
        installed_at=\(ISO8601DateFormatter().string(from: Date()))
        """
        try? marker.write(to: fineWineMarkerURL, atomically: true, encoding: .utf8)

        let crossoverVersion = (try? String(contentsOf: sourceRoot.appendingPathComponent("CROSSOVER_VERSION"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        ServiceSupport.logInfo(logger, "FineWine 模块覆盖完成（CrossOver \(crossoverVersion)）")
        return true
    }

    private func extractFineWineArchive(_ archive: URL) throws {
        ServiceSupport.removeIfExists(finewineRoot)
        try ServiceSupport.ensureDirectory(finewineRoot)
        let logURL = logsDir.appendingPathComponent("finewine-extract.log")
        let status = try? syncRun(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xzf", archive.path, "-C", finewineRoot.path],
            logFile: logURL
        )
        let sourceRoot = finewineRoot.appendingPathComponent(WineRuntimeCatalog.fineWine.archiveRoot)
        guard status == 0, FileManager.default.fileExists(atPath: sourceRoot.path) else {
            let tail = ServiceSupport.tail(of: logURL, maxLines: 30) ?? "(无日志)"
            throw LauncherError.extractionFailed("FineWine 模块解压失败，日志：\(logURL.path)\n\(tail)")
        }
        ServiceSupport.logInfo(logger, "FineWine 模块已解压到 \(finewineRoot.path)")
    }

    // MARK: Process execution

    /// Start a wine process that shows a GUI window (game) and return immediately.
    /// When `logFile` is provided the child's stdout/stderr are redirected there.
    @discardableResult
    func launch(
        wineArguments: [String],
        env: [String: String],
        workingDirectory: URL? = nil,
        logFile: URL? = nil
    ) throws -> Process {
        guard isInstalled() else { throw LauncherError.missingRuntime }
        let process = Process()
        process.executableURL = wineBinary
        process.arguments = wineArguments
        process.environment = mergedEnvironment(env)
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        var logHandle: FileHandle?
        if let logFile {
            try? ServiceSupport.ensureDirectory(logFile.deletingLastPathComponent())
            if !FileManager.default.fileExists(atPath: logFile.path) {
                FileManager.default.createFile(atPath: logFile.path, contents: nil)
            }
            logHandle = try? FileHandle(forWritingTo: logFile)
            logHandle?.seekToEndOfFile()
            process.standardOutput = logHandle ?? FileHandle.nullDevice
            process.standardError = logHandle ?? FileHandle.nullDevice
        }

        do {
            try process.run()
        } catch {
            try? logHandle?.close()
            throw LauncherError.processFailed("无法启动 Wine：\(error.localizedDescription)")
        }
        if let logHandle {
            // Close the log file once the wine process exits (AppState owns termination handling).
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                try? logHandle.close()
            }
            ServiceSupport.logInfo(logger, "游戏输出重定向到 \(logFile?.path ?? "")")
        }
        ServiceSupport.logInfo(logger, "启动 Wine 进程（PID \(process.processIdentifier)）：\(wineArguments.joined(separator: " "))")
        return process
    }

    /// Run a wine command and wait for it to exit.
    @discardableResult
    func runAndWait(
        wineArguments: [String],
        env: [String: String],
        logFile: URL? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> Int32 {
        guard isInstalled() else { throw LauncherError.missingRuntime }
        let environment = mergedEnvironment(env)
        if let logFile {
            try? ServiceSupport.ensureDirectory(logFile.deletingLastPathComponent())
        }
        return try await ServiceSupport.run(
            executable: wineBinary,
            arguments: wineArguments,
            environment: environment,
            logFile: logFile,
            timeout: timeout
        )
    }

    /// Wait until all processes in the bottle exit (`wineserver -w`).
    func waitUntilServerExits(env: [String: String], timeout: TimeInterval? = 600) async {
        guard isInstalled() else { return }
        let status = try? await ServiceSupport.run(
            executable: wineserverBinary,
            arguments: ["-w"],
            environment: mergedEnvironment(env),
            timeout: timeout
        )
        if status == nil {
            ServiceSupport.logWarn(logger, "等待 wineserver 退出超时")
        }
    }

    func killServer(env: [String: String]) async {
        guard isInstalled() else { return }
        let status = try? await ServiceSupport.run(
            executable: wineserverBinary,
            arguments: ["-k"],
            environment: mergedEnvironment(env),
            timeout: 15
        )
        if status == nil {
            ServiceSupport.logWarn(logger, "结束 wineserver 超时")
        } else {
            ServiceSupport.logInfo(logger, "已结束 Wine 容器内的进程")
        }
    }

    // MARK: Environment

    func baseEnvironment(prefix: URL?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["WINEDEBUG"] = env["WINEDEBUG"] ?? "-all"
        if let prefix {
            env["WINEPREFIX"] = prefix.path
        }
        return env
    }

    private func mergedEnvironment(_ overrides: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["WINEDEBUG"] = env["WINEDEBUG"] ?? "-all"
        for (key, value) in overrides {
            env[key] = value
        }
        return env
    }

    // MARK: Internal install helpers

    private func archiveIsValid(_ url: URL, sha256: String?, expectedSize: Int64?) -> Bool {
        guard let size = ServiceSupport.fileSize(url), size > 0 else { return false }
        if let expectedSize, size != expectedSize { return false }
        if let sha256 {
            guard let digest = try? Downloader.sha256(of: url) else { return false }
            return digest.caseInsensitiveCompare(sha256) == .orderedSame
        }
        return true
    }

    private func downloadArchive(
        remoteURL: URL,
        destination: URL,
        sha256: String?,
        expectedSize: Int64?,
        title: String,
        progress: @escaping @MainActor (TaskProgress) -> Void
    ) async throws {
        let candidates = WineRuntimeCatalog.candidateURLs(for: remoteURL)
        try await downloader.download(
            candidates: candidates,
            to: destination,
            expectedSHA256: sha256,
            expectedSize: expectedSize
        ) { p in
            var detail: String
            if p.total > 0 {
                detail = "\(ServiceSupport.humanBytes(p.received)) / \(ServiceSupport.humanBytes(p.total)) · \(ServiceSupport.humanSpeed(p.bytesPerSecond))"
                if let eta = ServiceSupport.remainingTime(
                    bytesRemaining: max(0, p.total - p.received),
                    bytesPerSecond: p.bytesPerSecond) {
                    detail += " · \(eta)"
                }
            } else {
                detail = "\(ServiceSupport.humanBytes(p.received)) · \(ServiceSupport.humanSpeed(p.bytesPerSecond))"
            }
            progress(TaskProgress(
                title: title,
                detail: detail,
                fraction: p.fraction,
                bytesPerSecond: p.bytesPerSecond
            ))
        }
    }

    private func extractWineArchive(_ archive: URL, distro: WineRuntimeCatalog.Distro) throws {
        ServiceSupport.removeIfExists(wineRoot)
        try ServiceSupport.ensureDirectory(runtimeRoot)
        let logURL = logsDir.appendingPathComponent("wine-extract.log")
        let tarURL = URL(fileURLWithPath: "/usr/bin/tar")

        var status = try? syncRun(
            executable: tarURL,
            arguments: ["-xJf", archive.path, "-C", runtimeRoot.path],
            logFile: logURL
        )
        if status != 0 {
            ServiceSupport.logWarn(logger, "tar -xJf 失败，改用 xz 管道解压")
            status = try? syncRun(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "/usr/bin/xz -dc '\(archive.path)' | /usr/bin/tar -xf - -C '\(runtimeRoot.path)'"],
                logFile: logURL
            )
        }
        guard status == 0, FileManager.default.fileExists(atPath: wineBinary.path) else {
            let tail = ServiceSupport.tail(of: logURL, maxLines: 30) ?? "(无日志)"
            throw LauncherError.extractionFailed(
                "Wine 归档解压失败，请检查磁盘空间与文件完整性。日志：\(logURL.path)\n\(tail)")
        }
        if !FileManager.default.isExecutableFile(atPath: wineBinary.path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wineBinary.path)
        }
        ServiceSupport.logInfo(logger, "Wine 已解压到 \(wineRoot.path)")
    }

    private func extractTarGz(_ archive: URL, to destination: URL) throws {
        ServiceSupport.removeIfExists(destination)
        try ServiceSupport.ensureDirectory(destination)
        let logURL = logsDir.appendingPathComponent("dxmt-extract.log")
        let status = try? syncRun(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xzf", archive.path, "-C", destination.path],
            logFile: logURL
        )
        let archRoot = destination.appendingPathComponent(WineRuntimeCatalog.dxmt.archiveRoot)
        guard status == 0, FileManager.default.fileExists(atPath: archRoot.path) else {
            let tail = ServiceSupport.tail(of: logURL, maxLines: 30) ?? "(无日志)"
            throw LauncherError.extractionFailed("DXMT 解压失败，日志：\(logURL.path)\n\(tail)")
        }
        ServiceSupport.logInfo(logger, "DXMT 已解压到 \(destination.path)")
    }

    private func syncRun(executable: URL, arguments: [String], logFile: URL?) throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let logFile {
            try? ServiceSupport.ensureDirectory(logFile.deletingLastPathComponent())
            if !FileManager.default.fileExists(atPath: logFile.path) {
                FileManager.default.createFile(atPath: logFile.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: logFile) {
                process.standardOutput = handle
                process.standardError = handle
            } else {
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
            }
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func removeQuarantine() {
        _ = ServiceSupport.capture(
            executable: URL(fileURLWithPath: "/usr/bin/xattr"),
            arguments: ["-dr", "com.apple.quarantine", wineRoot.path],
            timeout: 60
        )
        ServiceSupport.logInfo(logger, "已移除 Wine 目录的 quarantine 标记")
    }

    private func writeInstalledMarker() {
        let marker = """
        id=\(WineRuntimeCatalog.wineCrossover.id)
        version=\(wineVersion())
        finewine=\(WineRuntimeCatalog.fineWine.version)
        dxmt=\(WineRuntimeCatalog.dxmt.version)
        installed_at=\(ISO8601DateFormatter().string(from: Date()))
        """
        try? marker.write(to: installedMarkerURL, atomically: true, encoding: .utf8)
    }

    // MARK: Progress

    private func report(_ progress: @escaping @MainActor (TaskProgress) -> Void, _ value: TaskProgress) async {
        await MainActor.run {
            progress(value)
        }
    }
}
