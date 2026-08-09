# XiaoAI Spotify OH2P

把小米 `OH2P` 音箱改造成保留“小爱同学 / 米家 / 红外控制”的 Spotify Connect 音箱。

> **实验性项目。** 本项目会修改设备启动项和系统服务，操作错误可能导致音箱无法启动。它不是小米或 Spotify 官方项目。请先阅读[安全与恢复清单](docs/SECURITY-RECOVERY.md)，不要跨型号、跨固件盲刷。

## 已实现

- librespot 直接运行在音箱上；播放不需要电脑常开。
- “播放歌手、歌曲、专辑、我的歌单、点赞音乐”等语音请求路由到 Spotify。
- 原生小爱继续处理米家、红外、天气、闹钟等非音乐能力。
- 音箱播放/暂停、上一首、下一首实体键走本地 Spirc，延迟很低。
- Android 应用在家庭 Wi-Fi 下把手机上的 Spotify 会话安全接管到音箱。
- Spotify OAuth 使用 Authorization Code + PKCE；不需要 Client Secret。
- 手机 SSH 私钥由 Android Keystore 生成且不可导出；音箱只授权三个 forced commands，不开放手机 root shell。
- 点赞歌曲镜像歌单可每日同步，手机上的点赞变化会在下次同步后反映到音箱。

## 当前兼容范围

端到端真机验证基线：

- 型号：`OH2P`
- 固件：`1.56.20`
- CPU：ARMv7 hard-float
- glibc：不高于 `2.25`
- `mico_aivs_lab` SHA-256：见 [`compatibility/oh2p-1.56.20.json`](compatibility/oh2p-1.56.20.json)
- `libaivs_sdk.so` SHA-256：见同一兼容档案

设备端会在启用原生语音过滤器前核对二进制哈希，不匹配时拒绝加载。仓库还保留了 `1.62.2` 官方 OTA 的参考元数据和实验性同版本补丁工具，但它**不等于**当前完整方案已在 1.62.2 真机验证。

## 不会上传或共享的内容

本仓库只包含源代码、补丁、哈希和构建流程，不包含：

- 小米固件、rootfs、分区备份、设备 dump 或专有动态库；
- Spotify、米家或小米账号凭据；
- OAuth access/refresh token、SSH 私钥、root 密码；
- Android 签名证书、签名密码或个人 APK；
- 用户设备 IP、DID、序列号、MAC、SSH host key 指纹；
- 第三方刷机工具和预编译固件包。

运行 `npm run public-check` 可执行公开目录白名单和敏感内容检查。GitHub Actions 也会执行相同门禁。

## 每位使用者都使用自己的身份

- 自己的 Spotify Premium 账号；
- 自己在 Spotify Developer Dashboard 创建的应用与 Client ID；
- 自己音箱生成的 SSH host key；
- 自己手机 Android Keystore 生成的 SSH 私钥；
- 自己生成的 APK 发布签名；
- 自己的小米账号、Wi-Fi 和设备备份。

PKCE 不使用 Client Secret。公开仓库和公开 APK 都不应内置贡献者的 Spotify Client ID 或设备指纹。

## 开发者快速检查

需要 Node.js 20.6+、Git、WSL2/Ubuntu，以及 Android 构建所需的 JDK 21、Gradle 9.5.1、Android SDK 36。

```powershell
npm ci
npm test
npm run public-check
```

同步锁定的第三方源码和补丁：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/sync-resources.ps1
```

构建 OH2P ARMv7 组件：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build-oh2p.ps1
```

默认只构建运行时，不下载或生成固件。只有在设备与参考 OTA 严格同版、已完成备份且理解风险时，才可同时显式设置固件下载确认变量并传入 `-WithReferenceFirmware`。

首次公开版本暂不承诺“一键刷机”。现有 `host/` 和 `device/oh2p/` 是经过真机验证的工程脚本，只应由理解 A/B 分区、SSH host-key 固定和回滚流程的人使用。面向普通用户的安装器将采用显式状态机：识别设备、提示插拔电源/USB、轮询等待、哈希门禁、备份、部署、健康检查和失败回滚。

## Android 应用

公开源码要求构建者注入自己的 OAuth Client ID 和音箱 host-key 指纹：

```powershell
$env:XIAOAI_SPOTIFY_CLIENT_ID = '<your-client-id>'
$env:XIAOAI_SPEAKER_HOST_KEY_SHA256 = '<your-speaker-host-key-sha256>'
```

正式 release 另外要求四个签名环境变量；缺少任何一项时构建会失败，不会静默生成可误装的未签名发布包。详细说明见 [`android/handoff/README.md`](android/handoff/README.md)。

## 目录

- `android/handoff/`：Android 自动接管与手机端 Spotify 重新授权。
- `components/`：AIVS 过滤、实体键、本地控制和受限授权更新器。
- `device/oh2p/`：音箱运行脚本、自启动、健康检查和 Spotify Web API。
- `host/`、`scripts/`：构建、探测、部署和恢复工具。
- `patches/`：对固定上游提交的最小补丁。
- `compatibility/`：经验证型号、版本和哈希档案。
- `test/`：Node、Shell 和故障注入测试。
- `src/`：早期电脑端小米云语音桥接实现，仅供兼容性研究，不是 OH2P 主路径。

## 许可证

原创代码按 Apache-2.0 发布。第三方派生补丁继续使用相应上游许可证；详情见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) 和 `LICENSES/`。
