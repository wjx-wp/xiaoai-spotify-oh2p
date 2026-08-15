#!/bin/sh

set -eu

BASE_DIR=/data/xiaoaimusic
ENV_FILE="$BASE_DIR/device.env"
BIN="$BASE_DIR/bin/librespot"
CACHE_DIR="$BASE_DIR/cache/librespot"
SUPERVISOR="$BASE_DIR/supervise-librespot.sh"
PID_FILE=/tmp/xiaoaimusic-supervisor.pid
LOG_FILE=/tmp/xiaoaimusic-librespot.log

if [ -r /usr/share/mico/version ]; then
    MODEL=$(sed -n \
        -e "s/^[[:space:]]*option[[:space:]][[:space:]]*HARDWARE[[:space:]][[:space:]]*'\([^']*\)'.*/\1/p" \
        -e "s/.*HARDWARE[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" \
        /usr/share/mico/version | head -n 1)
    if [ -n "$MODEL" ] && [ "$MODEL" != "OH2P" ]; then
        echo "拒绝启动：检测到型号 $MODEL，不是 OH2P" >&2
        exit 2
    fi
fi

if [ ! -x "$BIN" ]; then
    echo "缺少可执行文件：$BIN" >&2
    exit 3
fi

if [ -r "$ENV_FILE" ]; then
    # 文件只允许由 root 写入，内容不得包含 shell 命令替换。
    . "$ENV_FILE"
fi

SPOTIFY_DEVICE_NAME=${SPOTIFY_DEVICE_NAME:-XiaoAI Music}
SPOTIFY_BITRATE=${SPOTIFY_BITRATE:-320}
SPOTIFY_INITIAL_VOLUME=${SPOTIFY_INITIAL_VOLUME:-100}
SPOTIFY_VOLUME_CTRL=${SPOTIFY_VOLUME_CTRL:-linear}
SPOTIFY_ENABLE_NORMALISATION=${SPOTIFY_ENABLE_NORMALISATION:-0}
SPOTIFY_AUDIO_BACKEND=${SPOTIFY_AUDIO_BACKEND:-subprocess}
SPOTIFY_AUDIO_COMMAND=${SPOTIFY_AUDIO_COMMAND:-/usr/bin/aplay -q -D default -t raw -f S16_LE -r 44100 -c 2}
LIBRESPOT_CONTROL_SOCKET=${LIBRESPOT_CONTROL_SOCKET:-/tmp/xiaoaimusic-librespot-control.sock}

mkdir -p "$CACHE_DIR"
chmod 700 "$BASE_DIR" "$CACHE_DIR"

if [ -r "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE" 2>/dev/null || true)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        echo "librespot 已运行，PID=$OLD_PID"
        exit 0
    fi
fi

if [ ! -x "$SUPERVISOR" ]; then
    echo "缺少监护脚本：$SUPERVISOR" >&2
    exit 5
fi

rm -f /tmp/xiaoaimusic-stop
export SPOTIFY_DEVICE_NAME SPOTIFY_BITRATE SPOTIFY_INITIAL_VOLUME
export SPOTIFY_VOLUME_CTRL SPOTIFY_ENABLE_NORMALISATION
export SPOTIFY_AUDIO_BACKEND SPOTIFY_AUDIO_COMMAND
export LIBRESPOT_CONTROL_SOCKET
"$SUPERVISOR" </dev/null >"$LOG_FILE" 2>&1 &

PID=$!
echo "$PID" >"$PID_FILE"
sleep 2

if ! kill -0 "$PID" 2>/dev/null; then
    echo "librespot 启动失败，日志如下：" >&2
    tail -n 80 "$LOG_FILE" >&2 || true
    exit 4
fi

echo "librespot 已启动，PID=$PID，日志=$LOG_FILE"
