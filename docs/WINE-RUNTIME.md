# Wine 运行时方案与实测报告（macOS 27.3 / Apple M6 / arm64）

> 本文记录**本机实际验证过**的《战双帕弥什》(Punishing: Gray Raven, PC/Windows 版) Wine 运行时方案、
> 每一步的实测证据、崩溃分析、可复用脚本与踩坑记录。
>
> 实测时间：2026-11-09 ~ 2026-11-10（Asia/Shanghai）
> 实验机器：macOS 27.3（build 26C5035r）、Apple M6（arm64, T8152）、16GB 内存、358GB 空闲
> 相关脚本：`scripts/wine/`；实验日志与截图：`/tmp/wine-test/`

---

## 0. TL;DR（结论先行）

| 问题 | 结论 |
|---|---|
| Wine 能不能在本机跑？ | **能**。`wine-crossover-11.0-1-osx64-signed`（x86_64 Mach-O）经 Rosetta 2 在 macOS 27.3 上 `wine --version` → `wine-11.0`，`wineboot -u` / `wine cmd /c ver` / `wineserver -w` 全部通过 |
| 推荐运行时组合 | **wine 11.0-1 Crossover signed（yaagl 包） + FineWine 1.4.3 兼容模块 + DXMT 0.80 builtin**，三者缺一不可（详见 §2） |
| DXMT 能不能生效？ | **能**。安装后 PGR.exe 实际加载 `d3d11.dll` / `DXGI.DLL` / `winemetal.dll`（DXMT 版本），并在 `DXMT_LOG_PATH` 下生成 `PGR_d3d11.log` / `PGR_dxgi.log` |
| 国服客户端（无 ACE）能不能跑？ | **能，已完整跑通**。全量安装 85,254 个文件 / 68.75GB（引擎二次校验 27s 通过）后，`PGR.exe` 经 PGRBase → UnityPlayer → IL2CPP → **DXMT(D3D11)** 正常启动，实测进入 **KURO GAMES 登录界面**（手机号+验证码、二维码、账号登录，渲染正常）。截图：[game-login.png](screenshots/game-login.png)、[game-loading.png](screenshots/game-loading.png)、[game-font-fixed.png](screenshots/game-font-fixed.png)。详见 §5.4 |
| 国际服（有 ACE 反作弊）能不能跑？ | **不建议**。base wine 直接崩；加 FineWine 模块后 ACE 能加载、`ACE-Setup64.exe` 会弹 GUI，但 `PGR.exe` 仍以 `rc=222` 退出（ACE 内核驱动链未过）。风险高、投入大（详见 §5.5） |
| 官方 Windows 启动器能不能用？ | **安装器 GUI 能跑，但产品启动器不可用**。`pclauncher.exe`（NSIS，PE32 i386）在 Wine 下安装界面可正常渲染（截图 [launcher-installer.png](screenshots/launcher-installer.png)），但装出的启动器是 .NET 8 WPF + WebView2 —— Wine 下不可用（WineHQ bug 60420）。项目已改为 **CDN 直连下载 + 直接启动 PGR.exe**（详见 §5.6） |
| Retina | `HKCU\Software\Wine\Mac Driver\RetinaMode` = `y`/`n` 均已实测可写入并 `reg query` 回读；影响见 §7 |
| 中文乱码 | **必须在启动 env 设 `LANG=zh_CN.UTF-8` / `LC_ALL=zh_CN.UTF-8`**。否则 Wine 按 `C` locale 用 cp1252，游戏内隐私协议等 ANSI 文本乱码（实测对比见 §7.3） |

---

## 1. 实测环境

```
macOS 27.3 (build 26C5035r), Darwin 27.3.0
CPU: Apple M6 (arm64, T8152), 16 GB RAM, 358 GB free
Xcode 27.2 / swift 6.4.2 可用；Rosetta 2 已安装；PATH 无 brew/node/npm/wine
网络：github.com release assets 可达但单连接约 50KB/s（镜像 0.8–1.7MB/s）；kurogame CDN 可达；google 不可达
参考实现：Yaagl 源码 /tmp/yaagl-src（src/wine/distro.ts、src/wine/wine.ts、
        src/clients/mhy/patch.ts、src/clients/mhy/hkrpg/program-launch-game.ts）
本机已有可比对样本：/Applications/Yaagl HSR.app 使用的
        ~/Library/Application Support/Yaagl HSR/{wine,dxmt,wineprefix}
        （wine_tag = 11.0-1-crossover-signed-experimental，retina=true）
```

---

## 2. 推荐运行时（已逐字节校验）

| 组件 | 版本/文件 | 大小 | SHA-256 | 作用 |
|---|---|---|---|---|
| Wine | `wine-crossover-11.0-1-osx64-signed.tar.xz`（yaagl/anime-game-wine） | 456,021,524 B | `89fa7e90fb626523a90d5867a03c6be785d017176739c6320a3b86c7838c3a35` | x86_64 wine-11.0（Crossover 11.0-1 内核），经 Rosetta 2 运行 |
| FineWine 兼容模块 | `endfield-wine-modules.tar.gz`（stoicswe/Endfield_FineWine v1.4.3） | 4,278,321 B | `d71b61275e98a65cab95626f33baa842567c63f8483a6b963a4031de862da2e2` | CrossOver 26.3.0 模块 + DW-Proton ACE/Rosetta 补丁；**修 PGRBase 崩溃** |
| DXMT | `dxmt-v0.80-builtin.tar.gz`（3Shain/dxmt，builtin 版） | 18,681,669 B | `8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d`（本地计算，官方未发布） | D3D10/11 → Metal 渲染层（含 winemetal） |

下载地址：

```
https://github.com/yaagl/anime-game-wine/releases/download/wine-crossover-11.0-1-signed/wine-crossover-11.0-1-osx64-signed.tar.xz
https://github.com/stoicswe/Endfield_FineWine/releases/download/1.4.3/endfield-wine-modules.tar.gz
https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz
```

GitHub 镜像回退（本机实测 0.8–1.7MB/s，脚本已内置）：

```
https://gh-proxy.com/<原始 github url>
https://ghfast.top/<原始 github url>
```

> 注意：单连接直连 GitHub 只有 ~50KB/s，456MB 需要 2 小时以上。**分段并发下载**（10 段 Range 请求）
> 实测可到 ~1MB/s/段，3 分钟下完；`scripts/wine/lib-common.sh` 的 `download_verified` 已实现。

---

## 3. 快速开始（可复用脚本）

```bash
cd <repo>

# 1) 下载 + SHA-256 校验 + 解压 + 安装 DXMT/FineWine（约 480MB，已存在会复用/校验）
scripts/wine/install-runtime.sh

# 2) 创建 wine 容器（首次 20–60 秒）+ 同步 DXMT DLL 到 system32 + 默认开启 Retina
scripts/wine/create-bottle.sh

# 3) 一条命令体检
scripts/wine/verify.sh --run-smoke

# 4) 启动游戏（cwd 必须是游戏根目录；--monitor 每 5 秒截图）
scripts/wine/run-game.sh --game-dir "$HOME/Games/PGR" --monitor 30

# 可选：Retina 开关 / 还原补丁
scripts/wine/set-retina.sh --on          # 或 --off / --query
scripts/wine/finewine-patch.sh --restore # 还原 wine 原生模块
scripts/wine/dxmt-install.sh --restore   # 还原 wine 原生 d3d11/dxgi/d3d10core
```

默认目录（与 App 的 `RuntimeManager` 完全一致，均可用环境变量覆盖）：

```
~/Library/Application Support/PGRLauncher/Runtime/downloads   下载缓存
~/Library/Application Support/PGRLauncher/Runtime/wine        wine-11.0
~/Library/Application Support/PGRLauncher/Runtime/dxmt/       DXMT v0.80
~/Library/Application Support/PGRLauncher/Runtime/finewine/   FineWine 模块
~/Library/Application Support/PGRLauncher/Bottle              WINEPREFIX
~/Library/Application Support/PGRLauncher/logs                日志
```

脚本清单：

| 文件 | 职责 |
|---|---|
| `lib-common.sh` | 版本/SHA256 常量、镜像回退、分段并发下载、SHA 校验、备份复制 |
| `install-runtime.sh` | 下载+校验+解压 wine/DXMT/FineWine，调用后两者安装，写 `runtime-installed.txt` |
| `dxmt-install.sh` | DXMT → wine 树（覆盖 builtin，保留 `.bak`）+ prefix system32 |
| `finewine-patch.sh` | FineWine 模块覆盖（含 `SHA256SUMS` 校验、`chmod 755 wineserver`） |
| `create-bottle.sh` | 创建/复用 WINEPREFIX、win10、system32 DLL、`cmd /c ver` 校验 |
| `set-retina.sh` | RetinaMode / LeftCommandIsCtrl / DXMT NV 扩展注册表 |
| `run-game.sh` | 按 Yaagl 同款 env 启动 PGR.exe，日志/截图/监控 |
| `verify.sh` | 系统/Rosetta/wine/DXMT/FineWine/容器/Retina 全面体检 |

---

## 4. Wine 包校验、解压与兼容性（实测）

### 4.1 归档结构与二进制架构

```
wine-crossover-11.0-1-osx64-signed.tar.xz
└── wine/                       (归档根，解压即 Runtime/wine)
    ├── bin/wine                Mach-O 64-bit executable x86_64   ← 只有 x86_64，无 arm64 slice
    ├── bin/wineserver          Mach-O 64-bit executable x86_64
    ├── bin/wineboot            #!/bin/sh 包装脚本（exec wine wineboot "$@"）
    ├── lib/wine/i386-windows/  (605 个 .dll，32 位 Windows DLL)
    ├── lib/wine/x86_64-windows/(608 个 .dll，64 位 Windows DLL)
    ├── lib/wine/x86_64-unix/   (31 个 .so，unix 侧实现 e.g. ntdll.so/winemac.drv)
    └── share/wine/             wine.inf、nls、fonts、gecko、mono
```

- 解压后 **2.0 GB**，本机 `tar -xJf` 约 **18 秒**。
- `wine --version` → `wine-11.0`，**在 macOS 27.3 上直接可用**（不需要任何兼容层配置）。
- **依赖 Rosetta 2**：`wine`、`wineserver` 都是 x86_64 Mach-O；本机已装 Rosetta 2。
  Apple 官方承诺 Rosetta 2 在 macOS 26/27 继续提供，因此本方案在当前大版本可用；
  未来若 Apple 移除 Rosetta，需改用 arm64 原生 wine 构建（如 dawn-winery 的 signed 构建，见 §9）。
- `wineboot -u` 会出现几条无害报错（`err:setupapi:do_file_copyW Unsupported style(s) 0x10`、
  `winebth.sys/wineusb.inf copy error 1812`），`wineboot` 退出码仍为 0，容器正常。

### 4.2 macOS 27 兼容性

- 已验证：`wineboot -u` → rc=0；`wine cmd /c ver` → `Microsoft Windows 10.0.19045`；
  `wineserver -w` → rc=0；GUI（`winemac.drv`）可创建窗口（ACE-Setup64 弹窗、Unity Fatal error 弹窗均为真实 wine 窗口）。
- 未发现 macOS 27 专有回归；`winemac.drv`、`dwmapi` 等路径正常。

---

## 5. 关键步骤与实测证据

### 5.1 创建 WINEPREFIX（一个必须知道的坑）

```bash
export WINEPREFIX="$HOME/Library/Application Support/PGRLauncher/Bottle"
mkdir -p "$WINEPREFIX"        # ← 必须先建目录！
"$WINE_DIR/bin/wineboot" -u
"$WINE_DIR/bin/wine" cmd /c ver
"$WINE_DIR/bin/wineserver" -w
```

**坑**：wine 创建 prefix 时会检查父目录归属。若直接用 `/tmp/xxx`：

```
wine: '/tmp' is not owned by you, refusing to create a configuration directory there
```

`/tmp` 属于 root，所以 winboot 拒绝创建。两个解法：① 先 `mkdir -p` 出 prefix 目录本身；
② 用 `~/Library/Application Support/...` 这类属于当前用户的父目录（推荐，也是 App 的做法）。
`scripts/wine/create-bottle.sh` 已内置这两条。

实测结果：
```
wineboot -u            → rc=0（约 26 秒）
wine cmd /c ver        → Microsoft Windows 10.0.19045
wineserver -w          → rc=0
container 结构         → drive_c/{Program Files, Program Files (x86), ProgramData, users, windows}
```

> 注：使用 FineWine/CrossOver 模块后，prefix 内默认用户名是 **`crossover`**
> （`drive_c/users/crossover`），日志里出现 `C:/users/crossover/...` 是正常现象。

### 5.2 DXMT 0.80 安装（与 Yaagl 同款映射）

DXMT v0.80 builtin 包结构：

```
v0.80/
├── x86_64-windows/  d3d10core.dll  d3d11.dll  dxgi.dll  nvapi64.dll  nvngx.dll  winemetal.dll
├── x86_64-unix/     winemetal.so (31.8MB)
└── i386-windows/    d3d10core.dll d3d11.dll dxgi.dll winemetal.dll
```

安装映射（`scripts/wine/dxmt-install.sh`，参考 `yaagl-src/src/clients/mhy/patch.ts` 的 `DXMT_FILES`）：

```
<wine>/lib/wine/x86_64-windows/   ← d3d10core.dll, d3d11.dll, dxgi.dll, winemetal.dll, nvngx.dll
                                     （覆盖 wine 自带 builtin；原文件备份为 *.bak）
<wine>/lib/wine/x86_64-unix/      ← winemetal.so
<prefix>/drive_c/windows/system32/← winemetal.dll, nvngx.dll（保证 native 优先被加载）
```

**DXMT 生效证据**（国服 PGR.exe 实测）：

1. 进程加载模块序列中出现 `C:\windows\system32\d3d11.dll`、`DXGI.DLL`、`winemetal.dll`，
   且 `d3d11.dll` 大小 5,350,886 B = DXMT 包内的版本（wine 原版不是这个大小）。
2. 设置 `DXMT_LOG_PATH` 后，实际生成 DXMT 自己的日志文件：
   ```
   /tmp/dxmtlogs/PGR_d3d11.log
   /tmp/dxmtlogs/PGR_dxgi.log
   ```
   （DXMT 按进程名建日志，说明 d3d11/dxgi 已被 DXMT 接管。）
3. 随后游戏调用 D3D11 创建设备，进入 Unity 图形初始化（见 §5.4）。

> 另外：若 `DXMT_ENABLE_NVEXT=1`，Yaagl 还会写 NV 扩展注册表
> （`HKLM\SOFTWARE\NVIDIA Corporation\Global\{41FCC608-...}=1`、`...\NGXCore FullPath=C:\Windows\System32`），
> 脚本 `set-retina.sh --nv-ext on` 可一键写入。

### 5.3 FineWine 兼容模块（**最关键的一步**）

**为什么必需**：只用 yaagl wine-11.0（不加 FineWine 模块）运行国服 PGR.exe，在加载 `PGRBase.dll`
之后约 8ms 立刻崩溃退出：

```
4660.xxx:trace:loaddll:build_module Loaded L"Z:\tmp\pgr-game-cn\PGR.exe" at 0000000140000000: native
4660.xxx:trace:loaddll:build_module Loaded L"Z:\tmp\pgr-game-cn\PGRBase.dll" at 00006FFFFC690000: native
4660.xxx:err:virtual:virtual_setup_exception stack overflow 1600 bytes addr 0x6ffffff78d0f stack 0x109c0 (0x10000-0x11000-0x110000)
```

国际服同样现象（`PGRBase.dll` + ACE 一起加载时）。加上 FineWine 模块后，PGRBase 保护层可正常初始化，
游戏继续进入 UnityPlayer/IL2CPP/D3D11。

**覆盖映射**（`scripts/wine/finewine-patch.sh`）：

```
<wine>/lib/wine/x86_64-windows/  kernel32.dll dwmapi.dll ntoskrnl.exe wineboot.exe rundll32.exe lsass.exe
<wine>/lib/wine/x86_64-unix/     ntdll.so winemac.so
<wine>/bin/wineserver            替换（解压后必须 chmod 755，否则 Permission denied）
<wine>/lib/libMoltenVK.dylib     **默认不覆盖**（保留 wine 自带 1.4.1；FineWine 的 1.4.2 在 macOS 27 + Rosetta 下会导致 wineboot 卡死，见 §10.2）
```

**版本兼容性证据**：
- FineWine 包内 `CROSSOVER_VERSION=26.3.0`，`SOURCE.txt`：基于 CrossOver 26.3.0 源码 +
  `stoicswe/Endfield_FineWine` commit `accd1e8`，含 dw-proton 的 ACE 补丁。
- 包内 `SHA256SUMS` 10 个文件全部 `shasum -a 256 -c` 通过（脚本会自动校验）。
- 替换后的 `wineserver --version` = **`Wine 11.0`**，与 base yaagl wine（`wine-11.0`）同版本串；
  实际运行 `wineboot`/`wine cmd /c ver`/游戏启动均正常 → **跨 CrossOver 小版本替换在本机可用**。
- `msync` 生效证据：启动日志出现 `msync: bootstrapped mach port on wine-xxxx-msync.` /
  `msync: up and running.`（说明 FineWine 的 wineserver 与 `WINEMSYNC=1` 生效）。

### 5.4 国服（CN，无 ACE）实测：**完整安装后成功进入登录界面** ✅

#### 5.4.1 最终验收结果（全量安装）

- 安装：国服官服（G148/10012）**85,254 个文件 / 68.75GB**，全部写入 `~/Games/PGR`；
  安装完成后游戏引擎二次校验 **27 秒**通过（无缺失/哈希不符）。
- 启动：`cd <gameDir> && wine PGR.exe`（cwd 必须是游戏根目录），启动 env 见 §8；
- 结果：**成功进入 KURO GAMES 登录界面**——手机号 + 验证码输入框、`+86` 区号、二维码登录按钮、
  账号登录按钮全部正常显示，背景立绘/加载动画由 **DXMT(D3D11→Metal)** 正常渲染，无崩溃。
- 截图（`docs/screenshots/`）：
  - [game-loading.png](screenshots/game-loading.png) — 加载界面（战双 Logo + 点击进入）
  - [game-login.png](screenshots/game-login.png) — 登录界面（此图终端 LANG=C.UTF-8 启动，隐私协议一行乱码）
  - [game-font-fixed.png](screenshots/game-font-fixed.png) — 修正 LANG 后同界面，中文/协议文本正常
- 日志：启动日志与 DXMT 日志在 `~/Library/Application Support/PGRLauncher/logs/`
  （`game-*.log`、`PGR_d3d11.log`、`PGR_dxgi.log`）。

**首次启动会自校验/自更新（正常现象）**：实测首启触发 HDiff 增量更新 1346 个文件（约 5 秒），
并下载约 1482MB 资源后才进入登录界面；这是官方客户端的正常自更新流程，不是 Wine 问题。

#### 5.4.2 编码/字体（必须设置 LANG）

从终端启动时若继承 `LANG=C.UTF-8`，Wine 会把 ANSI codepage 映射为 **cp1252**，
游戏内 ANSI 文本（隐私协议那一行）显示成 `æX'·...` 之类乱码（见 game-login.png 底部的勾选文字）。
显式设置：

```bash
export LANG=zh_CN.UTF-8
export LC_ALL=zh_CN.UTF-8
```

后 Wine 使用 **cp936(GBK)**，中文正常（game-font-fixed.png）。`scripts/wine/run-game.sh` 已强制默认
`zh_CN.UTF-8`（可用 `PGR_LANG` 覆盖）。

#### 5.4.3 最小文件集阶段（早期实验，供排查参考）

全量安装前，我们曾用 252MB 的最小运行集（`/tmp/pgr-mini-cn`：PGR.exe 322KB、PGRBase.dll 28MB、
UnityPlayer.dll 31MB、GameAssembly.dll 174MB、PGR_Data 根文件、KRSDK/CrashSight 插件）验证链路，
得到两个重要中间结论：

1. **缺 il2cpp 数据 + 空 metadata 文件**：首次运行弹 Unity 原生错误框
   「Fatal error: Failed to initialize IL2CPP」，日志
   `[libil2cpp] ERROR: Could not open .../PGR_Data/il2cpp_data\Metadata\global-metadata.dat`。
   国服清单里该文件是 **0 字节**（md5 `d41d8cd9...` 空文件 MD5），`touch` 一个空文件即解决；
   （国际服清单里是 8 字节，md5 `6b168e18...`）。再补 4 个
   `PGR_Data/il2cpp_data/Resources/*.dat`（I18N.CJK/mscorlib/System.Data/System.Drawing）后
   **IL2CPP 初始化通过**。
2. **随后在 Unity 图形初始化阶段崩溃**（补齐 il2cpp 后）：
   ```
   wine: Unhandled page fault on read access to 0000000000000038
         at address 00006FFFFA84E59C (thread 0024), starting debugger...
   栈：unityplayer ×6 ← pgr (0x14000106B/0x140001287) ← kernel32 ← ntdll
   A crash has been intercepted by the crash handler（Unity CrashSight 捕获）
   ```
   崩溃发生在 D3D11(DXMT) 设备创建后约 1.8s、尚未加载首场景 StreamingAssets 资源，
   因此当时判断为「缺资源 / DXMT 交互」二选一未分离。**全量安装后该崩溃未再出现**，
   说明它确实是**最小文件集缺资源**导致的原生空指针（真实资源到位后 DXMT 渲染路径正常）。
   排查当时用的命令仍保留在 §13 供以后回归：

   ```bash
   scripts/wine/run-game.sh --game-dir <dir> --args "-force-d3d11" --monitor 30
   scripts/wine/run-game.sh --game-dir <dir> --args "-force-vulkan" --monitor 30
   scripts/wine/run-game.sh --game-dir <dir> --debug "-all,+seh,+timestamp"
   ```

> 关键结论：**国服（无 ACE）在「yaagl wine 11.0-1 + FineWine 模块 + DXMT 0.80」组合下可正常启动到登录界面**，
> 不需要 ACE 补丁链、不需要官方启动器。

### 5.5 国际服（含 ACE）实测：ACE 能加载但过不了驱动链

测试集 `/tmp/pgr-game`（131MB，国际服 G143/50015，含 `AntiCheatExpert/` 7 个文件）。

| 组合 | 结果 |
|---|---|
| base wine + DXMT | 与 CN 一样，PGRBase.dll 后立刻 `virtual_setup_exception stack overflow` 退出 |
| FineWine wine + DXMT | `ntoskrnl.exe`（补丁版）加载、`lsass.exe`（FineWine stub）被启动、ACE 的异常探测被 vectored handler 正常接管（`FF FF FF FF` 返回）；**`ACE-Setup64.exe` 可以弹出真实 GUI 窗口**（内容："This will uninstall AntiCheatExpert, continue?"） |
| FineWine wine + DXMT + 直接跑 PGR.exe | `rc=222` 退出；无 ACE 服务/驱动注册（prefix `system32/drivers` 无 ACE 文件、注册表无 ACE 服务） |

结论：国际服需要**完整的 ACE 安装链**（`ACE-Setup64.exe` 静默安装参数 + `ACE-CORE.sys`/`ACE-BASE.sys`
驱动在 wine ntoskrnl 下加载 + 服务注册 + 反作弊握手）。目前只做到「ACE 组件能在 wine 下跑起来并弹窗」，
**不能认为国际服可运行**。同理，官方启动器安装出来的国际服客户端在 Wine 下会遇到 ACE 驱动问题。

> 国际服 il2cpp 数据参考：其 indexFile 里 `global-metadata.dat` 是 **8 字节**（md5 `6b168e18...`），
> 与国服 0 字节不同；若将来要验证国际服，需按清单放入 8 字节内容。

### 5.6 官方启动器 `pclauncher.exe`（实测：安装器 GUI 可跑，但产品启动器不可用，不采用）

- 文件：`/tmp/pclauncher.exe`，209,696,344 B，sha256 `3b2f122e16632eaf3cfc45ede384c3f676d00fc7a1dd1f3166f92170fc5f8ac1`
- 类型：`PE32 executable (GUI) Intel 80386, for MS Windows, Nullsoft Installer self-extracting archive`
  （NSIS 自解压安装器；`strings` 可见 `NullsoftInst`、`SETUPAPI`）。

**实测（Wine 11.0-1 + FineWine + DXMT，临时 prefix `/tmp/pgr-launcher-test`）**：

- `WINEPREFIX=<新容器> wine /tmp/pclauncher.exe` **安装器 GUI 正常启动并完整渲染**：
  窗口标题 `Punishing Gray Raven  Install`（720×456），背景立绘、`Install` 按钮、
  `I have read and agree to the "Terms of Service" & "Privacy Policy"` 勾选框、`Customize` 入口全部可见可交互；
  安装器内的 Web/渲染内容（Metal/Vulkan 路径）也都正常出图。
  截图：[launcher-installer.png](screenshots/launcher-installer.png)
- 但**装出来的启动器本体是 .NET 8 WPF + WebView2**，在 Wine 下不可用
  （WineHQ bug 60420：WPF/WebView2 组合缺失；WebView2 运行时无法安装/初始化）。
  且该路径要下载 ~460MB 启动器 + 249MB KRWebViewRuntime，最终仍卡在 .NET/WebView2。

**结论**：安装器 GUI 在 Wine 下能跑（说明 Wine/DXMT 图形栈没问题），但**官方启动器产品本身不可用**。
因此本项目**不依赖官方启动器**，改为「CDN 单文件直连下载游戏文件 + wine 直接启动 PGR.exe」——
实测该路线已完整跑通（§5.4）。

---

## 6. 目录与资源来源（启动器实现要点）

- 国服（G148/10012）indexFile 全量 85,254 文件 / 68.75 GB；根目录只有
  `PGR.exe`(322,248B)、`PGRBase.dll`(28MB)、`UnityPlayer.dll`(31MB)、`GameAssembly.dll`(174MB)、
  `baselib.dll`、`version.json`；`PGR_Data/Plugins` 有 KRSDK（登录）与 CrashSight；
  **国服完全没有 ACE 反作弊文件**（国际服才有 7 个 ACE 文件）。
- CDN 单文件直连（`CDN根 + default.config.baseUrl + dest`）对单个文件有效；
  `global-metadata.dat` 这类 0 字节文件返回 `200 + Content-Length: 0`，按清单写空文件即可。
- 本项目启动器实现「单文件直连 + MD5/大小校验 + 断点续传」即可，krzip 只是官方分发格式，
  不必实现解包（此结论由 Lead 复验：30/30 随机小文件 200 且 size/md5 完全一致）。

---

## 7. Retina 与分辨率

### 7.1 设置与验证（实测）

```bash
export WINEPREFIX="$HOME/Library/Application Support/PGRLauncher/Bottle"
W="$HOME/Library/Application Support/PGRLauncher/Runtime/wine"

"$W/bin/wine" reg add "HKCU\\Software\\Wine\\Mac Driver" /v RetinaMode /t REG_SZ /d y /f
"$W/bin/wine" reg query "HKCU\\Software\\Wine\\Mac Driver" /v RetinaMode
# → HKEY_CURRENT_USER\Software\Wine\Mac Driver
#       RetinaMode    REG_SZ    y
```

`y` / `n` 都实测可写入并回读（`build/winedrv_config` 风格的批处理也可，Yaagl 就是写一个 .bat 再 `wine cmd /c`）。
另有 `LeftCommandIsCtrl`（左 Command 当 Ctrl）同样写在 `HKCU\Software\Wine\Mac Driver`，
Yaagl 默认开启（本机 Yaagl HSR 的 `.storage/left_cmd.neustorage` = true）。

### 7.2 生效方式与影响

- **生效时机**：`RetinaMode` 在 **wine 进程启动时**读取；改完必须重启游戏（新进程）才生效，
  改注册表本身不用重启容器。
- **RetinaMode=y**：wine 按 macOS 的物理像素（backing scale factor，2x）创建窗口/画布。
  例如游戏内 1280×720 的窗口在 2x 屏上实际渲染 2560×1440 像素 → 文字/UI 清晰，但 GPU 负载与显存占用约 4 倍。
- **RetinaMode=n**：按逻辑分辨率（1x）渲染，由 macOS 放大到屏幕 → 画面略糊，但帧率更高、发热更低。
- 对 DXMT：DXMT 会按 wine 报告的 swapchain 尺寸创建 Metal 纹理；`y` 时渲染分辨率翻倍，
  对 M6 集显（16GB 统一内存）建议：**默认 y（清晰优先）**，若帧率不足或发热明显改 `n`，
  并在游戏内把分辨率/画质调到与窗口匹配的值。
- 也可用 DXMT 的 `DXMT_CONFIG=d3d11.preferredMaxFrameRate=N` 限帧（`run-game.sh --max-fps N`），降低发热。

### 7.3 编码 / LANG（实测必须设置）

| 启动时的 locale | Wine ANSI codepage | 结果 |
|---|---|---|
| `LANG=C.UTF-8`（终端继承，且未显式覆盖） | cp1252 | 游戏内 ANSI 文本乱码：隐私协议那行显示 `æX'·...`（见 [game-login.png](screenshots/game-login.png) 底部） |
| `LANG=zh_CN.UTF-8` + `LC_ALL=zh_CN.UTF-8` | cp936 (GBK) | 中文正常（见 [game-font-fixed.png](screenshots/game-font-fixed.png)） |

- 根因：Wine 的 ANSI codepage 由 **进程启动时的 locale** 决定，不是由注册表或游戏设置决定；
  `C.UTF-8` 映射到 cp1252，所以中文（GBK 编码的 ANSI 字符串）变乱码。
- 解决：启动器/脚本在 `launchEnvironment` 里显式设 `LANG=zh_CN.UTF-8`、`LC_ALL=zh_CN.UTF-8`
  （本项目 App 已让 `GameManager.launchEnvironment` 写入；`scripts/wine/run-game.sh` 同样默认强制）。
- 注意：只影响 ANSI（`A` 结尾）API 的文本；UTF-16 文本（登录框输入等）不受影响，
  因此乱码只出现在部分控件上，容易误判为字体缺失。

---

### 7.4 分辨率发糊（Retina）修复记录

**现象**：游戏窗口渲染模糊、文字发虚（尤其在 3024×1964 的 Liquid Retina XDR 屏上）。

**根因**：启动器此前把 `RetinaMode` 的写入放在独立 `Task` 里（fire-and-forget），而 `PGR.exe`
在写入落盘前就已启动；游戏按 Wine 报告的**逻辑分辨率 1512×982** 创建渲染目标，macOS 再按 2×
放大到 3024×1964 → 画面发糊。日志佐证（修复前）：
`record origin screen size: 1512 x 982` / `unity写入的设备分辨率，1512 * 982`。

**修复**（`Sources/Core/AppState.swift` + `RuntimeManager`）：
1. `applyBottleSettings()` 改为 `async`，在 `launchGame()` 中 **`await` 完成后**才启动游戏；
2. 写入 `HKCU\Software\Wine\Mac Driver\RetinaMode=y`（以及 `LeftCommandIsCtrl`）后执行
   `wineserver -w`，确保注册表落盘；
3. 设置面板的 Retina 开关仍可关闭（性能模式，游戏回到 1512×982 逻辑分辨率）。

**修复后实测**（`PGR.exe` 完整启动日志 + 窗口截图）：
- `record origin screen size: 3024 x 1964, safe size:3024 x 1964`
- `获取设备分辨率，width：3024，height：1964 ... unity写入的设备分辨率，3024 * 1964`
- 窗口截图分辨率 3024×1964（原生 2× 像素），文字/UI 清晰。
- 截图：`docs/screenshots/game-retina-native.png`（对比修复前的 `docs/screenshots/game-login.png`）。

**注意**：
- Retina 开启时 GPU 负载约为 4 倍（3024×1964，约 590 万像素）；M 系列 GPU 可流畅运行，
  低配机器可在设置中关闭 Retina 或降低帧率上限。
- 游戏内「设置 → 画质/分辨率」也可以调整渲染档位；本启动器的 Retina 控制的是 Wine 报告给
  游戏的屏幕分辨率，两者叠加生效。

## 8. 启动环境变量清单（Yaagl HSR 同款，已固化进 `run-game.sh`）

| 变量 | 推荐值 | 说明 |
|---|---|---|
| `WINEPREFIX` | `<...>/PGRLauncher/Bottle` | 容器路径；每个容器独立 |
| `WINEMSYNC` | `1` | FineWine/CrossOver wineserver 的 msync 同步（日志 `msync: up and running.`）；base wine 无此支持时被忽略 |
| `WINEDEBUG` | `-all`（默认）/ `+loaddll,+timestamp`（排查） | 静音避免日志爆炸；排查加载用 `+loaddll`，查崩溃用 `-all,+seh` |
| `DXMT_LOG_PATH` | `<logs>` | DXMT 日志目录（会生成 `PGR_d3d11.log` / `PGR_dxgi.log`） |
| `DXMT_CONFIG` | `d3d11.preferredMaxFrameRate=N;dxgi.customVendorId=10de;dxgi.customDeviceId=2684` | 限帧 + 伪装 NVIDIA 设备（部分游戏按 vendor 选渲染路径） |
| `DXMT_CONFIG_FILE` | `<logs>/dxmt.conf` | 同上配置的文件形式 |
| `DXMT_ENABLE_NVEXT` | `1` | 启用 NVAPI/NVNGX 扩展（配合 `set-retina.sh --nv-ext on` 写注册表） |
| `GST_PLUGIN_FEATURE_RANK` | `atdec:MAX,avdec_h264:MAX` | GStreamer 解码优先级（视频/过场用） |
| `MTL_HUD_ENABLED` | `0`/`1` | Metal HUD，调试帧率用 |
| `LANG` / `LC_ALL` | **`zh_CN.UTF-8`**（必须） | 决定 Wine ANSI codepage；不设置会乱码（§7.3） |
| `WINEDLLOVERRIDES` | 空 | 不覆盖 DLL；DXMT 已作为 builtin 替换 |
| `HTTP_PROXY`/`HTTPS_PROXY` | 可选 | 游戏走代理（同时设大写/小写） |
| cwd | **游戏根目录** | 必须；PGR.exe 以相对路径找 `PGR_Data/` |

> 游戏启动命令：`cd <gameDir> && "$WINE/bin/wine" PGR.exe [额外参数]`

---

## 9. 备选 wine 包（未在本机逐字节验证，供回退/升级）

来源均为 Yaagl `src/wine/distro.ts` 的官方清单：

| 发行版 | URL | SHA-256 | 说明 |
|---|---|---|---|
| Wine 11.8 DXMT (signed) | `https://github.com/yaagl/anime-game-wine/releases/download/wine-11.8-signed/wine-devel-11.8-osx64-signed.tar.xz` | `42430b7e8398642d7121e7cbac0aa03ce7312b4500e4ddf7eb75a7c8f2407a9c` | 更新版 devel；winePath 同样为 `wine/`。可作 base wine 升级候选，需重新验证 FineWine 模块兼容性 |
| Wine 11.0 DXMT (signed, with patches) | `https://github.com/yaagl/anime-game-wine/releases/download/wine-11.0-signed/wine-devel-11.0-osx64-signed.tar.xz` | `4ebba536115e937c3826fa5808dbed50cd5e91c8454999b54cbe0cd2a43d8b4c` | 11.0 devel，带 yaagl 补丁；与当前 Crossover 11.0-1 同代 |
| Dawn-Winery 11.4 (signed) | `https://github.com/dawn-winery/dawn-signed/releases/download/wine-gcenx-11.4-osx64/wine-devel-11.4-osx64-signed.tar.xz` | 清单未给 | winePath = `wine-devel-11.4-osx64-signed/Contents/Resources/wine`（归档根不同！） |
| Dawn-Winery 11.0 (signed) | `https://github.com/dawn-winery/dawn-signed/releases/download/wine-stable-gcenx-11.0-osx64/wine-stable-11.0-osx64-signed.tar.xz` | 清单未给 | winePath = `Wine Stable.app/Contents/Resources/wine`（归档根不同！） |
| Wine 11.17 D3DMetal (GPTK 4.0b2) | `https://github.com/dbc-hbin/wine-yaagl-d3dmetal/releases/download/wine-11.17-gptk4.0b2-10/wine-11.17-d3dmetal-gptk4.0b2-macos26.tar.xz` | `5084a2ca19071f9269193c9b6f003a82eeb96f823b1121382aa317ae2fb50fd4`（239,444,460 B） | D3DMetal 后端（需 GPTK 授权 + MoltenVK）；**本方案不推荐**：DXMT 更成熟且免授权 |
| FineWine 兼容模块（备用） | `https://github.com/stoicswe/Endfield_FineWine/releases/download/1.4.3/endfield-wine-modules.tar.gz` | `d71b61275e98a65cab95626f33baa842567c63f8483a6b963a4031de862da2e2` | 每次 FineWine 升级需重新对比模块列表与 base wine 版本串 |

选择理由：
- **wine 11.0-1 Crossover signed**：本机已验证、与 Yaagl HSR 实际使用的完全一致（`wine_tag=11.0-1-crossover-signed-experimental`），
  且其 `wineserver --version = Wine 11.0` 与 FineWine 模块匹配；
- **FineWine 1.4.3**：唯一能过 PGRBase 保护层的现成补丁；
- **DXMT 0.80 builtin**：免授权、与 wine 11.0 配套、Yaagl 生产使用中；D3D11 已实测接管。

---

## 10. 已知问题与风险

1. **FineWine 模块跨版本替换**：模块来自 CrossOver 26.3.0，base wine 是 Crossover 11.0-1；
   两者版本串都是 `Wine 11.0`，本机实测可用，但属于「非官方组合」——升级 base wine（如 11.8）后
   必须重测 PGRBase 是否仍能通过。
2. **⚠️ 不要覆盖 `libMoltenVK.dylib`（实测会卡死 wineboot）**：
   FineWine 包自带 MoltenVK 1.4.2（CrossOver 26.3），一旦把它覆盖到 `<wine>/lib/libMoltenVK.dylib`，
   在本机 macOS 27.3 + Rosetta 2 上会稳定出现：
   ```
   rosetta error: Attachment of code signature supplement failed: 1
     /var/db/oah/<hash>/libMoltenVK.dylib.aot
   ```
   随后 `wineboot -u` 卡死在 `rundll32.exe setupapi,InstallHinfSection PreInstall`（实测 3/3 复现，
   >120s 不返回）；把 wine 包**自带**的 MoltenVK 1.4.1 换回去后 `wineboot` 立刻恢复（2/2 通过）。
   - DXMT 后端**不需要** MoltenVK，保留 wine 自带的即可；
   - `scripts/wine/finewine-patch.sh` 默认**不覆盖** MoltenVK，只有 `--with-moltenvk`（D3DMetal 后端）才覆盖；
   - 如果已经踩坑：`cp <wine>/lib/libMoltenVK.dylib.bak <wine>/lib/libMoltenVK.dylib` 即可恢复。
   - **对 App 的提醒**：`RuntimeManager.applyFineWineModules()` 目前会无条件覆盖 `libMoltenVK.dylib`；
     本机验收时 App 安装的运行时里该文件已是 FineWine 1.4.2（`.bak` 为 wine 1.4.1），首次安装可用，
     但**「重新安装运行时 / 修复运行时」会在 Rosetta AOT 缓存已存在的情况下二次覆盖 → wineboot 卡死**。
     建议干脆不复制该文件（DXMT 不需要）；若必须保留，至少在文件已存在时跳过复制。
3. **wineserver 权限**：FineWine 归档里的 `bin/wineserver` 解压后是 644，**必须 chmod 755**，
   否则 `wine` 完全无法启动（`Permission denied`）。脚本已处理。
4. **prefix 放置位置**：不要放 `/tmp`（root 拥有），否则 wine 拒绝创建（见 §5.1）。
   另外 `winecfg -v win10` 会打开 GUI 阻塞无人值守脚本——设置 Windows 版本请用
   `wine reg add "HKCU\Software\Wine" /v Version /t REG_SZ /d win10 /f`（脚本已改）。
5. **中文乱码**：必须设 `LANG=zh_CN.UTF-8` / `LC_ALL=zh_CN.UTF-8`（§5.4.2、§7.3）。
6. **国际服 ACE**：不可运行（见 §5.5），除非投入完整 ACE 驱动链适配。
7. **Rosetta 依赖**：wine 是 x86_64，Apple 未来移除 Rosetta 后本方案失效；备选是 arm64 原生 wine 构建（§9）。
8. **Retina 性能**：`RetinaMode=y` 渲染像素 ×4，M6 集显在复杂场景可能掉帧；可用 `--max-fps` 限帧缓解。
9. **首次启动耗时**：wineboot ~26s；首启自校验/自更新（HDiff 1346 文件 ~5s + 下载 ~1482MB）；
   DXMT 首次编译 shader 会有缓存预热。
10. **最小文件集不能直接跑**：缺 `PGR_Data/il2cpp_data` 会报「Failed to initialize IL2CPP」，
    缺 StreamingAssets 资源会在 Unity 图形初始化后崩（§5.4.3）；调试时务必用全量安装目录。

---

## 11. 实验日志与截图（本机路径）

```
日志（/tmp/wine-test/logs/）
  wineboot-*.log            wineboot 各容器初始化
  pgr-base.log              base wine（无 FineWine）跑国际服：stack overflow 崩溃
  pgr-finewine.log          FineWine wine 跑国际服：ACE 加载、lsass 启动、MoltenVK
  mon-fw2.log               FineWine wine + +seh：ACE 异常探测/vectored handler 细节
  pgr-fw-loaddll.log        FineWine wine + +loaddll：ntoskrnl/lsass 加载顺序
  ace-setup.log             ACE-Setup64.exe 运行日志
  game-cn-fw.log            国服首次：IL2CPP 缺 global-metadata.dat（Fatal error）
  game-cn-il2cpp.log        国服补齐 il2cpp_data 后：IL2CPP 通过 → DXMT d3d11 → UnityPlayer 崩溃
  game-cn-vulkan.log        国服 + Vulkan/MoltenVK 路径（VkInstance 创建成功）
截图（docs/screenshots/，最终验收）
  game-loading.png          全量安装后游戏加载界面（战双 Logo + 点击进入）
  game-login.png            KURO GAMES 登录界面（LANG=C.UTF-8 时隐私协议乱码，作对照）
  game-font-fixed.png       LANG=zh_CN.UTF-8 后同一登录界面（中文正常）

截图（/tmp/wine-test/shots/，实验过程）
  cn-fatal.png              Unity 原生对话框「Fatal error: Failed to initialize IL2CPP」
  ace-dialog.png            ACE-Setup64 窗口「This will uninstall AntiCheatExpert, continue?」
  cn-fw-t5/10/20/30.png     最小文件集运行期间全屏截图
  shot-base.png、fw2-t5/10.png   base / FineWine 对照截图
DXMT 日志
  /tmp/dxmtlogs/PGR_d3d11.log、PGR_dxgi.log   （DXMT 生效证据）
```

> 说明：截图由 `screencapture -x` 采集；测试期间桌面上会同时有其它 App 窗口（同为该项目其它任务的进程），
> 判断 wine 窗口请以 `scripts/wine/run-game.sh` 打印的窗口列表 / 日志为准。

---

## 12. 与 App（RuntimeManager）的对应关系

本项目 Swift App 的 `Sources/Services/RuntimeManager.swift` 与本手册完全一致：

| App 行为 | 对应脚本/文档 |
|---|---|
| `WineRuntimeCatalog.wineCrossover` / `dxmt` / `fineWine` 的 URL+sha256+size | §2 常量（`scripts/wine/lib-common.sh` 同值） |
| `Runtime/{downloads,wine,dxmt,finewine}`、`Bottle/`、`logs/` | §3 目录约定 |
| `applyFineWineModules()`（`.bak` 备份 + `chmod 755 wineserver`） | `finewine-patch.sh` |
| `installDXMT()` / `installDXMTIntoPrefix()` | `dxmt-install.sh` |
| `initializePrefix()`（wineboot -u、win10、system32、`wineserver -w`） | `create-bottle.sh` |
| `setRetina()` / `setLeftCommandIsCtrl()` | `set-retina.sh` |
| `GameManager.launchEnvironment()`（WINEMSYNC/DXMT_*/GST/MTL_HUD/**LANG/LC_ALL**） | `run-game.sh`（§8 清单、§7.3 编码） |

---

## 13. 端到端验收结果与复现（已完成 ✅）

**验收结果（2026-11-10）**：国服官服全量安装（85,254 文件 / 68.75GB）→ 引擎二次校验 27s 通过
→ `wine PGR.exe` 启动 → DXMT 渲染 → **进入 KURO GAMES 登录界面**（截图见 §5.4.1）。
首启自更新（HDiff 1346 文件 + ~1482MB 资源下载）正常完成。

复现/回归命令：

```bash
# 0) 体检（wine/DXMT/FineWine/容器/Retina）
scripts/wine/verify.sh --run-smoke

# 1) 正常启动 + 截图 + 日志（默认 DXMT/d3d11，自动设 LANG=zh_CN.UTF-8）
scripts/wine/run-game.sh --game-dir "$HOME/Games/PGR" --monitor 60

# 2) 若崩溃，按矩阵分离原因
scripts/wine/run-game.sh --game-dir "$HOME/Games/PGR" --args "-force-vulkan"  --monitor 30
scripts/wine/run-game.sh --game-dir "$HOME/Games/PGR" --args "-force-d3d11"   --monitor 30
scripts/wine/run-game.sh --game-dir "$HOME/Games/PGR" --debug "-all,+seh,+timestamp"

# 3) 判定标准：出现 KURO GAMES 登录界面 / 游戏窗口即通过；
#    崩溃时留档 logs/game-*.log + DXMT_LOG_PATH 下的 PGR_d3d11.log / PGR_dxgi.log

# 4) 常见回退
scripts/wine/finewine-patch.sh --restore   # wineboot 卡死时先排除 FineWine 模块
scripts/wine/dxmt-install.sh --restore     # 渲染异常时还原 wine 自带 d3d11/dxgi
scripts/wine/set-retina.sh --off           # 帧率不足时关闭 Retina
```
