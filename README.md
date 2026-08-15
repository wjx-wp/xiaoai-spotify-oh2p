# XiaoAI Spotify OH2P

把小米 `OH2P` 音箱改造成保留“小爱同学 / 米家 / 红外控制”的 Spotify Connect 音箱。

librespot 直接运行在音箱内；语音和实体键可以控制 Spotify；Android 应用负责在家时自动把手机播放接管到音箱，并在手机浏览器完成 Spotify 授权。正常使用不需要电脑常开。

> [!WARNING]
> 这是非官方的实验性工程项目，不是小米或 Spotify 产品。目前还没有面向普通用户的零点击刷机安装器。错误修改启动槽或跨型号、跨固件套用补丁，可能让音箱无法启动。开始前必须阅读[安装状态](docs/INSTALLATION-STATUS.md)和[安全与恢复清单](docs/SECURITY-RECOVERY.md)。

## 从这里开始

| 你要做什么 | 文档 |
| --- | --- |
| 判断自己的设备能不能用 | [安装状态与兼容边界](docs/INSTALLATION-STATUS.md) |
| 从源码准备环境、构建、配对和部署 | [完整安装与部署](docs/INSTALLATION.md) |
| 学习语音、实体键、Spotify App 和自动接管 | [日常使用指南](docs/USAGE.md) |
| 出现无声、双播放器、授权、SSH 或同步问题 | [排障手册](docs/TROUBLESHOOTING.md) |
| 刷写前备份或恢复原厂槽 | [安全与恢复清单](docs/SECURITY-RECOVERY.md) |
| 了解组件、数据流和安全设计 | [架构与信任边界](docs/ARCHITECTURE.md) |
| 查看引用的原项目、作者和许可证 | [致谢与上游关系](docs/ACKNOWLEDGEMENTS.md) |
| 参与开发或报告漏洞 | [贡献指南](CONTRIBUTING.md) · [安全策略](SECURITY.md) |

## 已实现

- Spotify Connect 接收端直接运行在 OH2P 上，最高配置为 320 kbps，电脑无需常开。
- “播放歌手 / 歌曲 / 专辑 / 我的歌单 / 点赞音乐”等中文语音请求路由到 Spotify；小米云最终确认的其他音乐请求也会兜底接管。
- 原生小爱继续处理米家、红外、天气、闹钟等非音乐能力。
- AIVS 过滤器按原生 `audio_type=MUSIC` 最终判定抑制 QQ 音乐播放；非音乐提示音、米家、红外、天气和闹钟继续保留。
- 播放/暂停、上一首、下一首等实体键走本地 Spirc 控制，延迟低。
- Android 应用在 Wi-Fi 和音频路由条件满足时，把手机 Spotify 会话接管到音箱。
- Spotify OAuth 使用 Authorization Code + PKCE，不需要 Client Secret；授权和重新授权都可在手机完成。
- 手机 SSH 私钥由 Android Keystore 生成且不可导出；音箱只授予三个 forced commands，不给手机 root shell。
- Liked Songs 通过用户自己的私有镜像歌单每日同步；手机上的点赞变化会在下一次成功同步后反映到音箱。
- 每日同步同时生成最多 100 首的个人音乐池；单曲和泛化请求使用私有 `XiaoAI · Radio` 歌单随机、列表循环，避免单曲结束后停播。

详细命令与已知限制见[日常使用指南](docs/USAGE.md)。

## 当前兼容范围

端到端真机验证基线：

- 型号：`OH2P`
- 固件：`1.56.20`
- CPU：ARMv7 hard-float
- glibc：不高于 `2.25`
- `mico_aivs_lab` 与 `libaivs_sdk.so` SHA-256：[`compatibility/oh2p-1.56.20.json`](compatibility/oh2p-1.56.20.json)

设备端在启用原生语音过滤器前会核对型号、固件和二进制哈希；不匹配时拒绝加载。

仓库也保存 `1.62.2` 官方 OTA 的参考元数据及实验性同版本构建工具，但这**不表示**完整方案已经在 1.62.2 真机验证，也不授权把 1.62.2 镜像刷到其它版本。型号或哈希不同就停止，不要删除检查继续尝试。

## 每位使用者都使用自己的身份

这个仓库不提供共用账号、共用密钥或“作者云服务”。每位使用者需要：

- 自己的 Spotify Premium 账号；
- 自己在 Spotify Developer Dashboard 创建的应用与 Client ID；
- 自己音箱的 SSH host key；
- 自己手机 Android Keystore 生成的 SSH 私钥；
- 自己生成并妥善备份的 Android 发布签名；
- 自己的小米账号、家庭 Wi-Fi、设备备份和管理员恢复方式。

PKCE 不使用 Client Secret。公开仓库和公开 APK 都不应内置贡献者的 Spotify Client ID、token、音箱 IP 或 host-key 指纹。

## 仓库不包含什么

这里只发布源代码、补丁、兼容哈希、测试和构建流程，不发布：

- 小米固件、rootfs、分区备份、设备 dump 或专有动态库；
- Spotify、米家或小米账号凭据；
- OAuth access/refresh token、SSH 私钥或 root 密码；
- Android 签名证书、签名密码或个人 APK；
- 设备 IP、DID、序列号、MAC、SSH host key 或手机公钥；
- 第三方刷机工具和预编译修改固件。

仓库自带 `npm run public-check`、pre-commit hook 和 GitHub Actions 门禁，用来阻止常见秘密与禁入制品。门禁不能替代提交前人工检查。

## 开发者快速验证

基础环境需要 Node.js 20.6+、Git、PowerShell、WSL2/Ubuntu。Android 构建使用 JDK 21、Gradle 9.5.1、Android SDK 36；ARMv7 运行时工具链版本记录在 `resources.lock.json`。

```powershell
npm ci
npm test
npm run public-check
```

同步锁定的上游源码并应用本仓库补丁：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/sync-resources.ps1
```

默认只构建运行时，不下载或生成固件：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build-oh2p.ps1
```

完整环境准备、Android release 签名、可信配对和部署顺序见[安装与部署](docs/INSTALLATION.md)。不要把这三条开发者命令当成裸机一键安装器。

## 项目结构

- `android/handoff/`：Android 自动接管与手机端 Spotify 授权。
- `components/`：AIVS 过滤、实体键、本地控制和受限授权更新器。
- `device/oh2p/`：音箱运行脚本、自启动、健康检查和 Spotify Web API。
- `host/`、`scripts/`：构建、探测、部署和恢复工具。
- `patches/`：对固定上游提交的最小补丁。
- `compatibility/`：已验证型号、固件与哈希档案。
- `test/`：Node、Shell、协议、权限和故障注入测试。
- `src/`：早期电脑端小米云语音桥接，仅供兼容性研究，不是 OH2P 主路径。

## 项目状态与下一步

当前源码、音箱端组件、Android 授权/接管链路以及 OH2P 1.56.20 真机基线已经形成完整工程实现。仍缺的是面向陌生裸机和普通用户的交互式安装器：它需要持久状态机、USB/供电提示、设备轮询、备份校验、版本门禁、失败回滚和可恢复断点。

在该安装器完成并经过多台设备验证前，本项目只应作为工程预览使用，不应宣传为“买来插线就能自动刷完”。能自动化的步骤与必须由用户亲自完成的步骤见[安装状态](docs/INSTALLATION-STATUS.md)。

## 致谢、许可证与商标

感谢 [librespot](https://github.com/librespot-org/librespot)、[xiaoai-agent](https://github.com/stevenjoezhang/xiaoai-agent)、[open-xiaoai](https://github.com/idootop/open-xiaoai)、[mi-gpt](https://github.com/idootop/mi-gpt)、[xiaoai-crack](https://github.com/birdsofsummer/xiaoai-crack)、[mwiede/JSch](https://github.com/mwiede/jsch) 以及小爱音箱社区的作者和贡献者。它们在本项目中分别属于运行时依赖、补丁目标或研究参考，具体贡献与代码使用边界见[致谢与上游关系](docs/ACKNOWLEDGEMENTS.md)。

原创代码按 [Apache License 2.0](LICENSE) 发布。第三方派生补丁继续使用相应上游许可证；详情见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) 和 `LICENSES/`。

Xiaomi、XiaoAI、Mi Home 和 Spotify 等名称及商标属于各自权利人。本项目与这些公司及上游项目均无隶属或背书关系。
