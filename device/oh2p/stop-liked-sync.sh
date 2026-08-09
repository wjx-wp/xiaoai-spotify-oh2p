#!/bin/sh

PID_FILE=/tmp/xiaoaimusic-liked-sync-supervisor.pid
STOP_FILE=/tmp/xiaoaimusic-liked-sync-stop

touch "$STOP_FILE"
pids=$(ps w 2>/dev/null | awk '
    /\/data\/xiaoaimusic\/supervise-liked-sync[.]sh/ { print $1 }
')
for pid in $pids; do
    [ "$pid" = "$$" ] || kill "$pid" 2>/dev/null || true
done
sleep 1
for pid in $pids; do
    [ "$pid" = "$$" ] || ! kill -0 "$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
done
rm -f "$PID_FILE"
