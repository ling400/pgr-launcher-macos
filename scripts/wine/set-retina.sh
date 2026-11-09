#!/bin/bash
# set-retina.sh — 配置 Wine Mac Driver 的 Retina / 按键映射 / NVIDIA 扩展注册表
#
# Retina 相关（Yaagl 使用同样的键值）：
#   HKCU\Software\Wine\Mac Driver
#     RetinaMode        REG_SZ  y|n     ← y：按物理像素渲染（画面清晰，性能开销更大）
#                                          n：按逻辑分辨率渲染（由 macOS 放大，性能更好）
#     LeftCommandIsCtrl REG_SZ  y|n     ← 左 Command 键当 Ctrl 用（Mac 上顺手）
#
# DXMT 的 NVAPI/NVNGX 扩展（DXMT_ENABLE_NVEXT=1 时 Yaagl 会写入，供 DLSS/NGX 探测）：
#   HKLM\SOFTWARE\NVIDIA Corporation\Global            {41FCC608-8496-4DEF-B43E-7D9BD675A6FF} REG_BINARY 1
#   HKLM\SYSTEM\ControlSet001\Services\nvlddmkm        同上
#   HKLM\SOFTWARE\NVIDIA Corporation\Global\NGXCore    FullPath REG_SZ "C:\Windows\System32"
#
# 用法：
#   set-retina.sh --on | --off | --query
#   可选：--prefix DIR  --left-cmd on|off  --nv-ext on|off
# 环境变量：PGR_WINE_DIR / PGR_PREFIX

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-common.sh"

PREFIX_TARGET="$PREFIX"
MODE=""
LEFT_CMD=""
NV_EXT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --on)   MODE="y"; shift ;;
    --off)  MODE="n"; shift ;;
    --query) MODE="query"; shift ;;
    --prefix) PREFIX_TARGET="$2"; shift 2 ;;
    --left-cmd) LEFT_CMD="$2"; shift 2 ;;
    --nv-ext) NV_EXT="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done
[ -n "$MODE" ] || die "必须指定 --on / --off / --query 之一"

export WINEPREFIX="$PREFIX_TARGET"
export WINEDEBUG="${PGR_WINE_DEBUG:--all}"
assert_wine_runtime "$WINE_DIR"
[ -f "$PREFIX_TARGET/system.reg" ] || die "容器未初始化：${PREFIX_TARGET}（先跑 create-bottle.sh）"

wreg() { "$WINE_DIR/bin/wine" reg "$@" 2>&1 | grep -viE "^[0-9a-f]{4}:(fixme|err):" || true; }

case "$MODE" in
  query)
    log "当前 Retina / Mac Driver 配置："
    wreg query "HKCU\\Software\\Wine\\Mac Driver"
    ;;
  y|n)
    log "设置 RetinaMode=$MODE"
    wreg add "HKCU\\Software\\Wine\\Mac Driver" /v RetinaMode /t REG_SZ /d "$MODE" /f
    ;;
esac

if [ -n "$LEFT_CMD" ]; then
  case "$LEFT_CMD" in on) v="y" ;; off) v="n" ;; *) die "--left-cmd 只接受 on|off" ;; esac
  log "设置 LeftCommandIsCtrl=$v"
  wreg add "HKCU\\Software\\Wine\\Mac Driver" /v LeftCommandIsCtrl /t REG_SZ /d "$v" /f
fi

if [ -n "$NV_EXT" ]; then
  case "$NV_EXT" in
    on)
      log "写入 DXMT NVIDIA 扩展注册表（DXMT_ENABLE_NVEXT 配套）"
      wreg add "HKLM\\SOFTWARE\\NVIDIA Corporation\\Global" /v "{41FCC608-8496-4DEF-B43E-7D9BD675A6FF}" /t REG_BINARY /d 1 /f
      wreg add "HKLM\\SYSTEM\\ControlSet001\\Services\\nvlddmkm" /v "{41FCC608-8496-4DEF-B43E-7D9BD675A6FF}" /t REG_BINARY /d 1 /f
      wreg add "HKLM\\SOFTWARE\\NVIDIA Corporation\\Global\\NGXCore" /v FullPath /t REG_SZ /d "C:\\Windows\\System32" /f
      ;;
    off)
      log "删除 DXMT NVIDIA 扩展注册表"
      wreg delete "HKLM\\SOFTWARE\\NVIDIA Corporation\\Global" /v "{41FCC608-8496-4DEF-B43E-7D9BD675A6FF}" /f
      wreg delete "HKLM\\SYSTEM\\ControlSet001\\Services\\nvlddmkm" /v "{41FCC608-8496-4DEF-B43E-7D9BD675A6FF}" /f
      wreg delete "HKLM\\SOFTWARE\\NVIDIA Corporation\\Global\\NGXCore" /v FullPath /f
      ;;
    *) die "--nv-ext 只接受 on|off" ;;
  esac
fi

if [ "$MODE" != "query" ]; then
  log "回读验证："
  wreg query "HKCU\\Software\\Wine\\Mac Driver" /v RetinaMode
fi
"$WINE_DIR/bin/wineserver" -w 2>/dev/null || true
log "完成（RetinaMode 在下次启动 wine 程序时生效；对 DXMT 渲染分辨率的影响见 docs/WINE-RUNTIME.md）"
