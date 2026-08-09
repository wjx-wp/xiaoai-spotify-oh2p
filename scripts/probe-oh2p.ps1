[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9.-]+$')]
    [string]$Ip
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ReportDir = Join-Path $Root 'artifacts\device-reports'
New-Item -ItemType Directory -Force $ReportDir | Out-Null
$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Report = Join-Path $ReportDir "oh2p-$Timestamp.txt"

$RemoteCommand = @'
echo '=== uname ==='; uname -a
echo '=== release ==='; cat /etc/openwrt_release 2>/dev/null
echo '=== mico version ==='; cat /usr/share/mico/version 2>/dev/null
echo '=== cpu ==='; cat /proc/cpuinfo
echo '=== memory ==='; cat /proc/meminfo
echo '=== mtd ==='; cat /proc/mtd
echo '=== cmdline ==='; cat /proc/cmdline
echo '=== mounts ==='; mount
echo '=== disk ==='; df -h
echo '=== boot env ==='; fw_env -g boot_part 2>/dev/null; fw_env -g bootdelay 2>/dev/null
echo '=== network ==='; ip addr; ip route
echo '=== processes ==='; ps w
echo '=== playback ==='; aplay -l 2>/dev/null
echo '=== capture ==='; arecord -l 2>/dev/null
echo '=== asound ==='; cat /etc/asound.conf 2>/dev/null
echo '=== device nodes ==='; ls -la /dev/mtd* /dev/block/env /dev/block/ubootenv /dev/dtb 2>/dev/null
'@

$Options = @(
    '-4', '-o', 'IPQoS=none',
    '-o', 'HostKeyAlgorithms=+ssh-rsa',
    '-o', 'PubkeyAcceptedAlgorithms=+ssh-rsa',
    '-o', 'KexAlgorithms=curve25519-sha256@libssh.org,diffie-hellman-group14-sha1,diffie-hellman-group1-sha1'
)

$Output = & ssh.exe @Options "root@$Ip" $RemoteCommand 2>&1
$ExitCode = $LASTEXITCODE
$Output | Set-Content -Encoding UTF8 $Report
if ($ExitCode -ne 0) { throw "SSH 探测失败；输出保存在 $Report" }

Write-Host "只读报告已保存：$Report"
Write-Host '脚本没有读取 /data/TOKEN、/data/miio、Wi-Fi 配置或小米账号凭据。'
