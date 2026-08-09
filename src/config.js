import path from "node:path";

export function env(name, fallback = "") {
  return process.env[name]?.trim() || fallback;
}

export function required(name) {
  const value = env(name);
  if (!value) {
    throw new Error(`缺少环境变量 ${name}，请编辑 .env`);
  }
  return value;
}

export function numberEnv(name, fallback, minimum = Number.NEGATIVE_INFINITY) {
  const raw = env(name);
  if (!raw) return fallback;
  const value = Number(raw);
  if (!Number.isFinite(value) || value < minimum) {
    throw new Error(`${name} 必须是不小于 ${minimum} 的数字`);
  }
  return value;
}

export function booleanEnv(name, fallback = false) {
  const raw = env(name);
  if (!raw) return fallback;
  if (["true", "1", "yes", "on"].includes(raw.toLowerCase())) return true;
  if (["false", "0", "no", "off"].includes(raw.toLowerCase())) return false;
  throw new Error(`${name} 必须是 true 或 false`);
}

export function parsePair(value, name) {
  const pair = value.split(",").map((item) => Number(item.trim()));
  if (pair.length !== 2 || pair.some((item) => !Number.isInteger(item) || item < 1)) {
    throw new Error(`${name} 格式应为“5,3”`);
  }
  return pair;
}

export function spotifyConfig() {
  const redirectUri = env(
    "SPOTIFY_REDIRECT_URI",
    "http://127.0.0.1:43827/callback",
  );
  const url = new URL(redirectUri);
  if (url.protocol !== "http:" || url.hostname !== "127.0.0.1") {
    throw new Error(
      "本地回调地址必须使用 http://127.0.0.1:端口/路径；Spotify 不接受 localhost",
    );
  }
  return {
    clientId: required("SPOTIFY_CLIENT_ID"),
    redirectUri,
    preferredDeviceName: env("SPOTIFY_DEVICE_NAME"),
    tokenPath: path.resolve(".spotify-token.json"),
  };
}

export function xiaomiConfig() {
  return {
    userId: required("MI_USER_ID"),
    password: required("MI_PASSWORD"),
    did: required("MI_DEVICE"),
    enableTrace: booleanEnv("MI_ENABLE_TRACE", false),
    timeout: 8000,
  };
}
