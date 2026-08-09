package io.xiaoaimusic.handoff;

import android.content.Context;
import android.content.SharedPreferences;

final class AppPreferences {
    private static final String PREFS = "app_state";
    private static final String AUTO_ENABLED = "auto_enabled";
    private static final String LAST_STATUS = "last_status";
    private static final String LAST_STATUS_AT = "last_status_at";
    private static final String SPEAKER_HOST = "speaker_host";

    private final SharedPreferences preferences;

    AppPreferences(Context context) {
        preferences = context.getApplicationContext()
                .getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    boolean isAutoEnabled() {
        return preferences.getBoolean(AUTO_ENABLED, true);
    }

    void setAutoEnabled(boolean enabled) {
        preferences.edit().putBoolean(AUTO_ENABLED, enabled).apply();
    }

    void setLastStatus(String status) {
        preferences.edit()
                .putString(LAST_STATUS, status)
                .putLong(LAST_STATUS_AT, System.currentTimeMillis())
                .apply();
    }

    String getLastStatus() {
        return preferences.getString(LAST_STATUS, "尚未发送接管请求");
    }

    long getLastStatusAt() {
        return preferences.getLong(LAST_STATUS_AT, 0L);
    }

    String getSpeakerHost() {
        String stored = preferences.getString(SPEAKER_HOST, AppConfig.DEFAULT_SPEAKER_HOST);
        return Ipv4AddressRules.isPrivateUnicast(stored)
                ? stored : AppConfig.DEFAULT_SPEAKER_HOST;
    }

    boolean setSpeakerHost(String host) {
        if (!Ipv4AddressRules.isPrivateUnicast(host)) return false;
        preferences.edit().putString(SPEAKER_HOST, host).apply();
        return true;
    }
}
