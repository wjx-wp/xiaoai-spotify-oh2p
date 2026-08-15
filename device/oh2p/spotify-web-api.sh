#!/bin/sh

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CONFIG_FILE=${SPOTIFY_WEB_CONFIG:-$ROOT/spotify-web.env}
REFRESH_TOKEN_FILE=${SPOTIFY_REFRESH_TOKEN_FILE:-$ROOT/spotify-refresh-token}
ACCESS_TOKEN_FILE=${SPOTIFY_ACCESS_TOKEN_FILE:-/tmp/xiaoaimusic-spotify-access-token}
ACCESS_EXPIRY_FILE=${SPOTIFY_ACCESS_EXPIRY_FILE:-/tmp/xiaoaimusic-spotify-access-expiry}
DEVICE_ID_CACHE_FILE=$ROOT/spotify-device-id
AUTHORIZED_AT_FILE=${SPOTIFY_AUTHORIZED_AT_FILE:-$ROOT/spotify-authorized-at-ms}
REAUTHORIZATION_REQUIRED_FILE=${SPOTIFY_REAUTHORIZATION_REQUIRED_FILE:-$ROOT/spotify-reauthorization-required}
AUTH_VALIDITY_DAYS=${SPOTIFY_AUTH_VALIDITY_DAYS:-180}
AUTH_WARNING_DAYS=${SPOTIFY_AUTH_WARNING_DAYS:-30}
LOG_FILE=${SPOTIFY_API_LOG_FILE:-/tmp/xiaoaimusic-spotify-api.log}
AUTH_LOCK_FILE=$ROOT/.spotify-auth-update.lock
AUTH_TRANSACTION_FILE=$ROOT/.spotify-auth-update.transaction
FSYNC_BIN=${XIAOAIMUSIC_FSYNC_BIN:-/bin/fsync}
KEYBRIDGE_BIN=${XIAOAIMUSIC_KEYBRIDGE_BIN:-$ROOT/bin/xiaoaimusic-keybridge}
LOCAL_CONTROL_SOCKET=${XIAOAIMUSIC_CONTROL_SOCKET:-/tmp/xiaoaimusic-librespot-control.sock}
API_BASE=https://api.spotify.com/v1
ACCOUNTS_TOKEN_URL=https://accounts.spotify.com/api/token
API_RESPONSE=
API_STATUS=
API_SILENT_ERRORS=0
JSON_PREFIX=
LIKED_MIRROR_NAME='XiaoAI · Liked Songs'
LIKED_MIRROR_ID_FILE=${SPOTIFY_LIKED_MIRROR_ID_FILE:-$ROOT/liked-mirror-playlist-id}
LIKED_MIRROR_SYNC_FILE=${SPOTIFY_LIKED_MIRROR_SYNC_FILE:-$ROOT/liked-mirror-last-sync}
RADIO_NAME='XiaoAI · Radio'
RADIO_ID_FILE=${SPOTIFY_RADIO_ID_FILE:-$ROOT/radio-playlist-id}
PERSONAL_POOL_FILE=${SPOTIFY_PERSONAL_POOL_FILE:-$ROOT/personal-radio-track-uris}
PERSONAL_POOL_MAX=${SPOTIFY_PERSONAL_POOL_MAX:-100}

ATOMIC_WRITE_TMP=
ATOMIC_SLOT_TMP=
CURL_HEADER_TMP=
TOKEN_RESPONSE_TMP=

umask 077

cleanup_sensitive_temps() {
    [ -z "$ATOMIC_WRITE_TMP" ] || rm -f "$ATOMIC_WRITE_TMP"
    [ -z "$ATOMIC_SLOT_TMP" ] || rm -f "$ATOMIC_SLOT_TMP"
    [ -z "$CURL_HEADER_TMP" ] || rm -f "$CURL_HEADER_TMP"
    [ -z "$TOKEN_RESPONSE_TMP" ] || rm -f "$TOKEN_RESPONSE_TMP"
    ATOMIC_WRITE_TMP=
    ATOMIC_SLOT_TMP=
    CURL_HEADER_TMP=
    TOKEN_RESPONSE_TMP=
}

trap 'cleanup_sensitive_temps' EXIT
trap 'cleanup_sensitive_temps; exit 129' HUP
trap 'cleanup_sensitive_temps; exit 130' INT
trap 'cleanup_sensitive_temps; exit 143' TERM

path_directory() {
    case "$1" in
        */*) PATH_DIRECTORY_RESULT=${1%/*}; [ -n "$PATH_DIRECTORY_RESULT" ] || PATH_DIRECTORY_RESULT=/ ;;
        *) PATH_DIRECTORY_RESULT=. ;;
    esac
}

secure_root_regular_file() {
    secure_file=$1
    [ -f "$secure_file" ] && [ ! -L "$secure_file" ] || return 1
    LC_ALL=C ls -ldn "$secure_file" 2>/dev/null | awk '
        NR == 1 {
            ok = ($1 == "-rw-------" && $2 == "1" && $3 == "0")
            next
        }
        { ok = 0 }
        END { exit(ok ? 0 : 1) }
    '
}

secure_root_directory() {
    secure_dir=$1
    [ -d "$secure_dir" ] && [ ! -L "$secure_dir" ] || return 1
    LC_ALL=C ls -ldn "$secure_dir" 2>/dev/null | awk '
        NR == 1 {
            mode = $1
            sticky = (substr(mode, 10, 1) == "t" || substr(mode, 10, 1) == "T")
            writable = (substr(mode, 6, 1) == "w" || substr(mode, 9, 1) == "w")
            ok = (substr(mode, 1, 1) == "d" && $3 == "0" && (!writable || sticky))
            next
        }
        { ok = 0 }
        END { exit(ok ? 0 : 1) }
    '
}

make_secure_temp() {
    secure_temp_pattern=$1
    SECURE_TEMP_RESULT=$(mktemp "$secure_temp_pattern" 2>/dev/null) || return 1
    chmod 600 "$SECURE_TEMP_RESULT" 2>/dev/null || {
        rm -f "$SECURE_TEMP_RESULT"
        SECURE_TEMP_RESULT=
        return 1
    }
    secure_root_regular_file "$SECURE_TEMP_RESULT" || {
        rm -f "$SECURE_TEMP_RESULT"
        SECURE_TEMP_RESULT=
        return 1
    }
}

reserve_atomic_target() {
    reserve_target=$1
    secure_root_regular_file "$reserve_target" && return 0

    path_directory "$reserve_target"
    reserve_dir=$PATH_DIRECTORY_RESULT
    reserve_base=${reserve_target##*/}
    [ -n "$reserve_base" ] || return 1
    secure_root_directory "$reserve_dir" || return 1
    make_secure_temp "$reserve_dir/.${reserve_base}.slot.XXXXXX" || return 1
    ATOMIC_SLOT_TMP=$SECURE_TEMP_RESULT

    reserve_attempt=0
    while [ "$reserve_attempt" -lt 20 ]; do
        if secure_root_regular_file "$reserve_target"; then
            rm -f "$ATOMIC_SLOT_TMP"
            ATOMIC_SLOT_TMP=
            return 0
        fi
        if [ -d "$reserve_target" ] && [ ! -L "$reserve_target" ]; then
            rm -f "$ATOMIC_SLOT_TMP"
            ATOMIC_SLOT_TMP=
            return 1
        fi
        rm -f "$reserve_target" 2>/dev/null || {
            rm -f "$ATOMIC_SLOT_TMP"
            ATOMIC_SLOT_TMP=
            return 1
        }
        if ln "$ATOMIC_SLOT_TMP" "$reserve_target" 2>/dev/null; then
            rm -f "$ATOMIC_SLOT_TMP"
            ATOMIC_SLOT_TMP=
            secure_root_regular_file "$reserve_target" && return 0
            return 1
        fi
        reserve_attempt=$((reserve_attempt + 1))
    done

    rm -f "$ATOMIC_SLOT_TMP"
    ATOMIC_SLOT_TMP=
    return 1
}

atomic_write() {
    atomic_target=$1
    atomic_content=$2
    path_directory "$atomic_target"
    atomic_dir=$PATH_DIRECTORY_RESULT
    atomic_base=${atomic_target##*/}
    [ -n "$atomic_base" ] || return 1
    secure_root_directory "$atomic_dir" || return 1
    make_secure_temp "$atomic_dir/.${atomic_base}.tmp.XXXXXX" || return 1
    ATOMIC_WRITE_TMP=$SECURE_TEMP_RESULT

    if ! printf '%s\n' "$atomic_content" >"$ATOMIC_WRITE_TMP" ||
        ! secure_root_regular_file "$ATOMIC_WRITE_TMP" ||
        ! "$FSYNC_BIN" "$ATOMIC_WRITE_TMP" ||
        ! reserve_atomic_target "$atomic_target" ||
        ! mv -f "$ATOMIC_WRITE_TMP" "$atomic_target"; then
        rm -f "$ATOMIC_WRITE_TMP"
        ATOMIC_WRITE_TMP=
        return 1
    fi
    ATOMIC_WRITE_TMP=
    secure_root_regular_file "$atomic_target" &&
        "$FSYNC_BIN" "$atomic_target" &&
        "$FSYNC_BIN" "$atomic_dir"
}

atomic_install_file() {
    atomic_source=$1
    atomic_target=$2
    path_directory "$atomic_target"
    atomic_dir=$PATH_DIRECTORY_RESULT
    atomic_base=${atomic_target##*/}
    [ -n "$atomic_base" ] || return 1
    secure_root_directory "$atomic_dir" || return 1
    make_secure_temp "$atomic_dir/.${atomic_base}.tmp.XXXXXX" || return 1
    ATOMIC_WRITE_TMP=$SECURE_TEMP_RESULT

    if ! cp "$atomic_source" "$ATOMIC_WRITE_TMP" ||
        ! secure_root_regular_file "$ATOMIC_WRITE_TMP" ||
        ! "$FSYNC_BIN" "$ATOMIC_WRITE_TMP" ||
        ! reserve_atomic_target "$atomic_target" ||
        ! mv -f "$ATOMIC_WRITE_TMP" "$atomic_target"; then
        rm -f "$ATOMIC_WRITE_TMP"
        ATOMIC_WRITE_TMP=
        return 1
    fi
    ATOMIC_WRITE_TMP=
    secure_root_regular_file "$atomic_target" &&
        "$FSYNC_BIN" "$atomic_target" &&
        "$FSYNC_BIN" "$atomic_dir"
}

valid_access_token() {
    access_token_candidate=$1
    case "$access_token_candidate" in
        ''|*[!A-Za-z0-9._~+/=-]*) return 1 ;;
    esac
    [ "${#access_token_candidate}" -le 4096 ]
}

prepare_curl_authorization_header() {
    authorization_token=$1
    valid_access_token "$authorization_token" || return 1
    secure_root_directory /tmp || return 1
    make_secure_temp /tmp/xiaoaimusic-curl-header.XXXXXX || return 1
    CURL_HEADER_TMP=$SECURE_TEMP_RESULT
    if ! printf 'Authorization: Bearer %s\n' "$authorization_token" >"$CURL_HEADER_TMP" ||
        ! secure_root_regular_file "$CURL_HEADER_TMP"; then
        rm -f "$CURL_HEADER_TMP"
        CURL_HEADER_TMP=
        return 1
    fi
}

clear_curl_authorization_header() {
    [ -z "$CURL_HEADER_TMP" ] || rm -f "$CURL_HEADER_TMP"
    CURL_HEADER_TMP=
}

log_message() {
    reserve_atomic_target "$LOG_FILE" || return 1
    printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >>"$LOG_FILE" || return 1
    secure_root_regular_file "$LOG_FILE"
}

fail() {
    log_message "ERROR $*"
    printf '%s\n' "$*" >&2
    exit 1
}

load_config() {
    path_directory "$CONFIG_FILE"
    secure_root_directory "$PATH_DIRECTORY_RESULT" || fail 'Spotify config directory is not secure'
    secure_root_regular_file "$CONFIG_FILE" && [ -r "$CONFIG_FILE" ] || \
        fail "缺少或不安全的 $CONFIG_FILE"
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
    SPOTIFY_CLIENT_ID=${SPOTIFY_CLIENT_ID:-}
    SPOTIFY_DEVICE_NAME=${SPOTIFY_DEVICE_NAME:-XiaoAI Music}
    [ -n "$SPOTIFY_CLIENT_ID" ] || fail "SPOTIFY_CLIENT_ID 尚未配置"
    path_directory "$REFRESH_TOKEN_FILE"
    secure_root_directory "$PATH_DIRECTORY_RESULT" || \
        fail 'Spotify refresh token directory is not secure'
    secure_root_regular_file "$REFRESH_TOKEN_FILE" && [ -s "$REFRESH_TOKEN_FILE" ] || \
        fail 'Spotify refresh token file is missing or insecure'
}

json_value() {
    file=$1
    expression=$2
    jsonfilter -i "$file" -e "$expression" 2>/dev/null | head -n 1
}

json_values() {
    file=$1
    expression=$2
    jsonfilter -i "$file" -e "$expression" 2>/dev/null | sed '/^$/d'
}

spotify_error_message() {
    file=$1
    message=$(json_value "$file" '@.error.message')
    [ -n "$message" ] || message=$(json_value "$file" '@.error_description')
    [ -n "$message" ] || message=$(json_value "$file" '@.error')
    [ -n "$message" ] || message=unknown_error
    printf '%s' "$message"
}

mark_reauthorization_required() {
    marker_content=$(printf 'reason=invalid_grant\ndetected_at_epoch=%s' "$(date +%s)")
    marker_tmp=$REAUTHORIZATION_REQUIRED_FILE
    if atomic_write "$REAUTHORIZATION_REQUIRED_FILE" "$marker_content"; then
        chmod 600 "$marker_tmp" || return 1
        secure_root_regular_file "$marker_tmp" || return 1
        return 0
    fi
    log_message 'AUTH_MARKER_WRITE_FAILED'
    return 1
}

clear_reauthorization_required() {
    if [ -e "$REAUTHORIZATION_REQUIRED_FILE" ]; then
        rm -f "$REAUTHORIZATION_REQUIRED_FILE" || return 1
        log_message 'AUTH_RECOVERED marker=cleared'
    fi
}

format_epoch_date() {
    epoch=$1
    date -u -d "@$epoch" '+%Y-%m-%d' 2>/dev/null || \
        date -u -D '%s' -d "$epoch" '+%Y-%m-%d' 2>/dev/null || \
        printf 'epoch-%s\n' "$epoch"
}

authorization_status() {
    verification=${1:-unverified}
    case "$AUTH_VALIDITY_DAYS" in
        *[!0-9]*|'') validity_days=180 ;;
        *) validity_days=$AUTH_VALIDITY_DAYS ;;
    esac
    case "$AUTH_WARNING_DAYS" in
        *[!0-9]*|'') warning_days=30 ;;
        *) warning_days=$AUTH_WARNING_DAYS ;;
    esac

    if [ -e "$REAUTHORIZATION_REQUIRED_FILE" ]; then
        auth_state=AUTH_EXPIRED
        reauthorization_required=yes
    elif [ "$verification" = verified ]; then
        auth_state=AUTH_OK
        reauthorization_required=no
    else
        auth_state=AUTH_UNVERIFIED
        reauthorization_required=no
    fi

    if [ ! -s "$AUTHORIZED_AT_FILE" ]; then
        printf 'SPOTIFY_AUTH status=%s reauthorization_required=%s authorized_at=unknown estimated_remaining_days=unknown\n' \
            "$auth_state" "$reauthorization_required"
        return 0
    fi

    authorized_at_ms=$(sed -n '1p' "$AUTHORIZED_AT_FILE" 2>/dev/null)
    case "$authorized_at_ms" in
        *[!0-9]*|'')
            printf 'SPOTIFY_AUTH status=%s reauthorization_required=%s authorized_at=unknown estimated_remaining_days=unknown\n' \
                "$auth_state" "$reauthorization_required"
            return 0
            ;;
    esac
    if [ "${#authorized_at_ms}" -lt 13 ]; then
        printf 'SPOTIFY_AUTH status=%s reauthorization_required=%s authorized_at=unknown estimated_remaining_days=unknown\n' \
            "$auth_state" "$reauthorization_required"
        return 0
    fi

    authorized_epoch=$(printf '%s\n' "$authorized_at_ms" | sed 's/[0-9][0-9][0-9]$//')
    case "$authorized_epoch" in
        *[!0-9]*|'')
            printf 'SPOTIFY_AUTH status=%s reauthorization_required=%s authorized_at=unknown estimated_remaining_days=unknown\n' \
                "$auth_state" "$reauthorization_required"
            return 0
            ;;
    esac

    now=$(date +%s)
    estimated_expiry=$((authorized_epoch + validity_days * 86400))
    remaining_seconds=$((estimated_expiry - now))
    if [ "$remaining_seconds" -ge 0 ]; then
        remaining_days=$(((remaining_seconds + 86399) / 86400))
    else
        remaining_days=$((-((-remaining_seconds + 86399) / 86400)))
    fi
    authorized_date=$(format_epoch_date "$authorized_epoch")
    estimated_expiry_date=$(format_epoch_date "$estimated_expiry")
    printf 'SPOTIFY_AUTH status=%s reauthorization_required=%s authorized_at=%s estimated_expires_at=%s estimated_remaining_days=%s\n' \
        "$auth_state" "$reauthorization_required" "$authorized_date" \
        "$estimated_expiry_date" "$remaining_days"
    if [ "$remaining_days" -le "$warning_days" ]; then
        printf 'SPOTIFY_AUTH_WARNING remaining_days=%s 请在手机“小爱 Spotify 接管”应用中重新授权。\n' \
            "$remaining_days"
    fi
}

refresh_access_token_under_lock() {
    force=${1:-0}
    now=$(date +%s)

    if [ "$force" -eq 0 ] && \
        secure_root_regular_file "$ACCESS_TOKEN_FILE" && \
        secure_root_regular_file "$ACCESS_EXPIRY_FILE" && \
        [ -s "$ACCESS_TOKEN_FILE" ] && [ -s "$ACCESS_EXPIRY_FILE" ]; then
        expiry=$(cat "$ACCESS_EXPIRY_FILE" 2>/dev/null || printf '0')
        case "$expiry" in
            *[!0-9]*|'') expiry=0 ;;
        esac
        if [ "$expiry" -gt $((now + 60)) ]; then
            cached_access_token=$(cat "$ACCESS_TOKEN_FILE" 2>/dev/null) || return 1
            if valid_access_token "$cached_access_token" && \
                secure_root_regular_file "$ACCESS_TOKEN_FILE"; then
                printf '%s\n' "$cached_access_token"
                return 0
            fi
        fi
    fi

    secure_root_directory /tmp || return 1
    make_secure_temp /tmp/xiaoaimusic-token.XXXXXX || return 1
    response=$SECURE_TEMP_RESULT
    TOKEN_RESPONSE_TMP=$response
    secure_root_regular_file "$REFRESH_TOKEN_FILE" || return 1
    refresh_token=$(cat "$REFRESH_TOKEN_FILE" 2>/dev/null) || return 1
    secure_root_regular_file "$REFRESH_TOKEN_FILE" || return 1
    status=$(printf '%s' "$refresh_token" | \
        curl -q -sS --connect-timeout 10 --max-time 25 \
            -o "$response" -w '%{http_code}' \
            -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
            --data-urlencode 'grant_type=refresh_token' \
            --data-urlencode 'refresh_token@-' \
            --data-urlencode "client_id=$SPOTIFY_CLIENT_ID" \
            "$ACCOUNTS_TOKEN_URL")
    curl_rc=$?

    if [ "$curl_rc" -ne 0 ] || [ "$status" != 200 ]; then
        error_code=$(json_value "$response" '@.error')
        message=$(spotify_error_message "$response")
        if [ "$error_code" = invalid_grant ]; then
            mark_reauthorization_required || true
            log_message "AUTH_EXPIRED status=$status error=invalid_grant"
            rm -f "$response"
            TOKEN_RESPONSE_TMP=
            printf '%s\n' 'Spotify 授权已失效：请在手机“小爱 Spotify 接管”应用中重新授权。现有 refresh token 已保留。' >&2
            return 1
        fi
        rm -f "$response"
        TOKEN_RESPONSE_TMP=
        log_message "TOKEN_REFRESH_FAILED status=$status error=$message"
        printf 'Spotify token 刷新失败（HTTP %s）：%s\n' "$status" "$message" >&2
        return 1
    fi

    access_token=$(json_value "$response" '@.access_token')
    expires_in=$(json_value "$response" '@.expires_in')
    rotated_refresh_token=$(json_value "$response" '@.refresh_token')
    valid_access_token "$access_token" || {
        rm -f "$response"
        TOKEN_RESPONSE_TMP=
        printf '%s\n' 'Spotify token 响应缺少 access_token' >&2
        return 1
    }
    case "$expires_in" in
        *[!0-9]*|'') expires_in=3600 ;;
    esac

    if [ -n "$rotated_refresh_token" ]; then
        if ! atomic_write "$REFRESH_TOKEN_FILE" "$rotated_refresh_token"; then
            rm -f "$ACCESS_TOKEN_FILE" "$ACCESS_EXPIRY_FILE" "$response"
            TOKEN_RESPONSE_TMP=
            log_message 'REFRESH_TOKEN_ROTATION_WRITE_FAILED'
            printf '%s\n' 'Spotify refresh token rotation write failed' >&2
            return 1
        fi
        log_message 'REFRESH_TOKEN_ROTATED'
    fi

    if ! atomic_write "$ACCESS_TOKEN_FILE" "$access_token" ||
        ! atomic_write "$ACCESS_EXPIRY_FILE" $((now + expires_in)); then
        rm -f "$ACCESS_TOKEN_FILE" "$ACCESS_EXPIRY_FILE" "$response"
        TOKEN_RESPONSE_TMP=
        log_message 'TOKEN_CACHE_WRITE_FAILED'
        printf '%s\n' 'Spotify token cache write failed' >&2
        return 1
    fi

    clear_reauthorization_required || log_message 'AUTH_MARKER_CLEAR_FAILED'

    rm -f "$response"
    TOKEN_RESPONSE_TMP=
    printf '%s\n' "$access_token"
}

refresh_access_token() {
    reserve_atomic_target "$AUTH_LOCK_FILE" || return 1
    exec 9>>"$AUTH_LOCK_FILE" || return 1
    if ! secure_root_regular_file "$AUTH_LOCK_FILE" || ! flock -x 9; then
        exec 9>&-
        return 1
    fi
    if [ -e "$AUTH_TRANSACTION_FILE" ] || [ -L "$AUTH_TRANSACTION_FILE" ]; then
        log_message 'AUTH_TRANSACTION_PENDING refresh=blocked'
        flock -u 9 2>/dev/null || true
        exec 9>&-
        return 1
    fi

    refresh_access_token_under_lock "$@"
    refresh_result=$?
    flock -u 9 2>/dev/null || true
    exec 9>&-
    return "$refresh_result"
}

api_request() {
    method=$1
    url=$2
    shift 2
    auth_retry=0
    rate_retry=0

    while :; do
        token=$(refresh_access_token "$auth_retry") || return 1
        prepare_curl_authorization_header "$token" || {
            log_message 'AUTHORIZATION_HEADER_PREPARE_FAILED'
            printf '%s\n' 'Spotify access token is invalid' >&2
            return 1
        }
        make_secure_temp /tmp/xiaoaimusic-api.XXXXXX || {
            clear_curl_authorization_header
            return 1
        }
        response=$SECURE_TEMP_RESULT
        request_result=$(curl -q -sS --connect-timeout 10 --max-time 30 \
            -o "$response" -w '%{http_code}|%{time_total}' \
            -X "$method" -H "@$CURL_HEADER_TMP" \
            "$@" "$url")
        curl_rc=$?
        clear_curl_authorization_header
        status=${request_result%%|*}
        request_time=${request_result#*|}
        request_path=${url#"$API_BASE"}
        request_path=${request_path%%\?*}
        log_message "API method=$method status=$status seconds=$request_time path=$request_path"

        if [ "$curl_rc" -ne 0 ]; then
            rm -f "$response"
            log_message "API_NETWORK_FAILED method=$method"
            [ "$API_SILENT_ERRORS" -ne 0 ] || printf '%s\n' 'Spotify API 网络请求失败' >&2
            return 1
        fi

        if [ "$status" = 401 ] && [ "$auth_retry" -eq 0 ]; then
            rm -f "$response"
            auth_retry=1
            continue
        fi
        if [ "$status" = 429 ] && [ "$rate_retry" -eq 0 ]; then
            rm -f "$response"
            rate_retry=1
            sleep 2
            continue
        fi

        API_RESPONSE=$response
        API_STATUS=$status
        case "$status" in
            2??) return 0 ;;
        esac

        message=$(spotify_error_message "$response")
        log_message "API_FAILED method=$method status=$status error=$message"
        [ "$API_SILENT_ERRORS" -ne 0 ] || \
            printf 'Spotify API 请求失败（HTTP %s）：%s\n' "$status" "$message" >&2
        rm -f "$response"
        API_RESPONSE=
        return 1
    done
}

target_device_id() {
    force_refresh=${1:-0}
    if [ "$force_refresh" -eq 0 ] && \
        secure_root_regular_file "$DEVICE_ID_CACHE_FILE" && \
        [ -s "$DEVICE_ID_CACHE_FILE" ]; then
        cached_id=$(sed -n '1p' "$DEVICE_ID_CACHE_FILE" 2>/dev/null)
        if [ -n "$cached_id" ]; then
            printf '%s\n' "$cached_id"
            return 0
        fi
    fi

    # OH2P 固件内置的旧版 jshn.sh 会读取未定义的位置参数和
    # JSON_UNSET；只在这个命令替换子进程里关闭 nounset。
    set +u
    api_request GET "$API_BASE/me/player/devices" || return 1
    response=$API_RESPONSE

    # shellcheck disable=SC1091
    . /usr/share/libubox/jshn.sh
    json_init
    json_load "$(cat "$response")" || {
        rm -f "$response"
        printf '%s\n' '无法解析 Spotify 设备列表' >&2
        return 1
    }
    rm -f "$response"

    json_select devices || {
        printf '%s\n' 'Spotify 没有返回可用设备' >&2
        return 1
    }
    json_get_keys device_keys
    active_id=
    first_id=
    matched_id=

    for device_key in $device_keys; do
        device_id=
        device_name=
        is_active=false
        is_restricted=false
        json_select "$device_key"
        json_get_var device_id id
        json_get_var device_name name
        json_get_var is_active is_active
        json_get_var is_restricted is_restricted
        json_select ..

        case "$is_restricted" in
            1|true) continue ;;
        esac
        [ -n "$first_id" ] || first_id=$device_id
        case "$is_active" in
            1|true) [ -n "$active_id" ] || active_id=$device_id ;;
        esac
        if [ "$device_name" = "$SPOTIFY_DEVICE_NAME" ]; then
            matched_id=$device_id
            break
        fi
    done

    if [ -n "$SPOTIFY_DEVICE_NAME" ]; then
        [ -n "$matched_id" ] || {
            printf 'Spotify Connect 中未找到设备：%s\n' "$SPOTIFY_DEVICE_NAME" >&2
            return 1
        }
        atomic_write "$DEVICE_ID_CACHE_FILE" "$matched_id" || return 1
        printf '%s\n' "$matched_id"
        return 0
    fi

    [ -n "$active_id" ] && {
        printf '%s\n' "$active_id"
        return 0
    }
    [ -n "$first_id" ] && {
        printf '%s\n' "$first_id"
        return 0
    }
    printf '%s\n' 'Spotify Connect 中没有可控制的设备' >&2
    return 1
}

start_uri() {
    uri=$1
    uri_kind=$2
    device_id=$(target_device_id) || return 1

    if [ "$uri_kind" = track ]; then
        body=$(printf '{"uris":["%s"]}' "$uri")
    else
        body=$(printf '{"context_uri":"%s"}' "$uri")
    fi
    API_SILENT_ERRORS=1
    first_status=0
    api_request PUT "$API_BASE/me/player/play?device_id=$device_id" \
        -H 'Content-Type: application/json' --data "$body" || first_status=$?
    API_SILENT_ERRORS=0
    if [ "$first_status" -ne 0 ]; then
        log_message "DEVICE_CACHE_REFRESH reason=play-failed"
        rm -f "$DEVICE_ID_CACHE_FILE"
        device_id=$(target_device_id 1) || return 1
        api_request PUT "$API_BASE/me/player/play?device_id=$device_id" \
            -H 'Content-Type: application/json' --data "$body" || return 1
    fi
    rm -f "$API_RESPONSE"
}

start_track_uris() {
    uri_file=$1
    device_id=$(target_device_id) || return 1
    body_file=$(mktemp /tmp/xiaoaimusic-play.XXXXXX) || return 1
    count=0
    separator=
    printf '{"uris":[' >"$body_file"
    while IFS= read -r uri; do
        case "$uri" in
            spotify:track:*) ;;
            *) continue ;;
        esac
        printf '%s"%s"' "$separator" "$uri" >>"$body_file"
        separator=,
        count=$((count + 1))
    done <"$uri_file"
    printf ']}' >>"$body_file"

    if [ "$count" -eq 0 ]; then
        rm -f "$body_file"
        printf '%s\n' 'Spotify 收藏中没有可播放的歌曲' >&2
        return 1
    fi

    api_request PUT "$API_BASE/me/player/play?device_id=$device_id" \
        -H 'Content-Type: application/json' --data-binary "@$body_file" || {
            rm -f "$body_file"
            return 1
        }
    rm -f "$body_file" "$API_RESPONSE"
    printf '%s\n' "$count"
}

play_liked_queue() {
    api_request GET "$API_BASE/me/tracks" --get --data 'limit=50' --data 'offset=0' || return 1
    response=$API_RESPONSE
    uri_file=$(mktemp /tmp/xiaoaimusic-liked.XXXXXX) || {
        rm -f "$response"
        return 1
    }
    json_values "$response" '@.items[*].track.uri' >"$uri_file"
    rm -f "$response"
    count=$(start_track_uris "$uri_file") || {
        rm -f "$uri_file"
        return 1
    }
    rm -f "$uri_file"
    log_message "PLAY type=liked count=$count"
    printf 'PLAYING\tliked\t%s\n' "$count"
}

valid_playlist_id() {
    case "$1" in
        ''|*[!A-Za-z0-9]*) return 1 ;;
    esac
    [ "${#1}" -le 64 ]
}

liked_mirror_id() {
    secure_root_regular_file "$LIKED_MIRROR_ID_FILE" && \
        [ -s "$LIKED_MIRROR_ID_FILE" ] || return 1
    playlist_id=$(cat "$LIKED_MIRROR_ID_FILE" 2>/dev/null)
    valid_playlist_id "$playlist_id" || return 1
    printf '%s\n' "$playlist_id"
}

play_liked() {
    if [ -s "$LIKED_MIRROR_SYNC_FILE" ] && playlist_id=$(liked_mirror_id); then
        start_uri "spotify:playlist:$playlist_id" playlist || return 1
        apply_repeat context || log_message "LIKED_REPEAT_ENABLE_FAILED playlist_id=$playlist_id"
        log_message "PLAY type=liked-mirror playlist_id=$playlist_id"
        printf 'PLAYING\tliked-mirror\t%s\n' "$playlist_id"
        return 0
    fi
    play_liked_queue
}

find_my_playlist() (
    set +u
    query=$1
    offset=0
    first_uri=
    first_name=
    partial_uri=
    partial_name=
    while :; do
        api_request GET "$API_BASE/me/playlists" --get --data 'limit=50' --data "offset=$offset" || return 1
        response=$API_RESPONSE
        total=$(json_value "$response" '@.total')
        . /usr/share/libubox/jshn.sh
        json_init
        json_load "$(cat "$response")" || { rm -f "$response"; return 1; }
        rm -f "$response"
        json_select items || break
        json_get_keys item_keys
        page_count=0
        for item_key in $item_keys; do
            page_count=$((page_count + 1))
            json_select "$item_key"
            json_get_var playlist_name name
            json_get_var playlist_uri uri
            json_select ..
            [ -n "$first_uri" ] || {
                first_uri=$playlist_uri
                first_name=$playlist_name
            }
            if [ -z "$query" ] || [ "$playlist_name" = "$query" ]; then
                printf '%s\n%s\n' "$playlist_uri" "$playlist_name"
                return 0
            fi
            case "$playlist_name" in
                *"$query"*)
                    [ -n "$partial_uri" ] || {
                        partial_uri=$playlist_uri
                        partial_name=$playlist_name
                    }
                    ;;
            esac
        done
        case "$total" in *[!0-9]*|'') total=0 ;; esac
        offset=$((offset + page_count))
        [ "$page_count" -eq 50 ] && { [ "$total" -eq 0 ] || [ "$offset" -lt "$total" ]; } || break
    done
    if [ -n "$partial_uri" ]; then
        printf '%s\n%s\n' "$partial_uri" "$partial_name"
        return 0
    fi
    if [ -z "$query" ] && [ -n "$first_uri" ]; then
        printf '%s\n%s\n' "$first_uri" "$first_name"
        return 0
    fi
    return 1
)

play_my_playlist() {
    query=$1
    match=$(find_my_playlist "$query") || {
        printf '你的 Spotify 歌单中没有找到：%s\n' "$query" >&2
        return 1
    }
    matched_uri=$(printf '%s\n' "$match" | sed -n '1p')
    matched_name=$(printf '%s\n' "$match" | sed -n '2p')
    start_uri "$matched_uri" playlist || return 1
    apply_repeat context || log_message "PLAYLIST_REPEAT_ENABLE_FAILED uri=$matched_uri"
    log_message "PLAY type=my-playlist query=$query result=$matched_name"
    printf 'PLAYING\tmy-playlist\t%s\n' "$matched_name"
}

collect_saved_track_uris() {
    output=$1
    : >"$output"
    offset=0
    while :; do
        api_request GET "$API_BASE/me/tracks" --get --data 'limit=50' --data "offset=$offset" || return 1
        response=$API_RESPONSE
        total=$(json_value "$response" '@.total')
        page_file=$(mktemp /tmp/xiaoaimusic-liked-page.XXXXXX) || { rm -f "$response"; return 1; }
        json_values "$response" '@.items[*].track.uri' >"$page_file"
        page_count=$(json_values "$response" '@.items[*].added_at' | wc -l | tr -d ' ')
        rm -f "$response"
        while IFS= read -r uri; do
            case "$uri" in spotify:track:*) printf '%s\n' "$uri" >>"$output" ;; esac
        done <"$page_file"
        rm -f "$page_file"
        case "$page_count" in *[!0-9]*|'') page_count=0 ;; esac
        case "$total" in *[!0-9]*|'') total=0 ;; esac
        offset=$((offset + page_count))
        [ "$page_count" -eq 50 ] && { [ "$total" -eq 0 ] || [ "$offset" -lt "$total" ]; } || break
    done
}

find_liked_mirror_id() {
    result=$(find_my_playlist "$LIKED_MIRROR_NAME") || return 1
    uri=$(printf '%s\n' "$result" | sed -n '1p')
    name=$(printf '%s\n' "$result" | sed -n '2p')
    [ "$name" = "$LIKED_MIRROR_NAME" ] || return 1
    playlist_id=${uri#spotify:playlist:}
    valid_playlist_id "$playlist_id" || return 1
    printf '%s\n' "$playlist_id"
}

ensure_liked_mirror_id() {
    if playlist_id=$(liked_mirror_id); then
        printf '%s\n' "$playlist_id"
        return 0
    fi
    if playlist_id=$(find_liked_mirror_id); then
        atomic_write "$LIKED_MIRROR_ID_FILE" "$playlist_id" || return 1
        printf '%s\n' "$playlist_id"
        return 0
    fi
    body='{"name":"XiaoAI · Liked Songs","public":false,"description":"Managed by XiaoAI Music on OH2P."}'
    api_request POST "$API_BASE/me/playlists" -H 'Content-Type: application/json' --data "$body" || return 1
    playlist_id=$(json_value "$API_RESPONSE" '@.id')
    rm -f "$API_RESPONSE"
    valid_playlist_id "$playlist_id" || {
        printf '%s\n' 'Spotify 创建点赞镜像歌单后没有返回有效 ID' >&2
        return 1
    }
    atomic_write "$LIKED_MIRROR_ID_FILE" "$playlist_id" || return 1
    printf '%s\n' "$playlist_id"
}

radio_id() {
    secure_root_regular_file "$RADIO_ID_FILE" && [ -s "$RADIO_ID_FILE" ] || return 1
    playlist_id=$(cat "$RADIO_ID_FILE" 2>/dev/null)
    valid_playlist_id "$playlist_id" || return 1
    printf '%s\n' "$playlist_id"
}

find_radio_id() {
    result=$(find_my_playlist "$RADIO_NAME") || return 1
    uri=$(printf '%s\n' "$result" | sed -n '1p')
    name=$(printf '%s\n' "$result" | sed -n '2p')
    [ "$name" = "$RADIO_NAME" ] || return 1
    playlist_id=${uri#spotify:playlist:}
    valid_playlist_id "$playlist_id" || return 1
    printf '%s\n' "$playlist_id"
}

ensure_radio_id() {
    if playlist_id=$(radio_id); then
        printf '%s\n' "$playlist_id"
        return 0
    fi
    if playlist_id=$(find_radio_id); then
        atomic_write "$RADIO_ID_FILE" "$playlist_id" || return 1
        printf '%s\n' "$playlist_id"
        return 0
    fi
    body='{"name":"XiaoAI · Radio","public":false,"description":"Personal radio queue managed by XiaoAI Music."}'
    api_request POST "$API_BASE/me/playlists" -H 'Content-Type: application/json' --data "$body" || return 1
    playlist_id=$(json_value "$API_RESPONSE" '@.id')
    rm -f "$API_RESPONSE"
    valid_playlist_id "$playlist_id" || {
        printf '%s\n' 'Spotify 创建 Radio 歌单后没有返回有效 ID' >&2
        return 1
    }
    atomic_write "$RADIO_ID_FILE" "$playlist_id" || return 1
    printf '%s\n' "$playlist_id"
}

refresh_personal_pool() {
    liked_file=$1
    raw_file=$(mktemp /tmp/xiaoaimusic-personal-raw.XXXXXX) || return 1
    pool_file=$(mktemp /tmp/xiaoaimusic-personal-pool.XXXXXX) || {
        rm -f "$raw_file"
        return 1
    }
    : >"$raw_file"

    API_SILENT_ERRORS=1
    if api_request GET "$API_BASE/me/top/tracks" --get \
            --data 'time_range=medium_term' --data 'limit=50'; then
        response=$API_RESPONSE
        json_values "$response" '@.items[*].uri' >>"$raw_file"
        rm -f "$response"
    fi
    API_SILENT_ERRORS=0
    cat "$liked_file" >>"$raw_file"

    case "$PERSONAL_POOL_MAX" in *[!0-9]*|'') PERSONAL_POOL_MAX=100 ;; esac
    [ "$PERSONAL_POOL_MAX" -ge 2 ] || PERSONAL_POOL_MAX=2
    [ "$PERSONAL_POOL_MAX" -le 100 ] || PERSONAL_POOL_MAX=100
    awk -v max="$PERSONAL_POOL_MAX" '
        /^spotify:track:[A-Za-z0-9]+$/ && !seen[$0]++ {
            print
            count++
            if (count >= max) exit
        }
    ' "$raw_file" >"$pool_file"
    rm -f "$raw_file"
    if [ ! -s "$pool_file" ] || ! atomic_install_file "$pool_file" "$PERSONAL_POOL_FILE"; then
        rm -f "$pool_file"
        return 1
    fi
    pool_count=$(wc -l <"$pool_file" | tr -d ' ')
    rm -f "$pool_file"
    log_message "SYNC type=personal-pool count=$pool_count"
}

pick_personal_seed() {
    secure_root_regular_file "$PERSONAL_POOL_FILE" && [ -s "$PERSONAL_POOL_FILE" ] || return 1
    count=$(wc -l <"$PERSONAL_POOL_FILE" | tr -d ' ')
    case "$count" in *[!0-9]*|'') return 1 ;; esac
    [ "$count" -gt 0 ] || return 1
    now=$(date +%s)
    line=$((now % count + 1))
    track_uri=$(sed -n "${line}p" "$PERSONAL_POOL_FILE")
    case "$track_uri" in spotify:track:*) printf '%s\n' "$track_uri" ;; *) return 1 ;; esac
}

build_radio_body() {
    seed_uri=$1
    output=$2
    uri_file=$(mktemp /tmp/xiaoaimusic-radio-uris.XXXXXX) || return 1
    unique_file=$(mktemp /tmp/xiaoaimusic-radio-unique.XXXXXX) || {
        rm -f "$uri_file"
        return 1
    }
    printf '%s\n' "$seed_uri" >"$uri_file"
    if secure_root_regular_file "$PERSONAL_POOL_FILE"; then
        cat "$PERSONAL_POOL_FILE" >>"$uri_file"
    fi
    awk '
        /^spotify:track:[A-Za-z0-9]+$/ && !seen[$0]++ {
            print
            count++
            if (count >= 100) exit
        }
    ' "$uri_file" >"$unique_file"
    rm -f "$uri_file"
    write_uri_batch_body "$unique_file" 1 "$output"
    radio_count=$(wc -l <"$unique_file" | tr -d ' ')
    rm -f "$unique_file"
    [ "$radio_count" -ge 1 ]
}

play_track_radio() {
    track_uri=$1
    query=$2
    track_name=$3
    case "$track_uri" in
        spotify:track:*) ;;
        *) printf '%s\n' 'Spotify 返回了无效的单曲 URI' >&2; return 1 ;;
    esac

    playlist_id=$(ensure_radio_id) || return 1
    body_file=$(mktemp /tmp/xiaoaimusic-radio-body.XXXXXX) || return 1
    build_radio_body "$track_uri" "$body_file" || {
        rm -f "$body_file"
        return 1
    }
    api_request PUT "$API_BASE/playlists/$playlist_id/items" \
        -H 'Content-Type: application/json' --data-binary "@$body_file" || {
            rm -f "$body_file"
            return 1
        }
    rm -f "$body_file" "$API_RESPONSE"

    start_uri "spotify:playlist:$playlist_id" playlist || return 1
    apply_shuffle true || log_message "RADIO_SHUFFLE_ENABLE_FAILED playlist_id=$playlist_id"
    apply_repeat context || log_message "RADIO_REPEAT_ENABLE_FAILED playlist_id=$playlist_id"
    log_message "PLAY type=radio query=$query result=$track_name playlist_id=$playlist_id"
    printf 'PLAYING\tradio\t%s\n' "$track_name"
}

play_for_me() {
    if track_uri=$(pick_personal_seed); then
        play_track_radio "$track_uri" personal 'XiaoAI Personal Mix'
        return $?
    fi
    play_liked || return 1
    apply_shuffle true || return 1
    apply_repeat context || return 1
}

write_uri_batch_body() {
    source_file=$1
    start_line=$2
    output=$3
    end_line=$((start_line + 99))
    separator=
    printf '{"uris":[' >"$output"
    sed -n "${start_line},${end_line}p" "$source_file" | while IFS= read -r uri; do
        case "$uri" in spotify:track:*) printf '%s"%s"' "$separator" "$uri"; separator=, ;; esac
    done >>"$output"
    printf ']}' >>"$output"
}

sync_liked_mirror() {
    rm -f "$LIKED_MIRROR_SYNC_FILE"
    playlist_id=$(ensure_liked_mirror_id) || return 1
    uri_file=$(mktemp /tmp/xiaoaimusic-liked-all.XXXXXX) || return 1
    collect_saved_track_uris "$uri_file" || { rm -f "$uri_file"; return 1; }
    count=$(wc -l <"$uri_file" | tr -d ' ')
    case "$count" in *[!0-9]*|'') count=0 ;; esac
    start_line=1
    method=PUT
    while [ "$start_line" -le "$count" ] || { [ "$count" -eq 0 ] && [ "$start_line" -eq 1 ]; }; do
        body_file=$(mktemp /tmp/xiaoaimusic-liked-body.XXXXXX) || { rm -f "$uri_file"; return 1; }
        write_uri_batch_body "$uri_file" "$start_line" "$body_file"
        api_request "$method" "$API_BASE/playlists/$playlist_id/items" \
            -H 'Content-Type: application/json' --data-binary "@$body_file" || {
                rm -f "$body_file" "$uri_file"
                return 1
            }
        rm -f "$body_file" "$API_RESPONSE"
        [ "$count" -eq 0 ] && break
        start_line=$((start_line + 100))
        method=POST
    done
    refresh_personal_pool "$uri_file" || {
        rm -f "$uri_file"
        return 1
    }
    rm -f "$uri_file"
    sync_completed_at=$(date +%s)
    atomic_write "$LIKED_MIRROR_SYNC_FILE" "$sync_completed_at" || return 1
    log_message "SYNC type=liked-mirror playlist_id=$playlist_id count=$count"
    printf 'SYNCED\tliked-mirror\t%s\t%s\n' "$playlist_id" "$count"
}

search_and_play() {
    item_type=$1
    query=$2
    case "$item_type" in
        artist) collection=artists ;;
        track) collection=tracks ;;
        album) collection=albums ;;
        playlist) collection=playlists ;;
        *) printf '不支持的 Spotify 搜索类型：%s\n' "$item_type" >&2; return 1 ;;
    esac

    api_request GET "$API_BASE/search" --get \
        --data-urlencode "q=$query" --data "type=$item_type" --data 'limit=5' || return 1
    response=$API_RESPONSE
    uri=$(json_value "$response" "@.$collection.items[0].uri")
    name=$(json_value "$response" "@.$collection.items[0].name")
    rm -f "$response"
    [ -n "$uri" ] || {
        printf 'Spotify 中没有找到：%s\n' "$query" >&2
        return 1
    }

    if [ "$item_type" = track ]; then
        play_track_radio "$uri" "$query" "$name"
    else
        start_uri "$uri" "$item_type" || return 1
        apply_repeat context || log_message "CONTEXT_REPEAT_ENABLE_FAILED type=$item_type"
        log_message "PLAY type=$item_type query=$query result=$name"
        printf 'PLAYING\t%s\t%s\n' "$item_type" "$name"
    fi
}

auto_search_and_play() {
    query=$1
    api_request GET "$API_BASE/search" --get \
        --data-urlencode "q=$query" --data 'type=artist,track' --data 'limit=5' || return 1
    response=$API_RESPONSE
    artist_name=$(json_value "$response" '@.artists.items[0].name')
    artist_uri=$(json_value "$response" '@.artists.items[0].uri')
    track_name=$(json_value "$response" '@.tracks.items[0].name')
    track_uri=$(json_value "$response" '@.tracks.items[0].uri')
    rm -f "$response"

    if [ -n "$artist_uri" ] && [ "$artist_name" = "$query" ]; then
        start_uri "$artist_uri" artist || return 1
        apply_repeat context || log_message 'CONTEXT_REPEAT_ENABLE_FAILED type=artist'
        log_message "PLAY type=artist query=$query result=$artist_name"
        printf 'PLAYING\tartist\t%s\n' "$artist_name"
        return 0
    fi
    if [ -n "$track_uri" ]; then
        play_track_radio "$track_uri" "$query" "$track_name"
        return $?
    fi
    if [ -n "$artist_uri" ]; then
        start_uri "$artist_uri" artist || return 1
        apply_repeat context || log_message 'CONTEXT_REPEAT_ENABLE_FAILED type=artist'
        log_message "PLAY type=artist query=$query result=$artist_name"
        printf 'PLAYING\tartist\t%s\n' "$artist_name"
        return 0
    fi
    printf 'Spotify 中没有找到：%s\n' "$query" >&2
    return 1
}

local_transport() {
    action=$1
    case "$action" in
        resume) local_command=play ;;
        pause|next|previous) local_command=$action ;;
        *) return 1 ;;
    esac
    [ -x "$KEYBRIDGE_BIN" ] || return 1
    "$KEYBRIDGE_BIN" --send-command "$local_command" \
        --control-socket "$LOCAL_CONTROL_SOCKET" 2>/dev/null
}

transport() {
    action=$1
    if local_transport "$action"; then
        log_message "TRANSPORT action=$action source=local-spirc"
        printf 'TRANSPORT\t%s\n' "$action"
        return 0
    fi
    log_message "TRANSPORT_LOCAL_FAILED action=$action fallback=web-api"

    device_id=$(target_device_id) || return 1
    case "$action" in
        resume) method=PUT; path=play ;;
        pause) method=PUT; path=pause ;;
        next) method=POST; path=next ;;
        previous) method=POST; path=previous ;;
        *) return 1 ;;
    esac
    api_request "$method" "$API_BASE/me/player/$path?device_id=$device_id" --data '' || return 1
    rm -f "$API_RESPONSE"
    log_message "TRANSPORT action=$action source=web-api"
    printf 'TRANSPORT\t%s\n' "$action"
}

toggle_playback() {
    api_request GET "$API_BASE/me/player" || return 1
    response=$API_RESPONSE
    active_device_id=$(json_value "$response" '@.device.id')
    active_device_name=$(json_value "$response" '@.device.name')
    is_playing=$(json_value "$response" '@.is_playing')
    rm -f "$response"

    if [ -n "$active_device_id" ] && [ "$active_device_name" = "$SPOTIFY_DEVICE_NAME" ]; then
        device_id=$active_device_id
    else
        device_id=$(target_device_id) || return 1
    fi

    if [ "$active_device_id" = "$device_id" ] && { [ "$is_playing" = true ] || [ "$is_playing" = 1 ]; }; then
        action=pause
    else
        action=resume
    fi
    case "$action" in
        pause) path=pause ;;
        resume) path=play ;;
    esac
    api_request PUT "$API_BASE/me/player/$path?device_id=$device_id" --data '' || return 1
    rm -f "$API_RESPONSE"
    log_message "TRANSPORT action=$action source=keybridge"
    printf 'TRANSPORT\t%s\n' "$action"
}

apply_shuffle() {
    state=$1
    case "$state" in true|false) ;; *) return 1 ;; esac
    device_id=$(target_device_id) || return 1
    api_request PUT "$API_BASE/me/player/shuffle?state=$state&device_id=$device_id" --data '' || return 1
    rm -f "$API_RESPONSE"
}

set_shuffle() {
    state=$1
    case "$state" in
        on|true) state=true ;;
        off|false) state=false ;;
        *) printf '%s\n' '随机播放参数必须是 on 或 off' >&2; return 1 ;;
    esac
    apply_shuffle "$state" || return 1
    log_message "SHUFFLE state=$state"
    printf 'SHUFFLE\t%s\n' "$state"
}

apply_repeat() {
    state=$1
    case "$state" in
        off|track|context) ;;
        *) printf '%s\n' '循环参数必须是 off、track 或 context' >&2; return 1 ;;
    esac
    device_id=$(target_device_id) || return 1
    api_request PUT "$API_BASE/me/player/repeat?state=$state&device_id=$device_id" --data '' || return 1
    rm -f "$API_RESPONSE"
}

set_repeat() {
    state=$1
    apply_repeat "$state" || return 1
    log_message "REPEAT state=$state"
    printf 'REPEAT\t%s\n' "$state"
}

healthcheck() {
    if ! refresh_access_token 0 >/dev/null; then
        authorization_status unverified
        return 1
    fi
    authorization_status verified
    device_id=$(target_device_id 1) || return 1
    printf 'SPOTIFY_API_READY\t%s\t%s\n' "$SPOTIFY_DEVICE_NAME" "$device_id"
}

command=${1:-}
load_config

case "$command" in
    play-for-me)
        [ "$#" -eq 1 ] || fail '用法：spotify-web-api.sh play-for-me'
        play_for_me
        ;;
    play-auto)
        [ "$#" -ge 2 ] || fail '用法：spotify-web-api.sh play-auto 查询词'
        shift
        auto_search_and_play "$*"
        ;;
    play)
        [ "$#" -ge 3 ] || fail '用法：spotify-web-api.sh play artist|track|album|playlist 查询词'
        item_type=$2
        shift 2
        search_and_play "$item_type" "$*"
        ;;
    play-liked)
        [ "$#" -eq 1 ] || fail '用法：spotify-web-api.sh play-liked'
        play_liked
        ;;
    play-liked-shuffle)
        [ "$#" -eq 1 ] || fail '用法：spotify-web-api.sh play-liked-shuffle'
        play_liked
        set_shuffle on
        ;;
    sync-liked)
        [ "$#" -eq 1 ] || fail '用法：spotify-web-api.sh sync-liked'
        sync_liked_mirror
        ;;
    play-my-playlist)
        shift
        play_my_playlist "$*"
        ;;
    resume|pause|next|previous)
        transport "$command"
        ;;
    toggle)
        [ "$#" -eq 1 ] || fail '用法：spotify-web-api.sh toggle'
        toggle_playback
        ;;
    shuffle)
        [ "$#" -eq 2 ] || fail '用法：spotify-web-api.sh shuffle on|off'
        set_shuffle "$2"
        ;;
    repeat)
        [ "$#" -eq 2 ] || fail '用法：spotify-web-api.sh repeat off|track|context'
        set_repeat "$2"
        ;;
    health)
        healthcheck
        ;;
    *)
        fail '用法：spotify-web-api.sh {play-for-me|play-auto|play|play-liked|play-liked-shuffle|sync-liked|play-my-playlist|resume|pause|toggle|next|previous|shuffle|repeat|health}'
        ;;
esac
