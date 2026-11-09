# research/ —— 战双帕弥什（PGR）PC 客户端安装/更新机制研究产物

本目录只放**分析脚本**与**抓到的样本**，结论文档在 [`docs/PGR-CLIENT.md`](../docs/PGR-CLIENT.md)。
所有脚本只用 Python 3 标准库，可直接复跑。

## 脚本

| 脚本 | 作用 | 典型命令 |
|---|---|---|
| `parse_pe.py` | 纯 Python PE 分析：DOS/PE/可选头、节表、每节熵与 sha256、打包器指纹（NSIS/Electron/CEF/.NET/Unity…）、URL/域名/关键词提取（ASCII + UTF-16LE） | `python3 research/parse_pe.py /tmp/pclauncher.exe --dump-strings` |
| `nsis_extract.py` | 解包 PGR 官方安装器（NSIS 3.x Unicode，非 solid + raw DEFLATE）：解析 firstheader/头块/entries/字符串表，按 `EW_EXTRACTFILE` 提取全部内嵌文件 | `python3 research/nsis_extract.py /tmp/pclauncher.exe --out-dir /tmp/out` |
| `decrypt_krapp_conf.py` | 解密启动器内嵌配置 `Assets/KRApp.conf`（base64 + XOR 0x63）→ 得到 gameId/appId/appKey/configUrl/**cdn 入口** | `python3 research/decrypt_krapp_conf.py <KRApp.conf> --json-out /tmp/krapp.json` |
| `fetch_channel.py` | 复现官方 CDN 协议：拉 game index.json / 完整 indexFile 清单 / 单文件 md5 校验 / 启动器自更新配置 | `python3 research/fetch_channel.py config cn` 等 |

## 复现「从安装器拿到渠道参数」的完整流程（以国服为例）

```sh
# 1) 下载国服安装器（约 210MB）
curl -L -o /tmp/PGR_install_2.6.3.0.exe \
  https://zspms-txcdn-media.kurogame.com/install/PGR_install_2.6.3.0.exe
shasum -a 256 /tmp/PGR_install_2.6.3.0.exe   # 520eccb1...

# 2) 解 NSIS，得到 KRLauncher.zip / KRRes.zip 等
python3 research/nsis_extract.py /tmp/PGR_install_2.6.3.0.exe --out-dir /tmp/pgr_cn

# 3) 从 KRLauncher.zip 取出 2.6.3.0/Assets/KRApp.conf 并解密
unzip -oq /tmp/pgr_cn/KRLauncher.zip -d /tmp/pgr_cn/launcher
python3 research/decrypt_krapp_conf.py \
  /tmp/pgr_cn/launcher/2.6.3.0/Assets/KRApp.conf

# 4) 用脚本拉远端配置/清单（渠道常量已固化在 research/samples/channels.json）
python3 research/fetch_channel.py config cn
python3 research/fetch_channel.py manifest cn
python3 research/fetch_channel.py file cn version.json
```

国际服 / B 服同理，只是安装器 URL 与 `channels.json` 里的参数不同（见文档）。

## samples/ 内容与来源

| 文件 | 说明 | 来源 |
|---|---|---|
| `channels.json` | **三个渠道的全部已核实参数**（gameId/appId/appKey/pkgId/configUrl/backup/launcherConfigUrl/cdnList/版本/清单大小/安装器 URL+大小+md5+sha256） | 由三份解密的 KRApp.conf + 实测 HTTP 结果汇总 |
| `KRRes/KRPluginConfig.json` | 国际服安装器内的启动器渠道配置（G143 / 50015 / A1728 / 进程名 PGR.exe、KRSDKExternal.exe） | NSIS 解包 `KRRes.zip` |
| `KRRes/LauncherInstall.xml`、`MsgWnd.xml`、`Mask.xml`、`oldVerFileList.json` | 国际服安装器 DuiLib UI 布局/安装文件清单等 | 同上 |
| `game_probe/PGR.exe`、`game_probe/version.json` | 从 CDN 实下的国际服小文件（用于核对清单 md5） | `.../4.9.1/QQGk.../zip/` |
| `pgr_global_game_index.json` / `pgr_global_indexFile.json` | 国际服 `.../launcher/game/G143/.../index.json`（7.7KB）与完整逻辑清单 `indexFile.json`（13,741,605B，85,263 文件，68.4GB） | 官方 CDN 实抓 |
| `pgr_cn_game_index.json` / `pgr_cn_indexFile.json` | 国服官服（G148/10012）同项，85,254 文件，68,754,938,042B | 官方 CDN 实抓 |
| `pgr_bili_game_index.json` / `pgr_bili_indexFile.json` | B 服（G148/10011）同项，85,325 文件，68,950,331,895B | 官方 CDN 实抓 |
| `launcher_global.json` / `launcher_cn.json` / `launcher_bili.json` | 启动器自更新配置（launcher.zip 版本/大小/md5、WebView2 运行时组件） | 官方 CDN 实抓 |
| `installer_cn/KRApp.conf.decoded.json` | **国服官服**解密后的启动器配置（G148/10012/appKey/RnIUKs…/configUrl） | 国服安装器 NSIS 解包 |
| `installer_bili/KRApp.conf.decoded.json` | **B 服**解密后的启动器配置（G148/10011/appKey/qYQv6…/configUrl） | B 服安装器 NSIS 解包 |
| `pclauncher.nsis_header.bin` / `pclauncher.nsis_blocks.json` | 国际服安装器 NSIS 头块原始字节与解析结果（可用来核对 `nsis_extract.py`） | `parse_pe.py` 定位 |
| `launcher_main.utf16strings.txt` | 国际服 `launcher_main.dll`（.NET 8）里提取的 UTF-16 字符串（能看到 version.txt/cdnConfig.json/launcherDownloadConfig.json/hpatchz 等机制关键词） | 解包 `KRLauncher.zip` 后提取 |
| `installer/KRRes/`、`installer_cn/KRRes_cn/`、`installer_bili/KRRes_bili/` | 三个安装器里的渠道配置 JSON + DuiLib 布局（已剪掉 PNG 资源避免仓库过大） | NSIS 解包 |

> 说明：出于体积考虑，`KRLauncher.zip`（182MB）与解出的 .NET 运行时/DLL、安装器 exe 本体都没进仓库；
> 需要时按上面「复现流程」现场重下重解即可（安装器本身 <220MB，游戏清单 md5 可逐文件核对）。

## 关键哈希（便于核对下载物）

| 对象 | 大小 | md5 | sha256 |
|---|---|---|---|
| 国际服安装器 `pclauncher.exe` | 209,696,344 | `bb34c56146f113e7552faa672d35fcfc` | `3b2f122e16632eaf3cfc45ede384c3f676d00fc7a1dd1f3166f92170fc5f8ac1` |
| 国服官服安装器 `PGR_install_2.6.3.0.exe` | 210,016,024 | `36fbd20c48a5f255b54c78717dbc8874` | `520eccb190ef57fd036a50767f101d471ef0834c3a24025afc0eeeeb2d3e9f5f` |
| B 服安装器 `zspmsPCb_bilibili_20260625_….exe` | 210,063,512 | `5165e0536083523dfa46ec7f3a3daa68` | `34d3a66792f7b8a02f444c56928fc0c4295e8a123f4d23f8d7a680e9e26f9ba3` |
| 国际服 `PGR.exe` | 459,192 | `36449a8371e4064f78d86c0c851fdda5` | `0cb0cd3a001eeb1c8731456f814dde1bb1663d54003f94fdead4d8832c8d6fa0` |
| 国服/B服 `PGR.exe` | 322,248 | `cbe8f8db0ded6d83f7accb5cbb7e22f9` | `76aa84e953beed542b71f434522bcbd01c15ead770e64d71456b60c3b3132d68` |
| 公共 `version.json` | 24 | `ab37f420e29ce99f7c92ce578b292658` | 内容 `{package_version:4.9.1}\n` |

## 注意事项

- 所有结论基于 2026-11-09 的实测；`appKey`（configUrl 里的 token）来自安装器包内，**会随启动器版本更新而轮换**，
  失效时按上面流程重新解包最新安装器即可。
- 访问 B 站 `pkg.biligame.com` 下载链接必须带 `Referer: https://www.biligame.com/detail?id=114996`，否则 403。
- alicdn 上的 `index.json` 是 gzip 响应，客户端需声明 `Accept-Encoding: gzip` 并解压。
