#!/bin/sh

# Merge only after foreground coexistence tests pass.

/data/xiaoaimusic/mount-mobile-auth.sh >/tmp/xiaoaimusic-init.log 2>&1
/data/xiaoaimusic/activate-native-filters.sh >>/tmp/xiaoaimusic-init.log 2>&1
/data/xiaoaimusic/run-librespot.sh >>/tmp/xiaoaimusic-init.log 2>&1 &
/data/xiaoaimusic/run-voice-bridge.sh >>/tmp/xiaoaimusic-init.log 2>&1 &
/data/xiaoaimusic/run-keybridge.sh >>/tmp/xiaoaimusic-init.log 2>&1 &
/data/xiaoaimusic/supervise-liked-sync.sh >>/tmp/xiaoaimusic-liked-sync.log 2>&1 &
