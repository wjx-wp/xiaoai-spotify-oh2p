#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
USER_DIR=$(getent passwd "$(id -u)" | cut -d: -f6)
ZIG="$USER_DIR/.local/share/xiaoaimusic-tools/bin/zig"
OUTPUT="$REPO_ROOT/artifacts/build/oh2p/lib/libxiaoaimusic_touchpad_filter.so"

[ -x "$ZIG" ] || { echo "缺少 Zig，请先运行 host/bootstrap-wsl.sh" >&2; exit 2; }
mkdir -p "$(dirname -- "$OUTPUT")"
"$ZIG" cc -target arm-linux-gnueabihf.2.25 -Os -s -shared -fPIC \
    "$REPO_ROOT/components/touchpad-filter/touchpad-filter.c" -o "$OUTPUT"
chmod 755 "$OUTPUT"
"$REPO_ROOT/host/check-elf.sh" "$OUTPUT"
readelf -Ws "$OUTPUT" | grep -q 'GLOBAL.*player_toggle'
echo "$OUTPUT"
