package io.xiaoaimusic.handoff;

import static org.junit.Assert.assertEquals;

import org.junit.Test;

public final class PendingAuthorizationStateTest {
    private static final long NOW = 1_800_000_000_000L;
    private static final long HOUR = 3_600_000L;

    @Test
    public void noBundleIsNone() {
        assertEquals(PendingAuthorizationState.NONE,
                PendingAuthorizationState.evaluate(false, false, 0L, 0L, NOW));
    }

    @Test
    public void freshUnverifiedBundleNeedsVerification() {
        assertEquals(PendingAuthorizationState.NEEDS_VERIFICATION,
                PendingAuthorizationState.evaluate(
                        true, false, NOW, NOW + HOUR, NOW + 1_000L));
    }

    @Test
    public void unverifiedBundleRequiresBrowserAgainWhenAccessExpires() {
        assertEquals(PendingAuthorizationState.ACCESS_EXPIRED,
                PendingAuthorizationState.evaluate(
                        true, false, NOW, NOW + HOUR, NOW + HOUR));
    }

    @Test
    public void verifiedBundleSurvivesAccessExpiryAndSshOutage() {
        assertEquals(PendingAuthorizationState.VERIFIED_READY,
                PendingAuthorizationState.evaluate(
                        true, true, NOW, NOW + HOUR, NOW + 24L * HOUR));
    }

    @Test
    public void evenVerifiedBundleExpiresAtAuthorizationBoundary() {
        long after180Days = NOW + 180L * 24L * HOUR;
        assertEquals(PendingAuthorizationState.AUTHORIZATION_EXPIRED,
                PendingAuthorizationState.evaluate(
                        true, true, NOW, NOW + HOUR, after180Days));
    }

    @Test
    public void impossibleTimesFailClosed() {
        assertEquals(PendingAuthorizationState.INVALID,
                PendingAuthorizationState.evaluate(
                        true, false, NOW + 10L * 60L * 1_000L,
                        NOW + HOUR, NOW));
        assertEquals(PendingAuthorizationState.INVALID,
                PendingAuthorizationState.evaluate(
                        true, false, NOW, NOW, NOW));
    }
}
