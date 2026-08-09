package io.xiaoaimusic.handoff;

import com.jcraft.jsch.ChannelExec;
import com.jcraft.jsch.Session;

import android.content.Context;
import android.net.Network;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;

final class RestrictedSshUploader {
    private static final int CONNECT_TIMEOUT_MS = 8_000;
    private static final int COMMAND_TIMEOUT_MS = 75_000;
    private static final int STATUS_TIMEOUT_MS = 5_000;
    private static final int MAX_REPLY_BYTES = 4_096;

    private final Context context;
    private final SshKeyManager keyManager;

    RestrictedSshUploader(Context context, SshKeyManager keyManager) {
        this.context = context.getApplicationContext();
        this.keyManager = keyManager;
    }

    void upload(char[] refreshToken, long authorizedAtMs, boolean reconcilePriorAttempt)
            throws Exception {
        Network network = TrustedSshSessionCache.currentWifiNetwork(context);
        if (network == null) throw new SecurityException("a direct Wi-Fi network is required");
        Session session = SshSessionFactory.create(
                context, network, keyManager, CONNECT_TIMEOUT_MS);
        session.setTimeout(COMMAND_TIMEOUT_MS);
        byte[] payload = null;
        try {
            session.connect(CONNECT_TIMEOUT_MS);
            if (reconcilePriorAttempt
                    && authorizationStatusMatches(session, authorizedAtMs)) return;
            payload = buildPayload(refreshToken, authorizedAtMs);
            try {
                CommandResult update = runCommand(
                        session, AppConfig.AUTH_UPDATE_COMMAND, payload, COMMAND_TIMEOUT_MS);
                if (update.exitStatus != 0 || !"OK auth_updated".equals(update.stdout)) {
                    throw new java.io.IOException("speaker rejected the authorization update");
                }
                return;
            } catch (Exception updateFailure) {
                if (updateFailure instanceof InterruptedException interrupted) {
                    Thread.currentThread().interrupt();
                    throw interrupted;
                }
                if (session.isConnected()
                        && authorizationStatusMatches(session, authorizedAtMs)) return;
                session.disconnect();
                try {
                    Network recoveryNetwork = TrustedSshSessionCache.currentWifiNetwork(context);
                    if (recoveryNetwork != null) {
                        session = SshSessionFactory.create(
                                context, recoveryNetwork, keyManager, CONNECT_TIMEOUT_MS);
                        session.connect(CONNECT_TIMEOUT_MS);
                        if (authorizationStatusMatches(session, authorizedAtMs)) return;
                    }
                } catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt();
                    throw interrupted;
                } catch (Exception recoveryFailure) {
                    updateFailure.addSuppressed(recoveryFailure);
                }
                throw updateFailure;
            }
        } finally {
            if (payload != null) Arrays.fill(payload, (byte) 0);
            session.disconnect();
        }
    }

    private long queryAuthorizedAt(Session session) throws Exception {
        CommandResult status = runCommand(
                session, AppConfig.AUTH_STATUS_COMMAND, new byte[0], STATUS_TIMEOUT_MS);
        return parseAuthorizedAtStatus(status.exitStatus, status.stdout);
    }

    private boolean authorizationStatusMatches(Session session, long authorizedAtMs)
            throws InterruptedException {
        return authorizationStatusMatches(() -> queryAuthorizedAt(session), authorizedAtMs);
    }

    static boolean authorizationStatusMatches(
            AuthorizedAtQuery query, long authorizedAtMs) throws InterruptedException {
        try {
            return query.query() == authorizedAtMs;
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            throw interrupted;
        } catch (Exception unavailable) {
            return false;
        }
    }

    static long parseAuthorizedAtStatus(int exitStatus, String stdout)
            throws java.io.IOException {
        if (exitStatus != 0
                || stdout == null
                || !stdout.matches("OK auth_status [0-9]{13}")) {
            throw new java.io.IOException("speaker authorization status is unavailable");
        }
        return Long.parseLong(stdout.substring("OK auth_status ".length()));
    }

    private CommandResult runCommand(
            Session session, String command, byte[] input, int timeoutMs) throws Exception {
        ChannelExec channel = null;
        try {
            channel = (ChannelExec) session.openChannel("exec");
            channel.setCommand(command);
            channel.setPty(false);
            channel.setInputStream(new ByteArrayInputStream(input));
            LimitedOutputStream stdout = new LimitedOutputStream(MAX_REPLY_BYTES);
            LimitedOutputStream stderr = new LimitedOutputStream(MAX_REPLY_BYTES);
            channel.setOutputStream(stdout);
            channel.setErrStream(stderr);
            channel.connect(Math.min(CONNECT_TIMEOUT_MS, timeoutMs));
            long deadline = android.os.SystemClock.elapsedRealtime() + timeoutMs;
            while (!channel.isClosed() && android.os.SystemClock.elapsedRealtime() < deadline) {
                Thread.sleep(25L);
            }
            if (!channel.isClosed()) {
                throw new java.io.IOException("speaker restricted command timed out");
            }
            return new CommandResult(channel.getExitStatus(), stdout.asAscii().trim());
        } finally {
            if (channel != null) channel.disconnect();
        }
    }

    static byte[] buildPayload(String refreshToken, long authorizedAtMs) {
        return buildPayload(refreshToken == null ? null : refreshToken.toCharArray(), authorizedAtMs);
    }

    static byte[] buildPayload(char[] refreshToken, long authorizedAtMs) {
        if (!SecurityRules.isValidRefreshTokenChars(refreshToken)) {
            throw new SecurityException("refresh token is not valid for the update protocol");
        }
        String authorizedAt = Long.toString(authorizedAtMs);
        if (!authorizedAt.matches("[0-9]{13}")) {
            throw new SecurityException("authorization timestamp must contain exactly 13 digits");
        }
        byte[] prefix = ("XIAOAIMUSIC_AUTH_V1\n" + authorizedAt + "\n")
                .getBytes(StandardCharsets.US_ASCII);
        byte[] suffix = "\nEND\n".getBytes(StandardCharsets.US_ASCII);
        byte[] encoded = new byte[prefix.length + refreshToken.length + suffix.length];
        System.arraycopy(prefix, 0, encoded, 0, prefix.length);
        for (int index = 0; index < refreshToken.length; index++) {
            encoded[prefix.length + index] = (byte) refreshToken[index];
        }
        System.arraycopy(suffix, 0, encoded, prefix.length + refreshToken.length, suffix.length);
        if (encoded.length > 4_192) {
            Arrays.fill(encoded, (byte) 0);
            throw new SecurityException("authorization update is too large");
        }
        return encoded;
    }

    private static final class CommandResult {
        final int exitStatus;
        final String stdout;

        CommandResult(int exitStatus, String stdout) {
            this.exitStatus = exitStatus;
            this.stdout = stdout;
        }
    }

    @FunctionalInterface
    interface AuthorizedAtQuery {
        long query() throws Exception;
    }

    private static final class LimitedOutputStream extends ByteArrayOutputStream {
        private final int limit;

        LimitedOutputStream(int limit) {
            this.limit = limit;
        }

        @Override
        public synchronized void write(int value) {
            if (count < limit) super.write(value);
        }

        @Override
        public synchronized void write(byte[] value, int offset, int length) {
            int allowed = Math.min(length, Math.max(0, limit - count));
            if (allowed > 0) super.write(value, offset, allowed);
        }

        String asAscii() {
            return new String(toByteArray(), StandardCharsets.US_ASCII);
        }
    }
}
