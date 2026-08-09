package io.xiaoaimusic.handoff;

import android.annotation.SuppressLint;
import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.util.Arrays;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

final class SecureStore {
    private static final String ANDROID_KEYSTORE = "AndroidKeyStore";
    private static final String AES_ALIAS = "xiaoaimusic.secure-store.v1";
    private static final String PREFS = "secure_v1";
    private static final String PENDING_BUNDLE = "pending_authorization_v3";
    private static final String LEGACY_PENDING_REFRESH_TOKEN = "pending_refresh_token";
    private static final String AUTHORIZED_AT = "authorized_at";
    private static final byte CIPHERTEXT_FORMAT_VERSION = 1;
    private static final int BUNDLE_MAGIC = 0x58415033; // XAP3
    private static final int BUNDLE_SCHEMA = 3;
    private static final int GCM_TAG_BITS = 128;
    private static final int IV_BYTES = 12;
    private static final int PROVENANCE_BYTES = 32;

    private final SharedPreferences preferences;
    private boolean legacyCleanupFailed;

    static final class PendingAuthorization implements AutoCloseable {
        private final char[] refreshToken;
        private final char[] accessToken;
        private final long authorizedAtMs;
        private final long accessExpiresAtMs;
        private final byte[] provenance;
        private final boolean verified;
        private final boolean remoteAttempted;

        PendingAuthorization(
                char[] refreshToken,
                char[] accessToken,
                long authorizedAtMs,
                long accessExpiresAtMs,
                byte[] provenance,
                boolean verified,
                boolean remoteAttempted) {
            this.refreshToken = refreshToken;
            this.accessToken = accessToken;
            this.authorizedAtMs = authorizedAtMs;
            this.accessExpiresAtMs = accessExpiresAtMs;
            this.provenance = provenance;
            this.verified = verified;
            this.remoteAttempted = remoteAttempted;
        }

        char[] refreshToken() { return refreshToken; }
        char[] accessToken() { return accessToken; }
        long authorizedAtMs() { return authorizedAtMs; }
        long accessExpiresAtMs() { return accessExpiresAtMs; }
        byte[] provenance() { return provenance; }
        boolean verified() { return verified; }
        boolean remoteAttempted() { return remoteAttempted; }

        PendingAuthorizationState state(long nowMs) {
            return PendingAuthorizationState.evaluate(
                    true, verified, authorizedAtMs, accessExpiresAtMs, nowMs);
        }

        @Override
        public void close() {
            Arrays.fill(refreshToken, '\0');
            Arrays.fill(accessToken, '\0');
            Arrays.fill(provenance, (byte) 0);
        }
    }

    SecureStore(Context context) {
        this.preferences = context.getApplicationContext()
                .getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        discardLegacyPending();
    }

    @SuppressLint("ApplySharedPref")
    void savePendingAuthorization(SpotifyTokenExchange.Authorization authorization)
            throws Exception {
        if (authorization == null
                || !SecurityRules.isValidRefreshTokenChars(authorization.refreshToken())
                || !SecurityRules.isValidAccessTokenChars(authorization.accessToken())
                || authorization.provenance().length != PROVENANCE_BYTES) {
            throw new SecurityException("Spotify authorization bundle is invalid");
        }
        PendingAuthorization pending = new PendingAuthorization(
                authorization.refreshToken().clone(),
                authorization.accessToken().clone(),
                authorization.authorizedAtMs(),
                authorization.accessExpiresAtMs(),
                authorization.provenance().clone(),
                false,
                false);
        try {
            String encrypted = encryptBundle(pending);
            if (!preferences.edit()
                    .putString(PENDING_BUNDLE, encrypted)
                    .remove(LEGACY_PENDING_REFRESH_TOKEN)
                    .commit()) {
                throw new java.io.IOException("pending authorization commit failed");
            }
            legacyCleanupFailed = false;
        } finally {
            pending.close();
        }
    }

    PendingAuthorization getPendingAuthorization() throws Exception {
        if (legacyCleanupFailed) {
            throw new SecurityException("legacy pending authorization cleanup is incomplete");
        }
        String encoded = preferences.getString(PENDING_BUNDLE, null);
        if (encoded == null) return null;
        byte[] plaintext = decrypt(PENDING_BUNDLE, encoded);
        try {
            return decodeBundle(plaintext);
        } finally {
            Arrays.fill(plaintext, (byte) 0);
        }
    }

    @SuppressLint("ApplySharedPref")
    void markPendingVerified(byte[] expectedProvenance, long nowMs) throws Exception {
        try (PendingAuthorization pending = getPendingAuthorization()) {
            if (pending == null
                    || !MessageDigest.isEqual(pending.provenance(), expectedProvenance)
                    || pending.state(nowMs) != PendingAuthorizationState.NEEDS_VERIFICATION) {
                throw new SecurityException("Spotify pending authorization changed before verification");
            }
            PendingAuthorization verified = new PendingAuthorization(
                    pending.refreshToken().clone(),
                    new char[0],
                    pending.authorizedAtMs(),
                    0L,
                    pending.provenance().clone(),
                    true,
                    pending.remoteAttempted());
            try {
                String encrypted = encryptBundle(verified);
                if (!preferences.edit().putString(PENDING_BUNDLE, encrypted).commit()) {
                    throw new java.io.IOException("verified authorization commit failed");
                }
            } finally {
                verified.close();
            }
        }
    }

    @SuppressLint("ApplySharedPref")
    void markPendingRemoteAttempted(byte[] expectedProvenance, long nowMs) throws Exception {
        try (PendingAuthorization pending = getPendingAuthorization()) {
            if (pending == null
                    || !MessageDigest.isEqual(pending.provenance(), expectedProvenance)
                    || pending.state(nowMs) != PendingAuthorizationState.VERIFIED_READY) {
                throw new SecurityException("Spotify authorization is not ready for upload");
            }
            if (pending.remoteAttempted()) return;
            PendingAuthorization attempted = new PendingAuthorization(
                    pending.refreshToken().clone(),
                    new char[0],
                    pending.authorizedAtMs(),
                    0L,
                    pending.provenance().clone(),
                    true,
                    true);
            try {
                String encrypted = encryptBundle(attempted);
                if (!preferences.edit().putString(PENDING_BUNDLE, encrypted).commit()) {
                    throw new java.io.IOException("upload-attempt commit failed");
                }
            } finally {
                attempted.close();
            }
        }
    }

    @SuppressLint("ApplySharedPref")
    void markAuthorizationUploaded(byte[] expectedProvenance, long nowMs) throws Exception {
        try (PendingAuthorization pending = getPendingAuthorization()) {
            if (pending == null
                    || !MessageDigest.isEqual(pending.provenance(), expectedProvenance)
                    || pending.state(nowMs) != PendingAuthorizationState.VERIFIED_READY) {
                throw new SecurityException("Spotify authorization is not verified for upload");
            }
            if (!preferences.edit()
                    .remove(PENDING_BUNDLE)
                    .putLong(AUTHORIZED_AT, pending.authorizedAtMs())
                    .commit()) {
                throw new java.io.IOException("uploaded authorization cleanup failed");
            }
        }
    }

    long getAuthorizedAtMs() {
        return preferences.getLong(AUTHORIZED_AT, 0L);
    }

    boolean hasPendingAuthorization() {
        return !legacyCleanupFailed && preferences.contains(PENDING_BUNDLE);
    }

    PendingAuthorizationState pendingState(long nowMs) {
        if (!hasPendingAuthorization()) return PendingAuthorizationState.NONE;
        try (PendingAuthorization pending = getPendingAuthorization()) {
            return pending == null ? PendingAuthorizationState.NONE : pending.state(nowMs);
        } catch (Exception invalid) {
            return PendingAuthorizationState.INVALID;
        }
    }

    @SuppressLint("ApplySharedPref")
    void discardPendingAuthorization() throws java.io.IOException {
        if (!preferences.edit().remove(PENDING_BUNDLE).commit()) {
            throw new java.io.IOException("pending authorization cleanup failed");
        }
    }

    private String encryptBundle(PendingAuthorization pending) throws Exception {
        byte[] plaintext = encodeBundle(pending);
        try {
            return encrypt(PENDING_BUNDLE, plaintext);
        } finally {
            Arrays.fill(plaintext, (byte) 0);
        }
    }

    private static byte[] encodeBundle(PendingAuthorization pending) {
        int refreshLength = pending.refreshToken().length;
        int accessLength = pending.accessToken().length;
        ByteBuffer buffer = ByteBuffer.allocate(
                4 + 4 + 1 + 8 + 8 + PROVENANCE_BYTES + 4 + 4 + refreshLength + accessLength);
        buffer.putInt(BUNDLE_MAGIC);
        buffer.putInt(BUNDLE_SCHEMA);
        int flags = (pending.verified() ? 1 : 0) | (pending.remoteAttempted() ? 2 : 0);
        buffer.put((byte) flags);
        buffer.putLong(pending.authorizedAtMs());
        buffer.putLong(pending.accessExpiresAtMs());
        buffer.put(pending.provenance());
        buffer.putInt(refreshLength);
        buffer.putInt(accessLength);
        putAscii(buffer, pending.refreshToken());
        putAscii(buffer, pending.accessToken());
        return buffer.array();
    }

    private static PendingAuthorization decodeBundle(byte[] plaintext) {
        int minimum = 4 + 4 + 1 + 8 + 8 + PROVENANCE_BYTES + 4 + 4 + 32;
        if (plaintext.length < minimum) throw new SecurityException("pending bundle is truncated");
        ByteBuffer buffer = ByteBuffer.wrap(plaintext);
        if (buffer.getInt() != BUNDLE_MAGIC || buffer.getInt() != BUNDLE_SCHEMA) {
            throw new SecurityException("pending bundle schema is invalid");
        }
        byte flags = buffer.get();
        if ((flags & ~3) != 0 || (flags & 2) != 0 && (flags & 1) == 0) {
            throw new SecurityException("pending verification state is invalid");
        }
        long authorizedAtMs = buffer.getLong();
        long accessExpiresAtMs = buffer.getLong();
        byte[] provenance = new byte[PROVENANCE_BYTES];
        buffer.get(provenance);
        int refreshLength = buffer.getInt();
        int accessLength = buffer.getInt();
        boolean verified = (flags & 1) != 0;
        boolean remoteAttempted = (flags & 2) != 0;
        boolean accessLengthValid = verified
                ? accessLength == 0
                : accessLength >= 32 && accessLength <= 8192;
        if (refreshLength < 32 || refreshLength > 4096
                || !accessLengthValid
                || buffer.remaining() != refreshLength + accessLength) {
            Arrays.fill(provenance, (byte) 0);
            throw new SecurityException("pending token lengths are invalid");
        }
        char[] refresh = getAscii(buffer, refreshLength);
        char[] access = getAscii(buffer, accessLength);
        if (!SecurityRules.isValidRefreshTokenChars(refresh)
                || (!verified && !SecurityRules.isValidAccessTokenChars(access))) {
            Arrays.fill(refresh, '\0');
            Arrays.fill(access, '\0');
            Arrays.fill(provenance, (byte) 0);
            throw new SecurityException("pending token format is invalid");
        }
        return new PendingAuthorization(
                refresh, access, authorizedAtMs, accessExpiresAtMs, provenance,
                verified, remoteAttempted);
    }

    private static void putAscii(ByteBuffer buffer, char[] value) {
        for (char character : value) buffer.put((byte) character);
    }

    private static char[] getAscii(ByteBuffer buffer, int length) {
        char[] value = new char[length];
        for (int index = 0; index < length; index++) {
            value[index] = (char) (buffer.get() & 0xff);
        }
        return value;
    }

    private String encrypt(String name, byte[] plaintext) throws Exception {
        SecretKey key = getOrCreateKey();
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        // AndroidKeyStore keys created with randomized encryption required reject a
        // caller-provided IV. Let KeyMint generate it, then persist that IV beside
        // the ciphertext for the later GCM decryption operation.
        cipher.init(Cipher.ENCRYPT_MODE, key);
        byte[] iv = cipher.getIV();
        if (iv == null || iv.length != IV_BYTES) {
            throw new java.security.GeneralSecurityException(
                    "AndroidKeyStore returned an invalid GCM IV");
        }
        cipher.updateAAD(name.getBytes(StandardCharsets.UTF_8));
        byte[] ciphertext = cipher.doFinal(plaintext);
        ByteBuffer packed = ByteBuffer.allocate(1 + IV_BYTES + ciphertext.length);
        packed.put(CIPHERTEXT_FORMAT_VERSION).put(iv).put(ciphertext);
        Arrays.fill(ciphertext, (byte) 0);
        byte[] packedBytes = packed.array();
        try {
            return Base64.encodeToString(packedBytes, Base64.NO_WRAP);
        } finally {
            Arrays.fill(iv, (byte) 0);
            Arrays.fill(packedBytes, (byte) 0);
        }
    }

    private byte[] decrypt(String name, String encoded) throws Exception {
        byte[] packed = Base64.decode(encoded, Base64.NO_WRAP);
        try {
            if (packed.length < 1 + IV_BYTES + 16
                    || packed[0] != CIPHERTEXT_FORMAT_VERSION) {
                throw new SecurityException("encrypted value format is invalid");
            }
            ByteBuffer buffer = ByteBuffer.wrap(packed);
            buffer.get();
            byte[] iv = new byte[IV_BYTES];
            buffer.get(iv);
            byte[] ciphertext = new byte[buffer.remaining()];
            buffer.get(ciphertext);
            try {
                Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
                cipher.init(Cipher.DECRYPT_MODE, getOrCreateKey(),
                        new GCMParameterSpec(GCM_TAG_BITS, iv));
                cipher.updateAAD(name.getBytes(StandardCharsets.UTF_8));
                return cipher.doFinal(ciphertext);
            } finally {
                Arrays.fill(iv, (byte) 0);
                Arrays.fill(ciphertext, (byte) 0);
            }
        } finally {
            Arrays.fill(packed, (byte) 0);
        }
    }

    @SuppressLint("ApplySharedPref")
    private void discardLegacyPending() {
        if (!preferences.contains(LEGACY_PENDING_REFRESH_TOKEN)) return;
        legacyCleanupFailed = !preferences.edit()
                .remove(LEGACY_PENDING_REFRESH_TOKEN)
                .commit();
    }

    private SecretKey getOrCreateKey() throws Exception {
        KeyStore keyStore = KeyStore.getInstance(ANDROID_KEYSTORE);
        keyStore.load(null);
        if (keyStore.containsAlias(AES_ALIAS)) {
            return (SecretKey) keyStore.getKey(AES_ALIAS, null);
        }
        KeyGenerator generator = KeyGenerator.getInstance(
                KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE);
        generator.init(new KeyGenParameterSpec.Builder(
                AES_ALIAS, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setRandomizedEncryptionRequired(true)
                .setUserAuthenticationRequired(false)
                .build());
        return generator.generateKey();
    }
}
