#!/usr/bin/env bash

set -euo pipefail

DEVICE_IP=${1:-}
if [[ ! "$DEVICE_IP" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo '用法：host/deploy-liked-sync.sh 音箱IP' >&2
    exit 2
fi

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PASSWORD_FILE="$REPO_ROOT/.secrets/oh2p-root-password.txt"
KNOWN_HOSTS="$REPO_ROOT/.secrets/known_hosts_oh2p"
SSH_OPTIONS=(
    -o HostKeyAlgorithms=+ssh-rsa
    -o PubkeyAcceptedAlgorithms=+ssh-rsa
    -o StrictHostKeyChecking=yes
    -o "UserKnownHostsFile=$KNOWN_HOSTS"
)

sshpass -f "$PASSWORD_FILE" scp -O "${SSH_OPTIONS[@]}" \
    "$REPO_ROOT/device/oh2p/sync-liked-if-stale.sh" \
    "$REPO_ROOT/device/oh2p/supervise-liked-sync.sh" \
    "$REPO_ROOT/device/oh2p/stop-liked-sync.sh" \
    "root@$DEVICE_IP:/tmp/"

sshpass -f "$PASSWORD_FILE" ssh "${SSH_OPTIONS[@]}" "root@$DEVICE_IP" '
    set -e
    cp /tmp/sync-liked-if-stale.sh /tmp/supervise-liked-sync.sh /tmp/stop-liked-sync.sh \
        /data/xiaoaimusic/
    chmod 700 /data/xiaoaimusic/sync-liked-if-stale.sh \
        /data/xiaoaimusic/supervise-liked-sync.sh /data/xiaoaimusic/stop-liked-sync.sh
    /data/xiaoaimusic/stop-liked-sync.sh
    /data/xiaoaimusic/supervise-liked-sync.sh >>/tmp/xiaoaimusic-liked-sync.log 2>&1 &
    sleep 2
    count=$(ps w | awk "/\/data\/xiaoaimusic\/supervise-liked-sync[.]sh/ { count++ } END { print count+0 }")
    [ "$count" -eq 1 ]
    echo "LIKED_SYNC_ACTIVE count=$count"
    rm -f /tmp/sync-liked-if-stale.sh /tmp/supervise-liked-sync.sh /tmp/stop-liked-sync.sh
'
