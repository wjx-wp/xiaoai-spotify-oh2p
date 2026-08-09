#!/usr/bin/env bash

set -euo pipefail

DEVICE_IP=${1:-}
PHONE_PUBLIC_KEY=${2:-}
if [[ ! "$DEVICE_IP" =~ ^[A-Za-z0-9.-]+$ ]] || [ ! -f "$PHONE_PUBLIC_KEY" ]; then
    echo 'Usage: host/deploy-spotify-auth-updater.sh SPEAKER_IP PHONE_RSA_PUBLIC_KEY' >&2
    exit 2
fi

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PASSWORD_FILE="$REPO_ROOT/.secrets/oh2p-root-password.txt"
KNOWN_HOSTS="$REPO_ROOT/.secrets/known_hosts_oh2p"
ARTIFACT="$REPO_ROOT/artifacts/build/oh2p/bin/xiaoaimusic-spotify-auth-updater"
VERIFIER_ARTIFACT="$REPO_ROOT/artifacts/build/oh2p/bin/xiaoaimusic-authorized-keys-verify"
MOUNT_SCRIPT="$REPO_ROOT/device/oh2p/mount-mobile-auth.sh"
SPOTIFY_API="$REPO_ROOT/device/oh2p/spotify-web-api.sh"
REMOTE_STAGE="/tmp/xiaoaimusic-mobile-auth-stage-$$-$RANDOM"
STAGING=$(mktemp -d)

SSH_OPTIONS=(
    -o HostKeyAlgorithms=+ssh-rsa
    -o PubkeyAcceptedAlgorithms=+ssh-rsa
    -o StrictHostKeyChecking=yes
    -o "UserKnownHostsFile=$KNOWN_HOSTS"
)

cleanup() {
    rm -rf -- "$STAGING"
}
trap cleanup EXIT HUP INT TERM

for command_name in ssh sshpass scp ssh-keygen awk grep mktemp; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "Missing required command: $command_name" >&2
        exit 2
    }
done
for required_file in "$PASSWORD_FILE" "$KNOWN_HOSTS" "$MOUNT_SCRIPT" "$SPOTIFY_API"; do
    [ -s "$required_file" ] || { echo "Missing required file: $required_file" >&2; exit 2; }
done

PUBLIC_KEY_NORMALIZED="$STAGING/phone.pub"
LC_ALL=C awk '
    /^[[:space:]]*$/ { next }
    {
        lines++
        if (NF != 2 || $1 != "ssh-rsa" || $2 !~ /^[A-Za-z0-9+\/=]+$/) exit 2
        print $1 " " $2
    }
    END { if (lines != 1) exit 2 }
' "$PHONE_PUBLIC_KEY" >"$PUBLIC_KEY_NORMALIZED" || {
    echo 'Phone public key must be exactly one bare ssh-rsa key with no options or comment.' >&2
    exit 2
}

KEY_INFO=$(ssh-keygen -lf "$PUBLIC_KEY_NORMALIZED" -E sha256 2>/dev/null) || {
    echo 'Phone public key could not be parsed by ssh-keygen.' >&2
    exit 2
}
KEY_BITS=$(printf '%s\n' "$KEY_INFO" | awk 'NR == 1 { print $1 }')
KEY_FINGERPRINT=$(printf '%s\n' "$KEY_INFO" | awk 'NR == 1 { print $2 }')
[ "$KEY_BITS" = 3072 ] || {
    echo "Phone key must be RSA 3072; received ${KEY_BITS:-unknown} bits." >&2
    exit 2
}
[[ "$KEY_FINGERPRINT" =~ ^SHA256:[A-Za-z0-9+/]+$ ]] || {
    echo 'Phone key fingerprint is malformed.' >&2
    exit 2
}

"$REPO_ROOT/host/build-spotify-auth-updater.sh" >/dev/null
"$REPO_ROOT/host/build-authorized-keys-verify.sh" >/dev/null
[ -x "$ARTIFACT" ] && [ -x "$VERIFIER_ARTIFACT" ] || {
    echo 'Restricted auth build artifacts are missing.' >&2
    exit 2
}
mkdir -p "$STAGING/bin"
cp "$ARTIFACT" "$STAGING/bin/"
cp "$VERIFIER_ARTIFACT" "$STAGING/bin/"
cp "$MOUNT_SCRIPT" "$STAGING/"
cp "$SPOTIFY_API" "$STAGING/"

sshpass -f "$PASSWORD_FILE" ssh "${SSH_OPTIONS[@]}" "root@$DEVICE_IP" \
    "umask 077 && mkdir '$REMOTE_STAGE' && mkdir '$REMOTE_STAGE/bin'"
sshpass -f "$PASSWORD_FILE" scp -q -O -r "${SSH_OPTIONS[@]}" \
    "$STAGING/bin" "$STAGING/mount-mobile-auth.sh" \
    "$STAGING/spotify-web-api.sh" "$PUBLIC_KEY_NORMALIZED" \
    "root@$DEVICE_IP:$REMOTE_STAGE/"

REMOTE_OUTPUT=$(sshpass -f "$PASSWORD_FILE" ssh "${SSH_OPTIONS[@]}" \
    "root@$DEVICE_IP" "sh -s -- '$REMOTE_STAGE'" <<'REMOTE_INSTALL'
set -eu
set -f

STAGE=$1
ROOT=/data/xiaoaimusic
BIN=$ROOT/bin/xiaoaimusic-spotify-auth-updater
VERIFIER=$ROOT/bin/xiaoaimusic-authorized-keys-verify
MOUNT_SCRIPT=$ROOT/mount-mobile-auth.sh
SPOTIFY_API=$ROOT/spotify-web-api.sh
PERSIST=/data/etc/dropbear/authorized_keys
TARGET=/etc/dropbear/authorized_keys
INIT=/data/init.sh
TAG=xiaoaimusic-mobile-auth-v1
OPTIONS='no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty,command="/data/xiaoaimusic/bin/xiaoaimusic-spotify-auth-updater"'
BEGIN='# BEGIN XIAOAIMUSIC MOBILE AUTH'
END='# END XIAOAIMUSIC MOBILE AUTH'
MUTATED=0
COMMITTED=0
WAS_OWN_BOUND=0
NEW_BIND_CREATED=0
AUTH_TMP=
INIT_TMP=
INIT_BODY=
DEPLOY_TEMP=

case "$STAGE" in
    /tmp/xiaoaimusic-mobile-auth-stage-[0-9]*-[0-9]*) ;;
    *) echo 'Refusing unsafe staging path.' >&2; exit 2 ;;
esac
[ -f "$STAGE/bin/xiaoaimusic-spotify-auth-updater" ] || {
    echo 'Staged updater binary is missing.' >&2
    exit 2
}
[ -f "$STAGE/bin/xiaoaimusic-authorized-keys-verify" ] || {
    echo 'Staged authorized-keys verifier is missing.' >&2
    exit 2
}
[ -f "$STAGE/mount-mobile-auth.sh" ] || {
    echo 'Staged mount script is missing.' >&2
    exit 2
}
[ -f "$STAGE/spotify-web-api.sh" ] || {
    echo 'Staged Spotify Web API script is missing.' >&2
    exit 2
}
[ -f "$STAGE/phone.pub" ] || { echo 'Staged phone public key is missing.' >&2; exit 2; }
grep -q '\.spotify-auth-update\.lock' "$STAGE/spotify-web-api.sh" &&
    grep -q 'flock -x' "$STAGE/spotify-web-api.sh" || {
    echo 'Staged spotify-web-api.sh does not use the shared authorization lock.' >&2
    exit 2
}
for target in "$ROOT" "$ROOT/bin" "$ROOT/backups" "$BIN" "$VERIFIER" "$MOUNT_SCRIPT" "$SPOTIFY_API" \
    /data/etc /data/etc/dropbear "$PERSIST" "$TARGET" "$INIT"; do
    [ ! -L "$target" ] || { echo "Refusing symlink target: $target" >&2; exit 2; }
done

set -- $(cat "$STAGE/phone.pub")
[ "$#" -eq 2 ] && [ "$1" = ssh-rsa ] || {
    echo 'Staged phone public key format changed.' >&2
    exit 2
}
KEY_BLOB=$2
case "$KEY_BLOB" in
    ''|*[!A-Za-z0-9+/=]*) echo 'Staged phone key contains invalid characters.' >&2; exit 2 ;;
esac
STAGED_VERIFIER=$STAGE/bin/xiaoaimusic-authorized-keys-verify
[ -x "$STAGED_VERIFIER" ] && [ ! -L "$STAGED_VERIFIER" ] || {
    echo 'Staged authorized-keys verifier is not a trusted executable.' >&2
    exit 2
}
chown root:root "$STAGED_VERIFIER"
chmod 700 "$STAGED_VERIFIER"
ACTIVE_VERIFIER=$STAGED_VERIFIER
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

target_mount_record() {
    [ -r /proc/self/mountinfo ] || return 1
    awk -v target="$TARGET" '
        $5 == target { count++; device=$3; root=$4 }
        END { if (count == 1) print device "|" root; else exit 1 }
    ' /proc/self/mountinfo
}

source_filesystem_record() {
    [ -r /proc/self/mountinfo ] || return 1
    awk -v path="$PERSIST" '
        function contains(path, mountpoint) {
            return mountpoint == "/" || path == mountpoint ||
                   index(path, mountpoint "/") == 1
        }
        contains(path, $5) && length($5) > best_length {
            best_length=length($5)
            best_mount=$5
            best_root=$4
            best_device=$3
        }
        END {
            if (!best_length) exit 1
            if (best_mount == "/") relative=substr(path, 2)
            else if (path == best_mount) relative=""
            else relative=substr(path, length(best_mount) + 2)
            if (relative == "") expected=best_root
            else if (best_root == "/") expected="/" relative
            else expected=best_root "/" relative
            print best_device "|" expected
        }
    ' /proc/self/mountinfo
}

target_is_mounted() {
    [ -r /proc/self/mountinfo ] || return 1
    awk -v target="$TARGET" '$5 == target { found=1 } END { exit(found ? 0 : 1) }' \
        /proc/self/mountinfo
}

target_mount_is_project_source() {
    actual_record=$(target_mount_record) || return 1
    expected_record=$(source_filesystem_record) || return 1
    [ "$actual_record" = "$expected_record" ]
}

analyze_authorized_keys() {
    auth_file=$1
    mode=$2
    case "$mode" in
        required) "$ACTIVE_VERIFIER" --require-mobile "$auth_file" ;;
        optional) "$ACTIVE_VERIFIER" --allow-no-mobile "$auth_file" ;;
        *) return 2 ;;
    esac
}

validate_init_markers() {
    [ ! -e "$INIT" ] && return 0
    awk -v begin="$BEGIN" -v end="$END" '
        $0 == begin {
            begins++
            if (inside || begins > 1) bad=1
            inside=1
            next
        }
        $0 == end {
            ends++
            if (!inside || ends > 1) bad=1
            inside=0
            next
        }
        END {
            if (bad || inside || begins != ends || begins > 1) exit 1
        }
    ' "$INIT"
}

restore_file() {
    marker=$1
    saved=$2
    target=$3
    if [ -f "$BACKUP/$marker" ]; then
        cp -p "$BACKUP/$saved" "$target"
    else
        rm -f "$target"
    fi
}

install_staged_file() {
    staged_source=$1
    staged_target=$2
    staged_mode=$3
    staged_directory=${staged_target%/*}
    staged_name=${staged_target##*/}
    [ ! -L "$staged_target" ] && [ ! -d "$staged_target" ] || return 1
    DEPLOY_TEMP=$(mktemp "$staged_directory/.${staged_name}.deploy.XXXXXX") || return 1
    cp "$staged_source" "$DEPLOY_TEMP" &&
        chown root:root "$DEPLOY_TEMP" &&
        chmod "$staged_mode" "$DEPLOY_TEMP" &&
        mv "$DEPLOY_TEMP" "$staged_target" || return 1
    DEPLOY_TEMP=
}

rollback() {
    if target_is_mounted; then
        if [ "$NEW_BIND_CREATED" -eq 1 ] &&
           target_mount_is_project_source; then
            # The current transaction created this top-level bind.  Its
            # content verifier may be the exact postcondition that failed, so
            # provenance (not content) is the safe ownership proof here.
            umount "$TARGET" || true
        elif [ "$NEW_BIND_CREATED" -eq 0 ] &&
             target_mount_is_project_source &&
             analyze_authorized_keys "$TARGET" required >/dev/null 2>&1; then
            umount "$TARGET" || true
        else
            echo 'Rollback left an unexpected authorized_keys mount untouched.' >&2
        fi
    fi
    mkdir -p "$ROOT/bin" /data/etc/dropbear
    restore_file binary.present updater "$BIN"
    restore_file verifier.present authorized-keys-verifier "$VERIFIER"
    restore_file mount.present mount-mobile-auth.sh "$MOUNT_SCRIPT"
    restore_file spotify-api.present spotify-web-api.sh "$SPOTIFY_API"
    restore_file persist.present authorized_keys "$PERSIST"
    restore_file init.present init.sh "$INIT"
    if [ "$WAS_OWN_BOUND" -eq 1 ] && [ -f "$PERSIST" ] &&
       ! target_is_mounted; then
        mount -o bind "$PERSIST" "$TARGET" || true
    fi
}

on_exit() {
    status=$?
    trap - 0 1 2 15
    if [ "$COMMITTED" -ne 1 ] && [ "$MUTATED" -eq 1 ]; then
        echo 'Mobile auth deployment failed; restoring the previous state.' >&2
        rollback
    fi
    [ -z "$AUTH_TMP" ] || rm -f "$AUTH_TMP"
    [ -z "$INIT_TMP" ] || rm -f "$INIT_TMP"
    [ -z "$INIT_BODY" ] || rm -f "$INIT_BODY"
    [ -z "$DEPLOY_TEMP" ] || rm -f "$DEPLOY_TEMP"
    rm -rf "$STAGE"
    exit "$status"
}
trap on_exit 0
trap 'exit 129' 1
trap 'exit 130' 2
trap 'exit 143' 15

# Classify the active target before creating backups or changing /data.  A
# mounted target is either a canonical older bind from PERSIST or foreign; the
# latter is a hard stop and can never enter rollback.
[ -f "$TARGET" ] && [ ! -L "$TARGET" ] || {
    echo 'Dropbear authorized_keys target is missing or invalid.' >&2
    exit 2
}
AUTH_BASE=$TARGET
if target_is_mounted; then
    if ! target_mount_is_project_source ||
       ! analyze_authorized_keys "$TARGET" required >/dev/null; then
        echo 'Refusing deployment over a foreign authorized_keys mount.' >&2
        exit 2
    fi
    WAS_OWN_BOUND=1
else
    analyze_authorized_keys "$TARGET" optional >/dev/null || {
        echo 'Existing active authorized_keys is unsafe or has a malformed project tag.' >&2
        exit 2
    }
fi

umask 077
mkdir -p "$ROOT/bin" "$ROOT/backups" /data/etc/dropbear
ls -ldn /data/etc 2>/dev/null | awk '
    NR == 1 && $1 ~ /^d/ && $3 == 0 &&
    substr($1, 6, 1) != "w" && substr($1, 9, 1) != "w" { trusted=1 }
    END { exit(trusted ? 0 : 1) }
' || { echo '/data/etc is not a trusted root-owned directory.' >&2; exit 2; }
chown root:root "$ROOT" "$ROOT/bin" "$ROOT/backups" /data/etc/dropbear
chmod 700 "$ROOT" "$ROOT/bin" "$ROOT/backups" /data/etc/dropbear
for private_directory in "$ROOT" "$ROOT/bin" "$ROOT/backups" /data/etc/dropbear; do
    ls -ldn "$private_directory" 2>/dev/null | awk '
        NR == 1 && $1 ~ /^d/ && $3 == 0 &&
        substr($1, 2, 9) == "rwx------" { trusted=1 }
        END { exit(trusted ? 0 : 1) }
    ' || { echo "Private directory is not root-owned mode 0700: $private_directory" >&2; exit 2; }
done

if [ "$WAS_OWN_BOUND" -eq 1 ]; then
    [ -f "$PERSIST" ] && [ ! -L "$PERSIST" ] &&
        analyze_authorized_keys "$PERSIST" required >/dev/null || {
            echo 'Active project bind has no matching safe persistent authorized_keys.' >&2
            exit 2
        }
    cmp -s "$PERSIST" "$TARGET" || {
        echo 'Persistent authorized_keys and its active project bind use different inodes/content; reconcile before redeploying.' >&2
        exit 2
    }
    AUTH_BASE=$PERSIST
elif [ -e "$PERSIST" ]; then
    [ -f "$PERSIST" ] && [ ! -L "$PERSIST" ] &&
        analyze_authorized_keys "$PERSIST" optional >/dev/null || {
            echo 'Persistent authorized_keys is unsafe or has a malformed project tag.' >&2
            exit 2
        }
    cmp -s "$PERSIST" "$TARGET" || {
        echo 'Inactive persistent authorized_keys differs from the active target; reconcile before deploying.' >&2
        exit 2
    }
fi
"$ACTIVE_VERIFIER" --allow-no-mobile "$AUTH_BASE" \
    --reject-unrestricted "$KEY_BLOB" >/dev/null || {
    echo 'Refusing mobile key: it conflicts with an unrestricted or malformed authorized_keys entry.' >&2
    exit 2
}
validate_init_markers || {
    echo 'Refusing to rewrite /data/init.sh with malformed mobile-auth markers.' >&2
    exit 2
}

stamp=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo unknown)
backup_base="$ROOT/backups/mobile-auth-$stamp-$$"
BACKUP=$backup_base
suffix=0
while ! mkdir "$BACKUP" 2>/dev/null; do
    suffix=$((suffix + 1))
    [ "$suffix" -le 100 ] || { echo 'Cannot create a unique backup directory.' >&2; exit 1; }
    BACKUP="$backup_base-$suffix"
done
chown root:root "$BACKUP"
chmod 700 "$BACKUP"
ls -ldn "$BACKUP" 2>/dev/null | awk '
    NR == 1 && $1 ~ /^d/ && $3 == 0 && substr($1, 2, 9) == "rwx------" { trusted=1 }
    END { exit(trusted ? 0 : 1) }
' || { echo 'Backup directory is not trusted.' >&2; exit 2; }

if [ -e "$BIN" ]; then cp -p "$BIN" "$BACKUP/updater"; : >"$BACKUP/binary.present"; fi
if [ -e "$VERIFIER" ]; then cp -p "$VERIFIER" "$BACKUP/authorized-keys-verifier"; : >"$BACKUP/verifier.present"; fi
if [ -e "$MOUNT_SCRIPT" ]; then cp -p "$MOUNT_SCRIPT" "$BACKUP/mount-mobile-auth.sh"; : >"$BACKUP/mount.present"; fi
if [ -e "$SPOTIFY_API" ]; then cp -p "$SPOTIFY_API" "$BACKUP/spotify-web-api.sh"; : >"$BACKUP/spotify-api.present"; fi
if [ -e "$PERSIST" ]; then cp -p "$PERSIST" "$BACKUP/authorized_keys"; : >"$BACKUP/persist.present"; fi
if [ -e "$INIT" ]; then cp -p "$INIT" "$BACKUP/init.sh"; : >"$BACKUP/init.present"; fi
if [ "$WAS_OWN_BOUND" -eq 1 ]; then
    cp -p "$TARGET" "$BACKUP/mounted-authorized_keys"
    : >"$BACKUP/was-own-bound"
fi

MUTATED=1
install_staged_file "$STAGE/bin/xiaoaimusic-spotify-auth-updater" "$BIN" 700
install_staged_file "$STAGE/bin/xiaoaimusic-authorized-keys-verify" "$VERIFIER" 700
install_staged_file "$STAGE/mount-mobile-auth.sh" "$MOUNT_SCRIPT" 700
install_staged_file "$STAGE/spotify-web-api.sh" "$SPOTIFY_API" 700
ACTIVE_VERIFIER=$VERIFIER

AUTH_TMP=$(mktemp "$PERSIST.tmp.XXXXXX") || {
    echo 'Could not create a secure authorized_keys staging file.' >&2
    exit 1
}
INIT_TMP=$(mktemp "$INIT.tmp.XXXXXX") || {
    echo 'Could not create a secure init staging file.' >&2
    exit 1
}
INIT_BODY=$(mktemp "$INIT.tmp.body.XXXXXX") || {
    echo 'Could not create a secure init body staging file.' >&2
    exit 1
}
trap 'rm -f "$AUTH_TMP" "$INIT_TMP" "$INIT_BODY"; exit 129' 1
trap 'rm -f "$AUTH_TMP" "$INIT_TMP" "$INIT_BODY"; exit 130' 2
trap 'rm -f "$AUTH_TMP" "$INIT_TMP" "$INIT_BODY"; exit 143' 15

awk -v options="$OPTIONS" -v tag="$TAG" '
    function valid_blob(value) {
        return value != "" && value ~ /^[A-Za-z0-9+\/=]+$/
    }
    $NF == tag {
        if (NF != 4 || $1 != options || $2 != "ssh-rsa" ||
            !valid_blob($3) || $4 != tag) exit 42
        next
    }
    { print }
' "$AUTH_BASE" >"$AUTH_TMP" || {
    echo 'Refusing to remove an unrecognized line that collides with the mobile-auth tag.' >&2
    exit 1
}
printf '%s ssh-rsa %s %s\n' "$OPTIONS" "$KEY_BLOB" "$TAG" >>"$AUTH_TMP"
"$ACTIVE_VERIFIER" --require-mobile "$AUTH_TMP" \
    --expected-mobile "$KEY_BLOB" >/dev/null || {
    echo 'Constructed authorized_keys failed administrator, tag, or key-uniqueness validation.' >&2
    exit 1
}
chown root:root "$AUTH_TMP"
chmod 600 "$AUTH_TMP"

# An atomic source replacement changes its inode while an older bind continues
# to reference the previous inode.  Only the preflight-proven project mount may
# be detached here; mount-mobile-auth.sh will bind the new inode below.
if [ "$WAS_OWN_BOUND" -eq 1 ]; then
    target_mount_is_project_source &&
        analyze_authorized_keys "$TARGET" required >/dev/null || {
            echo 'Previously verified authorized_keys mount changed during deployment.' >&2
            exit 1
        }
    umount "$TARGET"
fi
mv "$AUTH_TMP" "$PERSIST"

if [ -f "$INIT" ]; then
    if ! awk -v begin="$BEGIN" -v end="$END" '
        $0 == begin {
            begins++
            if (inside || begins > 1) bad=1
            inside=1
            next
        }
        $0 == end {
            ends++
            if (!inside || ends > 1) bad=1
            inside=0
            next
        }
        !inside { print }
        END {
            if (bad || inside || begins != ends || begins > 1) exit 42
        }
    ' "$INIT" >"$INIT_BODY"; then
        echo 'Mobile-auth init markers changed or became malformed during deployment.' >&2
        exit 1
    fi
else
    printf '#!/bin/sh\n' >"$INIT_BODY"
fi
{
    printf '#!/bin/sh\n\n'
    printf '%s\n' "$BEGIN"
    printf '%s\n' '/data/xiaoaimusic/mount-mobile-auth.sh >>/tmp/xiaoaimusic-init.log 2>&1'
    printf '%s\n' "$END"
    awk 'NR == 1 && /^#!/ { next } { print }' "$INIT_BODY"
} >"$INIT_TMP"
rm -f "$INIT_BODY"
INIT_BODY=
chown root:root "$INIT_TMP"
chmod 700 "$INIT_TMP"
mv "$INIT_TMP" "$INIT"

"$MOUNT_SCRIPT"
NEW_BIND_CREATED=1
target_mount_is_project_source || { echo 'Restricted authorized_keys is not mounted from the project source.' >&2; exit 1; }
cmp -s "$PERSIST" "$TARGET" || { echo 'Mounted authorized_keys differs from persistent source.' >&2; exit 1; }
analyze_authorized_keys "$TARGET" required >/dev/null || {
    echo 'Restricted key is not uniquely active across authorized_keys.' >&2
    exit 1
}

COMMITTED=1
echo 'SPOTIFY_AUTH_UPDATER_ACTIVE commands=spotify-auth-update,spotify-auth-status,takeover protocol=XIAOAIMUSIC_AUTH_V1'
echo "SPOTIFY_AUTH_UPDATER_BACKUP=$BACKUP"
REMOTE_INSTALL
)

printf '%s\n' "$REMOTE_OUTPUT"
BACKUP_PATH=$(printf '%s\n' "$REMOTE_OUTPUT" |
    sed -n 's/^SPOTIFY_AUTH_UPDATER_BACKUP=//p' | tail -n 1)
[[ "$BACKUP_PATH" =~ ^/data/xiaoaimusic/backups/mobile-auth-[0-9A-Za-z._-]+$ ]] || {
    echo 'Deployment did not return a valid rollback path.' >&2
    exit 1
}

# Confirm the root-password rescue login and tagged bind are still available.
# The phone key's forced-command gate is tested later by the installed app.
sshpass -f "$PASSWORD_FILE" ssh "${SSH_OPTIONS[@]}" "root@$DEVICE_IP" \
    'test -x /data/xiaoaimusic/bin/xiaoaimusic-spotify-auth-updater && grep -q xiaoaimusic-mobile-auth-v1 /etc/dropbear/authorized_keys'

echo "Phone key installed with forced command only; fingerprint=$KEY_FINGERPRINT"
echo "Rollback snapshot: $BACKUP_PATH"
