#!/bin/bash
# dxmt-install.sh — 把 DXMT 0.80 安装进 wine 树（并可同步到 wine prefix 的 system32）
#
# 参考 Yaagl（src/clients/mhy/patch.ts）的做法：
#   DXMT_FILES = d3d10core.dll d3d11.dll dxgi.dll
#     → <wine>/lib/wine/x86_64-windows/   （覆盖 wine 自带的同名 builtin，原文件备份 .bak）
#   winemetal.dll → <wine>/lib/wine/x86_64-windows/
#   winemetal.so  → <wine>/lib/wine/x86_64-unix/     （winemetal.dll 的 unix 侧实现，走 Metal）
#   nvngx.dll     → <wine>/lib/wine/x86_64-windows/  （DXMT_ENABLE_NVEXT=1 时给 DLSS/NVAPI 用）
#   如果给了 --prefix：winemetal.dll / nvngx.dll 再复制到 prefix 的
#   drive_c/windows/system32（DLL 搜索路径里 native 优先，保证一定被加载）
#
# 用法：dxmt-install.sh [--wine-dir DIR] [--dxmt-dir DIR] [--prefix DIR] [--restore]
# 环境变量：PGR_WINE_DIR / PGR_DXMT_DIR / PGR_PREFIX
#   --restore：从 .bak 还原 DXMT 覆盖过的 wine 自带 DLL

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-common.sh"

WINE_TARGET="$WINE_DIR"
DXMT_SRC="$DXMT_DIR/$DXMT_ARCHIVE_ROOT"
PREFIX_TARGET="${PREFIX:-}"
RESTORE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --wine-dir) WINE_TARGET="$2"; shift 2 ;;
    --dxmt-dir) DXMT_SRC="$2/$DXMT_ARCHIVE_ROOT"; shift 2 ;;
    --prefix)   PREFIX_TARGET="$2"; shift 2 ;;
    --restore)  RESTORE=1; shift ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

WIN_LIB="$WINE_TARGET/lib/wine/x86_64-windows"
UNIX_LIB="$WINE_TARGET/lib/wine/x86_64-unix"
DXMT_WINDOWS_FILES=(d3d10core.dll d3d11.dll dxgi.dll)
DXMT_EXTRA_FILES=(winemetal.dll nvngx.dll)

[ -d "$WIN_LIB" ] || die "wine 目录不正确（缺少 ${WIN_LIB}）"
[ -d "$UNIX_LIB" ] || die "wine 目录不正确（缺少 ${UNIX_LIB}）"

if [ "$RESTORE" -eq 1 ]; then
  log "从 .bak 还原 DXMT 覆盖的 wine DLL"
  for f in "${DXMT_WINDOWS_FILES[@]}" winemetal.dll nvngx.dll; do
    if [ -f "$WIN_LIB/$f.bak" ]; then mv -f "$WIN_LIB/$f.bak" "$WIN_LIB/$f"; log "  restored $f"; fi
  done
  [ -f "$UNIX_LIB/winemetal.so.bak" ] && { mv -f "$UNIX_LIB/winemetal.so.bak" "$UNIX_LIB/winemetal.so"; log "  restored winemetal.so"; }
  [ -n "$PREFIX_TARGET" ] && for f in winemetal.dll nvngx.dll; do
    [ -f "$PREFIX_TARGET/drive_c/windows/system32/$f.bak" ] && mv -f "$PREFIX_TARGET/drive_c/windows/system32/$f.bak" "$PREFIX_TARGET/drive_c/windows/system32/$f"
  done
  exit 0
fi

[ -d "$DXMT_SRC/x86_64-windows" ] || die "DXMT 解压目录不正确：$DXMT_SRC/x86_64-windows 不存在"
[ -f "$DXMT_SRC/x86_64-unix/winemetal.so" ] || die "DXMT 归档缺少 x86_64-unix/winemetal.so"

log "安装 DXMT → $WINE_TARGET"
for f in "${DXMT_WINDOWS_FILES[@]}"; do
  [ -f "$DXMT_SRC/x86_64-windows/$f" ] || die "DXMT 归档缺少 $f"
  backup_and_copy "$DXMT_SRC/x86_64-windows/$f" "$WIN_LIB/$f"
  log "  $f → lib/wine/x86_64-windows/"
done
for f in "${DXMT_EXTRA_FILES[@]}"; do
  [ -f "$DXMT_SRC/x86_64-windows/$f" ] || continue
  backup_and_copy "$DXMT_SRC/x86_64-windows/$f" "$WIN_LIB/$f"
  log "  $f → lib/wine/x86_64-windows/"
done
backup_and_copy "$DXMT_SRC/x86_64-unix/winemetal.so" "$UNIX_LIB/winemetal.so"
log "  winemetal.so → lib/wine/x86_64-unix/"

if [ -n "$PREFIX_TARGET" ]; then
  SYS32="$PREFIX_TARGET/drive_c/windows/system32"
  if [ -d "$SYS32" ]; then
    for f in "${DXMT_EXTRA_FILES[@]}"; do
      [ -f "$DXMT_SRC/x86_64-windows/$f" ] || continue
      cp -f "$DXMT_SRC/x86_64-windows/$f" "$SYS32/$f"
      log "  $f → drive_c/windows/system32/"
    done
  else
    warn "prefix 尚未初始化，跳过 system32 复制：$SYS32"
  fi
fi

# 校验：文件大小应与 DXMT 包内一致
for f in "${DXMT_WINDOWS_FILES[@]}" "${DXMT_EXTRA_FILES[@]}"; do
  [ -f "$DXMT_SRC/x86_64-windows/$f" ] || continue
  a=$(file_size "$DXMT_SRC/x86_64-windows/$f"); b=$(file_size "$WIN_LIB/$f")
  [ "$a" -eq "$b" ] || die "安装校验失败：$f 大小 $b != $a"
done
log "DXMT 安装完成（原 wine DLL 已备份为 *.bak，可用 --restore 还原）"
