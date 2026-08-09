#!/bin/sh

echo "model:"
grep -E "HARDWARE|VERSION|ROM" /usr/share/mico/version 2>/dev/null || true
echo "librespot:"
ps w 2>/dev/null | grep '[l]ibrespot' || true
echo "supervisor:"
ps w 2>/dev/null | grep '[s]upervise-librespot' || true
echo "voice bridge:"
ps w 2>/dev/null | grep '[v]oice-bridge.sh' || true
echo "key bridge:"
ps w 2>/dev/null | grep '[x]iaoaimusic-keybridge' || true
echo "local control:"
ls -l /tmp/xiaoaimusic-librespot-control.sock 2>/dev/null || true
echo "legacy home takeover bridge:"
if ps w 2>/dev/null | grep -q '[x]iaoaimusic-home-bridge' ||
   netstat -lnt 2>/dev/null | grep -q ':18789[[:space:]]'; then
    echo "legacy_home_bridge=UNEXPECTED_ACTIVE port=18789"
else
    echo "legacy_home_bridge=inactive port=18789"
fi
echo "mobile spotify authorization updater:"
ls -l /data/xiaoaimusic/bin/xiaoaimusic-spotify-auth-updater \
    /data/xiaoaimusic/bin/xiaoaimusic-authorized-keys-verify \
    /data/xiaoaimusic/mount-mobile-auth.sh 2>/dev/null || true
if [ -e /data/etc/dropbear/authorized_keys ]; then
    ls -l /data/etc/dropbear/authorized_keys 2>/dev/null || true
    echo "pairing_metadata=present"
else
    echo "pairing_metadata=absent"
fi
MOBILE_AUTH_RECORD=$(awk '$5 == "/etc/dropbear/authorized_keys" {
    count++; record=$3 "|" $4
} END { if (count == 1) print record }' /proc/self/mountinfo 2>/dev/null || true)
MOBILE_AUTH_EXPECTED=$(awk -v path=/data/etc/dropbear/authorized_keys '
    function contains(path, mountpoint) {
        return mountpoint == "/" || path == mountpoint || index(path, mountpoint "/") == 1
    }
    contains(path, $5) && length($5) > best {
        best=length($5); mountpoint=$5; root=$4; device=$3
    }
    END {
        if (!best) exit
        if (mountpoint == "/") relative=substr(path, 2)
        else relative=substr(path, length(mountpoint) + 2)
        expected=(relative == "" ? root : (root == "/" ? "/" relative : root "/" relative))
        print device "|" expected
    }
' /proc/self/mountinfo 2>/dev/null || true)
if [ -n "$MOBILE_AUTH_RECORD" ]; then
    if [ "$MOBILE_AUTH_RECORD" = "$MOBILE_AUTH_EXPECTED" ] && \
            cmp -s /data/etc/dropbear/authorized_keys /etc/dropbear/authorized_keys && \
            /data/xiaoaimusic/bin/xiaoaimusic-authorized-keys-verify \
                --require-mobile /etc/dropbear/authorized_keys >/dev/null 2>&1; then
        echo "mobile_auth_bind=active"
    else
        echo "mobile_auth_bind=foreign"
    fi
else
    echo "mobile_auth_bind=inactive"
fi
echo "liked sync:"
ps w 2>/dev/null | grep '[s]upervise-liked-sync.sh' || true
[ ! -s /data/xiaoaimusic/liked-mirror-last-sync ] || {
    printf 'last_sync_epoch='
    cat /data/xiaoaimusic/liked-mirror-last-sync
}
echo "native filters:"
for process in mico_aivs_lab touchpad; do
    for pid in $(pidof "$process" 2>/dev/null); do
        echo "$process pid=$pid"
        grep 'libxiaoaimusic_.*_filter.so' "/proc/$pid/maps" 2>/dev/null || true
    done
done
echo "spotify web api:"
if [ -e /data/xiaoaimusic/spotify-reauthorization-required ]; then
    echo "authorization_marker=AUTH_EXPIRED（请在手机“小爱 Spotify 接管”应用中重新授权）"
    ls -l /data/xiaoaimusic/spotify-reauthorization-required 2>/dev/null || true
else
    echo "authorization_marker=clear"
fi
/data/xiaoaimusic/spotify-web-api.sh health 2>&1 || true
echo "audio devices:"
aplay -l 2>/dev/null || true
echo "mixer:"
amixer sget mysoftvol 2>/dev/null || true
echo "recent log:"
tail -n 60 /tmp/xiaoaimusic-librespot.log 2>/dev/null || true
