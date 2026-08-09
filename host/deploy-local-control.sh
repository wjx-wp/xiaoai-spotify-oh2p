#!/usr/bin/env bash

set -euo pipefail

DEVICE_IP=${1:-}
if [[ ! "$DEVICE_IP" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo '用法：host/deploy-local-control.sh 音箱IP' >&2
    exit 2
fi

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PASSWORD_FILE="$REPO_ROOT/.secrets/oh2p-root-password.txt"
KNOWN_HOSTS="$REPO_ROOT/.secrets/known_hosts_oh2p"
STAGING=$(mktemp -d)
trap 'rm -rf -- "$STAGING"' EXIT
mkdir -p "$STAGING/bin"
cp "$REPO_ROOT/artifacts/build/oh2p/bin/librespot" "$STAGING/bin/"
cp "$REPO_ROOT/artifacts/build/oh2p/bin/xiaoaimusic-keybridge" "$STAGING/bin/"
cp "$REPO_ROOT/device/oh2p/run-librespot.sh" "$STAGING/"
cp "$REPO_ROOT/device/oh2p/run-keybridge.sh" "$STAGING/"

SSH_OPTIONS=(
    -o HostKeyAlgorithms=+ssh-rsa
    -o PubkeyAcceptedAlgorithms=+ssh-rsa
    -o StrictHostKeyChecking=yes
    -o "UserKnownHostsFile=$KNOWN_HOSTS"
)

sshpass -f "$PASSWORD_FILE" ssh "${SSH_OPTIONS[@]}" "root@$DEVICE_IP" \
    'rm -rf /tmp/xiaoaimusic-local-control && mkdir -p /tmp/xiaoaimusic-local-control/bin'
sshpass -f "$PASSWORD_FILE" scp -O -r "${SSH_OPTIONS[@]}" "$STAGING"/* \
    "root@$DEVICE_IP:/tmp/xiaoaimusic-local-control/"
sshpass -f "$PASSWORD_FILE" ssh "${SSH_OPTIONS[@]}" "root@$DEVICE_IP" '
    set -e
    ROOT=/data/xiaoaimusic
    rollback() {
        "$ROOT/stop-keybridge.sh" >/dev/null 2>&1 || true
        "$ROOT/stop-librespot.sh" >/dev/null 2>&1 || true
        [ ! -f "$ROOT/bin/librespot.pre-local-control" ] || \
            cp "$ROOT/bin/librespot.pre-local-control" "$ROOT/bin/librespot"
        [ ! -f "$ROOT/bin/xiaoaimusic-keybridge.pre-local-control" ] || \
            cp "$ROOT/bin/xiaoaimusic-keybridge.pre-local-control" "$ROOT/bin/xiaoaimusic-keybridge"
        [ ! -f "$ROOT/run-librespot.sh.pre-local-control" ] || \
            cp "$ROOT/run-librespot.sh.pre-local-control" "$ROOT/run-librespot.sh"
        [ ! -f "$ROOT/run-keybridge.sh.pre-local-control" ] || \
            cp "$ROOT/run-keybridge.sh.pre-local-control" "$ROOT/run-keybridge.sh"
        "$ROOT/run-librespot.sh" >/dev/null 2>&1 || true
        "$ROOT/run-keybridge.sh" >/dev/null 2>&1 || true
    }
    trap rollback INT TERM HUP

    [ -f "$ROOT/bin/librespot.pre-local-control" ] || \
        cp -p "$ROOT/bin/librespot" "$ROOT/bin/librespot.pre-local-control"
    [ -f "$ROOT/bin/xiaoaimusic-keybridge.pre-local-control" ] || \
        cp -p "$ROOT/bin/xiaoaimusic-keybridge" "$ROOT/bin/xiaoaimusic-keybridge.pre-local-control"
    [ -f "$ROOT/run-librespot.sh.pre-local-control" ] || \
        cp -p "$ROOT/run-librespot.sh" "$ROOT/run-librespot.sh.pre-local-control"
    [ -f "$ROOT/run-keybridge.sh.pre-local-control" ] || \
        cp -p "$ROOT/run-keybridge.sh" "$ROOT/run-keybridge.sh.pre-local-control"

    "$ROOT/stop-keybridge.sh" >/dev/null 2>&1 || true
    "$ROOT/stop-librespot.sh" >/dev/null 2>&1 || true
    cp /tmp/xiaoaimusic-local-control/bin/librespot "$ROOT/bin/librespot"
    cp /tmp/xiaoaimusic-local-control/bin/xiaoaimusic-keybridge "$ROOT/bin/xiaoaimusic-keybridge"
    cp /tmp/xiaoaimusic-local-control/run-librespot.sh "$ROOT/run-librespot.sh"
    cp /tmp/xiaoaimusic-local-control/run-keybridge.sh "$ROOT/run-keybridge.sh"
    chmod 700 "$ROOT/bin/librespot" "$ROOT/bin/xiaoaimusic-keybridge" \
        "$ROOT/run-librespot.sh" "$ROOT/run-keybridge.sh"

    "$ROOT/run-librespot.sh"
    ready=0
    for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        if [ -S /tmp/xiaoaimusic-librespot-control.sock ]; then
            ready=1
            break
        fi
        sleep 1
    done
    if [ "$ready" -ne 1 ]; then
        echo LOCAL_CONTROL_SOCKET_TIMEOUT >&2
        rollback
        exit 1
    fi
    "$ROOT/run-keybridge.sh"
    kill -0 "$(cat /tmp/xiaoaimusic-keybridge.pid)"
    trap - INT TERM HUP
    rm -rf /tmp/xiaoaimusic-local-control
    echo LOCAL_CONTROL_ACTIVE
'
