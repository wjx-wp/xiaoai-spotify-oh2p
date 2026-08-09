#!/bin/sh

set -eu

SOURCE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TARGET_DIR=/data/xiaoaimusic
VERSION_FILE=/usr/share/mico/version
INSTALL_STAGE=

cleanup_stages() {
    [ -z "$INSTALL_STAGE" ] || rm -f "$INSTALL_STAGE"
}
trap cleanup_stages EXIT
trap 'cleanup_stages; exit 129' HUP
trap 'cleanup_stages; exit 130' INT
trap 'cleanup_stages; exit 143' TERM

install_file() {
    install_source=$1
    install_target=$2
    install_mode=$3
    install_directory=${install_target%/*}
    install_name=${install_target##*/}
    [ ! -L "$install_target" ] && [ ! -d "$install_target" ] || return 1
    INSTALL_STAGE=$(mktemp "$install_directory/.${install_name}.install.XXXXXX") || return 1
    cp "$install_source" "$INSTALL_STAGE" &&
        chown root:root "$INSTALL_STAGE" &&
        chmod "$install_mode" "$INSTALL_STAGE" &&
        mv "$INSTALL_STAGE" "$install_target" || return 1
    INSTALL_STAGE=
}

if [ ! -r "$VERSION_FILE" ] || ! grep -q "OH2P" "$VERSION_FILE"; then
    echo "拒绝安装：设备系统未确认是 OH2P" >&2
    exit 2
fi

for required_command in awk cmp ls mktemp mount readlink umount; do
    command -v "$required_command" >/dev/null 2>&1 || {
        echo "Device is missing required command: $required_command" >&2
        exit 2
    }
done
[ -x /usr/bin/flock ] && [ -x /bin/fsync ] || {
    echo 'Device is missing /usr/bin/flock or /bin/fsync.' >&2
    exit 2
}

INSTALL_SCRIPTS='run-librespot.sh stop-librespot.sh supervise-librespot.sh healthcheck.sh audio-probe.sh init-snippet.sh stop-native-music.sh capture-music-intent.sh spotify-web-api.sh voice-bridge.sh run-voice-bridge.sh stop-voice-bridge.sh run-keybridge.sh stop-keybridge.sh stop-home-bridge.sh mount-mobile-auth.sh spotify-button-action.sh sync-liked-if-stale.sh supervise-liked-sync.sh stop-liked-sync.sh activate-native-filters.sh deactivate-native-filters.sh install-autostart.sh remove-autostart.sh'
for required in bin/librespot \
    bin/xiaoaimusic-keybridge bin/xiaoaimusic-log-follower \
    bin/xiaoaimusic-spotify-auth-updater \
    bin/xiaoaimusic-authorized-keys-verify \
    lib/libxiaoaimusic_aivs_filter.so lib/libxiaoaimusic_touchpad_filter.so \
    device.env.example spotify-web.env.example $INSTALL_SCRIPTS; do
    [ -f "$SOURCE_DIR/$required" ] && [ ! -L "$SOURCE_DIR/$required" ] || {
        echo "拒绝安装：安装包缺少 $required" >&2
        exit 3
    }
done

for target_path in "$TARGET_DIR" "$TARGET_DIR/bin" "$TARGET_DIR/lib" \
    "$TARGET_DIR/cache" "$TARGET_DIR/cache/librespot" \
    "$TARGET_DIR/device.env" "$TARGET_DIR/spotify-web.env"; do
    [ ! -L "$target_path" ] || {
        echo "Refusing symlink installation target: $target_path" >&2
        exit 3
    }
done
LC_ALL=C ls -ldn /data 2>/dev/null | awk '
    NR == 1 && $1 ~ /^d/ && $3 == 0 &&
    substr($1, 6, 1) != "w" && substr($1, 9, 1) != "w" { trusted=1 }
    END { exit(trusted ? 0 : 1) }
' || { echo '/data is not a trusted root-owned directory.' >&2; exit 3; }
mkdir -p "$TARGET_DIR/bin" "$TARGET_DIR/lib" "$TARGET_DIR/cache/librespot"
chown root:root "$TARGET_DIR" "$TARGET_DIR/bin" "$TARGET_DIR/lib" \
    "$TARGET_DIR/cache" "$TARGET_DIR/cache/librespot"
chmod 700 "$TARGET_DIR" "$TARGET_DIR/bin" "$TARGET_DIR/lib" \
    "$TARGET_DIR/cache" "$TARGET_DIR/cache/librespot"
install_file "$SOURCE_DIR/bin/librespot" "$TARGET_DIR/bin/librespot" 700
install_file "$SOURCE_DIR/bin/xiaoaimusic-keybridge" \
    "$TARGET_DIR/bin/xiaoaimusic-keybridge" 700
install_file "$SOURCE_DIR/bin/xiaoaimusic-log-follower" \
    "$TARGET_DIR/bin/xiaoaimusic-log-follower" 700
install_file "$SOURCE_DIR/bin/xiaoaimusic-spotify-auth-updater" \
    "$TARGET_DIR/bin/xiaoaimusic-spotify-auth-updater" 700
install_file "$SOURCE_DIR/bin/xiaoaimusic-authorized-keys-verify" \
    "$TARGET_DIR/bin/xiaoaimusic-authorized-keys-verify" 700
install_file "$SOURCE_DIR/lib/libxiaoaimusic_aivs_filter.so" \
    "$TARGET_DIR/lib/libxiaoaimusic_aivs_filter.so" 600
install_file "$SOURCE_DIR/lib/libxiaoaimusic_touchpad_filter.so" \
    "$TARGET_DIR/lib/libxiaoaimusic_touchpad_filter.so" 600
for file in $INSTALL_SCRIPTS; do
    install_file "$SOURCE_DIR/$file" "$TARGET_DIR/$file" 700
done

if [ ! -e "$TARGET_DIR/device.env" ]; then
    install_file "$SOURCE_DIR/device.env.example" "$TARGET_DIR/device.env" 600
else
    [ -f "$TARGET_DIR/device.env" ] && [ ! -L "$TARGET_DIR/device.env" ] || exit 3
    chown root:root "$TARGET_DIR/device.env"
    chmod 600 "$TARGET_DIR/device.env"
fi
if [ ! -e "$TARGET_DIR/spotify-web.env" ]; then
    install_file "$SOURCE_DIR/spotify-web.env.example" "$TARGET_DIR/spotify-web.env" 600
else
    [ -f "$TARGET_DIR/spotify-web.env" ] && [ ! -L "$TARGET_DIR/spotify-web.env" ] || exit 3
    chown root:root "$TARGET_DIR/spotify-web.env"
    chmod 600 "$TARGET_DIR/spotify-web.env"
fi

chmod 700 "$TARGET_DIR" "$TARGET_DIR/bin" "$TARGET_DIR/lib" "$TARGET_DIR/cache" "$TARGET_DIR/cache/librespot"

trap - EXIT HUP INT TERM

echo "安装完成，但尚未启动、也未修改 /data/init.sh。"
echo "先运行：$TARGET_DIR/run-librespot.sh"
