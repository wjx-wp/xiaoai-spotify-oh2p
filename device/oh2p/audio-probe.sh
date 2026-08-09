#!/bin/sh

set -eu

echo "=== ALSA devices ==="
aplay -l
echo "=== default route: 44.1 kHz / stereo / S16_LE / 1 second silence ==="
dd if=/dev/zero bs=176400 count=1 2>/dev/null | \
    aplay -q -D default -t raw -f S16_LE -r 44100 -c 2
echo "default route accepted the test stream"
