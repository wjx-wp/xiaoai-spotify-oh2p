import { getMiNA } from "mi-service-lite";
import { spotifyConfig, xiaomiConfig } from "./config.js";
import { SpotifyClient } from "./spotify.js";
import { hasSpotifyToken } from "./spotify-auth.js";

let failed = false;

try {
  const config = spotifyConfig();
  if (!(await hasSpotifyToken(config.tokenPath))) {
    console.log("[Spotify] 未授权：运行 npm run auth");
    failed = true;
  } else {
    const devices = await new SpotifyClient(config).devices();
    console.log("[Spotify] 可用播放设备：");
    if (!devices.length) console.log("  （无；请启动 Spotify 桌面客户端并播放一次）");
    for (const device of devices) {
      console.log(
        `  - ${device.name} [${device.type}]${device.is_active ? "（当前活跃）" : ""}${
          device.is_restricted ? "（不可由 API 控制）" : ""
        }`,
      );
    }
  }
} catch (error) {
  console.error(`[Spotify] 失败：${error.message}`);
  failed = true;
}

try {
  const config = xiaomiConfig();
  const mina = await getMiNA(config);
  if (!mina?.account?.device) throw new Error(`找不到设备“${config.did}”`);
  const device = mina.account.device;
  console.log(
    `[小爱] 已找到：${device.name || device.alias || config.did}，型号 ${device.hardware || "未知"}`,
  );
} catch (error) {
  console.error(`[小爱] 失败：${error.message}`);
  failed = true;
}

if (failed) process.exitCode = 1;
