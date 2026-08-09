package io.xiaoaimusic.handoff;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public final class SpotifyAuthorizationExpiryTest {
    private static final long AUTHORIZED_AT = 1_700_000_000_000L;

    @Test
    public void estimatesExpiryAtExactlyOneHundredEightyDays() {
        assertEquals(
                AUTHORIZED_AT + 180L * SpotifyAuthorizationExpiry.DAY_MS,
                SpotifyAuthorizationExpiry.estimatedExpiryAtMs(AUTHORIZED_AT));
        assertEquals(180L,
                SpotifyAuthorizationExpiry.remainingDays(AUTHORIZED_AT, AUTHORIZED_AT));
        assertEquals(1L, SpotifyAuthorizationExpiry.remainingDays(
                AUTHORIZED_AT,
                SpotifyAuthorizationExpiry.estimatedExpiryAtMs(AUTHORIZED_AT) - 1L));
        assertEquals(0L, SpotifyAuthorizationExpiry.remainingDays(
                AUTHORIZED_AT,
                SpotifyAuthorizationExpiry.estimatedExpiryAtMs(AUTHORIZED_AT)));
    }

    @Test
    public void startsReminderAtThirtyDayBoundary() {
        long expiryAt = SpotifyAuthorizationExpiry.estimatedExpiryAtMs(AUTHORIZED_AT);
        assertFalse(SpotifyAuthorizationExpiry.shouldNotify(
                AUTHORIZED_AT, 0L, 0L,
                expiryAt - SpotifyAuthorizationExpiry.NOTICE_WINDOW_MS - 1L));
        assertTrue(SpotifyAuthorizationExpiry.shouldNotify(
                AUTHORIZED_AT, 0L, 0L,
                expiryAt - SpotifyAuthorizationExpiry.NOTICE_WINDOW_MS));
    }

    @Test
    public void continuesToRemindAfterEstimatedExpiry() {
        long afterExpiry = SpotifyAuthorizationExpiry.estimatedExpiryAtMs(AUTHORIZED_AT) + 1L;
        assertTrue(SpotifyAuthorizationExpiry.isExpired(AUTHORIZED_AT, afterExpiry));
        assertEquals(0L,
                SpotifyAuthorizationExpiry.remainingDays(AUTHORIZED_AT, afterExpiry));
        assertTrue(SpotifyAuthorizationExpiry.shouldNotify(
                AUTHORIZED_AT, 0L, 0L, afterExpiry));
    }

    @Test
    public void throttlesSameAuthorizationForSevenDays() {
        long now = SpotifyAuthorizationExpiry.estimatedExpiryAtMs(AUTHORIZED_AT)
                - SpotifyAuthorizationExpiry.NOTICE_WINDOW_MS;
        assertFalse(SpotifyAuthorizationExpiry.shouldNotify(
                AUTHORIZED_AT, AUTHORIZED_AT, now, now + 7L * SpotifyAuthorizationExpiry.DAY_MS - 1L));
        assertTrue(SpotifyAuthorizationExpiry.shouldNotify(
                AUTHORIZED_AT, AUTHORIZED_AT, now, now + 7L * SpotifyAuthorizationExpiry.DAY_MS));
        assertFalse(SpotifyAuthorizationExpiry.shouldNotify(
                AUTHORIZED_AT, AUTHORIZED_AT, now, now - 1L));
    }

    @Test
    public void newAuthorizationNaturallyMovesOutsideReminderWindow() {
        long oldExpiry = SpotifyAuthorizationExpiry.estimatedExpiryAtMs(AUTHORIZED_AT);
        long now = oldExpiry - SpotifyAuthorizationExpiry.DAY_MS;
        assertTrue(SpotifyAuthorizationExpiry.shouldNotify(
                AUTHORIZED_AT, AUTHORIZED_AT, now - SpotifyAuthorizationExpiry.REMINDER_INTERVAL_MS,
                now));
        assertFalse(SpotifyAuthorizationExpiry.shouldNotify(
                now, AUTHORIZED_AT, now, now));
    }

    @Test
    public void rejectsMissingOrOverflowingAuthorizationTime() {
        assertEquals(0L, SpotifyAuthorizationExpiry.estimatedExpiryAtMs(0L));
        assertEquals(0L, SpotifyAuthorizationExpiry.estimatedExpiryAtMs(Long.MAX_VALUE));
        assertEquals(-1L, SpotifyAuthorizationExpiry.remainingDays(0L, AUTHORIZED_AT));
        assertFalse(SpotifyAuthorizationExpiry.shouldNotify(0L, 0L, 0L, AUTHORIZED_AT));
        assertFalse(SpotifyAuthorizationExpiry.shouldNotify(
                AUTHORIZED_AT + SpotifyAuthorizationExpiry.DAY_MS,
                0L,
                0L,
                AUTHORIZED_AT));
    }
}
