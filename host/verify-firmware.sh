#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FIRMWARE_DIR="$REPO_ROOT/artifacts/build/oh2p/firmware-1.62.2-coexist"
ORIGINAL="$FIRMWARE_DIR/root-original.squashfs"
PATCHED="$FIRMWARE_DIR/root-patched-coexist.squashfs"
MANIFEST="$FIRMWARE_DIR/MANIFEST.txt"

for file in "$ORIGINAL" "$PATCHED" "$MANIFEST"; do
    [ -f "$file" ] || { echo "缺少固件产物：$file" >&2; exit 2; }
done

PATCHED_SIZE=$(stat -c %s "$PATCHED")
[ "$PATCHED_SIZE" -lt $((0x02800000)) ]
grep -q "^patched_size=$PATCHED_SIZE$" "$MANIFEST"

ORIGINAL_HASH=$(sha256sum "$ORIGINAL" | cut -d' ' -f1)
PATCHED_HASH=$(sha256sum "$PATCHED" | cut -d' ' -f1)
grep -q "^$ORIGINAL_HASH  " "$MANIFEST"
grep -q "^$PATCHED_HASH  " "$MANIFEST"

stream_hash() {
    unsquashfs -cat "$1" "$2" 2>/dev/null | sha256sum | cut -d' ' -f1
}

ORIGINAL_ASOUND=$(stream_hash "$ORIGINAL" etc/asound.conf)
PATCHED_ASOUND=$(stream_hash "$PATCHED" etc/asound.conf)
ORIGINAL_INITTAB=$(stream_hash "$ORIGINAL" etc/inittab)
PATCHED_INITTAB=$(stream_hash "$PATCHED" etc/inittab)
ORIGINAL_SHADOW=$(stream_hash "$ORIGINAL" etc/shadow)
PATCHED_SHADOW=$(stream_hash "$PATCHED" etc/shadow)

[ "$ORIGINAL_ASOUND" = "$PATCHED_ASOUND" ]
[ "$ORIGINAL_INITTAB" = "$PATCHED_INITTAB" ]
[ "$ORIGINAL_SHADOW" != "$PATCHED_SHADOW" ]
grep -q "^native_asound_sha256=$PATCHED_ASOUND$" "$MANIFEST"
grep -q "^native_inittab_sha256=$PATCHED_INITTAB$" "$MANIFEST"

unsquashfs -cat "$PATCHED" etc/inittab 2>/dev/null | grep -q '^ttyS0::askfirst:/bin/login$'
if unsquashfs -cat "$PATCHED" etc/inittab 2>/dev/null | grep -q '^ttyS0::askfirst:/bin/ash --login$'; then
    echo '检测到 ttyS0 免认证 Root Shell' >&2
    exit 3
fi
unsquashfs -cat "$PATCHED" etc/rc.local 2>/dev/null | grep -q '/data/init.sh'
unsquashfs -cat "$PATCHED" etc/init.d/dropbear 2>/dev/null | grep -q 'mkdir -p /data/etc/dropbear'
unsquashfs -cat "$PATCHED" bin/ota 2>/dev/null | grep -q 'download upgrade failed'
PATCHED_LISTING=$(unsquashfs -ll "$PATCHED" 2>/dev/null)
grep -q 'dev/console$' <<<"$PATCHED_LISTING"

echo "firmware_original_sha256=$ORIGINAL_HASH"
echo "firmware_patched_sha256=$PATCHED_HASH"
echo "firmware_patched_size=$PATCHED_SIZE"
echo 'firmware_mode=coexist (native asound + authenticated ttyS0 preserved)'
