# Android 自动接管

当前方案由手机应用通过受限 SSH 公钥直接调用音箱上的 `takeover` forced command；不再启动 `18789` HTTP 服务，也不再保存或传输 Home Bridge bearer token。

安装、Spotify 授权、主机密钥固定、RSA3072 手机密钥和自动接管说明统一维护在 [Android Handoff README](../android/handoff/README.md)。

旧版 `xiaoaimusic-home-bridge` 只保留停止脚本用于升级清理，不属于默认安装包或开机项。
