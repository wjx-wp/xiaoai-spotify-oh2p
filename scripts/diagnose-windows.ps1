$ErrorActionPreference = 'Continue'
$projectRoot = Split-Path -Parent $PSScriptRoot

Write-Host '=== Windows 音频端点 ==='
Get-PnpDevice -Class AudioEndpoint |
    Where-Object { $_.FriendlyName -match '小爱|Xiaomi|Mi|LX05|L05B|Speaker|扬声器' } |
    Select-Object Status, FriendlyName |
    Format-Table -AutoSize

Write-Host '=== Spotify 应用 ==='
$spotifyProcess = Get-Process Spotify -ErrorAction SilentlyContinue
if ($spotifyProcess) {
    $spotifyProcess | Select-Object ProcessName, Id, Path | Format-Table -AutoSize
}
else {
    Write-Host 'Spotify 桌面客户端未运行。'
}

Write-Host '=== 在线服务 ==='
Push-Location $projectRoot
try {
    & npm.cmd run diagnose
}
finally {
    Pop-Location
}
