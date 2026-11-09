import Foundation

// MARK: - Render backend

enum RenderBackend: String, Codable, CaseIterable, Identifiable {
    case dxmt
    case d3dmetal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dxmt: return "DXMT (D3D11 → Metal)"
        case .d3dmetal: return "D3DMetal (GPTK)"
        }
    }

    var subtitle: String {
        switch self {
        case .dxmt: return "轻量、开源，推荐用于 D3D11 游戏"
        case .d3dmetal: return "苹果官方转译层，需要额外下载运行时"
        }
    }
}

// MARK: - Key mapping

struct KeyMapping: Codable, Identifiable, Equatable {
    var id: UUID
    /// macOS virtual key code (CGKeyCode) of the physical key.
    var sourceKeyCode: Int
    /// Human readable label, e.g. "A", "Space", "F1".
    var sourceLabel: String
    /// macOS virtual key code posted to the game.
    var targetKeyCode: Int
    var targetLabel: String
    var enabled: Bool

    init(
        id: UUID = UUID(),
        sourceKeyCode: Int,
        sourceLabel: String,
        targetKeyCode: Int,
        targetLabel: String,
        enabled: Bool = true
    ) {
        self.id = id
        self.sourceKeyCode = sourceKeyCode
        self.sourceLabel = sourceLabel
        self.targetKeyCode = targetKeyCode
        self.targetLabel = targetLabel
        self.enabled = enabled
    }
}

// MARK: - Channels & CDN progress

/// A game channel (region / publisher). Each channel has its own CDN config endpoint.
struct GameChannel: Codable, Equatable, Identifiable {
    var id: String
    var displayName: String
    var subtitle: String
    var configURL: String
    var backupConfigURL: String

    static let cn = GameChannel(
        id: "cn",
        displayName: "国服官服",
        subtitle: "战双帕弥什（库洛官服，G148）",
        configURL: "https://prod-cn-alicdn-gamestarter.kurogame.com/launcher/game/G148/10012_RnIUKs3r59Csliu3N0rl5uRWWBOFDaJL/index.json",
        backupConfigURL: "https://prod-volcdn-gamestarter.kurogame.xyz/launcher/game/G148/10012_RnIUKs3r59Csliu3N0rl5uRWWBOFDaJL/index.json"
    )

    static let bili = GameChannel(
        id: "bili",
        displayName: "国服 B 服",
        subtitle: "战双帕弥什（Bilibili 渠道，G148/10011）",
        configURL: "https://prod-cn-alicdn-gamestarter.kurogame.com/launcher/game/G148/10011_qYQv6TyyyhCKD3ox3gssyolNPwMoCPZt/index.json",
        backupConfigURL: "https://prod-volcdn-gamestarter.kurogame.xyz/launcher/game/G148/10011_qYQv6TyyyhCKD3ox3gssyolNPwMoCPZt/index.json"
    )

    static let global = GameChannel(
        id: "global",
        displayName: "国际服",
        subtitle: "Punishing: Gray Raven（OS，G143）",
        configURL: "https://prod-alicdn-gamestarter.kurogame.com/launcher/game/G143/50015_LWdk9D2Ep9mpJmqBZZkcPBU2YNraEWBQ/index.json",
        backupConfigURL: "https://prod-volcdn-gamestarter.kurogame.net/launcher/game/G143/50015_LWdk9D2Ep9mpJmqBZZkcPBU2YNraEWBQ/index.json"
    )

    /// Known channels.
    static var all: [GameChannel] { [cn, bili, global] }

    static func channel(id: String) -> GameChannel {
        all.first(where: { $0.id == id }) ?? global
    }
}

/// Detailed progress for a CDN download / update (files + bytes).
struct InstallProgress: Equatable {
    var phase: String = ""
    var currentFile: String = ""
    var filesDone: Int = 0
    var filesTotal: Int = 0
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var bytesPerSecond: Int64 = 0

    var fraction: Double? {
        bytesTotal > 0 ? min(1.0, Double(bytesDone) / Double(bytesTotal)) : nil
    }
}

// MARK: - Configuration

struct AppConfig: Codable, Equatable {
    /// Absolute path of the game installation directory (inside macOS FS).
    var gameDir: String
    /// Wine render backend.
    var backend: RenderBackend
    /// Wine mac driver Retina mode.
    var retina: Bool
    /// Preferred max frame rate passed to DXMT (0 = unlimited).
    var maxFPS: Int
    /// Show Metal HUD overlay (MTL_HUD_ENABLED=1).
    var metalHud: Bool
    /// Optional HTTP(S) proxy used by wine processes and downloads.
    var proxy: String
    /// Treat the left Command key as Ctrl inside the Wine bottle (useful for Cmd-based shortcuts).
    var leftCommandIsCtrl: Bool
    /// Keyboard remapping master switch.
    var keyMappingEnabled: Bool
    /// Keyboard remapping rules.
    var keyMappings: [KeyMapping]
    /// Custom CDN config URL override (empty = use the selected channel's default endpoint).
    var installerURL: String
    /// Selected game channel id (see GameChannel).
    var channelID: String
    /// Wine distribution id (see WineRuntime catalog); "auto" selects the recommended one.
    var wineDistroID: String

    /// Empty means "use the selected channel's official config endpoint".
    static let defaultInstallerURL = ""

    static func defaultGameDir() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Games/PGR")
    }

    static func `default`() -> AppConfig {
        AppConfig(
            gameDir: defaultGameDir(),
            backend: .dxmt,
            retina: true,
            maxFPS: 60,
            metalHud: false,
            proxy: "",
            leftCommandIsCtrl: true,
            keyMappingEnabled: false,
            keyMappings: [],
            installerURL: defaultInstallerURL,
            channelID: GameChannel.cn.id,
            wineDistroID: "auto"
        )
    }

    // Tolerant decoding so that new fields never break an old config file.
    init(
        gameDir: String,
        backend: RenderBackend,
        retina: Bool,
        maxFPS: Int,
        metalHud: Bool,
        proxy: String,
        leftCommandIsCtrl: Bool,
        keyMappingEnabled: Bool,
        keyMappings: [KeyMapping],
        installerURL: String,
        channelID: String,
        wineDistroID: String
    ) {
        self.gameDir = gameDir
        self.backend = backend
        self.retina = retina
        self.maxFPS = maxFPS
        self.metalHud = metalHud
        self.proxy = proxy
        self.leftCommandIsCtrl = leftCommandIsCtrl
        self.keyMappingEnabled = keyMappingEnabled
        self.keyMappings = keyMappings
        self.installerURL = installerURL
        self.channelID = channelID
        self.wineDistroID = wineDistroID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig.default()
        gameDir = (try? c.decode(String.self, forKey: .gameDir)) ?? d.gameDir
        backend = (try? c.decode(RenderBackend.self, forKey: .backend)) ?? d.backend
        retina = (try? c.decode(Bool.self, forKey: .retina)) ?? d.retina
        maxFPS = (try? c.decode(Int.self, forKey: .maxFPS)) ?? d.maxFPS
        metalHud = (try? c.decode(Bool.self, forKey: .metalHud)) ?? d.metalHud
        proxy = (try? c.decode(String.self, forKey: .proxy)) ?? d.proxy
        leftCommandIsCtrl = (try? c.decode(Bool.self, forKey: .leftCommandIsCtrl)) ?? d.leftCommandIsCtrl
        keyMappingEnabled = (try? c.decode(Bool.self, forKey: .keyMappingEnabled)) ?? d.keyMappingEnabled
        keyMappings = (try? c.decode([KeyMapping].self, forKey: .keyMappings)) ?? d.keyMappings
        installerURL = (try? c.decode(String.self, forKey: .installerURL)) ?? d.installerURL
        channelID = (try? c.decode(String.self, forKey: .channelID)) ?? d.channelID
        wineDistroID = (try? c.decode(String.self, forKey: .wineDistroID)) ?? d.wineDistroID
    }
}

// MARK: - Status & progress

enum LauncherStatus: Equatable {
    case checking
    case needsRuntime
    case preparingRuntime
    case needsGame
    case downloading
    case installing
    case updating
    case ready
    case launching
    case running
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .checking, .preparingRuntime, .downloading, .installing, .updating, .launching:
            return true
        default:
            return false
        }
    }

    var title: String {
        switch self {
        case .checking: return "检查环境…"
        case .needsRuntime: return "需要准备 Wine 环境"
        case .preparingRuntime: return "正在准备 Wine 环境"
        case .needsGame: return "尚未安装游戏"
        case .downloading: return "正在下载"
        case .installing: return "正在安装"
        case .updating: return "正在更新"
        case .ready: return "准备就绪"
        case .launching: return "正在启动"
        case .running: return "游戏运行中"
        case .failed(let message): return "出错：\(message)"
        }
    }
}

struct TaskProgress: Equatable {
    var title: String = ""
    var detail: String = ""
    /// 0...1, nil means indeterminate.
    var fraction: Double? = nil
    var bytesPerSecond: Int64? = nil

    static let indeterminate = TaskProgress()
}

enum LogLevel: String {
    case info
    case warn
    case error
}

struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let level: LogLevel
    let message: String
}

/// Result of scanning a game installation directory.
struct GameInstallation: Equatable {
    var rootDir: URL
    var launcherExe: URL?
    var gameExe: URL?
    var version: String?

    var isValid: Bool { gameExe != nil || launcherExe != nil }
}
