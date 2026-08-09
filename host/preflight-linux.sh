#!/usr/bin/env bash

set -euo pipefail

USER_DIR=$(getent passwd "$(id -u)" | cut -d: -f6)
TOOLS_DIR="$USER_DIR/.local/share/xiaoaimusic-tools"
export PATH="$USER_DIR/.cargo/bin:$TOOLS_DIR/bin:$PATH"

REQUIRED=(git node npm python3 unsquashfs mksquashfs file readelf rustup cargo cargo-zigbuild zig)
FAILED=0
for command_name in "${REQUIRED[@]}"; do
    if command -v "$command_name" >/dev/null 2>&1; then
        printf 'OK   %-18s %s\n' "$command_name" "$(command -v "$command_name")"
    else
        printf 'MISS %-18s\n' "$command_name"
        FAILED=1
    fi
done

exit "$FAILED"
