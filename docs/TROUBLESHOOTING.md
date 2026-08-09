# 故障排除

本文针对已经部署完成的 `OH2P + 1.56.20` 主路径。不要为了排错关闭 SSH 主机密钥校验、给手机开放通用 root shell，或在未经哈希验证的固件上重新加载原生过滤器。

## 先收集一份基线状态

在音箱的可信 root SSH 会话中运行：

```sh
/data/xiaoaimusic/healthcheck.sh
```

重点保留以下几段：

- `librespot`、`voice bridge`、`key bridge` 和 `local control`
- `mobile_auth_bind`
- `liked sync`
- `native filters`
- `authorization_marker`、`SPOTIFY_AUTH` 和 `SPOTIFY_API_READY`
- 最后的 librespot 日志

进一步查看日志时使用：

```sh
tail -n 80 /tmp/xiaoaimusic-voice-bridge.log
tail -n 80 /tmp/xiaoaimusic-spotify-api.log
tail -n 80 /tmp/xiaoaimusic-librespot.log
tail -n 80 /tmp/xiaoaimusic-liked-sync.log
tail -n 80 /tmp/xiaoaimusic-keybridge.log
```

这些运行日志不应包含 OAuth token，但公开提交故障报告前仍请检查并删除设备 IP、设备 ID、账号名称、搜索内容和其他个人信息。

## 仍然听到“开通音乐会员”或试听版

这句话来自小米原生音乐链路，不是 Spotify Premium 的会员判断。通常表示语音没有命中项目路由，或原生 AIVS 过滤器没有工作。

1. 先用确定性较高的说法测试：`小爱同学，播放歌手周杰伦`。不要用本项目未支持的“最近播放”“常听歌曲”“当前队列”等说法。
2. 在健康输出中确认 `voice-bridge.sh` 正在运行。
3. 在 `native filters` 中确认 `mico_aivs_lab` 的内存映射包含 `libxiaoaimusic_aivs_filter.so`。
4. 查看语音桥日志。应看到最终 ASR、`MUSIC_INTENT_EARLY` 和对应的 `OK action=play...`；如果完全没有 ASR，检查小爱网络和原生语音服务。
5. 如果出现 `FAILED action=...`，继续检查 Spotify 授权、网络和设备是否在线。

已验证固件突然丢失过滤器时，优先重启音箱让已安装的开机流程恢复。仍不恢复才在可信 root 会话运行 `/data/xiaoaimusic/activate-native-filters.sh`；该脚本会核对固定二进制哈希，任何不匹配都必须停止排错，不得改掉哈希门禁强行加载。

## Spotify 和原生音乐同时响

双重播放意味着原生 `qplayer` 没有及时停止，常见于 AIVS/触控过滤器未加载或对应桥接进程退出。

1. 先运行一次：

   ```sh
   /data/xiaoaimusic/stop-native-music.sh
   ```

2. 语音触发双重播放：检查 `voice-bridge.sh` 和 `mico_aivs_lab` 的 AIVS 过滤器映射。
3. 中央播放键触发双重播放：检查 `xiaoaimusic-keybridge`、本地控制 socket，以及 `touchpad` 是否映射 `libxiaoaimusic_touchpad_filter.so`。
4. 如果过滤器都存在，查看语音桥或按键日志中是否有连续失败；再检查 `/tmp/xiaoaimusic-spotify-api.log`。

按键回退脚本会在切换 Spotify 后按递增间隔多次停止原生播放器。若双重播放能持续存在，不能把它当成正常的短暂切换现象。

## 语音搜索等待很久

`播放周杰伦` 至少需要最终 ASR、Spotify 搜索和启动播放；access token 需要刷新、设备缓存失效或网络较慢时还会增加请求。

- 用类型明确的命令缩小搜索，例如 `播放歌曲晴天`、`播放歌手周杰伦` 或 `播放我的歌单通勤`。
- 暂停、继续、上/下一首应优先走本地 Spirc，正常会比搜索播放快得多。
- 在 `/tmp/xiaoaimusic-spotify-api.log` 中查看每个 `API` 记录的 `seconds=` 和 `status=`；耗时发生在 Spotify 网络请求时，不要反复重启语音服务。
- 音箱会把 Spotify Connect 设备 ID 持久缓存到 `/data/xiaoaimusic/spotify-device-id`。播放失败时程序会自动删除缓存、重新发现设备并重试一次；无需手工定期清缓存。
- `SPOTIFY_API_READY` 缺失或提示找不到配置的设备名时，确认 librespot 正在运行，并确认 `device.env` 与 `spotify-web.env` 的 `SPOTIFY_DEVICE_NAME` 完全一致。

## 中央播放键有延迟或没有反应

正常路径是按键桥直接向 `/tmp/xiaoaimusic-librespot-control.sock` 发送 `toggle`。socket 不存在时才调用 Web API 回退，因此会多出设备状态查询和网络延迟。

检查：

```sh
ls -l /tmp/xiaoaimusic-librespot-control.sock
ps w | grep '[x]iaoaimusic-keybridge'
tail -n 80 /tmp/xiaoaimusic-keybridge.log
tail -n 80 /tmp/xiaoaimusic-librespot.log
```

- 没有 socket：librespot 未运行、启动参数没有启用本地控制，或异常重启尚未完成。先查看 librespot 日志和监护进程。
- socket 存在但没有反应：librespot 可能尚未建立 Spotify Spirc 会话；先在 Spotify 应用中选择一次音箱或发起一次语音播放。
- 按键桥进程不存在：运行 `/data/xiaoaimusic/run-keybridge.sh`，再复查日志。
- 每次都落到 Web API：检查按键日志中的 `local control failed`，并恢复本地 socket，而不是降低 API 超时。

当前只有中央播放键映射为 Spotify 播放/暂停切换；不要把其他实体键没有执行上/下一首误判成故障。

## 手机播放时先从手机出声

自动接管不是 Android 的系统默认音频路由，而是收到事件后把 Spotify Connect 会话转给音箱，因此触发条件不完整或事件到达稍晚时，手机可能先响一下。

1. 在伴侣应用确认“启用自动接管”已打开，配对状态为“已通过固定主机指纹和手机签名密钥认证”。
2. 开启“Spotify 启动预接管”无障碍服务，并在 Spotify 设置中开启 `Device Broadcast Status`。
3. 手机应使用家庭 Wi-Fi，不能走 VPN；音箱地址必须是当前可达地址。
4. 打开 Spotify 后稍等应用首页的最近状态变为“Spotify 打开预接管：音箱已接收”，再开始播放，可以最大程度避免首段从手机输出。
5. Android 14 及以上还会对可信的播放广播做约 0.5 秒和 2.5 秒两次接管；Android 13 及以下只依赖打开 Spotify 窗口的预接管。锁屏控件、第三方自动化或不打开 Spotify 窗口直接开始播放时，旧版 Android 不保证自动接管。

如果状态是“音箱密钥认证失败或暂时离线”，按 SSH/IP 小节处理；如果是“耳机/车载/USB 音频已连接，未接管”，这是预期的安全策略。

## 手机系统媒体音量与音箱不同步

这是两种不同的音量：

- Android 系统媒体音量控制手机当前输出；Spotify 已转移到 Connect 音箱后，把手机媒体音量降到零不等于把音箱静音。
- Spotify 应用播放界面中的设备音量滑块控制 librespot 的 Spotify Connect 音量。
- 音箱实体音量键和原生“小爱同学，音量调到…”控制 OH2P 的硬件/混音器音量。

当前项目没有把这两个百分比双向绑定。日常可用 Spotify 应用内滑块调流音量，用音箱实体键或原生语音调最终扬声器音量。排查实际混音器状态可查看健康输出的 `amixer sget mysoftvol` 段。

## Spotify 401、`AUTH_UNVERIFIED` 或授权过期

遇到 HTTP 401 时，设备端会强制刷新 access token 并重试一次。仍然失败时按状态区分：

- `authorization_marker=AUTH_EXPIRED`、`SPOTIFY_AUTH status=AUTH_EXPIRED reauthorization_required=yes`，或日志出现 `invalid_grant`：refresh token 已被 Spotify 拒绝。打开 Android 应用，点“重新授权 Spotify”，在官方页面完成授权并安全下发。
- `AUTH_UNVERIFIED` 但没有过期标记：可能是网络、Spotify 服务或 token 刷新暂时失败。检查时间、DNS/HTTPS 连通性和 `/tmp/xiaoaimusic-spotify-api.log` 后再运行 `/data/xiaoaimusic/spotify-web-api.sh health`。
- App 已经完成浏览器授权但显示等待验证/下发：点“重新验证并下发”或“重试下发已验证授权”；只有待处理材料已过期或被应用丢弃时才重新开始授权。
- 反复授权仍失败：确认 Android 构建时注入的 Spotify Client ID 与音箱 `/data/xiaoaimusic/spotify-web.env` 中的 Client ID 相同，并确认登录的是该 Spotify Developer 应用允许使用的 Premium 账号。

`estimated_expires_at` 是按 180 天计算的本地提醒，不是服务器返回的实际 refresh token 截止日。

## SSH host key 不匹配

Android 和工程主机都采用严格的 SSH 主机密钥固定。出现不匹配时会失败关闭；这可能是连到了另一台设备，也可能是音箱重装后真正更换了 host key。

- 不要关闭 `StrictHostKeyChecking`，不要在弹窗中盲目接受新密钥，也不要用未经验证的局域网扫描结果替换指纹。
- 先通过可信的物理 USB/ADB 恢复路径读取音箱当前 host key 指纹，与设备身份核对。
- 如果只是误连设备，改回正确 IP，不需要更换指纹。
- 如果经过物理核验确认音箱确实生成了新 host key，需要用新指纹重新构建并签名 Android 应用，再通过可信恢复路径重新登记手机公钥。工程主机的专用 `known_hosts` 也只能在完成同样核验后更新。

应用把“主机指纹不匹配”和“音箱暂时离线”统一显示为“音箱密钥认证失败或暂时离线”，需结合 IP 可达性判断。

## 音箱 IP 变化

建议在路由器中为音箱设置 DHCP 地址保留。地址已经变化时：

1. 通过路由器或可信的物理路径确认新地址确实属于同一台音箱。
2. 在 Android 应用的“音箱局域网 IPv4 地址”中输入新的私网地址，点“保存音箱地址并重新认证”。
3. 指纹相同且手机公钥配对仍有效时，应用会重新建立会话；无需重新做 Spotify OAuth。
4. 工程主机按地址记录的专用 `known_hosts` 条目可能也需要在核验指纹后更新。

不要把公网地址、域名或通过 VPN 到达的地址填入应用；它只接受私有单播 IPv4，自动接管也明确拒绝 VPN 网络。

## 耳机、车载或 USB 音频阻止接管

这是设计行为，不是权限错误。只要 Android 报告连接了以下任何外部输出，自动接管就会停止：有线耳机、蓝牙 A2DP/BLE、助听器、车载/USB 音频、HDMI、Line/AUX、底座、总线或远程混音输出。

- 想让音箱接管：先断开这些输出，再打开 Spotify 或重新开始播放。
- 想继续使用耳机/车载：保持连接即可，应用不会抢走播放。
- 应用首页最近状态会显示“耳机/车载/USB 音频已连接，未接管”。
- “测试接管”也遵守外部音频保护，不会绕过这项策略。

## Liked 镜像没有同步

自动任务每小时检查一次，但只有上次成功同步已超过 24 小时才调用 Spotify。因此手机刚点赞后短时间看不到变化是正常的。

1. 说 `小爱同学，同步点赞音乐` 强制同步，或在可信 root 会话运行：

   ```sh
   /data/xiaoaimusic/spotify-web-api.sh sync-liked
   ```

2. 查看健康输出中的 `supervise-liked-sync.sh` 进程和 `last_sync_epoch`。
3. 查看 `/tmp/xiaoaimusic-liked-sync.log` 与 `/tmp/xiaoaimusic-spotify-api.log`。
4. 确认账号中存在名为 `XiaoAI · Liked Songs` 的私有歌单。它由音箱管理，不要手工改名、删掉后同时保留旧的本地 ID，或编辑其中歌曲。
5. 401/`invalid_grant` 按上一节重新授权；权限不足时，用包含 `user-library-read`、`playlist-read-private` 和 `playlist-modify-private` 的当前应用版本重新授权。

成功时命令输出形如 `SYNCED liked-mirror ... <歌曲数>`，并更新 `/data/xiaoaimusic/liked-mirror-last-sync`。同步是完整镜像：取消点赞的歌曲也会在下次成功同步时从镜像歌单移除。

## 仍未解决

提交问题前请附上：

- 型号与固件版本；
- 兼容性哈希检查结果；
- 复现步骤和使用的准确语句；
- 脱敏后的健康检查相关段落和日志时间点；
- Android 版本、自动接管状态，以及是否连接外部音频或 VPN。

不要上传固件、分区备份、Spotify token、SSH 私钥、root 密码、Android 签名文件、真实设备 IP/MAC/DID 或未脱敏的完整日志。
