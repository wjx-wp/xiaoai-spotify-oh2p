#!/bin/sh

set -u

BASE_DIR=/data/xiaoaimusic
BIN="$BASE_DIR/bin/librespot"
CACHE_DIR="$BASE_DIR/cache/librespot"
CHILD_PID_FILE=/tmp/xiaoaimusic-librespot.pid
STOP_FILE=/tmp/xiaoaimusic-stop
DELAY=3
CHILD_PID=
NORMALISATION_ARG=

case "$SPOTIFY_ENABLE_NORMALISATION" in
    1|true|yes) NORMALISATION_ARG=--enable-volume-normalisation ;;
esac

stop_child() {
    if [ -n "$CHILD_PID" ] && kill -0 "$CHILD_PID" 2>/dev/null; then
        kill "$CHILD_PID" 2>/dev/null || true
        wait "$CHILD_PID" 2>/dev/null || true
    fi
    rm -f "$CHILD_PID_FILE"
}

trap 'touch "$STOP_FILE"; stop_child; exit 0' INT TERM HUP

while [ ! -e "$STOP_FILE" ]; do
    "$BIN" \
        --name "$SPOTIFY_DEVICE_NAME" \
        --device-type speaker \
        --bitrate "$SPOTIFY_BITRATE" \
        --initial-volume "$SPOTIFY_INITIAL_VOLUME" \
        --backend "$SPOTIFY_AUDIO_BACKEND" \
        --device "$SPOTIFY_AUDIO_COMMAND" \
        --format S16 \
        --volume-ctrl "$SPOTIFY_VOLUME_CTRL" \
        --system-cache "$CACHE_DIR" \
        --disable-audio-cache \
        $NORMALISATION_ARG &
    CHILD_PID=$!
    echo "$CHILD_PID" >"$CHILD_PID_FILE"
    wait "$CHILD_PID"
    STATUS=$?
    CHILD_PID=
    rm -f "$CHILD_PID_FILE"

    [ -e "$STOP_FILE" ] && break
    echo "librespot 异常退出（状态 $STATUS），${DELAY}s 后重启"
    sleep "$DELAY"
    if [ "$DELAY" -lt 60 ]; then
        DELAY=$((DELAY * 2))
        [ "$DELAY" -gt 60 ] && DELAY=60
    fi
done

rm -f "$CHILD_PID_FILE"
