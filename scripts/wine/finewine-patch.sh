#!/bin/bash
# finewine-patch.sh — 把 FineWine（CrossOver 26.3 + DW-Proton ACE/Rosetta 补丁）模块覆盖到 wine 树
#
# 为什么必须装：本机实测，纯 yaagl wine-11.0 上运行《战双帕弥什》PGR.exe，
# 在加载 PGRBase.dll 后约 8ms 就报
#   err:virtual:virtual_setup_exception stack overflow 1600 bytes addr 0x6ffffff78d0f
# 并退出。覆盖 FineWine 模块后 PGRBase 保护层可正常初始化，游戏能继续进入 Unity 引擎。
# （FineWine 来自 stoicswe/Endfield_FineWine v1.4.3，基于 CrossOver 26.3.0 源码 + dw-proton
#   的 ACE 补丁：修复 ACE-CORE DriverEntry 对「返回地址是否内核地址」的检查；并加入
#   lsass.exe stub 供反作弊使用。）
#
# 覆盖映射（与 FineWine 发布说明一致）：
#   <wine>/lib/wine/x86_64-windows/  kernel32.dll dwmapi.dll ntoskrnl.exe wineboot.exe rundll32.exe lsass.exe
#   <wine>/lib/wine/x86_64-unix/     ntdll.so winemac.so
#   <wine>/bin/wineserver            替换（解压后需 chmod 755；版本串同为 Wine 11.0，可兼容）
#   <wine>/lib/libMoltenVK.dylib     默认「不覆盖」！FineWine 自带的 MoltenVK 1.4.2 在本机
#                                    macOS 27.3 + Rosetta 2 上会触发
#                                      rosetta error: Attachment of code signature supplement failed
#                                      /var/db/oah/.../libMoltenVK.dylib.aot
#                                    导致 wineboot 卡死在 rundll32 setupapi（实测 3/3 复现）。
#                                    wine 包自带的 MoltenVK 1.4.1 正常（2/2 通过）。
#                                    只有改用 D3DMetal 后端时才需要 --with-moltenvk 手动覆盖。
#
# 用法：finewine-patch.sh [--wine-dir DIR] [--modules-dir DIR] [--restore]
# 环境变量：PGR_WINE_DIR / PGR_FINEWINE_DIR

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-common.sh"

WINE_TARGET="${WINE_DIR}"
MODULES_SRC="${FINEWINE_DIR}/${FINEWINE_ARCHIVE_ROOT}"
RESTORE=0
WITH_MOLTENVK=0

while [ $# -gt 0 ]; do
  case "$1" in
    --wine-dir)    WINE_TARGET="$2"; shift 2 ;;
    --modules-dir) MODULES_SRC="$2"; shift 2 ;;
    --restore)     RESTORE=1; shift ;;
    --with-moltenvk) WITH_MOLTENVK=1; shift ;;
    -h|--help)     sed -n '2,25p' "$0"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

WIN_LIB="$WINE_TARGET/lib/wine/x86_64-windows"
UNIX_LIB="$WINE_TARGET/lib/wine/x86_64-unix"
WINDOWS_MODULES=(kernel32.dll dwmapi.dll ntoskrnl.exe wineboot.exe rundll32.exe lsass.exe)
UNIX_MODULES=(ntdll.so winemac.so)

[ -d "$WIN_LIB" ] || die "wine 目录不正确（缺少 ${WIN_LIB}）"
[ -d "$UNIX_LIB" ] || die "wine 目录不正确（缺少 ${UNIX_LIB}）"

if [ "$RESTORE" -eq 1 ]; then
  log "从 .bak 还原 FineWine 覆盖的模块"
  for f in "${WINDOWS_MODULES[@]}"; do
    [ -f "$WIN_LIB/$f.bak" ] && { mv -f "$WIN_LIB/$f.bak" "$WIN_LIB/$f"; log "  restored $f"; }
  done
  for f in "${UNIX_MODULES[@]}"; do
    [ -f "$UNIX_LIB/$f.bak" ] && { mv -f "$UNIX_LIB/$f.bak" "$UNIX_LIB/$f"; log "  restored $f"; }
  done
  [ -f "$WINE_TARGET/bin/wineserver.bak" ] && { mv -f "$WINE_TARGET/bin/wineserver.bak" "$WINE_TARGET/bin/wineserver"; log "  restored wineserver"; }
  [ -f "$WINE_TARGET/lib/libMoltenVK.dylib.bak" ] && mv -f "$WINE_TARGET/lib/libMoltenVK.dylib.bak" "$WINE_TARGET/lib/libMoltenVK.dylib"
  exit 0
fi

[ -d "$MODULES_SRC" ] || die "FineWine 模块目录不存在：${MODULES_SRC}（先跑 install-runtime.sh）"

# 先校验发布包自带的 SHA256SUMS（防止解压损坏）
if [ -f "$MODULES_SRC/SHA256SUMS" ]; then
  log "校验 FineWine SHA256SUMS"
  ( cd "$MODULES_SRC" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1 ) \
    || die "FineWine 模块 SHA256SUMS 校验失败（重新下载 ${FINEWINE_NAME}）"
fi

for f in "${WINDOWS_MODULES[@]}"; do
  [ -f "$MODULES_SRC/$f" ] || die "FineWine 包缺少 $f"
  backup_and_copy "$MODULES_SRC/$f" "$WIN_LIB/$f"
  log "  $f → lib/wine/x86_64-windows/"
done
for f in "${UNIX_MODULES[@]}"; do
  [ -f "$MODULES_SRC/$f" ] || die "FineWine 包缺少 $f"
  backup_and_copy "$MODULES_SRC/$f" "$UNIX_LIB/$f"
  log "  $f → lib/wine/x86_64-unix/"
done

# wineserver 解压后通常没有执行位，必须 chmod，否则 wine 完全无法启动
backup_and_copy "$MODULES_SRC/wineserver" "$WINE_TARGET/bin/wineserver"
chmod 755 "$WINE_TARGET/bin/wineserver"

if [ "$WITH_MOLTENVK" -eq 1 ] && [ -f "$MODULES_SRC/libMoltenVK.dylib" ]; then
  warn "覆盖 libMoltenVK.dylib（仅 D3DMetal 后端需要）。若 wineboot 卡死/出现 rosetta AOT 报错，请用 --restore 恢复 wine 自带版本"
  backup_and_copy "$MODULES_SRC/libMoltenVK.dylib" "$WINE_TARGET/lib/libMoltenVK.dylib"
  log "  libMoltenVK.dylib → lib/"
else
  log "  跳过 libMoltenVK.dylib（保留 wine 自带 1.4.1；本机 macOS 27 + Rosetta 下 FineWine 的 1.4.2 会导致 wineboot 卡死）"
fi

CROSSOVER_VERSION="$(cat "$MODULES_SRC/CROSSOVER_VERSION" 2>/dev/null | tr -d '\n\r' || true)"
cat > "${RUNTIME_DIR}/FineWine.version" <<EOF
version=$FINEWINE_VERSION
sha256=$FINEWINE_SHA256
crossover_version=${CROSSOVER_VERSION:-unknown}
installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

log "FineWine 模块覆盖完成（CrossOver ${CROSSOVER_VERSION:-?}，原文件已备份 .bak）"
log "  wineserver: $("$WINE_TARGET/bin/wineserver" --version 2>&1 | head -1)"
