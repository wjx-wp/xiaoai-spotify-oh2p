package io.xiaoaimusic.handoff;

import android.content.Context;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.KeyStore;
import java.security.PrivateKey;
import java.security.Signature;
import java.security.interfaces.RSAPublicKey;
import java.security.spec.RSAKeyGenParameterSpec;

final class SshKeyManager {
    private static final String ANDROID_KEYSTORE = "AndroidKeyStore";
    private static final String KEY_ALIAS = "xiaoaimusic.mobile-auth.rsa.v1";
    private static final int PRIMARY_KEY_SIZE = 3072;
    private static final int FALLBACK_KEY_SIZE = 2048;

    private final Context context;

    SshKeyManager(Context context) {
        this.context = context.getApplicationContext();
    }

    synchronized KeyPair getOrCreateKeyPair() throws Exception {
        KeyStore keyStore = KeyStore.getInstance(ANDROID_KEYSTORE);
        keyStore.load(null);
        KeyStore.Entry existing = keyStore.getEntry(KEY_ALIAS, null);
        if (existing instanceof KeyStore.PrivateKeyEntry entry) {
            return new KeyPair(entry.getCertificate().getPublicKey(), entry.getPrivateKey());
        }
        try {
            return generate(PRIMARY_KEY_SIZE);
        } catch (Exception primaryFailure) {
            try {
                return generate(FALLBACK_KEY_SIZE);
            } catch (Exception fallbackFailure) {
                fallbackFailure.addSuppressed(primaryFailure);
                throw fallbackFailure;
            }
        }
    }

    File exportPublicKey() throws Exception {
        String line = publicKeyLine() + "\n";
        File destination = new File(context.getFilesDir(), AppConfig.MOBILE_AUTH_PUBLIC_KEY_FILE);
        try (FileOutputStream output = context.openFileOutput(
                AppConfig.MOBILE_AUTH_PUBLIC_KEY_FILE, Context.MODE_PRIVATE)) {
            output.write(line.getBytes(StandardCharsets.US_ASCII));
            output.getFD().sync();
        }
        return destination;
    }

    String publicKeyLine() throws Exception {
        KeyPair pair = getOrCreateKeyPair();
        return formatPublicKeyLine((RSAPublicKey) pair.getPublic());
    }

    static String formatPublicKeyLine(RSAPublicKey publicKey) {
        return SshWire.openSshRsaPublicKey(publicKey, null);
    }

    byte[] publicKeyBlob() throws Exception {
        return SshWire.rsaPublicKeyBlob((RSAPublicKey) getOrCreateKeyPair().getPublic());
    }

    byte[] signSshRsa(byte[] data) throws Exception {
        PrivateKey privateKey = getOrCreateKeyPair().getPrivate();
        Signature signer = Signature.getInstance("SHA1withRSA");
        signer.initSign(privateKey);
        signer.update(data);
        return SshWire.signatureBlob("ssh-rsa", signer.sign());
    }

    private KeyPair generate(int keySize) throws Exception {
        KeyPairGenerator generator = KeyPairGenerator.getInstance(
                KeyProperties.KEY_ALGORITHM_RSA, ANDROID_KEYSTORE);
        generator.initialize(new KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_SIGN)
                .setAlgorithmParameterSpec(new RSAKeyGenParameterSpec(
                        keySize, RSAKeyGenParameterSpec.F4))
                .setDigests(KeyProperties.DIGEST_SHA1, KeyProperties.DIGEST_SHA256)
                .setSignaturePaddings(KeyProperties.SIGNATURE_PADDING_RSA_PKCS1)
                .setUserAuthenticationRequired(false)
                .build());
        return generator.generateKeyPair();
    }
}
