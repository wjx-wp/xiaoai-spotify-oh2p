#!/bin/sh

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# The stock touchpad daemon still receives the key event.  Stop any native
# qplayer stream before and shortly after toggling Spotify so both players can
# never remain audible after a physical-button press.
"$ROOT/stop-native-music.sh" >/dev/null 2>&1 || true
"$ROOT/spotify-web-api.sh" toggle
(
    for delay in 0.05 0.10 0.20 0.40 0.80; do
        sleep "$delay"
        "$ROOT/stop-native-music.sh" >/dev/null 2>&1 || true
    done
) &
