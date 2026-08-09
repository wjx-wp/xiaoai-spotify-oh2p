#!/usr/bin/env bash

set -euo pipefail

RUST_VERSION=1.96.0
CARGO_ZIGBUILD_VERSION=0.23.0
ZIGLANG_VERSION=0.15.2
TARGET=armv7-unknown-linux-gnueabihf
USER_DIR=$(getent passwd "$(id -u)" | cut -d: -f6)
TOOLS_DIR="$USER_DIR/.local/share/xiaoaimusic-tools"

if [ "$(id -u)" -eq 0 ]; then
    SUDO=()
else
    SUDO=(sudo)
fi

"${SUDO[@]}" apt-get update
"${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential ca-certificates clang cmake curl file git jq libssl-dev \
    mtd-utils ninja-build nodejs npm openssl patch pkg-config python3 \
    python3-pip python3-venv qemu-user-binfmt rsync squashfs-tools unzip \
    usbutils wget xz-utils zip

if [ ! -x "$USER_DIR/.cargo/bin/rustup" ]; then
    curl --proto '=https' --tlsv1.2 -fsS https://sh.rustup.rs -o /tmp/xiaoaimusic-rustup.sh
    sh /tmp/xiaoaimusic-rustup.sh -y --profile minimal --default-toolchain "$RUST_VERSION"
    rm -f /tmp/xiaoaimusic-rustup.sh
fi

export PATH="$USER_DIR/.cargo/bin:$TOOLS_DIR/bin:$PATH"
rustup toolchain install "$RUST_VERSION" --profile minimal
rustup target add --toolchain "$RUST_VERSION" "$TARGET"

if [ ! -x "$TOOLS_DIR/bin/cargo-zigbuild" ] || \
   ! "$TOOLS_DIR/bin/cargo-zigbuild" --version 2>/dev/null | grep -q "$CARGO_ZIGBUILD_VERSION"; then
    python3 -m venv "$TOOLS_DIR"
    "$TOOLS_DIR/bin/python" -m pip install --disable-pip-version-check \
        "cargo-zigbuild==$CARGO_ZIGBUILD_VERSION" "ziglang==$ZIGLANG_VERSION"
fi
ln -sfn "$TOOLS_DIR/bin/python-zig" "$TOOLS_DIR/bin/zig"

rustc "+$RUST_VERSION" --version
"$TOOLS_DIR/bin/cargo-zigbuild" --version
"$TOOLS_DIR/bin/zig" version
echo "WSL 构建环境已就绪。"
