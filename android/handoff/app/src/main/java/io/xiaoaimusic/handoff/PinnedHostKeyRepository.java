package io.xiaoaimusic.handoff;

import com.jcraft.jsch.HostKey;
import com.jcraft.jsch.HostKeyRepository;
import com.jcraft.jsch.UserInfo;

final class PinnedHostKeyRepository implements HostKeyRepository {
    private final String expectedHost;
    private final String expectedFingerprint;

    PinnedHostKeyRepository(String expectedHost, String expectedFingerprint) {
        this.expectedHost = expectedHost;
        this.expectedFingerprint = expectedFingerprint;
    }

    @Override
    public int check(String host, byte[] key) {
        if (!expectedHost.equals(host)) return CHANGED;
        String actual = SecurityRules.sha256Fingerprint(key);
        return SecurityRules.constantTimeEquals(expectedFingerprint, actual) ? OK : CHANGED;
    }

    @Override
    public void add(HostKey hostkey, UserInfo userInfo) {
        throw new SecurityException("host-key changes are never accepted");
    }

    @Override
    public void remove(String host, String type) {
        throw new SecurityException("host-key pin cannot be removed");
    }

    @Override
    public void remove(String host, String type, byte[] key) {
        throw new SecurityException("host-key pin cannot be removed");
    }

    @Override
    public String getKnownHostsRepositoryID() {
        return "embedded SHA-256 host-key pin";
    }

    @Override
    public HostKey[] getHostKey() {
        return new HostKey[0];
    }

    @Override
    public HostKey[] getHostKey(String host, String type) {
        return new HostKey[0];
    }
}
