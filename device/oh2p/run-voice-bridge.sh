#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PID_FILE=/tmp/xiaoaimusic-voice-bridge.pid
LOG_FILE=/tmp/xiaoaimusic-voice-bridge.log

if [ -s "$PID_FILE" ]; then
    old_pid=$(cat "$PID_FILE")
    if kill -0 "$old_pid" 2>/dev/null; then
        echo "语音桥已在运行（PID $old_pid）"
        exit 0
    fi
    rm -f "$PID_FILE"
fi

[ -s "$ROOT/spotify-refresh-token" ] || {
    echo "Spotify 尚未授权，未启动语音桥。" >&2
    exit 2
}

"$ROOT/voice-bridge.sh" >>"$LOG_FILE" 2>&1 </dev/null &
pid=$!
printf '%s\n' "$pid" >"$PID_FILE"
sleep 1
if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$PID_FILE"
    echo "语音桥启动失败，请检查 $LOG_FILE" >&2
    exit 1
fi

echo "语音桥已启动（PID $pid）"
