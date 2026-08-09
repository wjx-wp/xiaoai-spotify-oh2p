#!/bin/sh

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN=$ROOT/bin/xiaoaimusic-home-bridge
PID_FILE=/tmp/xiaoaimusic-home-bridge.pid

pid_is_bridge() {
    candidate=$1
    case "$candidate" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$candidate" -gt 1 ] 2>/dev/null || return 1
    [ "$(readlink "/proc/$candidate/exe" 2>/dev/null || true)" = "$BIN" ]
}

bridge_pids() {
    for process_path in /proc/[0-9]*; do
        candidate=${process_path#/proc/}
        pid_is_bridge "$candidate" && printf '%s\n' "$candidate"
    done
}

terminate_bridge_pids() {
    signal_name=$1
    for candidate in $(bridge_pids); do
        pid_is_bridge "$candidate" && kill -s "$signal_name" "$candidate" 2>/dev/null || true
    done
}

terminate_bridge_pids TERM
for wait_step in 1 2 3 4 5; do
    [ -z "$(bridge_pids)" ] && break
    sleep 1
done
if [ -n "$(bridge_pids)" ]; then
    terminate_bridge_pids KILL
    sleep 1
fi
rm -f "$PID_FILE"
if [ -n "$(bridge_pids)" ]; then
    echo 'Legacy home bridge is still running.' >&2
    exit 1
fi
exit 0
