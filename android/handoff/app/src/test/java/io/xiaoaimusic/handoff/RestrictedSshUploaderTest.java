package io.xiaoaimusic.handoff;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertThrows;
import static org.junit.Assert.assertTrue;

import java.nio.charset.StandardCharsets;
import org.junit.Test;

public final class RestrictedSshUploaderTest {
    @Test
    public void buildsExactFourLineProtocolEndingAtEof() {
        String token = "R".repeat(32);
        assertEquals(
                "XIAOAIMUSIC_AUTH_V1\n1700000000000\n" + token + "\nEND\n",
                new String(RestrictedSshUploader.buildPayload(
                        token, 1_700_000_000_000L), StandardCharsets.US_ASCII));
    }

    @Test
    public void rejectsInvalidTimestampAndLineBreakingToken() {
        assertThrows(SecurityException.class,
                () -> RestrictedSshUploader.buildPayload("R".repeat(32), 123L));
        assertThrows(SecurityException.class,
                () -> RestrictedSshUploader.buildPayload("R".repeat(31) + "\n", 1_700_000_000_000L));
    }

    @Test
    public void acceptsOnlyExactSuccessfulAuthorizationStatus() throws Exception {
        assertEquals(1_700_000_000_000L,
                RestrictedSshUploader.parseAuthorizedAtStatus(
                        0, "OK auth_status 1700000000000"));
        assertThrows(java.io.IOException.class,
                () -> RestrictedSshUploader.parseAuthorizedAtStatus(
                        1, "OK auth_status 1700000000000"));
        assertThrows(java.io.IOException.class,
                () -> RestrictedSshUploader.parseAuthorizedAtStatus(
                        0, "OK auth_status 1700000000000 extra"));
    }

    @Test
    public void unavailableInitialStatusIsAdvisory() throws Exception {
        assertTrue(RestrictedSshUploader.authorizationStatusMatches(
                () -> 1_700_000_000_000L, 1_700_000_000_000L));
        assertFalse(RestrictedSshUploader.authorizationStatusMatches(
                () -> 1_699_999_999_999L, 1_700_000_000_000L));
        assertFalse(RestrictedSshUploader.authorizationStatusMatches(
                () -> { throw new java.io.IOException("status unsupported"); },
                1_700_000_000_000L));
    }

    @Test
    public void statusInterruptionIsNeverTreatedAsAdvisory() {
        try {
            assertThrows(InterruptedException.class,
                    () -> RestrictedSshUploader.authorizationStatusMatches(
                            () -> { throw new InterruptedException("cancelled"); },
                            1_700_000_000_000L));
            assertTrue(Thread.currentThread().isInterrupted());
        } finally {
            Thread.interrupted();
        }
    }
}
