import { getMiIOT, getMiNA } from "mi-service-lite";
import { env, numberEnv, parsePair, xiaomiConfig } from "./config.js";

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function feedbackMode() {
  const mode = env("VOICE_FEEDBACK", "errors").toLowerCase();
  if (!["none", "errors", "all"].includes(mode)) {
    throw new Error("VOICE_FEEDBACK 只能是 none、errors 或 all");
  }
  return mode;
}

export class XiaomiVoiceSource {
  constructor(onQuery) {
    this.onQuery = onQuery;
    this.running = false;
    this.cursor = 0;
    this.config = xiaomiConfig();
    this.interval = numberEnv("POLL_INTERVAL_MS", 1200, 800);
    this.ttsCommand = parsePair(env("MI_TTS_COMMAND", "5,3"), "MI_TTS_COMMAND");
    this.feedback = feedbackMode();
  }

  async initialize() {
    this.mina = await getMiNA(this.config);
    if (!this.mina?.account?.device) {
      throw new Error(`找不到小爱音箱“${this.config.did}”，请检查 MI_DEVICE`);
    }
    if (this.feedback !== "none") {
      this.miot = await getMiIOT(this.config);
    }
    const conversations = await this.mina.getConversations({ limit: 1 });
    this.cursor = conversations?.records?.[0]?.time || Date.now();
    return this.mina.account.device;
  }

  async say(text, kind = "success") {
    const shouldSpeak =
      this.feedback === "all" || (this.feedback === "errors" && kind === "error");
    if (!shouldSpeak || !this.miot) return;
    await this.miot.doAction(this.ttsCommand[0], this.ttsCommand[1], text);
  }

  async stopNativePlayback() {
    await this.mina.pause().catch(() => undefined);
  }

  async start() {
    this.running = true;
    let consecutiveFailures = 0;
    while (this.running) {
      try {
        const conversations = await this.mina.getConversations({ limit: 10 });
        const records = (conversations?.records || [])
          .filter((record) => record.time > this.cursor)
          .sort((left, right) => left.time - right.time);
        for (const record of records) {
          this.cursor = Math.max(this.cursor, record.time);
          await this.onQuery(record.query, record);
        }
        consecutiveFailures = 0;
        await delay(this.interval);
      } catch (error) {
        consecutiveFailures += 1;
        console.error(`拉取小爱对话失败（第 ${consecutiveFailures} 次）：${error.message}`);
        await delay(Math.min(30_000, this.interval * 2 ** consecutiveFailures));
      }
    }
  }

  stop() {
    this.running = false;
  }
}
