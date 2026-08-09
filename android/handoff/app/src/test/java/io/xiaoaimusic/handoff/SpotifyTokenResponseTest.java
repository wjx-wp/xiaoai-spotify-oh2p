package io.xiaoaimusic.handoff;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertThrows;
import static org.junit.Assert.assertTrue;

import java.nio.charset.StandardCharsets;
import org.junit.Test;

public final class SpotifyTokenResponseTest {
    private static final long NOW = 1_800_000_000_000L;
    private static final String ACCESS = "A".repeat(64);
    private static final String REFRESH = "R".repeat(64);

    @Test
    public void parsesOneStrictResponseAndBindsProvenance() throws Exception {
        byte[] response = validJson("Bearer", 3600, AppConfig.SPOTIFY_SCOPES);
        try (SpotifyTokenExchange.Authorization authorization =
                     SpotifyTokenExchange.parseAuthorizationResponse(response, NOW)) {
            assertArrayEquals(ACCESS.toCharArray(), authorization.accessToken());
            assertArrayEquals(REFRESH.toCharArray(), authorization.refreshToken());
            assertEquals(NOW, authorization.authorizedAtMs());
            assertEquals(NOW + 3_600_000L, authorization.accessExpiresAtMs());
            assertEquals(32, authorization.provenance().length);
        }
    }

    @Test
    public void acceptsOAuthBearerCaseInsensitively() throws Exception {
        try (SpotifyTokenExchange.Authorization ignored =
                     SpotifyTokenExchange.parseAuthorizationResponse(
                             validJson("bearer", 3600, AppConfig.SPOTIFY_SCOPES), NOW)) {
            assertTrue(true);
        }
    }

    @Test
    public void requiresEveryReturnedScope() {
        String missingOne = AppConfig.SPOTIFY_SCOPES
                .replace(" playlist-modify-private", "");
        assertThrows(SecurityException.class,
                () -> SpotifyTokenExchange.parseAuthorizationResponse(
                        validJson("Bearer", 3600, missingOne), NOW));
    }

    @Test
    public void rejectsDuplicateOrMalformedScopes() {
        assertThrows(SecurityException.class,
                () -> SpotifyTokenExchange.parseAuthorizationResponse(
                        validJson("Bearer", 3600,
                                AppConfig.SPOTIFY_SCOPES + " user-read-playback-state"), NOW));
        assertThrows(SecurityException.class,
                () -> SpotifyTokenExchange.parseAuthorizationResponse(
                        validJson("Bearer", 3600,
                                AppConfig.SPOTIFY_SCOPES.replace(" ", "  ")), NOW));
    }

    @Test
    public void rejectsWrongTypeAndNonIntegralOrUnreasonableExpiry() {
        assertThrows(SecurityException.class,
                () -> SpotifyTokenExchange.parseAuthorizationResponse(
                        validJson("MAC", 3600, AppConfig.SPOTIFY_SCOPES), NOW));
        String fractional = new String(validJson("Bearer", 3600, AppConfig.SPOTIFY_SCOPES),
                StandardCharsets.UTF_8).replace("\"expires_in\":3600", "\"expires_in\":3600.5");
        assertThrows(SecurityException.class,
                () -> SpotifyTokenExchange.parseAuthorizationResponse(
                        fractional.getBytes(StandardCharsets.UTF_8), NOW));
        assertThrows(SecurityException.class,
                () -> SpotifyTokenExchange.parseAuthorizationResponse(
                        validJson("Bearer", 59, AppConfig.SPOTIFY_SCOPES), NOW));
        assertThrows(SecurityException.class,
                () -> SpotifyTokenExchange.parseAuthorizationResponse(
                        validJson("Bearer", 86_401, AppConfig.SPOTIFY_SCOPES), NOW));
    }

    @Test
    public void rejectsMissingOrMalformedTokens() {
        String valid = new String(validJson("Bearer", 3600, AppConfig.SPOTIFY_SCOPES),
                StandardCharsets.UTF_8);
        assertThrows(SecurityException.class,
                () -> SpotifyTokenExchange.parseAuthorizationResponse(
                        valid.replace(ACCESS, "short").getBytes(StandardCharsets.UTF_8), NOW));
        assertThrows(SecurityException.class,
                () -> SpotifyTokenExchange.parseAuthorizationResponse(
                        valid.replace(REFRESH, "R".repeat(31) + " ")
                                .getBytes(StandardCharsets.UTF_8), NOW));
        assertThrows(SecurityException.class,
                () -> SpotifyTokenExchange.parseAuthorizationResponse(
                        valid.replace("\"refresh_token\":\"" + REFRESH + "\",", "")
                                .getBytes(StandardCharsets.UTF_8), NOW));
    }

    @Test
    public void closeWipesMutableTokenMaterial() throws Exception {
        SpotifyTokenExchange.Authorization authorization =
                SpotifyTokenExchange.parseAuthorizationResponse(
                        validJson("Bearer", 3600, AppConfig.SPOTIFY_SCOPES), NOW);
        char[] access = authorization.accessToken();
        char[] refresh = authorization.refreshToken();
        byte[] provenance = authorization.provenance();
        authorization.close();
        assertArrayEquals(new char[access.length], access);
        assertArrayEquals(new char[refresh.length], refresh);
        assertArrayEquals(new byte[provenance.length], provenance);
    }

    private static byte[] validJson(String type, long expiresIn, String scopes) {
        return ("{\"access_token\":\"" + ACCESS
                + "\",\"refresh_token\":\"" + REFRESH
                + "\",\"token_type\":\"" + type
                + "\",\"expires_in\":" + expiresIn
                + ",\"scope\":\"" + scopes + "\"}")
                .getBytes(StandardCharsets.UTF_8);
    }
}
