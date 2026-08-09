package io.xiaoaimusic.handoff;

import android.accessibilityservice.AccessibilityService;
import android.os.SystemClock;
import android.view.accessibility.AccessibilityEvent;

public final class SpotifyAccessibilityService extends AccessibilityService {
    private static final long DEBOUNCE_MS = 2_500L;
    private long lastRequestAt;

    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {
        if (event == null
                || event.getEventType() != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED
                || event.getPackageName() == null
                || !AppConfig.SPOTIFY_PACKAGE.contentEquals(event.getPackageName())) {
            return;
        }
        SpotifyAuthorizationReminder.maybeNotify(this);
        if (!new AppPreferences(this).isAutoEnabled()) return;
        long now = SystemClock.elapsedRealtime();
        if (now - lastRequestAt < DEBOUNCE_MS) return;
        lastRequestAt = now;
        TakeoverOrchestrator.sendAutomaticNow(this, "Spotify 打开预接管");
    }

    @Override
    public void onInterrupt() {
        // No continuous gesture or content operation exists to interrupt.
    }
}
