#!/bin/sh

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
INSTRUCTION_LOG=${XIAOAI_INSTRUCTION_LOG:-/tmp/mico_aivs_lab/instruction.log}
BRIDGE_LOG=/tmp/xiaoaimusic-voice-bridge.log
LOG_POLL_INTERVAL=${XIAOAI_LOG_POLL_INTERVAL:-1}
MODE=live
FIFO=
TAIL_PID=
PENDING_DIALOG=
PENDING_TEXT=
LAST_HANDLED_DIALOG=

log_message() {
    printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >>"$BRIDGE_LOG"
}

cleanup() {
    [ -n "$TAIL_PID" ] && kill "$TAIL_PID" 2>/dev/null || true
    [ -n "$FIFO" ] && rm -f "$FIFO"
}

trap cleanup EXIT INT TERM

json_line_value() {
    line=$1
    expression=$2
    jsonfilter -s "$line" -e "$expression" 2>/dev/null | head -n 1
}

stop_native_music() {
    "$ROOT/stop-native-music.sh" >/dev/null 2>&1 || true
}

aivs_filter_active() {
    for aivs_pid in $(pidof mico_aivs_lab 2>/dev/null); do
        grep -q 'libxiaoaimusic_aivs_filter.so' "/proc/$aivs_pid/maps" 2>/dev/null || continue
        tr '\000' '\n' <"/proc/$aivs_pid/environ" 2>/dev/null | \
            grep -q '^XIAOAI_FILTER_MODE=active$' && return 0
    done
    return 1
}

abort_native_dialog() {
    [ "$MODE" = live ] || return 0
    # The in-process AIVS filter consumes native music/TTS synchronously.  In
    # that mode restarting mico_aivs_lab would undo the filter and add latency.
    ! aivs_filter_active || return 0
    # Open-XiaoAI 在 OH2P 上采用同一方式中断原生回答；服务会在
    # 1-2 秒内自行恢复，米家和 librespot 不受影响。
    /etc/init.d/mico_aivs_lab restart >/dev/null 2>&1 || true
}

delayed_native_stop() {
    (
        sleep 1
        stop_native_music
        sleep 1
        stop_native_music
    ) &
}

run_api_action() {
    action=$1
    shift
    if [ "$MODE" = replay ]; then
        printf 'VOICE_ROUTE\t%s' "$action"
        for argument in "$@"; do
            printf '\t%s' "$argument"
        done
        printf '\n'
        return 0
    fi

    stop_native_music
    delayed_native_stop
    if result=$("$ROOT/spotify-web-api.sh" "$action" "$@" 2>&1); then
        log_message "OK action=$action query=$* result=$result"
        return 0
    fi
    log_message "FAILED action=$action query=$* error=$result"
    return 1
}

route_transport_if_needed() {
    dialog=$1
    text=$2
    case "$text" in
        同步点赞音乐|同步点赞歌曲|同步收藏音乐|同步收藏歌曲|刷新点赞音乐|刷新收藏音乐)
            run_api_action sync-liked
            LAST_HANDLED_DIALOG=$dialog
            ;;
        闭嘴|停止|暂停|暂停播放|暂停音乐|停止播放|停止音乐|关闭音乐|关掉音乐|把音乐关了|音乐关掉|别放了|不要播放了)
            run_api_action pause
            LAST_HANDLED_DIALOG=$dialog
            ;;
        继续|继续播放|继续音乐|恢复播放)
            run_api_action resume
            LAST_HANDLED_DIALOG=$dialog
            ;;
        下一首|下一曲|切歌)
            run_api_action next
            LAST_HANDLED_DIALOG=$dialog
            ;;
        上一首|上一曲)
            run_api_action previous
            LAST_HANDLED_DIALOG=$dialog
            ;;
        随机播放点赞音乐|随机播放点赞歌曲|随机播放收藏音乐|随机播放我喜欢的音乐)
            run_api_action play-liked-shuffle
            LAST_HANDLED_DIALOG=$dialog
            ;;
        随机播放|打开随机播放|开启随机播放)
            run_api_action shuffle on
            LAST_HANDLED_DIALOG=$dialog
            ;;
        关闭随机播放|不要随机播放)
            run_api_action shuffle off
            LAST_HANDLED_DIALOG=$dialog
            ;;
        单曲循环)
            run_api_action repeat track
            LAST_HANDLED_DIALOG=$dialog
            ;;
        列表循环|歌单循环)
            run_api_action repeat context
            LAST_HANDLED_DIALOG=$dialog
            ;;
        关闭循环|不要循环)
            run_api_action repeat off
            LAST_HANDLED_DIALOG=$dialog
            ;;
    esac
}

route_music_query() {
    text=$1
    item_type=auto
    query=

    case "$text" in
        随便播放*|随便放*|来一首*|来点歌*|来点音乐*|放点歌*|听点歌*|听点音乐*|推荐点歌*|推荐一些歌*)
            abort_native_dialog
            run_api_action play-for-me
            return $?
            ;;
    esac

    case "$text" in
        帮我播放*) query=${text#帮我播放} ;;
        请播放*) query=${text#请播放} ;;
        给我播放*) query=${text#给我播放} ;;
        播放一下*) query=${text#播放一下} ;;
        播放*) query=${text#播放} ;;
        放一下*) query=${text#放一下} ;;
        放*) query=${text#放} ;;
        *) return 2 ;;
    esac

    query=$(printf '%s' "$query" | sed 's/^[[:space:]]*//;s/[[:space:]，。！？!?]*$//')
    case "$query" in
        Spotify*) query=${query#Spotify} ;;
        spotify*) query=${query#spotify} ;;
        声破天*) query=${query#声破天} ;;
    esac
    query=$(printf '%s' "$query" | sed 's/^[[:space:]]*//')

    case "$query" in
        点赞音乐|点赞歌曲|点赞的音乐|点赞的歌曲|一点赞音乐|一点赞的音乐|我点赞的音乐|我点赞的歌曲|收藏音乐|收藏歌曲|收藏的音乐|收藏的歌曲|我喜欢的音乐|我喜欢的歌曲|喜欢的歌|我的收藏|我的音乐)
            abort_native_dialog
            run_api_action play-liked
            return $?
            ;;
    esac

    case "$query" in
        我的歌单*) item_type=my-playlist; query=${query#我的歌单} ;;
        歌单*) item_type=playlist; query=${query#歌单} ;;
        专辑*) item_type=album; query=${query#专辑} ;;
        歌手*) item_type=artist; query=${query#歌手} ;;
        艺人*) item_type=artist; query=${query#艺人} ;;
        歌曲*) item_type=track; query=${query#歌曲} ;;
        一首*) item_type=track; query=${query#一首} ;;
        *的歌) item_type=artist; query=${query%的歌} ;;
    esac
    query=$(printf '%s' "$query" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    # 明确的音乐命令无需等待原生 QQ 音乐 Play 指令；最终 ASR 一到
    # 就中断当前云端回答，避免会员 TTS/试听版先抢占扬声器。
    abort_native_dialog

    case "$query" in
        ''|音乐|歌曲)
            run_api_action play-for-me
            ;;
        *)
            if [ "$item_type" = auto ]; then
                run_api_action play-auto "$query"
            elif [ "$item_type" = my-playlist ]; then
                run_api_action play-my-playlist "$query"
            else
                run_api_action play "$item_type" "$query"
            fi
            ;;
    esac
}

process_instruction() {
    line=$1
    namespace=$(json_line_value "$line" '@.header.namespace')
    name=$(json_line_value "$line" '@.header.name')
    dialog=$(json_line_value "$line" '@.header.dialog_id')
    [ -n "$namespace" ] || return 0

    if [ "$namespace" = SpeechRecognizer ] && [ "$name" = RecognizeResult ]; then
        is_final=$(json_line_value "$line" '@.payload.is_final')
        [ "$is_final" = true ] || return 0
        text=$(json_line_value "$line" '@.payload.results[0].origin_text')
        [ -n "$text" ] || text=$(json_line_value "$line" '@.payload.results[0].text')
        [ -n "$text" ] || return 0
        PENDING_DIALOG=$dialog
        PENDING_TEXT=$text
        log_message "ASR dialog=$dialog text=$text"
        route_transport_if_needed "$dialog" "$text"
        [ "$dialog" = "$LAST_HANDLED_DIALOG" ] && return 0
        route_music_query "$text"
        music_status=$?
        if [ "$music_status" -ne 2 ]; then
            LAST_HANDLED_DIALOG=$dialog
            log_message "MUSIC_INTENT_EARLY dialog=$dialog text=$text status=$music_status"
        fi
        return 0
    fi

    if [ "$namespace" = SpeechSynthesizer ] && [ "$name" = Speak ]; then
        [ -n "$dialog" ] && [ "$dialog" = "$LAST_HANDLED_DIALOG" ] || return 0
        log_message "SUPPRESS_NATIVE_TTS dialog=$dialog"
        abort_native_dialog
        stop_native_music
        return 0
    fi

    if [ "$namespace" = AudioPlayer ] && [ "$name" = Play ]; then
        audio_type=$(json_line_value "$line" '@.payload.audio_type')
        [ "$audio_type" = MUSIC ] || return 0
        # 原生云端已经最终判定为音乐。无论前面的中文词典是否认识，
        # 都先阻止小米音源，再将同轮文本回补给 Spotify。
        stop_native_music
        if [ -n "$dialog" ] && [ "$dialog" = "$LAST_HANDLED_DIALOG" ]; then
            log_message "SUPPRESS_NATIVE_MUSIC dialog=$dialog"
            return 0
        fi
        LAST_HANDLED_DIALOG=$dialog
        if [ -n "$dialog" ] && [ "$dialog" = "$PENDING_DIALOG" ] && [ -n "$PENDING_TEXT" ]; then
            music_text=$PENDING_TEXT
        else
            music_text=
        fi
        log_message "MUSIC_INTENT_CONFIRMED dialog=$dialog text=$music_text"
        if [ -n "$music_text" ]; then
            route_music_query "$music_text"
        else
            abort_native_dialog
            run_api_action play-for-me
        fi
        music_status=$?
        if [ "$music_status" -ne 0 ]; then
            log_message "MUSIC_ROUTE_FALLBACK dialog=$dialog text=$music_text status=$music_status"
            abort_native_dialog
            run_api_action play-for-me || \
                log_message "MUSIC_ROUTE_FAILED dialog=$dialog text=$music_text"
        fi
    fi
}

process_stream() {
    while IFS= read -r line; do
        process_instruction "$line"
    done
}

case "${1:-}" in
    --replay)
        [ "$#" -eq 2 ] || {
            printf '%s\n' '用法：voice-bridge.sh --replay instruction.log' >&2
            exit 2
        }
        MODE=replay
        process_stream <"$2"
        ;;
    '')
        command -v jsonfilter >/dev/null 2>&1 || {
            printf '%s\n' '缺少 jsonfilter' >&2
            exit 2
        }
        FIFO=/tmp/xiaoaimusic-voice-bridge.$$.fifo
        rm -f "$FIFO"
        mkfifo "$FIFO"
        if [ -x "$ROOT/bin/xiaoaimusic-log-follower" ]; then
            "$ROOT/bin/xiaoaimusic-log-follower" "$INSTRUCTION_LOG" >"$FIFO" 2>>"$BRIDGE_LOG" &
        else
            tail -n 0 -F -s "$LOG_POLL_INTERVAL" "$INSTRUCTION_LOG" >"$FIFO" 2>>"$BRIDGE_LOG" &
        fi
        TAIL_PID=$!
        log_message "START instruction_log=$INSTRUCTION_LOG"
        process_stream <"$FIFO"
        ;;
    *)
        printf '%s\n' '用法：voice-bridge.sh [--replay instruction.log]' >&2
        exit 2
        ;;
esac
