package io.xiaoaimusic.handoff;

import android.content.Context;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

final class TakeoverOrchestrator {
    private static final ScheduledExecutorService EXECUTOR =
            Executors.newSingleThreadScheduledExecutor(new DaemonThreadFactory());
    private static final Object PENDING_LOCK = new Object();
    private static final List<ScheduledFuture<?>> PENDING = new ArrayList<>(2);
    private static final AtomicLong GENERATION = new AtomicLong();
    private static final long EVENT_LIFETIME_MS = 7_500L;

    static void sendNow(Context context, String reason) {
        long generation = replacePendingGeneration();
        schedule(context, reason, 0L, generation, false);
    }

    static void sendAutomaticNow(Context context, String reason) {
        long generation = replacePendingGeneration();
        schedule(context, reason, 0L, generation, true);
    }

    static void sendPlaybackStartedSequence(Context context) {
        long generation = replacePendingGeneration();
        schedule(context, "Spotify 已开始播放", 500L, generation, true);
        schedule(context, "Spotify 播放兜底重试", 2_500L, generation, true);
    }

    static void cancelPending() {
        replacePendingGeneration();
    }

    private static long replacePendingGeneration() {
        synchronized (PENDING_LOCK) {
            for (ScheduledFuture<?> pending : PENDING) pending.cancel(false);
            PENDING.clear();
            return GENERATION.incrementAndGet();
        }
    }

    private static void schedule(
            Context context, String reason, long delayMs, long generation, boolean requireAuto) {
        Context application = context.getApplicationContext();
        long deadline = android.os.SystemClock.elapsedRealtime() + EVENT_LIFETIME_MS;
        ScheduledFuture<?> future = EXECUTOR.schedule(() -> {
            if (generation != GENERATION.get()
                    || android.os.SystemClock.elapsedRealtime() > deadline) return;
            if (requireAuto && !new AppPreferences(application).isAutoEnabled()) return;
            TakeoverClient.Result result = new TakeoverClient(application).send(
                    deadline, requireAuto);
            if (generation != GENERATION.get()) return;
            new AppPreferences(application).setLastStatus(statusText(reason, result));
        }, delayMs, TimeUnit.MILLISECONDS);
        synchronized (PENDING_LOCK) {
            if (generation == GENERATION.get()) PENDING.add(future);
            else future.cancel(false);
        }
    }

    private static String statusText(String reason, TakeoverClient.Result result) {
        return switch (result) {
            case ACCEPTED -> reason + "：音箱已接收";
            case NOT_ON_WIFI -> reason + "：当前不是 Wi-Fi，未接管";
            case EXTERNAL_AUDIO_CONNECTED -> reason + "：耳机/车载/USB 音频已连接，未接管";
            case UNTRUSTED_WIFI -> reason + "：音箱密钥认证失败或暂时离线";
            case REJECTED -> reason + "：音箱拒绝了受限接管命令";
        };
    }

    private static final class DaemonThreadFactory implements ThreadFactory {
        @Override
        public Thread newThread(Runnable runnable) {
            Thread thread = new Thread(runnable, "xiaoai-takeover");
            thread.setDaemon(true);
            return thread;
        }
    }

    private TakeoverOrchestrator() {}
}
