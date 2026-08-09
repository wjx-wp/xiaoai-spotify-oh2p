#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 1 ] || [[ ! "$1" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo "用法：host/deploy-spotify-auth.sh 音箱IP" >&2
    exit 2
fi

DEVICE_IP=$1
REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ENV_FILE="$REPO_ROOT/.env"
TOKEN_JSON="$REPO_ROOT/.spotify-token.json"
PASSWORD_FILE="$REPO_ROOT/.secrets/oh2p-root-password.txt"
KNOWN_HOSTS="$REPO_ROOT/.secrets/known_hosts_oh2p"

for required_file in "$ENV_FILE" "$TOKEN_JSON" "$PASSWORD_FILE" "$KNOWN_HOSTS"; do
    if [ ! -s "$required_file" ]; then
        echo "缺少 $required_file" >&2
        exit 2
    fi
done

CLIENT_ID=$(sed -n 's/^SPOTIFY_CLIENT_ID=//p' "$ENV_FILE" | tail -n 1 | tr -d '\r')
DEVICE_NAME=$(sed -n 's/^SPOTIFY_DEVICE_NAME=//p' "$ENV_FILE" | tail -n 1 | tr -d '\r')
REFRESH_TOKEN=$(jq -r '.refresh_token // empty' "$TOKEN_JSON")
AUTHORIZED_AT=$(jq -r '.authorized_at // empty' "$TOKEN_JSON")

if [[ ! "$CLIENT_ID" =~ ^[A-Za-z0-9]+$ ]]; then
    echo "SPOTIFY_CLIENT_ID 格式无效" >&2
    exit 2
fi
if [[ -z "$DEVICE_NAME" || ! "$DEVICE_NAME" =~ ^[A-Za-z0-9._\ -]+$ ]]; then
    echo "SPOTIFY_DEVICE_NAME 格式无效" >&2
    exit 2
fi
if [ -z "$REFRESH_TOKEN" ]; then
    echo ".spotify-token.json 缺少 refresh_token" >&2
    exit 2
fi
if [[ ! "$AUTHORIZED_AT" =~ ^[0-9]+$ ]]; then
    AUTHORIZED_AT=$(date +%s)000
fi

STAGING_DIR=$(mktemp -d)
trap 'rm -rf -- "$STAGING_DIR"' EXIT
printf "SPOTIFY_CLIENT_ID='%s'\nSPOTIFY_DEVICE_NAME='%s'\n" \
    "$CLIENT_ID" "$DEVICE_NAME" >"$STAGING_DIR/spotify-web.env"
printf '%s\n' "$REFRESH_TOKEN" >"$STAGING_DIR/spotify-refresh-token"
printf '%s\n' "$AUTHORIZED_AT" >"$STAGING_DIR/spotify-authorized-at-ms"
cp "$REPO_ROOT/device/oh2p/spotify-web-api.sh" "$STAGING_DIR/spotify-web-api.sh"
cp "$REPO_ROOT/device/oh2p/run-librespot.sh" "$STAGING_DIR/run-librespot.sh"
chmod 600 "$STAGING_DIR"/*
chmod 700 "$STAGING_DIR/spotify-web-api.sh" "$STAGING_DIR/run-librespot.sh"

SSH_OPTIONS=(
    -o HostKeyAlgorithms=+ssh-rsa
    -o PubkeyAcceptedAlgorithms=+ssh-rsa
    -o StrictHostKeyChecking=yes
    -o "UserKnownHostsFile=$KNOWN_HOSTS"
)

SSHPASS=$(cat "$PASSWORD_FILE")
export SSHPASS
sshpass -e ssh "${SSH_OPTIONS[@]}" "root@$DEVICE_IP" \
    'rm -rf /tmp/xiaoaimusic-spotify-auth && mkdir -m 700 /tmp/xiaoaimusic-spotify-auth'
sshpass -e scp -O "${SSH_OPTIONS[@]}" "$STAGING_DIR"/* \
    "root@$DEVICE_IP:/tmp/xiaoaimusic-spotify-auth/"
sshpass -e ssh "${SSH_OPTIONS[@]}" "root@$DEVICE_IP" '
    set -e
    cp /tmp/xiaoaimusic-spotify-auth/spotify-web.env /data/xiaoaimusic/spotify-web.env
    cp /tmp/xiaoaimusic-spotify-auth/spotify-refresh-token /data/xiaoaimusic/spotify-refresh-token
    cp /tmp/xiaoaimusic-spotify-auth/spotify-authorized-at-ms /data/xiaoaimusic/spotify-authorized-at-ms
    cp /tmp/xiaoaimusic-spotify-auth/spotify-web-api.sh /data/xiaoaimusic/spotify-web-api.sh
    cp /tmp/xiaoaimusic-spotify-auth/run-librespot.sh /data/xiaoaimusic/run-librespot.sh
    chmod 600 /data/xiaoaimusic/spotify-web.env /data/xiaoaimusic/spotify-refresh-token /data/xiaoaimusic/spotify-authorized-at-ms
    chmod 700 /data/xiaoaimusic/spotify-web-api.sh /data/xiaoaimusic/run-librespot.sh
    rm -f /data/xiaoaimusic/spotify-reauthorization-required
    rm -f /tmp/xiaoaimusic-spotify-access-token /tmp/xiaoaimusic-spotify-access-expiry
    . /data/xiaoaimusic/spotify-web.env
    DEVICE_ENV=/data/xiaoaimusic/device.env
    if [ -f "$DEVICE_ENV" ] && [ ! -f "$DEVICE_ENV.pre-xiaoai-music" ]; then
        cp -p "$DEVICE_ENV" "$DEVICE_ENV.pre-xiaoai-music"
    fi
    if grep -q "^SPOTIFY_DEVICE_NAME=" "$DEVICE_ENV" 2>/dev/null; then
        sed -i "s/^SPOTIFY_DEVICE_NAME=.*/SPOTIFY_DEVICE_NAME=\"$SPOTIFY_DEVICE_NAME\"/" "$DEVICE_ENV"
    else
        printf "SPOTIFY_DEVICE_NAME=\"%s\"\n" "$SPOTIFY_DEVICE_NAME" >>"$DEVICE_ENV"
    fi
    rm -rf /tmp/xiaoaimusic-spotify-auth
    /data/xiaoaimusic/stop-librespot.sh
    sleep 1
    /data/xiaoaimusic/run-librespot.sh
    health_output=
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        if health_output=$(/data/xiaoaimusic/spotify-web-api.sh health 2>&1); then
            printf "%s\n" "$health_output"
            exit 0
        fi
        sleep 2
    done
    printf "%s\n" "$health_output" >&2
    exit 1
'

echo "新的 Spotify PKCE 授权已安全部署到音箱，旧失效标记已清除，并通过 API 健康检查。"
