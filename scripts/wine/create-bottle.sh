#!/bin/bash
# create-bottle.sh — 创建 / 复用 Wine 容器（WINEPREFIX）并做基础校验
#
# 关键坑（本机实测）：
#   wine 在创建 prefix 时会检查「prefix 的父目录是否属于当前用户」，/tmp 属于 root，
#   所以直接 `WINEPREFIX=/tmp/xxx wineboot -u` 会报：
#     wine: '/tmp' is not owned by you, refusing to create a configuration directory there
#   必须先用 mkdir -p 把 prefix 目录本身建出来，且父目录属于当前用户
#   （推荐 ~/Library/Application Support/PGRLauncher/Bottle）。
#
# 做的事：
#   1. mkdir -p ${PREFIX}（必须）
#   2. wineboot -u 初始化（首次约 20–60 秒）
#   3. 设置 Windows 版本为 win10（部分游戏拒绝 win7）
#   4. 把 DXMT 的 winemetal.dll / nvngx.dll 复制进 drive_c/windows/system32
#   5. 校验：wine cmd /c ver、wineserver -w、目录结构
#
# 用法：create-bottle.sh [--prefix DIR] [--force]
# 环境变量：PGR_WINE_DIR / PGR_PREFIX / PGR_LOG_DIR / PGR_DXMT_DIR

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-common.sh"

PREFIX_TARGET="$PREFIX"
FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX_TARGET="$2"; shift 2 ;;
    --force)  FORCE=1; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

export WINEPREFIX="$PREFIX_TARGET"
export WINEDEBUG="${PGR_WINE_DEBUG:-fixme-all,err-unwind}"
mkdirs "$PREFIX_TARGET" "$LOG_DIR"

# 若父目录属于 root（如 /tmp），wine 会拒绝「创建」配置目录；
# 只要先把 prefix 目录本身 mkdir 出来，wineboot 就能继续（已实测），这里只做提示。
parent="$(dirname "$PREFIX_TARGET")"
if [ "$(stat -f%u "$parent")" != "$(id -u)" ]; then
  warn "prefix 父目录 $parent 不属于当前用户（如 /tmp）；已预先 mkdir 出 prefix 目录，wine 仍可正常初始化，但更推荐 ~/Library/Application Support/PGRLauncher/Bottle"
fi

assert_wine_runtime "$WINE_DIR"

if [ -f "$PREFIX_TARGET/system.reg" ] && [ "$FORCE" -eq 0 ]; then
  log "容器已存在，复用：$PREFIX_TARGET"
else
  log "创建 wine 容器：${PREFIX_TARGET}（首次约 20–60 秒）"
  "$WINE_DIR/bin/wineboot" -u > "$LOG_DIR/wineboot.log" 2>&1 || {
    tail -20 "$LOG_DIR/wineboot.log" >&2
    die "wineboot -u 失败，日志：$LOG_DIR/wineboot.log"
  }
fi

log "设置 Windows 版本为 win10"
# 不要用 `winecfg -v win10`：winecfg 会打开 GUI 并阻塞（无人值守脚本会卡死）。
# 直接写注册表更可靠：
"$WINE_DIR/bin/wine" reg add "HKCU\\Software\\Wine" /v Version /t REG_SZ /d win10 /f \
  > "$LOG_DIR/winecfg.log" 2>&1 || warn "设置 Windows 版本失败（可手动 winecfg 设置 win10）"

# DXMT DLL 同步到 prefix system32（wine 树里已装好的前提下）
SYS32="$PREFIX_TARGET/drive_c/windows/system32"
if [ -d "$SYS32" ]; then
  DXMT_SRC="$DXMT_DIR/$DXMT_ARCHIVE_ROOT/x86_64-windows"
  for f in winemetal.dll nvngx.dll; do
    if [ -f "$DXMT_SRC/$f" ]; then
      cp -f "$DXMT_SRC/$f" "$SYS32/$f"
      log "  $f → drive_c/windows/system32/"
    else
      warn "未找到 DXMT 的 ${f}（未安装 DXMT？可先跑 scripts/wine/dxmt-install.sh）"
    fi
  done
else
  die "容器结构异常：缺少 $SYS32"
fi

# 校验
log "校验容器：wine cmd /c ver"
VER_OUT="$("$WINE_DIR/bin/wine" cmd /c ver 2>&1 | tr -d '\r')"
echo "$VER_OUT" | grep -qi "Windows" || die "wine cmd /c ver 失败：$VER_OUT"
log "  $(echo "$VER_OUT" | grep -i 'Windows' | head -1)"

log "校验容器：wineserver -w"
"$WINE_DIR/bin/wineserver" -w || die "wineserver -w 失败"

log "容器已就绪：$PREFIX_TARGET"
log "默认 Retina 开启："
PGR_PREFIX="$PREFIX_TARGET" bash "$SCRIPT_DIR/set-retina.sh" --on || warn "Retina 设置失败（可稍后手动执行 set-retina.sh）"
