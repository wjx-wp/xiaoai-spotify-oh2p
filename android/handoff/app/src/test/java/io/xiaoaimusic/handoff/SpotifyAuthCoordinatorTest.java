package io.xiaoaimusic.handoff;

import static org.junit.Assert.assertEquals;

import java.io.IOException;
import org.junit.Test;

public final class SpotifyAuthCoordinatorTest {
    @Test
    public void distinguishesTokenExchangeVerificationAndUploadStages() {
        assertEquals(
                "Spotify 授权码换取令牌失败（HTTP 400），请重新授权",
                SpotifyAuthCoordinator.safeFailureMessage(
                        PendingAuthorizationState.NONE,
                        new IOException("Spotify 授权接口返回 400")));
        assertEquals(
                "新授权已加密保存，但 Spotify 官方只读验证返回 HTTP 403；可点“重新验证并下发”",
                SpotifyAuthCoordinator.safeFailureMessage(
                        PendingAuthorizationState.NEEDS_VERIFICATION,
                        new IOException("Spotify 只读验证接口返回 403")));
        assertEquals(
                "Spotify 官方验证已通过，但音箱安全下发失败；授权已加密保留，可点“重试下发已验证授权”",
                SpotifyAuthCoordinator.safeFailureMessage(
                        PendingAuthorizationState.VERIFIED_READY,
                        new IOException("speaker rejected the authorization update")));
        assertEquals(
                "Spotify 已返回令牌，但手机本地加密保存失败（LOCAL_CRYPTO）；现有音箱授权未被覆盖",
                SpotifyAuthCoordinator.safeFailureMessage(
                        PendingAuthorizationState.NONE,
                        SpotifyAuthCoordinator.AuthorizationStage.LOCAL_ENCRYPT,
                        new java.security.KeyStoreException("redacted")));
        assertEquals(
                "Spotify 授权码尚未换成可保存的令牌（TOKEN_EXCHANGE_TLS），请重新授权",
                SpotifyAuthCoordinator.safeFailureMessage(
                        PendingAuthorizationState.NONE,
                        SpotifyAuthCoordinator.AuthorizationStage.TOKEN_EXCHANGE,
                        new javax.net.ssl.SSLHandshakeException("redacted")));
    }
}
