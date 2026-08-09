#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PID_FILE=/tmp/xiaoaimusic-keybridge.pid
LOG_FILE=/tmp/xiaoaimusic-keybridge.log
PLAY_CODE=${XIAOAI_PLAY_KEY_CODE:-114}
CONTROL_SOCKET=${LIBRESPOT_CONTROL_SOCKET:-/tmp/xiaoaimusic-librespot-control.sock}

if [ -s "$PID_FILE" ]; then
    old_pid=$(cat "$PID_FILE" 2>/dev/null || true)
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        echo "按键桥已在运行（PID $old_pid）"
        exit 0
    fi
fi
rm -f "$PID_FILE"
[ -x "$ROOT/bin/xiaoaimusic-keybridge" ] || {
    echo '缺少 xiaoaimusic-keybridge' >&2
    exit 2
}
[ -x "$ROOT/spotify-button-action.sh" ] || {
    echo '缺少 spotify-button-action.sh' >&2
    exit 2
}

/sbin/start-stop-daemon -S -b -m -p "$PID_FILE" -x /bin/sh -- -c \
    "exec '$ROOT/bin/xiaoaimusic-keybridge' --play-code '$PLAY_CODE' \
    --control-socket '$CONTROL_SOCKET' --command toggle >/dev/null 2>'$LOG_FILE'"
sleep 1
pid=$(cat "$PID_FILE")
kill -0 "$pid"
echo "按键桥已启动（PID $pid，播放键码 $PLAY_CODE）"
