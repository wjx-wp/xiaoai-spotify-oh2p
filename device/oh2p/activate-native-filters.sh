#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
NATIVE_DIR=$ROOT/native-init
ORIGINAL_DIR=$NATIVE_DIR/original
MICO_INIT=/etc/init.d/mico_aivs_lab
TOUCHPAD_INIT=/etc/init.d/touchpad
MICO_FILTER=$ROOT/lib/libxiaoaimusic_aivs_filter.so
TOUCHPAD_FILTER=$ROOT/lib/libxiaoaimusic_touchpad_filter.so

is_bound() {
    awk -v target="$1" '$2 == target { found=1 } END { exit !found }' /proc/mounts
}

stop_temporary_probes() {
    for name in xiaoaimusic-aivs-active xiaoaimusic-aivs-active-guard \
        xiaoaimusic-touchpad-filter xiaoaimusic-touchpad-guard; do
        pid_file="/tmp/$name.pid"
        if [ -s "$pid_file" ]; then
            pid=$(cat "$pid_file" 2>/dev/null || true)
            [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
        fi
        rm -f "$pid_file"
    done
    rm -f /tmp/xiaoaimusic-aivs-filter-active
}

restore_original_services() {
    /etc/init.d/mico_aivs_lab stop >/dev/null 2>&1 || true
    /etc/init.d/touchpad stop >/dev/null 2>&1 || true
    is_bound "$MICO_INIT" && umount "$MICO_INIT" || true
    is_bound "$TOUCHPAD_INIT" && umount "$TOUCHPAD_INIT" || true
    /etc/init.d/mico_aivs_lab start >/dev/null 2>&1 || true
    /etc/init.d/touchpad start >/dev/null 2>&1 || true
}

[ -f "$MICO_FILTER" ] && [ -f "$TOUCHPAD_FILTER" ] || {
    echo '缺少原生过滤器库' >&2
    exit 2
}
MICO_HASH=$(busybox sha256sum /usr/bin/mico_aivs_lab | cut -d' ' -f1)
SDK_HASH=$(busybox sha256sum /usr/lib/libaivs_sdk.so | cut -d' ' -f1)
test "$MICO_HASH" = b2064cfcecba129a89d4dc01ff7a5acdd1515fe1a6b4ec3db876cd9c88d2a608
test "$SDK_HASH" = 64150ecd6fdbddddd0944e177d26c45b9774306bd3ca5c19bce599080844eb9e

mkdir -p "$ORIGINAL_DIR"
if [ ! -f "$ORIGINAL_DIR/mico_aivs_lab" ]; then
    is_bound "$MICO_INIT" && umount "$MICO_INIT" || true
    cp "$MICO_INIT" "$ORIGINAL_DIR/mico_aivs_lab"
fi
if [ ! -f "$ORIGINAL_DIR/touchpad" ]; then
    is_bound "$TOUCHPAD_INIT" && umount "$TOUCHPAD_INIT" || true
    cp "$TOUCHPAD_INIT" "$ORIGINAL_DIR/touchpad"
fi

awk -v filter="$MICO_FILTER" '
    { print }
    /procd_set_param command \/usr\/bin\/mico_aivs_lab/ {
        print "    # xiaoaimusic-native-filter"
        print "    procd_set_param env XIAOAI_FILTER_MODE=active LD_PRELOAD=" filter
    }
' "$ORIGINAL_DIR/mico_aivs_lab" >"$NATIVE_DIR/mico_aivs_lab"
awk -v filter="$TOUCHPAD_FILTER" '
    { print }
    /procd_set_param command \/bin\/touchpad/ {
        print "  # xiaoaimusic-native-filter"
        print "  procd_set_param env LD_PRELOAD=" filter
    }
' "$ORIGINAL_DIR/touchpad" >"$NATIVE_DIR/touchpad"
chmod 755 "$NATIVE_DIR/mico_aivs_lab" "$NATIVE_DIR/touchpad"
grep -q xiaoaimusic-native-filter "$NATIVE_DIR/mico_aivs_lab"
grep -q xiaoaimusic-native-filter "$NATIVE_DIR/touchpad"

stop_temporary_probes
/etc/init.d/mico_aivs_lab stop >/dev/null 2>&1 || true
/etc/init.d/touchpad stop >/dev/null 2>&1 || true
is_bound "$MICO_INIT" && umount "$MICO_INIT" || true
is_bound "$TOUCHPAD_INIT" && umount "$TOUCHPAD_INIT" || true
mount -o bind "$NATIVE_DIR/mico_aivs_lab" "$MICO_INIT"
mount -o bind "$NATIVE_DIR/touchpad" "$TOUCHPAD_INIT"
/etc/init.d/mico_aivs_lab start >/dev/null 2>&1 || { restore_original_services; exit 1; }
/etc/init.d/touchpad start >/dev/null 2>&1 || { restore_original_services; exit 1; }
sleep 5

mico_ready=0
for pid in $(pidof mico_aivs_lab 2>/dev/null); do
    grep -q 'libxiaoaimusic_aivs_filter.so' "/proc/$pid/maps" 2>/dev/null && mico_ready=1
done
touchpad_ready=0
for pid in $(pidof touchpad 2>/dev/null); do
    grep -q 'libxiaoaimusic_touchpad_filter.so' "/proc/$pid/maps" 2>/dev/null && touchpad_ready=1
done
if [ "$mico_ready" -ne 1 ] || [ "$touchpad_ready" -ne 1 ]; then
    echo '原生过滤器加载验证失败，已回滚' >&2
    restore_original_services
    exit 1
fi
echo NATIVE_FILTERS_ACTIVE
