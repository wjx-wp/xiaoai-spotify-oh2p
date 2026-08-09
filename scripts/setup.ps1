[CmdletBinding()]
param(
    [switch]$InstallSpotify,
    [switch]$OpenBluetoothSettings
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
    throw '未找到 Node.js。请安装 Node.js 20.6 或更新版本。'
}

$major = [int]((& node --version).TrimStart('v').Split('.')[0])
if ($major -lt 20) {
    throw "Node.js 版本过旧：$(& node --version)。需要 20.6 或更新版本。"
}

if (-not (Test-Path -LiteralPath (Join-Path $projectRoot '.env'))) {
    Copy-Item -LiteralPath (Join-Path $projectRoot '.env.example') -Destination (Join-Path $projectRoot '.env')
    Write-Host '已创建 .env；稍后请填入账号配置。'
}

Push-Location $projectRoot
try {
    & npm.cmd install
    if ($LASTEXITCODE -ne 0) { throw 'npm install 失败' }
}
finally {
    Pop-Location
}

if ($InstallSpotify) {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) { throw '未找到 winget，无法自动安装 Spotify。' }
    & winget install --id Spotify.Spotify -e --accept-source-agreements --accept-package-agreements
}

if ($OpenBluetoothSettings) {
    Start-Process 'ms-settings:bluetooth'
}

Write-Host ''
Write-Host '基础环境已准备好。'
Write-Host '1. 对音箱说“小爱同学，打开蓝牙”，然后在 Windows 中配对。'
Write-Host '2. 把小爱音箱设为 Windows 声音输出，并登录 Spotify 桌面客户端。'
Write-Host '3. 编辑 .env；需要语音控制时再运行 npm run auth。'
