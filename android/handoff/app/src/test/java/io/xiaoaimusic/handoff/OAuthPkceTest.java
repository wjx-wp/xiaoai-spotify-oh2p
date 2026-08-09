package io.xiaoaimusic.handoff;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import org.junit.Test;

public final class OAuthPkceTest {
    @Test
    public void generatesIndependentRfc7636Values() throws Exception {
        OAuthPkce.Values first = OAuthPkce.generate();
        OAuthPkce.Values second = OAuthPkce.generate();
        assertTrue(first.verifier().length() >= 43 && first.verifier().length() <= 128);
        assertFalse(first.verifier().contains("="));
        assertFalse(first.state().equals(second.state()));
        assertEquals(
                OAuthPkce.base64Url(MessageDigest.getInstance("SHA-256")
                        .digest(first.verifier().getBytes(StandardCharsets.US_ASCII))),
                first.challenge());
    }
}
