#!/usr/bin/env bash

set -euo pipefail

DEVICE_IP=${1:-}
if [[ ! "$DEVICE_IP" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo '用法：host/deploy-music-takeover.sh 音箱IP' >&2
    exit 2
fi

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PASSWORD_FILE="$REPO_ROOT/.secrets/oh2p-root-password.txt"
KNOWN_HOSTS="$REPO_ROOT/.secrets/known_hosts_oh2p"
FILTER="$REPO_ROOT/artifacts/build/oh2p/lib/libxiaoaimusic_aivs_filter.so"
STAGING=$(mktemp -d)
REMOTE_STAGE="/tmp/xiaoaimusic-music-takeover.$$"
trap 'rm -rf -- "$STAGING"' EXIT

for file in "$FILTER" \
    "$REPO_ROOT/device/oh2p/voice-bridge.sh" \
    "$REPO_ROOT/device/oh2p/spotify-web-api.sh"; do
    [ -f "$file" ] || { echo "缺少构建产物：$file" >&2; exit 2; }
done

cp "$FILTER" "$STAGING/libxiaoaimusic_aivs_filter.so"
cp "$REPO_ROOT/device/oh2p/voice-bridge.sh" "$STAGING/"
cp "$REPO_ROOT/device/oh2p/spotify-web-api.sh" "$STAGING/"
(cd "$STAGING" && sha256sum \
    libxiaoaimusic_aivs_filter.so voice-bridge.sh spotify-web-api.sh >SHA256SUMS)

SSH_OPTIONS=(
    -o HostKeyAlgorithms=+ssh-rsa
    -o PubkeyAcceptedAlgorithms=+ssh-rsa
    -o StrictHostKeyChecking=yes
    -o "UserKnownHostsFile=$KNOWN_HOSTS"
)

sshpass -f "$PASSWORD_FILE" ssh "${SSH_OPTIONS[@]}" "root@$DEVICE_IP" \
    "rm -rf '$REMOTE_STAGE' && mkdir -m 700 '$REMOTE_STAGE'"
sshpass -f "$PASSWORD_FILE" scp -O "${SSH_OPTIONS[@]}" "$STAGING"/* \
    "root@$DEVICE_IP:$REMOTE_STAGE/"

sshpass -f "$PASSWORD_FILE" ssh "${SSH_OPTIONS[@]}" "root@$DEVICE_IP" \
    "REMOTE_STAGE='$REMOTE_STAGE' sh -s" <<'REMOTE'
set -eu

root=/data/xiaoaimusic
backup=$(mktemp -d "$root/backups/music-takeover.XXXXXX")
committed=0

restore() {
    [ "$committed" -eq 1 ] || return 0
    cp "$backup/libxiaoaimusic_aivs_filter.so" "$root/.aivs-filter.rollback"
    cp "$backup/voice-bridge.sh" "$root/.voice-bridge.rollback"
    cp "$backup/spotify-web-api.sh" "$root/.spotify-web-api.rollback"
    chmod 600 "$root/.aivs-filter.rollback"
    chmod 700 "$root/.voice-bridge.rollback" "$root/.spotify-web-api.rollback"
    mv -f "$root/.aivs-filter.rollback" "$root/lib/libxiaoaimusic_aivs_filter.so"
    mv -f "$root/.voice-bridge.rollback" "$root/voice-bridge.sh"
    mv -f "$root/.spotify-web-api.rollback" "$root/spotify-web-api.sh"
    "$root/activate-native-filters.sh" >/dev/null 2>&1 || true
    "$root/stop-voice-bridge.sh" >/dev/null 2>&1 || true
    "$root/run-voice-bridge.sh" >/dev/null 2>&1 || true
}
trap 'rc=$?; restore; rm -rf "$REMOTE_STAGE"; exit "$rc"' EXIT HUP INT TERM

cd "$REMOTE_STAGE"
busybox sha256sum -c SHA256SUMS
sh -n voice-bridge.sh
sh -n spotify-web-api.sh

test "$(busybox sha256sum /usr/bin/mico_aivs_lab | cut -d' ' -f1)" = \
    b2064cfcecba129a89d4dc01ff7a5acdd1515fe1a6b4ec3db876cd9c88d2a608
test "$(busybox sha256sum /usr/lib/libaivs_sdk.so | cut -d' ' -f1)" = \
    64150ecd6fdbddddd0944e177d26c45b9774306bd3ca5c19bce599080844eb9e

cp "$root/lib/libxiaoaimusic_aivs_filter.so" "$backup/"
cp "$root/voice-bridge.sh" "$backup/"
cp "$root/spotify-web-api.sh" "$backup/"
chmod 600 "$backup/libxiaoaimusic_aivs_filter.so"
chmod 700 "$backup/voice-bridge.sh" "$backup/spotify-web-api.sh"

cp libxiaoaimusic_aivs_filter.so "$root/.aivs-filter.music-new"
cp voice-bridge.sh "$root/.voice-bridge.music-new"
cp spotify-web-api.sh "$root/.spotify-web-api.music-new"
chmod 600 "$root/.aivs-filter.music-new"
chmod 700 "$root/.voice-bridge.music-new" "$root/.spotify-web-api.music-new"

"$root/stop-voice-bridge.sh" >/dev/null 2>&1 || true
mv -f "$root/.aivs-filter.music-new" "$root/lib/libxiaoaimusic_aivs_filter.so"
mv -f "$root/.voice-bridge.music-new" "$root/voice-bridge.sh"
mv -f "$root/.spotify-web-api.music-new" "$root/spotify-web-api.sh"
committed=1

"$root/activate-native-filters.sh"
"$root/run-voice-bridge.sh"
"$root/stop-native-music.sh" >/dev/null 2>&1 || true
"$root/spotify-web-api.sh" health

filter_ready=0
for pid in $(pidof mico_aivs_lab 2>/dev/null); do
    grep -q 'libxiaoaimusic_aivs_filter.so' "/proc/$pid/maps" 2>/dev/null && filter_ready=1
done
test "$filter_ready" -eq 1
voice_pid=$(cat /tmp/xiaoaimusic-voice-bridge.pid)
kill -0 "$voice_pid"

committed=0
trap - EXIT HUP INT TERM
rm -rf "$REMOTE_STAGE"
echo "MUSIC_TAKEOVER_DEPLOYED backup=$backup voice_pid=$voice_pid"
REMOTE
