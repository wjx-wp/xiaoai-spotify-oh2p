package io.xiaoaimusic.handoff;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;

public final class OAuthForegroundService extends Service {
    private static final String CHANNEL_ID = "spotify_authorization";
    private static final int NOTIFICATION_ID = 43827;

    static void start(Context context) {
        context.startForegroundService(new Intent(context, OAuthForegroundService.class));
    }

    static void finish(Context context) {
        context.stopService(new Intent(context, OAuthForegroundService.class));
    }

    @Override
    public void onCreate() {
        super.onCreate();
        NotificationManager notifications = getSystemService(NotificationManager.class);
        NotificationChannel channel = new NotificationChannel(
                CHANNEL_ID, "Spotify 授权", NotificationManager.IMPORTANCE_LOW);
        channel.setDescription("仅在浏览器授权期间保持本机回调端口可用");
        notifications.createNotificationChannel(channel);

        Intent openApp = new Intent(this, MainActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent contentIntent = PendingIntent.getActivity(
                this, 0, openApp, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Notification notification = new Notification.Builder(this, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_sys_upload)
                .setContentTitle("正在等待 Spotify 授权")
                .setContentText("完成后授权将直接安全下发到小爱音箱")
                .setContentIntent(contentIntent)
                .setOngoing(true)
                .setCategory(Notification.CATEGORY_SERVICE)
                .build();
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION_ID, notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SHORT_SERVICE);
        } else {
            startForeground(NOTIFICATION_ID, notification);
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        return START_NOT_STICKY;
    }

    @Override
    public void onTimeout(int startId) {
        SpotifyAuthCoordinator.cancelForServiceTimeout(this);
        stopSelf(startId);
    }

    @Override
    public void onTimeout(int startId, int foregroundServiceType) {
        SpotifyAuthCoordinator.cancelForServiceTimeout(this);
        stopSelf(startId);
    }

    @Override
    public void onDestroy() {
        SpotifyAuthCoordinator.cancelForServiceStopped();
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
