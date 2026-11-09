#!/usr/bin/env bash
# Build and launch the app in the foreground so log output stays visible.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-debug}"
"$ROOT/scripts/build.sh" "$MODE"
open "$ROOT/build/PGRLauncher.app"
echo "已启动 PGRLauncher.app"
