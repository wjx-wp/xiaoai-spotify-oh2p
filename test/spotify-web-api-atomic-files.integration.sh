#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT=$REPO_ROOT/device/oh2p/spotify-web-api.sh

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || fail 'this fixture must run as root'

TEST_ROOT=$(mktemp -d /tmp/xiaoaimusic-api-atomic-test.XXXXXX)
chmod 700 "$TEST_ROOT"
trap 'rm -rf "$TEST_ROOT"' EXIT

MOCK_BIN=$TEST_ROOT/bin
mkdir -m 700 "$MOCK_BIN"

cat >"$MOCK_BIN/jsonfilter" <<'MOCK_JSONFILTER'
#!/bin/sh
expression=
input_file=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -e) expression=$2; shift 2 ;;
        -i) input_file=$2; shift 2 ;;
        *) shift ;;
    esac
done
if [ "${FAKE_CURL_MODE:-success}" = rotation_chain ]; then
    case "$expression" in
        '@.access_token') sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p' "$input_file" ;;
        '@.expires_in') printf '%s\n' '3600' ;;
        '@.refresh_token') sed -n 's/.*"refresh_token":"\([^"]*\)".*/\1/p' "$input_file" ;;
    esac
    exit 0
fi
case "$expression" in
    '@.access_token') printf '%s\n' "${FAKE_ACCESS_TOKEN:-}" ;;
    '@.expires_in') printf '%s\n' '3600' ;;
    '@.refresh_token') printf '%s\n' "${FAKE_ROTATED_REFRESH_TOKEN:-}" ;;
    '@.error') [ "${FAKE_CURL_MODE:-success}" = invalid_grant ] && printf '%s\n' invalid_grant ;;
    '@.error_description') [ "${FAKE_CURL_MODE:-success}" = invalid_grant ] && printf '%s\n' invalid_grant ;;
esac
MOCK_JSONFILTER
chmod 700 "$MOCK_BIN/jsonfilter"

cat >"$MOCK_BIN/curl" <<'MOCK_CURL'
#!/bin/sh
set -u

: >"$FAKE_CURL_CALLED"
if tr '\000' '\n' </proc/$$/cmdline | grep -Fq "$FAKE_ACCESS_TOKEN"; then
    : >"$FAKE_CURL_ARGV_LEAK"
    exit 96
fi

output=
write_out=
header_argument=
is_token_request=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        *"$FAKE_ACCESS_TOKEN"*) : >"$FAKE_CURL_ARGV_LEAK"; exit 96 ;;
        -o|--output) output=$2; shift 2 ;;
        -w|--write-out) write_out=$2; shift 2 ;;
        -H|--header) header_argument=$2; shift 2 ;;
        *'/api/token'*) is_token_request=1; shift ;;
        *) shift ;;
    esac
done
[ -n "$output" ] || exit 97

if [ "$is_token_request" -eq 1 ]; then
    refresh_input=$(cat)
    if [ "${FAKE_CURL_MODE:-success}" = rotation_chain ]; then
        if ! mkdir "$FAKE_CURL_ACTIVE_DIR" 2>/dev/null; then
            : >"$FAKE_CURL_OVERLAP"
            exit 103
        fi
        trap 'rmdir "$FAKE_CURL_ACTIVE_DIR" 2>/dev/null || true' EXIT HUP INT TERM
        printf '%s\n' "$refresh_input" >>"$FAKE_CURL_REFRESH_INPUTS"
        sleep 1
        case "$refresh_input" in
            ORIGINAL_CONCURRENT_REFRESH) rotated_token=ROTATED_CONCURRENT_REFRESH_A ;;
            ROTATED_CONCURRENT_REFRESH_A) rotated_token=ROTATED_CONCURRENT_REFRESH_B ;;
            *) rmdir "$FAKE_CURL_ACTIVE_DIR" 2>/dev/null || true; trap - EXIT HUP INT TERM; exit 104 ;;
        esac
        printf '{"access_token":"%s","expires_in":3600,"refresh_token":"%s"}\n' \
            "$FAKE_ACCESS_TOKEN" "$rotated_token" >"$output"
        rmdir "$FAKE_CURL_ACTIVE_DIR" 2>/dev/null || true
        trap - EXIT HUP INT TERM
        printf '%s' 200
        exit 0
    fi
    if [ "${FAKE_CURL_MODE:-success}" = invalid_grant ]; then
        printf '%s\n' '{"error":"invalid_grant","error_description":"invalid_grant"}' >"$output"
        printf '%s' 400
        exit 0
    fi
    printf '{"access_token":"%s","expires_in":3600,"refresh_token":"%s"}\n' \
        "$FAKE_ACCESS_TOKEN" "$FAKE_ROTATED_REFRESH_TOKEN" >"$output"
    printf '%s' 200
    exit 0
fi

case "$header_argument" in
    @*) header_file=${header_argument#@} ;;
    *) exit 98 ;;
esac
header_metadata=$(LC_ALL=C ls -ldn "$header_file") || exit 99
set -- $header_metadata
[ "$1" = '-rw-------' ] && [ "$2" = 1 ] && [ "$3" = 0 ] || exit 100
IFS= read -r header_line <"$header_file" || exit 101
[ "$header_line" = "Authorization: Bearer $FAKE_ACCESS_TOKEN" ] || exit 102
printf '%s\n' "$header_line" >"$FAKE_CURL_HEADER_CAPTURE"
printf '%s\n' "$header_file" >"$FAKE_CURL_HEADER_PATH"
printf '%s\n' '{}' >"$output"
case "$write_out" in
    *'|'*) printf '%s' '200|0.001' ;;
    *) printf '%s' 200 ;;
esac
MOCK_CURL
chmod 700 "$MOCK_BIN/curl"

cat >"$MOCK_BIN/fsync" <<'MOCK_FSYNC'
#!/bin/sh
[ "$#" -eq 1 ] && { [ -e "$1" ] || [ -d "$1" ]; }
MOCK_FSYNC
chmod 700 "$MOCK_BIN/fsync"
export XIAOAIMUSIC_FSYNC_BIN=$MOCK_BIN/fsync

LIBRARY=$TEST_ROOT/spotify-web-api-library.sh
sed '/^load_config$/,$d' "$SCRIPT" >"$LIBRARY"

assert_root_0600_regular_nlink1() {
    metadata=$(LC_ALL=C ls -ldn "$1") || fail "missing secure file: $1"
    set -- $metadata
    [ "$1" = '-rw-------' ] && [ "$2" = 1 ] && [ "$3" = 0 ] || \
        fail "unsafe metadata: $metadata"
}

assert_file_equals() {
    actual=$(cat "$1")
    [ "$actual" = "$2" ] || fail "unexpected content in $1"
}

run_api_fixture() {
    case_root=$TEST_ROOT/api-success
    mkdir -m 700 "$case_root"
    printf '%s\n' 'SPOTIFY_CLIENT_ID=test-client-id' >"$case_root/spotify-web.env"
    printf '%s\n' 'ORIGINAL_REFRESH_SENTINEL_0123456789' >"$case_root/spotify-refresh-token"
    chmod 600 "$case_root/spotify-web.env" "$case_root/spotify-refresh-token"

    printf '%s\n' 'ACCESS_VICTIM_UNCHANGED' >"$case_root/access-victim"
    printf '%s\n' 'EXPIRY_VICTIM_UNCHANGED' >"$case_root/expiry-victim"
    printf '%s\n' 'LEGACY_ACCESS_TMP_VICTIM_UNCHANGED' >"$case_root/legacy-access-tmp-victim"
    printf '%s\n' 'LEGACY_REFRESH_TMP_VICTIM_UNCHANGED' >"$case_root/legacy-refresh-tmp-victim"
    printf '%s\n' 'LOG_VICTIM_UNCHANGED' >"$case_root/log-victim"
    chmod 600 "$case_root"/*-victim

    ln -s "$case_root/access-victim" "$case_root/access-token"
    ln -s "$case_root/expiry-victim" "$case_root/access-expiry"
    ln -s "$case_root/legacy-access-tmp-victim" "$case_root/access-token.tmp"
    ln -s "$case_root/legacy-refresh-tmp-victim" "$case_root/spotify-refresh-token.tmp"
    ln -s "$case_root/log-victim" "$case_root/api.log"

    export PATH="$MOCK_BIN:$PATH"
    export SPOTIFY_WEB_CONFIG=$case_root/spotify-web.env
    export SPOTIFY_REFRESH_TOKEN_FILE=$case_root/spotify-refresh-token
    export SPOTIFY_ACCESS_TOKEN_FILE=$case_root/access-token
    export SPOTIFY_ACCESS_EXPIRY_FILE=$case_root/access-expiry
    export SPOTIFY_DEVICE_ID_CACHE_FILE=$case_root/device-id
    export SPOTIFY_REAUTHORIZATION_REQUIRED_FILE=$case_root/reauth-required
    export SPOTIFY_API_LOG_FILE=$case_root/api.log
    export SPOTIFY_LIKED_MIRROR_ID_FILE=$case_root/liked-id
    export SPOTIFY_LIKED_MIRROR_SYNC_FILE=$case_root/liked-sync
    export FAKE_ACCESS_TOKEN='ACCESS_SENTINEL_Aa0._~-'
    export FAKE_ROTATED_REFRESH_TOKEN='ROTATED_REFRESH_SENTINEL_0123456789'
    export FAKE_CURL_MODE=success
    export FAKE_CURL_CALLED=$case_root/curl-called
    export FAKE_CURL_ARGV_LEAK=$case_root/curl-argv-leak
    export FAKE_CURL_HEADER_CAPTURE=$case_root/header-capture
    export FAKE_CURL_HEADER_PATH=$case_root/header-path

    sh -c '. "$1"; load_config; api_request GET "https://api.spotify.com/v1/test"; rm -f "$API_RESPONSE"' \
        "$case_root/spotify-web-api.sh" "$LIBRARY" \
        >"$case_root/stdout" 2>"$case_root/stderr" </dev/null

    [ ! -e "$FAKE_CURL_ARGV_LEAK" ] || fail 'access token appeared in curl argv'
    [ -s "$FAKE_CURL_HEADER_CAPTURE" ] || fail 'curl did not read the authorization header file'
    assert_file_equals "$FAKE_CURL_HEADER_CAPTURE" "Authorization: Bearer $FAKE_ACCESS_TOKEN"
    header_path=$(cat "$FAKE_CURL_HEADER_PATH")
    [ ! -e "$header_path" ] || fail 'authorization header temp survived the request'

    assert_file_equals "$case_root/access-victim" 'ACCESS_VICTIM_UNCHANGED'
    assert_file_equals "$case_root/expiry-victim" 'EXPIRY_VICTIM_UNCHANGED'
    assert_file_equals "$case_root/legacy-access-tmp-victim" 'LEGACY_ACCESS_TMP_VICTIM_UNCHANGED'
    assert_file_equals "$case_root/legacy-refresh-tmp-victim" 'LEGACY_REFRESH_TMP_VICTIM_UNCHANGED'
    assert_file_equals "$case_root/log-victim" 'LOG_VICTIM_UNCHANGED'
    [ -L "$case_root/access-token.tmp" ] || fail 'legacy access .tmp symlink was unexpectedly followed or replaced'
    [ -L "$case_root/spotify-refresh-token.tmp" ] || fail 'legacy refresh .tmp symlink was unexpectedly followed or replaced'
    [ ! -L "$case_root/access-token" ] || fail 'access-token destination symlink was not safely replaced'
    [ ! -L "$case_root/access-expiry" ] || fail 'access-expiry destination symlink was not safely replaced'
    [ ! -L "$case_root/api.log" ] || fail 'log destination symlink was not safely replaced'

    assert_file_equals "$case_root/access-token" "$FAKE_ACCESS_TOKEN"
    assert_file_equals "$case_root/spotify-refresh-token" "$FAKE_ROTATED_REFRESH_TOKEN"
    assert_root_0600_regular_nlink1 "$case_root/access-token"
    assert_root_0600_regular_nlink1 "$case_root/access-expiry"
    assert_root_0600_regular_nlink1 "$case_root/spotify-refresh-token"
    assert_root_0600_regular_nlink1 "$case_root/api.log"

    for secret in ORIGINAL_REFRESH_SENTINEL ROTATED_REFRESH_SENTINEL ACCESS_SENTINEL; do
        if grep -Fq "$secret" "$case_root/stdout" "$case_root/stderr" "$case_root/api.log" 2>/dev/null; then
            fail "secret leaked to command output/log: $secret"
        fi
    done
}

run_refresh_symlink_fixture() {
    case_root=$TEST_ROOT/refresh-symlink
    mkdir -m 700 "$case_root"
    printf '%s\n' 'SPOTIFY_CLIENT_ID=test-client-id' >"$case_root/spotify-web.env"
    printf '%s\n' 'REFRESH_SYMLINK_SECRET_SENTINEL' >"$case_root/refresh-victim"
    chmod 600 "$case_root/spotify-web.env" "$case_root/refresh-victim"
    ln -s "$case_root/refresh-victim" "$case_root/spotify-refresh-token"

    rm -f "$case_root/curl-called"
    if PATH="$MOCK_BIN:$PATH" \
        SPOTIFY_WEB_CONFIG=$case_root/spotify-web.env \
        SPOTIFY_REFRESH_TOKEN_FILE=$case_root/spotify-refresh-token \
        SPOTIFY_ACCESS_TOKEN_FILE=$case_root/access-token \
        SPOTIFY_ACCESS_EXPIRY_FILE=$case_root/access-expiry \
        SPOTIFY_API_LOG_FILE=$case_root/api.log \
        FAKE_ACCESS_TOKEN='ACCESS_SENTINEL_Aa0._~-' \
        FAKE_ROTATED_REFRESH_TOKEN='ROTATED_REFRESH_SENTINEL_0123456789' \
        FAKE_CURL_CALLED=$case_root/curl-called \
        FAKE_CURL_ARGV_LEAK=$case_root/curl-argv-leak \
        FAKE_CURL_HEADER_CAPTURE=$case_root/header-capture \
        FAKE_CURL_HEADER_PATH=$case_root/header-path \
        sh -c '. "$1"; load_config' "$case_root/spotify-web-api.sh" "$LIBRARY" \
            >"$case_root/stdout" 2>"$case_root/stderr"; then
        fail 'load_config accepted a symlinked refresh token'
    fi
    [ ! -e "$case_root/curl-called" ] || fail 'curl ran after staged refresh-token validation failed'
    assert_file_equals "$case_root/refresh-victim" 'REFRESH_SYMLINK_SECRET_SENTINEL'
    if grep -Fq 'REFRESH_SYMLINK_SECRET_SENTINEL' "$case_root/stdout" "$case_root/stderr" \
        "$case_root/api.log" 2>/dev/null; then
        fail 'symlinked refresh token leaked to output/log'
    fi
}

run_marker_symlink_fixture() {
    case_root=$TEST_ROOT/marker-symlink
    mkdir -m 700 "$case_root"
    cp "$SCRIPT" "$case_root/spotify-web-api.sh"
    chmod 700 "$case_root/spotify-web-api.sh"
    printf '%s\n' 'SPOTIFY_CLIENT_ID=test-client-id' >"$case_root/spotify-web.env"
    printf '%s\n' 'ORIGINAL_REFRESH_FOR_INVALID_GRANT' >"$case_root/.spotify-refresh-token.update.active"
    printf '%s\n' '1770000000000' >"$case_root/.spotify-authorized-at.update.active"
    printf '%s\n' 'MARKER_VICTIM_UNCHANGED' >"$case_root/marker-victim"
    chmod 600 "$case_root/spotify-web.env" "$case_root/.spotify-refresh-token.update.active" \
        "$case_root/.spotify-authorized-at.update.active" "$case_root/marker-victim"
    ln -s "$case_root/marker-victim" "$case_root/.spotify-reauth.update.active"

    if PATH="$MOCK_BIN:$PATH" \
        SPOTIFY_REFRESH_TOKEN_FILE=$case_root/.spotify-refresh-token.update.active \
        SPOTIFY_ACCESS_TOKEN_FILE=$case_root/.spotify-refresh-token.update.active.access.3001 \
        SPOTIFY_ACCESS_EXPIRY_FILE=$case_root/.spotify-refresh-token.update.active.expiry.3001 \
        SPOTIFY_AUTHORIZED_AT_FILE=$case_root/.spotify-authorized-at.update.active \
        SPOTIFY_REAUTHORIZATION_REQUIRED_FILE=$case_root/.spotify-reauth.update.active \
        SPOTIFY_API_LOG_FILE=$case_root/.spotify-refresh-token.update.active.log.3001 \
        FAKE_ACCESS_TOKEN='ACCESS_SENTINEL_Aa0._~-' \
        FAKE_ROTATED_REFRESH_TOKEN='ROTATED_REFRESH_SENTINEL_0123456789' \
        FAKE_CURL_MODE=invalid_grant \
        FAKE_CURL_CALLED=$case_root/curl-called \
        FAKE_CURL_ARGV_LEAK=$case_root/curl-argv-leak \
        FAKE_CURL_HEADER_CAPTURE=$case_root/header-capture \
        FAKE_CURL_HEADER_PATH=$case_root/header-path \
        sh -c '. "$1"; load_config; refresh_access_token 1 >/dev/null' \
            "$case_root/spotify-web-api.sh" "$LIBRARY" \
            >"$case_root/stdout" 2>"$case_root/stderr"; then
        fail 'invalid_grant unexpectedly succeeded'
    fi
    assert_file_equals "$case_root/marker-victim" 'MARKER_VICTIM_UNCHANGED'
    [ ! -L "$case_root/.spotify-reauth.update.active" ] || fail 'reauthorization marker symlink was not safely replaced'
    assert_root_0600_regular_nlink1 "$case_root/.spotify-reauth.update.active"
    grep -Fq 'reason=invalid_grant' "$case_root/.spotify-reauth.update.active" || fail 'reauthorization marker is incomplete'
}

run_quote_rejection_fixture() {
    case_root=$TEST_ROOT/quote-rejection
    mkdir -m 700 "$case_root"
    cp "$SCRIPT" "$case_root/spotify-web-api.sh"
    chmod 700 "$case_root/spotify-web-api.sh"
    printf '%s\n' 'SPOTIFY_CLIENT_ID=test-client-id' >"$case_root/spotify-web.env"
    printf '%s\n' 'ORIGINAL_REFRESH_FOR_QUOTE_TEST' >"$case_root/.spotify-refresh-token.update.active"
    printf '%s\n' '1770000000000' >"$case_root/.spotify-authorized-at.update.active"
    chmod 600 "$case_root/spotify-web.env" "$case_root/.spotify-refresh-token.update.active" \
        "$case_root/.spotify-authorized-at.update.active"

    if PATH="$MOCK_BIN:$PATH" \
        SPOTIFY_REFRESH_TOKEN_FILE=$case_root/.spotify-refresh-token.update.active \
        SPOTIFY_ACCESS_TOKEN_FILE=$case_root/.spotify-refresh-token.update.active.access.4001 \
        SPOTIFY_ACCESS_EXPIRY_FILE=$case_root/.spotify-refresh-token.update.active.expiry.4001 \
        SPOTIFY_AUTHORIZED_AT_FILE=$case_root/.spotify-authorized-at.update.active \
        SPOTIFY_REAUTHORIZATION_REQUIRED_FILE=$case_root/.spotify-reauth.update.active \
        SPOTIFY_API_LOG_FILE=$case_root/.spotify-refresh-token.update.active.log.4001 \
        FAKE_ACCESS_TOKEN='ACCESS"TOKEN_INJECTION' \
        FAKE_ROTATED_REFRESH_TOKEN='' \
        FAKE_CURL_MODE=success \
        FAKE_CURL_CALLED=$case_root/curl-called \
        FAKE_CURL_ARGV_LEAK=$case_root/curl-argv-leak \
        FAKE_CURL_HEADER_CAPTURE=$case_root/header-capture \
        FAKE_CURL_HEADER_PATH=$case_root/header-path \
        sh -c '. "$1"; load_config; refresh_access_token 1 >/dev/null' \
            "$case_root/spotify-web-api.sh" "$LIBRARY" \
            >"$case_root/stdout" 2>"$case_root/stderr"; then
        fail 'access token containing a quote was accepted'
    fi
    [ ! -e "$case_root/header-capture" ] || fail 'unsafe access token reached a curl header file'
}

run_concurrent_rotation_fixture() {
    case_root=$TEST_ROOT/concurrent-rotation
    mkdir -m 700 "$case_root"
    printf '%s\n' 'SPOTIFY_CLIENT_ID=test-client-id' >"$case_root/spotify-web.env"
    printf '%s\n' 'ORIGINAL_CONCURRENT_REFRESH' >"$case_root/spotify-refresh-token"
    chmod 600 "$case_root/spotify-web.env" "$case_root/spotify-refresh-token"

    run_validation_instance() {
        instance=$1
        PATH="$MOCK_BIN:$PATH" \
            SPOTIFY_WEB_CONFIG=$case_root/spotify-web.env \
            SPOTIFY_REFRESH_TOKEN_FILE=$case_root/spotify-refresh-token \
            SPOTIFY_ACCESS_TOKEN_FILE=$case_root/access-token-$instance \
            SPOTIFY_ACCESS_EXPIRY_FILE=$case_root/access-expiry-$instance \
            SPOTIFY_AUTHORIZED_AT_FILE=$case_root/authorized-at-$instance \
            SPOTIFY_REAUTHORIZATION_REQUIRED_FILE=$case_root/reauth-$instance \
            SPOTIFY_API_LOG_FILE=$case_root/api-$instance.log \
            FAKE_ACCESS_TOKEN='CONCURRENT_ACCESS_SENTINEL_Aa0._~-' \
            FAKE_ROTATED_REFRESH_TOKEN='' \
            FAKE_CURL_MODE=rotation_chain \
            FAKE_CURL_CALLED=$case_root/curl-called \
            FAKE_CURL_ARGV_LEAK=$case_root/curl-argv-leak \
            FAKE_CURL_HEADER_CAPTURE=$case_root/header-capture-$instance \
            FAKE_CURL_HEADER_PATH=$case_root/header-path-$instance \
            FAKE_CURL_ACTIVE_DIR=$case_root/fake-curl-active \
            FAKE_CURL_OVERLAP=$case_root/curl-overlap \
            FAKE_CURL_REFRESH_INPUTS=$case_root/refresh-inputs \
            sh -c '. "$1"; load_config; refresh_access_token 1 >/dev/null' \
                "$case_root/spotify-web-api.sh" "$LIBRARY" >"$case_root/stdout-$instance" \
                2>"$case_root/stderr-$instance" </dev/null
    }

    run_validation_instance one &
    first_pid=$!
    active_seen=0
    for _ in $(seq 1 100); do
        if [ -d "$case_root/fake-curl-active" ]; then
            active_seen=1
            break
        fi
        sleep 0.02
    done
    [ "$active_seen" -eq 1 ] || fail 'first refresh never entered fake curl'
    run_validation_instance two &
    second_pid=$!

    first_status=0
    second_status=0
    wait "$first_pid" || first_status=$?
    wait "$second_pid" || second_status=$?
    [ "$first_status" -eq 0 ] || fail "first concurrent refresh failed: $first_status"
    [ "$second_status" -eq 0 ] || fail "second concurrent refresh failed: $second_status"
    [ ! -e "$case_root/curl-overlap" ] || fail 'refresh critical sections overlapped'
    [ ! -e "$case_root/curl-argv-leak" ] || fail 'concurrent access token appeared in curl argv'

    assert_file_equals "$case_root/spotify-refresh-token" 'ROTATED_CONCURRENT_REFRESH_B'
    first_input=$(sed -n '1p' "$case_root/refresh-inputs")
    second_input=$(sed -n '2p' "$case_root/refresh-inputs")
    third_input=$(sed -n '3p' "$case_root/refresh-inputs")
    [ "$first_input" = ORIGINAL_CONCURRENT_REFRESH ] || fail 'first refresh did not read the original token'
    [ "$second_input" = ROTATED_CONCURRENT_REFRESH_A ] || fail 'second refresh did not read the first rotation'
    [ -z "$third_input" ] || fail 'unexpected extra concurrent token refresh'
    assert_root_0600_regular_nlink1 "$case_root/.spotify-auth-update.lock"

    for instance in one two; do
        assert_root_0600_regular_nlink1 "$case_root/access-token-$instance"
        assert_root_0600_regular_nlink1 "$case_root/access-expiry-$instance"
        assert_root_0600_regular_nlink1 "$case_root/api-$instance.log"
    done
}

run_pending_transaction_fixture() {
    case_root=$TEST_ROOT/pending-transaction
    mkdir -m 700 "$case_root"
    printf '%s\n' 'SPOTIFY_CLIENT_ID=test-client-id' >"$case_root/spotify-web.env"
    printf '%s\n' 'PENDING_TRANSACTION_REFRESH_UNCHANGED' >"$case_root/spotify-refresh-token"
    printf '%s\n' 'XIAOAIMUSIC_AUTH_TXN_V1' >"$case_root/.spotify-auth-update.transaction"
    printf '%s\n' 'PENDING_TRANSACTION_ACCESS_VICTIM' >"$case_root/access-victim"
    chmod 600 "$case_root/spotify-web.env" "$case_root/spotify-refresh-token" \
        "$case_root/.spotify-auth-update.transaction" "$case_root/access-victim"
    ln -s "$case_root/access-victim" "$case_root/access-token"
    rm -f "$case_root/curl-called"

    if PATH="$MOCK_BIN:$PATH" \
        SPOTIFY_WEB_CONFIG=$case_root/spotify-web.env \
        SPOTIFY_REFRESH_TOKEN_FILE=$case_root/spotify-refresh-token \
        SPOTIFY_ACCESS_TOKEN_FILE=$case_root/access-token \
        SPOTIFY_ACCESS_EXPIRY_FILE=$case_root/access-expiry \
        SPOTIFY_API_LOG_FILE=$case_root/api.log \
        FAKE_ACCESS_TOKEN='ACCESS_SENTINEL_Aa0._~-' \
        FAKE_ROTATED_REFRESH_TOKEN='ROTATED_REFRESH_MUST_NOT_BE_USED' \
        FAKE_CURL_MODE=success \
        FAKE_CURL_CALLED=$case_root/curl-called \
        FAKE_CURL_ARGV_LEAK=$case_root/curl-argv-leak \
        FAKE_CURL_HEADER_CAPTURE=$case_root/header-capture \
        FAKE_CURL_HEADER_PATH=$case_root/header-path \
        sh -c '. "$1"; load_config; refresh_access_token 1 >/dev/null' \
            "$case_root/spotify-web-api.sh" "$LIBRARY" \
            >"$case_root/stdout" 2>"$case_root/stderr"; then
        fail 'refresh proceeded while an updater transaction was pending'
    fi

    [ ! -e "$case_root/curl-called" ] || fail 'curl ran while an updater transaction was pending'
    assert_file_equals "$case_root/spotify-refresh-token" 'PENDING_TRANSACTION_REFRESH_UNCHANGED'
    assert_file_equals "$case_root/access-victim" 'PENDING_TRANSACTION_ACCESS_VICTIM'
    [ -L "$case_root/access-token" ] || fail 'pending transaction touched the access cache symlink'
    grep -Fq 'AUTH_TRANSACTION_PENDING refresh=blocked' "$case_root/api.log" || \
        fail 'pending transaction refusal was not logged'
}

run_api_fixture
run_refresh_symlink_fixture
run_marker_symlink_fixture
run_quote_rejection_fixture
run_concurrent_rotation_fixture
run_pending_transaction_fixture

grep -Fq 'make_secure_temp "$atomic_dir/.${atomic_base}.tmp.XXXXXX"' "$SCRIPT" || \
    fail 'atomic writes do not use unique same-directory temp files'
if grep -Fq 'stat -c' "$SCRIPT"; then
    fail 'spotify-web-api.sh depends on unavailable OH2P stat command'
fi
if grep -Eq '\$(ACCESS_TOKEN_FILE|ACCESS_EXPIRY_FILE|REFRESH_TOKEN_FILE|DEVICE_ID_CACHE_FILE|REAUTHORIZATION_REQUIRED_FILE)\.tmp(\.\$\$)?(["[:space:]]|$)' "$SCRIPT"; then
    fail 'legacy predictable sensitive .tmp path remains'
fi
if grep -Fq -- '-H "Authorization: Bearer $token"' "$SCRIPT"; then
    fail 'access token remains exposed in curl argv'
fi
grep -Fq 'AUTH_LOCK_FILE=$ROOT/.spotify-auth-update.lock' "$SCRIPT" || \
    fail 'web API does not share the updater lock path'
grep -Fq 'AUTH_TRANSACTION_FILE=$ROOT/.spotify-auth-update.transaction' "$SCRIPT" || \
    fail 'web API does not fail closed on the updater transaction marker'
grep -Fq '"$FSYNC_BIN" "$ATOMIC_WRITE_TMP"' "$SCRIPT" || fail 'atomic temp data is not durable before rename'
grep -Fq '"$FSYNC_BIN" "$atomic_dir"' "$SCRIPT" || fail 'atomic rename is not made directory-durable'
if grep -Eq 'auth-validate|XIAOAIMUSIC_AUTH_LOCK_HELD' "$SCRIPT"; then
    fail 'retired updater-side Spotify validation path remains'
fi

printf '%s\n' 'spotify-web-api atomic-file integration: PASS'
