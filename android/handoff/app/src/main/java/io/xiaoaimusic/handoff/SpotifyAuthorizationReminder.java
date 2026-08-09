package io.xiaoaimusic.handoff;

import android.Manifest;
import android.annotation.SuppressLint;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.os.Build;

final class SpotifyAuthorizationReminder {
    private static final Object LOCK = new Object();
    private static final String PREFS = "spotify_authorization_reminder_v1";
    private static final String LAST_NOTIFIED_AT = "last_notified_at";
    private static final String LAST_NOTIFIED_FOR_AUTHORIZED_AT =
            "last_notified_for_authorized_at";
    private static final String PERMISSION_REQUESTED = "notification_permission_requested";
    private static final String CHANNEL_ID = "spotify_authorization_expiry";
    private static final int NOTIFICATION_ID = 0x58414952;

    private SpotifyAuthorizationReminder() {}

    @SuppressLint("MissingPermission")
    static void maybeNotify(Context context) {
        Context app = context.getApplicationContext();
        synchronized (LOCK) {
            long authorizedAtMs = new SecureStore(app).getAuthorizedAtMs();
            long nowMs = System.currentTimeMillis();
            SharedPreferences preferences = preferences(app);
            if (!SpotifyAuthorizationExpiry.shouldNotify(
                    authorizedAtMs,
                    preferences.getLong(LAST_NOTIFIED_FOR_AUTHORIZED_AT, 0L),
                    preferences.getLong(LAST_NOTIFIED_AT, 0L),
                    nowMs)) {
                return;
            }
            NotificationManager notifications = app.getSystemService(NotificationManager.class);
            if (!canPostNotifications(app, notifications)) return;
            try {
                NotificationChannel channel = new NotificationChannel(
                        CHANNEL_ID, "Spotify 授权到期提醒", NotificationManager.IMPORTANCE_DEFAULT);
                channel.setDescription("Spotify 授权预计到期前的本地提醒");
                notifications.createNotificationChannel(channel);

                long remainingDays = SpotifyAuthorizationExpiry.remainingDays(
                        authorizedAtMs, nowMs);
                boolean expired = SpotifyAuthorizationExpiry.isExpired(authorizedAtMs, nowMs);
                String message = expired
                        ? "Spotify 授权已到预计有效期，请打开应用重新授权。"
                        : "Spotify 授权预计还剩 " + remainingDays + " 天，请打开应用重新授权。";
                Intent openApp = new Intent(app, MainActivity.class)
                        .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
                PendingIntent contentIntent = PendingIntent.getActivity(
                        app,
                        0,
                        openApp,
                        PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
                Notification notification = new Notification.Builder(app, CHANNEL_ID)
                        .setSmallIcon(R.drawable.ic_notification)
                        .setContentTitle("Spotify 授权到期提醒")
                        .setContentText(message)
                        .setStyle(new Notification.BigTextStyle().bigText(message))
                        .setCategory(Notification.CATEGORY_REMINDER)
                        .setContentIntent(contentIntent)
                        .setAutoCancel(true)
                        .setWhen(nowMs)
                        .setShowWhen(true)
                        .build();
                long previousForAuthorization = preferences.getLong(
                        LAST_NOTIFIED_FOR_AUTHORIZED_AT, 0L);
                long previousNotificationAt = preferences.getLong(LAST_NOTIFIED_AT, 0L);
                if (!preferences.edit()
                        .putLong(LAST_NOTIFIED_FOR_AUTHORIZED_AT, authorizedAtMs)
                        .putLong(LAST_NOTIFIED_AT, nowMs)
                        .commit()) {
                    return;
                }
                try {
                    notifications.notify(NOTIFICATION_ID, notification);
                } catch (RuntimeException notificationFailure) {
                    restoreReservation(
                            preferences, previousForAuthorization, previousNotificationAt);
                }
            } catch (RuntimeException notificationFailure) {
                // Notification failures must never break Spotify control or the status screen.
            }
        }
    }

    static boolean hasNotificationPermission(Context context) {
        NotificationManager notifications = context.getSystemService(NotificationManager.class);
        return canPostNotifications(context, notifications);
    }

    static void resetAfterAuthorization(Context context) {
        synchronized (LOCK) {
            preferences(context).edit()
                    .remove(LAST_NOTIFIED_FOR_AUTHORIZED_AT)
                    .remove(LAST_NOTIFIED_AT)
                    .apply();
            NotificationManager notifications = context.getSystemService(NotificationManager.class);
            if (notifications != null) notifications.cancel(NOTIFICATION_ID);
        }
    }

    static boolean claimFirstNotificationPermissionRequest(Context context) {
        if (Build.VERSION.SDK_INT < 33
                || context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                == PackageManager.PERMISSION_GRANTED) {
            return false;
        }
        synchronized (LOCK) {
            SharedPreferences preferences = preferences(context);
            if (preferences.getBoolean(PERMISSION_REQUESTED, false)) return false;
            return preferences.edit().putBoolean(PERMISSION_REQUESTED, true).commit();
        }
    }

    private static boolean canPostNotifications(
            Context context, NotificationManager notifications) {
        if (notifications == null || !notifications.areNotificationsEnabled()) return false;
        if (Build.VERSION.SDK_INT >= 33
                && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED) {
            return false;
        }
        NotificationChannel channel = notifications.getNotificationChannel(CHANNEL_ID);
        return channel == null || channel.getImportance() != NotificationManager.IMPORTANCE_NONE;
    }

    private static SharedPreferences preferences(Context context) {
        return context.getApplicationContext().getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    @SuppressLint("ApplySharedPref")
    private static void restoreReservation(
            SharedPreferences preferences,
            long previousForAuthorization,
            long previousNotificationAt) {
        SharedPreferences.Editor editor = preferences.edit();
        if (previousForAuthorization == 0L) {
            editor.remove(LAST_NOTIFIED_FOR_AUTHORIZED_AT);
        } else {
            editor.putLong(LAST_NOTIFIED_FOR_AUTHORIZED_AT, previousForAuthorization);
        }
        if (previousNotificationAt == 0L) {
            editor.remove(LAST_NOTIFIED_AT);
        } else {
            editor.putLong(LAST_NOTIFIED_AT, previousNotificationAt);
        }
        editor.commit();
    }
}
