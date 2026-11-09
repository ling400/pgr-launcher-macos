#!/bin/bash
# install-runtime.sh — 下载 + SHA-256 校验 + 解压 + 安装 Wine 运行时
#
# 组成（本机 macOS 27.3 / arm64 实测）：
#   1. Wine 11.0 Crossover 11.0-1 signed（yaagl 打包，x86_64，经 Rosetta 2 运行）
#   2. FineWine 1.4.3 兼容模块（stoicswe/Endfield_FineWine，CrossOver 26.3 + DW-Proton ACE/Rosetta 补丁）
#      必须安装：缺了它 PGR.exe 加载 PGRBase.dll 后立刻
#      `err:virtual:virtual_setup_exception stack overflow` 崩溃。
#   3. DXMT 0.80 builtin（D3D10/11 → Metal 渲染层）
#
# 用法：
#   scripts/wine/install-runtime.sh [--force] [--no-finewine] [--no-dxmt] [--verify-only]
# 环境变量：
#   PGR_RUNTIME_DIR  运行时根目录（默认 ~/Library/Application Support/PGRLauncher/Runtime）
#   PGR_GH_MIRRORS   GitHub 镜像前缀（默认 "https://gh-proxy.com/ https://ghfast.top/"）
#   PGR_DOWNLOAD_CONCURRENCY  分段下载并发数（默认 8）
#
# 下载总量约 480MB（wine 456MB + finewine 4.3MB + dxmt 18.7MB），缓存在 Runtime/downloads，
# 重复执行为「校验后复用」，不会重复下载。

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-common.sh"

FORCE=0; NO_FINEWINE=0; NO_DXMT=0; VERIFY_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --no-finewine) NO_FINEWINE=1 ;;
    --no-dxmt) NO_DXMT=1 ;;
    --verify-only) VERIFY_ONLY=1 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) die "未知参数：$arg" ;;
  esac
done

is_macos_arm64 || die "本脚本只在 Apple Silicon (arm64) macOS 上验证过"
mkdirs "$RUNTIME_DIR" "$DOWNLOADS_DIR" "$LOG_DIR"

WINE_ARCHIVE="$DOWNLOADS_DIR/$WINE_NAME"
DXMT_ARCHIVE="$DOWNLOADS_DIR/$DXMT_NAME"
FINEWINE_ARCHIVE="$DOWNLOADS_DIR/$FINEWINE_NAME"

# ---- 0. Rosetta 检查（x86_64 wine 必需） ------------------------------------
if [ "$VERIFY_ONLY" -eq 0 ]; then
  if ! /usr/bin/pgrep -q oahd 2>/dev/null && [ ! -f /Library/Apple/usr/share/rosetta/rosetta ]; then
    warn "未检测到 Rosetta 2：wine 是 x86_64 Mach-O，需要先执行 softwareupdate --install-rosetta --agree-to-license"
  fi

  # ---- 1. 下载（带镜像回退与断点续传） --------------------------------------
  download_verified "$WINE_ARCHIVE" "$WINE_SHA256" "$WINE_SIZE" "$WINE_URL" "Wine 11.0-1 (Crossover, signed)"
  if [ "$NO_FINEWINE" -eq 0 ]; then
    download_verified "$FINEWINE_ARCHIVE" "$FINEWINE_SHA256" "$FINEWINE_SIZE" "$FINEWINE_URL" "FineWine 兼容模块 v$FINEWINE_VERSION"
  fi
  if [ "$NO_DXMT" -eq 0 ]; then
    download_verified "$DXMT_ARCHIVE" "$DXMT_SHA256" "$DXMT_SIZE" "$DXMT_URL" "DXMT 0.80 (builtin)"
  fi

  # ---- 2. 解压 wine --------------------------------------------------------
  if [ -x "$WINE_DIR/bin/wine" ] && [ "$FORCE" -eq 0 ]; then
    log "wine 已解压（$(wine_version "$WINE_DIR")），跳过解压"
  else
    log "解压 Wine → ${RUNTIME_DIR}（约 2.0GB，约 20–60 秒）"
    rm -rf "$WINE_DIR" "$RUNTIME_DIR/.wine-extract"
    mkdirs "$RUNTIME_DIR/.wine-extract"
    tar -xJf "$WINE_ARCHIVE" -C "$RUNTIME_DIR/.wine-extract"
    [ -d "$RUNTIME_DIR/.wine-extract/$WINE_ARCHIVE_ROOT" ] \
      || die "wine 归档结构异常：缺少 $WINE_ARCHIVE_ROOT/ 目录"
    mv "$RUNTIME_DIR/.wine-extract/$WINE_ARCHIVE_ROOT" "$WINE_DIR"
    rm -rf "$RUNTIME_DIR/.wine-extract"
    chmod 755 "$WINE_DIR/bin/wine" "$WINE_DIR/bin/wineserver" 2>/dev/null || true
    xattr -dr com.apple.quarantine "$WINE_DIR" 2>/dev/null || true
  fi
  assert_wine_runtime "$WINE_DIR"

  # ---- 3. 解压 DXMT -------------------------------------------------------
  if [ "$NO_DXMT" -eq 0 ]; then
    if [ -x "$WINE_DIR/bin/wine" ] && [ -f "$DXMT_DIR/$DXMT_ARCHIVE_ROOT/x86_64-windows/d3d11.dll" ] && [ "$FORCE" -eq 0 ]; then
      log "DXMT 已解压，跳过"
    else
      log "解压 DXMT → $DXMT_DIR"
      rm -rf "$DXMT_DIR"; mkdirs "$DXMT_DIR"
      tar -xzf "$DXMT_ARCHIVE" -C "$DXMT_DIR"
    fi
    # ---- 4. 安装 DXMT 到 wine 树 ------------------------------------------
    PGR_WINE_DIR="$WINE_DIR" PGR_DXMT_DIR="$DXMT_DIR" bash "$SCRIPT_DIR/dxmt-install.sh"
  fi

  # ---- 5. 覆盖 FineWine 兼容模块 ------------------------------------------
  if [ "$NO_FINEWINE" -eq 0 ]; then
    if [ -f "$RUNTIME_DIR/FineWine.version" ] && grep -q "$FINEWINE_VERSION" "$RUNTIME_DIR/FineWine.version" 2>/dev/null && [ "$FORCE" -eq 0 ]; then
      log "FineWine v$FINEWINE_VERSION 已安装，跳过"
    else
      if [ -d "$FINEWINE_DIR/$FINEWINE_ARCHIVE_ROOT" ] && [ "$FORCE" -eq 0 ]; then
        log "FineWine 模块已解压，跳过解压"
      else
        log "解压 FineWine → $FINEWINE_DIR"
        rm -rf "$FINEWINE_DIR"; mkdirs "$FINEWINE_DIR"
        tar -xzf "$FINEWINE_ARCHIVE" -C "$FINEWINE_DIR"
      fi
      PGR_WINE_DIR="$WINE_DIR" PGR_FINEWINE_DIR="$FINEWINE_DIR" bash "$SCRIPT_DIR/finewine-patch.sh"
    fi
  fi
fi

# ---- 6. 校验 & 落盘 marker -------------------------------------------------
assert_wine_runtime "$WINE_DIR"
VER="$(wine_version "$WINE_DIR")"
[ "$VER" = "wine-11.0" ] || warn "wine --version 输出为「${VER}」，预期 wine-11.0"

cat > "$RUNTIME_DIR/runtime-installed.txt" <<EOF
installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
wine=$WINE_NAME
wine_sha256=$WINE_SHA256
wine_version=$VER
finewine=$FINEWINE_VERSION
finewine_sha256=$FINEWINE_SHA256
dxmt=$DXMT_ARCHIVE_ROOT
dxmt_sha256=$DXMT_SHA256
EOF

log "运行时安装完成：$WINE_DIR"
log "  wine --version : $VER"
log "  FineWine       : v${FINEWINE_VERSION}（$(cat "$RUNTIME_DIR/FineWine.version" 2>/dev/null | tr '\n' ' ')）"
log "  DXMT           : $DXMT_DIR/$DXMT_ARCHIVE_ROOT"
log "  标记文件       : $RUNTIME_DIR/runtime-installed.txt"
log "下一步：scripts/wine/create-bottle.sh 创建 wine 容器"
