#!/bin/bash
# run-game.sh — 用装好的 Wine 运行时启动《战双帕弥什》（PGR.exe）
#
# 启动环境变量完全对齐 Yaagl HSR 的 DXMT 启动方式
# （参考 yaagl-src/src/clients/mhy/hkrpg/program-launch-game.ts）：
#   WINEPREFIX            wine 容器
#   WINEMSYNC=1           CrossOver/FineWine 的 msync 同步（实测日志出现 "msync: up and running."）
#   DXMT_LOG_PATH         日志目录（DXMT 会写 PGR_d3d11.log / PGR_dxgi.log）
#   DXMT_CONFIG           d3d11.preferredMaxFrameRate / dxgi.customVendorId=10de / dxgi.customDeviceId=2684
#   DXMT_CONFIG_FILE      DXMT 配置文件路径
#   DXMT_ENABLE_NVEXT=1   启用 NVAPI/NVNGX 扩展
#   GST_PLUGIN_FEATURE_RANK=atdec:MAX,avdec_h264:MAX
#   MTL_HUD_ENABLED       Metal HUD（调试用）
#   LANG / LC_ALL         zh_CN.UTF-8（必须！见下方说明）
#   WINEDEBUG=-all         默认静音；排查问题用 --debug "+loaddll,+seh" 或 "-all,+seh,+timestamp"
#
# 编码（实测踩坑）：wine 的 ANSI codepage 由进程 locale 决定。
#   - 从终端继承 LANG=C.UTF-8 启动时，Wine 用 cp1252，游戏内 ANSI 文本（如隐私协议）显示为
#     「æX...」乱码；
#   - 显式设置 LANG=zh_CN.UTF-8 / LC_ALL=zh_CN.UTF-8 → Wine 用 cp936（GBK），中文正常。
#   截图对比：docs/screenshots/game-login.png（乱码）vs game-font-fixed.png（正常）。
#
# 用法：
#   scripts/wine/run-game.sh --game-dir "/path/to/Punishing Gray Raven" [选项]
#
# 选项：
#   --game-dir DIR        必填，包含 PGR.exe 的游戏根目录（cwd 必须是游戏根目录）
#   --prefix DIR          wine 容器（默认 $PGR_PREFIX 或 ~/Library/Application Support/PGRLauncher/Bottle）
#   --log-dir DIR         日志目录（默认 ~/Library/Application Support/PGRLauncher/logs）
#   --max-fps N           DXMT 限帧（0 = 不限）
#   --proxy URL           HTTP/HTTPS 代理（同时设置 HTTP_PROXY/HTTPS_PROXY）
#   --args "..."          传给 PGR.exe 的额外参数（如 "-force-vulkan" / "-force-d3d11"）
#   --debug "flags"       WINEDEBUG（默认 -all）
#   --monitor SECONDS     启动后监控 N 秒：每 5 秒截屏到 --shot-dir，并打印 PGR 进程状态
#   --shot-dir DIR        截图目录（默认与 --log-dir 相同）
#   --detach              启动后立即返回（不等待游戏退出）
#   --kill-server         结束时 wineserver -k 清理容器
#   --check               只做环境检查并打印将使用的命令，不启动
#
# 退出码：0 = 游戏正常退出或被 --monitor 正常结束；非 0 = wine 返回码 / 检查失败

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-common.sh"

GAME_DIR=""
PREFIX_TARGET="$PREFIX"
LOG_TARGET="$LOG_DIR"
SHOT_DIR=""
MAX_FPS="0"
PROXY=""
GAME_ARGS=""
DBG="${PGR_WINE_DEBUG:--all}"
MONITOR=0
DETACH=0
KILL_SERVER=0
CHECK_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --game-dir) GAME_DIR="$2"; shift 2 ;;
    --prefix)   PREFIX_TARGET="$2"; shift 2 ;;
    --log-dir)  LOG_TARGET="$2"; shift 2 ;;
    --shot-dir) SHOT_DIR="$2"; shift 2 ;;
    --max-fps)  MAX_FPS="$2"; shift 2 ;;
    --proxy)    PROXY="$2"; shift 2 ;;
    --args)     GAME_ARGS="$2"; shift 2 ;;
    --debug)    DBG="$2"; shift 2 ;;
    --monitor)  MONITOR="$2"; shift 2 ;;
    --detach)   DETACH=1; shift ;;
    --kill-server) KILL_SERVER=1; shift ;;
    --check)    CHECK_ONLY=1; shift ;;
    -h|--help)  sed -n '2,40p' "$0"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

[ -n "$GAME_DIR" ] || die "必须指定 --game-dir（包含 PGR.exe 的游戏根目录）"
[ -d "$GAME_DIR" ] || die "游戏目录不存在：$GAME_DIR"
[ -f "$GAME_DIR/PGR.exe" ] || die "游戏目录里没有 PGR.exe：$GAME_DIR"
assert_wine_runtime "$WINE_DIR"
[ -f "$PREFIX_TARGET/system.reg" ] || die "容器未初始化：${PREFIX_TARGET}（先跑 create-bottle.sh）"
mkdirs "$LOG_TARGET"; SHOT_DIR="${SHOT_DIR:-$LOG_TARGET}"; mkdirs "$SHOT_DIR" /tmp/dxmtlogs

STAMP="$(date +%Y%m%d-%H%M%S)"
GAME_LOG="$LOG_TARGET/game-$STAMP.log"
DXMT_CONF="$LOG_TARGET/dxmt.conf"

# DXMT 配置（Yaagl 同款）
DXMT_CONFIG_PARTS=()
[ "$MAX_FPS" -gt 0 ] 2>/dev/null && DXMT_CONFIG_PARTS+=("d3d11.preferredMaxFrameRate=$MAX_FPS")
DXMT_CONFIG_PARTS+=("dxgi.customVendorId=10de" "dxgi.customDeviceId=2684")
DXMT_CONFIG_VALUE=$(IFS=';'; echo "${DXMT_CONFIG_PARTS[*]}")
printf '%s\n' "${DXMT_CONFIG_PARTS[@]}" > "$DXMT_CONF"

export WINEPREFIX="$PREFIX_TARGET"
export WINEDEBUG="$DBG"
export WINEMSYNC=1
export DXMT_LOG_PATH="$LOG_TARGET"
export DXMT_CONFIG="$DXMT_CONFIG_VALUE"
export DXMT_CONFIG_FILE="$DXMT_CONF"
export DXMT_ENABLE_NVEXT=1
export GST_PLUGIN_FEATURE_RANK="atdec:MAX,avdec_h264:MAX"
export MTL_HUD_ENABLED="${MTL_HUD_ENABLED:-0}"
# 中文编码：必须，否则游戏内 ANSI 文本（隐私协议等）乱码（Wine 按 locale 选择 codepage）
export LANG="${PGR_LANG:-zh_CN.UTF-8}"
export LC_ALL="${PGR_LC_ALL:-zh_CN.UTF-8}"
if [ -n "$PROXY" ]; then export HTTP_PROXY="$PROXY" HTTPS_PROXY="$PROXY" http_proxy="$PROXY" https_proxy="$PROXY"; fi

log "运行时 : $WINE_DIR ($(wine_version "$WINE_DIR"))"
log "容器   : $PREFIX_TARGET"
log "游戏   : $GAME_DIR"
log "日志   : $GAME_LOG"
log "DXMT   : DXMT_CONFIG=$DXMT_CONFIG_VALUE  DXMT_LOG_PATH=$DXMT_LOG_PATH"
[ -n "$GAME_ARGS" ] && log "额外参数: $GAME_ARGS"

if [ "$CHECK_ONLY" -eq 1 ]; then
  log "环境检查通过（未启动游戏）"
  exit 0
fi

cd "$GAME_DIR"
# shellcheck disable=SC2086
"$WINE_DIR/bin/wine" PGR.exe $GAME_ARGS > "$GAME_LOG" 2>&1 &
WPID=$!
log "已启动 wine (pid=$WPID)，游戏日志：$GAME_LOG"

if [ "$MONITOR" -gt 0 ]; then
  log "监控 ${MONITOR}s：每 5 秒截屏到 $SHOT_DIR"
  i=0
  while [ "$i" -lt "$MONITOR" ]; do
    sleep 5; i=$((i + 5))
    ALIVE="yes"; kill -0 "$WPID" 2>/dev/null || ALIVE="no"
    SHOT="$SHOT_DIR/game-$STAMP-t${i}.png"
    screencapture -x "$SHOT" 2>/dev/null || true
    WINE_WIN=$(osascript -e 'tell application "System Events" to get name of every window of every process whose name contains "wine"' 2>/dev/null || true)
    log "  t=${i}s wine_alive=$ALIVE shot=$SHOT ${WINE_WIN:+windows=$WINE_WIN}"
    [ "$ALIVE" = "no" ] && break
  done
  kill -0 "$WPID" 2>/dev/null && { log "监控结束，PGR 仍在运行（pid=${WPID}）"; }
fi

if [ "$DETACH" -eq 1 ]; then
  log "--detach：不等待游戏退出。结束游戏：kill $WPID 或 wineserver -k（WINEPREFIX=${PREFIX_TARGET}）"
  exit 0
fi

set +e
wait "$WPID"; RC=$?
set -e
log "wine 退出码：${RC}（日志：${GAME_LOG}）"
log "DXMT 日志：$(ls -1 "$LOG_TARGET" | grep -iE 'd3d11|dxgi' | tr '\n' ' ')"
if [ "$KILL_SERVER" -eq 1 ]; then
  log "清理容器进程（wineserver -k）"
  "$WINE_DIR/bin/wineserver" -k 2>/dev/null || true
fi
exit "$RC"
