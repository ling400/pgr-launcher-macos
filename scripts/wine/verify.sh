#!/bin/bash
# verify.sh — 一条命令体检本机 Wine 运行时 / 容器 / DXMT / FineWine / Retina 状态
#
# 用法：scripts/wine/verify.sh [--prefix DIR] [--run-smoke]
#   --run-smoke  额外跑一次 `wine cmd /c ver` + `wineserver -w`（会启动 wineserver，约 5–10 秒）
#
# 输出参考（本机 2026-11 实测通过的样子）：
#   macOS 27.3 (26C5035r) arm64
#   rosetta       : installed / not found
#   wine          : wine-11.0 (Mach-O x86_64)
#   dxmt          : d3d11.dll synced (dxmt build)  winemetal.so present
#   finewine      : v1.4.3 (CrossOver 26.3.0) modules in place
#   prefix        : initialized (windows 10.0.19045)
#   retina        : RetinaMode=y

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-common.sh"

PREFIX_TARGET="$PREFIX"
RUN_SMOKE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX_TARGET="$2"; shift 2 ;;
    --run-smoke) RUN_SMOKE=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

FAIL=0
ok()   { printf '  \033[1;32mOK\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; FAIL=1; }
info() { printf '       %s\n' "$*"; }

echo "== 系统 =="
echo "  $(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion)) $(uname -m)"
if [ -f /Library/Apple/usr/share/rosetta/rosetta ] || /usr/bin/pgrep -q oahd 2>/dev/null; then
  ok "Rosetta 2 已安装"
else
  bad "未检测到 Rosetta 2（x86_64 wine 需要：softwareupdate --install-rosetta --agree-to-license）"
fi

echo "== Wine 运行时 =="
if [ -x "$WINE_DIR/bin/wine" ]; then
  VER="$(wine_version "$WINE_DIR")"
  ARCHINFO="$(file -b "$WINE_DIR/bin/wine" | head -1)"
  ok "wine: $VER"
  info "$ARCHINFO"
  info "路径: $WINE_DIR"
else
  bad "wine 未安装：$WINE_DIR/bin/wine（跑 scripts/wine/install-runtime.sh）"
fi

echo "== DXMT 0.80 =="
WIN_LIB="$WINE_DIR/lib/wine/x86_64-windows"
UNIX_LIB="$WINE_DIR/lib/wine/x86_64-unix"
DXMT_SRC="$DXMT_DIR/$DXMT_ARCHIVE_ROOT/x86_64-windows"
for f in d3d11.dll dxgi.dll d3d10core.dll winemetal.dll; do
  if [ -f "$WIN_LIB/$f" ] && { [ ! -f "$DXMT_SRC/$f" ] || [ "$(file_size "$WIN_LIB/$f")" -eq "$(file_size "$DXMT_SRC/$f")" ]; }; then
    ok "$f = DXMT 版本（$(file_size "$WIN_LIB/$f") bytes，原 wine 版已备份 .bak）"
  else
    bad "$f 未安装/不匹配（lib/wine/x86_64-windows/）"
  fi
done
[ -f "$UNIX_LIB/winemetal.so" ] && ok "winemetal.so 已安装（lib/wine/x86_64-unix/）" || bad "缺少 winemetal.so"
[ -f "$WIN_LIB/nvngx.dll" ] && info "nvngx.dll 已安装（DXMT_ENABLE_NVEXT 用，可选）"

echo "== FineWine 兼容模块（必须） =="
if [ -f "$RUNTIME_DIR/FineWine.version" ]; then
  ok "FineWine 标记：$(tr '\n' ' ' < "$RUNTIME_DIR/FineWine.version")"
else
  bad "缺少 $RUNTIME_DIR/FineWine.version（未安装 FineWine）"
fi
for f in kernel32.dll dwmapi.dll ntoskrnl.exe wineboot.exe rundll32.exe lsass.exe; do
  [ -f "$WIN_LIB/$f" ] || bad "缺少 FineWine 模块 lib/wine/x86_64-windows/$f"
done
for f in ntdll.so winemac.so; do
  [ -f "$UNIX_LIB/$f" ] || bad "缺少 FineWine 模块 lib/wine/x86_64-unix/$f"
done
ok "windows/unix 模块检查完成"
if [ -x "$WINE_DIR/bin/wineserver" ]; then
  ok "wineserver 可执行：$("$WINE_DIR/bin/wineserver" --version 2>&1 | head -1)"
else
  bad "wineserver 不可执行（FineWine 解压后忘记 chmod 755？）"
fi

echo "== Wine 容器 =="
if [ -f "$PREFIX_TARGET/system.reg" ] && [ -d "$PREFIX_TARGET/drive_c/windows/system32" ]; then
  ok "已初始化：$PREFIX_TARGET"
  for f in winemetal.dll nvngx.dll; do
    [ -f "$PREFIX_TARGET/drive_c/windows/system32/$f" ] && info "system32/$f 已存在" || info "system32/$f 缺失（可选）"
  done
else
  bad "容器未初始化：${PREFIX_TARGET}（跑 scripts/wine/create-bottle.sh）"
fi

if [ "$RUN_SMOKE" -eq 1 ] && [ -x "$WINE_DIR/bin/wine" ] && [ -f "$PREFIX_TARGET/system.reg" ]; then
  echo "== 冒烟测试 =="
  export WINEPREFIX="$PREFIX_TARGET" WINEDEBUG="-all"
  OUT="$("$WINE_DIR/bin/wine" cmd /c ver 2>&1 | tr -d '\r')"
  echo "$OUT" | grep -qi Windows && ok "wine cmd /c ver: $(echo "$OUT" | grep -i Windows | head -1)" || bad "wine cmd /c ver 失败"
  "$WINE_DIR/bin/wineserver" -w 2>/dev/null && ok "wineserver -w 正常" || bad "wineserver -w 失败"
  RET=$("$WINE_DIR/bin/wine" reg query "HKCU\\Software\\Wine\\Mac Driver" /v RetinaMode 2>/dev/null | grep -i RetinaMode | awk '{print $NF}' || true)
  [ -n "$RET" ] && ok "RetinaMode=$RET" || info "RetinaMode 未设置"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "结论：运行时状态正常 ✅"
else
  echo "结论：存在问题 ❌（见上面 FAIL 项）"
  exit 1
fi
