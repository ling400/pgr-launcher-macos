import Foundation

/// Game installation management: detects the installed client, launches it inside the bottle
/// with a Yaagl-style environment, and delegates download / update to the official-CDN engine.
final class GameManager {
    let appSupportDir: URL
    let logger: Logger

    /// Official-CDN download / update engine (implemented in Sources/Services/CDN).
    private lazy var cdn = GameCDN(logger: logger, appSupportDir: appSupportDir)

    var downloadsDir: URL { appSupportDir.appendingPathComponent("downloads", isDirectory: true) }
    var logsDir: URL { appSupportDir.appendingPathComponent("logs", isDirectory: true) }

    /// Main game executable, relative to the game directory (Unity IL2CPP build).
    static let gameExecutableName = "PGR.exe"
    static let versionFileName = "version.json"
    /// Same marker the CDN engine writes after a complete install / update.
    static let installCompleteMarkerName = ".pgrlauncher-install-complete"
    /// Files that must exist before the game can start (Unity IL2CPP payload).
    static let requiredLaunchFiles = ["GameAssembly.dll", "version.json"]

    init(appSupportDir: URL, logger: Logger) {
        self.appSupportDir = appSupportDir
        self.logger = logger
        try? ServiceSupport.ensureDirectory(logsDir)
    }

    // MARK: Detection

    /// Inspect a game directory.
    ///
    /// A directory counts as installed when the CDN engine's `.pgrlauncher-install-complete`
    /// marker exists. Installations made before the marker was introduced are accepted when
    /// `PGR.exe`, `GameAssembly.dll` and `version.json` are all present. A half-finished
    /// directory (e.g. only `PGR.exe` downloaded so far) returns `nil` so the UI keeps
    /// offering the download / repair action.
    func detectInstallation(in gameDir: URL) -> GameInstallation? {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: gameDir.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }

        guard let gameExe = Self.findGameExecutable(in: gameDir) else {
            return nil
        }

        let markerURL = gameDir.appendingPathComponent(Self.installCompleteMarkerName)
        let hasMarker = fileManager.fileExists(atPath: markerURL.path)
        let hasLegacyPayload = Self.requiredLaunchFiles.allSatisfy {
            fileManager.fileExists(atPath: gameDir.appendingPathComponent($0).path)
        }
        guard hasMarker || hasLegacyPayload else {
            ServiceSupport.logInfo(
                logger,
                "游戏目录暂未完整（缺少安装完成标记或 GameAssembly.dll/version.json）：\(gameDir.path)")
            return nil
        }

        let version = Self.readVersion(in: gameDir)
        return GameInstallation(rootDir: gameDir, launcherExe: nil, gameExe: gameExe, version: version)
    }

    /// Locate `PGR.exe` (case-insensitive, tolerating one extra directory level).
    private static func findGameExecutable(in gameDir: URL) -> URL? {
        let fileManager = FileManager.default
        let rootCandidate = gameDir.appendingPathComponent(gameExecutableName)
        if fileManager.fileExists(atPath: rootCandidate.path) {
            return rootCandidate
        }
        // Be tolerant about case and a single wrapping directory (e.g. .../Punishing Gray Raven/PGR.exe).
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: gameDir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        let rootDepth = gameDir.standardizedFileURL.pathComponents.count
        var visited = 0
        while let url = enumerator.nextObject() as? URL {
            visited += 1
            if visited > 5_000 { break }
            let depth = url.standardizedFileURL.pathComponents.count - rootDepth
            if depth > 2 {
                enumerator.skipDescendants()
                continue
            }
            guard url.lastPathComponent.lowercased() == gameExecutableName.lowercased() else { continue }
            if (try? url.resourceValues(forKeys: Set(keys)))?.isRegularFile == true {
                return url
            }
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    /// Parse `version.json`, which the official client writes as `{package_version:4.9.1}`
    /// (tolerating valid JSON as well).
    static func readVersion(in gameDir: URL) -> String? {
        let url = gameDir.appendingPathComponent(versionFileName)
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        if let version = matchPackageVersion(in: text) {
            return version
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["package_version", "packageVersion", "version"] {
                if let value = object[key] as? String, !value.isEmpty { return value }
                if let value = object[key] as? NSNumber { return value.stringValue }
            }
        }
        return nil
    }

    private static func matchPackageVersion(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "package_version\\s*[:=]\\s*\"?([0-9]+(?:\\.[0-9]+)*)\"?") else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[valueRange])
    }

    // MARK: CDN download / update

    /// Download and install the game directly from the official CDN (no official launcher).
    func downloadAndInstall(
        channel: GameChannel,
        gameDir: URL,
        configURLOverride: String?,
        progress: @escaping @MainActor (InstallProgress) -> Void
    ) async throws {
        ServiceSupport.logInfo(logger, "从官方 CDN 安装游戏：渠道=\(channel.displayName) 目录=\(gameDir.path)")
        try await cdn.install(
            channel: channel,
            gameDir: gameDir,
            configURLOverride: configURLOverride,
            progress: progress
        )
    }

    /// Compare the local version with the official CDN and download only changed files.
    func updateInstall(
        channel: GameChannel,
        gameDir: URL,
        configURLOverride: String?,
        progress: @escaping @MainActor (InstallProgress) -> Void
    ) async throws {
        ServiceSupport.logInfo(logger, "检查游戏更新：渠道=\(channel.displayName) 目录=\(gameDir.path)")
        try await cdn.update(
            channel: channel,
            gameDir: gameDir,
            configURLOverride: configURLOverride,
            progress: progress
        )
    }

    /// Remote version of the selected channel (used by UI / diagnostics).
    func remoteVersion(channel: GameChannel, configURLOverride: String?) async throws -> String {
        try await cdn.remoteVersion(channel: channel, configURLOverride: configURLOverride)
    }

    // MARK: Launch

    /// Launch the game executable inside the bottle, logging its stdout/stderr to `logs/game_*.log`.
    func launchGame(
        installation: GameInstallation,
        runtime: RuntimeManager,
        prefix: URL,
        env: [String: String]
    ) async throws -> Process {
        guard runtime.isInstalled() else { throw LauncherError.missingRuntime }
        guard runtime.isPrefixInitialized(at: prefix) else { throw LauncherError.missingPrefix }

        let gameDir = installation.rootDir
        guard FileManager.default.fileExists(atPath: gameDir.path) else {
            throw LauncherError.processFailed("游戏目录不存在：\(gameDir.path)")
        }
        guard let gameExe = installation.gameExe
            ?? Self.findGameExecutable(in: gameDir) else {
            throw LauncherError.processFailed(
                "未找到游戏主程序 \(Self.gameExecutableName)，请先下载游戏")
        }
        guard ServiceSupport.fileExists(gameExe) else {
            throw LauncherError.processFailed("游戏主程序不存在：\(gameExe.path)")
        }
        let missingFiles = Self.requiredLaunchFiles.filter {
            !FileManager.default.fileExists(atPath: gameDir.appendingPathComponent($0).path)
        }
        guard missingFiles.isEmpty else {
            throw LauncherError.processFailed(
                "游戏文件不完整（缺少 \(missingFiles.joined(separator: "、"))），请重新运行下载/校验")
        }

        try ServiceSupport.ensureDirectory(logsDir)
        let logURL = logsDir.appendingPathComponent("game-\(Self.timestamp()).log")
        prepareDXMTConfigFile(env: env)
        ServiceSupport.logInfo(logger, "启动游戏：\(gameExe.path)（工作目录 \(gameDir.path)）")

        return try runtime.launch(
            wineArguments: [ServiceSupport.windowsPath(for: gameExe)],
            env: env,
            workingDirectory: gameDir,
            logFile: logURL
        )
    }

    // MARK: Launch environment

    /// Assemble the environment variables used to launch the game in the bottle.
    /// Mirrors Yaagl's `program-launch-game.ts` (HSR) environment.
    ///
    /// The locale entries matter for the CN client: when launched from a terminal with
    /// `LANG=C.UTF-8`, wine maps the C locale to Windows ANSI codepage 1252 and Chinese
    /// text rendered through ANSI APIs turns into mojibake. Pin a UTF-8 Chinese locale so
    /// wine picks codepage 936 (verified: privacy-policy line renders correctly).
    func launchEnvironment(
        config: AppConfig,
        prefix: URL,
        runtime: RuntimeManager,
        logDir: URL
    ) -> [String: String] {
        try? ServiceSupport.ensureDirectory(logDir)
        var env: [String: String] = [:]
        // Locale first: CN client requires it, harmless for the global client.
        let locale = "zh_CN.UTF-8"
        env["LANG"] = locale
        env["LC_ALL"] = locale
        env["LC_CTYPE"] = locale
        env["WINEPREFIX"] = prefix.path
        env["WINEDEBUG"] = "-all"
        env["WINEMSYNC"] = "1"

        if config.backend == .dxmt {
            var dxmtConfig: [String] = []
            if config.maxFPS > 0 {
                dxmtConfig.append("d3d11.preferredMaxFrameRate=\(config.maxFPS)")
            }
            dxmtConfig.append("dxgi.customVendorId=10de")
            dxmtConfig.append("dxgi.customDeviceId=2684")
            let dxmtConfigValue = dxmtConfig.joined(separator: ";")

            env["DXMT_LOG_PATH"] = logDir.path
            env["DXMT_CONFIG"] = dxmtConfigValue
            env["DXMT_CONFIG_FILE"] = logDir.appendingPathComponent("dxmt.conf").path
            env["DXMT_ENABLE_NVEXT"] = "1"
            env["GST_PLUGIN_FEATURE_RANK"] = "atdec:MAX,avdec_h264:MAX"
            env["MTL_HUD_ENABLED"] = config.metalHud ? "1" : "0"
            writeDXMTConfigFile(contents: dxmtConfigValue, logDir: logDir)
        } else {
            // D3DMetal (GPTK) runtime: no DXMT variables, keep the renderer choice native.
            env["WINEESYNC"] = "1"
            env["MTL_HUD_ENABLED"] = config.metalHud ? "1" : "0"
        }

        if !config.proxy.isEmpty {
            env["HTTP_PROXY"] = config.proxy
            env["HTTPS_PROXY"] = config.proxy
            env["http_proxy"] = config.proxy
            env["https_proxy"] = config.proxy
        }
        return env
    }

    private func writeDXMTConfigFile(contents: String, logDir: URL) {
        try? ServiceSupport.ensureDirectory(logDir)
        let url = logDir.appendingPathComponent("dxmt.conf")
        try? (dotenvBody(from: contents)).write(to: url, atomically: true, encoding: .utf8)
    }

    private func prepareDXMTConfigFile(env: [String: String]) {
        guard let configFile = env["DXMT_CONFIG_FILE"], let config = env["DXMT_CONFIG"] else { return }
        let url = URL(fileURLWithPath: configFile)
        try? ServiceSupport.ensureDirectory(url.deletingLastPathComponent())
        try? dotenvBody(from: config).write(to: url, atomically: true, encoding: .utf8)
        ServiceSupport.logInfo(logger, "DXMT 配置已写入：\(url.path)")
    }

    private func dotenvBody(from dxmtConfig: String) -> String {
        dxmtConfig.split(separator: ";").map(String.init).joined(separator: "\n") + "\n"
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
