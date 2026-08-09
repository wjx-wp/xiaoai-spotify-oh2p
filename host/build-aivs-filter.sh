#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
USER_DIR=$(getent passwd "$(id -u)" | cut -d: -f6)
TOOLS_DIR="$USER_DIR/.local/share/xiaoaimusic-tools"
TARGET=armv7-unknown-linux-gnueabihf.2.25
TARGET_DIR_NAME=armv7-unknown-linux-gnueabihf
CACHE_DIR="${XIAOAMUSIC_BUILD_CACHE:-$USER_DIR/.cache/xiaoaimusic-build}/aivs-filter"
OUTPUT="$REPO_ROOT/artifacts/build/oh2p/lib/libxiaoaimusic_aivs_filter.so"

export PATH="$USER_DIR/.cargo/bin:$TOOLS_DIR/bin:$PATH"
export CARGO_ZIGBUILD_PYTHON_PATH="$TOOLS_DIR/bin/python"
export CARGO_ZIGBUILD_ZIG_PATH="$TOOLS_DIR/bin/zig"
export CARGO_ZIGBUILD_CACHE_DIR="${XIAOAMUSIC_BUILD_CACHE:-$USER_DIR/.cache/xiaoaimusic-build}/zig-cache"

mkdir -p "$CACHE_DIR" "$(dirname -- "$OUTPUT")"
cd "$REPO_ROOT/components/aivs-filter"
CARGO_TARGET_DIR="$CACHE_DIR" cargo +1.96.0 test
CARGO_TARGET_DIR="$CACHE_DIR" cargo +1.96.0 zigbuild --release --target "$TARGET"
cp "$CACHE_DIR/$TARGET_DIR_NAME/release/libxiaoaimusic_aivs_filter.so" "$OUTPUT"
chmod 755 "$OUTPUT"
"$REPO_ROOT/host/check-elf.sh" "$OUTPUT"
readelf -Ws "$OUTPUT" | grep -q '_ZN4aivs6Engine6createERSt10shared_ptr'
echo "$OUTPUT"
