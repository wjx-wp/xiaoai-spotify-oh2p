package io.xiaoaimusic.handoff;

import android.content.Context;
import android.net.Network;

import com.jcraft.jsch.JSch;
import com.jcraft.jsch.Session;

import java.util.Hashtable;

final class SshSessionFactory {
    static Session create(
            Context context, Network network, SshKeyManager keyManager, int connectTimeoutMs)
            throws Exception {
        String host = new AppPreferences(context).getSpeakerHost();
        JSch jsch = new JSch();
        jsch.setHostKeyRepository(new PinnedHostKeyRepository(
                host, AppConfig.SPEAKER_HOST_KEY_SHA256));
        jsch.addIdentity(new KeystoreIdentity(keyManager), null);

        Session session = jsch.getSession(
                AppConfig.SPEAKER_SSH_USER,
                host,
                AppConfig.SPEAKER_SSH_PORT);
        Hashtable<String, String> config = new Hashtable<>();
        config.put("StrictHostKeyChecking", "yes");
        config.put("PreferredAuthentications", "publickey");
        config.put("kex", "diffie-hellman-group14-sha1");
        config.put("server_host_key", "ssh-rsa");
        config.put("PubkeyAcceptedAlgorithms", "ssh-rsa");
        config.put("cipher.c2s", "aes128-ctr,aes256-ctr");
        config.put("cipher.s2c", "aes128-ctr,aes256-ctr");
        config.put("mac.c2s", "hmac-sha1");
        config.put("mac.s2c", "hmac-sha1");
        session.setConfig(config);
        session.setSocketFactory(new NetworkBoundSocketFactory(network, connectTimeoutMs));
        return session;
    }

    private SshSessionFactory() {}
}
