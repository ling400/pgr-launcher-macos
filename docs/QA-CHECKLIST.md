# QA 验收清单（Lead 维护）

## 构建
- [ ] `./scripts/build.sh debug` 无错误
- [ ] `./scripts/build.sh`（release）无错误
- [ ] `codesign -dv build/PGRLauncher.app` 显示 ad-hoc 签名
- [ ] `plutil -lint Resources/Info.plist` 通过
- [ ] `Resources/AppIcon.icns` 生效（Finder 显示图标）

## 应用启动
- [ ] `open build/PGRLauncher.app` 能打开窗口，无崩溃
- [ ] 窗口尺寸/深色主题正常，Retina 下清晰（截图确认）
- [ ] 关闭窗口后进程退出，无残留

## 状态机
- [ ] 无 Wine 运行时时：显示“需要准备 Wine 环境”，主按钮触发 installRuntime
- [ ] 点了准备环境：进度条/状态/日志更新，失败时错误可读且可重试
- [ ] 有运行时但无游戏：显示“尚未安装游戏”，主按钮触发下载游戏
- [ ] 游戏安装后：识别版本，主按钮变为“启动游戏”
- [ ] 下载/安装/更新期间按钮禁用，防止并发操作

## 运行时（真实安装）
- [ ] Wine 归档下载完成、SHA-256 与预期一致
- [ ] 解压后 `Runtime/wine/bin/wine --version` 输出 wine-11.0
- [ ] DXMT 文件安装到 wine/lib 与 Bottle system32（存在性检查）
- [ ] `wineboot -u` 初始化 prefix 成功，`wine cmd /c ver` 有输出
- [ ] Retina 开关落盘：`wine reg query "HKCU\Software\Wine\Mac Driver" /v RetinaMode`

## 游戏流程（真实）
- [ ] 安装器 pclauncher.exe 下载完整（209,696,344 bytes）
- [ ] Wine 中运行官方安装器有 GUI（截图）
- [ ] 官方启动器可运行/可下载（记录结论与限制）
- [ ] 游戏主程序可被识别并直接启动（若本机完成下载）
- [ ] 游戏进程退出后启动器状态回到 ready

## 键盘映射
- [ ] 无辅助功能权限时有提示与「去授权」入口
- [ ] 授权后可新增/删除/启停映射
- [ ] 游戏运行期间映射生效（可用文本编辑器模拟进程测试），退出后不拦截系统按键

## 文档
- [ ] README 与实现一致（功能、路径、命令）
- [ ] docs/ARCHITECTURE.md、docs/CONTRACT.md、docs/PGR-CLIENT.md、docs/WINE-RUNTIME.md 齐全
- [ ] 代码中无遗留 TODO/占位（notImplemented 等）
