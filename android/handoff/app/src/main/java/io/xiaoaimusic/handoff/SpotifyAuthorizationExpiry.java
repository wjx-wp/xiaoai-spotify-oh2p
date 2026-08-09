package io.xiaoaimusic.handoff;

final class SpotifyAuthorizationExpiry {
    static final long DAY_MS = 86_400_000L;
    static final long VALIDITY_MS = 180L * DAY_MS;
    static final long NOTICE_WINDOW_MS = 30L * DAY_MS;
    static final long REMINDER_INTERVAL_MS = 7L * DAY_MS;

    private SpotifyAuthorizationExpiry() {}

    static long estimatedExpiryAtMs(long authorizedAtMs) {
        if (authorizedAtMs <= 0L || authorizedAtMs > Long.MAX_VALUE - VALIDITY_MS) return 0L;
        return authorizedAtMs + VALIDITY_MS;
    }

    static long remainingDays(long authorizedAtMs, long nowMs) {
        long expiryAtMs = estimatedExpiryAtMs(authorizedAtMs);
        if (expiryAtMs == 0L || nowMs <= 0L) return -1L;
        if (nowMs >= expiryAtMs) return 0L;
        long remainingMs = expiryAtMs - nowMs;
        return 1L + ((remainingMs - 1L) / DAY_MS);
    }

    static boolean isExpired(long authorizedAtMs, long nowMs) {
        long expiryAtMs = estimatedExpiryAtMs(authorizedAtMs);
        return expiryAtMs != 0L && nowMs >= expiryAtMs;
    }

    static boolean shouldNotify(
            long authorizedAtMs,
            long lastNotifiedForAuthorizedAtMs,
            long lastNotifiedAtMs,
            long nowMs) {
        long expiryAtMs = estimatedExpiryAtMs(authorizedAtMs);
        if (expiryAtMs == 0L || nowMs <= 0L) return false;
        if (nowMs < expiryAtMs - NOTICE_WINDOW_MS) return false;
        if (lastNotifiedForAuthorizedAtMs != authorizedAtMs || lastNotifiedAtMs <= 0L) {
            return true;
        }
        if (nowMs < lastNotifiedAtMs) return false;
        return nowMs - lastNotifiedAtMs >= REMINDER_INTERVAL_MS;
    }
}
