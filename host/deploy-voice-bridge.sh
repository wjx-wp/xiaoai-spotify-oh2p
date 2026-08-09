#!/usr/bin/env bash

set -euo pipefail

DEVICE_IP=${1:-}
if [[ ! "$DEVICE_IP" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo '用法：host/deploy-voice-bridge.sh 音箱IP' >&2
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
    "$REPO_ROOT/device/oh2p/voice-bridge.sh" \
    "$REPO_ROOT/device/oh2p/spotify-web-api.sh" \
    "$REPO_ROOT/artifacts/build/oh2p/bin/xiaoaimusic-log-follower" \
    "root@$DEVICE_IP:/tmp/"
sshpass -f "$PASSWORD_FILE" ssh "${SSH_OPTIONS[@]}" "root@$DEVICE_IP" '
    set -e
    cp /tmp/voice-bridge.sh /data/xiaoaimusic/voice-bridge.sh
    cp /tmp/spotify-web-api.sh /data/xiaoaimusic/spotify-web-api.sh
    cp /tmp/xiaoaimusic-log-follower /data/xiaoaimusic/bin/xiaoaimusic-log-follower
    chmod 700 /data/xiaoaimusic/voice-bridge.sh /data/xiaoaimusic/spotify-web-api.sh \
        /data/xiaoaimusic/bin/xiaoaimusic-log-follower
    /data/xiaoaimusic/stop-voice-bridge.sh >/dev/null 2>&1 || true
    /data/xiaoaimusic/run-voice-bridge.sh
    /data/xiaoaimusic/spotify-web-api.sh health
    rm -f /tmp/voice-bridge.sh /tmp/spotify-web-api.sh /tmp/xiaoaimusic-log-follower
'
