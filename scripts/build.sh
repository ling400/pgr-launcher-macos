#!/usr/bin/env bash
# Build PGRLauncher.app from Swift sources (no Xcode project required).
# Usage: ./scripts/build.sh [release|debug]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-release}"
APP="$ROOT/build/PGRLauncher.app"
TARGET="arm64-apple-macos14.0"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find "$ROOT/Sources" -name '*.swift' -print | sort)

if [ ${#SOURCES[@]} -eq 0 ]; then
  echo "错误: Sources/ 下没有 Swift 源文件" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

FLAGS=(-parse-as-library -swift-version 5 -target "$TARGET")
if [ "$MODE" = "release" ]; then
  FLAGS+=(-O)
else
  FLAGS+=(-Onone -g)
fi

echo "编译 ${#SOURCES[@]} 个 Swift 文件 ($MODE)…"
swiftc "${FLAGS[@]}" "${SOURCES[@]}" \
  -o "$APP/Contents/MacOS/PGRLauncher" \
  -framework SwiftUI \
  -framework AppKit \
  -framework Combine \
  -framework ApplicationServices \
  -framework CoreGraphics \
  -framework IOKit \
  -framework Security \
  -framework UniformTypeIdentifiers

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "✅ 构建完成: $APP"
