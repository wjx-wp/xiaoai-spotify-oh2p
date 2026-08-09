# OH2P 安全与恢复清单

## 首刷边界

只允许写入一个非活动系统槽（计划为 `system0`），同时保留可启动的原厂 `boot1/system1`。首阶段禁止改写：

- BL2、TPL、U-Boot、DTB、bootloader；
- `boot1`、`system1`；
- `/data`、环境分区和设备身份分区；
- 任何无法由实机 `/proc/mtd` 对应确认的 MTD 编号。

禁止执行 `disk_initial`、`defenv`、`store erase`、`flash_erase` 或整 NAND 写入。

## 刷写前只读备份

先用 Amlogic 工具确认 `mread` 能只读导出两个 40 MiB rootfs 槽：

```sh
update.exe mread store system0 normal 0x02800000 system0.factory.bin
update.exe mread store system1 normal 0x02800000 system1.factory.bin
certutil -hashfile system0.factory.bin SHA256
certutil -hashfile system1.factory.bin SHA256
```

社区 OH2P 教程没有系统验证 `mread` 备份流程，因此命令失败就停止，不猜偏移、不改成其它写命令。把导出镜像在 WSL 中用 `unsquashfs -s` 和 `/usr/share/mico/version` 复核。

首次 SSH 后，先保存 `/proc/mtd`，再按实机列出的每个只读 MTD 逐一备份。二进制流使用 Git Bash 或能保证字节不转码的程序，不使用旧版 Windows PowerShell 文本重定向。

`/data` 备份可能含 DID、miio key、Wi-Fi 与账号令牌，必须加密并保存在 `.secrets/` 或 `artifacts/device-backups/`，不得提交。

## 回滚

如果补丁槽不启动，但 USB 烧录模式仍可识别：

```sh
update.exe bulkcmd "setenv boot_part boot1"
update.exe bulkcmd "saveenv"
```

如果能进入 SSH：

```sh
fw_env -s boot_part boot1
reboot
```

如果两个系统槽都损坏但 USB 模式仍在，只恢复提前备份且哈希已记录的同机原始槽。若 USB 模式也永久失效，当前公开社区资源没有经验证的 OH2P 无拆机全 NAND 恢复流程，只能走售后、UART 或编程器级维修。

## 隐私边界

`probe-oh2p.ps1` 有意不读取以下路径内容：

```text
/data/etc/device.info
/data/miio
/data/TOKEN
/data/wifi
/data/bt
```

分享设备报告前仍要人工检查序列号、MAC、IP 和其它身份信息。
