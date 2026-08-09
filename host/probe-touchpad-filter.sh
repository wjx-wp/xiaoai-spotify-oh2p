#!/usr/bin/env bash

set -euo pipefail

DEVICE_IP=${1:-}
if [[ ! "$DEVICE_IP" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo '用法：host/probe-touchpad-filter.sh 音箱IP' >&2
    exit 2
fi

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PASSWORD_FILE="$REPO_ROOT/.secrets/oh2p-root-password.txt"
KNOWN_HOSTS="$REPO_ROOT/.secrets/known_hosts_oh2p"
FILTER="$REPO_ROOT/artifacts/build/oh2p/lib/libxiaoaimusic_touchpad_filter.so"
SSH_OPTIONS=(
    -o HostKeyAlgorithms=+ssh-rsa
    -o PubkeyAcceptedAlgorithms=+ssh-rsa
    -o StrictHostKeyChecking=yes
    -o "UserKnownHostsFile=$KNOWN_HOSTS"
)

sshpass -f "$PASSWORD_FILE" scp -O "${SSH_OPTIONS[@]}" "$FILTER" \
    "root@$DEVICE_IP:/tmp/libxiaoaimusic_touchpad_filter.so"
sshpass -f "$PASSWORD_FILE" ssh "${SSH_OPTIONS[@]}" "root@$DEVICE_IP" '
    set -e
    restore_touchpad() {
        if [ -s /tmp/xiaoaimusic-touchpad-filter.pid ]; then
            FILTER_PID=$(cat /tmp/xiaoaimusic-touchpad-filter.pid)
            [ -z "$FILTER_PID" ] || kill "$FILTER_PID" 2>/dev/null || true
        fi
        rm -f /tmp/xiaoaimusic-touchpad-filter.pid
        /etc/init.d/touchpad start >/dev/null 2>&1 || true
    }

    if [ -s /tmp/xiaoaimusic-touchpad-guard.pid ]; then
        kill "$(cat /tmp/xiaoaimusic-touchpad-guard.pid)" 2>/dev/null || true
    fi
    restore_touchpad
    /etc/init.d/touchpad stop
    rm -f /tmp/xiaoaimusic-touchpad-filter.pid /tmp/xiaoaimusic-touchpad-filter.out \
        /tmp/xiaoaimusic-touchpad-guard.pid
    /sbin/start-stop-daemon -S -b -m -p /tmp/xiaoaimusic-touchpad-filter.pid \
        -x /bin/sh -- -c "exec /bin/busybox env \
        LD_PRELOAD=/tmp/libxiaoaimusic_touchpad_filter.so /bin/touchpad \
        >/tmp/xiaoaimusic-touchpad-filter.out 2>&1"
    sleep 2
    FILTER_PID=$(cat /tmp/xiaoaimusic-touchpad-filter.pid)
    kill -0 "$FILTER_PID"
    grep -q '/tmp/libxiaoaimusic_touchpad_filter.so' "/proc/$FILTER_PID/maps"

    # If the test is not committed within five minutes, restore stock touchpad.
    /sbin/start-stop-daemon -S -b -m -p /tmp/xiaoaimusic-touchpad-guard.pid \
        -x /bin/sh -- -c "
            sleep 300
            if [ -s /tmp/xiaoaimusic-touchpad-filter.pid ]; then
                kill \$(cat /tmp/xiaoaimusic-touchpad-filter.pid) 2>/dev/null || true
                rm -f /tmp/xiaoaimusic-touchpad-filter.pid
            fi
            /etc/init.d/touchpad start >/dev/null 2>&1 || true
        "
    echo "TOUCHPAD_FILTER_ACTIVE pid=$FILTER_PID rollback_seconds=300"
'
