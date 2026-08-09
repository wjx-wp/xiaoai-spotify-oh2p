package io.xiaoaimusic.handoff;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public final class OAuthCallbackParserTest {
    @Test
    public void acceptsExactLoopbackCallbackAndMatchingState() {
        OAuthCallbackParser.Result result = OAuthCallbackParser.parse(
                "GET /callback?code=abc-123&state=expected HTTP/1.1\r\n"
                        + "Host: 127.0.0.1:43827\r\n\r\n",
                "expected");
        assertTrue(result.isSuccess());
        assertEquals("abc-123", result.code());
    }

    @Test
    public void rejectsStateMismatchDuplicateHostAndAbsoluteTargets() {
        assertFalse(OAuthCallbackParser.parse(
                "GET /callback?code=a&state=wrong HTTP/1.1\r\n"
                        + "Host: 127.0.0.1:43827\r\n\r\n", "expected").isSuccess());
        assertFalse(OAuthCallbackParser.parse(
                "GET /callback?code=a&state=expected HTTP/1.1\r\n"
                        + "Host: invalid\r\nHost: 127.0.0.1:43827\r\n\r\n",
                "expected").isSuccess());
        assertFalse(OAuthCallbackParser.parse(
                "GET http://127.0.0.1:43827/callback?code=a&state=expected HTTP/1.1\r\n"
                        + "Host: 127.0.0.1:43827\r\n\r\n",
                "expected").isSuccess());
    }
}
