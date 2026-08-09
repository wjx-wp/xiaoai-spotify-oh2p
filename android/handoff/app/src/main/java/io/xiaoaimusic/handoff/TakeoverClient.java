package io.xiaoaimusic.handoff;

import android.content.Context;

final class TakeoverClient {
    enum Result {
        ACCEPTED,
        NOT_ON_WIFI,
        EXTERNAL_AUDIO_CONNECTED,
        UNTRUSTED_WIFI,
        REJECTED
    }

    private final Context context;
    TakeoverClient(Context context) {
        this.context = context.getApplicationContext();
    }

    Result send(long eventDeadlineElapsedMs, boolean requireAuto) {
        if (requireAuto && !new AppPreferences(context).isAutoEnabled()) {
            return Result.REJECTED;
        }
        TakeoverPolicy.Decision decision = TakeoverPolicy.evaluate(context);
        if (decision == TakeoverPolicy.Decision.NOT_ON_WIFI) return Result.NOT_ON_WIFI;
        if (decision == TakeoverPolicy.Decision.EXTERNAL_AUDIO_CONNECTED) {
            return Result.EXTERNAL_AUDIO_CONNECTED;
        }
        if (TrustedSshSessionCache.currentWifiNetwork(context) == null) {
            return Result.NOT_ON_WIFI;
        }
        return TrustedSshSessionCache.requestTakeover(
                context, eventDeadlineElapsedMs, requireAuto)
                ? Result.ACCEPTED : Result.UNTRUSTED_WIFI;
    }
}
