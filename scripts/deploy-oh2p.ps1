[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9.-]+$')]
    [string]$Ip,
    [switch]$Install
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Package = Join-Path $Root 'artifacts\build\oh2p\package\xiaoaimusic-oh2p'
foreach ($Required in @('bin\librespot', 'bin\xiaoaimusic-spotify-auth-updater',
        'bin\xiaoaimusic-authorized-keys-verify', 'stop-home-bridge.sh', 'install.sh')) {
    if (-not (Test-Path (Join-Path $Package $Required) -PathType Leaf)) {
        throw "设备包不完整（缺少 $Required）；先运行 scripts\build-oh2p.ps1。"
    }
}

if (-not $Install) {
    Write-Host '当前是预演模式：不会连接或修改音箱。'
    Write-Host "确认实机报告和固件版本后，使用："
    Write-Host "  .\scripts\deploy-oh2p.ps1 -Ip $Ip -Install"
    exit 0
}

$Options = @('-4', '-o', 'IPQoS=none', '-o', 'HostKeyAlgorithms=+ssh-rsa',
    '-o', 'PubkeyAcceptedAlgorithms=+ssh-rsa')

& ssh.exe @Options "root@$Ip" 'rm -rf /tmp/xiaoaimusic-install && mkdir -p /tmp/xiaoaimusic-install'
if ($LASTEXITCODE -ne 0) { throw '无法创建临时上传目录。' }

& scp.exe @Options -r "$Package\*" "root@${Ip}:/tmp/xiaoaimusic-install/"
if ($LASTEXITCODE -ne 0) { throw '上传失败。' }

& ssh.exe @Options "root@$Ip" 'chmod 700 /tmp/xiaoaimusic-install/install.sh && /tmp/xiaoaimusic-install/install.sh'
if ($LASTEXITCODE -ne 0) { throw '设备端安装失败。' }

Write-Host '文件已安装，但没有启动 librespot，也没有修改开机自启。'
