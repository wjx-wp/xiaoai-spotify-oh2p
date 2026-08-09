#!/bin/sh

PID_FILE=/tmp/xiaoaimusic-voice-bridge.pid

if [ ! -s "$PID_FILE" ]; then
    echo "语音桥未运行"
    exit 0
fi

pid=$(cat "$PID_FILE")
kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
rm -f "$PID_FILE"
echo "语音桥已停止"
