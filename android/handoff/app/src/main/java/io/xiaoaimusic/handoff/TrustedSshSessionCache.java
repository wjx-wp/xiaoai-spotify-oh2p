package io.xiaoaimusic.handoff;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;

import com.jcraft.jsch.ChannelExec;
import com.jcraft.jsch.Session;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;

final class TrustedSshSessionCache {
    private static final Object LOCK = new Object();
    private static final int CONNECT_TIMEOUT_MS = 2_500;
    private static final int COMMAND_TIMEOUT_MS = 3_000;
    private static final int MAX_REPLY_BYTES = 512;
    private static volatile Session cachedSession;
    private static volatile long cachedNetworkHandle = -1L;
    private static volatile String cachedHost;

    static Network currentWifiNetwork(Context context) {
        ConnectivityManager connectivity = context.getSystemService(ConnectivityManager.class);
        if (connectivity == null) return null;
        Network network = connectivity.getActiveNetwork();
        NetworkCapabilities capabilities = network == null
                ? null : connectivity.getNetworkCapabilities(network);
        if (capabilities == null
                || !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
                || capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) {
            return null;
        }
        return network;
    }

    static boolean prewarm(Context context) {
        synchronized (LOCK) {
            try {
                return connectedSessionLocked(context, CONNECT_TIMEOUT_MS) != null;
            } catch (Exception failure) {
                disconnectLocked();
                return false;
            }
        }
    }

    static boolean isConnectedForCurrentNetwork(Context context) {
        Network network = currentWifiNetwork(context);
        Session snapshot = cachedSession;
        return network != null
                && cachedNetworkHandle == network.getNetworkHandle()
                && new AppPreferences(context).getSpeakerHost().equals(cachedHost)
                && snapshot != null
                && snapshot.isConnected();
    }

    static boolean requestTakeover(
            Context context, long eventDeadlineElapsedMs, boolean requireAuto) {
        synchronized (LOCK) {
            for (int attempt = 0; attempt < 2; attempt++) {
                try {
                    int connectTimeout = remainingTimeout(
                            eventDeadlineElapsedMs, CONNECT_TIMEOUT_MS);
                    if (connectTimeout <= 0) return false;
                    Session session = connectedSessionLocked(context, connectTimeout);
                    if (session == null
                            || !isCurrentSnapshotLocked(context)
                            || (requireAuto && !new AppPreferences(context).isAutoEnabled())
                            || TakeoverPolicy.evaluate(context) != TakeoverPolicy.Decision.ALLOW) {
                        return false;
                    }
                    if (executeTakeoverLocked(
                            context, session, eventDeadlineElapsedMs, requireAuto)) {
                        return android.os.SystemClock.elapsedRealtime() <= eventDeadlineElapsedMs
                                && isCurrentSnapshotLocked(context)
                                && (!requireAuto
                                || new AppPreferences(context).isAutoEnabled())
                                && TakeoverPolicy.evaluate(context)
                                == TakeoverPolicy.Decision.ALLOW;
                    }
                } catch (Exception failure) {
                    // A stale session gets one clean reconnect below; no secret is logged.
                }
                disconnectLocked();
            }
            return false;
        }
    }

    static void invalidate() {
        Session snapshot = cachedSession;
        if (snapshot != null) snapshot.disconnect();
        synchronized (LOCK) {
            disconnectLocked();
        }
    }

    static void abortInFlight() {
        Session snapshot = cachedSession;
        if (snapshot != null) snapshot.disconnect();
    }

    static void invalidateIfMatches(long networkHandle) {
        long observedHandle = cachedNetworkHandle;
        Session snapshot = cachedSession;
        if (observedHandle == networkHandle && cachedNetworkHandle == networkHandle) {
            if (snapshot != null) snapshot.disconnect();
        }
        synchronized (LOCK) {
            if (cachedNetworkHandle == networkHandle) disconnectLocked();
        }
    }

    private static Session connectedSessionLocked(Context context, int connectTimeoutMs)
            throws Exception {
        Network network = currentWifiNetwork(context);
        if (network == null) return null;
        long handle = network.getNetworkHandle();
        String host = new AppPreferences(context).getSpeakerHost();
        if (cachedSession != null
                && cachedSession.isConnected()
                && cachedNetworkHandle == handle
                && host.equals(cachedHost)) {
            return cachedSession;
        }
        disconnectLocked();
        Session candidate = SshSessionFactory.create(
                context, network, new SshKeyManager(context), connectTimeoutMs);
        candidate.setServerAliveInterval(15_000);
        candidate.setServerAliveCountMax(2);
        try {
            candidate.connect(connectTimeoutMs);
            if (!network.equals(currentWifiNetwork(context))
                    || !host.equals(new AppPreferences(context).getSpeakerHost())) {
                candidate.disconnect();
                return null;
            }
            cachedNetworkHandle = handle;
            cachedHost = host;
            cachedSession = candidate;
            return cachedSession;
        } catch (Exception failure) {
            candidate.disconnect();
            throw failure;
        }
    }

    private static boolean executeTakeoverLocked(
            Context context,
            Session session,
            long eventDeadlineElapsedMs,
            boolean requireAuto) throws Exception {
        ChannelExec channel = null;
        try {
            if (!isCurrentSnapshotLocked(context)
                    || (requireAuto && !new AppPreferences(context).isAutoEnabled())
                    || TakeoverPolicy.evaluate(context) != TakeoverPolicy.Decision.ALLOW) {
                return false;
            }
            int channelConnectTimeout = remainingTimeout(
                    eventDeadlineElapsedMs, CONNECT_TIMEOUT_MS);
            if (channelConnectTimeout <= 0) return false;
            channel = (ChannelExec) session.openChannel("exec");
            channel.setCommand(AppConfig.TAKEOVER_COMMAND);
            channel.setPty(false);
            channel.setInputStream(new ByteArrayInputStream(new byte[0]));
            LimitedOutputStream stdout = new LimitedOutputStream(MAX_REPLY_BYTES);
            LimitedOutputStream stderr = new LimitedOutputStream(MAX_REPLY_BYTES);
            channel.setOutputStream(stdout);
            channel.setErrStream(stderr);
            channel.connect(channelConnectTimeout);
            long deadline = Math.min(
                    eventDeadlineElapsedMs,
                    android.os.SystemClock.elapsedRealtime() + COMMAND_TIMEOUT_MS);
            while (!channel.isClosed() && android.os.SystemClock.elapsedRealtime() < deadline) {
                Thread.sleep(20L);
            }
            return channel.isClosed()
                    && channel.getExitStatus() == 0
                    && "OK takeover_queued".equals(stdout.asAscii().trim());
        } finally {
            if (channel != null) channel.disconnect();
        }
    }

    private static boolean isCurrentSnapshotLocked(Context context) {
        Network current = currentWifiNetwork(context);
        return current != null
                && current.getNetworkHandle() == cachedNetworkHandle
                && new AppPreferences(context).getSpeakerHost().equals(cachedHost)
                && cachedSession != null
                && cachedSession.isConnected();
    }

    private static int remainingTimeout(long deadlineElapsedMs, int capMs) {
        long remaining = deadlineElapsedMs - android.os.SystemClock.elapsedRealtime();
        if (remaining <= 0L) return 0;
        return (int) Math.max(1L, Math.min((long) capMs, remaining));
    }

    private static void disconnectLocked() {
        if (cachedSession != null) cachedSession.disconnect();
        cachedSession = null;
        cachedNetworkHandle = -1L;
        cachedHost = null;
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

    private TrustedSshSessionCache() {}
}
