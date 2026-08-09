# 致谢与上游关系

XiaoAI Spotify OH2P 建立在小爱音箱社区长期公开的设备研究、工具和开源软件之上。感谢下列项目的作者与贡献者分享研究成果，使本项目能够更快理解设备能力、验证实现方向并构建可复现的运行环境。

本页刻意区分“资料或灵感参考”“补丁目标”和“直接运行时依赖”。列出项目仅表示致谢及履行许可证告知义务，**不表示这些项目的作者参与、认可、赞助或为 XiaoAI Spotify OH2P 背书**。

## 社区研究与实现参考

| 项目 | 对本项目的帮助与关系 | 许可证与代码使用边界 |
| --- | --- | --- |
| [idootop/mi-gpt](https://github.com/idootop/mi-gpt) | 为前期的小爱音箱兼容性、语音桥接和米家能力调研提供了重要社区资料与思路参考。 | [MIT](https://github.com/idootop/mi-gpt/blob/main/LICENSE)。本仓库不依赖该项目、未对其打补丁，也未复制其源代码。 |
| [birdsofsummer/xiaoai-crack](https://github.com/birdsofsummer/xiaoai-crack) | 提供了小爱音箱底层接口、服务和设备行为方面的公开研究资料，帮助设备侧探索与交叉验证。 | 截至 2026-08-09，该仓库未提供可识别的开源许可证。它在本项目中仅作为阅读和研究资料；本仓库未复制、修改或再分发其代码。保留所有权利并尊重原作者。 |
| [idootop/open-xiaoai](https://github.com/idootop/open-xiaoai) | 端侧小爱音箱实现及原生服务协作方式的历史参考。构建资源清单锁定了其提交 [`bc3396c`](https://github.com/idootop/open-xiaoai/tree/bc3396c64e2a435f354eb5cb12a203981f1fe422)，用于来源可追溯和研究验证。 | [MIT](https://github.com/idootop/open-xiaoai/blob/bc3396c64e2a435f354eb5cb12a203981f1fe422/LICENSE)。其源码不随本仓库入库，也不作为 XiaoAI Spotify OH2P 的直接运行时组件；同步脚本会在开发者明确执行时从上游获取锁定版本。 |

上述“参考”不应理解为这些项目对本项目的功能、安全性或设备兼容性作出保证。

## 补丁目标与音箱端运行时

### xiaoai-agent

[stevenjoezhang/xiaoai-agent](https://github.com/stevenjoezhang/xiaoai-agent) 提供 OH2P 固件研究、rootfs 提取/重打包和端侧 Agent 构建基础。本项目锁定提交 [`b408562`](https://github.com/stevenjoezhang/xiaoai-agent/tree/b408562a8524dea2a613e99cb58a2268d8e2ea42)，并通过 `patches/xiaoai-agent-coexist.patch` 对该版本作最小化适配，使原生小爱/米家能力与本项目组件共存，同时加强登录和构建流程。

- 关系：构建工具、补丁目标，以及编译后的音箱端组件来源。
- 许可证：[GNU Lesser General Public License v3.0 or later](https://github.com/stevenjoezhang/xiaoai-agent/blob/b408562a8524dea2a613e99cb58a2268d8e2ea42/LICENSE)（其 `xiaoai-agent/Cargo.toml` 标注 `LGPL-3.0-or-later`）。
- 本项目针对它的派生补丁继续按 `LGPL-3.0-or-later` 分发；仓库内副本见 [`LICENSES/xiaoai-agent-LGPL-3.0-or-later.txt`](../LICENSES/xiaoai-agent-LGPL-3.0-or-later.txt)。
- 本仓库不内置完整上游源码；同步脚本按 `resources.lock.json` 获取固定提交并应用补丁。

### librespot

[librespot-org/librespot](https://github.com/librespot-org/librespot) 是音箱端 Spotify Connect 播放运行时。本项目锁定版本 `v0.8.0` 的提交 [`d36f9f1`](https://github.com/librespot-org/librespot/tree/d36f9f1907e8cc9d68a93f8ebc6b627b1bf7267d)，并通过 `patches/librespot-local-control.patch` 增加仅限本机的播放控制接口，用于语音和实体按键的低延迟控制。

- 关系：直接运行时依赖和补丁目标。
- 许可证：[MIT](https://github.com/librespot-org/librespot/blob/d36f9f1907e8cc9d68a93f8ebc6b627b1bf7267d/LICENSE)。
- 本项目针对它的补丁按 MIT 许可证分发；仓库内副本见 [`LICENSES/librespot-MIT.txt`](../LICENSES/librespot-MIT.txt)。
- 本仓库不内置完整上游源码或预编译二进制；同步和构建流程从锁定提交生成目标文件。

## 应用与电脑端直接依赖

| 项目 | 在本项目中的用途 | 许可证 |
| --- | --- | --- |
| [mwiede/jsch](https://github.com/mwiede/jsch) | Android 应用使用 `com.github.mwiede:jsch:2.28.4` 建立主机密钥固定的受限 SSH 会话，并把授权资料安全下发到音箱。 | 上游 [`LICENSE.txt`](https://github.com/mwiede/jsch/blob/master/LICENSE.txt) 所载 Revised BSD / BSD-style 许可证；其分发包还包含 JZlib 与 jBCrypt 的独立告知。对应副本见 [`LICENSES/jsch-Revised-BSD.txt`](../LICENSES/jsch-Revised-BSD.txt)、[`LICENSES/JZlib.txt`](../LICENSES/JZlib.txt) 和 [`LICENSES/jBCrypt.txt`](../LICENSES/jBCrypt.txt)。 |
| [idootop/mi-service-lite](https://github.com/idootop/mi-service-lite) | Node.js 兼容/诊断路径使用的直接依赖（锁定 `3.1.0`），用于访问小米 MiNA 与 MIoT 服务；它不是 OH2P 音箱端 Spotify 播放主链路的必需组件。 | npm 包元数据声明 [MIT](https://www.npmjs.com/package/mi-service-lite/v/3.1.0)。本项目通过包管理器安装该依赖，不在仓库中复制其源代码。 |

直接依赖还可能带入传递依赖。源码仓库中的告知文件不能替代二进制发布前的完整依赖许可证审计；发布 APK、安装包或预编译音箱组件时，应根据实际构建产物重新生成并随包提供第三方许可证清单。

## 本项目自身的范围

本仓库中的原创代码以 [Apache License 2.0](../LICENSE) 发布；对第三方项目的派生补丁以及构建得到的第三方组件继续受各自上游许可证约束。完整的分发边界和许可证摘要另见 [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md)。

本项目不会把“小爱音箱社区已有研究”宣称为自身原创，也不会因为引用、兼容或使用某个上游项目而暗示存在官方合作关系。Xiaomi、XiaoAI、Mi Home 和 Spotify 等名称及商标属于各自权利人；本项目是独立的非官方社区项目。
