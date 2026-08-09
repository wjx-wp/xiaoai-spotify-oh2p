[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Lock = Get-Content -Raw -Encoding UTF8 (Join-Path $Root 'resources.lock.json') | ConvertFrom-Json

function Invoke-Git {
    param([string[]]$Arguments)
    & git.exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "git 失败：git $($Arguments -join ' ')"
    }
}

foreach ($Source in $Lock.upstreams) {
    $Destination = Join-Path $Root ("upstream\{0}" -f $Source.name)
    if (-not (Test-Path (Join-Path $Destination '.git'))) {
        New-Item -ItemType Directory -Force (Split-Path $Destination) | Out-Null
        Invoke-Git @('clone', '--filter=blob:none', '--no-checkout', $Source.url, $Destination)
        Invoke-Git @('-C', $Destination, 'fetch', '--depth=1', 'origin', $Source.commit)
        Invoke-Git @('-C', $Destination, 'checkout', '--detach', $Source.commit)
    }

    $Head = (& git.exe -C $Destination rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $Head -ne $Source.commit) {
        throw "$($Source.name) 版本不匹配：实际 $Head，要求 $($Source.commit)"
    }
    Write-Host "OK   $($Source.name) @ $Head"
}

foreach ($LocalPatch in $Lock.localPatches) {
    $PatchPath = Join-Path $Root $LocalPatch.file
    $PatchHash = (Get-FileHash -Algorithm SHA256 $PatchPath).Hash.ToLowerInvariant()
    if ($PatchHash -ne $LocalPatch.sha256) {
        throw "$($LocalPatch.repo) 本地补丁哈希错误：$PatchHash"
    }

    $TargetRepo = Join-Path $Root ("upstream\{0}" -f $LocalPatch.repo)
    if (-not (Test-Path (Join-Path $TargetRepo '.git'))) {
        throw "缺少补丁目标仓库：$($LocalPatch.repo)"
    }

    $PreviousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & git.exe -C $TargetRepo apply --check $PatchPath 2>$null
    $CanApply = $LASTEXITCODE -eq 0
    $ErrorActionPreference = $PreviousPreference

    if ($CanApply) {
        Invoke-Git @('-C', $TargetRepo, 'apply', $PatchPath)
        Write-Host "OK   已应用 $($LocalPatch.repo) 补丁"
        continue
    }

    $PreviousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & git.exe -C $TargetRepo apply --reverse --check $PatchPath 2>$null
    $IsApplied = $LASTEXITCODE -eq 0
    $ErrorActionPreference = $PreviousPreference
    if (-not $IsApplied) {
        throw "$($LocalPatch.repo) 补丁既不能应用，也不是已应用状态；请检查工作区冲突。"
    }
    Write-Host "OK   $($LocalPatch.repo) 补丁已经应用"
}

$FirmwareDir = Join-Path $Root 'artifacts\firmware\oh2p\1.62.2'
$FirmwarePath = Join-Path $FirmwareDir $Lock.firmware.filename
if (-not (Test-Path $FirmwarePath)) {
    if ($env:XIAOAI_DOWNLOAD_REFERENCE_FIRMWARE -ne 'I_UNDERSTAND_1_62_2_ONLY') {
        Write-Warning '未下载实验性 1.62.2 参考 OTA。若设备已确认是同版本，并理解跨版本刷写风险，请显式设置 XIAOAI_DOWNLOAD_REFERENCE_FIRMWARE=I_UNDERSTAND_1_62_2_ONLY 后重试。'
        Write-Host '资源源码与补丁同步完成；固件下载已安全跳过。'
        return
    }
    New-Item -ItemType Directory -Force $FirmwareDir | Out-Null
    $PartPath = "$FirmwarePath.part"
    Invoke-WebRequest -Uri $Lock.firmware.url -OutFile $PartPath
    Move-Item -LiteralPath $PartPath -Destination $FirmwarePath
}

$Firmware = Get-Item $FirmwarePath
$Md5 = (Get-FileHash -Algorithm MD5 $FirmwarePath).Hash.ToLowerInvariant()
$Sha256 = (Get-FileHash -Algorithm SHA256 $FirmwarePath).Hash.ToLowerInvariant()
if ($Firmware.Length -ne [int64]$Lock.firmware.size -or
    $Md5 -ne $Lock.firmware.md5 -or
    $Sha256 -ne $Lock.firmware.sha256) {
    throw "固件校验失败；不会继续使用：$FirmwarePath"
}

Write-Host "OK   OH2P 1.62.2 OTA size=$($Firmware.Length) md5=$Md5 sha256=$Sha256"
Write-Host '资源同步与完整性校验完成。'
