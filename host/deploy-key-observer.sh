#!/usr/bin/env bash

set -euo pipefail

DEVICE_IP=${1:-}
if [[ ! "$DEVICE_IP" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo '用法：host/deploy-key-observer.sh 音箱IP' >&2
    exit 2
fi

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PASSWORD_FILE="$REPO_ROOT/.secrets/oh2p-root-password.txt"
KNOWN_HOSTS="$REPO_ROOT/.secrets/known_hosts_oh2p"
BINARY="$REPO_ROOT/artifacts/build/oh2p/bin/xiaoaimusic-keybridge"
SSH_OPTIONS=(
    -o HostKeyAlgorithms=+ssh-rsa
    -o PubkeyAcceptedAlgorithms=+ssh-rsa
    -o StrictHostKeyChecking=yes
    -o "UserKnownHostsFile=$KNOWN_HOSTS"
)

[ -x "$BINARY" ] || { echo '请先运行 host/build-keybridge.sh' >&2; exit 2; }
sshpass -f "$PASSWORD_FILE" ssh "${SSH_OPTIONS[@]}" "root@$DEVICE_IP" '
    if [ -s /tmp/xiaoaimusic-keybridge-observe.pid ]; then
        kill "$(cat /tmp/xiaoaimusic-keybridge-observe.pid)" 2>/dev/null || true
        sleep 1
    fi
'
sshpass -f "$PASSWORD_FILE" scp -O "${SSH_OPTIONS[@]}" \
    "$BINARY" "root@$DEVICE_IP:/tmp/xiaoaimusic-keybridge"
sshpass -f "$PASSWORD_FILE" ssh "${SSH_OPTIONS[@]}" "root@$DEVICE_IP" '
    chmod 700 /tmp/xiaoaimusic-keybridge
    rm -f /tmp/xiaoaimusic-keybridge-observe.log
    /sbin/start-stop-daemon -S -b -m \
        -p /tmp/xiaoaimusic-keybridge-observe.pid \
        -x /bin/sh -- -c "exec /tmp/xiaoaimusic-keybridge --observe >/dev/null 2>/tmp/xiaoaimusic-keybridge-observe.log"
    sleep 1
    cat /tmp/xiaoaimusic-keybridge-observe.log
'
