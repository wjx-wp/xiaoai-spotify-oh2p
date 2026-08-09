package io.xiaoaimusic.handoff;

import android.app.Application;
import android.annotation.SuppressLint;
import android.content.Context;
import android.content.IntentFilter;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.os.Build;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class HandoffApplication extends Application {
    private SpotifyPlaybackReceiver playbackReceiver;
    private ConnectivityManager.NetworkCallback networkCallback;
    private final ExecutorService trustExecutor = Executors.newSingleThreadExecutor(runnable -> {
        Thread thread = new Thread(runnable, "xiaoai-network-trust");
        thread.setDaemon(true);
        return thread;
    });

    @Override
    public void onCreate() {
        super.onCreate();
        AppPreferences state = new AppPreferences(this);
        try {
            new SshKeyManager(this).exportPublicKey();
        } catch (Exception failure) {
            state.setLastStatus("手机安全签名密钥初始化失败，请重新打开应用");
        }

        playbackReceiver = new SpotifyPlaybackReceiver();
        IntentFilter filter = new IntentFilter(AppConfig.SPOTIFY_PLAYBACK_ACTION);
        registerSpotifyReceiver(filter);

        ConnectivityManager connectivity = getSystemService(ConnectivityManager.class);
        if (connectivity != null) {
            networkCallback = new ConnectivityManager.NetworkCallback() {
                @Override
                public void onAvailable(Network network) {
                    refreshNetworkTrust();
                }

                @Override
                public void onLost(Network network) {
                    TrustedSshSessionCache.invalidateIfMatches(network.getNetworkHandle());
                }

                @Override
                public void onCapabilitiesChanged(
                        Network network, NetworkCapabilities networkCapabilities) {
                    Network current = TrustedSshSessionCache.currentWifiNetwork(
                            HandoffApplication.this);
                    if (current == null || !current.equals(network)) {
                        TrustedSshSessionCache.invalidateIfMatches(network.getNetworkHandle());
                    } else {
                        trustExecutor.execute(() -> TrustedSshSessionCache.prewarm(
                                HandoffApplication.this));
                    }
                }
            };
            connectivity.registerDefaultNetworkCallback(networkCallback);
            refreshNetworkTrust();
        }
    }

    @SuppressLint("UnspecifiedRegisterReceiverFlag")
    private void registerSpotifyReceiver(IntentFilter filter) {
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(playbackReceiver, filter, Context.RECEIVER_EXPORTED);
        } else {
            registerReceiver(playbackReceiver, filter);
        }
    }

    private void refreshNetworkTrust() {
        TrustedSshSessionCache.invalidate();
        trustExecutor.execute(() -> TrustedSshSessionCache.prewarm(this));
    }
}
