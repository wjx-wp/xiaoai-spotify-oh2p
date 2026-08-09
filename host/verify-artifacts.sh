#!/usr/bin/env bash

set -euo pipefail

VERIFY_FIRMWARE=1
if [ "${1:-}" = --skip-firmware ]; then
    VERIFY_FIRMWARE=0
    shift
fi
[ "$#" -eq 0 ] || { echo 'usage: verify-artifacts.sh [--skip-firmware]' >&2; exit 2; }

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT_DIR="$REPO_ROOT/artifacts/build/oh2p"

"$REPO_ROOT/host/check-elf.sh" "$OUT_DIR/bin/librespot"
"$REPO_ROOT/host/check-elf.sh" "$OUT_DIR/bin/xiaoai-agent"
"$REPO_ROOT/host/check-elf.sh" "$OUT_DIR/bin/xiaoaimusic-spotify-auth-updater"
"$REPO_ROOT/host/check-elf.sh" "$OUT_DIR/bin/xiaoaimusic-authorized-keys-verify"
if [ "$VERIFY_FIRMWARE" -eq 1 ]; then
    "$REPO_ROOT/host/verify-firmware.sh"
fi

PACKAGE_LIST=$(tar -tzf "$OUT_DIR/xiaoaimusic-oh2p.tar.gz")
grep -q '^xiaoaimusic-oh2p/bin/librespot$' <<<"$PACKAGE_LIST"
grep -q '^xiaoaimusic-oh2p/bin/xiaoaimusic-spotify-auth-updater$' <<<"$PACKAGE_LIST"
grep -q '^xiaoaimusic-oh2p/bin/xiaoaimusic-authorized-keys-verify$' <<<"$PACKAGE_LIST"
grep -q '^xiaoaimusic-oh2p/install.sh$' <<<"$PACKAGE_LIST"
grep -q '^xiaoaimusic-oh2p/mount-mobile-auth.sh$' <<<"$PACKAGE_LIST"
grep -q '^xiaoaimusic-oh2p/stop-home-bridge.sh$' <<<"$PACKAGE_LIST"
if grep -Eq '^xiaoaimusic-oh2p/(bin/xiaoaimusic-home-bridge|run-home-bridge\.sh)$' \
        <<<"$PACKAGE_LIST"; then
    echo 'refusing package containing the retired LAN home bridge' >&2
    exit 3
fi
grep -q '^xiaoaimusic-oh2p/supervise-librespot.sh$' <<<"$PACKAGE_LIST"
if grep -Eq '(^|/)(authorized_keys|[^/]*\.pub|home-takeover-token|spotify-refresh-token|\.spotify-token\.json)$' \
        <<<"$PACKAGE_LIST"; then
    echo 'refusing artifact containing credentials, a phone public key, or a token' >&2
    exit 3
fi

echo 'all OH2P build artifacts verified'
