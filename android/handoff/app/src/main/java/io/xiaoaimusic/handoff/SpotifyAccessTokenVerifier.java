package io.xiaoaimusic.handoff;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;

import javax.net.ssl.HttpsURLConnection;

final class SpotifyAccessTokenVerifier {
    static void verify(char[] accessToken) throws Exception {
        if (!SecurityRules.isValidAccessTokenChars(accessToken)) {
            throw new SecurityException("待验证的 Spotify access token 无效");
        }
        HttpsURLConnection connection = (HttpsURLConnection)
                new URL(AppConfig.SPOTIFY_DEVICES_URL).openConnection();
        byte[] body = null;
        String authorization = "Bearer " + new String(accessToken);
        try {
            connection.setRequestMethod("GET");
            connection.setConnectTimeout(15_000);
            connection.setReadTimeout(15_000);
            connection.setInstanceFollowRedirects(false);
            connection.setRequestProperty("Accept", "application/json");
            connection.setRequestProperty("Authorization", authorization);
            int status = connection.getResponseCode();
            InputStream input = status == HttpURLConnection.HTTP_OK
                    ? connection.getInputStream() : connection.getErrorStream();
            body = readBounded(input, 262_144);
            if (status == HttpURLConnection.HTTP_UNAUTHORIZED) {
                throw new AccessTokenRejectedException();
            }
            if (status != HttpURLConnection.HTTP_OK) {
                throw new java.io.IOException("Spotify 只读验证接口返回 " + status);
            }
            String contentType = connection.getContentType();
            if (contentType == null
                    || !contentType.toLowerCase(java.util.Locale.ROOT).startsWith("application/json")) {
                throw new SecurityException("Spotify 只读验证响应类型无效");
            }
            JSONObject parsed = new JSONObject(new String(body, StandardCharsets.UTF_8));
            Object devices = parsed.opt("devices");
            if (!(devices instanceof JSONArray)) {
                throw new SecurityException("Spotify 只读验证响应无效");
            }
        } finally {
            authorization = null;
            if (body != null) Arrays.fill(body, (byte) 0);
            connection.disconnect();
        }
    }

    static final class AccessTokenRejectedException extends SecurityException {
        AccessTokenRejectedException() {
            super("Spotify access token 已失效，请重新浏览器授权");
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
                if (total > limit) throw new java.io.IOException("Spotify verification response is too large");
                output.write(buffer, 0, read);
            }
            Arrays.fill(buffer, (byte) 0);
            return output.toByteArray();
        }
    }

    private SpotifyAccessTokenVerifier() {}
}
