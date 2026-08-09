package io.xiaoaimusic.handoff;

import android.content.Context;
import android.media.AudioDeviceInfo;
import android.media.AudioManager;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;

final class TakeoverPolicy {
    enum Decision {
        ALLOW,
        NOT_ON_WIFI,
        EXTERNAL_AUDIO_CONNECTED
    }

    static Decision evaluate(Context context) {
        ConnectivityManager connectivity = context.getSystemService(ConnectivityManager.class);
        Network active = connectivity == null ? null : connectivity.getActiveNetwork();
        NetworkCapabilities capabilities = active == null
                ? null : connectivity.getNetworkCapabilities(active);
        if (capabilities == null || !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
            return Decision.NOT_ON_WIFI;
        }

        AudioManager audio = context.getSystemService(AudioManager.class);
        if (audio != null) {
            for (AudioDeviceInfo device : audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS)) {
                if (isExternalPrivateOutput(device.getType())) {
                    return Decision.EXTERNAL_AUDIO_CONNECTED;
                }
            }
        }
        return Decision.ALLOW;
    }

    static boolean isExternalPrivateOutput(int type) {
        return switch (type) {
            case AudioDeviceInfo.TYPE_WIRED_HEADSET,
                    AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
                    AudioDeviceInfo.TYPE_USB_ACCESSORY,
                    AudioDeviceInfo.TYPE_USB_DEVICE,
                    AudioDeviceInfo.TYPE_USB_HEADSET,
                    AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
                    AudioDeviceInfo.TYPE_HEARING_AID,
                    AudioDeviceInfo.TYPE_BLE_HEADSET,
                    AudioDeviceInfo.TYPE_BLE_SPEAKER,
                    AudioDeviceInfo.TYPE_BLE_BROADCAST,
                    AudioDeviceInfo.TYPE_HDMI,
                    AudioDeviceInfo.TYPE_HDMI_ARC,
                    AudioDeviceInfo.TYPE_HDMI_EARC,
                    AudioDeviceInfo.TYPE_LINE_ANALOG,
                    AudioDeviceInfo.TYPE_LINE_DIGITAL,
                    AudioDeviceInfo.TYPE_AUX_LINE,
                    AudioDeviceInfo.TYPE_DOCK,
                    AudioDeviceInfo.TYPE_BUS,
                    AudioDeviceInfo.TYPE_REMOTE_SUBMIX -> true;
            default -> false;
        };
    }

    private TakeoverPolicy() {}
}
