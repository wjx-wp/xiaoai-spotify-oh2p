#!/bin/sh

set -u

LOG=/tmp/xiaoaimusic-music-intent.log
TIMEOUT_SECONDS=${1:-75}

rm -f "$LOG"
ubus monitor >"$LOG" 2>&1 &
MONITOR_PID=$!
FOUND=0
ELAPSED=0

while [ "$ELAPSED" -lt "$TIMEOUT_SECONDS" ]; do
    sleep 1
    if grep -q '"method":"player_play_music"' "$LOG"; then
        FOUND=1
        break
    fi
    ELAPSED=$((ELAPSED + 1))
done

kill "$MONITOR_PID" 2>/dev/null || true
wait "$MONITOR_PID" 2>/dev/null || true

if [ "$FOUND" -ne 1 ]; then
    echo "MUSIC_INTENT_TIMEOUT"
    exit 2
fi

sleep 1
/data/xiaoaimusic/stop-native-music.sh
echo "MUSIC_INTENT_CAPTURED"
grep -E '"method":"player_play_(music|commad|album_playlist|url)"' "$LOG"
