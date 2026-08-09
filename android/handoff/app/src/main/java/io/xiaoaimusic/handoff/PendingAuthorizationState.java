package io.xiaoaimusic.handoff;

enum PendingAuthorizationState {
    NONE,
    NEEDS_VERIFICATION,
    VERIFIED_READY,
    ACCESS_EXPIRED,
    AUTHORIZATION_EXPIRED,
    INVALID;

    private static final long MAX_FUTURE_SKEW_MS = 5L * 60L * 1_000L;
    private static final long ACCESS_EXPIRY_SAFETY_MS = 30L * 1_000L;
    private static final long AUTHORIZATION_VALIDITY_MS = 180L * 24L * 60L * 60L * 1_000L;

    static PendingAuthorizationState evaluate(
            boolean present,
            boolean verified,
            long authorizedAtMs,
            long accessExpiresAtMs,
            long nowMs) {
        if (!present) return NONE;
        if (nowMs <= 0L
                || authorizedAtMs < 1_000_000_000_000L
                || authorizedAtMs > nowMs + MAX_FUTURE_SKEW_MS) {
            return INVALID;
        }
        if (nowMs >= authorizedAtMs + AUTHORIZATION_VALIDITY_MS) {
            return AUTHORIZATION_EXPIRED;
        }
        // Once Spotify has verified this exact token response, the short-lived access token is
        // no longer used. An SSH outage must not invalidate an already-established provenance.
        if (verified) return VERIFIED_READY;
        if (accessExpiresAtMs <= authorizedAtMs) return INVALID;
        if (nowMs >= accessExpiresAtMs - ACCESS_EXPIRY_SAFETY_MS) {
            return ACCESS_EXPIRED;
        }
        return NEEDS_VERIFICATION;
    }
}
