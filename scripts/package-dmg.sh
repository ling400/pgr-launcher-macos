#!/usr/bin/env bash
# Package build/PGRLauncher.app into a distributable DMG (ad-hoc signed).
# Usage: ./scripts/package-dmg.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/PGRLauncher.app"
DMG="$ROOT/build/PGRLauncher.dmg"
STAGE="$ROOT/build/dmg-stage"
VOLNAME="战双启动器"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0.0.0)"

if [ ! -d "$APP" ]; then
  echo "缺少 $APP，请先运行 ./scripts/build.sh" >&2
  exit 1
fi

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/PGRLauncher.app"
ln -s /Applications "$STAGE/Applications"

# Simple usage note inside the DMG
cat > "$STAGE/安装说明.txt" <<'EOF'
PGR Launcher — 战双帕弥什 macOS 启动器

1. 把 PGRLauncher.app 拖进 Applications 文件夹。
2. 首次打开如提示「无法验证开发者」，请到
   系统设置 → 隐私与安全性 → 仍要打开。
3. 键位映射需要在 系统设置 → 隐私与安全性 → 辅助功能 中授权。
4. 首次使用请先点「准备 Wine 环境」，随后下载游戏（国服约 68.8GB）。
5. 数据目录：~/Library/Application Support/PGRLauncher
   游戏目录：~/Games/PGR（可在设置中修改）

本项目为社区作品，与库洛游戏 / Kuro Games 无关。
EOF

hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "✅ 打包完成: $DMG ($(du -h "$DMG" | cut -f1))"
