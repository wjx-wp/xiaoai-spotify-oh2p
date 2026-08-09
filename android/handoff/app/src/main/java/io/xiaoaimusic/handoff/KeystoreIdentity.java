package io.xiaoaimusic.handoff;

import com.jcraft.jsch.Identity;
import com.jcraft.jsch.JSchException;

final class KeystoreIdentity implements Identity {
    private final SshKeyManager keys;

    KeystoreIdentity(SshKeyManager keys) {
        this.keys = keys;
    }

    @Override
    public boolean setPassphrase(byte[] passphrase) throws JSchException {
        return passphrase == null || passphrase.length == 0;
    }

    @Override
    public byte[] getPublicKeyBlob() {
        try {
            return keys.publicKeyBlob();
        } catch (Exception failure) {
            return null;
        }
    }

    @Override
    public byte[] getSignature(byte[] data) {
        return getSignature(data, "ssh-rsa");
    }

    @Override
    public byte[] getSignature(byte[] data, String algorithm) {
        if (!"ssh-rsa".equals(algorithm)) return null;
        try {
            return keys.signSshRsa(data);
        } catch (Exception failure) {
            return null;
        }
    }

    @Override
    public String getAlgName() {
        return "ssh-rsa";
    }

    @Override
    public String getName() {
        return "AndroidKeyStore:xiaoai-mobile-auth";
    }

    @Override
    public boolean isEncrypted() {
        return false;
    }

    @Override
    public void clear() {
        // The non-exportable AndroidKeyStore private key has no in-memory bytes to clear.
    }
}
