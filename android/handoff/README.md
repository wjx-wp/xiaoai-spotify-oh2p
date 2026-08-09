# XiaoAI Spotify Handoff for Android

Android companion app for an already-provisioned OH2P speaker. It performs three tasks:

1. securely transfers Spotify playback to the speaker over a host-key-pinned SSH forced command;
2. completes Spotify Authorization Code + PKCE in the phone browser;
3. sends a verified refresh token to the speaker without storing a speaker root password.

## Public-build configuration

This repository intentionally contains no real Spotify Client ID, speaker address or SSH host-key fingerprint.

Before building a release, set:

```powershell
$env:XIAOAI_SPOTIFY_CLIENT_ID = '<your-client-id>'
$env:XIAOAI_SPEAKER_HOST_KEY_SHA256 = '<your-speaker-host-key-sha256>'
```

Create your own Spotify Developer application and register this redirect URI exactly:

```text
http://127.0.0.1:43827/callback
```

PKCE does not use a Client Secret. Do not add one to this project.

The speaker's private RFC1918 IPv4 address is entered in the app after installation. The SSH fingerprint must be obtained during the trusted physical/ADB provisioning stage; never learn or replace it from an untrusted LAN prompt.

## Release signing

Generate and back up your own signing key. Never commit the keystore or passwords.

```powershell
$env:XIAOAI_ANDROID_KEYSTORE = '<absolute-keystore-path>'
$env:XIAOAI_ANDROID_KEY_ALIAS = '<key-alias>'
$env:XIAOAI_ANDROID_STORE_PASSWORD = '<store-password>'
$env:XIAOAI_ANDROID_KEY_PASSWORD = '<key-password>'
```

Release packaging fails unless the two public runtime identifiers and all four signing variables are present. Unit tests and lint do not require them.

Recommended toolchain: JDK 21, Gradle 9.5.1, Android Gradle Plugin 9.3.0 and Android SDK 36.

```powershell
gradle --no-daemon :app:testDebugUnitTest :app:lintRelease :app:assembleRelease
```

Verify the resulting APK with `apksigner verify --verbose --print-certs`. Future updates must use the same signing certificate or Android will require uninstalling the app, which also destroys its Android Keystore SSH identity.

## Security model

- The mobile RSA private key is non-exportable in Android Keystore.
- SSH host-key checking is strict and fail-closed.
- The registered mobile public key can invoke only `takeover`, `spotify-auth-status` and `spotify-auth-update`.
- Spotify token responses are strictly parsed; a fixed HTTPS `/v1/me/player/devices` request verifies the access token before the paired refresh token becomes uploadable.
- Pending authorization is a single AES-GCM protected atomic bundle. The access token is erased after verification.
- No token, OAuth code, PKCE verifier, password or private key is logged.
- The accessibility service observes only Spotify window-state changes and cannot retrieve window content.

Uninstalling the app, clearing its data or changing the APK signing identity destroys the mobile SSH identity. Re-pair through a trusted physical recovery path; never solve this by granting the phone a general root shell.
