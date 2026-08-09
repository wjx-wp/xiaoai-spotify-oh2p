#!/bin/sh

PID_FILE=/tmp/xiaoaimusic-supervisor.pid
CHILD_PID_FILE=/tmp/xiaoaimusic-librespot.pid

touch /tmp/xiaoaimusic-stop

if [ -r "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE" 2>/dev/null || true)
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        kill "$PID"
    fi
    rm -f "$PID_FILE"
fi

if [ -r "$CHILD_PID_FILE" ]; then
    PID=$(cat "$CHILD_PID_FILE" 2>/dev/null || true)
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        kill "$PID"
    fi
    rm -f "$CHILD_PID_FILE"
fi
