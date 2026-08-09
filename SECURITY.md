# 安全策略

## 报告漏洞

仓库发布后，请优先使用 GitHub Security Advisories 私下报告安全问题；不要先创建公开 Issue。报告中只附最小复现材料，并删除 IP、设备标识、账号名和所有凭据。如果仓库尚未启用 Security Advisories，请通过仓库所有者公开资料中的私下联系方式报告。

不要在 Issue、讨论、PR、日志或截图中发布：

- 音箱 root 密码或管理员公钥；
- OAuth code、access token、refresh token 或 PKCE verifier；
- SSH 私钥、Android 签名密钥或密码；
- 小米账号、Spotify 账号和 Wi-Fi 凭据；
- 固件 dump、分区备份、DID、序列号、MAC 或设备 host key。

提交前运行：

```text
npm run public-check
npm test
```

## 部署安全边界

OH2P 的旧版 Dropbear 算法只允许出现在“固定 host key + 公钥认证 + forced command + 可信局域网”的组合中。不要把音箱 SSH、调试端口或任何接管接口映射到互联网，也不要把手机 key 扩展为普通 root shell。

首次配对必须通过可信物理/ADB 路径取得 host-key 指纹和登记手机公钥；不要接受局域网弹窗提供的新指纹。手机清数据、卸载应用或更换 APK 签名会销毁 Android Keystore 中的私钥，需要重新走可信物理配对。

设备端所有 native filter 都必须通过型号、固件和二进制哈希门禁。哈希不匹配时应停止，不得通过删除检查来“尝试启动”。详细信任边界见 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)，恢复清单见 [`docs/SECURITY-RECOVERY.md`](docs/SECURITY-RECOVERY.md)。
