import { spotifyConfig } from "./config.js";
import { authorizeSpotify } from "./spotify-auth.js";

try {
  await authorizeSpotify(spotifyConfig());
  console.log("Spotify 授权已保存。下一步运行 npm run diagnose。\n");
} catch (error) {
  console.error(`授权失败：${error.message}`);
  process.exitCode = 1;
}
