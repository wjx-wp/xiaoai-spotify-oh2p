#!/bin/sh

set -eu

ROOT=/data/xiaoaimusic
INIT=/data/init.sh
MOBILE_AUTH_SOURCE=/data/etc/dropbear/authorized_keys
MOBILE_AUTH_TARGET=/etc/dropbear/authorized_keys
MOBILE_AUTH_VERIFIER=$ROOT/bin/xiaoaimusic-authorized-keys-verify
BEGIN='# BEGIN XIAOAIMUSIC'
END='# END XIAOAIMUSIC'
MOBILE_BEGIN='# BEGIN XIAOAIMUSIC MOBILE AUTH'
MOBILE_END='# END XIAOAIMUSIC MOBILE AUTH'
TMP=
ROLLBACK=
RESTORE_TMP=
INIT_MUTATED=0
MOBILE_AUTH_WAS_MOUNTED=0
MOBILE_AUTH_UNMOUNTED=0
COMMITTED=0

trusted_directory() {
    expected_private=$2
    [ -d "$1" ] && [ ! -L "$1" ] || return 1
    LC_ALL=C ls -ldn "$1" 2>/dev/null | awk -v private="$expected_private" '
        NR == 1 && $1 ~ /^d/ && $3 == 0 &&
        substr($1, 6, 1) != "w" && substr($1, 9, 1) != "w" &&
        (!private || substr($1, 2, 9) == "rwx------") { trusted=1 }
        END { exit(trusted ? 0 : 1) }
    '
}

trusted_executable() {
    [ -f "$1" ] && [ ! -L "$1" ] || return 1
    LC_ALL=C ls -ldn "$1" 2>/dev/null | awk '
        NR == 1 && $1 ~ /^-/ && $3 == 0 && substr($1, 4, 1) == "x" &&
        substr($1, 6, 1) != "w" && substr($1, 9, 1) != "w" { trusted=1 }
        END { exit(trusted ? 0 : 1) }
    '
}

target_is_mounted() {
    [ -r /proc/self/mountinfo ] || return 1
    awk -v target="$MOBILE_AUTH_TARGET" \
        '$5 == target { found=1 } END { exit(found ? 0 : 1) }' /proc/self/mountinfo
}

is_mobile_auth_bind() {
    target_is_mounted || return 1
    [ -f "$MOBILE_AUTH_SOURCE" ] && [ ! -L "$MOBILE_AUTH_SOURCE" ] || return 1
    [ -f "$MOBILE_AUTH_TARGET" ] && [ ! -L "$MOBILE_AUTH_TARGET" ] || return 1
    actual_record=$(awk -v target="$MOBILE_AUTH_TARGET" '
        $5 == target { count++; record=$3 "|" $4 }
        END { if (count == 1) print record; else exit 1 }
    ' /proc/self/mountinfo) || return 1
    expected_record=$(awk -v path="$MOBILE_AUTH_SOURCE" '
        function contains(path, mountpoint) {
            return mountpoint == "/" || path == mountpoint || index(path, mountpoint "/") == 1
        }
        contains(path, $5) && length($5) > best {
            best=length($5); mountpoint=$5; root=$4; device=$3
        }
        END {
            if (!best) exit 1
            if (mountpoint == "/") relative=substr(path, 2)
            else if (path == mountpoint) relative=""
            else relative=substr(path, length(mountpoint) + 2)
            expected=(relative == "" ? root : (root == "/" ? "/" relative : root "/" relative))
            print device "|" expected
        }
    ' /proc/self/mountinfo) || return 1
    [ "$actual_record" = "$expected_record" ] &&
        cmp -s "$MOBILE_AUTH_SOURCE" "$MOBILE_AUTH_TARGET" &&
        trusted_executable "$MOBILE_AUTH_VERIFIER" &&
        "$MOBILE_AUTH_VERIFIER" --require-mobile "$MOBILE_AUTH_TARGET" >/dev/null 2>&1
}

restore_init() {
    [ "$INIT_MUTATED" -eq 1 ] || return 0
    RESTORE_TMP=$(mktemp /data/.xiaoaimusic-init.restore.XXXXXX) || return 1
    cp -p "$ROLLBACK" "$RESTORE_TMP" &&
        chown root:root "$RESTORE_TMP" &&
        mv "$RESTORE_TMP" "$INIT" || return 1
    RESTORE_TMP=
}

restore_mobile_mount() {
    [ "$MOBILE_AUTH_WAS_MOUNTED" -eq 1 ] &&
        [ "$MOBILE_AUTH_UNMOUNTED" -eq 1 ] || return 0
    target_is_mounted && return 1
    mount -o bind "$MOBILE_AUTH_SOURCE" "$MOBILE_AUTH_TARGET" &&
        is_mobile_auth_bind
}

cleanup() {
    status=$?
    trap - 0 1 2 15
    if [ "$COMMITTED" -ne 1 ]; then
        restore_init || {
            echo 'Failed to restore /data/init.sh after removal failure.' >&2
            status=1
        }
        restore_mobile_mount || {
            echo 'Failed to restore the restricted authorized_keys bind.' >&2
            status=1
        }
    fi
    [ -z "$TMP" ] || rm -f "$TMP"
    [ -z "$ROLLBACK" ] || rm -f "$ROLLBACK"
    [ -z "$RESTORE_TMP" ] || rm -f "$RESTORE_TMP"
    exit "$status"
}

trusted_directory /data 0 || {
    echo '/data is not a trusted root-owned directory.' >&2
    exit 2
}
[ -r /proc/self/mountinfo ] || {
    echo 'Cannot inspect authorized_keys mount provenance.' >&2
    exit 2
}
if target_is_mounted; then
    trusted_directory "$ROOT" 1 && trusted_directory "$ROOT/bin" 1 || {
        echo 'Restricted authorization directories are not trusted.' >&2
        exit 2
    }
    if ! is_mobile_auth_bind; then
        echo 'Detected a foreign authorized_keys mount; leaving it and all startup state untouched.' >&2
        exit 2
    fi
    MOBILE_AUTH_WAS_MOUNTED=1
fi

trap cleanup 0
trap 'exit 129' 1
trap 'exit 130' 2
trap 'exit 143' 15

if [ -e "$INIT" ]; then
    [ -f "$INIT" ] && [ ! -L "$INIT" ] || {
        echo 'Refusing a non-regular or symlink /data/init.sh.' >&2
        exit 2
    }
    LC_ALL=C ls -ldn "$INIT" 2>/dev/null | awk '
        NR == 1 && $1 ~ /^-/ && $3 == 0 &&
        substr($1, 6, 1) != "w" && substr($1, 9, 1) != "w" { trusted=1 }
        END { exit(trusted ? 0 : 1) }
    ' || { echo '/data/init.sh is not trusted.' >&2; exit 2; }
    TMP=$(mktemp /data/.xiaoaimusic-init-remove.XXXXXX) || exit 1
    ROLLBACK=$(mktemp /data/.xiaoaimusic-init-remove-rollback.XXXXXX) || exit 1
    cp -p "$INIT" "$ROLLBACK"
    chown root:root "$ROLLBACK"
    awk -v begin="$BEGIN" -v end="$END" \
        -v mobile_begin="$MOBILE_BEGIN" -v mobile_end="$MOBILE_END" '
        $0 == begin {
            begins++
            if (inside || begins > 1) bad=1
            inside=begin
            next
        }
        $0 == mobile_begin {
            mobile_begins++
            if (inside || mobile_begins > 1) bad=1
            inside=mobile_begin
            next
        }
        $0 == end {
            ends++
            if (inside != begin || ends > 1) bad=1
            inside=""
            next
        }
        $0 == mobile_end {
            mobile_ends++
            if (inside != mobile_begin || mobile_ends > 1) bad=1
            inside=""
            next
        }
        !inside { print }
        END {
            if (bad || inside || begins != ends || mobile_begins != mobile_ends ||
                begins > 1 || mobile_begins > 1) exit 42
        }
    ' "$INIT" >"$TMP" || {
        echo 'Refusing malformed or nested XiaoAI startup markers.' >&2
        exit 2
    }
    chown root:root "$TMP"
    chmod 700 "$TMP"
fi

if [ "$MOBILE_AUTH_WAS_MOUNTED" -eq 1 ]; then
    umount "$MOBILE_AUTH_TARGET" || {
        echo 'Could not unmount the restricted authorized_keys bind.' >&2
        exit 1
    }
    MOBILE_AUTH_UNMOUNTED=1
fi
if [ -n "$TMP" ]; then
    INIT_MUTATED=1
    mv "$TMP" "$INIT"
    TMP=
fi

COMMITTED=1
"$ROOT/stop-home-bridge.sh" >/dev/null 2>&1 || true
"$ROOT/stop-liked-sync.sh" >/dev/null 2>&1 || true
"$ROOT/stop-keybridge.sh" >/dev/null 2>&1 || true
"$ROOT/stop-voice-bridge.sh" >/dev/null 2>&1 || true
"$ROOT/stop-librespot.sh" >/dev/null 2>&1 || true
"$ROOT/deactivate-native-filters.sh" >/dev/null 2>&1 || true
echo AUTOSTART_REMOVED
