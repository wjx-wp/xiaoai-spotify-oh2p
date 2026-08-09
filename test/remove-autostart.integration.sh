#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE_SCRIPT="$REPO_ROOT/device/oh2p/remove-autostart.sh"
VERIFIER_SOURCE="$REPO_ROOT/components/authorized-keys-verify/xiaoaimusic-authorized-keys-verify.c"
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT

ROOT="$WORK/data/xiaoaimusic"
SOURCE="$WORK/data/etc/dropbear/authorized_keys"
TARGET="$WORK/etc/dropbear/authorized_keys"
INIT="$WORK/data/init.sh"
VERIFIER="$ROOT/bin/xiaoaimusic-authorized-keys-verify"
TEST_SCRIPT="$WORK/remove-autostart.sh"
STOP_LOG="$WORK/stop.log"

mkdir -p "$ROOT/bin" "$(dirname "$SOURCE")" "$(dirname "$TARGET")"
chmod 755 "$WORK/data"
chmod 700 "$ROOT" "$ROOT/bin"
cc -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror \
    "$VERIFIER_SOURCE" -o "$VERIFIER"
chmod 700 "$VERIFIER"

for helper in stop-home-bridge.sh stop-liked-sync.sh stop-keybridge.sh \
    stop-voice-bridge.sh stop-librespot.sh deactivate-native-filters.sh; do
    cat >"$ROOT/$helper" <<EOF
#!/bin/sh
printf '%s\\n' '$helper' >>'$STOP_LOG'
EOF
    chmod 700 "$ROOT/$helper"
done

sed \
    -e "s|^ROOT=/data/xiaoaimusic$|ROOT=$ROOT|" \
    -e "s|^INIT=/data/init.sh$|INIT=$INIT|" \
    -e "s|^MOBILE_AUTH_SOURCE=/data/etc/dropbear/authorized_keys$|MOBILE_AUTH_SOURCE=$SOURCE|" \
    -e "s|^MOBILE_AUTH_TARGET=/etc/dropbear/authorized_keys$|MOBILE_AUTH_TARGET=$TARGET|" \
    -e "s|trusted_directory /data 0|trusted_directory $WORK/data 0|" \
    -e "s|mktemp /data/|mktemp $WORK/data/|g" \
    "$SOURCE_SCRIPT" >"$TEST_SCRIPT"
chmod 700 "$TEST_SCRIPT"

ssh-keygen -q -t rsa -b 2048 -N '' -f "$WORK/admin" </dev/null
ssh-keygen -q -t rsa -b 3072 -N '' -f "$WORK/mobile" </dev/null
ADMIN=$(awk '{print $2}' "$WORK/admin.pub")
MOBILE=$(awk '{print $2}' "$WORK/mobile.pub")
OPTIONS='no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty,command="/data/xiaoaimusic/bin/xiaoaimusic-spotify-auth-updater"'
TAG=xiaoaimusic-mobile-auth-v1

{
    printf 'ssh-rsa %s administrator\n' "$ADMIN"
    printf '%s ssh-rsa %s %s\n' "$OPTIONS" "$MOBILE" "$TAG"
} >"$SOURCE"
printf 'rom-administrator\n' >"$TARGET"
chmod 600 "$SOURCE" "$TARGET"

export WORK ROOT SOURCE TARGET INIT VERIFIER TEST_SCRIPT STOP_LOG

unshare -m bash <<'NAMESPACE'
set -euo pipefail
mount --make-rprivate / >/dev/null 2>&1 || true

write_init() {
    cat >"$INIT" <<'EOF'
#!/bin/sh
before
# BEGIN XIAOAIMUSIC MOBILE AUTH
old-mobile-mount
# END XIAOAIMUSIC MOBILE AUTH
# BEGIN XIAOAIMUSIC
old-services
# END XIAOAIMUSIC
after
EOF
    chmod 700 "$INIT"
}

# A malformed init is rejected before the proven project bind is detached.
cat >"$INIT" <<'EOF'
#!/bin/sh
# BEGIN XIAOAIMUSIC
unterminated
must-survive
EOF
chmod 700 "$INIT"
cp "$INIT" "$WORK/malformed-expected"
mount -o bind "$SOURCE" "$TARGET"
if "$TEST_SCRIPT" >"$WORK/malformed.out" 2>"$WORK/malformed.err"; then
    echo 'Removal unexpectedly accepted an unterminated init block.' >&2
    exit 1
fi
grep -q 'malformed or nested' "$WORK/malformed.err"
cmp -s "$WORK/malformed-expected" "$INIT"
mountpoint -q "$TARGET"
cmp -s "$SOURCE" "$TARGET"
umount "$TARGET"

# A different filesystem remains foreign even when its bytes are canonical.
# Foreign preflight happens before init mutation or service shutdown.
write_init
cp "$INIT" "$WORK/foreign-init-expected"
rm -f "$STOP_LOG"
mkdir -p "$WORK/foreign-fs"
mount -t tmpfs tmpfs "$WORK/foreign-fs"
cp "$SOURCE" "$WORK/foreign-fs/authorized_keys"
chmod 600 "$WORK/foreign-fs/authorized_keys"
mount -o bind "$WORK/foreign-fs/authorized_keys" "$TARGET"
if "$TEST_SCRIPT" >"$WORK/foreign.out" 2>"$WORK/foreign.err"; then
    echo 'Removal unexpectedly accepted a foreign authorized_keys mount.' >&2
    exit 1
fi
grep -q 'leaving it and all startup state untouched' "$WORK/foreign.err"
mountpoint -q "$TARGET"
cmp -s "$WORK/foreign-init-expected" "$INIT"
[ ! -e "$STOP_LOG" ]
umount "$TARGET"
umount "$WORK/foreign-fs"

# A canonical project bind is removed, the ROM target becomes visible, and
# only the two exact startup blocks disappear; surrounding boot logic survives.
write_init
mount -o bind "$SOURCE" "$TARGET"
"$TEST_SCRIPT"
! mountpoint -q "$TARGET"
grep -q '^rom-administrator$' "$TARGET"
grep -q '^before$' "$INIT"
grep -q '^after$' "$INIT"
! grep -q 'BEGIN XIAOAIMUSIC' "$INIT"
grep -q '^stop-home-bridge.sh$' "$STOP_LOG"
[ -f "$SOURCE" ]
! find "$WORK/data" -maxdepth 1 -type f -name '.xiaoaimusic-init-*' | grep -q .
NAMESPACE

echo REMOVE_AUTOSTART_TESTS_OK
