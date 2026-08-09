#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE_SCRIPT="$REPO_ROOT/device/oh2p/install.sh"
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT

PACKAGE="$WORK/package"
TARGET="$WORK/data/xiaoaimusic"
VERSION="$WORK/version"
mkdir -p "$PACKAGE/bin" "$PACKAGE/lib" "$WORK/data"
chmod 755 "$WORK/data"
printf 'HARDWARE=OH2P\n' >"$VERSION"
printf '#!/bin/sh\nexit 0\n' >"$WORK/flock"
printf '#!/bin/sh\nexit 0\n' >"$WORK/fsync"
chmod 755 "$WORK/flock" "$WORK/fsync"

INSTALL_SCRIPTS='run-librespot.sh stop-librespot.sh supervise-librespot.sh healthcheck.sh audio-probe.sh init-snippet.sh stop-native-music.sh capture-music-intent.sh spotify-web-api.sh voice-bridge.sh run-voice-bridge.sh stop-voice-bridge.sh run-keybridge.sh stop-keybridge.sh stop-home-bridge.sh mount-mobile-auth.sh spotify-button-action.sh sync-liked-if-stale.sh supervise-liked-sync.sh stop-liked-sync.sh activate-native-filters.sh deactivate-native-filters.sh install-autostart.sh remove-autostart.sh'

for binary in librespot xiaoaimusic-keybridge xiaoaimusic-log-follower \
    xiaoaimusic-spotify-auth-updater xiaoaimusic-authorized-keys-verify; do
    printf 'package-%s\n' "$binary" >"$PACKAGE/bin/$binary"
done
for library in libxiaoaimusic_aivs_filter.so libxiaoaimusic_touchpad_filter.so; do
    printf 'package-%s\n' "$library" >"$PACKAGE/lib/$library"
done
for script in $INSTALL_SCRIPTS; do
    printf '#!/bin/sh\nexit 0\n' >"$PACKAGE/$script"
done
printf 'DEVICE_CONFIG=1\n' >"$PACKAGE/device.env.example"
printf 'SPOTIFY_CLIENT_ID=test\n' >"$PACKAGE/spotify-web.env.example"

sed \
    -e "s|^TARGET_DIR=/data/xiaoaimusic$|TARGET_DIR=$TARGET|" \
    -e "s|^VERSION_FILE=/usr/share/mico/version$|VERSION_FILE=$VERSION|" \
    -e "s|LC_ALL=C ls -ldn /data|LC_ALL=C ls -ldn $WORK/data|" \
    -e "s|\[ -x /usr/bin/flock \] && \[ -x /bin/fsync \]|[ -x $WORK/flock ] \&\& [ -x $WORK/fsync ]|" \
    "$SOURCE_SCRIPT" >"$PACKAGE/install.sh"
chmod 700 "$PACKAGE/install.sh"

mkdir -p "$TARGET/bin"
printf 'victim-sentinel\n' >"$WORK/victim"
ln -s "$WORK/victim" "$TARGET/bin/librespot"
if "$PACKAGE/install.sh" >"$WORK/symlink.out" 2>"$WORK/symlink.err"; then
    echo 'Installer unexpectedly accepted a symlink binary target.' >&2
    exit 1
fi
grep -qx 'victim-sentinel' "$WORK/victim"
rm "$TARGET/bin/librespot"

# Atomic rename replaces an old hardlink directory entry instead of truncating
# the inode shared with an unrelated file.
ln "$WORK/victim" "$TARGET/bin/xiaoaimusic-keybridge"
"$PACKAGE/install.sh"
grep -qx 'victim-sentinel' "$WORK/victim"
grep -qx 'package-xiaoaimusic-keybridge' "$TARGET/bin/xiaoaimusic-keybridge"
[ "$(stat -c %h "$WORK/victim")" -eq 1 ]

for directory in "$TARGET" "$TARGET/bin" "$TARGET/lib" \
    "$TARGET/cache" "$TARGET/cache/librespot"; do
    [ "$(stat -c %u:%a "$directory")" = 0:700 ]
done
for binary in librespot xiaoaimusic-keybridge xiaoaimusic-log-follower \
    xiaoaimusic-spotify-auth-updater xiaoaimusic-authorized-keys-verify; do
    [ "$(stat -c %u:%a "$TARGET/bin/$binary")" = 0:700 ]
done
for script in $INSTALL_SCRIPTS; do
    [ "$(stat -c %u:%a "$TARGET/$script")" = 0:700 ]
done
for library in libxiaoaimusic_aivs_filter.so libxiaoaimusic_touchpad_filter.so; do
    [ "$(stat -c %u:%a "$TARGET/lib/$library")" = 0:600 ]
done
[ "$(stat -c %u:%a "$TARGET/device.env")" = 0:600 ]
[ "$(stat -c %u:%a "$TARGET/spotify-web.env")" = 0:600 ]
[ ! -e "$WORK/data/init.sh" ]
[ ! -e "$TARGET/bin/xiaoaimusic-home-bridge" ]
[ ! -e "$TARGET/run-home-bridge.sh" ]
! find "$TARGET" -type f -name '.*.install.*' | grep -q .

echo INSTALL_PACKAGE_TESTS_OK
