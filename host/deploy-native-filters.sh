#!/usr/bin/env bash

set -euo pipefail

DEVICE_IP=${1:-}
if [[ ! "$DEVICE_IP" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo '用法：host/deploy-native-filters.sh 音箱IP' >&2
    exit 2
fi

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PASSWORD_FILE="$REPO_ROOT/.secrets/oh2p-root-password.txt"
KNOWN_HOSTS="$REPO_ROOT/.secrets/known_hosts_oh2p"
STAGING=$(mktemp -d)
trap 'rm -rf -- "$STAGING"' EXIT
mkdir -p "$STAGING/bin" "$STAGING/lib"
cp "$REPO_ROOT/artifacts/build/oh2p/bin/xiaoaimusic-keybridge" "$STAGING/bin/"
cp "$REPO_ROOT/artifacts/build/oh2p/bin/xiaoaimusic-log-follower" "$STAGING/bin/"
cp "$REPO_ROOT/artifacts/build/oh2p/lib/libxiaoaimusic_aivs_filter.so" "$STAGING/lib/"
cp "$REPO_ROOT/artifacts/build/oh2p/lib/libxiaoaimusic_touchpad_filter.so" "$STAGING/lib/"
for file in activate-native-filters.sh deactivate-native-filters.sh \
    voice-bridge.sh run-keybridge.sh stop-keybridge.sh spotify-button-action.sh \
    sync-liked-if-stale.sh supervise-liked-sync.sh stop-liked-sync.sh \
    spotify-web-api.sh; do
    cp "$REPO_ROOT/device/oh2p/$file" "$STAGING/"
done
SSH_OPTIONS=(
    -o HostKeyAlgorithms=+ssh-rsa
    -o PubkeyAcceptedAlgorithms=+ssh-rsa
    -o StrictHostKeyChecking=yes
    -o "UserKnownHostsFile=$KNOWN_HOSTS"
)

sshpass -f "$PASSWORD_FILE" ssh "${SSH_OPTIONS[@]}" "root@$DEVICE_IP" \
    'rm -rf /tmp/xiaoaimusic-native-stage && mkdir -p /tmp/xiaoaimusic-native-stage/bin /tmp/xiaoaimusic-native-stage/lib'
sshpass -f "$PASSWORD_FILE" scp -O -r "${SSH_OPTIONS[@]}" "$STAGING"/* \
    "root@$DEVICE_IP:/tmp/xiaoaimusic-native-stage/"
sshpass -f "$PASSWORD_FILE" ssh "${SSH_OPTIONS[@]}" "root@$DEVICE_IP" '
    set -e
    mkdir -p /data/xiaoaimusic/bin /data/xiaoaimusic/lib
    cp /tmp/xiaoaimusic-native-stage/bin/xiaoaimusic-keybridge /data/xiaoaimusic/bin/
    cp /tmp/xiaoaimusic-native-stage/bin/xiaoaimusic-log-follower /data/xiaoaimusic/bin/
    cp /tmp/xiaoaimusic-native-stage/lib/*.so /data/xiaoaimusic/lib/
    cp /tmp/xiaoaimusic-native-stage/*.sh /data/xiaoaimusic/
    chmod 700 /data/xiaoaimusic/bin/xiaoaimusic-keybridge \
        /data/xiaoaimusic/bin/xiaoaimusic-log-follower /data/xiaoaimusic/*.sh
    chmod 600 /data/xiaoaimusic/lib/*.so
    /data/xiaoaimusic/activate-native-filters.sh
    /data/xiaoaimusic/stop-voice-bridge.sh >/dev/null 2>&1 || true
    /data/xiaoaimusic/run-voice-bridge.sh
    /data/xiaoaimusic/stop-keybridge.sh >/dev/null 2>&1 || true
    /data/xiaoaimusic/run-keybridge.sh
    /data/xiaoaimusic/stop-liked-sync.sh >/dev/null 2>&1 || true
    /data/xiaoaimusic/supervise-liked-sync.sh >>/tmp/xiaoaimusic-liked-sync.log 2>&1 &
    /data/xiaoaimusic/spotify-web-api.sh health
    rm -rf /tmp/xiaoaimusic-native-stage
'
