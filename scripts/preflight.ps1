[CmdletBinding()]
param(
    [switch]$RequireReferenceFirmware
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Lock = Get-Content -Raw -Encoding UTF8 (Join-Path $Root 'resources.lock.json') | ConvertFrom-Json
$Failed = $false

foreach ($Name in @('git.exe', 'node.exe', 'npm.cmd', 'wsl.exe', 'ssh.exe', 'scp.exe')) {
    $Command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($Command) {
        Write-Host ("OK   {0,-12} {1}" -f $Name, $Command.Source)
    } else {
        Write-Host ("MISS {0}" -f $Name) -ForegroundColor Red
        $Failed = $true
    }
}

foreach ($Source in $Lock.upstreams) {
    $Repo = Join-Path $Root ("upstream\{0}" -f $Source.name)
    $Head = if (Test-Path (Join-Path $Repo '.git')) {
        (& git.exe -C $Repo rev-parse HEAD 2>$null).Trim()
    } else { '' }
    if ($Head -eq $Source.commit) {
        Write-Host "OK   $($Source.name) @ $Head"
    } else {
        Write-Host "MISS $($Source.name) locked commit $($Source.commit)" -ForegroundColor Red
        $Failed = $true
    }
}

foreach ($Patch in $Lock.localPatches) {
    $PatchPath = Join-Path $Root $Patch.file
    if ((Test-Path $PatchPath) -and
        (Get-FileHash -Algorithm SHA256 $PatchPath).Hash.ToLowerInvariant() -eq $Patch.sha256) {
        Write-Host "OK   $($Patch.repo) patch $($Patch.sha256)"
    } else {
        Write-Host "MISS $($Patch.repo) patch or hash mismatch" -ForegroundColor Red
        $Failed = $true
    }
}

$FirmwarePath = Join-Path $Root ("artifacts\firmware\oh2p\1.62.2\{0}" -f $Lock.firmware.filename)
if (Test-Path $FirmwarePath) {
    $File = Get-Item $FirmwarePath
    $Md5 = (Get-FileHash -Algorithm MD5 $FirmwarePath).Hash.ToLowerInvariant()
    $Sha256 = (Get-FileHash -Algorithm SHA256 $FirmwarePath).Hash.ToLowerInvariant()
    if ($File.Length -eq [int64]$Lock.firmware.size -and
        $Md5 -eq $Lock.firmware.md5 -and $Sha256 -eq $Lock.firmware.sha256) {
        Write-Host "OK   firmware size=$($File.Length) md5=$Md5 sha256=$Sha256"
    } else {
        Write-Host 'FAIL firmware hash/size mismatch' -ForegroundColor Red
        $Failed = $true
    }
} else {
    if ($RequireReferenceFirmware) {
        Write-Host 'MISS explicitly required reference firmware' -ForegroundColor Red
        $Failed = $true
    } else {
        Write-Host 'INFO experimental reference firmware is not present (runtime-only mode)'
    }
}

$Drive = $Root.Substring(0, 1).ToLowerInvariant()
$LinuxRoot = "/mnt/$Drive/" + $Root.Substring(3).Replace('\', '/')
if ($LinuxRoot) {
    & wsl.exe -d Ubuntu -- bash "$LinuxRoot/host/preflight-linux.sh"
    if ($LASTEXITCODE -ne 0) { $Failed = $true }

    & wsl.exe -d Ubuntu -- bash "$LinuxRoot/host/validate-scripts.sh"
    if ($LASTEXITCODE -eq 0) {
        Write-Host 'OK   shell syntax'
    } else {
        Write-Host 'FAIL shell syntax' -ForegroundColor Red
        $Failed = $true
    }
}

if ($Failed) { throw '预检未通过；请根据上面的具体失败项修复。' }
Write-Host '全部到货前预检通过。' -ForegroundColor Green
