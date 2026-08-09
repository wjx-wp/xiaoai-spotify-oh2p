#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
USER_DIR=$(getent passwd "$(id -u)" | cut -d: -f6)
ZIG="$USER_DIR/.local/share/xiaoaimusic-tools/bin/zig"
SOURCE="$REPO_ROOT/components/spotify-auth-updater/xiaoaimusic-spotify-auth-updater.c"
OUTPUT="$REPO_ROOT/artifacts/build/oh2p/bin/xiaoaimusic-spotify-auth-updater"
VERIFY_OUTPUT="${OUTPUT}.verify.$$"
READELF=${READELF:-readelf}

[ -x "$ZIG" ] || {
    echo 'Missing Zig; run host/bootstrap-wsl.sh first.' >&2
    exit 2
}
[ -f "$SOURCE" ] || { echo "Missing source: $SOURCE" >&2; exit 2; }
mkdir -p "$(dirname -- "$OUTPUT")"
trap 'rm -f -- "$VERIFY_OUTPUT"' EXIT

COMMON_FLAGS=(
    -target arm-linux-gnueabihf.2.25 -O2
    -D_FORTIFY_SOURCE=2 -fPIE -pie -fstack-protector-all -fno-common
    -Wall -Wextra -Wpedantic -Werror -Wformat=2 -Wformat-security
    -Wl,-z,relro,-z,now,-z,noexecstack,-z,defs
)

"$ZIG" cc "${COMMON_FLAGS[@]}" "$SOURCE" -o "$VERIFY_OUTPUT"
"$READELF" -h "$VERIFY_OUTPUT" | grep -E 'Type:[[:space:]]+DYN' >/dev/null || {
    echo 'spotify-auth-updater is not PIE.' >&2
    exit 1
}
"$READELF" -lW "$VERIFY_OUTPUT" | grep 'GNU_RELRO' >/dev/null || {
    echo 'spotify-auth-updater is missing GNU_RELRO.' >&2
    exit 1
}
if "$READELF" -lW "$VERIFY_OUTPUT" |
    awk '/GNU_STACK/ && /RWE/ { executable = 1 } END { exit(executable ? 0 : 1) }'; then
    echo 'spotify-auth-updater has an executable GNU_STACK.' >&2
    exit 1
fi
"$READELF" -dW "$VERIFY_OUTPUT" | grep -E 'BIND_NOW|FLAGS.*NOW' >/dev/null || {
    echo 'spotify-auth-updater is missing full RELRO/BIND_NOW.' >&2
    exit 1
}
"$READELF" -sW "$VERIFY_OUTPUT" | grep '__stack_chk_fail' >/dev/null || {
    echo 'spotify-auth-updater is missing stack protection.' >&2
    exit 1
}

"$ZIG" cc "${COMMON_FLAGS[@]}" -s "$SOURCE" -o "$OUTPUT"
chmod 755 "$OUTPUT"
"$REPO_ROOT/host/check-elf.sh" "$OUTPUT"
"$READELF" -h "$OUTPUT" | grep -E 'Type:[[:space:]]+DYN' >/dev/null
"$READELF" -lW "$OUTPUT" | grep 'GNU_RELRO' >/dev/null
if "$READELF" -lW "$OUTPUT" |
    awk '/GNU_STACK/ && /RWE/ { executable = 1 } END { exit(executable ? 0 : 1) }'; then
    echo 'final spotify-auth-updater has an executable GNU_STACK.' >&2
    exit 1
fi
"$READELF" -dW "$OUTPUT" | grep -E 'BIND_NOW|FLAGS.*NOW' >/dev/null
echo "$OUTPUT"
