package io.xiaoaimusic.handoff;

import static org.junit.Assert.assertTrue;

import org.junit.Test;

public final class OAuthCallbackServerTest {
    @Test
    public void browserAuthorizationWindowFitsInsideShortServiceLimit() {
        assertTrue(OAuthCallbackServer.TOTAL_TIMEOUT_MS >= 120_000L);
        assertTrue(OAuthCallbackServer.TOTAL_TIMEOUT_MS < 180_000L);
    }
}
