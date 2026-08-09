package io.xiaoaimusic.handoff;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Base64;

final class OAuthPkce {
    record Values(String verifier, String challenge, String state) {}

    static Values generate() {
        SecureRandom random = new SecureRandom();
        byte[] verifierBytes = new byte[64];
        byte[] stateBytes = new byte[32];
        random.nextBytes(verifierBytes);
        random.nextBytes(stateBytes);
        String verifier = base64Url(verifierBytes);
        try {
            String challenge = base64Url(MessageDigest.getInstance("SHA-256")
                    .digest(verifier.getBytes(StandardCharsets.US_ASCII)));
            return new Values(verifier, challenge, base64Url(stateBytes));
        } catch (Exception impossible) {
            throw new IllegalStateException("SHA-256 unavailable", impossible);
        }
    }

    static String base64Url(byte[] value) {
        return Base64.getUrlEncoder().withoutPadding().encodeToString(value);
    }

    private OAuthPkce() {}
}
