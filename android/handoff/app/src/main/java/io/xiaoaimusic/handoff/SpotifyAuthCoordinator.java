package io.xiaoaimusic.handoff;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.atomic.AtomicReference;

final class SpotifyAuthCoordinator {
    interface Listener {
        void onFinished(boolean success, String message);
    }

    private static final ExecutorService EXECUTOR = Executors.newSingleThreadExecutor(runnable -> {
        Thread thread = new Thread(runnable, "spotify-oauth");
        thread.setDaemon(true);
        return thread;
    });
    private static final AtomicReference<Operation> ACTIVE = new AtomicReference<>();

    static void authorize(Activity activity, Listener listener) {
        Operation operation = new Operation(activity, listener);
        if (!ACTIVE.compareAndSet(null, operation)) {
            listener.onFinished(false, "已有一个 Spotify 授权正在进行");
            return;
        }

        OAuthPkce.Values pkce = OAuthPkce.generate();
        try {
            operation.callback = new OAuthCallbackServer(pkce.state());
        } catch (Exception failure) {
            cancel(operation, "无法启动本机授权回调，请稍后重试");
            return;
        }
        try {
            OAuthForegroundService.start(activity);
        } catch (Exception failure) {
            cancel(operation, "无法启动授权保活服务，请稍后重试");
            return;
        }

        Uri authorizationUri = Uri.parse(AppConfig.SPOTIFY_AUTHORIZE_URL).buildUpon()
                .appendQueryParameter("response_type", "code")
                .appendQueryParameter("client_id", AppConfig.SPOTIFY_CLIENT_ID)
                .appendQueryParameter("redirect_uri", AppConfig.SPOTIFY_REDIRECT_URI)
                .appendQueryParameter("scope", AppConfig.SPOTIFY_SCOPES)
                .appendQueryParameter("state", pkce.state())
                .appendQueryParameter("code_challenge_method", "S256")
                .appendQueryParameter("code_challenge", pkce.challenge())
                .build();

        operation.task = EXECUTOR.submit(() -> {
            try {
                String code = operation.callback.awaitCode();
                ensureActive(operation);
                operation.stage = AuthorizationStage.TOKEN_EXCHANGE;
                try (SpotifyTokenExchange.Authorization authorization =
                             SpotifyTokenExchange.exchange(code, pkce.verifier())) {
                    ensureActive(operation);
                    operation.stage = AuthorizationStage.LOCAL_ENCRYPT;
                    SecureStore store = new SecureStore(operation.context);
                    // A single synchronous SharedPreferences commit replaces any prior pending
                    // bundle before its access token is used to establish provenance.
                    operation.gate.commit(() -> store.savePendingAuthorization(authorization));
                    operation.stage = AuthorizationStage.SPOTIFY_VERIFY;
                    verifyAndUploadPending(operation, store);
                }
                complete(operation, true, "Spotify 已授权并安全下发到音箱");
            } catch (Exception failure) {
                complete(operation, false,
                        safeFailureMessage(operation.context, operation.stage, failure));
            }
        });

        try {
            activity.startActivity(new Intent(Intent.ACTION_VIEW, authorizationUri));
        } catch (Exception failure) {
            cancel(operation, "没有可打开 Spotify 授权页的浏览器");
        }
    }

    static void retryPending(Context context, Listener listener) {
        Operation operation = new Operation(context, listener);
        if (!ACTIVE.compareAndSet(null, operation)) {
            listener.onFinished(false, "已有一个授权任务正在进行");
            return;
        }
        try {
            OAuthForegroundService.start(context);
        } catch (Exception failure) {
            cancel(operation, "无法启动授权保活服务，请重新打开应用后重试");
            return;
        }
        operation.task = EXECUTOR.submit(() -> {
            try {
                SecureStore store = new SecureStore(operation.context);
                ensureActive(operation);
                verifyAndUploadPending(operation, store);
                complete(operation, true, "Spotify 授权已重新验证并写入音箱");
            } catch (Exception failure) {
                complete(operation, false,
                        safeFailureMessage(operation.context, operation.stage, failure));
            }
        });
    }

    static void cancelForServiceTimeout(Context context) {
        Operation operation = ACTIVE.get();
        if (operation != null) {
            cancel(operation, "授权任务已停止；若音箱已收到更新，保留状态可在应用内重试确认");
        } else {
            new AppPreferences(context).setLastStatus("Spotify 授权总时限已到，请重试");
        }
    }

    static void cancelForServiceStopped() {
        Operation operation = ACTIVE.get();
        if (operation != null) {
            cancel(operation, "授权任务已停止；若音箱已收到更新，保留状态可在应用内重试确认");
        }
    }

    private static void verifyAndUploadPending(Operation operation, SecureStore store)
            throws Exception {
        long nowMs = System.currentTimeMillis();
        try (SecureStore.PendingAuthorization pending = store.getPendingAuthorization()) {
            if (pending == null) throw new SecurityException("没有可下发的 Spotify 授权");
            PendingAuthorizationState state = pending.state(nowMs);
            if (state == PendingAuthorizationState.INVALID
                    || state == PendingAuthorizationState.ACCESS_EXPIRED
                    || state == PendingAuthorizationState.AUTHORIZATION_EXPIRED) {
                operation.gate.commit(store::discardPendingAuthorization);
                throw new ReauthorizationRequiredException();
            }
            if (state == PendingAuthorizationState.NEEDS_VERIFICATION) {
                ensureActive(operation);
                operation.stage = AuthorizationStage.SPOTIFY_VERIFY;
                try {
                    SpotifyAccessTokenVerifier.verify(pending.accessToken());
                } catch (SpotifyAccessTokenVerifier.AccessTokenRejectedException rejected) {
                    operation.gate.commit(store::discardPendingAuthorization);
                    throw rejected;
                }
                ensureActive(operation);
                operation.gate.commit(() -> store.markPendingVerified(
                        pending.provenance(), System.currentTimeMillis()));
            }
        }

        ensureActive(operation);
        try (SecureStore.PendingAuthorization verified = store.getPendingAuthorization()) {
            if (verified == null
                    || verified.state(System.currentTimeMillis())
                    != PendingAuthorizationState.VERIFIED_READY) {
                throw new SecurityException("Spotify 授权尚未完成官方验证");
            }
            byte[] provenance = verified.provenance().clone();
            try {
                operation.stage = AuthorizationStage.SSH_UPLOAD;
                SshKeyManager keys = new SshKeyManager(operation.context);
                boolean reconcilePriorAttempt = verified.remoteAttempted();
                operation.gate.commit(() -> store.markPendingRemoteAttempted(
                        provenance, System.currentTimeMillis()));
                operation.gate.beginRemoteCommit();
                try {
                    new RestrictedSshUploader(operation.context, keys)
                            .upload(verified.refreshToken(), verified.authorizedAtMs(),
                                    reconcilePriorAttempt);
                    operation.gate.commitRemoteSuccess(() -> store.markAuthorizationUploaded(
                            provenance, System.currentTimeMillis()));
                } catch (Exception failure) {
                    operation.gate.remoteFailed();
                    throw failure;
                }
            } finally {
                java.util.Arrays.fill(provenance, (byte) 0);
            }
        }
    }

    private static void ensureActive(Operation operation) throws InterruptedException {
        operation.gate.ensureActive();
    }

    private static void complete(
            Operation operation, boolean success, String message) {
        if (!operation.gate.finish()) return;
        ACTIVE.compareAndSet(operation, null);
        closeCallback(operation);
        OAuthForegroundService.finish(operation.context);
        publish(operation, success, message);
    }

    private static void cancel(Operation operation, String message) {
        CancellationCommitGate.CancelResult cancelResult = operation.gate.cancel();
        if (cancelResult == CancellationCommitGate.CancelResult.ALREADY_TERMINAL) return;
        ACTIVE.compareAndSet(operation, null);
        closeCallback(operation);
        Future<?> task = operation.task;
        if (task != null) task.cancel(true);
        OAuthForegroundService.finish(operation.context);
        String published = cancelResult == CancellationCommitGate.CancelResult.REMOTE_RESULT_UNCERTAIN
                ? "任务已停止，但音箱写入结果待核对；已验证授权仍保留，可稍后重试确认"
                : message;
        publish(operation, false, published);
    }

    private static void closeCallback(Operation operation) {
        OAuthCallbackServer callback = operation.callback;
        if (callback == null) return;
        try {
            callback.close();
        } catch (Exception ignored) {
            // Closing an already-closed loopback server is harmless.
        }
        operation.callback = null;
    }

    private static void publish(
            Operation operation, boolean success, String message) {
        new AppPreferences(operation.context).setLastStatus(message);
        new Handler(Looper.getMainLooper()).post(
                () -> operation.listener.onFinished(success, message));
    }

    private static String safeFailureMessage(
            Context context, AuthorizationStage stage, Exception failure) {
        PendingAuthorizationState pendingState = PendingAuthorizationState.NONE;
        try {
            pendingState = new SecureStore(context).pendingState(System.currentTimeMillis());
        } catch (Exception ignored) {
            // Failure reporting must never weaken or mutate the encrypted authorization state.
        }
        return safeFailureMessage(pendingState, stage, failure);
    }

    static String safeFailureMessage(
            PendingAuthorizationState pendingState, Exception failure) {
        return safeFailureMessage(pendingState, AuthorizationStage.TOKEN_EXCHANGE, failure);
    }

    static String safeFailureMessage(
            PendingAuthorizationState pendingState,
            AuthorizationStage stage,
            Exception failure) {
        String httpStatus = spotifyHttpStatus(failure.getMessage());
        if (pendingState == PendingAuthorizationState.VERIFIED_READY) {
            return "Spotify 官方验证已通过，但音箱安全下发失败；授权已加密保留，可点“重试下发已验证授权”";
        }
        if (pendingState == PendingAuthorizationState.NEEDS_VERIFICATION) {
            return httpStatus == null
                    ? "新授权已加密保存，但 Spotify 官方只读验证暂时失败；可点“重新验证并下发”"
                    : "新授权已加密保存，但 Spotify 官方只读验证返回 HTTP "
                            + httpStatus + "；可点“重新验证并下发”";
        }
        if (failure instanceof ReauthorizationRequiredException
                || failure instanceof SpotifyAccessTokenVerifier.AccessTokenRejectedException) {
            return "Spotify 临时访问凭证已失效，请重新通过浏览器授权";
        }
        String message = failure.getMessage();
        if (message != null && (message.contains("state") || message.contains("Spotify 返回"))) {
            return "Spotify 授权失败：" + message;
        }
        if (failure instanceof java.net.SocketTimeoutException
                && message != null && message.contains("OAuth callback")) {
            return "等待 Spotify 浏览器授权超时，请重新发起";
        }
        String failureCode = safeFailureCode(failure);
        if (stage == AuthorizationStage.LOCAL_ENCRYPT) {
            return "Spotify 已返回令牌，但手机本地加密保存失败（" + failureCode
                    + "）；现有音箱授权未被覆盖";
        }
        if (httpStatus != null) {
            return "Spotify 授权码换取令牌失败（HTTP " + httpStatus + "），请重新授权";
        }
        if (message != null && (message.contains("token response")
                || message.contains("token type")
                || message.contains("required scope")
                || message.contains("expires_in")
                || message.contains("invalid token"))) {
            return "Spotify 返回的授权数据未通过完整性检查，请重新授权";
        }
        if (failure instanceof java.net.SocketTimeoutException) {
            return "连接 Spotify 换取令牌超时，请重新授权";
        }
        return "Spotify 授权码尚未换成可保存的令牌（" + failureCode + "），请重新授权";
    }

    private static String safeFailureCode(Exception failure) {
        if (failure instanceof javax.net.ssl.SSLException) return "TOKEN_EXCHANGE_TLS";
        if (failure instanceof java.net.UnknownHostException) return "TOKEN_EXCHANGE_DNS";
        if (failure instanceof java.net.SocketTimeoutException) return "TOKEN_EXCHANGE_TIMEOUT";
        if (failure instanceof java.security.GeneralSecurityException
                || failure instanceof java.security.ProviderException) return "LOCAL_CRYPTO";
        if (failure instanceof SecurityException) return "RESPONSE_VALIDATION";
        if (failure instanceof org.json.JSONException) return "RESPONSE_JSON";
        if (failure instanceof java.io.IOException) return "TOKEN_EXCHANGE_IO";
        return "LOCAL_STATE";
    }

    private static String spotifyHttpStatus(String message) {
        if (message == null || !message.startsWith("Spotify ")) return null;
        java.util.regex.Matcher matcher = java.util.regex.Pattern
                .compile("(?:^| )([3-5][0-9]{2})$")
                .matcher(message);
        return matcher.find() ? matcher.group(1) : null;
    }

    private static final class Operation {
        final Context context;
        final Listener listener;
        final CancellationCommitGate gate = new CancellationCommitGate();
        volatile OAuthCallbackServer callback;
        volatile Future<?> task;
        volatile AuthorizationStage stage = AuthorizationStage.CALLBACK;

        Operation(Context context, Listener listener) {
            this.context = context.getApplicationContext();
            this.listener = listener;
        }
    }

    enum AuthorizationStage {
        CALLBACK,
        TOKEN_EXCHANGE,
        LOCAL_ENCRYPT,
        SPOTIFY_VERIFY,
        SSH_UPLOAD
    }

    private static final class ReauthorizationRequiredException extends SecurityException {
        ReauthorizationRequiredException() {
            super("Spotify access token expired; browser authorization is required");
        }
    }

    private SpotifyAuthCoordinator() {}
}
