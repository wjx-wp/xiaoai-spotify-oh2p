[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$Path
)

$ErrorActionPreference = 'Stop'
$File = Get-Item -LiteralPath $Path
$Signature = Get-AuthenticodeSignature -LiteralPath $File.FullName
$Hashes = foreach ($Algorithm in @('SHA256', 'SHA1', 'MD5')) {
    Get-FileHash -LiteralPath $File.FullName -Algorithm $Algorithm
}
$Version = $File.VersionInfo

[pscustomobject]@{
    Path = $File.FullName
    Size = $File.Length
    ProductName = $Version.ProductName
    FileVersion = $Version.FileVersion
    SignatureStatus = $Signature.Status
    Signer = $Signature.SignerCertificate.Subject
} | Format-List

$Hashes | Select-Object Algorithm, Hash | Format-Table -AutoSize
Write-Host '此脚本只读取元数据和哈希，不会安装驱动或执行该文件。'
