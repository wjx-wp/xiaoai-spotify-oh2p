# 参与贡献

欢迎提交兼容档案、可复现构建改进、测试、排障文档以及更安全的恢复路径。这个项目会触及设备启动链和账号凭据，因此“可验证、可回滚、默认拒绝未知状态”比功能数量更重要。

## 提交前提

1. 不得提交小米固件、专有动态库、设备 dump、分区备份、账号凭据、已签名 APK 或第三方刷机工具。
2. 每个新固件变体都要新增独立兼容档案、目标二进制哈希和 fail-closed 门禁。
3. 补丁和改编代码必须保留上游许可证，不得把 MIT/LGPL 派生内容重新标成项目的 Apache-2.0 原创代码。
4. 真机测试说明必须删除序列号、MAC、DID、账号名、IP、host key、公钥和 token。
5. 不要为了支持更多版本而绕过哈希、host-key 固定、受限 SSH 或管理员恢复 key 检查。

架构和安全边界见 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)，恢复原则见 [`docs/SECURITY-RECOVERY.md`](docs/SECURITY-RECOVERY.md)。

## 开发流程

从独立分支开始，并尽量让每次提交只解决一个问题。同步第三方源码时必须使用 `resources.lock.json` 中锁定的提交；不要直接把整个上游工作树复制进本仓库。

```powershell
npm ci
npm test
npm run public-check
```

如修改 Android 应用，再运行：

```powershell
Set-Location android/handoff
gradle --no-daemon :app:testDebugUnitTest :app:lintRelease
```

如修改设备端 C/Rust、打包或安装脚本，还应完成对应 ARMv7 构建、Shell integration 和故障注入测试。PR 中请写明：

- 改动目的与威胁模型；
- 自动化测试结果；
- 是否做过真机测试及准确型号/固件；
- 失败后的恢复方法；
- 新增或变更的第三方代码及许可证。

## 补丁与上游署名

- `patches/librespot-local-control.patch` 是对 librespot 的派生补丁，继续遵循 MIT。
- `patches/xiaoai-agent-coexist.patch` 是对 xiaoai-agent 的派生补丁，继续遵循 LGPL-3.0-or-later。
- 若参考某个社区仓库但没有复制代码，请在 `docs/ACKNOWLEDGEMENTS.md` 说明其启发和边界，不要伪造作者关系或许可证。

## Git 门禁

本 checkout 使用仓库自带的 `.githooks/pre-commit`。如果克隆后没有自动配置，运行：

```text
git config core.hooksPath .githooks
```

`npm run public-check` 会拒绝常见秘密、固件/二进制制品、私钥、APK、设备报告和禁入目录。门禁通过不代表可以跳过人工审查；提交前仍应检查 `git diff --cached` 和最终文件清单。
