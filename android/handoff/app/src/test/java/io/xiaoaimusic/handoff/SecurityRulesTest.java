package io.xiaoaimusic.handoff;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public final class SecurityRulesTest {
    @Test
    public void refreshTokenAcceptsOnlyBoundedVisibleAsciiWithoutWhitespace() {
        assertTrue(SecurityRules.isValidRefreshToken("!".repeat(32)));
        assertTrue(SecurityRules.isValidRefreshToken("~".repeat(4096)));
        assertTrue(SecurityRules.isValidRefreshToken("A1-z_./~".repeat(4)));

        assertFalse(SecurityRules.isValidRefreshToken(null));
        assertFalse(SecurityRules.isValidRefreshToken("x".repeat(31)));
        assertFalse(SecurityRules.isValidRefreshToken("x".repeat(4097)));
        assertFalse(SecurityRules.isValidRefreshToken("x".repeat(31) + " "));
        assertFalse(SecurityRules.isValidRefreshToken("x".repeat(31) + "\r"));
        assertFalse(SecurityRules.isValidRefreshToken("x".repeat(31) + "\n"));
        assertFalse(SecurityRules.isValidRefreshToken("x".repeat(31) + "中"));
    }

    @Test
    public void sha256FingerprintUsesOpenSshFormatWithoutBase64Padding() {
        assertEquals(
                "SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU",
                SecurityRules.sha256Fingerprint(new byte[0]));
        assertFalse(SecurityRules.sha256Fingerprint(new byte[] {1, 2, 3}).endsWith("="));
    }

    @Test
    public void constantTimeEqualsExposesTheExpectedEqualityResult() {
        assertTrue(SecurityRules.constantTimeEquals("same secret", "same secret"));
        assertTrue(SecurityRules.constantTimeEquals("周杰伦", "周杰伦"));
        assertFalse(SecurityRules.constantTimeEquals("same secret", "same secreu"));
        assertFalse(SecurityRules.constantTimeEquals("short", "a different length"));
        assertFalse(SecurityRules.constantTimeEquals(null, "value"));
        assertFalse(SecurityRules.constantTimeEquals("value", null));
        assertFalse(SecurityRules.constantTimeEquals(null, null));
    }
}
