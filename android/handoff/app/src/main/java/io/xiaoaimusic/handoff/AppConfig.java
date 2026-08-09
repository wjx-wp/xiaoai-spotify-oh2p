package io.xiaoaimusic.handoff;

final class AppConfig {
    static final String SPOTIFY_PACKAGE = "com.spotify.music";
    static final String SPOTIFY_PLAYBACK_ACTION = "com.spotify.music.playbackstatechanged";
    static final String DEFAULT_SPEAKER_HOST = "";
    static final int SPEAKER_SSH_PORT = 22;
    static final String SPEAKER_SSH_USER = "root";
    static final String SPEAKER_HOST_KEY_SHA256 = BuildConfig.SPEAKER_HOST_KEY_SHA256;

    static final String SPOTIFY_CLIENT_ID = BuildConfig.SPOTIFY_CLIENT_ID;
    static final String SPOTIFY_REDIRECT_URI = "http://127.0.0.1:43827/callback";
    static final String SPOTIFY_AUTHORIZE_URL = "https://accounts.spotify.com/authorize";
    static final String SPOTIFY_TOKEN_URL = "https://accounts.spotify.com/api/token";
    static final String SPOTIFY_DEVICES_URL = "https://api.spotify.com/v1/me/player/devices";
    static final String SPOTIFY_SCOPES = String.join(" ", new String[] {
            "user-read-playback-state",
            "user-modify-playback-state",
            "user-library-read",
            "user-library-modify",
            "user-read-recently-played",
            "user-top-read",
            "playlist-read-private",
            "playlist-read-collaborative",
            "playlist-modify-private"});

    static final String MOBILE_AUTH_PUBLIC_KEY_FILE = "mobile-auth-public-key.pub";
    static final String AUTH_UPDATE_COMMAND = "spotify-auth-update";
    static final String AUTH_STATUS_COMMAND = "spotify-auth-status";
    static final String TAKEOVER_COMMAND = "takeover";

    private AppConfig() {}
}
