#!/usr/bin/env bash

set -euo pipefail

DEVICE_IP=${1:-}
REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SSH_OPTIONS=(
    -o HostKeyAlgorithms=+ssh-rsa
    -o PubkeyAcceptedAlgorithms=+ssh-rsa
    -o StrictHostKeyChecking=yes
    -o "UserKnownHostsFile=$REPO_ROOT/.secrets/known_hosts_oh2p"
)

sshpass -f "$REPO_ROOT/.secrets/oh2p-root-password.txt" \
    ssh "${SSH_OPTIONS[@]}" "root@$DEVICE_IP" '
        echo STATUS
        ps w | grep -E "mico_aivs_lab|librespot|voice-bridge|keybridge|home-bridge|supervise-liked-sync|/bin/touchpad" | grep -v grep || true
        echo FILTER_MAPS
        for process in mico_aivs_lab touchpad; do
            for pid in $(pidof "$process" 2>/dev/null); do
                echo "$process pid=$pid"
                grep "libxiaoaimusic_.*_filter.so" "/proc/$pid/maps" 2>/dev/null || true
            done
        done
        echo LOCAL_CONTROL
        ls -l /tmp/xiaoaimusic-librespot-control.sock 2>/dev/null || true
        tail -n 12 /tmp/xiaoaimusic-librespot.log 2>/dev/null || true
        echo LEGACY_HOME_BRIDGE
        if ps w 2>/dev/null | grep -q "[x]iaoaimusic-home-bridge" || \
           netstat -lnt 2>/dev/null | grep -q ":18789[[:space:]]"; then
            echo legacy_home_bridge=UNEXPECTED_ACTIVE port=18789
        else
            echo legacy_home_bridge=inactive port=18789
        fi
        echo MOBILE_AUTH
        ls -l /data/xiaoaimusic/bin/xiaoaimusic-spotify-auth-updater \
            /data/xiaoaimusic/bin/xiaoaimusic-authorized-keys-verify \
            /data/xiaoaimusic/mount-mobile-auth.sh 2>/dev/null || true
        if [ -e /data/etc/dropbear/authorized_keys ]; then
            ls -l /data/etc/dropbear/authorized_keys 2>/dev/null || true
            echo pairing_metadata=present
        else
            echo pairing_metadata=absent
        fi
        mobile_auth_record=$(awk '\''$5 == "/etc/dropbear/authorized_keys" {
            count++; record=$3 "|" $4
        } END { if (count == 1) print record }'\'' /proc/self/mountinfo 2>/dev/null || true)
        mobile_auth_expected=$(awk -v path=/data/etc/dropbear/authorized_keys '\''
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
        '\'' /proc/self/mountinfo 2>/dev/null || true)
        if [ -n "$mobile_auth_record" ]; then
            if [ "$mobile_auth_record" = "$mobile_auth_expected" ] && \
                    cmp -s /data/etc/dropbear/authorized_keys /etc/dropbear/authorized_keys && \
                    /data/xiaoaimusic/bin/xiaoaimusic-authorized-keys-verify \
                        --require-mobile /etc/dropbear/authorized_keys >/dev/null 2>&1; then
                echo mobile_auth_bind=active
            else
                echo mobile_auth_bind=foreign
            fi
        else
            echo mobile_auth_bind=inactive
        fi
        echo KEYLOG
        cat /tmp/xiaoaimusic-keybridge-observe.log 2>/dev/null || true
        echo API
        if [ -e /data/xiaoaimusic/spotify-reauthorization-required ]; then
            echo "authorization_marker=AUTH_EXPIRED reauthorization_required=yes"
            ls -l /data/xiaoaimusic/spotify-reauthorization-required 2>/dev/null || true
        else
            echo "authorization_marker=clear reauthorization_required=no"
        fi
        /data/xiaoaimusic/spotify-web-api.sh health 2>&1 || true
        echo LIKED_SYNC
        [ ! -s /data/xiaoaimusic/liked-mirror-last-sync ] || {
            printf "last_sync_epoch="
            cat /data/xiaoaimusic/liked-mirror-last-sync
        }
        tail -n 10 /tmp/xiaoaimusic-liked-sync.log 2>/dev/null || true
        echo API_TIMING
        tail -n 20 /tmp/xiaoaimusic-spotify-api.log 2>/dev/null || true
        echo AIVS_FILTER
        tail -n 80 /tmp/xiaoaimusic-aivs-filter.log 2>/dev/null || true
        echo VOICE_BRIDGE
        tail -n 20 /tmp/xiaoaimusic-voice-bridge.log 2>/dev/null || true
    '
