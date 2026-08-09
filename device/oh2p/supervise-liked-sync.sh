#!/bin/sh

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PID_FILE=/tmp/xiaoaimusic-liked-sync-supervisor.pid
STOP_FILE=/tmp/xiaoaimusic-liked-sync-stop
CHECK_INTERVAL=${XIAOAI_LIKED_SYNC_CHECK_INTERVAL:-3600}
SLEEP_PID=

case "$CHECK_INTERVAL" in
    *[!0-9]*|'') CHECK_INTERVAL=3600 ;;
esac
[ "$CHECK_INTERVAL" -ge 60 ] || CHECK_INTERVAL=60

if [ -s "$PID_FILE" ]; then
    old_pid=$(cat "$PID_FILE" 2>/dev/null || true)
    if [ -n "$old_pid" ] && [ "$old_pid" != "$$" ] && kill -0 "$old_pid" 2>/dev/null; then
        echo "点赞音乐同步服务已在运行（PID $old_pid）"
        exit 0
    fi
fi

cleanup() {
    if [ -n "$SLEEP_PID" ] && kill -0 "$SLEEP_PID" 2>/dev/null; then
        kill "$SLEEP_PID" 2>/dev/null || true
        wait "$SLEEP_PID" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
}

trap 'cleanup; exit 0' INT TERM HUP
trap cleanup EXIT

rm -f "$STOP_FILE"
printf '%s\n' "$$" >"$PID_FILE"

while [ ! -e "$STOP_FILE" ]; do
    "$ROOT/sync-liked-if-stale.sh" || true
    sleep "$CHECK_INTERVAL" &
    SLEEP_PID=$!
    wait "$SLEEP_PID" 2>/dev/null || true
    SLEEP_PID=
done
