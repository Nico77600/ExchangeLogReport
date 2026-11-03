#Requires -Version 7.4
<#
.SYNOPSIS
    Builds the release package ExchangeLogReport-<version>-win-x64 in three phases, so that the owner signs between them.

.DESCRIPTION
    Build (default): copies package\ (the portal is the report template of templates\) and the third-party binaries
    (PowerShell runtime, SQLite tools) into a new folder under -OutputRoot and refuses to continue unless the six PowerShell files of
    package\ carry the timestamped owner signature. No manifest is written.
    -Unsigned (continuous integration): the same build without the signature requirement. The committed
    package\PackageIntegrity.psd1 is copied when it exists. The folder is verified with -DevelopmentMode and an
    '-unsigned-ci' ZIP is written; it is never a release.
    -Manifest <package folder>: hashes the built folder and writes an unsigned PackageIntegrity.psd1. The owner signs it.
    -Seal <package folder>: verifies the signed manifest on the built folder and on package\ (the bytes of the
    protected files must be the ones in the repository), then writes the release ZIP and prints its SHA-256.
    Signing key material is never read by this script.

.NOTES
    Author  : Nicolas Fabert
    Version : 3.0.0
#>
[CmdletBinding(DefaultParameterSetName = 'Build')]
param(
    [Parameter(ParameterSetName = 'Build')][string]$OutputRoot = (Join-Path (Split-Path $PSScriptRoot -Parent) 'artifacts'),
    [Parameter(ParameterSetName = 'Build')][string]$PowerShellArchive,
    [Parameter(ParameterSetName = 'Build')][switch]$Unsigned,
    [Parameter(ParameterSetName = 'Manifest', Mandatory)][string]$Manifest,
    [Parameter(ParameterSetName = 'Seal', Mandatory)][string]$Seal
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$source = Join-Path $root 'package'
$product = Get-Content -LiteralPath (Join-Path $root 'product.json') -Raw | ConvertFrom-Json
$signer = '0F28E442889F17B5F4D251E8F96E7CC6E2C9C6D6'
$signedScripts = @('Invoke-ExchangeLogReport.ps1', 'Database-Storage.ps1', 'ExchangeLogReport.psm1', 'ExchangeLogReport.psd1',
    'src\Test-PackageIntegrity.ps1', 'src\Get-ExlExchangeSettings.ps1')
$binaryFolders = @('powershell', 'sqlite-tools')

function Get-RelativeFile([string]$Base) {
    Get-ChildItem -LiteralPath $Base -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($Base.Length + 1) } | Sort-Object { $_ } -CaseSensitive
}
function Assert-OwnerSigned([string]$Path) {
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ([string]$signature.Status -cne 'Valid' -or $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Thumbprint -cne $signer -or $null -eq $signature.TimeStamperCertificate) {
        throw "Not signed with the trusted, timestamped owner certificate ($($signature.Status)): $Path"
    }
}
function Write-Manifest([string]$Package) {
    $entries = foreach ($relative in Get-RelativeFile $Package) {
        if ($relative -ceq 'PackageIntegrity.psd1' -or $relative -ceq 'config\ExchangeLogReport.config.psd1') { continue }
        [pscustomobject]@{
            Path = $relative
            Sha256 = (Get-FileHash -LiteralPath (Join-Path $Package $relative) -Algorithm SHA256).Hash
            Binary = ($relative.Split('\')[0] -cin $binaryFolders -and $relative -cne 'sqlite-tools\NOTICE.txt')
        }
    }
    $text = [Text.StringBuilder]::new()
    [void]$text.AppendLine('@{')
    [void]$text.AppendLine('    SchemaVersion = 1')
    [void]$text.AppendLine("    Algorithm = 'SHA256'")
    [void]$text.AppendLine("    SignerThumbprint = '$signer'")
    [void]$text.AppendLine("    Version = '$($product.version)'")
    foreach ($list in @(@{ Name = 'Files'; Binary = $false }, @{ Name = 'DistributionFiles'; Binary = $true })) {
        [void]$text.AppendLine("    $($list.Name) = @(")
        foreach ($entry in $entries | Where-Object { $_.Binary -eq $list.Binary }) {
            if ($entry.Path.Contains("'")) { throw "A packaged path contains a quote: $($entry.Path)" }
            [void]$text.AppendLine("        @{ Path = '$($entry.Path)'; Sha256 = '$($entry.Sha256)' }")
        }
        [void]$text.AppendLine('    )')
    }
    [void]$text.AppendLine('}')
    $target = Join-Path $Package 'PackageIntegrity.psd1'
    [IO.File]::WriteAllText($target, ($text.ToString() -replace "`r?`n", "`r`n"), [Text.UTF8Encoding]::new($false))
    $target
}

if ($PSCmdlet.ParameterSetName -eq 'Manifest') {
    $Manifest = [IO.Path]::GetFullPath($Manifest).TrimEnd('\')
    foreach ($relative in $signedScripts) { Assert-OwnerSigned (Join-Path $Manifest $relative) }
    $runtime = Get-AuthenticodeSignature -LiteralPath (Join-Path $Manifest 'powershell\pwsh.exe')
    if ($runtime.Status -ne 'Valid' -or $runtime.SignerCertificate.Subject -notmatch '(^|, )O=Microsoft Corporation(,|$)') {
        throw "The pinned PowerShell executable signature is not valid Microsoft Authenticode: $($runtime.Status)"
    }
    if ((Get-FileHash -LiteralPath (Join-Path $Manifest 'sqlite-tools\sqlite3.exe') -Algorithm SHA256).Hash -ne $product.sqliteTools.executableSha256) {
        throw 'The packaged SQLite tool does not match its pinned SHA256.'
    }
    $path = Write-Manifest $Manifest
    Write-Output "Unsigned manifest written: $path"
    Write-Output "Sign it, then copy the signed file to $(Join-Path $source 'PackageIntegrity.psd1') and run: .\tools\Build-Standalone.ps1 -Seal `"$Manifest`""
    return
}

if ($PSCmdlet.ParameterSetName -eq 'Seal') {
    $Seal = [IO.Path]::GetFullPath($Seal).TrimEnd('\')
    $signedManifest = Join-Path $source 'PackageIntegrity.psd1'
    if (-not (Test-Path -LiteralPath $signedManifest)) { throw "Copy the signed manifest to $signedManifest first." }
    if ((Get-FileHash -LiteralPath $signedManifest -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath (Join-Path $Seal 'PackageIntegrity.psd1') -Algorithm SHA256).Hash) {
        Copy-Item -LiteralPath $signedManifest -Destination (Join-Path $Seal 'PackageIntegrity.psd1') -Force
    }
    $result = & (Join-Path $Seal 'src\Test-PackageIntegrity.ps1') -Root $Seal -Distribution
    if ($result.Status -cne 'Valid') { throw 'The built package is not Valid.' }
    $sourceResult = & (Join-Path $source 'src\Test-PackageIntegrity.ps1') -Root $source
    if ($sourceResult.Status -notlike 'Valid*') { throw 'The repository package folder is not Valid.' }
    foreach ($relative in Get-RelativeFile $Seal) {
        $sourceFile = Join-Path $source $relative
        if ($relative.Split('\')[0] -cin $binaryFolders -or -not (Test-Path -LiteralPath $sourceFile)) { continue }
        if ($relative -ceq 'config\ExchangeLogReport.config.psd1') { continue }
        if ((Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath (Join-Path $Seal $relative) -Algorithm SHA256).Hash) {
            throw "The packaged file differs from the repository file: $relative"
        }
    }
    $zip = "$Seal.zip"
    if (Test-Path -LiteralPath $zip) { throw "The ZIP already exists: $zip" }
    Compress-Archive -LiteralPath $Seal -DestinationPath $zip -CompressionLevel Optimal
    [pscustomobject]@{
        Package = $Seal; Zip = $zip; ZipBytes = (Get-Item -LiteralPath $zip).Length
        ZipSha256 = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
        Files = $result.Files + $result.DistributionFiles; Signed = $true; Published = $false
    } | ConvertTo-Json
    return
}

# ---- Build ---------------------------------------------------------------------------------------------------------
$sourceFiles = @(Get-ChildItem -LiteralPath $source -Recurse -File -Force | Where-Object {
    $relative = $_.FullName.Substring($source.Length + 1)
    $top = $relative.Split('\')[0]
    -not ($top -cin @('bin', 'data', 'logs', 'reports', 'host', 'powershell', 'sqlite-tools')) -and
    -not ($relative -clike 'docs\*.md') -and -not ($relative -clike 'docs\images\*') -and
    $relative -cne 'PackageIntegrity.psd1' -and $_.Name -notlike '*.paths.psd1' -and $_.Extension -ne '.credential'
})
$inputFiles = @(
    $sourceFiles
    Get-Item -LiteralPath (Join-Path $root 'product.json'), (Join-Path $root 'LICENSE'), (Join-Path $root 'SECURITY.md'), (Join-Path $root 'CHANGELOG.md')
)
$inputs = @($inputFiles | Sort-Object FullName -Unique | ForEach-Object {
    [pscustomobject]@{ path = $_.FullName.Substring($root.Length + 1); sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
})
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$name = "$($product.name)-$($product.version)-win-x64"
$destination = Join-Path $OutputRoot $name
$zip = if ($Unsigned) { "$destination-unsigned-ci.zip" } else { "$destination.zip" }
$projectPrefix = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
$destinationPrefix = [IO.Path]::GetFullPath($destination).TrimEnd('\') + '\'
$artifactsPrefix = (Join-Path $root 'artifacts').TrimEnd('\') + '\'
if ($destinationPrefix.StartsWith($projectPrefix, [StringComparison]::OrdinalIgnoreCase) -and
    -not $destinationPrefix.StartsWith($artifactsPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Inside the source tree, packages must stay under the ignored artifacts folder.'
}
if ((Test-Path -LiteralPath $destination) -or (Test-Path -LiteralPath $zip)) {
    throw "Build destination already exists. Choose a new OutputRoot; existing deliveries are never overwritten: $destination"
}
if (-not $Unsigned) { foreach ($relative in $signedScripts) { Assert-OwnerSigned (Join-Path $source $relative) } }
$cache = Join-Path $root '.cache'
[void][IO.Directory]::CreateDirectory($cache)
$sqliteTool = Join-Path $root 'lib\sqlite-tools\sqlite3.exe'
if (-not (Test-Path -LiteralPath $sqliteTool)) {
    $sqliteArchive = Join-Path $cache "sqlite-tools-$($product.sqliteTools.version)-win-x64.zip"
    if (-not (Test-Path -LiteralPath $sqliteArchive)) {
        Invoke-WebRequest -Uri $product.sqliteTools.url -OutFile $sqliteArchive
    }
    if ((Get-FileHash -LiteralPath $sqliteArchive -Algorithm SHA256).Hash -ne $product.sqliteTools.archiveSha256) {
        throw 'The official SQLite tools archive does not match its pinned SHA256.'
    }
    $sqliteStaging = Join-Path $cache ("sqlite-restore-" + [guid]::NewGuid().ToString('N'))
    try {
        Expand-Archive -LiteralPath $sqliteArchive -DestinationPath $sqliteStaging
        $executables = @(Get-ChildItem -LiteralPath $sqliteStaging -Filter 'sqlite3.exe' -File -Recurse)
        if ($executables.Count -ne 1) { throw 'Expected exactly one sqlite3.exe in the reviewed archive.' }
        [void][IO.Directory]::CreateDirectory((Split-Path $sqliteTool -Parent))
        Copy-Item -LiteralPath $executables[0].FullName -Destination $sqliteTool
    } finally { if (Test-Path -LiteralPath $sqliteStaging) { Remove-Item -LiteralPath $sqliteStaging -Recurse -Force } }
}
if ((Get-FileHash -LiteralPath $sqliteTool -Algorithm SHA256).Hash -ne $product.sqliteTools.executableSha256) {
    throw 'The SQLite diagnostic executable does not match its pinned SHA256.'
}
if (-not $PowerShellArchive) {
    $PowerShellArchive = Join-Path $cache "PowerShell-$($product.powerShell.version)-win-x64.zip"
    if (-not (Test-Path -LiteralPath $PowerShellArchive)) {
        Invoke-WebRequest -Uri $product.powerShell.url -OutFile $PowerShellArchive
    }
}
if ((Get-FileHash -LiteralPath $PowerShellArchive -Algorithm SHA256).Hash -ne $product.powerShell.sha256) {
    throw 'The portable PowerShell archive does not match its pinned SHA256.'
}
[void][IO.Directory]::CreateDirectory($destination)
foreach ($file in @('SECURITY.md', 'CHANGELOG.md', 'LICENSE', 'product.json')) {
    Copy-Item -LiteralPath (Join-Path $root $file) -Destination (Join-Path $destination $file)
}
$sqliteDestination = Join-Path $destination 'sqlite-tools'
[void][IO.Directory]::CreateDirectory($sqliteDestination)
Copy-Item -LiteralPath $sqliteTool -Destination (Join-Path $sqliteDestination 'sqlite3.exe')
Copy-Item -LiteralPath (Join-Path $root 'lib\sqlite-tools\NOTICE.txt') -Destination (Join-Path $sqliteDestination 'NOTICE.txt')
foreach ($sourceFile in $sourceFiles) {
    $relative = $sourceFile.FullName.Substring($source.Length + 1)
    $target = Join-Path $destination $relative
    [void][IO.Directory]::CreateDirectory((Split-Path $target -Parent))
    Copy-Item -LiteralPath $sourceFile.FullName -Destination $target
}
$config = Import-PowerShellDataFile -LiteralPath (Join-Path $destination 'config\ExchangeLogReport.config.psd1')
if (($config.Servers.Name -join ',') -ne 'EXCH01,EXCH02' -or $config.Mail.Enabled -or $config.Mail.SmtpServer -or
    $config.Mail.From -or @($config.Mail.To).Count -or @($config.Mail.Cc).Count -or $config.Mail.CertificateThumbprint) {
    throw 'The package configuration is not the reviewed empty/example configuration.'
}
Expand-Archive -LiteralPath $PowerShellArchive -DestinationPath (Join-Path $destination 'powershell')
Get-ChildItem -LiteralPath (Join-Path $destination 'powershell') -Filter '*.pdb' -Recurse -File | Remove-Item
$powerShellExe = Join-Path $destination 'powershell\pwsh.exe'
$signature = Get-AuthenticodeSignature -LiteralPath $powerShellExe
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|, )O=Microsoft Corporation(,|$)') {
    throw "The pinned PowerShell executable signature is not valid Microsoft Authenticode: $($signature.Status)"
}
& $powerShellExe -NoLogo -NoProfile -Command 'if ([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne "X64") { exit 1 }; $PSVersionTable.PSVersion.ToString()'
if ($LASTEXITCODE -ne 0) { throw 'The bundled PowerShell executable did not start correctly.' }
$prohibited = @(Get-ChildItem -LiteralPath $destination -Recurse -File | Where-Object {
    $_.Name -match '\.(sqlite(?:-.*)?|db|log|credential|pdb)$' -or $_.Name -like '*.paths.psd1'
})
if ($prohibited.Count) { throw "Runtime/private files found in package: $($prohibited.Name -join ', ')" }
foreach ($required in @('templates\Report.template.html', 'templates\Report.template.js', 'powershell\pwsh.exe', 'Run-Collector.cmd', 'Start-Portal.cmd',
        'Database-Storage.cmd', 'Database-Storage.ps1', 'sqlite-tools\sqlite3.exe', 'src\Test-PackageIntegrity.ps1', 'Invoke-ExchangeLogReport.ps1')) {
    if (-not (Test-Path -LiteralPath (Join-Path $destination $required))) { throw "Required package file missing: $required" }
}
foreach ($inputFile in $inputs) {
    if ((Get-FileHash -LiteralPath (Join-Path $root $inputFile.path) -Algorithm SHA256).Hash -ne $inputFile.sha256) {
        throw "Source changed during packaging; do not distribute this incomplete output: $($inputFile.path)"
    }
}
if ($Unsigned) {
    $committed = Join-Path $source 'PackageIntegrity.psd1'
    if (Test-Path -LiteralPath $committed) {
        Copy-Item -LiteralPath $committed -Destination (Join-Path $destination 'PackageIntegrity.psd1')
        & (Join-Path $destination 'src\Test-PackageIntegrity.ps1') -Root $destination -DevelopmentMode | Out-Null
    } else {
        Write-Warning 'package\PackageIntegrity.psd1 is not committed: this unsigned build carries no manifest.'
    }
    Compress-Archive -LiteralPath $destination -DestinationPath $zip -CompressionLevel Optimal
    [pscustomobject]@{
        Package = $destination; Zip = $zip; ZipBytes = (Get-Item -LiteralPath $zip).Length
        Files = @(Get-ChildItem -LiteralPath $destination -Recurse -File).Count; Signed = $false; Published = $false
    } | ConvertTo-Json
    return
}
Write-Output "Package built (no manifest yet): $destination"
Write-Output "Next: .\tools\Build-Standalone.ps1 -Manifest `"$destination`""