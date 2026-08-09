[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9.-]+$')]
    [string]$Ip
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$WslRoot = (& wsl.exe -e wslpath -a $Root).Trim()
if ($LASTEXITCODE -ne 0 -or -not $WslRoot) {
    throw '无法把项目路径转换为 WSL 路径。'
}

& wsl.exe -e bash "$WslRoot/host/deploy-spotify-auth.sh" $Ip
if ($LASTEXITCODE -ne 0) {
    throw 'Spotify 授权部署失败。'
}
