#!/usr/bin/env bash

set -euo pipefail

BUILD_LIBRESPOT=1
BUILD_AGENT=1
BUILD_FIRMWARE=0
for arg in "$@"; do
    case "$arg" in
        --skip-librespot) BUILD_LIBRESPOT=0 ;;
        --skip-agent) BUILD_AGENT=0 ;;
        --skip-firmware) BUILD_FIRMWARE=0 ;;
        --with-reference-firmware) BUILD_FIRMWARE=1 ;;
        *) echo "未知参数：$arg" >&2; exit 2 ;;
    esac
done

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
USER_DIR=$(getent passwd "$(id -u)" | cut -d: -f6)
TOOLS_DIR="$USER_DIR/.local/share/xiaoaimusic-tools"
if [ -n "${XIAOAMUSIC_BUILD_CACHE:-}" ]; then
    CACHE_DIR=$XIAOAMUSIC_BUILD_CACHE
elif [ -d /mnt/d ] && [ -w /mnt/d ]; then
    CACHE_DIR=/mnt/d/xiaoaimusic-build-cache
else
    CACHE_DIR="${XDG_CACHE_HOME:-$USER_DIR/.cache}/xiaoaimusic-build"
fi
TARGET=armv7-unknown-linux-gnueabihf.2.25
TARGET_DIR_NAME=armv7-unknown-linux-gnueabihf
OUT_DIR="$REPO_ROOT/artifacts/build/oh2p"
RUST_VERSION=1.96.0

[ "$(git -C "$REPO_ROOT/upstream/librespot" rev-parse HEAD)" = d36f9f1907e8cc9d68a93f8ebc6b627b1bf7267d ]
[ "$(git -C "$REPO_ROOT/upstream/xiaoai-agent" rev-parse HEAD)" = b408562a8524dea2a613e99cb58a2268d8e2ea42 ]
[ "$(git -C "$REPO_ROOT/upstream/open-xiaoai" rev-parse HEAD)" = bc3396c64e2a435f354eb5cb12a203981f1fe422 ]
LIBRESPOT_PATCH="$REPO_ROOT/patches/librespot-local-control.patch"
echo 'c075bec69bd7183ea262885fbe451a86b55743108c5edfb6de1f7e5bc92f1830  '"$LIBRESPOT_PATCH" | sha256sum -c -
if git -C "$REPO_ROOT/upstream/librespot" apply --reverse --check --ignore-space-change "$LIBRESPOT_PATCH" 2>/dev/null; then
    :
elif git -C "$REPO_ROOT/upstream/librespot" apply --check --ignore-space-change "$LIBRESPOT_PATCH"; then
    git -C "$REPO_ROOT/upstream/librespot" apply --ignore-space-change "$LIBRESPOT_PATCH"
else
    echo 'librespot 本地控制补丁与锁定源码不兼容' >&2
    exit 3
fi
grep -q 'LIBRESPOT_CONTROL_SOCKET' "$REPO_ROOT/upstream/librespot/src/local_control.rs"
echo '26c71022cbccb984fecbdb5590f55539c28f9a3ff29273540a23acc843e7bf78  '"$REPO_ROOT/patches/xiaoai-agent-coexist.patch" | sha256sum -c -
grep -q 'XIAOAI_MODE=${XIAOAI_MODE:-"coexist"}' "$REPO_ROOT/upstream/xiaoai-agent/deploy/client-patch/src/patch.sh"
grep -q 'stat -L -c %s' "$REPO_ROOT/upstream/xiaoai-agent/deploy/client-patch/src/squashfs.sh"
if grep -q '^+ttyS0::askfirst:/bin/ash --login' "$REPO_ROOT/upstream/xiaoai-agent/deploy/client-patch/patches/02-login.patch"; then
    echo '不安全的 ttyS0 免认证 Root Shell 补丁仍然存在' >&2
    exit 3
fi

export PATH="$USER_DIR/.cargo/bin:$TOOLS_DIR/bin:$PATH"
export CARGO_ZIGBUILD_PYTHON_PATH="$TOOLS_DIR/bin/python"
export CARGO_ZIGBUILD_ZIG_PATH="$TOOLS_DIR/bin/zig"
export CARGO_ZIGBUILD_CACHE_DIR="$CACHE_DIR/zig-cache"
mkdir -p "$CACHE_DIR" "$OUT_DIR/bin" "$OUT_DIR/package" "$OUT_DIR/licenses"
cp "$REPO_ROOT/upstream/librespot/LICENSE" "$OUT_DIR/licenses/LICENSE.librespot-MIT"
cp "$REPO_ROOT/upstream/xiaoai-agent/LICENSE" "$OUT_DIR/licenses/LICENSE.xiaoai-agent-LGPL-3.0"
cp "$REPO_ROOT/upstream/open-xiaoai/LICENSE" "$OUT_DIR/licenses/LICENSE.open-xiaoai-MIT"

build_and_verify() {
    local name=$1
    local source=$2
    local binary_name=$3
    shift 3
    local target_dir="$CACHE_DIR/$name"

    echo "=== 构建 $name ==="
    cd "$source"
    CARGO_TARGET_DIR="$target_dir" cargo "+$RUST_VERSION" zigbuild \
        --release --locked --target "$TARGET" "$@"
    local binary="$target_dir/$TARGET_DIR_NAME/release/$binary_name"
    [ -f "$binary" ] || { echo "未找到构建产物：$binary" >&2; exit 3; }
    "$REPO_ROOT/host/check-elf.sh" "$binary"
    cp "$binary" "$OUT_DIR/bin/$binary_name"
    chmod 755 "$OUT_DIR/bin/$binary_name"
}

if [ "$BUILD_LIBRESPOT" -eq 1 ]; then
    build_and_verify librespot "$REPO_ROOT/upstream/librespot" librespot \
        --no-default-features --features rustls-tls-webpki-roots,with-libmdns
fi

if [ "$BUILD_AGENT" -eq 1 ]; then
    "$REPO_ROOT/host/build-aivs-filter.sh"
    "$REPO_ROOT/host/build-keybridge.sh"
    "$REPO_ROOT/host/build-log-follower.sh"
    "$REPO_ROOT/host/build-spotify-auth-updater.sh"
    "$REPO_ROOT/host/build-authorized-keys-verify.sh"
    "$REPO_ROOT/host/build-touchpad-filter.sh"
fi

if [ "$BUILD_AGENT" -eq 1 ]; then
    build_and_verify xiaoai-agent "$REPO_ROOT/upstream/xiaoai-agent/xiaoai-agent" xiaoai-agent
fi

if [ "$BUILD_LIBRESPOT" -eq 1 ]; then
    PACKAGE_DIR="$OUT_DIR/package/xiaoaimusic-oh2p"
    rm -rf "$PACKAGE_DIR"
    mkdir -p "$PACKAGE_DIR/bin"
    cp "$OUT_DIR/bin/librespot" "$PACKAGE_DIR/bin/librespot"
    cp "$OUT_DIR/bin/xiaoaimusic-keybridge" "$PACKAGE_DIR/bin/"
    cp "$OUT_DIR/bin/xiaoaimusic-log-follower" "$PACKAGE_DIR/bin/"
    cp "$OUT_DIR/bin/xiaoaimusic-spotify-auth-updater" "$PACKAGE_DIR/bin/"
    cp "$OUT_DIR/bin/xiaoaimusic-authorized-keys-verify" "$PACKAGE_DIR/bin/"
    mkdir -p "$PACKAGE_DIR/lib"
    cp "$OUT_DIR/lib/libxiaoaimusic_aivs_filter.so" "$PACKAGE_DIR/lib/"
    cp "$OUT_DIR/lib/libxiaoaimusic_touchpad_filter.so" "$PACKAGE_DIR/lib/"
    cp "$REPO_ROOT/config/oh2p-device.env.example" "$PACKAGE_DIR/device.env.example"
    cp "$REPO_ROOT/device/oh2p/spotify-web.env.example" "$PACKAGE_DIR/spotify-web.env.example"
    cp "$REPO_ROOT/device/oh2p/"*.sh "$PACKAGE_DIR/"
    rm -f "$PACKAGE_DIR/run-home-bridge.sh"
    cp "$REPO_ROOT/upstream/librespot/LICENSE" "$PACKAGE_DIR/LICENSE.librespot-MIT"
    tar -C "$OUT_DIR/package" -czf "$OUT_DIR/xiaoaimusic-oh2p.tar.gz" xiaoaimusic-oh2p
fi

if [ "$BUILD_FIRMWARE" -eq 1 ]; then
    "$REPO_ROOT/host/patch-firmware-1622.sh"
fi

{
    echo "built_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "rust=$(rustc +$RUST_VERSION --version)"
    echo "cargo_zigbuild=$(cargo-zigbuild --version)"
    echo "zig=$($TOOLS_DIR/bin/zig version)"
    find "$OUT_DIR/bin" -maxdepth 1 -type f -exec sha256sum {} \;
    [ ! -f "$OUT_DIR/xiaoaimusic-oh2p.tar.gz" ] || sha256sum "$OUT_DIR/xiaoaimusic-oh2p.tar.gz"
} >"$OUT_DIR/BUILD-MANIFEST.txt"

if [ "$BUILD_LIBRESPOT" -eq 1 ] && [ "$BUILD_AGENT" -eq 1 ]; then
    if [ "$BUILD_FIRMWARE" -eq 1 ]; then
        "$REPO_ROOT/host/verify-artifacts.sh"
    else
        "$REPO_ROOT/host/verify-artifacts.sh" --skip-firmware
    fi
fi

echo "OH2P 到货前产物已生成：$OUT_DIR"
