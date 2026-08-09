#!/bin/sh

PID_FILE=/tmp/xiaoaimusic-keybridge.pid

if [ -s "$PID_FILE" ]; then
    pid=$(cat "$PID_FILE" 2>/dev/null || true)
    [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
fi
rm -f "$PID_FILE"
echo '按键桥已停止'
