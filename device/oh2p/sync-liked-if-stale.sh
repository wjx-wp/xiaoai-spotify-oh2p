#!/bin/sh

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STAMP=$ROOT/liked-mirror-last-sync
MAX_AGE=${XIAOAI_LIKED_SYNC_MAX_AGE:-86400}
now=$(date +%s)
last=0
if [ -s "$STAMP" ]; then
    last=$(cat "$STAMP" 2>/dev/null || printf '0')
fi
case "$last" in *[!0-9]*|'') last=0 ;; esac
case "$MAX_AGE" in *[!0-9]*|'') MAX_AGE=86400 ;; esac

if [ $((now - last)) -lt "$MAX_AGE" ]; then
    exit 0
fi
"$ROOT/spotify-web-api.sh" sync-liked >>/tmp/xiaoaimusic-liked-sync.log 2>&1
