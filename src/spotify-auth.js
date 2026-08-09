import crypto from "node:crypto";
import fs from "node:fs/promises";
import http from "node:http";
import { spawn } from "node:child_process";

const SCOPES = [
  "user-read-playback-state",
  "user-modify-playback-state",
  "user-library-read",
  "user-library-modify",
  "user-read-recently-played",
  "user-top-read",
  "playlist-read-private",
  "playlist-read-collaborative",
  "playlist-modify-private",
];

export class SpotifyAuthRequiredError extends Error {
  constructor(message = "Spotify 授权已失效，请运行 npm run auth 重新授权") {
    super(message);
    this.name = "SpotifyAuthRequiredError";
  }
}

function base64Url(value) {
  return Buffer.from(value).toString("base64url");
}

async function readToken(tokenPath) {
  try {
    return JSON.parse(await fs.readFile(tokenPath, "utf8"));
  } catch (error) {
    if (error.code === "ENOENT") return undefined;
    throw error;
  }
}

async function writeToken(tokenPath, token) {
  const temporaryPath = `${tokenPath}.tmp`;
  await fs.writeFile(temporaryPath, `${JSON.stringify(token, null, 2)}\n`, {
    encoding: "utf8",
    mode: 0o600,
  });
  await fs.rename(temporaryPath, tokenPath);
}

export async function removeToken(tokenPath) {
  await fs.rm(tokenPath, { force: true });
}

function openBrowser(url) {
  const options = { detached: true, stdio: "ignore" };
  let child;
  if (process.platform === "win32") {
    child = spawn("rundll32.exe", ["url.dll,FileProtocolHandler", url], options);
  } else if (process.platform === "darwin") {
    child = spawn("open", [url], options);
  } else {
    child = spawn("xdg-open", [url], options);
  }
  child.unref();
}

async function exchangeToken(body) {
  const response = await fetch("https://accounts.spotify.com/api/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(body),
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    const error = new Error(
      `Spotify 授权接口返回 ${response.status}: ${data.error_description || data.error || "未知错误"}`,
    );
    error.status = response.status;
    error.code = data.error;
    throw error;
  }
  return data;
}

function waitForCallback(redirectUri, expectedState, timeoutMs = 300_000) {
  const callbackUrl = new URL(redirectUri);
  return new Promise((resolve, reject) => {
    const server = http.createServer((request, response) => {
      const requestUrl = new URL(request.url, redirectUri);
      if (requestUrl.pathname !== callbackUrl.pathname) {
        response.writeHead(404).end("Not found");
        return;
      }
      const state = requestUrl.searchParams.get("state");
      const code = requestUrl.searchParams.get("code");
      const oauthError = requestUrl.searchParams.get("error");
      if (state !== expectedState) {
        response.writeHead(400, { "content-type": "text/plain; charset=utf-8" });
        response.end("Spotify 授权失败：state 不匹配。可以关闭此页面。");
        server.close();
        reject(new Error("Spotify OAuth state 不匹配，已拒绝回调"));
        return;
      }
      if (oauthError || !code) {
        response.writeHead(400, { "content-type": "text/plain; charset=utf-8" });
        response.end("Spotify 授权未完成。可以关闭此页面。");
        server.close();
        reject(new Error(`Spotify 授权未完成: ${oauthError || "缺少 code"}`));
        return;
      }
      response.writeHead(200, { "content-type": "text/plain; charset=utf-8" });
      response.end("Spotify 授权成功。可以关闭此页面并返回终端。");
      server.close();
      resolve(code);
    });

    server.on("error", reject);
    server.listen(Number(callbackUrl.port), callbackUrl.hostname);
    const timer = setTimeout(() => {
      server.close();
      reject(new Error("等待 Spotify 授权超时"));
    }, timeoutMs);
    server.on("close", () => clearTimeout(timer));
  });
}

export async function authorizeSpotify({ clientId, redirectUri, tokenPath }) {
  const verifier = base64Url(crypto.randomBytes(64));
  const challenge = base64Url(
    crypto.createHash("sha256").update(verifier).digest(),
  );
  const state = base64Url(crypto.randomBytes(24));
  const authorizationUrl = new URL("https://accounts.spotify.com/authorize");
  authorizationUrl.search = new URLSearchParams({
    response_type: "code",
    client_id: clientId,
    redirect_uri: redirectUri,
    scope: SCOPES.join(" "),
    state,
    code_challenge_method: "S256",
    code_challenge: challenge,
  }).toString();

  const callback = waitForCallback(redirectUri, state);
  console.log("浏览器将打开 Spotify 授权页……");
  console.log(`若没有自动打开，请访问：${authorizationUrl}`);
  openBrowser(authorizationUrl.toString());
  const code = await callback;
  const token = await exchangeToken({
    client_id: clientId,
    grant_type: "authorization_code",
    code,
    redirect_uri: redirectUri,
    code_verifier: verifier,
  });
  const now = Date.now();
  await writeToken(tokenPath, {
    ...token,
    expires_at: now + token.expires_in * 1000,
    authorized_at: now,
  });
  return token;
}

export async function getAccessToken({ clientId, tokenPath }) {
  const token = await readToken(tokenPath);
  if (!token?.refresh_token) throw new SpotifyAuthRequiredError();
  if (token.access_token && token.expires_at > Date.now() + 60_000) {
    return token.access_token;
  }

  let refreshed;
  try {
    refreshed = await exchangeToken({
      client_id: clientId,
      grant_type: "refresh_token",
      refresh_token: token.refresh_token,
    });
  } catch (error) {
    if (error.code === "invalid_grant") {
      await removeToken(tokenPath);
      throw new SpotifyAuthRequiredError();
    }
    throw error;
  }
  const updated = {
    ...token,
    ...refreshed,
    refresh_token: refreshed.refresh_token || token.refresh_token,
    expires_at: Date.now() + refreshed.expires_in * 1000,
  };
  await writeToken(tokenPath, updated);
  return updated.access_token;
}

export async function hasSpotifyToken(tokenPath) {
  return Boolean(await readToken(tokenPath));
}
