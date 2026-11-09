#!/bin/bash
# lib-common.sh — 共享常量与工具函数（被 scripts/wine/ 下其它脚本 source）
#
# 本文件记录了在本机（macOS 27.3 / Apple M6 / arm64）实测通过的运行时期版本、
# 官方 SHA-256 与 GitHub 镜像回退策略。
#
# 目录约定（与 App 的 RuntimeManager 保持一致）：
#   APP_SUPPORT = ~/Library/Application Support/PGRLauncher
#   RUNTIME_DIR = $APP_SUPPORT/Runtime
#     downloads/  下载缓存（wine/dxmt/finewine 三个归档）
#     wine/       解压后的 wine（bin/wine、lib/wine/...）
#     dxmt/       解压后的 DXMT（v0.80/...）
#     finewine/   解压后的 FineWine 模块（endfield-wine-modules/...）
#   PREFIX      = $APP_SUPPORT/Bottle   （WINEPREFIX）
#   LOGS        = $APP_SUPPORT/logs
#
# 所有路径都可以用环境变量覆盖：PGR_RUNTIME_DIR / PGR_PREFIX / PGR_LOG_DIR。

set -euo pipefail

APP_SUPPORT="${PGR_APP_SUPPORT:-$HOME/Library/Application Support/PGRLauncher}"
RUNTIME_DIR="${PGR_RUNTIME_DIR:-$APP_SUPPORT/Runtime}"
DOWNLOADS_DIR="$RUNTIME_DIR/downloads"
WINE_DIR="${PGR_WINE_DIR:-$RUNTIME_DIR/wine}"
DXMT_DIR="${PGR_DXMT_DIR:-$RUNTIME_DIR/dxmt}"
FINEWINE_DIR="${PGR_FINEWINE_DIR:-$RUNTIME_DIR/finewine}"
PREFIX="${PGR_PREFIX:-$APP_SUPPORT/Bottle}"
LOG_DIR="${PGR_LOG_DIR:-$APP_SUPPORT/logs}"

# ---- 固定的运行时版本（2026-11 实测） ----------------------------------------
WINE_NAME="wine-crossover-11.0-1-osx64-signed.tar.xz"
WINE_URL="https://github.com/yaagl/anime-game-wine/releases/download/wine-crossover-11.0-1-signed/wine-crossover-11.0-1-osx64-signed.tar.xz"
WINE_SHA256="89fa7e90fb626523a90d5867a03c6be785d017176739c6320a3b86c7838c3a35"
WINE_SIZE=456021524
WINE_ARCHIVE_ROOT="wine"   # 归档内目录，解压到 RUNTIME_DIR/wine

DXMT_NAME="dxmt-v0.80-builtin.tar.gz"
DXMT_URL="https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz"
DXMT_SHA256="8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d"
DXMT_SIZE=18681669
DXMT_ARCHIVE_ROOT="v0.80"

FINEWINE_NAME="endfield-wine-modules.tar.gz"
FINEWINE_URL="https://github.com/stoicswe/Endfield_FineWine/releases/download/1.4.3/endfield-wine-modules.tar.gz"
FINEWINE_SHA256="d71b61275e98a65cab95626f33baa842567c63f8483a6b963a4031de862da2e2"
FINEWINE_SIZE=4278321
FINEWINE_ARCHIVE_ROOT="endfield-wine-modules"
FINEWINE_VERSION="1.4.3"

# GitHub release 直连在本机约 50KB/s；镜像可到 0.8–1.7MB/s。
GH_MIRRORS="${PGR_GH_MIRRORS:-https://gh-proxy.com/ https://ghfast.top/}"

log()  { printf '\033[1;34m[wine]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[wine][warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[wine][error]\033[0m %s\n' "$*" >&2; exit 1; }

mkdirs() { mkdir -p "$@"; }

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
file_size() { stat -f%z "$1" 2>/dev/null || echo 0; }

# 为 GitHub URL 追加镜像候选（直连 + 镜像，按顺序尝试）
candidate_urls() {
  local url="$1"
  echo "$url"
  case "$url" in
    *github.com/*|*githubusercontent.com/*)
      for prefix in $GH_MIRRORS; do
        echo "${prefix}${url}"
      done
      ;;
  esac
}

# _url_size <url> — 通过 Range 0-0 探测远端文件大小（跟随重定向）
_url_size() {
  local url="$1" total
  total=$(curl -sL --max-time 30 -r 0-0 -D - -o /dev/null "$url" 2>/dev/null \
    | tr -d '\r' | awk 'tolower($1)=="content-range:"{split($2,a,"/"); print a[2]}' | tail -1)
  if [ -z "${total:-}" ]; then
    total=$(curl -sL --max-time 30 -D - -o /dev/null "$url" 2>/dev/null \
      | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}' | tail -1)
  fi
  echo "${total:-0}"
}

# _download_parallel <url> <dest> <total> [nproc]
# GitHub 单连接会被限速；切成 N 段并发下载再拼接（支持复用已存在的前缀）。
_download_parallel() {
  local url="$1" dest="$2" total="$3" nproc="${4:-8}"
  local tmp="${dest}.parts"
  rm -rf "$tmp"; mkdir -p "$tmp"

  local have=0
  if [ -f "$dest" ]; then
    have=$(file_size "$dest")
    [ "$have" -lt "$total" ] && mv "$dest" "$tmp/seg0000"
  fi
  local start=$have
  local remain=$(( total - start ))
  if [ "$remain" -le 0 ]; then :; else
    local chunk=$(( (remain + nproc - 1) / nproc )) i a b seg pids=""
    for i in $(seq 0 $((nproc - 1))); do
      a=$(( start + i * chunk )); b=$(( a + chunk - 1 ))
      [ "$b" -ge "$total" ] && b=$(( total - 1 ))
      [ "$a" -gt "$b" ] && continue
      seg=$(printf "%s/seg%04d" "$tmp" $(( i + 1 )))
      local want=$(( b - a + 1 ))
      (
        for attempt in 1 2 3 4 5; do
          curl -sL --retry 3 --retry-delay 2 --max-time 900 --range "${a}-${b}" -o "$seg" "$url" || true
          got=$(file_size "$seg")
          [ "$got" -ge "$want" ] && exit 0
          warn "segment $((i+1)) retry $attempt ($got/$want bytes)"
          sleep 2
        done
        exit 1
      ) &
      pids="$pids $!"
    done
    local fail=0
    for p in $pids; do wait "$p" || fail=1; done
    [ "$fail" -ne 0 ] && { rm -rf "$tmp"; return 1; }
  fi

  : > "${dest}.tmp"
  for f in "$tmp"/seg*; do cat "$f" >> "${dest}.tmp"; done
  mv "${dest}.tmp" "$dest"
  rm -rf "$tmp"
  [ "$(file_size "$dest")" -eq "$total" ] || return 1
  return 0
}

# download_verified <dest> <sha256> <size> <url> [名称]
# 已存在且校验通过则跳过；否则按「直连 + 镜像」依次尝试（并发分段下载），最后校验 SHA-256。
download_verified() {
  local dest="$1" sha="$2" size="$3" url="$4" label="${5:-$(basename "$dest")}"
  mkdirs "$(dirname "$dest")"

  if [ -f "$dest" ] && [ "$(file_size "$dest")" -eq "$size" ] && [ "$(sha256_of "$dest")" = "$sha" ]; then
    log "$label 已存在且校验通过，跳过下载：$dest"
    return 0
  fi

  local candidate total rc
  while read -r candidate; do
    [ -z "$candidate" ] && continue
    log "$label 下载：$candidate"
    total=$(_url_size "$candidate")
    if [ "${total:-0}" -le 0 ]; then
      warn "无法探测大小，改试下一个源：$candidate"
      continue
    fi
    if [ "$total" -ne "$size" ]; then
      warn "远端大小 $total 与期望 $size 不一致，改试下一个源"
      continue
    fi
    rm -f "$dest"
    if _download_parallel "$candidate" "$dest" "$total" "${PGR_DOWNLOAD_CONCURRENCY:-8}"; then
      if [ "$(sha256_of "$dest")" = "$sha" ]; then
        log "$label SHA-256 校验通过"
        return 0
      fi
      warn "$label SHA-256 校验失败（${candidate}）"
    else
      warn "$label 分段下载失败（${candidate}）"
    fi
  done < <(candidate_urls "$url")

  die "$label 下载/校验失败：$dest"
}

# assert_wine_runtime [dir]
assert_wine_runtime() {
  local w="${1:-$WINE_DIR}"
  [ -x "$w/bin/wine" ] || die "wine 未安装：$w/bin/wine 不存在（先跑 install-runtime.sh）"
  [ -f "$w/bin/wineserver" ] || die "wine 运行时损坏：$w/bin/wineserver 不存在"
}

# wine_version [dir]
wine_version() {
  local w="${1:-$WINE_DIR}"
  "$w/bin/wine" --version 2>/dev/null | head -1
}

# backup_and_copy <src> <dst> — 目标存在时先备份为 .bak（不覆盖已有 .bak）
backup_and_copy() {
  local src="$1" dst="$2"
  mkdirs "$(dirname "$dst")"
  if [ -f "$dst" ] && [ ! -f "${dst}.bak" ]; then
    cp -p "$dst" "${dst}.bak"
  fi
  cp -p "$src" "$dst"
}

# is_macos_arm64 — 本机校验（脚本仅支持 Apple Silicon + Rosetta）
is_macos_arm64() {
  [ "$(uname -s)" = "Darwin" ] || return 2
  [ "$(uname -m)" = "arm64" ] || return 3
  return 0
}
