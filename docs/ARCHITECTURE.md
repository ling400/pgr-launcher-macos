# PGR Launcher 架构说明

> 一个面向 macOS（Apple Silicon）的原生启动器：下载 / 更新 Windows 版《战双帕弥什》
> （Punishing: Gray Raven），在 Wine 容器中运行，并提供 Retina 与键盘映射等增强能力。
> 设计目标与交互对标 [Yaagl](https://github.com/yaagl/yet-another-anime-game-launcher) 的 HSR 启动器。

## 1. 总览

```
┌──────────────────────────────────────────────────────────────────────┐
│                        PGRLauncher.app (SwiftUI)                     │
│                                                                      │
│  UI 层  Sources/UI/**                                                │
│    ├─ 主界面（游戏卡片 / 主操作 / 进度 / 日志）                        │
│    ├─ 设置（渲染后端、Retina、帧率、代理、目录）                       │
│    └─ 键位映射（录入 / 开关 / Accessibility 权限）                     │
│                                                                      │
│  状态与编排  Sources/Core/AppState.swift（@MainActor ObservableObject）│
│                                                                      │
│  服务层  Sources/Services/**                                          │
│    ├─ RuntimeManager  Wine 运行时下载/校验/解压、DXMT 安装、prefix、注册表│
│    ├─ GameManager     官方安装器/启动器驱动、游戏识别、启动、env 组装     │
│    ├─ Downloader      URLSession 断点续传 + SHA-256                   │
│    ├─ KeyMapper       CGEventTap 键盘重映射 + 按键捕获                 │
│    └─ Logger          内存 + 文件日志                                 │
└──────────────────────────────────────────────────────────────────────┘
        │                                   │
        │ 进程启动                           │ 文件系统
        ▼                                   ▼
┌──────────────────────────┐      ┌─────────────────────────────────────┐
│ Wine 11 (Crossover-based)│      │ ~/Library/Application Support/      │
│   + DXMT (D3D11 → Metal) │      │   PGRLauncher/                      │
│   WINEPREFIX = Bottle/   │      │     Runtime/wine/   Wine 发行版      │
└──────────────────────────┘      │     Runtime/downloads/ 安装包/归档   │
        │                         │     Bottle/        WINEPREFIX       │
        ▼                         │     logs/          运行日志          │
┌──────────────────────────┐      │     config.json    用户配置          │
│ Windows 游戏              │      └─────────────────────────────────────┘
│ 官方启动器 launcher.exe   │                     │
│ 游戏主程序 PGR*.exe       │◄────────────────────┘
└──────────────────────────┘
```

## 2. 关键设计决策

### 2.1 为什么是原生 SwiftUI 而不是 Electron / Neutralino

Yaagl 使用 Neutralino.js（Web 前端 + 轻量壳）。本机没有 Node/包管理器环境，而 Xcode 27 / Swift 6.4
可直接用 `swiftc` 构建原生 App，零外部依赖、启动快、系统集成（NSOpenPanel、Accessibility、
CGEventTap、NSWorkspace）更自然。因此本项目采用 SwiftUI + 手写 `.app` 打包脚本
（`scripts/build.sh`），不引入任何第三方依赖。

### 2.2 Wine 运行时选择

复用 Yaagl 同款运行时（与 HSR 启动器一致的组合，已在同类机器验证）：

| 组件 | 来源 | 说明 |
|---|---|---|
| Wine | `yaagl/anime-game-wine` → `wine-crossover-11.0-1-signed`（456MB, sha256 `89fa7e90…a35`） | Crossover 11 内核 + macOS 驱动补丁，x86_64（Rosetta） |
| FineWine 模块 | `stoicswe/Endfield_FineWine` → v1.4.3 `endfield-wine-modules.tar.gz`（4.1MB, sha256 `d71b6127…`） | CrossOver 26.3 + DW-Proton ACE/Rosetta 修补模块，覆盖 ntoskrnl/kernel32/ntdll/winemac/wineserver 等，修复 Apple Silicon 下 PGRBase 崩溃 |
| DXMT | `3Shain/dxmt` → `v0.80-builtin`（18.6MB） | Metal 实现的 D3D11/D3D10 翻译层，安装进 wine `lib/wine/x86_64-windows` 与 prefix `system32` |

下载源在 GitHub 上（大陆网络常 <100KB/s），因此 `RuntimeManager` 内置镜像回退：
直连 → `https://gh-proxy.com/<url>` → `https://ghfast.top/<url>`，并做 SHA-256 校验。
（镜像列表可再扩展。）

### 2.3 游戏下载 / 更新方式（Yaagl 式 CDN 直连）

官方 Windows 客户端采用「NSIS 安装器 + .NET 8 WPF/WebView2 启动器」两层结构。实测该启动器依赖
WebView2 与 .NET 8 桌面运行时，在 Wine 下不可用（WineHQ Bug 60420），因此本项目 **不驱动官方启动器**，
而是直接对接官方 CDN 的版本清单协议（与 Yaagl 对 HSR 的做法同类）：

1. 拉取渠道配置 `index.json`（主 + 备用端点），得到 `cdnList`、`baseUrl`、`indexFile`、版本与总大小；
2. 下载全量清单 `indexFile.json`（国服约 13MB，85,000+ 条 `{dest, md5, size}`）；
3. 计划阶段：对比本地文件（存在性 / 大小 / MD5），得到缺失与变更文件列表；
4. 下载阶段：并发 8 路、单文件 Range 断点续传、失败切换 CDN 并退避重试、MD5 校验、临时文件原子落盘；
5. 更新阶段：重新拉取配置与清单，按 MD5 差异只下载变更文件（不做官方 hpatchz 差分；不删除旧文件）。

单文件 URL = `CDN 根 + baseUrl + percent-encode(dest)`；CDN 支持 Range(206)。实测随机抽样
20 个文件 + version.json 的 MD5 与清单完全一致，可安全用作校验依据。

> 官方渠道参数（gameId / appId / appKey / CDN 列表）见 `docs/PGR-CLIENT.md`；国服与国际服是
> 两套独立端点与账号体系。B 服（Bilibili）端点确认后可作为额外渠道加入。

### 2.4 Retina 模式

Wine 的 macOS 驱动通过注册表 `HKCU\Software\Wine\Mac Driver\RetinaMode` 控制 Retina 行为
（与 Yaagl 相同）。启动器在每次启动游戏前按用户设置写入 `y`/`n`，并等待 wineserver 退出使配置生效。
配合 DXMT 的 `d3d11.preferredMaxFrameRate`、Metal HUD 等 env 参数，在 Retina 屏上获得清晰渲染。

### 2.5 键盘映射

采用进程级方案：`KeyMapper` 用 `CGEventTap`（session tap）在游戏运行时拦截键盘事件，
按用户配置的 `sourceKeyCode → targetKeyCode` 改写后重新投递并吞掉原事件；未授权时通过
`AXIsProcessTrustedWithOptions` 引导用户到“辅助功能”授权。映射只在游戏启动期间启用，
退出游戏即停止，避免影响系统输入。UI 提供“按一下要映射的键 → 按一下目标键”的录入流程。

## 3. 目录结构

```
Sources/
  main.swift                  App 入口 + NSApplicationDelegate
  Models/CoreModels.swift     AppConfig / LauncherStatus / TaskProgress / KeyMapping …
  Core/AppState.swift         全局状态、业务编排、配置持久化
  Services/                   Wine / 下载 / 游戏 / 键位 / 日志
  UI/                         全部 SwiftUI 界面
Resources/Info.plist          应用元信息（bundle id: local.pgr.launcher）
Resources/AppIcon.icns        图标（scripts/make-icon.py 生成）
scripts/build.sh              swiftc 构建 + .app 打包 + ad-hoc 签名
scripts/run.sh                build + open
docs/                         架构 / 契约 / 客户端研究 / 运行时验证
research/                     客户端协议研究脚本与样本
```

## 4. 状态机（LauncherStatus）

```
checking ──► needsRuntime ──(installRuntime)──► preparingRuntime ──► needsGame
                  ▲                                                    │
                  │                                        (downloadAndInstallGame)
                  │                                                    ▼
                  │                                              downloading ─► installing
                  │                                                    │
                  │                                                    ▼
                  └──────────── ready ◄────────────(detect)────── 安装完成
                                    │
                    launchGame ──► launching ──► running ──(进程退出)──► ready
                                    │
                    updateGame ──► updating ──(官方启动器退出)──► ready/needsGame
```

## 5. 后续可扩展

- 直接 CDN 下载/更新（拿到版本 manifest 后）。
- D3DMetal（GPTK）后端与 D3D12 支持。
- 手柄映射（GameController → 键盘事件 / 虚拟手柄）。
- 多游戏支持（同一套 Wine 管理能力复用到 HSR / ZZZ / 鸣潮等）。
- 自动更新启动器自身、签名/公证。
