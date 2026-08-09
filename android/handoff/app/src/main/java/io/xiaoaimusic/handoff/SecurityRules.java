package io.xiaoaimusic.handoff;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Base64;
import java.util.regex.Pattern;

final class SecurityRules {
    private static final Pattern REFRESH_TOKEN = Pattern.compile("[\\x21-\\x7e]{32,4096}");
    private static final Pattern ACCESS_TOKEN = Pattern.compile("[\\x21-\\x7e]{32,8192}");

    static boolean isValidRefreshToken(String value) {
        return value != null
                && value.indexOf('\r') < 0
                && value.indexOf('\n') < 0
                && REFRESH_TOKEN.matcher(value).matches();
    }

    static boolean isValidAccessToken(String value) {
        return value != null
                && value.indexOf('\r') < 0
                && value.indexOf('\n') < 0
                && ACCESS_TOKEN.matcher(value).matches();
    }

    static boolean isValidAccessTokenChars(char[] value) {
        if (value == null || value.length < 32 || value.length > 8192) return false;
        for (char character : value) {
            if (character < 0x21 || character > 0x7e) return false;
        }
        return true;
    }

    static boolean isValidRefreshTokenChars(char[] value) {
        if (value == null || value.length < 32 || value.length > 4096) return false;
        for (char character : value) {
            if (character < 0x21 || character > 0x7e) return false;
        }
        return true;
    }

    static boolean constantTimeEquals(String left, String right) {
        if (left == null || right == null) return false;
        return MessageDigest.isEqual(
                left.getBytes(StandardCharsets.UTF_8),
                right.getBytes(StandardCharsets.UTF_8));
    }

    static String sha256Fingerprint(byte[] keyBlob) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(keyBlob);
            return "SHA256:" + Base64.getEncoder().withoutPadding().encodeToString(digest);
        } catch (Exception impossible) {
            throw new IllegalStateException("SHA-256 unavailable", impossible);
        }
    }

    private SecurityRules() {}
}
