#!/usr/bin/env bash

set -euo pipefail

DEVICE_IP=${1:-}
if [[ ! "$DEVICE_IP" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo '用法：host/probe-aivs-active.sh 音箱IP' >&2
    exit 2
fi

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PASSWORD_FILE="$REPO_ROOT/.secrets/oh2p-root-password.txt"
KNOWN_HOSTS="$REPO_ROOT/.secrets/known_hosts_oh2p"
FILTER="$REPO_ROOT/artifacts/build/oh2p/lib/libxiaoaimusic_aivs_filter.so"
VOICE_BRIDGE="$REPO_ROOT/device/oh2p/voice-bridge.sh"
SSH_OPTIONS=(
    -o HostKeyAlgorithms=+ssh-rsa
    -o PubkeyAcceptedAlgorithms=+ssh-rsa
    -o StrictHostKeyChecking=yes
    -o "UserKnownHostsFile=$KNOWN_HOSTS"
)

sshpass -f "$PASSWORD_FILE" scp -O "${SSH_OPTIONS[@]}" "$FILTER" "$VOICE_BRIDGE" \
    "root@$DEVICE_IP:/tmp/"
sshpass -f "$PASSWORD_FILE" ssh "${SSH_OPTIONS[@]}" "root@$DEVICE_IP" '
    set -e
    restore_aivs() {
        if [ -s /tmp/xiaoaimusic-aivs-active.pid ]; then
            ACTIVE_PID=$(cat /tmp/xiaoaimusic-aivs-active.pid)
            [ -z "$ACTIVE_PID" ] || kill "$ACTIVE_PID" 2>/dev/null || true
        fi
        rm -f /tmp/xiaoaimusic-aivs-active.pid /tmp/xiaoaimusic-aivs-filter-active
        /etc/init.d/mico_aivs_lab start >/dev/null 2>&1 || true
    }

    if [ -s /tmp/xiaoaimusic-aivs-active-guard.pid ]; then
        kill "$(cat /tmp/xiaoaimusic-aivs-active-guard.pid)" 2>/dev/null || true
    fi
    restore_aivs
    /etc/init.d/mico_aivs_lab stop

    mkdir -p /data/xiaoaimusic/lib
    cp /tmp/libxiaoaimusic_aivs_filter.so /data/xiaoaimusic/lib/
    chmod 600 /data/xiaoaimusic/lib/libxiaoaimusic_aivs_filter.so
    [ -f /data/xiaoaimusic/voice-bridge.sh.pre-aivs-filter ] || \
        cp -p /data/xiaoaimusic/voice-bridge.sh \
            /data/xiaoaimusic/voice-bridge.sh.pre-aivs-filter
    cp /tmp/voice-bridge.sh /data/xiaoaimusic/voice-bridge.sh
    chmod 700 /data/xiaoaimusic/voice-bridge.sh
    /data/xiaoaimusic/stop-voice-bridge.sh >/dev/null 2>&1 || true
    /data/xiaoaimusic/run-voice-bridge.sh

    rm -f /tmp/xiaoaimusic-aivs-filter.log /tmp/xiaoaimusic-aivs-active.out \
        /tmp/xiaoaimusic-aivs-active.pid /tmp/xiaoaimusic-aivs-active-guard.pid
    touch /tmp/xiaoaimusic-aivs-filter-active
    /sbin/start-stop-daemon -S -b -m -p /tmp/xiaoaimusic-aivs-active.pid \
        -x /bin/sh -- -c "exec /bin/busybox env XIAOAI_FILTER_MODE=active \
        LD_PRELOAD=/data/xiaoaimusic/lib/libxiaoaimusic_aivs_filter.so \
        /usr/bin/mico_aivs_lab >/tmp/xiaoaimusic-aivs-active.out 2>&1"
    sleep 5
    ACTIVE_PID=$(cat /tmp/xiaoaimusic-aivs-active.pid)
    kill -0 "$ACTIVE_PID"
    grep -q '/data/xiaoaimusic/lib/libxiaoaimusic_aivs_filter.so' "/proc/$ACTIVE_PID/maps"
    grep -q "HOOK capability=InstructionCapability slot=3" /tmp/xiaoaimusic-aivs-filter.log

    /sbin/start-stop-daemon -S -b -m -p /tmp/xiaoaimusic-aivs-active-guard.pid \
        -x /bin/sh -- -c "
            sleep 300
            if [ -s /tmp/xiaoaimusic-aivs-active.pid ]; then
                kill \$(cat /tmp/xiaoaimusic-aivs-active.pid) 2>/dev/null || true
                rm -f /tmp/xiaoaimusic-aivs-active.pid
            fi
            rm -f /tmp/xiaoaimusic-aivs-filter-active
            /etc/init.d/mico_aivs_lab start >/dev/null 2>&1 || true
        "
    echo "AIVS_FILTER_ACTIVE pid=$ACTIVE_PID rollback_seconds=300"
'
