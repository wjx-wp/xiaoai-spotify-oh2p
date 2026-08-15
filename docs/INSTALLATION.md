# OH2P 工程版安装指南

本文说明如何把仓库中的运行时、原生语音过滤器、实体按键桥、Spotify Web API 和 Android 接管应用部署到一台**已经安全取得 root/SSH 的 OH2P**。

> **当前不是一键刷机工具。** 仓库可以锁定源码、构建 ARMv7 运行时、校验设备、部署服务和设置自启动，但还不能自动完成 USB 引导、取得 root、判断未知分区布局或安全刷写任意固件。首次 root/固件写入仍需熟悉 Amlogic、双系统槽和设备恢复的操作者完成。不要把本指南用于陌生型号或陌生固件。

安装完成后，音乐直接由音箱上的 librespot 播放，电脑不需要常开。原生小爱、米家和红外控制继续保留。

## 1. 支持范围和硬停止条件

当前唯一端到端真机验证组合：

| 项目 | 要求 |
| --- | --- |
| 音箱型号 | `OH2P` |
| 固件版本 | `1.56.20` |
| CPU ABI | ARMv7 hard-float |
| glibc | 不高于 `2.25` |
| Android | Android 9（API 28）或更高版本 |
| Spotify | 用户自己的 Premium 账号 |
| 网络 | 手机与音箱可互访的家庭局域网；音箱使用私网 IPv4 |

`compatibility/oh2p-1.56.20.json` 还锁定了两个原生过滤器输入：

```text
/usr/bin/mico_aivs_lab
SHA-256 b2064cfcecba129a89d4dc01ff7a5acdd1515fe1a6b4ec3db876cd9c88d2a608

/usr/lib/libaivs_sdk.so
SHA-256 64150ecd6fdbddddd0944e177d26c45b9774306bd3ca5c19bce599080844eb9e
```

遇到以下任何一项都应停止，不要“试试看”：

- 型号不是 `OH2P`，包括名称相似的其它小爱音箱；
- 固件不是 `1.56.20`，或上面任一二进制哈希不匹配；
- `/proc/mtd`、分区大小、当前启动槽与本指南的双槽假设不一致；
- 无法完整读出并校验同一台设备的原厂 `system0`、`system1`；
- 无法确认 `boot1/system1` 是可启动且保留不动的原厂恢复槽；
- 通过局域网看到的 SSH 主机指纹与可信物理通道导出的指纹不同；
- 手机生成的配对密钥不是脚本要求的 RSA 3072 位；
- 任一构建、哈希、回读、健康检查或自启动门禁失败。

仓库中的 `1.62.2` 只是实验性参考 OTA 元数据，**没有完成同等端到端真机验证**。不要把它用于 `1.56.20` 设备，也不要设置 `XIAOAI_DOWNLOAD_REFERENCE_FIRMWARE` 或使用 `-WithReferenceFirmware` 完成本指南。

## 2. 先准备用户自己的 Spotify 应用

1. 使用自己的 Spotify Premium 账号登录 Spotify Developer Dashboard。
2. 创建一个自己的应用，记录 **Client ID**。
3. 在应用设置中精确登记以下 Redirect URI：

   ```text
   http://127.0.0.1:43827/callback
   ```

4. 如果 Dashboard 当前模式要求用户白名单，把实际授权的 Spotify 账号加入允许列表。

Android 应用使用 Authorization Code + PKCE；**不需要、也不应填写 Client Secret**。Client ID 会在构建 APK 时写入该用户自己的 APK，同时写入音箱的本地配置。请勿把 Client ID、APK、令牌或本地配置提交回公共仓库。

浏览器授权时只应在 Spotify 官方账号页面登录；本地回调由手机上的应用在 `127.0.0.1:43827` 接收。

## 3. Windows、WSL 和 Android 构建环境

主机脚本按以下环境编写：

- Windows 10/11、PowerShell；
- Git、Node.js 20.6+、npm、Windows OpenSSH 的 `ssh.exe`/`scp.exe`；
- WSL2，发行版注册名为 `Ubuntu`；
- WSL 内可联网并可使用 `sudo`；
- Android 构建使用 JDK 21、Gradle 9.5.1、Android SDK 36；
- Android SDK Platform Tools（`adb`）和 Build Tools（`apksigner`）。

如果尚未安装 WSL，可在管理员 PowerShell 中安装，按系统提示重启：

```powershell
wsl --install -d Ubuntu
```

检查基础命令和发行版名称：

```powershell
git --version
node --version
npm --version
ssh -V
wsl -l -v
java -version
gradle --version
adb --version
apksigner --version
```

`gradle --version` 应显示 Gradle 9.5.1，并使用 JDK 21。Android Studio 的 SDK Manager 可安装 Android SDK Platform 36、Build Tools 36 和 Platform Tools；确保 `JAVA_HOME`、`ANDROID_HOME` 以及相应的 `bin`/`platform-tools`/`build-tools` 已配置到当前终端。

## 4. 获取源码、锁定上游并构建运行时

以下命令都从公共仓库根目录执行。先克隆仓库并安装 Node 依赖：

```powershell
git clone '<GITHUB_REPOSITORY_URL>' xiaoai-spotify-oh2p
Set-Location .\xiaoai-spotify-oh2p
npm ci
npm test
npm run public-check
```

同步 `resources.lock.json` 锁定的上游提交并应用仓库内补丁：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\sync-resources.ps1
```

默认会跳过实验性参考固件，这是本指南需要的行为。

首次构建前，在 WSL 中安装锁定的 Rust、Zig 和系统依赖；部署脚本还需要 `sshpass`：

```powershell
$Repo = (Resolve-Path .).Path
$Drive = $Repo.Substring(0, 1).ToLowerInvariant()
$WslRepo = "/mnt/$Drive/" + $Repo.Substring(3).Replace('\', '/')
wsl.exe -d Ubuntu -- bash "$WslRepo/host/bootstrap-wsl.sh"
wsl.exe -d Ubuntu -- sudo apt-get install -y openssh-client sshpass
```

运行预检，再构建**仅运行时**产物：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\preflight.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-oh2p.ps1 -SkipBootstrap -SkipFirmware
```

主要产物位于：

```text
artifacts/build/oh2p/xiaoaimusic-oh2p.tar.gz
artifacts/build/oh2p/package/xiaoaimusic-oh2p/
artifacts/build/oh2p/BUILD-MANIFEST.txt
```

构建脚本会检查 ARMv7 ABI、动态链接器和 glibc 兼容性，并以 `--skip-firmware` 模式调用 `host/verify-artifacts.sh`。`artifacts/`、`upstream/` 和 `.secrets/` 均被 Git 忽略。

## 5. 设备备份与 root 前置边界

如果设备已经有可靠的 root SSH，并且你能证明它是匹配的 `OH2P 1.56.20`，可继续到第 6 节。否则请完整阅读 `docs/SECURITY-RECOVERY.md`。

本仓库的首刷安全边界是：只考虑修改**非活动的 `system0`**，永久保留可启动的原厂 `boot1/system1`。禁止写入 BL2、TPL、U-Boot、DTB、bootloader、`boot1/system1`、环境分区、`/data` 或设备身份分区。

### 5.1 只读备份

下面是只读 `mread` 示例。工具、驱动、USB 进入方式由你采用的可信 OH2P root 流程提供；命令失败就停止，不猜偏移、不换成写命令。

```text
update.exe mread store system0 normal 0x02800000 system0.factory.bin
update.exe mread store system1 normal 0x02800000 system1.factory.bin
certutil -hashfile system0.factory.bin SHA256
certutil -hashfile system1.factory.bin SHA256
```

两个文件都应为 40 MiB。把哈希和备份加密保存在仓库外，另复制一份到被忽略的 `artifacts/device-backups/` 供本地构建使用。`/data` 备份可能包含 DID、miio key、Wi-Fi 和账号令牌，绝不能上传。

在 WSL 中复核 SquashFS 和版本文件：

```bash
unsquashfs -s ./artifacts/device-backups/system0.factory.bin
unsquashfs -cat ./artifacts/device-backups/system0.factory.bin usr/share/mico/version
unsquashfs -s ./artifacts/device-backups/system1.factory.bin
unsquashfs -cat ./artifacts/device-backups/system1.factory.bin usr/share/mico/version
```

### 5.2 从本机备份生成同版本 rootfs 候选

只使用**这台音箱自己读出的** `system0.factory.bin`：

```bash
cd /mnt/<DRIVE>/<PATH_TO_REPOSITORY>
export EXPECTED_MODEL=OH2P
export EXPECTED_ROM=1.56.20
./host/patch-device-rootfs.sh \
  ./artifacts/device-backups/system0.factory.bin \
  '<SYSTEM0_FACTORY_SHA256>'
```

脚本会校验 40 MiB、型号、版本和输入哈希，生成随机 root 密码到 `.secrets/oh2p-root-password.txt`，保留原生声卡和认证串口登录，加入 `/data/init.sh`/Dropbear 支持并禁用 OTA 写入路径。候选镜像位于：

```text
artifacts/build/oh2p/firmware-1.56.20-coexist-from-device/root-patched-coexist.squashfs
```

> **危险：从这里开始涉及系统分区写入。** 当前仓库没有经多机验证的自动写入器，因此本文故意不提供可复制粘贴的 `mwrite`/烧录命令。只有在确认当前活动槽、`/proc/mtd`、分区长度、USB 恢复路径和 `boot1/system1` 原厂槽后，才由有 OH2P/Amlogic 恢复经验的操作者把候选写入非活动 `system0`。绝不能跨设备或跨固件使用候选镜像。

写入后必须重新只读回读完整 40 MiB 分区，并验证镜像前缀一致、剩余区域全为 `FF`：

```bash
./host/verify-partition-readback.sh \
  ./artifacts/build/oh2p/firmware-1.56.20-coexist-from-device/root-patched-coexist.squashfs \
  ./artifacts/device-backups/system0.after-write.bin \
  41943040
```

回读验证通过之前不要切换启动槽。切槽、首次启动和救援验证仍属于专业 root 阶段。首次 SSH 后先保存 `scripts/probe-oh2p.ps1` 生成的只读报告，并再次核对 `/proc/mtd`、`boot_part`、版本和上述两个原生二进制哈希。

## 6. 通过可信物理通道固定 SSH 主机指纹

不要第一次从不可信局域网提示中“学习”音箱密钥。补丁后的 Dropbear 主机私钥通常持久化在：

```text
/data/etc/dropbear/dropbear_rsa_host_key
```

通过取得 root 时使用的 USB、串口或 ADB 等**可信物理通道**，在音箱本机导出公钥部分：

```sh
dropbearkey -y -f /data/etc/dropbear/dropbear_rsa_host_key
```

把输出中的单行 `ssh-rsa ...` 通过同一可信通道保存为本机的：

```text
.secrets/speaker-host-key.trusted.pub
```

计算可信指纹：

```powershell
ssh-keygen.exe -lf .\.secrets\speaker-host-key.trusted.pub -E sha256
```

记下其中的 `SHA256:<BASE64_FINGERPRINT>`。然后才允许在局域网读取候选公钥：

```powershell
$SpeakerIp = '<SPEAKER_LAN_IPV4>'
wsl.exe -d Ubuntu -- bash -lc "mkdir -p '$WslRepo/.secrets' && chmod 700 '$WslRepo/.secrets' && ssh-keyscan -T 5 -t rsa '$SpeakerIp' > '$WslRepo/.secrets/known_hosts_oh2p.candidate' && ssh-keygen -lf '$WslRepo/.secrets/known_hosts_oh2p.candidate' -E sha256"
```

人工逐字符比较可信物理通道和局域网候选的 SHA-256 指纹。完全一致时才固定：

```powershell
Move-Item .\.secrets\known_hosts_oh2p.candidate .\.secrets\known_hosts_oh2p
```

如目标文件已经存在，先核对，不要强制覆盖。以后任何变化都按攻击或设备重置处理：停止连接，通过可信物理通道重新调查，绝不能点击“接受新密钥”。

Windows 版 `scripts/deploy-oh2p.ps1` 使用当前用户的默认 OpenSSH `known_hosts`。在确认其中没有同 IP 的冲突条目后，仅将**刚验证过**的行加入默认文件：

```powershell
$SshDir = Join-Path $env:USERPROFILE '.ssh'
$WindowsKnownHosts = Join-Path $SshDir 'known_hosts'
New-Item -ItemType Directory -Force $SshDir | Out-Null
if (Test-Path $WindowsKnownHosts) {
    ssh-keygen.exe -F $SpeakerIp -f $WindowsKnownHosts
}
```

如果上一条没有返回旧条目，再执行：

```powershell
Get-Content .\.secrets\known_hosts_oh2p | Add-Content -Encoding ascii $WindowsKnownHosts
ssh.exe -o StrictHostKeyChecking=yes -o HostKeyAlgorithms=+ssh-rsa root@$SpeakerIp true
```

输入 root 密码时让 SSH 自己交互提示，不要把密码放进命令行或 PowerShell 历史。WSL 部署脚本从被忽略的 `.secrets/oh2p-root-password.txt` 读取同一密码。

## 7. 构建并安装用户自己的 Android APK

APK 在构建时固定两个公开标识：用户自己的 Spotify Client ID，以及第 6 节可信得到的音箱 SSH SHA-256 指纹。音箱 IP 不写死，可在应用内修改。

### 7.1 创建并备份签名密钥

在仓库根目录运行；`keytool` 会交互询问密码和证书信息：

```powershell
New-Item -ItemType Directory -Force .\.secrets | Out-Null
keytool -genkeypair -v `
  -keystore .\.secrets\xiaoai-handoff-release.p12 `
  -storetype PKCS12 `
  -alias xiaoai-handoff `
  -keyalg RSA `
  -keysize 3072 `
  -validity 3650
```

把 `.p12` 和密码离线备份。以后更新必须使用同一签名证书；卸载应用、清除应用数据或换签名安装都会销毁 Android Keystore 中不可导出的手机 SSH 身份，需要通过可信 root 路径重新配对。

### 7.2 注入构建参数并构建

推荐使用 PowerShell 7 的 `Read-Host -MaskInput`，使密码不进入命令历史：

```powershell
$env:XIAOAI_SPOTIFY_CLIENT_ID = '<YOUR_SPOTIFY_CLIENT_ID>'
$env:XIAOAI_SPEAKER_HOST_KEY_SHA256 = 'SHA256:<TRUSTED_SPEAKER_FINGERPRINT>'
$env:XIAOAI_ANDROID_KEYSTORE = (Resolve-Path .\.secrets\xiaoai-handoff-release.p12).Path
$env:XIAOAI_ANDROID_KEY_ALIAS = 'xiaoai-handoff'
$env:XIAOAI_ANDROID_STORE_PASSWORD = Read-Host -MaskInput 'Keystore password'
$env:XIAOAI_ANDROID_KEY_PASSWORD = $env:XIAOAI_ANDROID_STORE_PASSWORD

Push-Location .\android\handoff
gradle --no-daemon :app:testDebugUnitTest :app:lintRelease :app:assembleRelease
Pop-Location
```

验证 APK 签名：

```powershell
$Apk = '.\android\handoff\app\build\outputs\apk\release\app-release.apk'
apksigner verify --verbose --print-certs $Apk
Get-FileHash -Algorithm SHA256 $Apk
```

清除当前终端中的敏感环境变量：

```powershell
Remove-Item Env:XIAOAI_ANDROID_STORE_PASSWORD
Remove-Item Env:XIAOAI_ANDROID_KEY_PASSWORD
Remove-Item Env:XIAOAI_ANDROID_KEYSTORE
Remove-Item Env:XIAOAI_ANDROID_KEY_ALIAS
Remove-Item Env:XIAOAI_SPOTIFY_CLIENT_ID
Remove-Item Env:XIAOAI_SPEAKER_HOST_KEY_SHA256
```

安装到手机：

```powershell
adb devices
adb install -r $Apk
```

也可以把 APK 传到手机后手动安装。只安装自己构建并核对哈希/签名的 APK。

## 8. 先部署运行时，但不启用自启动

先运行预演，它不连接或修改音箱：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\deploy-oh2p.ps1 -Ip $SpeakerIp
```

确认型号、固件、备份和主机指纹均已通过后才执行安装：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\deploy-oh2p.ps1 -Ip $SpeakerIp -Install
```

该脚本把包上传到 `/tmp/xiaoaimusic-install`，执行设备端 `install.sh`，将文件原子安装到 `/data/xiaoaimusic`。这一步**不会启动 librespot，也不会修改 `/data/init.sh`**。

使用严格主机检查登录音箱，检查并编辑两个 root-only 配置文件：

```powershell
ssh.exe -o StrictHostKeyChecking=yes -o HostKeyAlgorithms=+ssh-rsa root@$SpeakerIp
```

`/data/xiaoaimusic/device.env` 可先保留默认值；`/data/xiaoaimusic/spotify-web.env` 至少应为：

```text
SPOTIFY_CLIENT_ID=<YOUR_SPOTIFY_CLIENT_ID>
SPOTIFY_DEVICE_NAME='XiaoAI Music'
```

如果修改设备名，两个文件里的 `SPOTIFY_DEVICE_NAME` 必须完全一致。两个文件应由 root 拥有且权限为 `0600`。

先只启动 librespot：

```sh
/data/xiaoaimusic/run-librespot.sh
/data/xiaoaimusic/healthcheck.sh
```

此时应看到 librespot 及 supervisor 进程、`/tmp/xiaoaimusic-librespot-control.sock`；尚未授权时 Spotify API/语音桥显示未就绪是正常的。如果 librespot 不能稳定运行，停止，不要继续手机配对或自启动。

## 9. 导出手机公钥并部署受限 SSH 更新器

1. 打开手机上的“小爱 Spotify 接管”。
2. 输入音箱家庭局域网 IPv4，点“保存音箱地址并重新认证”。首次尚未配对时显示等待是正常的。
3. 点“复制手机配对公钥”。私钥在 Android Keystore 中不可导出，剪贴板只有一行公钥，不需要手机存储权限。
4. 在电脑仓库根目录把剪贴板保存为被忽略的本地文件：

   ```powershell
   Get-Clipboard | Set-Content -Encoding ascii .\.secrets\mobile-auth-public-key.pub
   ssh-keygen.exe -lf .\.secrets\mobile-auth-public-key.pub -E sha256
   ```

部署脚本要求公钥恰好是一行无选项、无注释的 `ssh-rsa`，并且为 RSA 3072 位。如果输出为 2048 位，停止；当前部署门禁不接受手机的兼容降级密钥。

在 WSL 中部署受限更新器：

```bash
cd /mnt/<DRIVE>/<PATH_TO_REPOSITORY>
./host/deploy-spotify-auth-updater.sh \
  '<SPEAKER_LAN_IPV4>' \
  './.secrets/mobile-auth-public-key.pub'
```

脚本会：

- 重新构建并校验更新器和 authorized-keys 验证器；
- 为原文件和 `/data/init.sh` 建立事务式备份；
- 将手机公钥安装为 forced command；
- 禁止端口转发、Agent 转发、X11 和 PTY；
- 只允许 `takeover`、`spotify-auth-status`、`spotify-auth-update`；
- 把持久化 authorized_keys 安全绑定到 Dropbear；
- 保留 root 密码救援登录。

成功输出应包含：

```text
SPOTIFY_AUTH_UPDATER_ACTIVE commands=spotify-auth-update,spotify-auth-status,takeover ...
Phone key installed with forced command only; fingerprint=SHA256:...
Rollback snapshot: /data/xiaoaimusic/backups/mobile-auth-...
```

记录回滚快照路径，但不要上传其中内容。回到手机，再次保存音箱地址，然后点“测试接管”。必须看到音箱已接收；手机密钥不能获得通用 root shell。

## 10. 在手机浏览器完成 Spotify PKCE 授权

保持手机和音箱在同一家庭 Wi-Fi，打开应用并点“重新授权 Spotify”：

1. 系统浏览器打开 Spotify 官方授权页；
2. 使用与自己 Client ID 对应、已允许使用该应用的 Premium 账号登录；
3. 同意授权后，浏览器把结果送回手机本机的 `127.0.0.1` 回调；
4. 应用先用临时 access token 向 Spotify 官方做只读设备验证；
5. 验证通过后，refresh token 才通过受限 SSH 下发音箱；
6. 成功后手机删除 access token 和 refresh token，只保留授权日期。

成功状态为：

```text
Spotify 已授权并安全下发到音箱
```

如果显示“等待官方验证”或“等待安全下发”，使用界面中的“重新验证并下发”或“重试下发已验证授权”。不要清除应用数据，也不要把 OAuth 回调、Token 或调试日志贴到 Issue。

## 11. 前台验证全部功能

Spotify 授权成功后，仍然先以前台方式运行，不启用开机启动。root SSH 中按顺序执行：

```sh
/data/xiaoaimusic/activate-native-filters.sh
/data/xiaoaimusic/run-voice-bridge.sh
/data/xiaoaimusic/run-keybridge.sh
/data/xiaoaimusic/supervise-liked-sync.sh >/tmp/xiaoaimusic-liked-sync.log 2>&1 &
/data/xiaoaimusic/healthcheck.sh
```

必须确认：

- `mico_aivs_lab` 和 `touchpad` 的 `/proc/<pid>/maps` 已加载两个项目过滤器；
- librespot、supervisor、voice bridge、key bridge 正常运行；
- 本地控制 socket 存在；
- `mobile_auth_bind=active`；
- `SPOTIFY_AUTH status=AUTH_OK`；
- Spotify API 输出 `SPOTIFY_API_READY`；
- 手机 Spotify 可选择 `XiaoAI Music` 并播放；
- 应用“测试接管”成功；
- 音箱播放键能低延迟控制 Spotify，不会同时启动原生音乐；
- “小爱同学，播放……”和“随便播放一首歌曲”等音乐指令进入 Spotify，原生 QQ/试听音源不播放；
- 非音乐的小爱、米家和红外指令仍由原生系统处理；
- 点赞音乐同步可运行，并生成最多 100 首的个人 Radio 池；连续两次下一首能加载不同歌曲。

在 Android 应用中按需开启通知，打开系统无障碍设置中的“Spotify 启动预接管”，再启用“自动接管”。Spotify 设置中还需打开 `Device Broadcast Status`。耳机、车载或 USB 音频连接时，应用策略会避免抢占播放。

任一项失败时不要启用自启动。先运行：

```bash
./host/device-status.sh '<SPEAKER_LAN_IPV4>'
```

以及检查音箱上的 `/tmp/xiaoaimusic-*.log`。分享日志前删除 IP、设备标识和可能的账号信息。

## 12. 最后才启用自启动

`install-autostart.sh` 有硬门禁：受限手机公钥、forced command 验证器和 authorized_keys bind 必须全部可信且正在生效，否则拒绝修改 `/data/init.sh`。旧的局域网 HTTP bridge 只会在新启动块原子写入成功后才停止。

所有第 11 节验证通过后，在 WSL 中运行最终部署：

```bash
cd /mnt/<DRIVE>/<PATH_TO_REPOSITORY>
./host/deploy-final-oh2p.sh '<SPEAKER_LAN_IPV4>'
```

它会校验本地包 SHA-256、重新安装最终包，然后调用 `/data/xiaoaimusic/install-autostart.sh`。成功输出应包含：

```text
FINAL_PACKAGE_INSTALLED
AUTOSTART_INSTALLED_SSH_TAKEOVER_ONLY
FINAL_DEPLOYMENT_OK ...
```

再次运行设备状态检查，确认旧端口 `18789` 为 inactive：

```bash
./host/device-status.sh '<SPEAKER_LAN_IPV4>'
```

## 13. 冷启动验证

> **重启前警告：** 只有在 root 密码救援登录、原厂 `boot1/system1`、USB 恢复模式和备份都已验证可用时，才进行首次冷启动测试。

在严格主机检查的 root SSH 中执行：

```sh
sync
reboot
```

等待音箱完整启动并重新联网，再运行：

```bash
cd /mnt/<DRIVE>/<PATH_TO_REPOSITORY>
./host/device-status.sh '<SPEAKER_LAN_IPV4>'
```

冷启动验收标准：

- librespot、voice bridge、key bridge 和点赞同步 supervisor 自动出现；
- 两个原生进程加载正确过滤器；
- `mobile_auth_bind=active`，旧端口 `18789` 未监听；
- Spotify 授权健康且设备可见；
- 手机接管、实体按键、音乐语音和米家/红外各测试一次；
- 不连接电脑也能持续播放。

建议给音箱设置路由器 DHCP 保留地址。IP 改变只需在 Android 应用中修改；SSH host key 改变则必须停止使用并通过可信物理通道调查，不能在应用中动态接受。

## 14. 回滚

### 14.1 服务或自启动回滚（仍能 root SSH）

先确认 root 密码救援登录仍正常。下面的项目自带脚本会原子移除两组启动标记、解除项目自己的 authorized_keys bind、停止所有项目服务并恢复原生过滤器：

```sh
/data/xiaoaimusic/remove-autostart.sh
```

成功应输出：

```text
AUTOSTART_REMOVED
```

随后重启并验证原生小爱、米家、红外和原生音频。脚本故意保留 `/data/xiaoaimusic` 文件用于调查和再次启用；确认恢复前不要手工递归删除它。

### 14.2 补丁槽不能启动

> **危险：以下命令修改启动环境。** 只在你已经通过备份和实机环境确认原厂恢复槽确实是 `boot1/system1` 时使用。若命名不同，停止。

若还能进入 root SSH：

```sh
fw_env -s boot_part boot1
reboot
```

若补丁槽不能启动，但可信 USB 烧录模式仍可识别：

```text
update.exe bulkcmd "setenv boot_part boot1"
update.exe bulkcmd "saveenv"
```

如果两个系统槽都损坏，只恢复提前从**同一台设备**读出且已记录哈希的原始槽。若 USB 模式也失效，当前公开方案没有经过验证的无拆机全 NAND 恢复流程，只能使用售后、UART 或编程器级维修。

## 15. 常见停止点

- **`preflight.ps1` 报 WSL 工具缺失**：先完整运行 `host/bootstrap-wsl.sh`；确认发行版名称确实是 `Ubuntu`。
- **固件或补丁哈希不匹配**：删除未锁定的上游工作副本后重新同步；仍不匹配就停止，不跳过检查。
- **原生过滤器拒绝加载**：设备二进制不在兼容档案内；不要改常量绕过 fail-closed。
- **SSH 指纹不匹配**：断开网络，从物理通道重新核验；不要删除旧记录后盲目接受。
- **手机公钥为 2048 位**：当前 restricted updater 要求 RSA 3072；停止配对，不放宽验证器。
- **应用显示地址已保存但无法认证**：检查同一 Wi-Fi、AP 隔离、音箱私网 IPv4、固定指纹和受限公钥部署。
- **Spotify 官方验证通过但下发失败**：保留应用数据，使用“重试下发已验证授权”；检查受限 SSH，而不是重新输入 root 密码到手机。
- **Spotify 音量或播放正常，但语音/按键不工作**：检查 local-control socket、key bridge、voice bridge 和过滤器 maps。
- **出现两路音乐或端口 18789 仍监听**：自启动门禁未完成或旧 bridge 未退出；不要重启固化，先回到第 11 节检查。
- **Android 更新提示签名不一致**：只能用原签名密钥构建更新；卸载会导致手机 SSH 身份丢失并要求重新配对。

完成所有冷启动验收后，电脑可以关机。后续 Spotify 浏览器重新授权、自动接管和播放控制由手机与音箱完成。

下一步请阅读[日常使用指南](USAGE.md)。遇到会员提示、双播放器、按键延迟、自动接管、授权、IP、host key 或点赞同步问题时，按[故障排除](TROUBLESHOOTING.md)逐项检查。
