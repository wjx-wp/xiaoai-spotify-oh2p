[CmdletBinding()]
param(
    [switch]$SkipBootstrap,
    [switch]$SkipFirmware,
    [switch]$WithReferenceFirmware,
    [switch]$SkipAgent,
    [switch]$SkipLibrespot
)

$ErrorActionPreference = 'Stop'
if ($SkipFirmware -and $WithReferenceFirmware) {
    throw 'SkipFirmware and WithReferenceFirmware cannot be used together.'
}
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Drive = $Root.Substring(0, 1).ToLowerInvariant()
$LinuxRoot = "/mnt/$Drive/" + $Root.Substring(3).Replace('\', '/')

if (-not $SkipBootstrap) {
    & wsl.exe -d Ubuntu -- bash "$LinuxRoot/host/bootstrap-wsl.sh"
    if ($LASTEXITCODE -ne 0) { throw 'WSL 构建环境安装失败。' }
}

$Arguments = @("$LinuxRoot/host/build-oh2p.sh")
if ($SkipFirmware) { $Arguments += '--skip-firmware' }
if ($WithReferenceFirmware) { $Arguments += '--with-reference-firmware' }
if ($SkipAgent) { $Arguments += '--skip-agent' }
if ($SkipLibrespot) { $Arguments += '--skip-librespot' }

& wsl.exe -d Ubuntu -- bash @Arguments
if ($LASTEXITCODE -ne 0) { throw 'OH2P 构建失败。' }

Write-Host "构建完成：$(Join-Path $Root 'artifacts\build\oh2p')" -ForegroundColor Green
