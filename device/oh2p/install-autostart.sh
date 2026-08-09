#!/bin/sh

set -eu

INIT=/data/init.sh
ROOT=/data/xiaoaimusic
BACKUP_DIR=$ROOT/backups
PERSIST=/data/etc/dropbear/authorized_keys
TARGET=/etc/dropbear/authorized_keys
BEGIN='# BEGIN XIAOAIMUSIC'
END='# END XIAOAIMUSIC'
MOBILE_BEGIN='# BEGIN XIAOAIMUSIC MOBILE AUTH'
MOBILE_END='# END XIAOAIMUSIC MOBILE AUTH'
PRE_XIAOAI_INIT=$INIT.pre-xiaoaimusic
TMP=
ROLLBACK=
PREINIT_TMP=
RESTORE_TMP=
HAD_INIT=0
COMMITTED=0
INIT_MUTATED=0

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

restore_init() {
    if [ "$HAD_INIT" -eq 1 ]; then
        RESTORE_TMP=$(mktemp /data/.xiaoaimusic-init.restore.XXXXXX) || return 1
        cp -p "$ROLLBACK" "$RESTORE_TMP" &&
            chown root:root "$RESTORE_TMP" &&
            mv "$RESTORE_TMP" "$INIT" || return 1
        RESTORE_TMP=
    else
        rm -f "$INIT"
    fi
}

cleanup() {
    status=$?
    trap - 0 1 2 15
    if [ "$COMMITTED" -ne 1 ] && [ "$INIT_MUTATED" -eq 1 ]; then
        restore_init || {
            echo 'Failed to restore /data/init.sh after autostart failure.' >&2
            status=1
        }
    fi
    [ -z "$TMP" ] || rm -f "$TMP"
    [ -z "$ROLLBACK" ] || rm -f "$ROLLBACK"
    [ -z "$PREINIT_TMP" ] || rm -f "$PREINIT_TMP"
    [ -z "$RESTORE_TMP" ] || rm -f "$RESTORE_TMP"
    exit "$status"
}

trusted_directory /data 0 || {
    echo '/data is not a trusted root-owned directory.' >&2
    exit 2
}
for private_directory in "$ROOT" "$ROOT/bin" "$BACKUP_DIR"; do
    trusted_directory "$private_directory" 1 || {
        echo "Untrusted private directory: $private_directory" >&2
        exit 2
    }
done
for required in "$ROOT/mount-mobile-auth.sh" \
    "$ROOT/bin/xiaoaimusic-spotify-auth-updater" \
    "$ROOT/bin/xiaoaimusic-authorized-keys-verify" \
    "$ROOT/stop-home-bridge.sh"; do
    trusted_executable "$required" || {
        echo "Missing or untrusted executable: $required" >&2
        exit 2
    }
done
for init_path in "$INIT" "$PRE_XIAOAI_INIT"; do
    [ ! -L "$init_path" ] || {
        echo "Refusing symlink init path: $init_path" >&2
        exit 2
    }
done
if [ -e "$INIT" ]; then
    [ -f "$INIT" ] || { echo '/data/init.sh is not a regular file.' >&2; exit 2; }
    LC_ALL=C ls -ldn "$INIT" 2>/dev/null | awk '
        NR == 1 && $1 ~ /^-/ && $3 == 0 &&
        substr($1, 6, 1) != "w" && substr($1, 9, 1) != "w" { trusted=1 }
        END { exit(trusted ? 0 : 1) }
    ' || { echo '/data/init.sh is not trusted.' >&2; exit 2; }
fi
if [ -e "$PRE_XIAOAI_INIT" ]; then
    [ -f "$PRE_XIAOAI_INIT" ] && [ ! -L "$PRE_XIAOAI_INIT" ] || {
        echo 'Existing pre-XiaoAI init backup is not a regular file.' >&2
        exit 2
    }
    LC_ALL=C ls -ldn "$PRE_XIAOAI_INIT" 2>/dev/null | awk '
        NR == 1 && $1 ~ /^-/ && $3 == 0 &&
        substr($1, 6, 1) != "w" && substr($1, 9, 1) != "w" { trusted=1 }
        END { exit(trusted ? 0 : 1) }
    ' || { echo 'Existing pre-XiaoAI init backup is not trusted.' >&2; exit 2; }
fi

# The main deployment flow invokes this only after a real phone-key takeover
# succeeds. Re-check the complete restricted-key mount before retiring the
# legacy LAN bridge; no persistent marker or bearer secret is introduced.
"$ROOT/mount-mobile-auth.sh"
"$ROOT/bin/xiaoaimusic-authorized-keys-verify" --require-mobile "$PERSIST"
cmp -s "$PERSIST" "$TARGET" || {
    echo 'Restricted phone authorized_keys is not active.' >&2
    exit 2
}

trap cleanup 0
trap 'exit 129' 1
trap 'exit 130' 2
trap 'exit 143' 15
TMP=$(mktemp /data/.xiaoaimusic-init.XXXXXX) || exit 1
ROLLBACK=$(mktemp "$BACKUP_DIR/.init-autostart-rollback.XXXXXX") || exit 1

if [ -f "$INIT" ]; then
    HAD_INIT=1
    cp -p "$INIT" "$ROLLBACK"
else
    printf '#!/bin/sh\n' >"$ROLLBACK"
fi
chown root:root "$ROLLBACK"

if [ ! -e "$PRE_XIAOAI_INIT" ]; then
    PREINIT_TMP=$(mktemp /data/.init.pre-xiaoaimusic.XXXXXX) || exit 1
    cp -p "$ROLLBACK" "$PREINIT_TMP"
    chown root:root "$PREINIT_TMP"
    if ln "$PREINIT_TMP" "$PRE_XIAOAI_INIT" 2>/dev/null; then
        rm -f "$PREINIT_TMP"
        PREINIT_TMP=
    elif [ ! -f "$PRE_XIAOAI_INIT" ] || [ -L "$PRE_XIAOAI_INIT" ]; then
        echo 'Could not safely create the pre-XiaoAI init backup.' >&2
        exit 1
    fi
fi

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
' "$ROLLBACK" >"$TMP" || {
    echo 'Refusing malformed or nested XiaoAI startup markers.' >&2
    exit 2
}
cat >>"$TMP" <<'EOF'
# BEGIN XIAOAIMUSIC
/data/xiaoaimusic/mount-mobile-auth.sh >>/tmp/xiaoaimusic-init.log 2>&1
/data/xiaoaimusic/activate-native-filters.sh >>/tmp/xiaoaimusic-init.log 2>&1
/data/xiaoaimusic/run-librespot.sh >>/tmp/xiaoaimusic-init.log 2>&1 &
/data/xiaoaimusic/run-voice-bridge.sh >>/tmp/xiaoaimusic-init.log 2>&1 &
/data/xiaoaimusic/run-keybridge.sh >>/tmp/xiaoaimusic-init.log 2>&1 &
/data/xiaoaimusic/supervise-liked-sync.sh >>/tmp/xiaoaimusic-liked-sync.log 2>&1 &
# END XIAOAIMUSIC
EOF
chown root:root "$TMP"
chmod 700 "$TMP"
INIT_MUTATED=1
mv "$TMP" "$INIT"
TMP=

# This is intentionally last: until the verified restricted SSH path and the
# new boot block are both in place, the currently working legacy bridge stays
# available as rollback insurance.
"$ROOT/stop-home-bridge.sh"
if netstat -lnt 2>/dev/null | grep -q ':18789[[:space:]]'; then
    echo 'Legacy home bridge listener is still active on port 18789.' >&2
    exit 1
fi

COMMITTED=1
rm -f "$ROOT/run-home-bridge.sh" "$ROOT/bin/xiaoaimusic-home-bridge" \
    "$ROOT/home-takeover-token"
echo AUTOSTART_INSTALLED_SSH_TAKEOVER_ONLY
