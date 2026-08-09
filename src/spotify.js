import { getAccessToken } from "./spotify-auth.js";

const API_BASE = "https://api.spotify.com/v1";

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function normalize(value) {
  return value.trim().toLocaleLowerCase();
}

export class SpotifyClient {
  constructor(config) {
    this.config = config;
  }

  async request(path, options = {}, attempt = 0) {
    const accessToken = await getAccessToken(this.config);
    const url = new URL(`${API_BASE}${path}`);
    for (const [key, value] of Object.entries(options.query || {})) {
      if (value !== undefined && value !== "") url.searchParams.set(key, value);
    }
    const headers = { authorization: `Bearer ${accessToken}` };
    if (options.body !== undefined) headers["content-type"] = "application/json";
    const response = await fetch(url, {
      method: options.method || "GET",
      headers,
      body: options.body === undefined ? undefined : JSON.stringify(options.body),
    });

    if (response.status === 429 && attempt < 2) {
      const retryAfter = Math.max(1, Number(response.headers.get("retry-after")) || 1);
      await delay(Math.min(retryAfter, 30) * 1000);
      return this.request(path, options, attempt + 1);
    }
    if (response.status === 204) return undefined;
    const data = await response.json().catch(() => ({}));
    if (!response.ok) {
      const message = data?.error?.message || data?.error_description || "未知错误";
      const error = new Error(`Spotify API ${response.status}: ${message}`);
      error.status = response.status;
      throw error;
    }
    return data;
  }

  async devices() {
    const data = await this.request("/me/player/devices");
    return data?.devices || [];
  }

  async targetDevice() {
    const devices = await this.devices();
    const preferred = this.config.preferredDeviceName;
    let device;
    if (preferred) {
      device = devices.find((item) => normalize(item.name) === normalize(preferred));
    }
    device ||= devices.find((item) => item.is_active && !item.is_restricted);
    device ||= devices.find((item) => !item.is_restricted);
    if (!device) {
      throw new Error(
        "没有可控的 Spotify 播放设备。请先启动 Spotify 桌面客户端并播放任意歌曲一次",
      );
    }
    return device;
  }

  async playerRequest(path, method, body) {
    const device = await this.targetDevice();
    await this.request(path, {
      method,
      query: { device_id: device.id },
      body,
    });
    return device;
  }

  async search(query, type = "track") {
    const data = await this.request("/search", {
      query: { q: query, type, limit: "5" },
    });
    const collectionName = `${type}s`;
    const item = data?.[collectionName]?.items?.find(Boolean);
    if (!item) throw new Error(`Spotify 中没有找到“${query}”`);
    return item;
  }

  async playSearch(query, type = "track") {
    const item = await this.search(query, type);
    const body = type === "track" ? { uris: [item.uri] } : { context_uri: item.uri };
    const device = await this.playerRequest("/me/player/play", "PUT", body);
    return { item, device };
  }

  async savedTracks(limit = 50) {
    const data = await this.request("/me/tracks", {
      query: { limit: String(Math.min(50, Math.max(1, limit))), offset: "0" },
    });
    return (data?.items || [])
      .map((entry) => entry?.track)
      .filter((track) => track?.uri?.startsWith("spotify:track:"));
  }

  async playUris(uris) {
    const playable = uris.filter((uri) => uri?.startsWith("spotify:track:"));
    if (!playable.length) throw new Error("Spotify 收藏中没有可播放的歌曲");
    await this.playerRequest("/me/player/play", "PUT", { uris: playable });
    return playable.length;
  }

  async playLiked() {
    const tracks = await this.savedTracks(50);
    return this.playUris(tracks.map((track) => track.uri));
  }

  async resume() {
    return this.playerRequest("/me/player/play", "PUT");
  }

  async pause() {
    return this.playerRequest("/me/player/pause", "PUT");
  }

  async next() {
    return this.playerRequest("/me/player/next", "POST");
  }

  async previous() {
    return this.playerRequest("/me/player/previous", "POST");
  }

  async setShuffle(enabled) {
    const device = await this.targetDevice();
    await this.request("/me/player/shuffle", {
      method: "PUT",
      query: { device_id: device.id, state: enabled ? "true" : "false" },
    });
    return device;
  }

  async setRepeat(mode) {
    if (!["off", "track", "context"].includes(mode)) {
      throw new Error(`不支持的循环模式：${mode}`);
    }
    const device = await this.targetDevice();
    await this.request("/me/player/repeat", {
      method: "PUT",
      query: { device_id: device.id, state: mode },
    });
    return device;
  }

  async setVolume(percent) {
    const device = await this.targetDevice();
    await this.request("/me/player/volume", {
      method: "PUT",
      query: { device_id: device.id, volume_percent: String(percent) },
    });
    return device;
  }

  async nowPlaying() {
    const state = await this.request("/me/player");
    if (!state?.item) return undefined;
    return {
      isPlaying: state.is_playing,
      name: state.item.name,
      artists: (state.item.artists || []).map((artist) => artist.name),
      device: state.device?.name,
    };
  }
}
