#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE_SCRIPT="$REPO_ROOT/device/oh2p/mount-mobile-auth.sh"
VERIFIER_SOURCE="$REPO_ROOT/components/authorized-keys-verify/xiaoaimusic-authorized-keys-verify.c"
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT

DATA_ETC="$WORK/data/etc"
PERSIST="$DATA_ETC/dropbear/authorized_keys"
TARGET="$WORK/etc/dropbear/authorized_keys"
UPDATER="$WORK/data/xiaoaimusic/bin/xiaoaimusic-spotify-auth-updater"
VERIFIER="$WORK/data/xiaoaimusic/bin/xiaoaimusic-authorized-keys-verify"
TEST_SCRIPT="$WORK/mount-mobile-auth.sh"

mkdir -p "$(dirname "$PERSIST")" "$(dirname "$TARGET")" "$(dirname "$UPDATER")"
chmod 755 "$DATA_ETC"
chmod 700 "$(dirname "$PERSIST")" "$WORK/data/xiaoaimusic" \
    "$WORK/data/xiaoaimusic/bin"
: >"$TARGET"
printf '#!/bin/sh\nexit 0\n' >"$UPDATER"
chmod 700 "$UPDATER"
cc -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror "$VERIFIER_SOURCE" -o "$VERIFIER"
chmod 700 "$VERIFIER"

# Exercise the production script without touching real system paths.  Mounts
# live in a private namespace; the algorithm still consumes real mountinfo.
sed \
    -e "s|^SOURCE=.*|SOURCE=$PERSIST|" \
    -e "s|^TARGET=.*|TARGET=$TARGET|" \
    -e "s|^UPDATER=.*|UPDATER=$UPDATER|" \
    -e "s|^VERIFIER=.*|VERIFIER=$VERIFIER|" \
    -e "s|for trusted_path in /data/etc /data/etc/dropbear|for trusted_path in $DATA_ETC $(dirname "$PERSIST")|" \
    -e "s|\[ -d /data/etc \] && \[ -d /data/etc/dropbear \]|[ -d $DATA_ETC ] \&\& [ -d $(dirname "$PERSIST") ]|" \
    -e "s|ls -ldn /data/etc|ls -ldn $DATA_ETC|" \
    -e "s|trusted_directory /data/etc 0|trusted_directory $DATA_ETC 0|" \
    -e "s|chown root:root /data/etc/dropbear|chown root:root $(dirname "$PERSIST")|" \
    -e "s|chmod 700 /data/etc/dropbear|chmod 700 $(dirname "$PERSIST")|" \
    -e "s|for private_directory in /data/xiaoaimusic /data/xiaoaimusic/bin|for private_directory in $WORK/data/xiaoaimusic $WORK/data/xiaoaimusic/bin|" \
    -e "s|    /data/etc/dropbear; do|    $(dirname "$PERSIST"); do|" \
    "$SOURCE_SCRIPT" >"$TEST_SCRIPT"
chmod 700 "$TEST_SCRIPT"

ssh-keygen -q -t rsa -b 2048 -N '' -f "$WORK/admin" </dev/null
ssh-keygen -q -t rsa -b 3072 -N '' -f "$WORK/mobile-one" </dev/null
ssh-keygen -q -t rsa -b 3072 -N '' -f "$WORK/mobile-two" </dev/null
ADMIN_BLOB=$(awk '{print $2}' "$WORK/admin.pub")
MOBILE_ONE=$(awk '{print $2}' "$WORK/mobile-one.pub")
MOBILE_TWO=$(awk '{print $2}' "$WORK/mobile-two.pub")
OPTIONS='no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty,command="/data/xiaoaimusic/bin/xiaoaimusic-spotify-auth-updater"'
TAG=xiaoaimusic-mobile-auth-v1

export WORK PERSIST TARGET UPDATER VERIFIER TEST_SCRIPT DATA_ETC
export ADMIN_BLOB MOBILE_ONE MOBILE_TWO OPTIONS TAG

unshare -m bash <<'NAMESPACE'
set -euo pipefail
mount --make-rprivate / >/dev/null 2>&1 || true

write_valid() {
    blob=$1
    {
        printf 'ssh-rsa %s administrator\n' "$ADMIN_BLOB"
        printf '%s ssh-rsa %s %s\n' "$OPTIONS" "$blob" "$TAG"
    } >"$PERSIST"
    chmod 600 "$PERSIST"
}

write_valid "$MOBILE_ONE"
"$TEST_SCRIPT"
cmp -s "$PERSIST" "$TARGET"
[ "$(stat -c %a "$DATA_ETC")" = 755 ]

# Atomic source replacement leaves TARGET bound to the old inode.  Its
# mountinfo provenance and canonical old content permit a safe remount.
write_valid "$MOBILE_TWO"
mv "$PERSIST" "$PERSIST.new"
mv "$PERSIST.new" "$PERSIST"
"$TEST_SCRIPT"
cmp -s "$PERSIST" "$TARGET"
grep -q "$MOBILE_TWO" "$TARGET"

# A canonical-looking bind from another filesystem is foreign.  It must be
# rejected and remain mounted, proving the script never unmounts unknown state.
umount "$TARGET"
mkdir -p "$WORK/foreign-fs"
mount -t tmpfs tmpfs "$WORK/foreign-fs"
cp "$PERSIST" "$WORK/foreign-fs/authorized_keys"
mount -o bind "$WORK/foreign-fs/authorized_keys" "$TARGET"
if "$TEST_SCRIPT" >"$WORK/foreign.out" 2>"$WORK/foreign.err"; then
    echo 'Foreign mount was accepted.' >&2
    exit 1
fi
grep -q 'foreign authorized_keys mount' "$WORK/foreign.err"
mountpoint -q "$TARGET"
cmp -s "$WORK/foreign-fs/authorized_keys" "$TARGET"
umount "$TARGET"
umount "$WORK/foreign-fs"

# Scan every adjacent pair.  The first decoy ssh-rsa token must not hide the
# unrestricted duplicate of the mobile key later on the same line.
write_valid "$MOBILE_TWO"
printf 'command="echo ssh-rsa DECOY",no-pty ssh-rsa %s\n' "$MOBILE_TWO" >>"$PERSIST"
if "$TEST_SCRIPT" >"$WORK/duplicate.out" 2>"$WORK/duplicate.err"; then
    echo 'Hidden duplicate mobile blob was accepted.' >&2
    exit 1
fi

# A forced/optioned key is not a guaranteed rescue administrator key.
{
    printf 'command="/bin/false" ssh-rsa %s disabled-admin\n' "$ADMIN_BLOB"
    printf '%s ssh-rsa %s %s\n' "$OPTIONS" "$MOBILE_ONE" "$TAG"
} >"$PERSIST"
if "$TEST_SCRIPT" >"$WORK/forced-admin.out" 2>"$WORK/forced-admin.err"; then
    echo 'Forced key was incorrectly accepted as the rescue administrator.' >&2
    exit 1
fi

# A comment/tag collision must be rejected, never silently filtered.
{
    printf 'ssh-rsa %s administrator\n' "$ADMIN_BLOB"
    printf 'ssh-rsa %s %s\n' "$MOBILE_ONE" "$TAG"
} >"$PERSIST"
if "$TEST_SCRIPT" >"$WORK/tag-collision.out" 2>"$WORK/tag-collision.err"; then
    echo 'Malformed project-tag line was accepted.' >&2
    exit 1
fi
NAMESPACE

echo MOBILE_AUTH_MOUNT_TESTS_OK
