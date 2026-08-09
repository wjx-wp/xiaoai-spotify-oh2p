#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
USER_DIR=$(getent passwd "$(id -u)" | cut -d: -f6)
TOOLS_DIR="$USER_DIR/.local/share/xiaoaimusic-tools"
ZIG="$TOOLS_DIR/bin/zig"
OUTPUT="$REPO_ROOT/artifacts/build/oh2p/bin/xiaoaimusic-keybridge"

[ -x "$ZIG" ] || { echo "缺少 Zig，请先运行 host/bootstrap-wsl.sh" >&2; exit 2; }
mkdir -p "$(dirname -- "$OUTPUT")"
"$ZIG" cc -target arm-linux-gnueabihf.2.25 -Os -s \
    "$REPO_ROOT/components/keybridge/xiaoaimusic-keybridge.c" -o "$OUTPUT"
chmod 755 "$OUTPUT"
"$REPO_ROOT/host/check-elf.sh" "$OUTPUT"
echo "$OUTPUT"
