#!/usr/bin/env bash
# Package PGRLauncher.app into a macOS installer .pkg (component + distribution).
#
# Usage: ./scripts/package-pkg.sh
# Output: build/PGRLauncher.pkg  (installs /Applications/战双启动器.app)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/PGRLauncher.app"
OUT_PKG="$ROOT/build/PGRLauncher.pkg"
WORK="$ROOT/build/pkg-work"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0.1.0)"
APP_NAME="战双启动器.app"
PKG_ID="local.pgr.launcher"
COMPONENT="$WORK/PGRLauncher-component.pkg"

if [ ! -d "$APP" ]; then
  echo "缺少 $APP，请先运行 ./scripts/build.sh" >&2
  exit 1
fi
if ! command -v pkgbuild >/dev/null || ! command -v productbuild >/dev/null; then
  echo "缺少 pkgbuild/productbuild（请安装 Xcode Command Line Tools）" >&2
  exit 1
fi

rm -rf "$WORK" "$OUT_PKG"
mkdir -p "$WORK/payload/Applications" "$WORK/resources"

# ---- Payload: /Applications/战双启动器.app ---------------------------------
ditto "$APP" "$WORK/payload/Applications/$APP_NAME"
# Make sure the app is ad-hoc signed as part of the payload (kmutil/Gatekeeper friendliness).
codesign --force --deep --sign - "$WORK/payload/Applications/$APP_NAME" >/dev/null 2>&1 || true

# ---- Installer UI text (Chinese) -------------------------------------------
cat > "$WORK/resources/welcome.html" <<'EOF'
<!DOCTYPE html>
<html><head><meta charset="utf-8"><style>
body { font: 13px -apple-system, "PingFang SC", sans-serif; color:#1d1d1f; margin:0; }
h2 { font-size: 16px; margin: 0 0 8px; }
p  { margin: 6px 0; line-height: 1.5; }
ul { margin: 6px 0 6px 18px; padding: 0; }
li { margin: 3px 0; }
.note { color:#6e6e73; font-size:12px; }
code { font-family: ui-monospace, Menlo, monospace; font-size:12px; }
</style></head><body>
<h2>战双启动器 · PGR Launcher for macOS</h2>
<p>类似 Yaagl HSR 的《战双帕弥什》macOS 启动器：在 Apple Silicon Mac 上通过 Wine 运行 Windows 客户端，
支持官方 CDN 直连下载/更新、Retina 高清渲染与键盘映射。</p>
<ul>
  <li>安装位置：<code>/Applications/战双启动器.app</code></li>
  <li>首次打开请先点击「准备 Wine 环境」（约 480MB，下载并校验 Wine 11 + FineWine + DXMT）</li>
  <li>随后点击「下载游戏」（国服约 68.8GB，支持断点续传与逐文件 MD5 校验）</li>
  <li>需要 macOS 14 或更高版本 / Apple Silicon（M 系列）</li>
</ul>
<p class="note">本项目为社区作品，与库洛游戏 / Kuro Games 无关。使用前请阅读仓库 README 中的免责声明。</p>
</body></html>
EOF

cat > "$WORK/resources/readme.html" <<'EOF'
<!DOCTYPE html>
<html><head><meta charset="utf-8"><style>
body { font: 13px -apple-system, "PingFang SC", sans-serif; color:#1d1d1f; margin:0; }
h3 { font-size: 14px; margin: 12px 0 6px; }
p, li { margin: 5px 0; line-height: 1.5; }
ul { margin: 4px 0 4px 18px; padding: 0; }
code { font-family: ui-monospace, Menlo, monospace; font-size:12px; }
</style></head><body>
<h3>安装后第一次使用</h3>
<ol>
  <li>打开「战双启动器」（首次打开如提示无法验证开发者：右键 → 打开，或到「系统设置 → 隐私与安全性 → 仍要打开」）。</li>
  <li>在「设置」里选择游戏服务器（默认「国服官服」；另有国服 B 服、国际服）。</li>
  <li>点击「准备 Wine 环境」：下载 Wine 11 + FineWine 兼容模块 + DXMT（共约 480MB）。</li>
  <li>点击「下载游戏」：从官方 CDN 直接下载（国服约 68.8GB）。</li>
  <li>下载完成后点击「启动游戏」。首次启动游戏会自动做一次官方自校验/自更新，属正常现象。</li>
</ol>
<h3>数据目录</h3>
<ul>
  <li>运行时/容器/日志/配置：<code>~/Library/Application Support/PGRLauncher</code></li>
  <li>游戏安装目录：<code>~/Games/PGR</code>（可在设置中修改）</li>
</ul>
<h3>键盘映射</h3>
<p>需要在「系统设置 → 隐私与安全性 → 辅助功能」中授权本 App，游戏运行时映射生效，退出即停止。</p>
<h3>卸载</h3>
<p>把「战双启动器.app」从 Applications 拖进废纸篓，并删除上面两个数据目录即可。</p>
</body></html>
EOF

cat > "$WORK/resources/license.html" <<'EOF'
<!DOCTYPE html>
<html><head><meta charset="utf-8"><style>
body { font: 12px -apple-system, "PingFang SC", sans-serif; color:#1d1d1f; margin:0; }
p { margin: 6px 0; line-height: 1.5; }
</style></head><body>
<p>本安装包仅包含启动器程序本身，不包含《战双帕弥什》游戏本体、Wine 运行时或任何第三方游戏资源。</p>
<p>启动器为社区爱好者作品，与库洛游戏 / Kuro Games 无关。使用本项目可能违反游戏服务条款，存在账号风险，请自行评估。Wine、DXMT、FineWine 及相关补丁版权归各自作者所有。</p>
</body></html>
EOF

# Remove any leftover ._ AppleDouble files / extended attributes before packaging.
xattr -cr "$WORK/payload" 2>/dev/null || true

# ---- Component package ------------------------------------------------------
pkgbuild \
  --root "$WORK/payload" \
  --identifier "$PKG_ID" \
  --version "$VERSION" \
  --install-location "/" \
  --ownership recommended \
  "$COMPONENT" >/dev/null

# ---- Distribution XML ------------------------------------------------------
cat > "$WORK/Distribution.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>战双启动器</title>
  <organization>local.pgr.launcher</organization>
  <options hostArchitectures="arm64" customize="never" require-scripts="false"/>
  <domains enable_localSystem="true"/>
  <welcome file="welcome.html" mime-type="text/html"/>
  <readme file="readme.html" mime-type="text/html"/>
  <license file="license.html" mime-type="text/html"/>
  <pkg-ref id="$PKG_ID"/>
  <choices-outline>
    <line choice="default">
      <line choice="$PKG_ID"/>
    </line>
  </choices-outline>
  <choice id="default"/>
  <choice id="$PKG_ID" visible="false">
    <pkg-ref id="$PKG_ID"/>
  </choice>
  <pkg-ref id="$PKG_ID" version="$VERSION" onConclusion="none">PGRLauncher-component.pkg</pkg-ref>
</installer-gui-script>
EOF

productbuild \
  --distribution "$WORK/Distribution.xml" \
  --resources "$WORK/resources" \
  --package-path "$WORK" \
  "$OUT_PKG" >/dev/null

rm -rf "$WORK"
echo "✅ PKG 打包完成: $OUT_PKG ($(du -h "$OUT_PKG" | cut -f1))"
echo "   version: $VERSION  →  /Applications/$APP_NAME"
