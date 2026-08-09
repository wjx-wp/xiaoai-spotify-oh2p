package io.xiaoaimusic.handoff;

import android.Manifest;
import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.ComponentName;
import android.content.Intent;
import android.graphics.Color;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.text.TextUtils;
import android.text.format.DateFormat;
import android.text.InputType;
import android.view.View;
import android.widget.Button;
import android.widget.CompoundButton;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.Switch;
import android.widget.TextView;
import android.widget.Toast;

import java.util.Date;

public final class MainActivity extends Activity {
    private static final int REQUEST_NOTIFICATION_PERMISSION = 1_002;

    private TextView pairingStatus;
    private TextView accessibilityStatus;
    private TextView authorizationExpiryStatus;
    private TextView lastStatus;
    private Switch autoSwitch;
    private Button authorizationButton;
    private Button retryAuthorizationButton;
    private EditText speakerHostInput;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(buildContent());
        requestNotificationPermissionIfNeeded();
    }

    @Override
    protected void onResume() {
        super.onResume();
        refreshStatus();
        SpotifyAuthorizationReminder.maybeNotify(this);
        mainHandler.postDelayed(this::refreshPairingStatus, 1_500L);
    }

    private View buildContent() {
        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        LinearLayout content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        int padding = dp(24);
        content.setPadding(padding, dp(28), padding, dp(40));
        scroll.addView(content, new ScrollView.LayoutParams(
                ScrollView.LayoutParams.MATCH_PARENT, ScrollView.LayoutParams.WRAP_CONTENT));

        TextView title = text("小爱 Spotify 接管", 28, Color.rgb(24, 26, 30));
        title.setTypeface(title.getTypeface(), android.graphics.Typeface.BOLD);
        content.addView(title);
        TextView subtitle = text(
                "在家打开或播放 Spotify 时，自动把声音移到小爱音箱；耳机、车载或 USB 音频连接时不会抢走播放。",
                16, Color.rgb(85, 90, 98));
        subtitle.setPadding(0, dp(8), 0, dp(24));
        content.addView(subtitle);

        content.addView(section("安全配对"));
        pairingStatus = text("正在检查…", 16, Color.DKGRAY);
        pairingStatus.setPadding(0, dp(8), 0, dp(18));
        content.addView(pairingStatus);
        TextView hostLabel = text("音箱局域网 IPv4 地址", 14, Color.rgb(95, 99, 107));
        content.addView(hostLabel);
        speakerHostInput = new EditText(this);
        speakerHostInput.setSingleLine(true);
        speakerHostInput.setInputType(InputType.TYPE_CLASS_PHONE);
        speakerHostInput.setTextSize(17);
        speakerHostInput.setContentDescription("音箱局域网 IPv4 地址");
        content.addView(speakerHostInput, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT));
        Button saveHost = button("保存音箱地址并重新认证");
        saveHost.setOnClickListener(view -> saveSpeakerHost());
        content.addView(saveHost);
        Button copyPairingKey = button("复制手机配对公钥");
        copyPairingKey.setOnClickListener(view -> copyPairingPublicKey());
        content.addView(copyPairingKey);

        content.addView(section("自动接管"));
        autoSwitch = new Switch(this);
        autoSwitch.setText("启用自动接管");
        autoSwitch.setTextSize(17);
        autoSwitch.setPadding(0, dp(8), 0, dp(8));
        autoSwitch.setOnCheckedChangeListener(this::onAutoChanged);
        content.addView(autoSwitch);

        accessibilityStatus = text("", 14, Color.rgb(95, 99, 107));
        accessibilityStatus.setPadding(0, 0, 0, dp(10));
        content.addView(accessibilityStatus);
        Button accessibility = button("打开系统无障碍设置");
        accessibility.setOnClickListener(view -> startActivity(
                new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)));
        content.addView(accessibility);

        TextView spotifyHint = text(
                "还需在 Spotify 设置中打开 “Device Broadcast Status”，它只发送播放/暂停状态，不开放账户内容。",
                14, Color.rgb(95, 99, 107));
        spotifyHint.setPadding(0, dp(12), 0, dp(8));
        content.addView(spotifyHint);
        Button openSpotify = button("打开 Spotify");
        openSpotify.setOnClickListener(view -> openSpotify());
        content.addView(openSpotify);

        Button test = button("测试接管");
        LinearLayout.LayoutParams testParams = buttonParams();
        testParams.topMargin = dp(18);
        test.setLayoutParams(testParams);
        test.setOnClickListener(view -> {
            TakeoverOrchestrator.sendNow(this, "手动测试");
            Toast.makeText(this, "已发送，正在检查家庭网络", Toast.LENGTH_SHORT).show();
            mainHandler.postDelayed(this::refreshStatus, 2_100L);
        });
        content.addView(test);

        content.addView(sectionWithTop("Spotify 授权", 28));
        TextView authDescription = text(
                "授权在手机浏览器完成。应用先用同次响应的临时访问凭证向 Spotify 官方做只读验证；通过后才允许刷新令牌经受限 SSH 下发，成功后手机删除两种凭证。",
                14, Color.rgb(95, 99, 107));
        authDescription.setPadding(0, dp(8), 0, dp(10));
        content.addView(authDescription);
        authorizationExpiryStatus = text("", 14, Color.rgb(50, 54, 61));
        authorizationExpiryStatus.setPadding(0, 0, 0, dp(10));
        content.addView(authorizationExpiryStatus);
        authorizationButton = button("重新授权 Spotify");
        authorizationButton.setOnClickListener(view -> startNewAuthorization());
        content.addView(authorizationButton);
        retryAuthorizationButton = button("重新验证并下发");
        retryAuthorizationButton.setVisibility(View.GONE);
        retryAuthorizationButton.setOnClickListener(view -> retryPendingAuthorization());
        content.addView(retryAuthorizationButton);

        content.addView(sectionWithTop("最近状态", 28));
        lastStatus = text("", 15, Color.rgb(50, 54, 61));
        lastStatus.setPadding(0, dp(8), 0, 0);
        content.addView(lastStatus);
        return scroll;
    }

    private void onAutoChanged(CompoundButton button, boolean enabled) {
        if (!button.isPressed()) return;
        new AppPreferences(this).setAutoEnabled(enabled);
        if (!enabled) {
            TakeoverOrchestrator.cancelPending();
            TrustedSshSessionCache.abortInFlight();
        }
        refreshStatus();
    }

    private void startNewAuthorization() {
        authorizationButton.setEnabled(false);
        SpotifyAuthCoordinator.Listener listener = (success, message) -> {
            authorizationButton.setEnabled(true);
            if (success) SpotifyAuthorizationReminder.resetAfterAuthorization(this);
            Toast.makeText(this, message, Toast.LENGTH_LONG).show();
            refreshStatus();
        };
        SpotifyAuthCoordinator.authorize(this, listener);
    }

    private void retryPendingAuthorization() {
        retryAuthorizationButton.setEnabled(false);
        SpotifyAuthCoordinator.retryPending(this, (success, message) -> {
            retryAuthorizationButton.setEnabled(true);
            Toast.makeText(this, message, Toast.LENGTH_LONG).show();
            refreshStatus();
        });
    }

    private void refreshStatus() {
        SecureStore store = new SecureStore(this);
        refreshPairingStatus();
        if (!speakerHostInput.hasFocus()) {
            speakerHostInput.setText(new AppPreferences(this).getSpeakerHost());
        }
        boolean accessibilityEnabled = isAccessibilityEnabled();

        accessibilityStatus.setText(accessibilityEnabled
                ? "Spotify 启动预接管：系统服务已开启"
                : "需手动开启；它也负责让后台播放广播保持可靠");
        autoSwitch.setOnCheckedChangeListener(null);
        autoSwitch.setChecked(new AppPreferences(this).isAutoEnabled());
        autoSwitch.setOnCheckedChangeListener(this::onAutoChanged);
        PendingAuthorizationState pendingState = store.pendingState(System.currentTimeMillis());
        if (pendingState == PendingAuthorizationState.INVALID
                || pendingState == PendingAuthorizationState.ACCESS_EXPIRED
                || pendingState == PendingAuthorizationState.AUTHORIZATION_EXPIRED) {
            try {
                store.discardPendingAuthorization();
            } catch (Exception ignored) {
                // A failed cleanup remains non-uploadable and will be retried next refresh.
            }
            pendingState = PendingAuthorizationState.NONE;
        }
        retryAuthorizationButton.setVisibility(
                pendingState == PendingAuthorizationState.NEEDS_VERIFICATION
                        || pendingState == PendingAuthorizationState.VERIFIED_READY
                        ? View.VISIBLE : View.GONE);
        retryAuthorizationButton.setText(
                pendingState == PendingAuthorizationState.NEEDS_VERIFICATION
                        ? "重新验证并下发" : "重试下发已验证授权");
        refreshAuthorizationExpiryStatus(store);

        AppPreferences state = new AppPreferences(this);
        long time = state.getLastStatusAt();
        String timestamp = time == 0L ? "" : DateFormat.getMediumDateFormat(this).format(new Date(time))
                + " " + DateFormat.getTimeFormat(this).format(new Date(time));
        lastStatus.setText(time == 0L ? state.getLastStatus()
                : getString(R.string.last_status_with_time, state.getLastStatus(), timestamp));
    }

    private void refreshAuthorizationExpiryStatus(SecureStore store) {
        long authorizedAtMs = store.getAuthorizedAtMs();
        long expiryAtMs = SpotifyAuthorizationExpiry.estimatedExpiryAtMs(authorizedAtMs);
        long nowMs = System.currentTimeMillis();
        PendingAuthorizationState state = store.pendingState(nowMs);
        String pendingState = switch (state) {
            case NEEDS_VERIFICATION -> getString(
                    R.string.spotify_authorization_pending_verification);
            case VERIFIED_READY -> getString(R.string.spotify_authorization_pending_upload);
            default -> "";
        };
        if (expiryAtMs == 0L) {
            authorizationExpiryStatus.setText(
                    getString(R.string.spotify_authorization_date_unavailable) + pendingState);
            return;
        }
        long remainingDays = SpotifyAuthorizationExpiry.remainingDays(authorizedAtMs, nowMs);
        String authorizedDate = DateFormat.getMediumDateFormat(this)
                .format(new Date(authorizedAtMs));
        String expiryDate = DateFormat.getMediumDateFormat(this).format(new Date(expiryAtMs));
        String remaining = SpotifyAuthorizationExpiry.isExpired(authorizedAtMs, nowMs)
                ? getString(R.string.spotify_authorization_expired)
                : getString(R.string.spotify_authorization_remaining_days, remainingDays);
        String notificationState = SpotifyAuthorizationReminder.hasNotificationPermission(this)
                ? getString(R.string.spotify_authorization_notification_enabled)
                : getString(R.string.spotify_authorization_notification_disabled);
        authorizationExpiryStatus.setText(getString(
                R.string.spotify_authorization_expiry_status,
                authorizedDate,
                expiryDate,
                remaining,
                notificationState,
                pendingState));
    }

    private void requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= 33
                && SpotifyAuthorizationReminder.claimFirstNotificationPermissionRequest(this)) {
            requestPermissions(
                    new String[] {Manifest.permission.POST_NOTIFICATIONS},
                    REQUEST_NOTIFICATION_PERMISSION);
        }
    }

    @Override
    public void onRequestPermissionsResult(
            int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode != REQUEST_NOTIFICATION_PERMISSION) return;
        refreshStatus();
        if (grantResults.length > 0
                && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            SpotifyAuthorizationReminder.maybeNotify(this);
        }
    }

    private void refreshPairingStatus() {
        pairingStatus.setText(TrustedSshSessionCache.isConnectedForCurrentNetwork(this)
                ? "已通过固定主机指纹和手机签名密钥认证"
                : "等待家庭 Wi-Fi 与音箱公钥认证（不会保存音箱密码）");
    }

    private void saveSpeakerHost() {
        String host = speakerHostInput.getText().toString().trim();
        AppPreferences preferences = new AppPreferences(this);
        if (!preferences.setSpeakerHost(host)) {
            Toast.makeText(this, "请输入有效的家庭私网 IPv4 地址", Toast.LENGTH_LONG).show();
            return;
        }
        speakerHostInput.clearFocus();
        pairingStatus.setText("正在用固定主机指纹重新认证…");
        Thread worker = new Thread(() -> {
            TrustedSshSessionCache.invalidate();
            boolean connected = TrustedSshSessionCache.prewarm(this);
            runOnUiThread(() -> {
                Toast.makeText(this, connected ? "音箱地址已认证" : "地址已保存，但暂时无法认证音箱",
                        Toast.LENGTH_LONG).show();
                refreshStatus();
            });
        }, "xiaoai-host-save");
        worker.setDaemon(true);
        worker.start();
    }

    private void copyPairingPublicKey() {
        Thread worker = new Thread(() -> {
            try {
                String publicKey = new SshKeyManager(this).publicKeyLine();
                runOnUiThread(() -> {
                    ClipboardManager clipboard = getSystemService(ClipboardManager.class);
                    if (clipboard == null) {
                        Toast.makeText(this, "系统剪贴板不可用", Toast.LENGTH_LONG).show();
                        return;
                    }
                    clipboard.setPrimaryClip(ClipData.newPlainText(
                            "小爱 Spotify 手机配对公钥", publicKey));
                    Toast.makeText(this, "配对公钥已复制（公钥不含密码）",
                            Toast.LENGTH_LONG).show();
                });
            } catch (Exception failure) {
                runOnUiThread(() -> Toast.makeText(this,
                        "无法读取手机配对公钥，请重新打开应用", Toast.LENGTH_LONG).show());
            }
        }, "xiaoai-copy-public-key");
        worker.setDaemon(true);
        worker.start();
    }

    private boolean isAccessibilityEnabled() {
        if (Settings.Secure.getInt(getContentResolver(),
                Settings.Secure.ACCESSIBILITY_ENABLED, 0) != 1) return false;
        String enabled = Settings.Secure.getString(
                getContentResolver(), Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES);
        if (TextUtils.isEmpty(enabled)) return false;
        ComponentName ours = new ComponentName(this, SpotifyAccessibilityService.class);
        TextUtils.SimpleStringSplitter splitter = new TextUtils.SimpleStringSplitter(':');
        splitter.setString(enabled);
        while (splitter.hasNext()) {
            ComponentName component = ComponentName.unflattenFromString(splitter.next());
            if (ours.equals(component)) return true;
        }
        return false;
    }

    private void openSpotify() {
        Intent launch = getPackageManager().getLaunchIntentForPackage(AppConfig.SPOTIFY_PACKAGE);
        if (launch == null) {
            Toast.makeText(this, "手机上没有找到 Spotify", Toast.LENGTH_LONG).show();
            return;
        }
        startActivity(launch);
    }

    private TextView section(String value) {
        return sectionWithTop(value, 0);
    }

    private TextView sectionWithTop(String value, int topDp) {
        TextView view = text(value, 19, Color.rgb(25, 28, 33));
        view.setTypeface(view.getTypeface(), android.graphics.Typeface.BOLD);
        view.setPadding(0, dp(topDp), 0, 0);
        return view;
    }

    private TextView text(String value, int sp, int color) {
        TextView view = new TextView(this);
        view.setText(value);
        view.setTextSize(sp);
        view.setTextColor(color);
        view.setLineSpacing(0f, 1.15f);
        return view;
    }

    private Button button(String label) {
        Button button = new Button(this);
        button.setText(label);
        button.setTextSize(16);
        button.setAllCaps(false);
        button.setLayoutParams(buttonParams());
        return button;
    }

    private LinearLayout.LayoutParams buttonParams() {
        return new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}
