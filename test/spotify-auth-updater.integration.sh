#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE="$REPO_ROOT/components/spotify-auth-updater/xiaoaimusic-spotify-auth-updater.c"
WORK=$(mktemp -d)
AUTH_ROOT="$WORK/root"
UPDATER="$WORK/xiaoaimusic-spotify-auth-updater"
ACCESS_TOKEN="$WORK/access-token"
ACCESS_EXPIRY="$WORK/access-expiry"
CONTROL_SOCKET="$WORK/librespot-control.sock"
trap 'rm -rf -- "$WORK"' EXIT

mkdir -m 700 "$AUTH_ROOT"
cc -O2 -Wall -Wextra -Wpedantic -Werror \
    -DXIAOAIMUSIC_ALLOW_NON_ROOT=1 \
    -DXIAOAIMUSIC_AUTH_ROOT="\"$AUTH_ROOT\"" \
    -DXIAOAIMUSIC_ACCESS_TOKEN_PATH="\"$ACCESS_TOKEN\"" \
    -DXIAOAIMUSIC_ACCESS_EXPIRY_PATH="\"$ACCESS_EXPIRY\"" \
    -DXIAOAIMUSIC_CONTROL_SOCKET_PATH="\"$CONTROL_SOCKET\"" \
    -DXIAOAIMUSIC_TEST_COMMIT_DELAY_MS=1000 \
    -DXIAOAIMUSIC_TEST_FAULT_INJECTION=1 \
    "$SOURCE" -o "$UPDATER"

if grep -Eq 'execve|auth-validate|spotify-web-api|fork[[:space:]]*\(' "$SOURCE"; then
    echo 'Updater must not execute a Spotify/network validation subprocess.' >&2
    exit 1
fi

OLD_TOKEN='OLD-abcdefghijklmnopqrstuvwxyz0123456789'
OLD_TIME='1750000000000'
NEW_TIME='1786000000000'
printf '%s\n' "$OLD_TOKEN" >"$AUTH_ROOT/spotify-refresh-token"
printf '%s\n' "$OLD_TIME" >"$AUTH_ROOT/spotify-authorized-at-ms"
printf '%s\n' 'STALE-abcdefghijklmnopqrstuvwxyz0123456789' \
    >"$AUTH_ROOT/.spotify-refresh-token.update.99999"
chmod 600 "$AUTH_ROOT/spotify-refresh-token" "$AUTH_ROOT/spotify-authorized-at-ms"

run_update() {
    command_name=$1
    payload_file=$2
    output_file=$3
    set +e
    SSH_ORIGINAL_COMMAND="$command_name" SSH_CONNECTION='192.0.2.8 32100 192.0.2.2 22' \
        "$UPDATER" <"$payload_file" >"$output_file" 2>"$WORK/stderr"
    UPDATE_STATUS=$?
    set -e
}

SUCCESS_TOKEN='VALID-abcdefghijklmnopqrstuvwxyz0123456789'
printf 'XIAOAIMUSIC_AUTH_V1\n%s\n%s\nEND\n' "$NEW_TIME" "$SUCCESS_TOKEN" \
    >"$WORK/success.payload"
run_update spotify-auth-update "$WORK/success.payload" "$WORK/success.out"
[ "$UPDATE_STATUS" -eq 0 ]
grep -qx 'OK auth_updated' "$WORK/success.out"
grep -qx "$SUCCESS_TOKEN" "$AUTH_ROOT/spotify-refresh-token"
grep -qx "$NEW_TIME" "$AUTH_ROOT/spotify-authorized-at-ms"
[ ! -e "$AUTH_ROOT/.spotify-refresh-token.update.99999" ]
! grep -Fq "$SUCCESS_TOKEN" "$WORK/success.out"

# A lost success ACK can be reconciled without ever returning the token.
: >"$WORK/empty.payload"
run_update spotify-auth-status "$WORK/empty.payload" "$WORK/status.out"
[ "$UPDATE_STATUS" -eq 0 ]
grep -qx "OK auth_status $NEW_TIME" "$WORK/status.out"
! grep -Fq "$SUCCESS_TOKEN" "$WORK/status.out"
printf 'unexpected\n' >"$WORK/status-extra.payload"
run_update spotify-auth-status "$WORK/status-extra.payload" "$WORK/status-extra.out"
[ "$UPDATE_STATUS" -eq 64 ]
grep -qx 'ERR protocol' "$WORK/status-extra.out"

(
    exec 9<>"$AUTH_ROOT/.spotify-auth-update.lock"
    flock -x 9
    touch "$WORK/lock.ready"
    while [ ! -e "$WORK/lock.release" ]; do sleep 0.01; done
) &
LOCK_HOLDER_PID=$!
for _ in $(seq 1 100); do
    [ -e "$WORK/lock.ready" ] && break
    sleep 0.01
done
[ -e "$WORK/lock.ready" ]
run_update spotify-auth-status "$WORK/empty.payload" "$WORK/status-busy.out"
[ "$UPDATE_STATUS" -eq 75 ]
grep -qx 'ERR busy' "$WORK/status-busy.out"
touch "$WORK/lock.release"
wait "$LOCK_HOLDER_PID"

# takeover queues one fixed datagram and returns promptly without waiting for
# SSH channel EOF.  The socket must be owned by the trusted uid and mode 0600.
cat >"$WORK/socket-receiver.py" <<'PY'
import os
import socket
import sys

path, ready, received = sys.argv[1:]
try:
    os.unlink(path)
except FileNotFoundError:
    pass
sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
sock.bind(path)
os.chmod(path, 0o600)
with open(ready, "w", encoding="ascii") as handle:
    handle.write("ready\n")
data = sock.recv(64)
with open(received, "wb") as handle:
    handle.write(data)
sock.close()
os.unlink(path)
PY
python3 "$WORK/socket-receiver.py" "$CONTROL_SOCKET" \
    "$WORK/socket.ready" "$WORK/socket.received" &
RECEIVER_PID=$!
for _ in $(seq 1 100); do
    [ -e "$WORK/socket.ready" ] && break
    sleep 0.01
done
[ -e "$WORK/socket.ready" ]
run_update takeover "$WORK/empty.payload" "$WORK/takeover.out"
[ "$UPDATE_STATUS" -eq 0 ]
grep -qx 'OK takeover_queued' "$WORK/takeover.out"
wait "$RECEIVER_PID"
grep -qx 'transfer' "$WORK/socket.received"

run_update takeover "$WORK/empty.payload" "$WORK/takeover-missing.out"
[ "$UPDATE_STATUS" -eq 69 ]
grep -qx 'ERR takeover' "$WORK/takeover-missing.out"

# Protocol/format failures are rejected locally before the shared lock or live
# files are touched.  The updater deliberately performs no Spotify network
# validation; the signed Android PKCE flow supplies pending_verified input.
cp "$AUTH_ROOT/spotify-refresh-token" "$WORK/token.before"
cp "$AUTH_ROOT/spotify-authorized-at-ms" "$WORK/time.before"
printf 'XIAOAIMUSIC_AUTH_V1\n%s\nshort\nEND\n' "$NEW_TIME" \
    >"$WORK/malformed.payload"
printf '%s\n' 'LIVE-ACCESS-CACHE-SENTINEL' >"$ACCESS_TOKEN"
printf '%s\n' 'LIVE-EXPIRY-CACHE-SENTINEL' >"$ACCESS_EXPIRY"
run_update spotify-auth-update "$WORK/malformed.payload" "$WORK/malformed.out"
[ "$UPDATE_STATUS" -eq 64 ]
grep -qx 'ERR protocol' "$WORK/malformed.out"
cmp -s "$WORK/token.before" "$AUTH_ROOT/spotify-refresh-token"
cmp -s "$WORK/time.before" "$AUTH_ROOT/spotify-authorized-at-ms"
grep -qx 'LIVE-ACCESS-CACHE-SENTINEL' "$ACCESS_TOKEN"
grep -qx 'LIVE-EXPIRY-CACHE-SENTINEL' "$ACCESS_EXPIRY"

# Existing live credentials with an unexpected hard link are not backed up or
# replaced; this prevents the old secret from surviving through another name.
ln "$AUTH_ROOT/spotify-refresh-token" "$AUTH_ROOT/token-hardlink"
run_update spotify-auth-update "$WORK/success.payload" "$WORK/hardlink.out"
[ "$UPDATE_STATUS" -eq 74 ]
grep -qx 'ERR unavailable' "$WORK/hardlink.out"
cmp -s "$WORK/token.before" "$AUTH_ROOT/spotify-refresh-token"
! find "$AUTH_ROOT" -maxdepth 1 -name '*.active*' | grep -q .
rm "$AUTH_ROOT/token-hardlink"

# The shared auth lock is itself a trust boundary.  Unsafe mode, ownership, or
# link count is rejected without chmod/unlink repair of an attacker-controlled
# inode; the live credential pair is untouched.
LOCK_FILE="$AUTH_ROOT/.spotify-auth-update.lock"
chmod 0644 "$LOCK_FILE"
run_update spotify-auth-update "$WORK/success.payload" "$WORK/lock-mode.out"
[ "$UPDATE_STATUS" -eq 74 ]
grep -qx 'ERR unavailable' "$WORK/lock-mode.out"
[ "$(stat -c %a "$LOCK_FILE")" = 644 ]
chmod 0600 "$LOCK_FILE"

if [ "$(id -u)" -eq 0 ]; then
    chown 65534:65534 "$LOCK_FILE"
    run_update spotify-auth-update "$WORK/success.payload" "$WORK/lock-owner.out"
    [ "$UPDATE_STATUS" -eq 74 ]
    grep -qx 'ERR unavailable' "$WORK/lock-owner.out"
    [ "$(stat -c %u "$LOCK_FILE")" -eq 65534 ]
    chown 0:0 "$LOCK_FILE"
    chmod 0600 "$LOCK_FILE"
fi

ln "$LOCK_FILE" "$AUTH_ROOT/auth-lock-hardlink"
run_update spotify-auth-update "$WORK/success.payload" "$WORK/lock-link.out"
[ "$UPDATE_STATUS" -eq 74 ]
grep -qx 'ERR unavailable' "$WORK/lock-link.out"
[ -e "$AUTH_ROOT/auth-lock-hardlink" ]
rm "$AUTH_ROOT/auth-lock-hardlink"
cmp -s "$WORK/token.before" "$AUTH_ROOT/spotify-refresh-token"
cmp -s "$WORK/time.before" "$AUTH_ROOT/spotify-authorized-at-ms"

# Dropbear's forced command must still present the exact application command.
run_update sh "$WORK/success.payload" "$WORK/command.out"
[ "$UPDATE_STATUS" -eq 64 ]
grep -qx 'ERR command' "$WORK/command.out"
cmp -s "$WORK/token.before" "$AUTH_ROOT/spotify-refresh-token"

# Trailing data is rejected; four LF-terminated lines followed by EOF is exact.
printf 'XIAOAIMUSIC_AUTH_V1\n%s\n%s\nEND\nEXTRA' "$NEW_TIME" "$SUCCESS_TOKEN" \
    >"$WORK/trailing.payload"
run_update spotify-auth-update "$WORK/trailing.payload" "$WORK/trailing.out"
[ "$UPDATE_STATUS" -eq 64 ]
grep -qx 'ERR protocol' "$WORK/trailing.out"
cmp -s "$WORK/token.before" "$AUTH_ROOT/spotify-refresh-token"
grep -qx 'LIVE-ACCESS-CACHE-SENTINEL' "$ACCESS_TOKEN"
grep -qx 'LIVE-EXPIRY-CACHE-SENTINEL' "$ACCESS_EXPIRY"

# Any format-valid pending_verified token is committed byte-for-byte without a
# network subprocess, and successful commit invalidates live access caches.
LOCAL_TOKEN='LOCAL-PENDING-VERIFIED-abcdefghijklmnopqrstuvwxyz0123456789'
printf 'XIAOAIMUSIC_AUTH_V1\n%s\n%s\nEND\n' "$NEW_TIME" "$LOCAL_TOKEN" \
    >"$WORK/local.payload"
run_update spotify-auth-update "$WORK/local.payload" "$WORK/local.out"
[ "$UPDATE_STATUS" -eq 0 ]
grep -qx "$LOCAL_TOKEN" "$AUTH_ROOT/spotify-refresh-token"
! grep -Fq "$LOCAL_TOKEN" "$WORK/local.out"
[ ! -e "$ACCESS_TOKEN" ]
[ ! -e "$ACCESS_EXPIRY" ]

# SIGKILL and power-loss-equivalent exits before the durable marker retain the
# old pair.  The marker is the commit decision: every valid phase after it rolls
# forward.  auth-status takes the same lock and performs recovery before it
# reports the timestamp, so a lost ACK cannot strand backups or old caches.
assert_crash_recovery() {
    crash_point=$1
    crash_index=$2
    expect_commit=$3
    crash_token="VALID-CRASH-${crash_index}-abcdefghijklmnopqrstuvwxyz0123456789"
    crash_time=$((1791000000000 + crash_index))
    printf '%s\n' "$OLD_TOKEN" >"$AUTH_ROOT/spotify-refresh-token"
    printf '%s\n' "$OLD_TIME" >"$AUTH_ROOT/spotify-authorized-at-ms"
    printf '%s\n' "OLD-ACCESS-${crash_index}" >"$ACCESS_TOKEN"
    printf '%s\n' "OLD-EXPIRY-${crash_index}" >"$ACCESS_EXPIRY"
    chmod 600 "$AUTH_ROOT/spotify-refresh-token" \
        "$AUTH_ROOT/spotify-authorized-at-ms"
    printf 'XIAOAIMUSIC_AUTH_V1\n%s\n%s\nEND\n' \
        "$crash_time" "$crash_token" >"$WORK/crash.payload"

    set +e
    XIAOAIMUSIC_TEST_CRASH_AT="$crash_point" \
        SSH_ORIGINAL_COMMAND=spotify-auth-update \
        SSH_CONNECTION='192.0.2.8 32100 192.0.2.2 22' \
        "$UPDATER" <"$WORK/crash.payload" >"$WORK/crash.out" \
        2>"$WORK/crash.err"
    crash_status=$?
    set -e
    [ "$crash_status" -eq 137 ]
    ! grep -Fq "$crash_token" "$WORK/crash.out"
    ! grep -Fq "$crash_token" "$WORK/crash.err"
    [ "$(stat -c %h "$AUTH_ROOT/spotify-refresh-token")" -eq 1 ]
    [ "$(stat -c %h "$AUTH_ROOT/spotify-authorized-at-ms")" -eq 1 ]
    [ "$(stat -c %a "$AUTH_ROOT/.spotify-refresh-token.backup.active")" = 600 ]
    [ "$(stat -c %h "$AUTH_ROOT/.spotify-refresh-token.backup.active")" -eq 1 ]
    [ "$(stat -c %i "$AUTH_ROOT/.spotify-refresh-token.backup.active")" != \
        "$(stat -c %i "$AUTH_ROOT/spotify-refresh-token")" ]
    if [ "$crash_point" != after-first-backup ]; then
        [ "$(stat -c %a "$AUTH_ROOT/.spotify-authorized-at.backup.active")" = 600 ]
        [ "$(stat -c %h "$AUTH_ROOT/.spotify-authorized-at.backup.active")" -eq 1 ]
        [ "$(stat -c %i "$AUTH_ROOT/.spotify-authorized-at.backup.active")" != \
            "$(stat -c %i "$AUTH_ROOT/spotify-authorized-at-ms")" ]
    fi
    if [ "$expect_commit" -eq 1 ]; then
        [ "$(stat -c %a "$AUTH_ROOT/.spotify-auth-update.transaction")" = 600 ]
        [ "$(stat -c %h "$AUTH_ROOT/.spotify-auth-update.transaction")" -eq 1 ]
    else
        [ ! -e "$AUTH_ROOT/.spotify-auth-update.transaction" ]
    fi

    run_update spotify-auth-status "$WORK/empty.payload" \
        "$WORK/crash-status.out"
    [ "$UPDATE_STATUS" -eq 0 ]
    if [ "$expect_commit" -eq 1 ]; then
        grep -qx "OK auth_status $crash_time" "$WORK/crash-status.out"
        grep -qx "$crash_token" "$AUTH_ROOT/spotify-refresh-token"
        grep -qx "$crash_time" "$AUTH_ROOT/spotify-authorized-at-ms"
        [ ! -e "$ACCESS_TOKEN" ]
        [ ! -e "$ACCESS_EXPIRY" ]
    else
        grep -qx "OK auth_status $OLD_TIME" "$WORK/crash-status.out"
        grep -qx "$OLD_TOKEN" "$AUTH_ROOT/spotify-refresh-token"
        grep -qx "$OLD_TIME" "$AUTH_ROOT/spotify-authorized-at-ms"
        grep -qx "OLD-ACCESS-${crash_index}" "$ACCESS_TOKEN"
        grep -qx "OLD-EXPIRY-${crash_index}" "$ACCESS_EXPIRY"
    fi
    ! grep -Fq "$crash_token" "$WORK/crash-status.out"
    if find "$AUTH_ROOT" -maxdepth 1 \
        \( -name '*.active*' -o -name '.spotify-auth-update.transaction' \) |
        grep -q .; then
        echo "Recovery left transaction artifacts after $crash_point." >&2
        exit 1
    fi
}

assert_crash_recovery after-first-backup 1 0
assert_crash_recovery after-second-backup 2 0
assert_crash_recovery after-marker 3 1
assert_crash_recovery after-first-rename 4 1
assert_crash_recovery after-second-rename 5 1

# A killed first-ever authorization after the marker also rolls forward; no
# backup is required when the pre-state had no live credentials.
FIRST_TOKEN='VALID-FIRST-abcdefghijklmnopqrstuvwxyz0123456789'
FIRST_TIME='1792000000000'
printf 'XIAOAIMUSIC_AUTH_V1\n%s\n%s\nEND\n' "$FIRST_TIME" "$FIRST_TOKEN" \
    >"$WORK/first.payload"
rm -f "$AUTH_ROOT/spotify-refresh-token" \
    "$AUTH_ROOT/spotify-authorized-at-ms"
set +e
XIAOAIMUSIC_TEST_CRASH_AT=after-marker \
    SSH_ORIGINAL_COMMAND=spotify-auth-update \
    SSH_CONNECTION='192.0.2.8 32100 192.0.2.2 22' \
    "$UPDATER" <"$WORK/first.payload" >"$WORK/first-crash.out" \
    2>"$WORK/first-crash.err"
first_crash_status=$?
set -e
[ "$first_crash_status" -eq 137 ]
! grep -Fq "$FIRST_TOKEN" "$WORK/first-crash.out"
! grep -Fq "$FIRST_TOKEN" "$WORK/first-crash.err"
run_update spotify-auth-status "$WORK/empty.payload" "$WORK/first-recovery.out"
[ "$UPDATE_STATUS" -eq 0 ]
grep -qx "OK auth_status $FIRST_TIME" "$WORK/first-recovery.out"
grep -qx "$FIRST_TOKEN" "$AUTH_ROOT/spotify-refresh-token"
grep -qx "$FIRST_TIME" "$AUTH_ROOT/spotify-authorized-at-ms"

# HUP/TERM are blocked across both renames and directory fsyncs.  A disconnect
# can suppress the ACK, but it must never expose a mixed token/timestamp pair.
assert_signal_consistency() {
    signal_name=$1
    signal_token="VALID-${signal_name}-abcdefghijklmnopqrstuvwxyz0123456789"
    signal_time=1790000000000
    printf '%s\n' "$OLD_TOKEN" >"$AUTH_ROOT/spotify-refresh-token"
    printf '%s\n' "$OLD_TIME" >"$AUTH_ROOT/spotify-authorized-at-ms"
    printf '%s\n' "${signal_name}-OLD-ACCESS" >"$ACCESS_TOKEN"
    printf '%s\n' "${signal_name}-OLD-EXPIRY" >"$ACCESS_EXPIRY"
    printf 'XIAOAIMUSIC_AUTH_V1\n%s\n%s\nEND\n' \
        "$signal_time" "$signal_token" >"$WORK/signal.payload"
    SSH_ORIGINAL_COMMAND=spotify-auth-update \
        SSH_CONNECTION='192.0.2.8 32100 192.0.2.2 22' \
        "$UPDATER" <"$WORK/signal.payload" >"$WORK/signal.out" 2>"$WORK/signal.err" &
    updater_pid=$!
    sleep 0.2
    kill -s "$signal_name" "$updater_pid"
    set +e
    wait "$updater_pid"
    signal_status=$?
    set -e
    [ "$signal_status" -ne 0 ]
    live_token=$(sed -n '1p' "$AUTH_ROOT/spotify-refresh-token")
    live_time=$(sed -n '1p' "$AUTH_ROOT/spotify-authorized-at-ms")
    if [ "$live_token" = "$OLD_TOKEN" ]; then
        [ "$live_time" = "$OLD_TIME" ]
        grep -qx "${signal_name}-OLD-ACCESS" "$ACCESS_TOKEN"
        grep -qx "${signal_name}-OLD-EXPIRY" "$ACCESS_EXPIRY"
    else
        [ "$live_token" = "$signal_token" ]
        [ "$live_time" = "$signal_time" ]
        [ ! -e "$ACCESS_TOKEN" ]
        [ ! -e "$ACCESS_EXPIRY" ]
    fi
}

assert_signal_consistency TERM
assert_signal_consistency HUP

# A subsequent request removes any stage left by a signal received before the
# protected section and proves the updater remains usable.
run_update spotify-auth-update "$WORK/success.payload" "$WORK/recovery.out"
[ "$UPDATE_STATUS" -eq 0 ]

if find "$AUTH_ROOT" -maxdepth 1 -type f \
    \( -name '*.update.*' -o -name '*.backup.*' -o -name '*.restore.*' \
       -o -name '.spotify-reauth.*' \
       -o -name '.spotify-auth-update.transaction*' \) |
    grep -q .; then
    echo 'Updater left a staging or backup file behind.' >&2
    exit 1
fi

echo SPOTIFY_AUTH_UPDATER_TESTS_OK
