const SPOTIFY_NAME =
  /(?:spotify|spot\s*ify|斯波提法|斯波蒂法|思波提法|思博提法|声破天)/iu;

function cleanText(value) {
  return value
    .normalize("NFKC")
    .replace(/[，。！？!?]/gu, " ")
    .replace(/\s+/gu, " ")
    .trim();
}

export function parseCommand(input) {
  const original = cleanText(input);
  const nameMatch = SPOTIFY_NAME.exec(original);
  if (!nameMatch) return undefined;

  let text = original.slice(nameMatch.index + nameMatch[0].length).trim();
  text = text.replace(/^(?:里面|上的|里|中)?\s*(?:帮我|请|给我|一下)*/u, "").trim();
  if (!text || /^(?:打开|启动)$/u.test(text)) return { action: "resume" };
  if (/^(?:暂停|停一下|停止播放|停止)$/u.test(text)) return { action: "pause" };
  if (/^(?:继续|继续播放|恢复|恢复播放|播放)$/u.test(text)) return { action: "resume" };
  if (/^(?:下一首|切歌|下一曲)$/u.test(text)) return { action: "next" };
  if (/^(?:上一首|上一曲)$/u.test(text)) return { action: "previous" };
  if (/^(?:(?:播放|放)(?:一下)?\s*)?(?:点赞音乐|点赞歌曲|点赞的音乐|一点赞音乐|一点赞的音乐|收藏音乐|收藏歌曲|我喜欢的音乐|我喜欢的歌曲|喜欢的歌|我的收藏|我的音乐)$/u.test(text)) {
    return { action: "play-liked" };
  }
  if (/^(?:随机播放|打开随机播放|开启随机播放)$/u.test(text)) {
    return { action: "shuffle", enabled: true };
  }
  if (/^(?:关闭随机播放|不要随机播放)$/u.test(text)) {
    return { action: "shuffle", enabled: false };
  }
  if (/^单曲循环$/u.test(text)) return { action: "repeat", mode: "track" };
  if (/^(?:列表循环|歌单循环)$/u.test(text)) {
    return { action: "repeat", mode: "context" };
  }
  if (/^(?:关闭循环|不要循环)$/u.test(text)) {
    return { action: "repeat", mode: "off" };
  }
  if (/^(?:现在播放什么|正在播放什么|这是什么歌)$/u.test(text)) {
    return { action: "now-playing" };
  }

  const volume = /^(?:把)?音量(?:调到|设置为|设为)?\s*(\d{1,3})(?:%|百分之)?$/u.exec(text);
  if (volume) {
    return { action: "volume", percent: Math.min(100, Number(volume[1])) };
  }

  const typedPlay = /^(?:播放|放)(?:一下)?\s*(歌单|专辑|歌手|艺人|歌曲)?\s*(.+)$/u.exec(text);
  if (!typedPlay) return { action: "unknown", text };
  const typeMap = {
    歌单: "playlist",
    专辑: "album",
    歌手: "artist",
    艺人: "artist",
    歌曲: "track",
  };
  return {
    action: "play",
    type: typeMap[typedPlay[1]] || "track",
    query: typedPlay[2].trim(),
  };
}

function itemDescription(item) {
  const artist = item.artists?.map((entry) => entry.name).join("、");
  return artist ? `${artist}的${item.name}` : item.name;
}

export async function executeCommand(command, spotify) {
  switch (command.action) {
    case "play": {
      const { item } = await spotify.playSearch(command.query, command.type);
      return `开始播放${itemDescription(item)}`;
    }
    case "resume":
      await spotify.resume();
      return "继续播放";
    case "pause":
      await spotify.pause();
      return "已暂停";
    case "next":
      await spotify.next();
      return "已切到下一首";
    case "previous":
      await spotify.previous();
      return "已切到上一首";
    case "play-liked": {
      const count = await spotify.playLiked();
      return `开始播放点赞音乐，共加入${count}首`;
    }
    case "shuffle":
      await spotify.setShuffle(command.enabled);
      return command.enabled ? "已打开随机播放" : "已关闭随机播放";
    case "repeat":
      await spotify.setRepeat(command.mode);
      return command.mode === "track"
        ? "已打开单曲循环"
        : command.mode === "context"
          ? "已打开列表循环"
          : "已关闭循环";
    case "volume":
      await spotify.setVolume(command.percent);
      return `Spotify 音量已调到百分之${command.percent}`;
    case "now-playing": {
      const state = await spotify.nowPlaying();
      if (!state) return "Spotify 当前没有播放音乐";
      return `现在${state.isPlaying ? "播放" : "暂停在"}${state.artists.join("、")}的${state.name}`;
    }
    default:
      throw new Error("没听懂 Spotify 指令，可以说播放、暂停、继续、上一首或下一首");
  }
}
