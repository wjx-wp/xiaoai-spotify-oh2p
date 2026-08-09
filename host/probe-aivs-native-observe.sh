#!/usr/bin/env bash

set -euo pipefail

DEVICE_IP=${1:-}
if [[ ! "$DEVICE_IP" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo '用法：host/probe-aivs-native-observe.sh 音箱IP' >&2
    exit 2
fi

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PASSWORD_FILE="$REPO_ROOT/.secrets/oh2p-root-password.txt"
KNOWN_HOSTS="$REPO_ROOT/.secrets/known_hosts_oh2p"
FILTER="$REPO_ROOT/artifacts/build/oh2p/lib/libxiaoaimusic_aivs_filter.so"
SSH_OPTIONS=(
    -o HostKeyAlgorithms=+ssh-rsa
    -o PubkeyAcceptedAlgorithms=+ssh-rsa
    -o StrictHostKeyChecking=yes
    -o "UserKnownHostsFile=$KNOWN_HOSTS"
)

sshpass -f "$PASSWORD_FILE" scp -O "${SSH_OPTIONS[@]}" "$FILTER" \
    "root@$DEVICE_IP:/tmp/libxiaoaimusic_aivs_filter.so"
sshpass -f "$PASSWORD_FILE" ssh "${SSH_OPTIONS[@]}" "root@$DEVICE_IP" '
    set -e
    restore_native() {
        if [ -s /tmp/mico-aivs-observe.pid ]; then
            kill "$(cat /tmp/mico-aivs-observe.pid)" 2>/dev/null || true
        fi
        rm -f /tmp/mico-aivs-observe.pid
        /etc/init.d/mico_aivs_lab start >/dev/null 2>&1 || true
    }
    trap restore_native EXIT INT TERM

    MICO_HASH=$(busybox sha256sum /usr/bin/mico_aivs_lab | cut -d" " -f1)
    SDK_HASH=$(busybox sha256sum /usr/lib/libaivs_sdk.so | cut -d" " -f1)
    test "$MICO_HASH" = b2064cfcecba129a89d4dc01ff7a5acdd1515fe1a6b4ec3db876cd9c88d2a608
    test "$SDK_HASH" = 64150ecd6fdbddddd0944e177d26c45b9774306bd3ca5c19bce599080844eb9e

    # Independent recovery guard in case this SSH session disappears.
    rm -f /tmp/mico-aivs-observe-guard.pid
    /sbin/start-stop-daemon -S -b -m -p /tmp/mico-aivs-observe-guard.pid \
        -x /bin/sh -- -c "
        sleep 30
        if [ -s /tmp/mico-aivs-observe.pid ]; then
            kill \$(cat /tmp/mico-aivs-observe.pid) 2>/dev/null || true
        fi
        /etc/init.d/mico_aivs_lab start >/dev/null 2>&1 || true
    "

    /etc/init.d/mico_aivs_lab stop
    rm -f /tmp/xiaoaimusic-aivs-filter.log /tmp/mico-aivs-observe.out
    /sbin/start-stop-daemon -S -b -m -p /tmp/mico-aivs-observe.pid \
        -x /bin/sh -- -c "exec /bin/busybox env XIAOAI_FILTER_MODE=observe \
        LD_PRELOAD=/tmp/libxiaoaimusic_aivs_filter.so /usr/bin/mico_aivs_lab \
        >/tmp/mico-aivs-observe.out 2>&1"
    sleep 8
    kill -0 "$(cat /tmp/mico-aivs-observe.pid)"
    grep -q "HOOK engine=Engine slot=0" /tmp/xiaoaimusic-aivs-filter.log
    grep -q "HOOK capability=InstructionCapability slot=3" /tmp/xiaoaimusic-aivs-filter.log
    cat /tmp/xiaoaimusic-aivs-filter.log

    restore_native
    if [ -s /tmp/mico-aivs-observe-guard.pid ]; then
        GUARD_PID=$(cat /tmp/mico-aivs-observe-guard.pid)
        [ -z "$GUARD_PID" ] || kill "$GUARD_PID" 2>/dev/null || true
    fi
    rm -f /tmp/mico-aivs-observe-guard.pid
    trap - EXIT INT TERM
    sleep 8
    pidof mico_aivs_lab >/dev/null
    echo NATIVE_AIVS_RESTORED
'
