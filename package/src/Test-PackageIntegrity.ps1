#Requires -Version 7.4
<#
.SYNOPSIS
    Verifies the authenticated Exchange Log Report package before any of its code runs.

.DESCRIPTION
    Invoked by the launchers, by Invoke-ExchangeLogReport.ps1, by Database-Storage.ps1, by the module (import and
    engine initialization) and by the package builder. It requires a valid, timestamped owner signature on this
    script, on PackageIntegrity.psd1 and on every PowerShell file of the inventory, then compares the SHA256 of every
    inventory file (C# sources, SQLite libraries, report template, HTML guides, README, notices, launchers) with the
    signed manifest. Missing, changed, unknown or reparse-point files fail closed.

    The manifest has two lists. Files are present in the source tree and in the package. DistributionFiles are the
    built binaries (powershell\, sqlite-tools\) that exist in the package only; they are hash-protected by the
    signed manifest, not signed by the owner.

    Not protected, by design: config\ExchangeLogReport.config.psd1, config\ExchangeLogReport.paths.psd1 and
    config\ExchangeLogReport.mail.credential (edited or written by the administrator), and the generated
    folders bin\, data\, logs\ and reports\ (never executed: no compiled cache is loaded).

.PARAMETER Root
    Package folder to verify, not its src subfolder. This script must belong to that package's src folder.

.PARAMETER Distribution
    Verifies a release package: the files copied by the package builder are required and every file of
    DistributionFiles is hashed. A file under powershell\ or sqlite-tools\ that the manifest does not list is
    refused. Refused together with -DevelopmentMode.

.PARAMETER DevelopmentMode
    For an unsigned continuous-integration build or a developer package: the files and the six PowerShell
    signatures are still enforced, the built binaries are not verified (a warning says so).
    Without -Distribution and -DevelopmentMode only Files are verified; the built binaries are not examined.

.NOTES
    Author  : Nicolas Fabert
    Version : 3.0.1
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Root, [switch]$Distribution, [switch]$DevelopmentMode)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Distribution -and $DevelopmentMode) { throw 'Package integrity: -Distribution and -DevelopmentMode cannot be combined.' }
$signer = '0F28E442889F17B5F4D251E8F96E7CC6E2C9C6D6'
# What to do, at the end of the two refusals an unsigned or re-saved package meets first.
$releaseHint = 'Use the complete release ZIP (https://github.com/Nico77600/ExchangeLogReport/releases/latest): extract it again and unblock it. A modified, re-saved or unsigned file cannot be started by the launchers. A development or CI build is started from its folder with powershell\pwsh.exe -NoLogo -NoProfile -File Invoke-ExchangeLogReport.ps1 <parameters> -DevelopmentMode (or Database-Storage.ps1 -DevelopmentMode <arguments>).'
$rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\')
$signed = @(
    'Invoke-ExchangeLogReport.ps1'
    'Database-Storage.ps1'
    'ExchangeLogReport.psm1'
    'ExchangeLogReport.psd1'
    'src\Test-PackageIntegrity.ps1'
    'src\Get-ExlExchangeSettings.ps1'
)
$required = @($signed) + @(
    'src\Engine.Collector.cs'
    'src\Engine.Mail.cs'
    'src\Engine.Pipeline.cs'
    'src\Engine.Report.cs'
    'src\Engine.ReportExecution.cs'
    'src\Engine.ReportHtml.cs'
    'src\Engine.ReportRoute.cs'
    'src\Engine.ReportRows.cs'
    'src\Engine.ReportSessions.cs'
    'src\Engine.ReportTranscripts.cs'
    'src\Engine.Serve.cs'
    'src\Engine.ServeAggregates.cs'
    'src\Engine.ServeDiagnostics.cs'
    'src\Engine.ServeFilterExpression.cs'
    'src\Engine.ServeQuery.cs'
    'src\Engine.ServeRollup.cs'
    'src\Engine.ServeScan.cs'
    'src\Engine.ServeUsage.cs'
    'src\Engine.ServeVerification.cs'
    'src\Engine.Sessions.cs'
    'src\Engine.SmtpAuth.cs'
    'src\Engine.SmtpClients.cs'
    'src\Engine.Store.cs'
    'src\Engine.Text.cs'
    'src\Storage.Audit.cs'
    'src\Storage.Cli.cs'
    'src\Storage.Fingerprint.cs'
    'src\Storage.LegacyRollup.cs'
    'src\Storage.Maintenance.cs'
    'src\Storage.RollupVerification.cs'
    'src\Storage.Safety.cs'
    'lib\sqlite\Microsoft.Data.Sqlite.dll'
    'lib\sqlite\SQLitePCLRaw.core.dll'
    'lib\sqlite\SQLitePCLRaw.provider.e_sqlite3.dll'
    'lib\sqlite\SQLitePCLRaw.batteries_v2.dll'
    'lib\sqlite\runtimes\win-x64\e_sqlite3.dll'
    'lib\sqlite\runtimes\win-arm64\e_sqlite3.dll'
    'templates\Report.template.html'
    'templates\Report.template.js'
    'docs\ExchangeLogReport-Guide.html'
    'docs\ExchangeLogReport-UserGuide.html'
    'README.md'
    'THIRD-PARTY-NOTICES.md'
    'Run-Collector.cmd'
    'Start-Portal.cmd'
    'Database-Storage.cmd'
)
# Copied from the repository root or produced by the package build: hashed, required only in a distribution.
$distributionOnly = @(
    'CHANGELOG.md'
    'LICENSE'
    'SECURITY.md'
    'product.json'
    'sqlite-tools\NOTICE.txt'
)
# Folders that exist in a built package only; their files are listed in DistributionFiles.
$binaryFolders = @('powershell', 'sqlite-tools')
$binaryRequired = @('powershell\pwsh.exe', 'sqlite-tools\sqlite3.exe')
# Repository-only documents are not loaded by the engine or copied into the distribution.
# These exact names (not an extension or directory wildcard) are the only unhashed source extras.
$sourceDocuments = @(
    'docs\ExchangeLogReport-Guide.md'
    'docs\ExchangeLogReport-UserGuide.md'
    'docs\images\console-report.png'
    'docs\images\mail-daily-problems.png'
    'docs\images\portal-authentication.png'
    'docs\images\portal-authentication-row.png'
    'docs\images\portal-export.png'
    'docs\images\portal-message-route.png'
    'docs\images\portal-overview.png'
    'docs\images\portal-overview-dark.png'
    'docs\images\portal-server-selection.png'
    'docs\images\portal-session-timeline.png'
    'docs\images\portal-sessions-remote.png'
    'docs\images\readme-banner-dark.svg'
    'docs\images\readme-banner-light.svg'
    'docs\images\readme-console-report.png'
    'docs\images\readme-how-dark.png'
    'docs\images\readme-how-light.png'
    'docs\images\readme-mail-daily.png'
    'docs\images\readme-noise-dark.png'
    'docs\images\readme-noise-light.png'
    'docs\images\readme-path-dark.png'
    'docs\images\readme-path-light.png'
    'docs\images\readme-report-message.png'
    'docs\images\readme-report-overview.png'
    'docs\images\readme-report-session.png'
    'docs\images\readme-report-smtp-client.png'
    'docs\images\readme-sessions-dark.png'
    'docs\images\readme-sessions-light.png'
    'docs\images\readme-why-dark.png'
    'docs\images\readme-why-light.png'
    'docs\images\report-client-sessions.png'
    'docs\images\report-message-route.png'
    'docs\images\report-overview.png'
    'docs\images\report-session-step.png'
    'docs\images\report-session-timeline.png'
    'docs\images\report-smtp-clients.png'
    'docs\images\usage-decommission.png'
)
# Written or edited by the administrator; they are data, never executed.
$editableFiles = @(
    'config\ExchangeLogReport.config.psd1'
    'config\ExchangeLogReport.paths.psd1'
    'config\ExchangeLogReport.mail.credential'
)
$inventory = @($required) + @($distributionOnly)
function Assert-PlainPath([string]$Path, [bool]$Directory = $false) {
    $item = Microsoft.PowerShell.Management\Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint -or $item.PSIsContainer -ne $Directory) {
        throw "Package integrity: unsafe path or unexpected type: $Path"
    }
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    while ($parent) {
        $ancestor = Microsoft.PowerShell.Management\Get-Item -LiteralPath $parent -Force -ErrorAction Stop
        if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Package integrity: reparse-point ancestor: $parent"
        }
        $parent = [IO.Path]::GetDirectoryName($parent)
    }
}
function Assert-OwnerSignature([string]$Path) {
    $signature = Microsoft.PowerShell.Security\Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    if ([string]$signature.Status -cne 'Valid' -or $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Thumbprint -cne $signer -or $null -eq $signature.TimeStamperCertificate) {
        throw "Package integrity: expected trusted, timestamped owner signature: $Path. $releaseHint"
    }
}
function Test-Entry($Entry) {
    $Entry -is [hashtable] -and $Entry.Count -eq 2 -and $Entry.ContainsKey('Path') -and $Entry.ContainsKey('Sha256') -and
        $Entry.Path -is [string] -and $Entry.Sha256 -is [string] -and $Entry.Sha256 -cmatch '^[0-9A-F]{64}$'
}
Assert-PlainPath $rootPath $true
if (-not [string]::Equals([IO.Path]::GetFullPath($PSCommandPath),
    [IO.Path]::Combine($rootPath, 'src', 'Test-PackageIntegrity.ps1'), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Package integrity: verifier must belong to this package root.'
}
Assert-PlainPath $PSCommandPath
Assert-OwnerSignature $PSCommandPath
$manifestPath = [IO.Path]::Combine($rootPath, 'PackageIntegrity.psd1')
if (-not [IO.File]::Exists($manifestPath)) { throw "Package integrity: PackageIntegrity.psd1 is missing. $releaseHint" }
Assert-PlainPath $manifestPath
Assert-OwnerSignature $manifestPath
# Authenticate the raw PSD1 before parsing its restricted data language.
$manifest = Microsoft.PowerShell.Utility\Import-PowerShellDataFile -LiteralPath $manifestPath -ErrorAction Stop
if ($manifest.Count -ne 6 -or -not $manifest.ContainsKey('SchemaVersion') -or
    -not $manifest.ContainsKey('Algorithm') -or -not $manifest.ContainsKey('SignerThumbprint') -or
    -not $manifest.ContainsKey('Version') -or -not $manifest.ContainsKey('Files') -or
    -not $manifest.ContainsKey('DistributionFiles') -or $manifest.SchemaVersion -isnot [int] -or
    $manifest.SchemaVersion -ne 1 -or $manifest.Algorithm -cne 'SHA256' -or
    $manifest.SignerThumbprint -cne $signer -or $manifest.Version -isnot [string] -or
    $manifest.Files -isnot [array] -or $manifest.DistributionFiles -isnot [array]) {
    throw 'Package integrity: unsupported or incomplete manifest schema.'
}
if ($manifest.Files.Count -ne $inventory.Count) {
    throw "Package integrity: the manifest lists $($manifest.Files.Count) files, $($inventory.Count) expected."
}
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($entry in $manifest.Files) {
    if (-not (Test-Entry $entry) -or $entry.Path -cnotin $inventory -or -not $seen.Add($entry.Path)) {
        throw 'Package integrity: invalid, duplicate or unapproved inventory path/hash.'
    }
    $path = [IO.Path]::Combine($rootPath, $entry.Path)
    if ($entry.Path -cin $distributionOnly -and -not $Distribution -and
        -not (Microsoft.PowerShell.Management\Test-Path -LiteralPath $path)) { continue }
    Assert-PlainPath $path
    $hash = (Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash
    if ($hash -cne $entry.Sha256) { throw "Package integrity: SHA256 mismatch: $($entry.Path)" }
    if ($entry.Path -cmatch '\.ps(m1|d1|1)$') { Assert-OwnerSignature $path }
}
foreach ($path in $inventory) {
    if (-not $seen.Contains($path)) { throw "Package integrity: missing inventory path: $path" }
}
# Built binaries: validated as a list in every mode, hashed only in a distribution.
$binary = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($entry in $manifest.DistributionFiles) {
    if (-not (Test-Entry $entry)) { throw 'Package integrity: invalid binary inventory entry.' }
    $parts = $entry.Path.Split('\')
    if ($parts.Count -lt 2 -or $parts[0] -cnotin $binaryFolders -or $entry.Path.StartsWith('\') -or $entry.Path.Contains('/') -or
        $entry.Path.Contains(':') -or ($parts | Where-Object { $_ -eq '' -or $_ -eq '.' -or $_ -eq '..' })) {
        throw "Package integrity: binary path outside powershell and sqlite-tools: $($entry.Path)"
    }
    if (-not $binary.TryAdd($entry.Path, $entry.Sha256)) { throw "Package integrity: duplicate binary inventory path: $($entry.Path)" }
}
foreach ($path in $binaryRequired) {
    if (-not $binary.ContainsKey($path)) { throw "Package integrity: missing binary inventory path: $path" }
}
$status = 'Valid (files only)'
if ($Distribution) {
    foreach ($pair in $binary.GetEnumerator()) {
        $path = [IO.Path]::Combine($rootPath, $pair.Key)
        Assert-PlainPath $path
        $hash = (Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash
        if ($hash -cne $pair.Value) { throw "Package integrity: SHA256 mismatch: $($pair.Key)" }
    }
    $runtime = Microsoft.PowerShell.Security\Get-AuthenticodeSignature -LiteralPath ([IO.Path]::Combine($rootPath, 'powershell', 'pwsh.exe')) -ErrorAction Stop
    if ([string]$runtime.Status -cne 'Valid' -or $null -eq $runtime.SignerCertificate -or $runtime.SignerCertificate.Subject -notmatch '(^|, )O=Microsoft Corporation(,|$)') {
        throw 'Package integrity: powershell\pwsh.exe must carry a valid Microsoft signature.'
    }
    $product = Microsoft.PowerShell.Management\Get-Content -LiteralPath ([IO.Path]::Combine($rootPath, 'product.json')) -Raw | Microsoft.PowerShell.Utility\ConvertFrom-Json
    if (($binary['sqlite-tools\sqlite3.exe']) -cne ([string]$product.sqliteTools.executableSha256).ToUpperInvariant()) {
        throw 'Package integrity: sqlite-tools\sqlite3.exe is not the pinned SQLite command-line tool.'
    }
    $status = 'Valid'
} elseif ($DevelopmentMode) {
    Write-Warning 'Package integrity: DevelopmentMode: the built binaries (powershell, sqlite-tools) are not verified; the files and the PowerShell signatures are.'
    $status = 'Valid (binaries not verified: DevelopmentMode)'
}
$queue = [Collections.Generic.Queue[string]]::new()
$queue.Enqueue($rootPath)
while ($queue.Count) {
    $directory = $queue.Dequeue()
    foreach ($item in Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop) {
        $relative = [IO.Path]::GetRelativePath($rootPath, $item.FullName)
        if ($directory -ceq $rootPath -and $item.PSIsContainer -and $item.Name -cin @('bin', 'data', 'logs', 'reports')) {
            continue
        }
        if ($directory -ceq $rootPath -and $item.PSIsContainer -and $item.Name -cin $binaryFolders -and -not $Distribution) {
            # Built binaries are listed in DistributionFiles; they are examined only by -Distribution.
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Package integrity: protected reparse point: $relative" }
            continue
        }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Package integrity: protected reparse point: $relative"
        }
        if ($item.PSIsContainer) { $queue.Enqueue($item.FullName); continue }
        # The owner-signed manifest itself (authenticated above, before it was parsed).
        if ($relative -ceq 'PackageIntegrity.psd1') { continue }
        if ($relative -cin $editableFiles -or $relative -cin $sourceDocuments) { continue }
        if ($relative -cin $inventory) { continue }
        if ($Distribution -and $binary.ContainsKey($relative)) { continue }
        throw "Package integrity: unexpected stable file: $relative"
    }
}
[pscustomobject]@{
    Name              = 'ExchangeLogReport'
    Version           = $manifest.Version
    Files             = $manifest.Files.Count
    DistributionFiles = $manifest.DistributionFiles.Count
    Status            = $status
    Signer            = $signer
}
# SIG # Begin signature block
# MIImKQYJKoZIhvcNAQcCoIImGjCCJhYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAVB8RFBvksHnAM
# 7XAWY66HZR3u57O0axUWcRASR5SsIaCCDW8wggZyMIIEWqADAgECAghkM1HTxzif
# CDANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMx
# EDAOBgNVBAcMB0hvdXN0b24xGDAWBgNVBAoMD1NTTCBDb3Jwb3JhdGlvbjExMC8G
# A1UEAwwoU1NMLmNvbSBSb290IENlcnRpZmljYXRpb24gQXV0aG9yaXR5IFJTQTAe
# Fw0xNjA2MjQyMDQ0MzBaFw0zMTA2MjQyMDQ0MzBaMHgxCzAJBgNVBAYTAlVTMQ4w
# DAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjERMA8GA1UECgwIU1NMIENv
# cnAxNDAyBgNVBAMMK1NTTC5jb20gQ29kZSBTaWduaW5nIEludGVybWVkaWF0ZSBD
# QSBSU0EgUjEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCfgxNzqrDG
# bSHL24t6h3TQcdyOl3Ka5LuINLTdgAPGL0WkdJq/Hg9Q6p5tePOf+lEmqT2d0bKU
# Vz77OYkbkStW72fL5gvjDjmMxjX0jD3dJekBrBdCfVgWQNz51ShEHZVkMGE6ZPKX
# 13NMfXsjAm3zdetVPW+qLcSvvnSsXf5qtvzqXHnpD0OctVIFD+8+sbGP0EmtpuNC
# GVQ/8y8Ooct8/hP5IznaJRy4PgBKOm8yMDdkHseudQfYVdIYyQ6KvKNc8HwKp4WB
# wg6vj5lc02AlvINaaRwlE81y9eucgJvcLGfE3ckJmNVz68Qho+Uyjj4vUpjGYDdk
# jLJvSlRyGMwnh/rNdaJjIUy1PWT9K6abVa8mTGC0uVz+q0O9rdATZlAfC9KJpv/X
# gAbxwxECMzNhF/dWH44vO2jnFfF3VkopngPawismYTJboFblSSmNNqf1x1KiVgMg
# Lzh4gL32Bq5BNMuURb2bx4kYHwu6/6muakCZE93vUN8BuvIE1tAx3zQ4XldbyDge
# VtSsSKbt//m4wTvtwiS+RGCnd83VPZhZtEPqqmB9zcLlL/Hr9dQg1Zc0bl0EawUR
# 0tOSjAknRO1PNTFGfnQZBWLsiePqI3CY5NEv1IoTGEaTZeVYc9NMPSd6Ij/D+KNV
# t/nmh4LsRR7Fbjp8sU65q2j3m2PVkUG8qQIDAQABo4H7MIH4MA8GA1UdEwEB/wQF
# MAMBAf8wHwYDVR0jBBgwFoAU3QQJB6L1en1SUxKSle44gCUNplkwMAYIKwYBBQUH
# AQEEJDAiMCAGCCsGAQUFBzABhhRodHRwOi8vb2NzcHMuc3NsLmNvbTARBgNVHSAE
# CjAIMAYGBFUdIAAwEwYDVR0lBAwwCgYIKwYBBQUHAwMwOwYDVR0fBDQwMjAwoC6g
# LIYqaHR0cDovL2NybHMuc3NsLmNvbS9zc2wuY29tLXJzYS1Sb290Q0EuY3JsMB0G
# A1UdDgQWBBRUwv4QlQCTzWr158DX2bJLuI8M4zAOBgNVHQ8BAf8EBAMCAYYwDQYJ
# KoZIhvcNAQELBQADggIBAPUPJodwr5miyvXWyfCNZj05gtOII9iCv49UhCe204MH
# 154niU2EjlTRIO5gQ9tXQjzHsJX2vszqoz2OTwbGK1mGf+tzG8rlQCbgPW/M9r1x
# xs19DiBAOdYF0q+UCL9/wlG3K7V7gyHwY9rlnOFpLnUdTsthHvWlM98CnRXZ7WmT
# V7pGRS6AvGW+5xI+3kf/kJwQrfZWsqTU+tb8LryXIbN2g9KR+gZQ0bGAKID+260P
# Z+34fdzZcFt6umi1s0pmF4/n8OdX3Wn+vF7h1YyfE7uVmhX7eSuF1W0+Z0duGwdc
# +1RFDxYRLhHDsLy1bhwzV5Qe/kI0Ro4xUE7bM1eV+jjk5hLbq1guRbfZIsr0WkdJ
# LCjoT4xCPGRo6eZDrBmRqccTgl/8cQo3t51Qezxd96JSgjXktefTCm9r/o35pNfV
# HUvnfWII+NnXrJlJ27WEQRQu9i5gl1NLmv7xiHp0up516eDap8nMLDt7TAp4z5T3
# NmC2gzyKVMtODWgqlBF1JhTqIDfM63kXdlV4cW3iSTgzN9vkbFnHI2LmvM4uVEv9
# XgMqyN0eS3FE0HU+MWJliymm7STheh2ENH+kF3y0rH0/NVjLw78a3Z9UVm1F5VPz
# iIorMaPKPlDRADTsJwjDZ8Zc6Gi/zy4WZbg8Zv87spWrmo2dzJTw7XhQf+xkR6Od
# MIIG9TCCBN2gAwIBAgIQBof4ljXihJpmCqqt2mhAWzANBgkqhkiG9w0BAQsFADB4
# MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24x
# ETAPBgNVBAoMCFNTTCBDb3JwMTQwMgYDVQQDDCtTU0wuY29tIENvZGUgU2lnbmlu
# ZyBJbnRlcm1lZGlhdGUgQ0EgUlNBIFIxMB4XDTI2MTAxMzAyNDgwMloXDTI3MTAx
# MzAyNDgwMlowXDELMAkGA1UEBhMCRlIxGzAZBgNVBAcMEkNoYW50ZWxvdXAtRW4t
# QnJpZTEXMBUGA1UECgwOTmljb2xhcyBGYWJlcnQxFzAVBgNVBAMMDk5pY29sYXMg
# RmFiZXJ0MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAsg6CT0mFQ4jB
# V2plIS4uWFSoVqRHd82Y7XYZ4CUTe/7nPBRUlXXdKTZMMHzGgiG8dEXNE8K1Xe90
# Dgl/FnorzAFlrNWSwf6t27UAUw9xkqtRDVVpVgpixpWkAwjcQeLG+YMqBkGbFi35
# TGvS23lPFWvLp4DxARrv15MtZ/NjNTCAAGUlMP2hFVBknEmrnYjEGyeJ93sl20RS
# WXQQLNqlenBdkGCrQW4XjHtRjJAEqAC68hN6nWevopSQ8CLUV7A1RFfHFarDrzrL
# zr0/NjIdSyIfM9hShln31NDrktB6Ups2XIyrtPDNB7fjkW4jpLlOqQGfYKsU9ErE
# 4SnFsh0yOOjitegyh1RvZ9wH++3DF4CmJfTli5l/gEIm8xCCryxI+K5EogW3wu1y
# u8NT2hcvHjdh7OpRyPyFAuLZ8MfX7kPAJpnuCeOuktzY/20eVD8bDglj+4zgqzsn
# cR/t6T/7w1/HxpRyrVoKvEyRx+mphYh5jMdEa0BjxOL0vAJpdGZSfXGmPm/yPqRn
# 5STTkMtzkVQXPbcvgKM0luzFcQKPHk3qdHLEXa8gf93ktYDbLE5Wd2UHrXz3SZxN
# URHPdIXCr1qgrqQve7041kMpzrkDI5DnG2lvRG4108gp02bHG0muKyZlDdCOra7h
# Zonu2nO79sFallruzzNi0o994PoWksUCAwEAAaOCAZUwggGRMAwGA1UdEwEB/wQC
# MAAwHwYDVR0jBBgwFoAUVML+EJUAk81q9efA19myS7iPDOMwegYIKwYBBQUHAQEE
# bjBsMEgGCCsGAQUFBzAChjxodHRwOi8vY2VydC5zc2wuY29tL1NTTGNvbS1TdWJD
# QS1Db2RlU2lnbmluZy1SU0EtNDA5Ni1SMS5jZXIwIAYIKwYBBQUHMAGGFGh0dHA6
# Ly9vY3Nwcy5zc2wuY29tMFEGA1UdIARKMEgwCAYGZ4EMAQQBMDwGDCsGAQQBgqkw
# AQMDATAsMCoGCCsGAQUFBwIBFh5odHRwczovL3d3dy5zc2wuY29tL3JlcG9zaXRv
# cnkwEwYDVR0lBAwwCgYIKwYBBQUHAwMwTQYDVR0fBEYwRDBCoECgPoY8aHR0cDov
# L2NybHMuc3NsLmNvbS9TU0xjb20tU3ViQ0EtQ29kZVNpZ25pbmctUlNBLTQwOTYt
# UjEuY3JsMB0GA1UdDgQWBBRoUx3630l9wA1fUpkKkw2GUIxl/jAOBgNVHQ8BAf8E
# BAMCB4AwDQYJKoZIhvcNAQELBQADggIBAE3oj6cNuwlDToi1BwjgsA5djfRN4DIi
# BYDFZIRYaIRe/rEdnItz3aqQQdFuwXnJA/MQEmi2WAGek8GeZF+R41s8FbcDxBUE
# BoSt98TuBE+0xgxQWDiPhhXaX1Aw9V0GF4ZnlfCSw1eu2KiASaKn7Bo0PLbEAXff
# vftRXof/kyqtw8iID6I4Rhrf5DI3WVZQodakUUmWnbnziWvEZOWbNOfzwP+7BwEt
# 7jQANfbmEfb4p75rfy5dQVwniTDSvdo6xkrbe1Cr93GS7cJta18IG5CoIVUmdK+s
# W38B1sLuy8Mi0MstMXV3004yaRuzLdNaAM0f9WAFerxemiQC0kdmA44/lWV3lVkM
# WJSwkHBkkSg8Eh0hxcGzTH2xmtDhLJHNNLRwkI9u2Ur+HbLCt50oBgSV8BcCs/1i
# qi884iC/yuX+HIv9YgTUNZ8c4lLaq4VuliJpXLu2buHIsTkO0v0+5oCM91zjTVZm
# ULeH38N0Vr83psiJVuBSxQyt5nRVrpYz7FACq5gtXELkyViq/rGOlJKaRrgQ6WWq
# eoIXqKhVFAdP/jAEm2M8ezoVYsUgPyKY2OcuecV9coulAcxUIUydx6qYiOfsGj5u
# Dy7l4aYjvB771wkUMzUQwxzcDYXJtMMTaWRe6n9EemR67jc73u5CJyFg3PfA5WR1
# wZislcdCZuS6MYIYEDCCGAwCAQEwgYwweDELMAkGA1UEBhMCVVMxDjAMBgNVBAgM
# BVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDE0MDIG
# A1UEAwwrU1NMLmNvbSBDb2RlIFNpZ25pbmcgSW50ZXJtZWRpYXRlIENBIFJTQSBS
# MQIQBof4ljXihJpmCqqt2mhAWzANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3
# AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisG
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCBHH9nfvqxX
# WFJG7NN+8p5El5JaiIv/9s5UBozkJpavijANBgkqhkiG9w0BAQEFAASCAgAvKukR
# 93czbFIQKCFt1X+vpQ/Ky3zIfx9BxNOHXMmh+//I6S2C8aulD8Z67BZXJwzi3FDd
# v7gfJv4uC/q4US9Iz4+lvViekCJK0Uyi/GWnufYZUJdNQr7QlqrwL2WJfNDdPVaP
# QfUvJfZWhDxpDvmRT7XhPRMOKLkjm7ISiSno3NU2woZRTY9RrC7VSyTRYX8QvQD4
# A00GU9pYZuUVWmFUKb7x5mAz0RE7cOXVxF5WdhLx1rTi96lJFT1SsDFlMLX8wD89
# g3E77sKP5LHybUKqfUlBN8d16sYRjtovfVHfjB9zA9CC8LAJpWaF7WaieOzNtS5A
# tGoQuSscfdxOwBSRvs+QEGEQkimpxsJTL0hR2VpBT8H7P5PVIMHbbUow0sgDrJ34
# f2p0p4Zhnp8cxLgrlGTL0SNHdPwSBdAyrtVTzss4FUE6fOjpZw6+tSCWQw/frDmR
# bsMsiAvkV+dohKu0vujwYywkG0m9/aqEhNzVagxVZBvg7AZI8aC3KinNC8G4C6yt
# h026dDhkORNr2n0WIUjn/F42s56T8PWHivSekcfKfoYwarBQr0fu2BQcxYnjj9gR
# HDp4/imsi+X7utrYDei8G3iRBf88ZVNkYUa4jHHZ+0T2ZDdpNcgc/e96DXkMl5Hn
# ffNMOWraIiSixV+/A1IS12b+LqqEcc/50HSXQqGCFM0wghTJBgorBgEEAYI3AwMB
# MYIUuTCCFLUGCSqGSIb3DQEHAqCCFKYwghSiAgEDMQ0wCwYJYIZIAWUDBAIBMIGJ
# BgsqhkiG9w0BCRABBKB6BHgwdgIBAQYMKwYBBAGCqTABAwYBMDEwDQYJYIZIAWUD
# BAIBBQAEIKydGss7A+p01G13WU4w2FeITvypYzmMHG2rvaGD2M7RAghMAFAEXEqb
# IhgPMjAyNjExMTcyMTA0NTZaMAMCAQECEC/tPi+SXkn+Cy0eoJSP3uGgghGnMIIE
# 8zCCAtugAwIBAgIQVEP4N71a7hgBhHK4XNqO4zANBgkqhkiG9w0BAQsFADByMQsw
# CQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24xETAP
# BgNVBAoMCFNTTCBDb3JwMS4wLAYDVQQDDCVTU0wuY29tIFRpbWVzdGFtcGluZyBJ
# c3N1aW5nIFJTQSBDQSAyMB4XDTI2MDYxMjE3MjI0NloXDTM2MDYwOTE3MjI0NVow
# bjELMAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3VzdG9u
# MREwDwYDVQQKDAhTU0wgQ29ycDEqMCgGA1UEAwwhU1NMLmNvbSBUaW1lc3RhbXBp
# bmcgVW5pdCAyMDI2IEUxMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE6CWLuGYT
# LkiSOPMLNskOBthXsIhRSA46feOQwvSLcDaNh6vxUzBKEx1KdFBRFs7OHrnH/K0V
# A6MbDQIFpUg0PaOCAVIwggFOMB8GA1UdIwQYMBaAFHCaZcFDgKP86bFkiW7xMJwJ
# Icl8ME0GCCsGAQUFBwEBBEEwPzA9BggrBgEFBQcwAoYxaHR0cDovL2NlcnQuc3Ns
# LmNvbS9TU0wuY29tLXRpbWVTdGFtcGluZy1JLVIyLmNlcjBRBgNVHSAESjBIMDwG
# DCsGAQQBgqkwAQMGATAsMCoGCCsGAQUFBwIBFh5odHRwczovL3d3dy5zc2wuY29t
# L3JlcG9zaXRvcnkwCAYGZ4EMAQQCMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMEIG
# A1UdHwQ7MDkwN6A1oDOGMWh0dHA6Ly9jcmxzLnNzbC5jb20vU1NMLmNvbS10aW1l
# U3RhbXBpbmctSS1SMi5jcmwwHQYDVR0OBBYEFCesA1a6KGq6FzuDPUB/eagk7MM8
# MA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOCAgEAT3ZuzvwDnsIZTXBn
# +hjmuBXgzB12fbYxT9uYe6ZvhvpbZWKcyDQgacETkPw8k6yeqnYCYyFZ063lMPEq
# AhAD2nMG614Zh7PtHW9DWqfsgivxbPYBeN+t7UxgkYT3expbWMdPEqBtWVyHOvLc
# KvMxgJWfJjANwVkwVDfky/j7cf28+iimN8PKc7S/u8/LenRRnV2W2YfncRnkz9Cf
# s5nRDzaZguiHrrp2GxwgnNQSH4GBjHOl3PzLsnVbGoZKi4ZEjgXups4mGGOK7+GB
# 2HAlQn+OS944cHqlkH0gElt2WezoCNRpELph9qaxuBnjSEqXWWfgE6yGBwO0uxKN
# qpWVTHmAwr6SvBPofxubXIuEn9ivR4CLOuAxUSrJ41ZBg/qqG0oJjF6GkRKbxq7c
# yWSkEZYJhmKCg2Hg5fXHagOxiwbmn5JPZ1vhWCrbk3v/dTx2gvTK5+erC5H9/rTc
# ljUI776yd2rfhjfkpvyAsbtXs4D7nrnw8i9wor5+fdtRSJBVxqzLmykFftoL0Up2
# Q++tyKCUdribdcnrB4HKS3s+t3AjdcbA06DCL8GifQi9fL0yRBRNlA4o6BP+Sr75
# 5MaCNjURYZDvDyxJHBBT7cqjZIwsiR8s+6860noFbBBtdge2Iw7CPC/1Q31I27hV
# olS7B0yao3v8X2MtWy3msZlXTcEwggXdMIIDxaADAgECAgh7LJvTFoAymTANBgkq
# hkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNV
# BAcMB0hvdXN0b24xGDAWBgNVBAoMD1NTTCBDb3Jwb3JhdGlvbjExMC8GA1UEAwwo
# U1NMLmNvbSBSb290IENlcnRpZmljYXRpb24gQXV0aG9yaXR5IFJTQTAeFw0xNjAy
# MTIxNzM5MzlaFw00MTAyMTIxNzM5MzlaMHwxCzAJBgNVBAYTAlVTMQ4wDAYDVQQI
# DAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjEYMBYGA1UECgwPU1NMIENvcnBvcmF0
# aW9uMTEwLwYDVQQDDChTU0wuY29tIFJvb3QgQ2VydGlmaWNhdGlvbiBBdXRob3Jp
# dHkgUlNBMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA+Q/doyt9y9Aq
# /uxnhabnLhu6d+Hj9a+k7PpKXZHEV0drGHdrdvL9k+Q9D8IWngtmw1aUnheDhc5W
# 7/IW/QBi9SIJVOhlF05BueBPRpeqG8i4bmJeabFf2yoCfvxsyvNB2O3Q6Pw/YUjt
# sAMUHRAOSxngu07shmX/NvNeZwILnYZVYf16OO3+4hkAt2+hUGJ1dDyg+sglkrRu
# eiLH+B6h47LdkTGrKx0E/6VKBDfphaQzK/3i1lU0fBmkSmjHsqjTt8qhk4jrwZe8
# jPkd2SKEJHTHBD1qqSmTzOu4W+H+XyWqNFjIwSNUnRuYEcM4nH49hmylD0CGfAL0
# XAJPKMuucZ8POsgz/hElNer8usVgPdl8GNWyqdN1eANyIso6wx/vLOUuqfqeLLZR
# Rv2vA9bqYGjqhRY2a4XpHsCz3cQk3IAqgUFtlD7I4MmBQQCeXr9/xQiYohgsQkCz
# +W84J0tOgPQ9gUfgiHzqHM61dVxRLhwrfxpyKOcAtdF0xtfkn60Hk7ZTNTX8N+TD
# 9l0WviFz3pIK+KBjaryWkmo++LxlVZve9Q2JJgT8JRqmJWnLwm3KfOJZX5es6+8u
# yLzXG1k8K8zyGciTaydjGc/86Sb4ynGbf5P+NGeETpnr/LN4CTNwumamdu0bc+sa
# pQ3EIhMglFYKTixsTrH9z5wJuqIz7YcCAwEAAaNjMGEwHQYDVR0OBBYEFN0ECQei
# 9Xp9UlMSkpXuOIAlDaZZMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU3QQJ
# B6L1en1SUxKSle44gCUNplkwDgYDVR0PAQH/BAQDAgGGMA0GCSqGSIb3DQEBCwUA
# A4ICAQAgGBGUKfsmnRweHnBh8ZVyk3EkrWiTWI4yrxuzcAP8JSt0hZA9eGr0uYul
# lzu1GJG7Hqf5QFuR+VWZrx4R0Fwdp2bjsZQHDDI5puobsHnYHZxwROOK3cT5lR+K
# OEM/AYWlR6c9RrK85SJo93uc2Cw+CiHILTOsv8WBmTF0wXVxxb6x8CNF9J1r/Blj
# naO8BMYYCyW7U4kPs4BQ3kXuRH+rlHhkmNP2KN2H2HBldPsOuRPrpw9hqTKWzN67
# 7WNMGLupQPegVG4giHF1GOp6tDRy4CMnd1y2kOqGJUCr7zMPy5+CvqIg+/a1LRrm
# woWxdA/7yGUCpFIBR91JIsG/2OtrrH7e7GMzFbcjCI/GD41BWt2OxbmP5UU/eNu6
# 0htAsf5xTT/ggaK6XrTsFeCT3QgffuFVmQsh3pOeCvvmo0m9NjD+53eyoHWXtS2B
# iBdlIPfakACfyVLMMso1fPU9D9gr1/UmbMkGNJYW6nBZGjJ5eQu2iH8PUkg9v2zY
# okQu0U63cljTiROV/kSr+NeLG26cvCygW9VqAK9fN+HV+hALmJyG5yaPzvDsbopX
# C4DjTrLAoGNhkLpVaDd0araS25+hhiK2ZScO7LafQmDkZ8K12kELxNOLYRu8+h+R
# K9dEB166KazZxenvU0ha64DxKFghzbAGVfsnP1OQcKkEHlcnuTCCBsswggSzoAMC
# AQICEFKdu8K4iYf1g4DgsOuiBjYwDQYJKoZIhvcNAQELBQAwfDELMAkGA1UEBhMC
# VVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMRgwFgYDVQQKDA9T
# U0wgQ29ycG9yYXRpb24xMTAvBgNVBAMMKFNTTC5jb20gUm9vdCBDZXJ0aWZpY2F0
# aW9uIEF1dGhvcml0eSBSU0EwHhcNMjYwNjEyMTY0MjE1WhcNNDEwMjEyMTczOTM5
# WjByMQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0
# b24xETAPBgNVBAoMCFNTTCBDb3JwMS4wLAYDVQQDDCVTU0wuY29tIFRpbWVzdGFt
# cGluZyBJc3N1aW5nIFJTQSBDQSAyMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIIC
# CgKCAgEAny+r5nNNkLwxRps2B3laUGNU9y7vWiJ5013yf0iXz65bQdwa9bjj8l/S
# keXqHGqfSh2Foae+80E8mDEf93oIwjsy2CX2cXmKxqtF8HJGYB4f6yRhKED50wkb
# OysL02IXf+/EZna44jffhhVz4OU/k52xQ/PnIg/uFhc2Wk+Sc/CHqAr+lYVkPz7L
# y5RqB9f1RKGr9JC37W1LgVdHC50dNIdsa3QXPhltYZubR3npE4Bbfi0joUW5n5O0
# ayweN45R/YVLxA0YGlp1OHVfVnsqXq8bhnw1Lc4kjJ6XOgXlOlw/a8ze57TvbduZ
# l3ehewTmvO0Aky/nqOWDS9IPPxdxdG6vprBbSuHlxNANBAbHTiFgkfZmf0dZYlT/
# AnZIoFxAq0HILPolf4OgWgET76SiWSlm2XYRIXwVjpeqG0plvXwRIQBzSiEJj7Qe
# QFnCvHx4gQMINvN3+yG/1rxhEbajGve0tTP3lX4PPOHVAE0QJp4ZzPI1YYJkhVRr
# iVVxVRU4Fsg4BPwP6I+YLmHb1tZ4RLwOFNLh/gJYDgPlChCoxOogFxXgwPZZrDyE
# RYB0aeOexW0OKacN4RRu9cqF2KKu/Ab5AL7eYDLVGUPrEEyYbIMApVKqpebc0/jD
# QniC+3rkauRAjgVc8m1ip/CQgG1Dw4Z9ulVRAY9VR6Za26LsTbUCAwEAAaOCAVEw
# ggFNMBIGA1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0jBBgwFoAU3QQJB6L1en1SUxKS
# le44gCUNplkwTQYIKwYBBQUHAQEEQTA/MD0GCCsGAQUFBzAChjFodHRwOi8vY2Vy
# dC5zc2wuY29tL1NTTGNvbS1Sb290Q0EtUlNBLTQwOTYtUjEuY2VyMD8GA1UdIAQ4
# MDYwNAYEVR0gADAsMCoGCCsGAQUFBwIBFh5odHRwczovL3d3dy5zc2wuY29tL3Jl
# cG9zaXRvcnkwEwYDVR0lBAwwCgYIKwYBBQUHAwgwQgYDVR0fBDswOTA3oDWgM4Yx
# aHR0cDovL2NybHMuc3NsLmNvbS9TU0xjb20tUm9vdENBLVJTQS00MDk2LVIxLmNy
# bDAdBgNVHQ4EFgQUcJplwUOAo/zpsWSJbvEwnAkhyXwwDgYDVR0PAQH/BAQDAgGG
# MA0GCSqGSIb3DQEBCwUAA4ICAQBlFFvNMemA6iBiBYo56IKQjWhWuQaYKuo4qpf0
# KJNERAt1gz+HsA2SL3xA/V+EA8SRPNP9SvX0is+5mDsppYvpKyYGqYP36YFW0mbF
# 1F0ZtXxumCUUO/ZV5mBNKDf5Q4PY7Qb0eWAepUc0rNJr/Mvn5ZiXfJPxDb2xmcg8
# aRD652/nr+Ork2UBP0E43iJdI4LF7Vs29R3SGRLYZOxM15DI4QebsKRl0KDlf4Om
# YGCKc7umTxibkZtN1C1KWgnf9jadU/JwnySaYEBgx6/v+FVC6SGONziY7TcvI9MV
# +qYxHUPlOm6AaQP2dS4bjWXnm86ldCbUkxtOACumSfT97077JNiVa7PZ1IBkd/2P
# E1AC8gs7U+/Yk1BN9XRPIi15k/uA1xF9oeee5KGjyiGKkqIT7W8QkgUT5zeCinFK
# kcKafZMcROSVYpXtmtQqGGR2g4uPYqJ0K1hms6gJXrHt/34p8M9PrV8oNWe0Zl1E
# rDMtXndUg3qhJL4pA3ZUlo7w5lM5ml+A7ijr/3Gk2v4QRoDeE2ShmTXdHgtqo8L/
# fT119mYcETycE2NYGRXsBl3N0rzDsHRr8P3TrprqhRrX04iS0P7eQ+lDxgS3yhGn
# 3OzWGhDt9Gf2x1qe0/qdhFAVOkXxzMZz4Uat6xsAfzX0+/m8GEKW5Ojw/HY+kLvV
# wzSPOzGCAlUwggJRAgEBMIGGMHIxCzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhh
# czEQMA4GA1UEBwwHSG91c3RvbjERMA8GA1UECgwIU1NMIENvcnAxLjAsBgNVBAMM
# JVNTTC5jb20gVGltZXN0YW1waW5nIElzc3VpbmcgUlNBIENBIDICEFRD+De9Wu4Y
# AYRyuFzajuMwCwYJYIZIAWUDBAIBoIIBYDAaBgkqhkiG9w0BCQMxDQYLKoZIhvcN
# AQkQAQQwHAYJKoZIhvcNAQkFMQ8XDTI2MTExNzIxMDQ1NlowKAYJKoZIhvcNAQk0
# MRswGTALBglghkgBZQMEAgGhCgYIKoZIzj0EAwIwLwYJKoZIhvcNAQkEMSIEIC0N
# ts87He7pgc+b+OwgRCpzt3B4Vnmnxx+quSY8mqbrMIHIBgsqhkiG9w0BCRACLzGB
# uDCBtTCBsjCBrwQgV0/qF6r6XnxqK5sIyZixc15FCzhzykTmokygkw5j87AwgYow
# dqR0MHIxCzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91
# c3RvbjERMA8GA1UECgwIU1NMIENvcnAxLjAsBgNVBAMMJVNTTC5jb20gVGltZXN0
# YW1waW5nIElzc3VpbmcgUlNBIENBIDICEFRD+De9Wu4YAYRyuFzajuMwCgYIKoZI
# zj0EAwIERjBEAiA3PdUPISu0KXakFoY7QQwtkKXzp6QlePwQSgs8yIKJ6AIgPE+v
# mn1zOU2tScyvWXOdxzEvA5wOUCawLPNlGJCsPRQ=
# SIG # End signature block
