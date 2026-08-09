#!/bin/sh

# 只停止原生媒体播放，不停止 mibrain、米家控制、闹钟或 TTS 服务。
ubus call mediaplayer media_control \
    '{"player":"mediaplayer","action":"pause","volume":0}' >/dev/null 2>&1 || true
ubus call mediaplayer player_play_operation \
    '{"media":"app_ios","action":"stop"}' >/dev/null 2>&1 || true
