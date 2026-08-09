#!/usr/bin/env bash

set -euo pipefail

DEVICE_IP=${1:-}
PLAY_CODE=${2:-114}
if [[ ! "$DEVICE_IP" =~ ^[A-Za-z0-9.-]+$ ]] || [[ ! "$PLAY_CODE" =~ ^[0-9]+$ ]]; then
    echo '用法：host/deploy-keybridge-active.sh 音箱IP [播放键码]' >&2
    exit 2
fi

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PASSWORD_FILE="$REPO_ROOT/.secrets/oh2p-root-password.txt"
KNOWN_HOSTS="$REPO_ROOT/.secrets/known_hosts_oh2p"
STAGING=$(mktemp -d)
trap 'rm -rf -- "$STAGING"' EXIT
cp "$REPO_ROOT/artifacts/build/oh2p/bin/xiaoaimusic-keybridge" "$STAGING/"
cp "$REPO_ROOT/device/oh2p/spotify-web-api.sh" "$STAGING/"
cp "$REPO_ROOT/device/oh2p/spotify-button-action.sh" "$STAGING/"
chmod 700 "$STAGING"/*
SSH_OPTIONS=(
    -o HostKeyAlgorithms=+ssh-rsa
    -o PubkeyAcceptedAlgorithms=+ssh-rsa
    -o StrictHostKeyChecking=yes
    -o "UserKnownHostsFile=$KNOWN_HOSTS"
)

sshpass -f "$PASSWORD_FILE" ssh "${SSH_OPTIONS[@]}" "root@$DEVICE_IP" '
    if [ -s /tmp/xiaoaimusic-keybridge-observe.pid ]; then
        kill "$(cat /tmp/xiaoaimusic-keybridge-observe.pid)" 2>/dev/null || true
    fi
    if [ -s /tmp/xiaoaimusic-keybridge.pid ]; then
        kill "$(cat /tmp/xiaoaimusic-keybridge.pid)" 2>/dev/null || true
    fi
    sleep 1
'
sshpass -f "$PASSWORD_FILE" scp -O "${SSH_OPTIONS[@]}" "$STAGING"/* \
    "root@$DEVICE_IP:/tmp/"
sshpass -f "$PASSWORD_FILE" ssh "${SSH_OPTIONS[@]}" "root@$DEVICE_IP" "
    set -e
    mkdir -p /data/xiaoaimusic/bin
    [ -f /data/xiaoaimusic/spotify-web-api.sh.pre-keybridge ] || \
        cp -p /data/xiaoaimusic/spotify-web-api.sh \
            /data/xiaoaimusic/spotify-web-api.sh.pre-keybridge
    cp /tmp/xiaoaimusic-keybridge /data/xiaoaimusic/bin/
    cp /tmp/spotify-web-api.sh /data/xiaoaimusic/
    cp /tmp/spotify-button-action.sh /data/xiaoaimusic/
    chmod 700 /data/xiaoaimusic/bin/xiaoaimusic-keybridge \
        /data/xiaoaimusic/spotify-web-api.sh \
        /data/xiaoaimusic/spotify-button-action.sh
    rm -f /tmp/xiaoaimusic-keybridge.log /tmp/xiaoaimusic-keybridge.pid
    /sbin/start-stop-daemon -S -b -m -p /tmp/xiaoaimusic-keybridge.pid \
        -x /bin/sh -- -c \"exec /data/xiaoaimusic/bin/xiaoaimusic-keybridge \
        --play-code $PLAY_CODE >/dev/null 2>/tmp/xiaoaimusic-keybridge.log\"
    sleep 1
    kill -0 \"\$(cat /tmp/xiaoaimusic-keybridge.pid)\"
    /data/xiaoaimusic/spotify-web-api.sh health
    cat /tmp/xiaoaimusic-keybridge.log
"
