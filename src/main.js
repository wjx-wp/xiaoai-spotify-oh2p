import { parseCommand, executeCommand } from "./commands.js";
import { spotifyConfig } from "./config.js";
import { SpotifyClient } from "./spotify.js";
import { hasSpotifyToken } from "./spotify-auth.js";
import { XiaomiVoiceSource } from "./xiaomi.js";

const config = spotifyConfig();
if (!(await hasSpotifyToken(config.tokenPath))) {
  throw new Error("尚未完成 Spotify 授权，请先运行 npm run auth");
}

const spotify = new SpotifyClient(config);
let xiaomi;
xiaomi = new XiaomiVoiceSource(async (query) => {
  const command = parseCommand(query);
  if (!command) return;
  console.log(`🎙️ ${query}`);
  await xiaomi.stopNativePlayback();
  try {
    const result = await executeCommand(command, spotify);
    console.log(`✅ ${result}`);
    await xiaomi.say(result, "success");
  } catch (error) {
    console.error(`❌ ${error.message}`);
    await xiaomi.say(`Spotify 控制失败，${error.message}`, "error");
  }
});

const device = await xiaomi.initialize();
console.log(`已连接小爱音箱：${device.name || device.alias || device.hardware}`);
console.log("语音桥已运行。可以说：小爱同学，Spotify 播放稻香");

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => {
    xiaomi.stop();
    process.exit(0);
  });
}

await xiaomi.start();
