#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE_SCRIPT="$REPO_ROOT/device/oh2p/install-autostart.sh"
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT

ROOT="$WORK/data/xiaoaimusic"
INIT="$WORK/data/init.sh"
PERSIST="$WORK/data/etc/dropbear/authorized_keys"
TARGET="$WORK/etc/dropbear/authorized_keys"
TEST_SCRIPT="$WORK/install-autostart.sh"
FAKE_BIN="$WORK/fake-bin"

mkdir -p "$ROOT/bin" "$ROOT/backups" "$(dirname "$PERSIST")" \
    "$(dirname "$TARGET")" "$FAKE_BIN"
chmod 755 "$WORK/data"
chmod 700 "$ROOT" "$ROOT/bin" "$ROOT/backups"

printf 'admin-and-mobile\n' >"$PERSIST"
cp "$PERSIST" "$TARGET"
chmod 600 "$PERSIST" "$TARGET"

cat >"$ROOT/mount-mobile-auth.sh" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$ROOT/bin/xiaoaimusic-authorized-keys-verify" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$ROOT/bin/xiaoaimusic-spotify-auth-updater" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$ROOT/stop-home-bridge.sh" <<'EOF'
#!/bin/sh
[ "${STOP_SHOULD_FAIL:-0}" -eq 0 ]
EOF
cat >"$FAKE_BIN/netstat" <<'EOF'
#!/bin/sh
if [ "${NETSTAT_ACTIVE:-0}" -eq 1 ]; then
    printf 'tcp 0 0 0.0.0.0:18789 0.0.0.0:* LISTEN\n'
fi
EOF
chmod 700 "$ROOT/mount-mobile-auth.sh" "$ROOT/stop-home-bridge.sh" \
    "$ROOT/bin/xiaoaimusic-authorized-keys-verify" \
    "$ROOT/bin/xiaoaimusic-spotify-auth-updater"
chmod 755 "$FAKE_BIN/netstat"

sed \
    -e "s|^INIT=/data/init.sh$|INIT=$INIT|" \
    -e "s|^ROOT=/data/xiaoaimusic$|ROOT=$ROOT|" \
    -e "s|^PERSIST=/data/etc/dropbear/authorized_keys$|PERSIST=$PERSIST|" \
    -e "s|^TARGET=/etc/dropbear/authorized_keys$|TARGET=$TARGET|" \
    -e "s|trusted_directory /data 0|trusted_directory $WORK/data 0|" \
    -e "s|mktemp /data/|mktemp $WORK/data/|g" \
    "$SOURCE_SCRIPT" >"$TEST_SCRIPT"
chmod 700 "$TEST_SCRIPT"

write_legacy_files() {
    printf '#!/bin/sh\n' >"$ROOT/run-home-bridge.sh"
    printf 'legacy\n' >"$ROOT/bin/xiaoaimusic-home-bridge"
    printf 'secret\n' >"$ROOT/home-takeover-token"
    chmod 700 "$ROOT/run-home-bridge.sh" "$ROOT/bin/xiaoaimusic-home-bridge"
    chmod 600 "$ROOT/home-takeover-token"
}

assert_no_stages() {
    ! find "$WORK/data" "$ROOT/backups" -maxdepth 1 -type f \
        \( -name '.xiaoaimusic-init.*' -o -name '.init-autostart-rollback.*' \) \
        | grep -q .
}

cat >"$INIT" <<'EOF'
#!/bin/sh
before
# BEGIN XIAOAIMUSIC MOBILE AUTH
old-mobile-mount
# END XIAOAIMUSIC MOBILE AUTH
after
EOF
chmod 700 "$INIT"
write_legacy_files
PATH="$FAKE_BIN:$PATH" "$TEST_SCRIPT"
grep -q '^before$' "$INIT"
grep -q '^after$' "$INIT"
[ "$(grep -c '^# BEGIN XIAOAIMUSIC$' "$INIT")" -eq 1 ]
! grep -q 'XIAOAIMUSIC MOBILE AUTH' "$INIT"
[ ! -e "$ROOT/run-home-bridge.sh" ]
[ ! -e "$ROOT/bin/xiaoaimusic-home-bridge" ]
[ ! -e "$ROOT/home-takeover-token" ]
assert_no_stages

# A stop failure occurs after the new init was atomically installed.  The old
# init must be atomically restored and every legacy rollback aid retained.
cat >"$INIT" <<'EOF'
#!/bin/sh
rollback-sentinel
EOF
chmod 700 "$INIT"
cp "$INIT" "$WORK/expected-init"
write_legacy_files
if STOP_SHOULD_FAIL=1 PATH="$FAKE_BIN:$PATH" "$TEST_SCRIPT" \
        >"$WORK/stop-fail.out" 2>"$WORK/stop-fail.err"; then
    echo 'Autostart unexpectedly ignored a legacy bridge stop failure.' >&2
    exit 1
fi
cmp -s "$WORK/expected-init" "$INIT"
[ -e "$ROOT/run-home-bridge.sh" ]
[ -e "$ROOT/bin/xiaoaimusic-home-bridge" ]
[ -e "$ROOT/home-takeover-token" ]
assert_no_stages

# A residual listener is also a failed retirement and must roll init back.
if NETSTAT_ACTIVE=1 PATH="$FAKE_BIN:$PATH" "$TEST_SCRIPT" \
        >"$WORK/listener.out" 2>"$WORK/listener.err"; then
    echo 'Autostart unexpectedly accepted a live legacy listener.' >&2
    exit 1
fi
grep -q 'still active' "$WORK/listener.err"
cmp -s "$WORK/expected-init" "$INIT"
assert_no_stages

# Malformed/nested marker state is rejected without truncating subsequent boot
# logic or touching the legacy fallback.
cat >"$INIT" <<'EOF'
#!/bin/sh
# BEGIN XIAOAIMUSIC
inside
# BEGIN XIAOAIMUSIC MOBILE AUTH
nested
# END XIAOAIMUSIC MOBILE AUTH
# END XIAOAIMUSIC
must-survive
EOF
chmod 700 "$INIT"
cp "$INIT" "$WORK/malformed-expected"
if PATH="$FAKE_BIN:$PATH" "$TEST_SCRIPT" \
        >"$WORK/malformed.out" 2>"$WORK/malformed.err"; then
    echo 'Autostart unexpectedly accepted nested startup markers.' >&2
    exit 1
fi
grep -q 'malformed or nested' "$WORK/malformed.err"
cmp -s "$WORK/malformed-expected" "$INIT"
grep -q '^must-survive$' "$INIT"
assert_no_stages

echo INSTALL_AUTOSTART_TESTS_OK
