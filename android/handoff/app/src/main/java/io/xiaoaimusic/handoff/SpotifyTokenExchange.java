package io.xiaoaimusic.handoff;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;

import javax.net.ssl.HttpsURLConnection;

final class SpotifyTokenExchange {
    static final long MIN_EXPIRES_IN_SECONDS = 60L;
    static final long MAX_EXPIRES_IN_SECONDS = 86_400L;

    static final class Authorization implements AutoCloseable {
        private final char[] refreshToken;
        private final char[] accessToken;
        private final long authorizedAtMs;
        private final long accessExpiresAtMs;
        private final byte[] provenance;

        Authorization(
                char[] refreshToken,
                char[] accessToken,
                long authorizedAtMs,
                long accessExpiresAtMs,
                byte[] provenance) {
            this.refreshToken = refreshToken;
            this.accessToken = accessToken;
            this.authorizedAtMs = authorizedAtMs;
            this.accessExpiresAtMs = accessExpiresAtMs;
            this.provenance = provenance;
        }

        char[] refreshToken() { return refreshToken; }
        char[] accessToken() { return accessToken; }
        long authorizedAtMs() { return authorizedAtMs; }
        long accessExpiresAtMs() { return accessExpiresAtMs; }
        byte[] provenance() { return provenance; }

        @Override
        public void close() {
            Arrays.fill(refreshToken, '\0');
            Arrays.fill(accessToken, '\0');
            Arrays.fill(provenance, (byte) 0);
        }
    }

    static Authorization exchange(String code, String verifier) throws Exception {
        if (code == null || code.isEmpty() || code.length() > 4_096) {
            throw new SecurityException("Spotify authorization code is invalid");
        }
        if (verifier == null || verifier.length() < 43 || verifier.length() > 128) {
            throw new SecurityException("PKCE verifier is invalid");
        }
        String body = form("client_id", AppConfig.SPOTIFY_CLIENT_ID)
                + "&" + form("grant_type", "authorization_code")
                + "&" + form("code", code)
                + "&" + form("redirect_uri", AppConfig.SPOTIFY_REDIRECT_URI)
                + "&" + form("code_verifier", verifier);
        byte[] bodyBytes = body.getBytes(StandardCharsets.UTF_8);

        HttpsURLConnection connection = (HttpsURLConnection)
                new URL(AppConfig.SPOTIFY_TOKEN_URL).openConnection();
        byte[] responseBytes = null;
        try {
            connection.setRequestMethod("POST");
            connection.setConnectTimeout(15_000);
            connection.setReadTimeout(15_000);
            connection.setInstanceFollowRedirects(false);
            connection.setDoOutput(true);
            connection.setFixedLengthStreamingMode(bodyBytes.length);
            connection.setRequestProperty("Content-Type", "application/x-www-form-urlencoded");
            connection.setRequestProperty("Accept", "application/json");
            try (OutputStream output = connection.getOutputStream()) {
                output.write(bodyBytes);
            }
            int status = connection.getResponseCode();
            InputStream response = status == HttpURLConnection.HTTP_OK
                    ? connection.getInputStream() : connection.getErrorStream();
            responseBytes = readBounded(response, 65_536);
            if (status != HttpURLConnection.HTTP_OK) {
                throw new java.io.IOException("Spotify 授权接口返回 " + status);
            }
            String contentType = connection.getContentType();
            if (contentType == null
                    || !contentType.toLowerCase(java.util.Locale.ROOT)
                    .startsWith("application/json")) {
                throw new SecurityException("Spotify token response type is invalid");
            }
            return parseAuthorizationResponse(responseBytes, System.currentTimeMillis());
        } finally {
            Arrays.fill(bodyBytes, (byte) 0);
            if (responseBytes != null) Arrays.fill(responseBytes, (byte) 0);
            connection.disconnect();
        }
    }

    static Authorization parseAuthorizationResponse(byte[] jsonBytes, long receivedAtMs)
            throws Exception {
        if (jsonBytes == null || jsonBytes.length == 0 || jsonBytes.length > 65_536) {
            throw new SecurityException("Spotify token response size is invalid");
        }
        if (receivedAtMs < 1_000_000_000_000L || receivedAtMs > 9_999_999_999_999L) {
            throw new SecurityException("Spotify authorization time is invalid");
        }
        byte[] provenance = MessageDigest.getInstance("SHA-256").digest(jsonBytes);
        String access = null;
        String refresh = null;
        try {
            JSONObject parsed = new JSONObject(new String(jsonBytes, StandardCharsets.UTF_8));
            Object accessValue = parsed.opt("access_token");
            Object refreshValue = parsed.opt("refresh_token");
            Object tokenTypeValue = parsed.opt("token_type");
            Object expiresValue = parsed.opt("expires_in");
            Object scopeValue = parsed.opt("scope");
            if (!(accessValue instanceof String)
                    || !(refreshValue instanceof String)
                    || !(tokenTypeValue instanceof String)
                    || !(scopeValue instanceof String)
                    || !(expiresValue instanceof Number)) {
                throw new SecurityException("Spotify token response fields are invalid");
            }
            access = (String) accessValue;
            refresh = (String) refreshValue;
            if (!SecurityRules.isValidAccessToken(access)
                    || !SecurityRules.isValidRefreshToken(refresh)) {
                throw new SecurityException("Spotify returned an invalid token");
            }
            if (!"Bearer".equalsIgnoreCase((String) tokenTypeValue)) {
                throw new SecurityException("Spotify token type is not Bearer");
            }
            long expiresIn = strictIntegralSeconds((Number) expiresValue);
            if (expiresIn < MIN_EXPIRES_IN_SECONDS || expiresIn > MAX_EXPIRES_IN_SECONDS) {
                throw new SecurityException("Spotify access token lifetime is invalid");
            }
            validateScopeCoverage((String) scopeValue);
            long expiresAtMs = Math.addExact(receivedAtMs, Math.multiplyExact(expiresIn, 1_000L));
            return new Authorization(
                    refresh.toCharArray(),
                    access.toCharArray(),
                    receivedAtMs,
                    expiresAtMs,
                    provenance);
        } catch (Exception failure) {
            Arrays.fill(provenance, (byte) 0);
            throw failure;
        } finally {
            access = null;
            refresh = null;
        }
    }

    static Set<String> parseScopes(String value) {
        if (value == null || value.isEmpty()) {
            throw new SecurityException("Spotify returned no scopes");
        }
        Set<String> scopes = new HashSet<>();
        for (String scope : value.split(" ", -1)) {
            if (scope.isEmpty() || !scope.matches("[\\x21\\x23-\\x5b\\x5d-\\x7e]+")) {
                throw new SecurityException("Spotify returned malformed scopes");
            }
            if (!scopes.add(scope)) {
                throw new SecurityException("Spotify returned duplicate scopes");
            }
        }
        return scopes;
    }

    private static void validateScopeCoverage(String value) {
        Set<String> returned = parseScopes(value);
        Set<String> required = parseScopes(AppConfig.SPOTIFY_SCOPES);
        if (!returned.containsAll(required)) {
            throw new SecurityException("Spotify did not grant every required scope");
        }
    }

    private static long strictIntegralSeconds(Number value) {
        String encoded = value.toString();
        if (!encoded.matches("[1-9][0-9]{0,5}")) {
            throw new SecurityException("Spotify expires_in is not an integer");
        }
        return Long.parseLong(encoded);
    }

    private static String form(String name, String value) {
        try {
            return URLEncoder.encode(name, StandardCharsets.UTF_8.name()) + "="
                    + URLEncoder.encode(value, StandardCharsets.UTF_8.name());
        } catch (java.io.UnsupportedEncodingException impossible) {
            throw new IllegalStateException("UTF-8 unavailable", impossible);
        }
    }

    private static byte[] readBounded(InputStream input, int limit) throws Exception {
        if (input == null) return new byte[0];
        try (input; ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[4_096];
            int total = 0;
            int read;
            while ((read = input.read(buffer)) >= 0) {
                total += read;
                if (total > limit) throw new java.io.IOException("Spotify response is too large");
                output.write(buffer, 0, read);
            }
            Arrays.fill(buffer, (byte) 0);
            return output.toByteArray();
        }
    }

    private SpotifyTokenExchange() {}
}
