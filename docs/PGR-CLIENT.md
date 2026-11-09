# 战双帕弥什（Punishing: Gray Raven）Windows 客户端 · 下载/更新机制研究报告

> 面向 **macOS SwiftUI 启动器**（Yaagl 式：下载 Windows 客户端 → 校验/更新 → Wine 启动）的实现文档。
> 结论基于 2026-11-09 实测；所有 URL 均用 `curl` 验证过状态码/大小/哈希。
> 复现脚本与原始样本在 [`research/`](../research/)：`parse_pe.py`、`nsis_extract.py`、`decrypt_krapp_conf.py`、`fetch_channel.py`、`samples/channels.json` 等。

---

## 0. TL;DR（给实现者的 10 行结论）

1. **不要依赖官方启动器下载**。官方启动器是 200MB 级 NSIS 安装器 + .NET 8/WPF/WinForms/WebView2/DuiLib 应用，Wine 下能跑但很脆（WebView2 透明窗口、KRSDK 弹窗、无法脚本化），因此我们只把它当作「参数来源」。
2. 游戏本体走**纯 HTTP CDN 直连**：每个渠道有一个 **configUrl（index.json）**，返回带权重 CDN 列表 + 版本 + 清单路径；清单是纯 JSON，每文件带 `md5`/`size`，下载后 MD5 校验即可。
3. CDN 支持 **Range（206）**、`ETag`=文件 MD5（大写）、多备份节点，适合自研多线程/断点续传下载器。
4. **下载规则很简单**：清单里**每一条都能单文件直连**：`URL = CDN根 + default.config.baseUrl + percent-encode(dest)`，MD5 校验（实测 85k 条清单里抽小/中/大文件全部 200 且 md5 一致，含 <2 MiB 小文件）。官方的「首次安装」另用 `zipConfig` 分发成 5,000+ 独立文件 + 9 个 `N.krzip`（标准 ZIP，含 <2MiB 文件），可作为批量下载优化/404 兜底，但不是必需。
5. 首次安装 ≈ **68–69 GiB**（85k 级清单文件；若走官方 zipConfig 分发 = 59–60 GiB 独立文件 + 7.6–7.7 GiB krzip 包）；增量更新按本地 MD5 差集只下变化文件。
6. 三个渠道（全部已实测可用）：**国际服 G143/50015**、**国服官服 G148/10012**、**B服 G148/10011**；三者参数表见 §1。
7. 版本语义：`index.json.default.config.version` = 资源清单版本（当前 4.9.0）；CDN 上 `version.json` 内容 `{package_version:4.9.1}` = 客户端包版本（当前 4.9.1）。**判断更新用 version.json / 清单 md5，不要用 config.version 字面值**。
8. **反作弊**：国际服含 **腾讯 ACE（AntiCheatExpert）** 7 个文件/66.5MB（内核驱动）；**国服官服与 B 服清单里没有 ACE**。WineHQ Bug 57567 的 2026-10 结论：游戏本体可在最新 Wine 跑，ACE 新驱动需要 DriverInit 返回地址补丁；macOS ARM64 已有 `pgrpatcher` 实践。
9. 建议架构：`GameChannel`（静态渠道表，参数内嵌）→ `CDNService`（configUrl→index.json→indexFile 清单→单文件并发/Range 下载+MD5 校验）→ `PatchService`（本地 MD5 扫描/差集/deleteFiles）→ `WineLauncher`。krzip 解包只作为可选优化/兜底。启动器本体**不下载、不运行**。
10. 风险：configUrl 里的 `appKey`（token）来自安装器包内，**会随官方启动器版本轮换**；2026-11-09 的三个 token 均有效，需设计「失效→重新解包最新安装器/提示」的兜底。

---

## 1. 渠道总表（全部实测）

> 参数来自安装器内嵌 `Assets/KRApp.conf`（base64+XOR 0x63）解密，样本：
> `research/samples/installer_cn/KRApp.conf.decoded.json`、`research/samples/installer_bili/KRApp.conf.decoded.json`、
> `research/samples/KRApp.conf.decoded.json`（国际服，解包自 `/tmp/pclauncher.exe`）。
> 机器可读版：[`research/samples/channels.json`](../research/samples/channels.json)。

| 项目 | 国际服（Global / Steam 同源） | 国服官服 | B 服（Bilibili） |
|---|---|---|---|
| gameId | **G143** | **G148** | **G148** |
| appId | **50015** | **10012** | **10011** |
| appKey（token） | `LWdk9D2Ep9mpJmqBZZkcPBU2YNraEWBQ` | `RnIUKs3r59Csliu3N0rl5uRWWBOFDaJL` | `qYQv6TyyyhCKD3ox3gssyolNPwMoCPZt` |
| pkgId | A1728 | A1393 | A1508 |
| 启动器内渠道名 | KRInstall PGR Overseas | KRInstall PGR | KRInstall PGR（bilibili 包） |
| 游戏目录名 | `Punishing Gray Raven Game` | 同左 | 同左 |
| 游戏主程序 | `PGR.exe`（另起 `KRSDKExternal.exe` 登录进程） | 同左 | 同左 |
| configUrl | `https://prod-alicdn-gamestarter.kurogame.com/launcher/game/G143/50015_LWdk9D2Ep9mpJmqBZZkcPBU2YNraEWBQ/index.json` | `https://prod-cn-alicdn-gamestarter.kurogame.com/launcher/game/G148/10012_RnIUKs3r59Csliu3N0rl5uRWWBOFDaJL/index.json` | `https://prod-cn-alicdn-gamestarter.kurogame.com/launcher/game/G148/10011_qYQv6TyyyhCKD3ox3gssyolNPwMoCPZt/index.json` |
| 备用 configUrl | `https://prod-volcdn-gamestarter.kurogame.net/launcher/game/G143/50015_…/index.json` | `https://prod-volcdn-gamestarter.kurogame.xyz/launcher/game/G148/10012_…/index.json` | `https://prod-volcdn-gamestarter.kurogame.xyz/launcher/game/G148/10011_…/index.json` |
| 启动器自更新配置 | `https://prod-alicdn-gamestarter.kurogame.com/launcher/launcher/50015_LWdk9D2Ep9mpJmqBZZkcPBU2YNraEWBQ/G143/index.json` | `https://prod-cn-alicdn-gamestarter.kurogame.com/launcher/launcher/10012_RnIUK…/G148/index.json` | `https://prod-cn-alicdn-gamestarter.kurogame.com/launcher/launcher/10011_qYQv6…/G148/index.json` |
| CDN 列表（权重 P） | `zspms-volcdn-gamestarter.kurogame.net` P=0；`zspms-txcdn-gamestarter.kurogame.net` P=13416；`zspms-akcdn-gamestarter.pgr-game.com` P=2177 | `zspms-alicdn-gamestarter.kurogame.com` P=8714；`zspms-txcdn-gamestarter.kurogame.com` P=7031；`zspms-volcdn-gamestarter.kurogame.com` P=1677 | 同国服官服 |
| 当前 `config.version` | 4.9.0 | 4.9.0 | 4.9.0 |
| CDN `version.json` | `{package_version:4.9.1}`（24 B） | 同左（md5 相同） | 同左 |
| 逻辑清单 | `indexFile.json` 13,741,605 B，**85,263** 文件，**68,417,752,404 B** | 13,740,917 B，**85,254** 文件，**68,754,938,042 B** | 13,753,736 B，**85,325** 文件，**68,950,331,895 B** |
| 清单 md5 | `b823c24ef71fc4825416f3b103c02956` | `06b9f70449183a73bd87a4c06cf7d434` | `d891acbde36caca275f3d3bf57ee95b8` |
| 官方分发清单（loose+krzip，可选） | `zipConfig.indexFile` 15,820,324 B，md5 `8a987e589ab49d58fb6102e7dff73e1e`，unCompressSize 8,977,028,246 | 15,818,736 B，md5 `3169e0082b38ce97e66b2e095749b685`，8,996,591,514 | 15,833,695 B，md5 `de2b0f6e7ea9bb1986b26d3c34865b2d`，9,019,098,564 |
| 下载基址（loose） | `launcher/game/G143/50015/4.9.1/QQGkKrpYIBdJPKpXTzGsGHGwAMhTQTXE/zip/` | `launcher/game/G148/10012/4.9.1/oZAVZdjVyCofYySVooaLxbTABngpVFhu/zip/` | `launcher/game/G148/10011/4.9.1/kxNHYCUTCEtzQkNvtzpSizgEPZqlOQmn/zip/` |
| krzip 包基址（备选） | `launcher/game/G143/50015/4.9.0/QQGk.../resource/50015/4.9.0/4.9.0/resources/` | `launcher/game/G148/10012/4.9.0/oZAV.../resource/10012/4.9.0/4.9.0/resources/` | `launcher/game/G148/10011/4.9.0/kxNH.../resource/10011/4.9.0/4.9.0/resources/` |
| 可更新来源版本（patchConfig） | 2.17.0.0 起 15 个 | 3.2.0 起 21 个 | 3.6.0 起 13 个 |
| ACE 反作弊 | **有**（7 文件/66,455,188 B） | **无** | **无** |
| 安装器 URL | `https://zspms-volcdn-gamestarter.kurogame.net/install/pclauncher.exe` | `https://zspms-txcdn-media.kurogame.com/install/PGR_install_2.6.3.0.exe` | `https://pkg.biligame.com/games/zspmsPCb_bilibili_20260625_1233547d30fd8386f9a8cecf1a41d05171fbe27bf35562.exe` |
| 安装器大小 | 209,696,344 B | 210,016,024 B | 210,063,512 B |
| 安装器 md5 | `bb34c56146f113e7552faa672d35fcfc` | `36fbd20c48a5f255b54c78717dbc8874` | `5165e0536083523dfa46ec7f3a3daa68` |
| 安装器 sha256 | `3b2f122e16632eaf3cfc45ede384c3f676d00fc7a1dd1f3166f92170fc5f8ac1` | `520eccb190ef57fd036a50767f101d471ef0834c3a24025afc0eeeeb2d3e9f5f` | `34d3a66792f7b8a02f444c56928fc0c4295e8a123f4d23f8d7a680e9e26f9ba3` |
| 安装器内启动器版本 | 2.5.1.1（旧；会自更新到 2.6.3.0） | 2.6.3.0 | 2.6.3.0 |
| 启动器自更新 launcher.zip | 2.6.3.0，463,413,771 B，md5 `385a6cfec6b12c3a557d5ee28fa173a2` | 463,417,804 B，md5 `a0f3fd25ddae535c2bd2a2b1a5edac2d` | 463,452,625 B，md5 `0f3d2702215f18b3b08ffd31ff9902fa` |

补充：

- **安装器镜像**：国际服 `zspms-txcdn-gamestarter.kurogame.net/install/pclauncher.exe`、`zspms-akcdn-gamestarter.pgr-game.com/install/pclauncher.exe` 均 200、Content-Length/ETag 相同（`bb34c5…`）。国服官服镜像 `https://media-cdn-zspms.kurogame.com/install/PGR_install_2.6.3.0.exe`。
- **B 站下载必须带 Referer**：`pkg.biligame.com` 与 `pkgdl.biligame.net` 对无 Referer 请求返回 **403**；带 `Referer: https://www.biligame.com/detail?id=114996` 即 200（实测）。
- 国际服安装器 `pclauncher.exe` 的 Last-Modified 是 2026-03-09（较旧），但游戏 config 端点仍有效；游戏版本由 config 端点决定，与安装器新旧无关。
- 中国大陆网络建议优先 `zspms-alicdn/txcdn`；海外优先 `zspms-volcdn`/`akcdn`（国际服）。P=0 表示官方不做加权随机选择，但仍可直接访问（实测国际服 volcdn 即 200）。

---

## 2. 官方安装器结构（为什么不在 Wine 里用它下载）

### 2.1 文件格式（三渠道一致）

- 外壳：**NSIS 3.08**（PE32 GUI，`requireAdministrator`；`FileDescription="Punishing Gray Raven"`）。头块 raw DEFLATE（非 solid），数据块逐文件 DEFLATE。
- 内嵌 15 个文件（国际服，`research/nsis_extract.py` 可复跑）：

| 文件 | 大小 | 说明 |
|---|---|---|
| `KRNSISPlugin.dll` | 513,464（国际服）/ 533,192（国服、B服） | NSIS 自定义插件 |
| `DuiLib.dll` | 1,411,152 | 国产 DirectUI 库（安装器 UI） |
| `libcrypto-3.dll` / `libssl-3.dll` / `libcurl.dll` / `sqlite3.dll` / `zlibwapi.dll` | 共 ~7 MB | 启动器运行库 |
| `thinkingdata.dll` / `kurodata.dll` | 295 KB / 312 KB | 埋点 SDK（国际/国内不同） |
| `msvcp_win.dll` / `msvcp140.dll` / `ucrtbase.dll` / `vcruntime140.dll` | 共 ~2.2 MB | VC 运行库 |
| `KRRes.zip` | 22.6 MB | 安装器资源（DuiLib 布局 XML、语言、图片） |
| **`KRLauncher.zip`** | **182.6 MB** | **真正的启动器**：`launcher.exe`(引导) + `uninst.exe` + `2.x.x.x/`（.NET 8 自包含运行时 + 主程序） |

- `KRLauncher.zip/2.5.1.1/`（国际服，2026-02 构建）关键内容：`launcher_main.dll`(1 MB，主逻辑)、`launcher_updater.dll`、
  `launcher_main.exe`/`launcher_updater.exe`、`launcher_main.deps.json`/`.runtimeconfig.json`（net8.0 + Microsoft.WindowsDesktop.App 8.0.15）、
  `coreclr.dll`/`hostfxr.dll`…（自包含 .NET 8）、`PresentationFramework.dll`/`Microsoft.Web.WebView2.*`（WPF + WebView2）、
  `DuiLib`、`KRLauncher.SkinRes.dll`、`krfeapp.dat`（15 MB，**WebView2 前端 = 打包成 ZIP 的 Vue SPA**，含 launcher SDK API 域名）、
  `hpatchz.exe`（HDiffPatch 补丁执行器）、`KRShmq.dll`、`CrashSight64.dll`（腾讯 CrashSight 崩溃上报）、`KRSDK*`。
- 结论：**不是 Electron/CEF/Tauri，而是 .NET 8 + WPF/WinForms + WebView2（Blink）+ DuiLib**；游戏下载/更新逻辑在 `launcher_main.dll`（字符串可见 `version.txt`、`cdnConfig.json`、`launcherDownloadConfig.json`、`KRCDNDownloadTask`、`StartCDNSelectDownload`、`hpatchz arguments:` 等）。

### 2.2 安装行为

- 安装到 `%ProgramFiles%\Punishing Gray Raven\`（B 服为 `Punishing Gray Raven bilibili`；注册表 `KRInstall PGR`/`KRInstall PGR Overseas`）。
- 释放 `launcher.exe` 引导器 + `KRLauncher.zip` 解出的版本目录 + `KRRes.zip` 资源；注册表写入 `KRLauncher_G143_50015` 等自启/单实例键。
- 首次运行启动器后：拉 `launcherConfigUrl` 自更新到 2.6.3.0（launcher.zip 463 MB），再拉游戏 `configUrl` 下载游戏（本报告 §3 的协议）。

### 2.3 为什么启动器不进入我们的实现

- 体积/复杂度：200 MB 安装器 + 463 MB 自更新 + 每渠道一套；Wine 里还要 WebView2 Runtime（`KRWebViewRuntime.zip` 249.5 MB，WebView2 133.0.3065.59）。
- Wine 现实问题（见 §6）：启动器窗口在 Wine 下会透明/白屏（WineHQ Bug 60420），KRSDKExternal 弹窗、登录 WebView 依赖 CEF/WebView2。
- 无法脚本化/无进度接口；且它只是「又一个下载器」，我们已有全量 HTTP 协议。
- **唯一值得复用的是它的「参数」**：`Assets/KRApp.conf`（解密后即 §1 的渠道表）。若 token 轮换，用 `nsis_extract.py` + `decrypt_krapp_conf.py` 从最新安装器重新取即可（可自动化）。

---

## 3. 直连下载/更新协议（主方案）

### 3.1 三层数据结构

```
configUrl (index.json, 每渠道固定)
   ├─ default.cdnList[]        : CDN 根 URL + 权重 P
   ├─ default.version          : 资源清单版本（4.9.0）
   ├─ default.config
   │    ├─ version             : 4.9.0
   │    ├─ size                : 逻辑全量大小（68.4~69.0 GB）
   │    ├─ indexFile           : 逻辑清单路径（13.7 MB JSON，85k 文件）★校验基准
   │    ├─ indexFileMd5        : 逻辑清单 md5
   │    ├─ baseUrl             : loose 文件下载目录（.../4.9.1/<key>/zip/）
   │    ├─ patchType           : "patch"
   │    ├─ patchConfig[]       : 每个历史版本的「更新清单」（见 3.5）
   │    └─ zipConfig           : 官方首次安装分发清单（可选优化：9 个 krzip + 5k loose）
   │         ├─ indexFile      : .../4.9.0/<key>/resource/<appId>/4.9.0/4.9.0/indexFile.json（15.8 MB）
   │         ├─ indexFileMd5
   │         ├─ baseUrl        : krzip 包目录（.../4.9.0/<key>/resource/<appId>/4.9.0/4.9.0/resources/，备选）
   │         └─ version         : 4.9.0
   ├─ default.resources        : ".../4.9.1/<key>/resource.json"（同逻辑清单的镜像，可作修复清单）
   └─ default.resourcesBasePath: ".../4.9.1/<key>/zip"
```

实测（2026-11-09）：

```
GET https://prod-alicdn-gamestarter.kurogame.com/launcher/game/G143/50015_LWdk9D2Ep9mpJmqBZZkcPBU2YNraEWBQ/index.json
→ 200, application/json, gzip(压缩后 1,449 B / 解压 7,678 B), last-modified 2026-11-04
```

> ⚠️ alicdn 上 `index.json` 是 **gzip 响应**：请求需 `Accept-Encoding: gzip` 并处理 `Content-Encoding`（curl 用 `--compressed`）。

### 3.2 CDN 选择

- `default.cdnList[]` 每项 `{url, P, K1, K2}`；`P` 是权重（0=不参与）。
- 官方启动器先做 CDN 测速（`downloadCdnSelectTestDuration`），再按加权选择；我们实现可直接按 P 加权随机 + 失败切换（3 个节点）。
- 每个 CDN 根都能提供全部对象；`P=0` 的节点也可直接用。
- 国际服三节点：`zspms-volcdn…kurogame.net` / `zspms-txcdn…kurogame.net` / `zspms-akcdn…pgr-game.com`；
  国服/B服三节点：`zspms-alicdn…kurogame.com` / `zspms-txcdn…kurogame.com` / `zspms-volcdn…kurogame.com`。

### 3.3 `indexFile.json`（逻辑全量清单）格式

```json
{
  "resource": [
    { "dest": "baselib.dll", "md5": "c62544e30864c18a65451dce2ea80e07", "size": 419096 },
    { "dest": "PGR.exe",     "md5": "36449a8371e4064f78d86c0c851fdda5", "size": 459192 },
    { "dest": "PGR_Data/StreamingAssets/resource/matrix/…uab", "md5": "…", "size": 2097438 }
  ]
}
```

- 当前 85k 条，合计 68.4–69.0 GB；`dest` 是相对安装根的 Windows 路径（`/` 分隔），`md5`/`size` 是**最终落地文件**的哈希/大小。
- 下载 `indexFile` 后先校验 `indexFileMd5`（= 响应 `ETag`，大小写不敏感；实测三者全部一致）。
- 国际服 root 文件：`PGR.exe`(459,192) / `PGRBase.dll`(34,361,168) / `baselib.dll`(419,096) / `UnityPlayer.dll`(31,039,256) / `GameAssembly.dll`(174,752,776) / `version.json`(24)；
  国服/B服：`PGR.exe`(322,248) / `PGRBase.dll`(28,207,512) / `GameAssembly.dll`(174,292,248) / 其余相同。
- 游戏为 **Unity IL2CPP**（资产在 `PGR_Data/`），不是 UE。

### 3.4 ⭐ URL 规则：单文件直连（主）+ krzip 分发（备选）

**主规则（实测全量可用）**：逻辑清单里的**每一条**都可以作为独立对象直连下载：

```
文件 URL = <CDN 根> + <default.config.baseUrl> + percent-encode(<dest>, 保留 '/')
```

- `config.baseUrl` 形如 `launcher/game/G148/10012/4.9.1/oZAV…/zip/`（**注意是 `config.baseUrl`，不是 `zipConfig.baseUrl`**，后者是 krzip 包目录）。
- 实测证据（2026-11-09）：国服/国际服各随机抽 **30 条 <2 MiB 小文件** 全部 `HEAD 200`；再各下载 3 条小文件，MD5 与清单 **全部一致**；此前 Lead 的 20 文件随机下载 + 25 条 HEAD 同样全 200。`PGR.exe`/`version.json`/2 MB 级 `.uab`/大 `.usm` 均 200。CDN 支持 Range 206、`ETag`=MD5。
- 因此 **CDN 下载器只需要一份 `config.indexFile`（13.7 MB）+ `config.baseUrl` 就能装/修/更全量文件**，不需要解析 krzip。

**官方实际分发方式（了解即可，可作为优化/兜底）**：`default.config.zipConfig.indexFile`（15.8 MB）描述的是官方启动器「首次安装」的打包分发：

| 类别 | 数量 | 字节 | 说明 |
|---|---|---|---|
| loose 独立文件（≥2 MiB） | 5,008 | 59.76 GB | 条目带 `fromFolder` → `CDN + fromFolder + dest` |
| krzip 包（9 个 ZIP，含 <2 MiB 文件） | 9 包 / 包内 80,246 文件 | 7.64 GB（包体） | `CDN + zipConfig.baseUrl + "N.krzip"`，解压得到包内文件 |

- 分布规律：loose 最小 2,097,438 B、krzip 成员最大 2,096,933 B → 官方按 **2 MiB** 阈值打包；`loose ∪ zipInfos 成员 = 逻辑清单`（三渠道 100% 覆盖、无重叠）。
- krzip 实测是**标准 ZIP**（`PK\x03\x04`），包内路径即 `dest`，可用 unzip/libarchive 解；`zipInfos[].entries[]` 给出包内每个文件的 `dest/md5/size`。
- `chunkInfos`（仅 krzip 条目）：按 **100 MiB 分片**（`end-start+1`，最后一片例外）给每片 md5 → 可做**分片断点续传 + 分片校验**（`chunkDownloadSwitch=0` 表示当前端未启用，但协议在）。
- **建议**：主流程按单文件直连（实现简单、进度细、可并发/断点）；若某条 `dest` 直连返回 404（理论上不应发生，防 CDN 边缘/热更过渡期异常），再用 `zipInfos` 反查所属 krzip 整包下载解压兜底，而不是无限重试。
- `zipConfig.indexFile` 结构示例：

```json
{
  "resource": [
    { "dest": "PGR_Data/…/9300802a5c8c0d1f.uab", "md5": "…", "size": 2097438,
      "fromFolder": "launcher/game/G148/10012/4.9.1/oZAV…/zip/" },
    { "dest": "5.krzip", "md5": "…", "size": 975221429,
      "chunkInfos": [ {"start":0,"end":104857599,"md5":"…"}, … ] }
  ],
  "zipInfos": [
    { "dest": "0.krzip", "entries": [ {"dest":"PGR_Data/…/x.uab","md5":"…","size":6305}, … ] }
  ],
  "deleteFiles": []
}
```

### 3.5 版本语义与更新算法

**版本语义（实测）**

| 字段 | 值 | 含义 |
|---|---|---|
| `index.json.default.config.version` | `4.9.0` | 资源清单/资源代版本（决定清单路径） |
| `index.json.default.version` | `4.9.0` | 同上 |
| `baseUrl` 路径段 | `…/4.9.1/…/zip/` | 文件所在目录（hotfix 代，含最新文件内容） |
| CDN `…/zip/version.json` | `{"package_version":4.9.1}`（24 B，md5 `ab37f420e29ce99f7c92ce578b292658`） | **客户端包版本**（真正给玩家看的版本号） |
| 本地安装根 `version.json` | 同上 | 启动器用它判断「是否已是最新」 |
| `launcherDownloadConfig.json`（本地） | 启动器生成 | 下载簿记（非必须） |

**结论**：`config.version` 用于定位清单，**不要**拿它和玩家版本比较；更新判定用 CDN `version.json.package_version` 与本地 `version.json`。二者不一致时按清单做 MD5 差量同步（更稳），或直接按 `patchConfig[本地版本]` 清单同步。

**首次安装（单文件直连为主）**

1. `GET configUrl` → 解析 `default`；按 `cdnList` 加权选一个 CDN 根（失败换下一个）。
2. `GET version.json`（记下 `package_version`）。
3. `GET config.indexFile`（13.7 MB）→ 校验 `indexFileMd5`（= 响应 ETag），得到 85k 条 `{dest, md5, size}`。
4. 8–16 并发按 `URL = CDN + config.baseUrl + percent-encode(dest)` 下载全部文件到 `安装根/dest`（大文件 Range 断点、临时文件 + 原子 rename、逐文件 MD5）。
5. 逐文件 MD5 校验最终树（可与下载边下边校验；保留 `(size,mtime,md5)` 缓存供更新复用）。
6. 写入 `version.json`（来自 CDN），结束。
7. *可选优化*：先下 `zipConfig.indexFile` 的 9 个 krzip（共 ~9 GB，能覆盖 8 万个小文件，减少请求数）解压，再对剩余 loose/差异文件单文件下载；krzip 内文件按 `zipInfos` 校验。

**增量更新（已安装 → 新版本）**

1. `GET configUrl` → 取 `default.version`/`config.indexFileMd5`；`GET version.json`。
2. 若本地 `version.json.package_version` == 远端 → 无更新（可选做抽样修复）。
3. 否则：`GET config.indexFile`（校验 md5）得到目标树；本地已有文件按 `(size, mtime, md5缓存)` 快速比对：
   - 缺失/哈希不符 → 从 `CDN + config.baseUrl + dest` 单文件下载该文件（含 <2 MiB 小文件，实测可直连）；
   - 目标树里不存在的本地文件 → 删除（优先用对应 `patchConfig[源版本].deleteFiles`；否则按清单差集）
   - （可选优化）若一次变更涉及大量小文件，可用 `zipConfig` 的 9 个 krzip 整包下载替代逐文件下载；404 兜底同理。
4. 二次全量/抽样 MD5 校验 → 原子写 `version.json`。
5. 说明：PGR 的 `patchConfig` 清单实际内容 = **目标树的完整文件列表**（含 `deleteFiles` 删除清单），不是二进制 diff；
   `patchType:"patch"` 只是表示「支持按清单增量」，**不需要实现 KrDiff/HDiffPatch 引擎**（官方 `hpatchz.exe` 仅在有 diff 条目时用，本例清单里没有 krpdiff 条目）。
   实测：CN `patchConfig[4.8.0]` 清单 5,004 条（官方分发视角 = 4,995 loose + 9 krzip 包，`deleteFiles` 46,695 条）；从「单文件直连」视角直接按 `config.indexFile` 的 85k 条差异即可，无需读 patchConfig。

**HTTP 细节（实测）**

- 所有对象 `Accept-Ranges: bytes`；Range 请求返回 **206 + Content-Range**（例：`bytes 0-99/322248`）。
- 对象 `ETag` = **文件 MD5（大写）**；`index.json` 的 ETag 即 `indexFileMd5`；部分对象是分片 ETag（`"…-82"` 形式，如安装器）。
- 建议：`If-Range: <ETag>` 做断点续传；并发 8~16 连接；单连接读超时 30 s、重试 4 次、跨 CDN 切换。
- 文件名含中文/特殊字符时按 URL path 规则 percent-encode（清单里的 `dest` 以 `/` 分隔，逐段编码）。
- 服务端：阿里云 OSS + Tengine/Byte-nginx；404 时返回 `<Error><Code>NoSuchKey</Code>…`（正常不应出现；若出现先重试 1 次，再按 `zipInfos` 用 krzip 兜底）。

---

## 4. 安装后目录结构（目标树）

```
Punishing Gray Raven/            ← 安装根（Wine: <prefix>/drive_c/Punishing Gray Raven）
├─ PGR.exe                       ← 459,192 B（国际服）/ 322,248 B（国服·B服）Unity 启动壳
├─ PGRBase.dll                   ← 34,361,168 / 28,207,512  B（含 ACE 引导逻辑；Wine 侧需 patch）
├─ GameAssembly.dll              ← 174,752,776 / 174,292,248 B（IL2CPP）
├─ UnityPlayer.dll               ← 31,039,256 B
├─ baselib.dll                   ← 419,096 B（三渠道相同）
├─ version.json                  ← {package_version:4.9.1}\n
├─ AntiCheatExpert/              ← 仅国际服（7 文件，66.5 MB）
│   ├─ ACE-Base.dat / ACE-Base64.dll / ACE-BASE.sys
│   └─ ACE-CORE.sys / ACE-CORE.sys2 / ACE-Setup64.exe / ACE-Service64.exe
├─ PGR_Data/                     ← 85k 文件主体（StreamingAssets 84.8k 个）
│   ├─ StreamingAssets/resource/{matrix,…}  ← .uab/.usm/.awb/.acb 等
│   ├─ Plugins/                  ← KRSDKExternal.exe、CrashSight64.dll、KRSDK、mfc140u、libcurl…
│   ├─ Plugins/KRSDKRes/KRSDKWebView/  ← 内嵌 Chromium(CEF) 登录窗口（libcef.dll 等）
│   ├─ il2cpp_data/、Managed/、Resources/…
├─ (B服额外) PGR_Data/Plugins/KRSDKRes/Bilibili/BLPlatform64/**  ← B 站 SDK（71 个文件）
└─ (启动器安装时) launcher.exe、KRRes/、2.6.3.0/…（我们的实现不安装这些）
```

渠道文件差异（CN 官服 vs B 服，清单 diff 实测）：

- B 服多 **71** 个文件（全部在 `KRSDKRes/Bilibili/BLPlatform64/**`，B 站登录 SDK/CEF 资源）；
- **18** 个同路径文件内容不同，全部是渠道 SDK 层：`KRSDKEx.dll`、`KRSDKExternal.exe`、`kurodata.dll`、`KRSDKConfig.json`、`KRShmq.dll`、`KRSDKWebView*` 的 `KRWebView.exe/libcef.dll/libGLESv2.dll/vulkan-1.dll/…`；
- 游戏资源/主程序一致（`PGR.exe`、`PGRBase.dll`、`UnityPlayer.dll`、`version.json` md5 相同；`GameAssembly.dll` 同 md5？实测 CN 官服 `a02a0456…`、B 服 `a02a0456…` 相同）。
- 国际服与国服差异更大：`PGR.exe`/`PGRBase.dll`/`GameAssembly.dll` 不同（渠道 SDK 与 ACE 集成不同），资源清单条数 85,263 vs 85,254。

---

## 5. 反作弊（ACE）与 Wine 兼容性

### 5.1 国际服 ACE 文件（清单实测）

| 文件 | 大小 | PE 版本信息 |
|---|---|---|
| `AntiCheatExpert/ACE-Base.dat` | 66,340 | 加密数据 |
| `AntiCheatExpert/ACE-Base64.dll` | 52,605,152 | ACE Client Tray，FileVersion `1.0.2505.16428`，CompanyName `ANTICHEATEXPERT.COM` |
| `AntiCheatExpert/ACE-BASE.sys` | 4,283,040 | ACE-BASE64 System Driver，`20.3.2505.16464` |
| `AntiCheatExpert/ACE-CORE.sys` | 2,841,776 | ACE-CORE32 System Driver，`20.4.2506.496` |
| `AntiCheatExpert/ACE-CORE.sys2` | 2,498,720 | ACE-CORE32 System Driver，`20.4.2506.496` |
| `AntiCheatExpert/ACE-Setup64.exe` | 898,896 | ACE-Setup exe，`20.4.2505.214` |
| `AntiCheatExpert/ACE-Service64.exe` | 3,261,264 | ACE-Service exe，`20.4.2505.173` |

合计 **66,455,188 B**。国服官服/B 服清单里 **没有** `AntiCheatExpert/`（无内核驱动）；两者只有 `CrashSight64.dll`（5.58 MB 崩溃上报）与 KRSDK。

### 5.2 WineHQ Bug 57567（Punishing gray raven fails to launch）

- 状态 NEW，起始 2024-12-19（Wine 10.0-rc2），URL 字段 `https://pgr.kurogame.net/`（国际服）。
- 2026-10-04 的结论（comment 8，mkrsym1）：*"This game should work on current upstream Wine even if they added a driver (like most ACE games do right now). However if they added the latest driver version, it includes a check against userspace kernel emulators (KACE)… needs a workaround to set the high bits of the DriverEntry return address."*
  对应补丁：dawn-winery `wine-dwproton` commit **f6578ff9e7caaa56ee0eecec11def15b54c4f66a**
  `ntoskrnl: Call DriverInit with bits 48-64 of return address set`（`call_driver_init` 里 `orq 0xFFFF800000000000,(%rsp)`；并在 `instr.c` 的 vectored handler 处理 kernelmode rip）。
- comment 11（2026-10-04）：*"the game itself works perfectly fine on latest Wine"*，挂的只是 **启动器** 的 WebView2 透明窗口问题（WineHQ Bug 60420，与鸣潮启动器同因）。
- 结论：**游戏本体（PGR.exe + ACE 驱动加载）在最新 Wine 可运行**；需要「DriverInit 返回地址高位」补丁（dwproton/CrossOver 类运行时已带，或自行打）。

### 5.3 macOS ARM64 实践：`reiserFSs/pgrpatcher`（2026）

- 把官方安装版/Steam 版装进 Sikarugir（CrossOver/Wine 前端）后，运行 `pgr_apply_patches.py`：
  - `PGRBase.dll`：① 修 **Rosetta-hostile NOP**（Apple Silicon Rosetta 转译下会崩的 NOP 指令签名）；② 安装 **Unity startup stub**（按 PE 导出表解析 `UnityMain` RVA，跳到 Unity 启动，**绕过 ACE bootstrap/下载路径**）。
  - `GameAssembly.dll`：修 Rosetta-hostile NOP。
  - `PGR.exe` 不改。
- README「Current Wine 11 Notes」：推荐 CrossOver Wine 11 runtime（d3dmetal、`WINEDLLOVERRIDES="d3d11,dxgi=n,b"`、`WINEDLLPATH=…/lib/dxmt`），接近原生启动、无 KRSDK 窗口；Wine 10 下会有空白 `KRSDKExternal.exe` 窗口（不能关闭/移出屏幕，否则主进程冻结）。
- **依赖**：必须给 Wine 装 **GStreamer**，否则 CriWare 视频播放会让客户端崩溃；性能 M4 Pro 下 80–120 fps（DXVK），D3DMetal 更快。
- 另有 Lutris 脚本（punishing-gray-raven-standard）：`pclauncher.exe` + `winetricks vcrun2019 corefonts`，装完**不要点 Start**，直接关窗口（说明官方启动器能在 Wine 跑通安装，但启动不稳）。
- `Vedaru/kuro`（Linux 原生安装/更新器）结论：*"PGR ships ACE (AntiCheatExpert). Its kernel drivers can't load under Proton; most ACE games run fine with it absent, some refuse — no clean workaround."* —— 与 Bug 57567 相互印证：ACE 驱动是主要阻碍，绕过/缺失时本体多能跑。
- **Steam Deck / Proton**：PGR 的 Steam 版（appid 4125930）在 ProtonDB 为 **gold**（32 份报告，最好 platinum，近期 trending platinum）；但 Linux 侧的共识是「官方启动器在 Wine/Proton 下不可用、ACE 内核驱动无法加载」——可行路径是「原生下载器 + Wine/Proton 直接跑 `PGR.exe` + 需要时 ACE patch」，而不是在 Proton 里跑官方启动器。

### 5.4 对我们 macOS 启动器的含义

- **国服官服 / B 服无 ACE** → 理论上 Wine 侧阻力更小（但 KRSDKExternal/KRSDKWebView(CEF) 登录仍依赖 Wine 的 WebView/CEF 能力，需 wine-runtime 队友实测）。
- **国际服**需 ACE 绕过：要么用带 dwproton 补丁的 Wine 运行时（DriverInit 高位补丁），要么对 `PGRBase.dll` 做 `pgrpatcher` 同款 patch（我们的启动器可以在「下载完成/每次更新后」自动应用）——注意每次游戏更新二进制变了要重打（脚本按字节签名，更新后可能失配，需要容错）。
- 强烈建议：**默认渠道用国服官服**（无 ACE、下载快），国际服作为可选渠道并标注需要 ACE patch/Wine 运行时支持。
- 风险提示：绕过反作弊可能违反 ToS，存在封号风险；启动器侧应提示用户，并保留「不 patch、仅用支持补丁的 Wine 运行时」的选项。

---

## 6. 给 SwiftUI 启动器实现的明确建议

### 6.1 数据模型（`GameChannel`）

```swift
struct GameChannel {
    let id: String                  // "global" / "cn" / "bilibili"
    let gameId: String              // G143 / G148
    let appId: String               // 50015 / 10012 / 10011
    let configUrl: URL
    let backupConfigUrl: URL
    let launcherConfigUrl: URL
    let launcherBackupConfigUrl: URL
    let cdnList: [CDNNode]          // url + weight
    let gameDirName: String         // "Punishing Gray Raven Game"
    let gameExe: String             // "PGR.exe"
    let requiresACEPatch: Bool      // global=true
    let tokenRefreshHint: String    // 失效时如何更新参数
}
```

三渠道参数直接用 §1 表（`research/samples/channels.json` 可转成 Swift 字面量）。

### 6.2 服务拆分

1. **ConfigService**：拉 `configUrl`（先主后备，gzip）→ 解析 cdnList/version/config/zipConfig；选 CDN（按 P 加权 + 健康检查/失败切换）。
2. **ManifestService**：拉 `config.indexFile` + `config.zipConfig.indexFile`，md5 校验；构建：
   `expectedTree: [path: (size, md5)]`（来自 `config.indexFile`）；可选再建 `krzipSource: [path: bundle]`（来自 `zipConfig.zipInfos`）用于兜底/优化。
3. **DownloadService**：URLSession（`URLSessionConfiguration.httpMaximumConnectionsPerHost` 8–16）；对每个 `dest` 带 `Range`+`If-Range` 断点、临时文件 + 原子 rename、逐文件 md5；单文件最大约 490 MiB。可选：krzip 包用 `chunkInfos` 100 MiB 分片并行、逐片 md5 后拼接（仅当采用「整包」优化或 404 兜底时）。
4. **UnpackService（可选）**：krzip = ZIP（`Archive`/libarchive/`unzip`）；解压到临时目录，按 `zipInfos` 的 md5 校验，再原子替换到目标树。主流程（单文件直连）不需要它。
5. **PatchService**：本地扫描（size+mtime 缓存 md5）→ 差集 → 下载/解压 → 删除 stale（`deleteFiles` 或目标树差集）→ version.json 原子写。
6. **WineLauncher**：`PGR.exe`（wine 路径 `drive_c/Punishing Gray Raven/PGR.exe`），注入 `WINEPREFIX`；国际服按需先跑 ACE patch helper；退出码/日志上报。

### 6.3 关键实现注意

- **一定先读 §3.4**：清单所有条目都能单文件直连（`config.baseUrl + dest`）；404 正常不应出现，出现时重试 1 次后按 `zipInfos` 走 krzip 兜底，不要无限重试。
- 用 `version.json` 判断更新；`config.version` 只用来定位清单。首次安装后比较 CDN `version.json` md5 与本地文件 md5（更直接）。
- 磁盘空间：首次安装 ~69 GiB（若用 krzip 优化，额外临时 ~9 GiB + 解压余量）→ 至少预留 85 GiB；UI 必须提前校验。
- 安装根建议 `~/Library/Application Support/<App>/prefix/drive_c/Punishing Gray Raven Game`（与渠道一致可复用官方路径）；Wine prefix 与游戏目录分离，便于「只换 game 目录不重装 prefix」。
- 更新时不要删除 `Client/Saved/**`（本地设置/资源通道）；只在清单差集内删除，且跳过 SDK 运行时生成的文件。
- token 轮换兜底：`configUrl` 返回 403/404 时，提示「渠道参数过期」，可现场解包最新安装器（我们已有脚本逻辑：NSIS 解 → KRLauncher.zip → Assets/KRApp.conf → base64+XOR 0x63）或回退 `backupConfigUrl`。注意该兜底需要下载 ~210MB 安装器，不宜每次启动都做。
- 断点/重试参数建议：连接超时 10 s、读空闲超时 30 s、单文件重试 4 次、CDN 切换 3 节点轮换、并发 8（PGR 单文件最大 ~490 MiB）。
- 日志：记录每个请求 URL/状态/ETag/Range/耗时（复现问题用），注意不要记录 token 全量。

### 6.4 与官方启动器的共存

- 同一机器若已有官方启动器安装（Lutris/Steam），可直接复用其目录（版本判定同一套）；我们的下载器不依赖它。
- 反之，我们的目录也可被官方启动器识别（`version.json` + 文件树完整即可「修复/更新」，注意官方会检查 `filechecklist.json`/`launcherDownloadConfig.json`，若缺失可能提示「修复游戏」，但不影响运行）。

---

## 7. 风险与限制

| 风险 | 说明 | 缓解 |
|---|---|---|
| token 轮换 | configUrl 中 `appKey` 随官方启动器更新变化；失效时所有请求 403/404 | 备用 URL、重新解包最新安装器、UI 提示；参数表可远程下发 |
| 渠道/版本变化 | 未来版本可能改清单结构/加字段（如 `chunkDownloadSwitch`、`RHIOptionSwitch` 已出现） | 解析要宽容（未知字段忽略）、按 `config.indexFileMd5` 严格校验 |
| krzip 格式（仅备选路径） | 官方分发包当前是标准 ZIP；若某天改成自定义容器需新解析 | 先探测 `PK\x03\x04`，否则回退：整包保存 + 报告不支持；主路径不依赖 krzip |
| ACE 绕过 | 违反 ToS/封号风险；patch 依赖二进制签名，更新后可能失配 | 默认国服渠道；国际服显式提示；patch 失败不阻止启动（交给运行时补丁） |
| 网络 | 国际服 CDN 对大陆网络可能慢（volcdn/akcdn 在海外）；国服 CDN 对海外慢 | 按渠道选节点 + 自动切换；支持用户自定义代理 |
| Steam 版本 | Steam 版（appid **4125930**）文件与官方启动器版同源（同一 G143 清单），但 Steam 有自己的 depot 分发；ProtonDB 评分 gold（32 报告，最好 platinum） | 不做 Steam depot 下载（需 Steam 客户端/登录）；仅提示用户 Steam 版可用 |
| 本机网络限制 | 本次环境访问 `store.steampowered.com`/`store.steampowered.com/api` 失败（code 000）、SteamDB 被 Cloudflare 403、google 不通 | Steam 区域信息未取得（见 §8 说明） |

---

## 8. Steam appid 4125930（区域信息，未完全取得）

- Steam 商店页存在：`Punishing: Gray Raven`，appid **4125930**；Lutris 的 PGR 条目也把 `steamid` 记为 4125930，但其安装脚本用的是官方 `pclauncher.exe`（说明 Steam 版与官方启动器版同源/同一客户端）。
- ProtonDB API 实测：`https://www.protondb.com/api/v1/reports/summaries/4125930.json` →
  `{"bestReportedTier":"platinum","confidence":"strong","score":0.68,"tier":"gold","total":32,"trendingTier":"platinum"}`（32 条报告）。
- **区域（region）信息未取得**：本机网络对 `store.steampowered.com/api/appdetails` 与商店页请求均超时（code 000），SteamDB 被 Cloudflare 403 拦截；steamcmd 亦不可用。若需要精确的解锁区域/价格表，需在可访问 Steam 的环境用官方 Web API（`ISteamApps/GetAppList`、`appdetails?cc=xx`）或 steamcmd 匿名查询补全。**这不影响下载/更新方案**（我们不依赖 Steam depot）。

---

## 9. 复现命令（可直接跑）

```sh
# 渠道配置（三选一：global/cn/bilibili）
python3 research/fetch_channel.py config cn
python3 research/fetch_channel.py launcher cn          # 启动器自更新信息
python3 research/fetch_channel.py manifest cn          # 13.7MB 逻辑清单 + md5 校验
python3 research/fetch_channel.py file cn version.json # 单文件下载 + md5 校验

# 解包官方安装器（任选渠道）
python3 research/nsis_extract.py /tmp/pclauncher.exe --out-dir /tmp/pgr_global
python3 research/decrypt_krapp_conf.py \
  /tmp/pgr_global/KRLauncher.zip  # 先 unzip，再指向 2.x.x.x/Assets/KRApp.conf

# 安装器 PE 分析
python3 research/parse_pe.py /tmp/pclauncher.exe --dump-strings
```

实测样例（curl，2026-11-09）：

```sh
# 国际服 config（gzip）
curl -s --compressed \
  'https://prod-alicdn-gamestarter.kurogame.com/launcher/game/G143/50015_LWdk9D2Ep9mpJmqBZZkcPBU2YNraEWBQ/index.json' | head -c 400
# → {"chunkDownloadSwitch":0,...,"cdnList":[{"P":0,...,"url":"https://zspms-volcdn-gamestarter.kurogame.net/"},...]}

# 国服单文件（200 + md5 校验）
curl -s -D- -o /tmp/PGR.exe \
  'https://zspms-alicdn-gamestarter.kurogame.com/launcher/game/G148/10012/4.9.1/oZAVZdjVyCofYySVooaLxbTABngpVFhu/zip/PGR.exe'
md5 /tmp/PGR.exe    # cbe8f8db0ded6d83f7accb5cbb7e22f9 = 清单一致

# Range（断点）
curl -s -r 0-99 -D- -o /dev/null \
  'https://zspms-alicdn-gamestarter.kurogame.com/launcher/game/G148/10012/4.9.1/oZAVZdjVyCofYySVooaLxbTABngpVFhu/zip/PGR.exe'
# → HTTP/1.1 206 Partial Content / Content-Range: bytes 0-99/322248

# krzip（官方分发包，标准 ZIP；仅备选/优化路径需要）
curl -s -r 0-3 \
  'https://zspms-alicdn-gamestarter.kurogame.com/launcher/game/G148/10012/4.9.0/oZAVZdjVyCofYySVooaLxbTABngpVFhu/resource/10012/4.9.0/4.9.0/resources/0.krzip' | xxd
# → 504b 0304 = "PK.."
```

---

## 10. 附录：样本与证据路径

| 内容 | 路径 |
|---|---|
| 三渠道参数（机器可读） | `research/samples/channels.json` |
| 国际服解密 KRApp.conf | 解包 `/tmp/pclauncher.exe` → `KRLauncher.zip/2.5.1.1/Assets/KRApp.conf`（`decrypt_krapp_conf.py`） |
| 国服官服解密 KRApp.conf | `research/samples/installer_cn/KRApp.conf.decoded.json` |
| B 服解密 KRApp.conf | `research/samples/installer_bili/KRApp.conf.decoded.json` |
| 三渠道 index.json | `research/samples/pgr_{global,cn,bili}_game_index.json` |
| 三渠道逻辑清单 indexFile | `research/samples/pgr_{global,cn,bili}_indexFile.json`（共 ~40 MB） |
| 启动器自更新配置 | `research/samples/launcher_{global,cn,bili}.json` |
| 国际服小文件实测样本 | `research/samples/game_probe/PGR.exe`、`version.json` |
| NSIS 解析证据 | `research/samples/pclauncher.nsis_header.bin`、`pclauncher.nsis_blocks.json` |
| 安装器资源（渠道配置/UI） | `research/samples/KRRes/`、`installer_cn/KRRes_cn/`、`installer_bili/KRRes_bili/` |
| 启动器 .NET 字符串（机制关键词） | `research/samples/launcher_main.utf16strings.txt` |
| 解析/解密/抓取脚本 | `research/parse_pe.py`、`nsis_extract.py`、`decrypt_krapp_conf.py`、`fetch_channel.py` |
| 复现说明 | `research/README.md` |

---

*报告生成时间：2026-11-09（Asia/Shanghai）。所有 URL/哈希均为当日实测；官方更新后请以 `fetch_channel.py` 重新核实。*
