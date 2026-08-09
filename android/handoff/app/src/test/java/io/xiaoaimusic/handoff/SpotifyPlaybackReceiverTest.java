package io.xiaoaimusic.handoff;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public final class SpotifyPlaybackReceiverTest {
    private static final long NOW_MS = 1_800_000_000_000L;

    @Test
    public void acceptsCurrentAndBoundaryTimestamps() {
        assertTrue(SpotifyPlaybackReceiver.isFresh(NOW_MS, NOW_MS));
        assertTrue(SpotifyPlaybackReceiver.isFresh(NOW_MS - 30_000L, NOW_MS));
        assertTrue(SpotifyPlaybackReceiver.isFresh(NOW_MS + 5_000L, NOW_MS));
    }

    @Test
    public void rejectsMissingStaleAndExcessivelyFutureTimestamps() {
        assertFalse(SpotifyPlaybackReceiver.isFresh(0L, NOW_MS));
        assertFalse(SpotifyPlaybackReceiver.isFresh(-1L, NOW_MS));
        assertFalse(SpotifyPlaybackReceiver.isFresh(NOW_MS - 30_001L, NOW_MS));
        assertFalse(SpotifyPlaybackReceiver.isFresh(NOW_MS + 5_001L, NOW_MS));
        assertFalse(SpotifyPlaybackReceiver.isFresh(1L, Long.MAX_VALUE));
    }
}
