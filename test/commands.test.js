import assert from "node:assert/strict";
import test from "node:test";
import { executeCommand, parseCommand } from "../src/commands.js";

test("ignores commands without the Spotify keyword", () => {
  assert.equal(parseCommand("小爱同学播放稻香"), undefined);
});

test("parses common play commands and transcription aliases", () => {
  assert.deepEqual(parseCommand("小爱同学，Spotify 播放 稻香"), {
    action: "play",
    type: "track",
    query: "稻香",
  });
  assert.deepEqual(parseCommand("请用斯波蒂法播放歌单爵士咖啡馆"), {
    action: "play",
    type: "playlist",
    query: "爵士咖啡馆",
  });
  assert.deepEqual(parseCommand("声破天播放歌手陈奕迅"), {
    action: "play",
    type: "artist",
    query: "陈奕迅",
  });
});

test("parses transport and volume commands", () => {
  assert.deepEqual(parseCommand("Spotify 暂停"), { action: "pause" });
  assert.deepEqual(parseCommand("Spotify 下一首"), { action: "next" });
  assert.deepEqual(parseCommand("Spotify 音量调到 120"), {
    action: "volume",
    percent: 100,
  });
});

test("parses personal library, shuffle and repeat before generic search", () => {
  assert.deepEqual(parseCommand("Spotify 播放我喜欢的音乐"), {
    action: "play-liked",
  });
  assert.deepEqual(parseCommand("Spotify 打开随机播放"), {
    action: "shuffle",
    enabled: true,
  });
  assert.deepEqual(parseCommand("Spotify 单曲循环"), {
    action: "repeat",
    mode: "track",
  });
});

test("executes personal library playback", async () => {
  let called = 0;
  const result = await executeCommand(
    { action: "play-liked" },
    {
      async playLiked() {
        called += 1;
        return 37;
      },
    },
  );
  assert.equal(called, 1);
  assert.equal(result, "开始播放点赞音乐，共加入37首");
});

test("executes a play command against the Spotify adapter", async () => {
  const calls = [];
  const spotify = {
    async playSearch(query, type) {
      calls.push({ query, type });
      return { item: { name: "稻香", artists: [{ name: "周杰伦" }] } };
    },
  };
  const result = await executeCommand(
    { action: "play", type: "track", query: "稻香" },
    spotify,
  );
  assert.deepEqual(calls, [{ query: "稻香", type: "track" }]);
  assert.equal(result, "开始播放周杰伦的稻香");
});
