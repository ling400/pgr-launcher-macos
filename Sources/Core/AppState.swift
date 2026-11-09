import Foundation
import SwiftUI
import Combine

/// Central application state: owns services, persists configuration and exposes intents to the UI.
@MainActor
final class AppState: ObservableObject {
    static let appVersion = "0.1.0"
    static let appName = "PGR Launcher"

    let appSupportDir: URL
    let logger: Logger
    let runtime: RuntimeManager
    let game: GameManager
    let keyMapper: KeyMapper

    @Published private(set) var config: AppConfig
    @Published private(set) var status: LauncherStatus = .checking
    @Published private(set) var progress: TaskProgress?
    @Published private(set) var wineVersion: String = "未安装"
    @Published private(set) var installation: GameInstallation?
    @Published private(set) var isGameRunning: Bool = false
    @Published private(set) var runtimeInstalled: Bool = false
    @Published var showSettings: Bool = false
    @Published var showKeyMapping: Bool = false
    @Published var showLogs: Bool = false

    private let configURL: URL
    private var gameProcess: Process?
    private var cancellables = Set<AnyCancellable>()
    private var didBootstrap = false

    // MARK: Init

    init(appSupportDir: URL? = nil) {
        let support = appSupportDir ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PGRLauncher", isDirectory: true)
        self.appSupportDir = support
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.logger = Logger(appSupportDir: support)
        self.runtime = RuntimeManager(appSupportDir: support, logger: logger)
        self.game = GameManager(appSupportDir: support, logger: logger)
        self.keyMapper = KeyMapper(logger: logger)
        self.configURL = support.appendingPathComponent("config.json")
        self.config = Self.loadConfig(from: configURL) ?? .default()

        keyMapper.setMappings(config.keyMappings)

        // Forward logger changes so views observing AppState refresh the log console.
        logger.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        logger.info("\(Self.appName) \(Self.appVersion) 启动，数据目录：\(support.path)")
    }

    // MARK: Derived

    var bottleDir: URL { appSupportDir.appendingPathComponent("Bottle", isDirectory: true) }
    var availableChannels: [GameChannel] { GameChannel.all }
    var currentChannel: GameChannel { GameChannel.channel(id: config.channelID) }
    var logsDir: URL { appSupportDir.appendingPathComponent("logs", isDirectory: true) }
    var gameDirURL: URL { URL(fileURLWithPath: config.gameDir) }
    var logEntries: [LogEntry] { logger.entries }
    var isBusy: Bool { status.isBusy }

    var gameVersionText: String {
        if let version = installation?.version, !version.isEmpty { return version }
        return installation == nil ? "未安装" : "已安装"
    }

    // MARK: Lifecycle

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        status = .checking
        refreshRuntimeState()
        installation = game.detectInstallation(in: gameDirURL)
        if !runtimeInstalled {
            status = .needsRuntime
        } else if installation == nil {
            status = .needsGame
        } else {
            status = .ready
        }
        logger.info("环境检查完成：wine=\(wineVersion)，游戏=\(installation == nil ? "未安装" : "已安装")")
    }

    func refreshRuntimeState() {
        runtimeInstalled = runtime.isInstalled()
        wineVersion = runtime.wineVersion()
        if keyMapper.isRunning { keyMapper.stop() }
    }

    // MARK: Runtime

    func installRuntime() async {
        guard !status.isBusy else { return }
        status = .preparingRuntime
        logger.info("开始安装 Wine 运行时")
        do {
            progress = TaskProgress(title: "下载 Wine 运行时", detail: "准备中…")
            try await runtime.install { [weak self] p in self?.progress = p }
            progress = TaskProgress(title: "初始化 Wine 容器", detail: "首次初始化可能需要几十秒…", fraction: nil)
            try await runtime.initializePrefix(at: bottleDir) { [weak self] p in self?.progress = p }
            progress = nil
            refreshRuntimeState()
            await applyBottleSettings()
            installation = game.detectInstallation(in: gameDirURL)
            status = installation == nil ? .needsGame : .ready
            logger.info("Wine 运行时安装完成")
        } catch {
            fail(error)
        }
    }

    func reinstallRuntime() async {
        guard !status.isBusy else { return }
        do {
            logger.warn("卸载既有 Wine 运行时")
            try runtime.uninstall()
            refreshRuntimeState()
            await installRuntime()
        } catch {
            fail(error)
        }
    }

    // MARK: Game

    /// Download / install the game directly from the official CDN (Yaagl-style, no official launcher needed).
    func downloadAndInstallGame() async {
        guard !status.isBusy else { return }
        guard runtimeInstalled else { status = .needsRuntime; return }
        status = .downloading
        logger.info("开始从官方 CDN 下载游戏，渠道：\(currentChannel.displayName)")
        do {
            try await game.downloadAndInstall(
                channel: currentChannel,
                gameDir: gameDirURL,
                configURLOverride: config.installerURL.isEmpty ? nil : config.installerURL
            ) { [weak self] p in
                self?.applyInstallProgress(p)
            }
            refreshInstallation()
            progress = nil
            status = installation == nil ? .needsGame : .ready
            logger.info("游戏下载/安装完成，版本：\(installation?.version ?? "未知")")
        } catch {
            fail(error)
        }
    }

    /// Check for a newer version and download changed files only.
    func updateGame() async {
        guard !status.isBusy else { return }
        guard runtimeInstalled else { status = .needsRuntime; return }
        status = .updating
        logger.info("检查游戏更新…")
        do {
            try await game.updateInstall(
                channel: currentChannel,
                gameDir: gameDirURL,
                configURLOverride: config.installerURL.isEmpty ? nil : config.installerURL
            ) { [weak self] p in
                self?.applyInstallProgress(p)
            }
            refreshInstallation()
            progress = nil
            status = installation == nil ? .needsGame : .ready
            logger.info("游戏已更新到最新版本")
        } catch {
            fail(error)
        }
    }

    private func applyInstallProgress(_ p: InstallProgress) {
        var detail = p.phase
        if p.filesTotal > 0 {
            detail = "\(p.phase) · \(p.filesDone)/\(p.filesTotal) 个文件"
        }
        if p.bytesTotal > 0, let pct = p.fraction {
            detail += " · \(Int(pct * 100))%"
        }
        if !p.currentFile.isEmpty {
            detail += " · \(p.currentFile)"
        }
        progress = TaskProgress(
            title: "下载游戏资源",
            detail: detail,
            fraction: p.fraction,
            bytesPerSecond: p.bytesPerSecond
        )
    }

    func launchGame() async {
        guard !status.isBusy else { return }
        guard runtimeInstalled else { status = .needsRuntime; return }
        guard let install = installation ?? game.detectInstallation(in: gameDirURL),
              install.gameExe != nil else {
            status = .needsGame
            return
        }
        status = .launching
        do {
            // Must complete before PGR.exe starts: it picks its render resolution from Wine here.
            await applyBottleSettings()
            let env = game.launchEnvironment(
                config: config, prefix: bottleDir, runtime: runtime, logDir: logsDir)
            let process = try await game.launchGame(
                installation: install, runtime: runtime, prefix: bottleDir, env: env)
            gameProcess = process
            isGameRunning = true
            status = .running
            startKeyMappingIfNeeded()
            process.terminationHandler = { [weak self] _ in
                Task { @MainActor in
                    self?.onGameTerminated()
                }
            }
            logger.info("游戏已启动，PID \(process.processIdentifier)")
        } catch {
            fail(error)
        }
    }

    private func onGameTerminated() {
        isGameRunning = false
        gameProcess = nil
        keyMapper.stop()
        if !status.isBusy { status = .ready }
        logger.info("游戏进程已退出")
    }

    func terminateGame() {
        if let p = gameProcess, p.isRunning {
            p.terminate()
            logger.warn("已请求终止游戏进程")
        }
        Task { await runtime.killServer(env: game.launchEnvironment(
            config: config, prefix: bottleDir, runtime: runtime, logDir: logsDir)) }
    }

    private func refreshInstallation() {
        installation = game.detectInstallation(in: gameDirURL)
    }

    /// Re-scan the installation after the official launcher exits (it may have downloaded the game).
    func rescanInstallation() {
        refreshInstallation()
        if installation != nil, !status.isBusy, status != .running {
            status = .ready
        }
    }

    // MARK: Settings

    /// Apply per-bottle settings (Retina / left Cmd) **synchronously** before a launch.
    ///
    /// The game decides its render resolution from the resolution Wine reports at startup, so
    /// `RetinaMode` must already be in the bottle when PGR.exe starts (otherwise the game renders
    /// at the logical point size and macOS upscales it → blurry). Also flushes wineserver so the
    /// registry write is durable before the game process starts.
    func applyBottleSettings() async {
        guard runtimeInstalled else { return }
        do {
            try await runtime.setRetina(config.retina, prefix: bottleDir)
            try await runtime.setLeftCommandIsCtrl(config.leftCommandIsCtrl, prefix: bottleDir)
            await runtime.waitUntilServerExits(env: ["WINEPREFIX": bottleDir.path])
            logger.info("Wine 设置已应用：RetinaMode=\(config.retina ? "y" : "n")")
        } catch {
            logger.error("写入 Wine 设置失败：\(error.localizedDescription)")
        }
    }

    func setBackend(_ backend: RenderBackend) {
        config.backend = backend
        saveConfig()
    }

    func setRetina(_ enabled: Bool) {
        config.retina = enabled
        saveConfig()
        Task { await applyBottleSettings() }
    }

    func setMaxFPS(_ fps: Int) {
        config.maxFPS = fps
        saveConfig()
    }

    func setMetalHud(_ enabled: Bool) {
        config.metalHud = enabled
        saveConfig()
    }

    func setProxy(_ proxy: String) {
        config.proxy = proxy
        saveConfig()
    }

    func setLeftCommandIsCtrl(_ enabled: Bool) {
        config.leftCommandIsCtrl = enabled
        saveConfig()
        Task { await applyBottleSettings() }
    }

    func setGameDir(_ path: String) {
        config.gameDir = path
        saveConfig()
        rescanInstallation()
    }

    func setInstallerURL(_ url: String) {
        config.installerURL = url
        saveConfig()
    }

    func setChannel(_ channelID: String) {
        config.channelID = channelID
        saveConfig()
    }

    func chooseGameDir(_ url: URL) {
        setGameDir(url.path)
    }

    func openGameDir() {
        try? FileManager.default.createDirectory(at: gameDirURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(gameDirURL)
    }

    func openBottleDir() {
        try? FileManager.default.createDirectory(at: bottleDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(bottleDir)
    }

    // MARK: Key mapping

    func setKeyMappingEnabled(_ enabled: Bool) {
        config.keyMappingEnabled = enabled
        keyMapper.setMappings(config.keyMappings)
        if enabled {
            keyMapper.start()
        } else {
            keyMapper.stop()
        }
        saveConfig()
    }

    func addKeyMapping(_ mapping: KeyMapping) {
        config.keyMappings.append(mapping)
        keyMapper.setMappings(config.keyMappings)
        saveConfig()
    }

    func updateKeyMapping(_ mapping: KeyMapping) {
        if let idx = config.keyMappings.firstIndex(where: { $0.id == mapping.id }) {
            config.keyMappings[idx] = mapping
            keyMapper.setMappings(config.keyMappings)
            saveConfig()
        }
    }

    func removeKeyMapping(id: UUID) {
        config.keyMappings.removeAll { $0.id == id }
        keyMapper.setMappings(config.keyMappings)
        saveConfig()
    }

    func requestAccessibilityPermission() {
        keyMapper.requestAccessibilityPermission()
    }

    private func startKeyMappingIfNeeded() {
        guard config.keyMappingEnabled else { return }
        keyMapper.setMappings(config.keyMappings)
        keyMapper.start()
    }

    // MARK: Persistence

    func saveConfig() {
        do {
            try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: configURL, options: .atomic)
        } catch {
            logger.error("保存配置失败：\(error.localizedDescription)")
        }
    }

    private static func loadConfig(from url: URL) -> AppConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AppConfig.self, from: data)
    }

    // MARK: Errors

    private func fail(_ error: Error) {
        progress = nil
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        status = .failed(message)
        logger.error(message)
    }
}
