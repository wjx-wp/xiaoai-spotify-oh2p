package io.xiaoaimusic.handoff;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Build;

final class SpotifyPlaybackReceiver extends BroadcastReceiver {
    private static final long MAX_EVENT_AGE_MS = 30_000L;
    private static final long MAX_FUTURE_SKEW_MS = 5_000L;

    @Override
    public void onReceive(Context context, Intent intent) {
        if (!AppConfig.SPOTIFY_PLAYBACK_ACTION.equals(intent.getAction())) return;
        if (!isTrustedSender()) return;
        if (!isFresh(intent.getLongExtra("timeSent", 0L), System.currentTimeMillis())) return;
        SpotifyAuthorizationReminder.maybeNotify(context);
        if (!new AppPreferences(context).isAutoEnabled()) return;
        if (!intent.getBooleanExtra("playing", false)) return;
        TakeoverOrchestrator.sendPlaybackStartedSequence(context);
    }

    private boolean isTrustedSender() {
        // Older Android versions cannot attribute an exported dynamic broadcast reliably.
        if (Build.VERSION.SDK_INT < 34) return false;
        return AppConfig.SPOTIFY_PACKAGE.equals(getSentFromPackage());
    }

    static boolean isFresh(long sentAtMs, long nowMs) {
        if (sentAtMs <= 0L) return false;
        long age = nowMs - sentAtMs;
        return age >= -MAX_FUTURE_SKEW_MS && age <= MAX_EVENT_AGE_MS;
    }
}
