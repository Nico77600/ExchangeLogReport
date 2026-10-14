#Requires -Version 7.4
<#
.SYNOPSIS
    Copies the files needed to run Exchange Log Report into a separate folder, ready to be zipped.

.DESCRIPTION
    The package contains only what Invoke-ExchangeLogReport.ps1 needs at run time, plus the short README,
    the HTML guides and the licence notice of the SQLite binaries:
        Invoke-ExchangeLogReport.ps1, ExchangeLogReport.psd1, ExchangeLogReport.psm1,
        PackageIntegrity.psd1, config\, src\ (including Test-PackageIntegrity.ps1),
        templates\, lib\sqlite\, docs\ExchangeLogReport-UserGuide.html, docs\ExchangeLogReport-Guide.html,
        README.md, CHANGELOG.md, THIRD-PARTY-NOTICES.md
    The package source and the finished package must pass the owner-signed integrity check
    (src\Test-PackageIntegrity.ps1 and PackageIntegrity.psd1: exact SHA256 of every hashed file). The HTML guides are
    self-contained (images inline) and are copied as hashed: the builder never regenerates them. Rebuild them with
    tools\Build-Documentation.ps1 before the manifest is generated and signed; after that, any change fails the check.
    It never copies data\, reports\, logs\, bin\ or tests\: there is no database in the package, the
    tool creates an empty one at the first collection.

    The configuration is copied as delivered (example server names). The script checks that no
    database, report or log file is in the package.

.PARAMETER Destination
    Package folder. Default: package\ExchangeLogReport-<version>, next to the repository folder.

.PARAMETER Force
    Replace the destination folder if it already contains a package. A folder that contains a data\
    sub-folder (a package that has been run) is never replaced.

.EXAMPLE
    .\tools\New-ExchangeLogReportPackage.ps1
    Creates ..\package\ExchangeLogReport-2.1.0.

.NOTES
    Author  : Nicolas Fabert
    Version : 2.1.0
#>
[CmdletBinding()]
param(
    [string]$Destination,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$packageRoot = Join-Path $root 'package'
function Assert-AuthenticatedPackage([string]$Path, [switch]$Distribution) {
    $verifier = Join-Path $Path 'src\Test-PackageIntegrity.ps1'
    $cursor = [IO.Path]::GetFullPath($verifier)
    while ($cursor) {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Package integrity: reparse point: $cursor" }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    $signature = Microsoft.PowerShell.Security\Get-AuthenticodeSignature -LiteralPath $verifier -ErrorAction Stop
    if ([string]$signature.Status -cne 'Valid' -or $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Thumbprint -cne '0F28E442889F17B5F4D251E8F96E7CC6E2C9C6D6' -or
        $null -eq $signature.TimeStamperCertificate) {
        throw 'Package integrity: verifier must have the trusted, timestamped owner signature.'
    }
    if ($Distribution) { & $verifier -Root $Path -Distribution } else { & $verifier -Root $Path }
}
Assert-AuthenticatedPackage $packageRoot
$version = (Import-PowerShellDataFile (Join-Path $packageRoot 'ExchangeLogReport.psd1')).ModuleVersion
if (-not $Destination) { $Destination = Join-Path (Split-Path $root -Parent) "package\ExchangeLogReport-$version" }
$Destination = [IO.Path]::GetFullPath($Destination, (Get-Location).Path).TrimEnd('\')

$repoPrefix = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
if (($Destination + '\').StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase) -or $repoPrefix.StartsWith($Destination + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "The destination must be outside the tool folder: $Destination"
}
if (Test-Path -LiteralPath $Destination) {
    if (-not $Force) { throw "The destination already exists: $Destination. Use -Force to replace it." }
    if (-not (Test-Path -LiteralPath (Join-Path $Destination 'Invoke-ExchangeLogReport.ps1'))) { throw "The destination is not an Exchange Log Report package, it is not replaced: $Destination" }
    if (Test-Path -LiteralPath (Join-Path $Destination 'data')) { throw "The destination contains a data folder (a database may be in it), it is not replaced: $Destination" }
    Remove-Item -LiteralPath $Destination -Recurse -Force
}

# ---- Files needed at run time -------------------------------------------------------------------
$files = [Collections.Generic.List[string]]::new()
foreach ($f in 'Invoke-ExchangeLogReport.ps1', 'ExchangeLogReport.psd1', 'ExchangeLogReport.psm1', 'PackageIntegrity.psd1', 'README.md', 'CHANGELOG.md', 'THIRD-PARTY-NOTICES.md',
    'config\ExchangeLogReport.config.psd1', 'templates\Report.template.html', 'docs\ExchangeLogReport-Guide.html', 'docs\ExchangeLogReport-UserGuide.html') { $files.Add($f) }
foreach ($folder in 'src', 'lib\sqlite') {
    Get-ChildItem -LiteralPath (Join-Path $packageRoot $folder) -Recurse -File | ForEach-Object { $files.Add($_.FullName.Substring($packageRoot.Length + 1)) }
}
foreach ($f in $files) {
    $source = if ($f -eq 'CHANGELOG.md') { Join-Path $root $f } else { Join-Path $packageRoot $f }
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Missing file in the tool folder: $f" }
    $target = Join-Path $Destination $f
    [void][IO.Directory]::CreateDirectory((Split-Path $target -Parent))
    Copy-Item -LiteralPath $source -Destination $target
}

# ---- Checks ---------------------------------------------------------------------------------------
$problems = [Collections.Generic.List[string]]::new()
foreach ($name in 'data', 'reports', 'logs', 'bin', 'tests') {
    if (Test-Path -LiteralPath (Join-Path $Destination $name)) { $problems.Add("Folder $name\ must not be in the package.") }
}
Get-ChildItem -LiteralPath $Destination -Recurse -File -Include '*.sqlite', '*.sqlite-*', '*.db', '*.lock', '*.log', '*.csv', '*.paths.psd1' |
    ForEach-Object { $problems.Add("Runtime file in the package: $($_.Name)") }
if (@($files | Select-Object -Unique).Count -ne $files.Count) { throw 'Package integrity: duplicate distribution file path.' }
foreach ($f in 'src\Engine.Text.cs', 'src\Engine.Store.cs', 'src\Engine.Collector.cs', 'src\Engine.Sessions.cs', 'src\Engine.Report.cs', 'src\Engine.ReportSessions.cs', 'src\Get-ExlExchangeSettings.ps1', 'src\Test-PackageIntegrity.ps1', 'PackageIntegrity.psd1', 'lib\sqlite\runtimes\win-x64\e_sqlite3.dll', 'docs\ExchangeLogReport-Guide.html', 'docs\ExchangeLogReport-UserGuide.html') {
    if (-not (Test-Path -LiteralPath (Join-Path $Destination $f))) { $problems.Add("Missing in the package: $f") }
}
if ($problems.Count) { throw ("Package not valid ($Destination):`n - " + ($problems -join "`n - ")) }
Assert-AuthenticatedPackage $Destination -Distribution

$all = Get-ChildItem -LiteralPath $Destination -Recurse -File
Write-Host ''
Write-Host "  Exchange Log Report $version - package ready" -ForegroundColor Green
Write-Host "  Folder   : $Destination"
Write-Host ("  Content  : {0} files, {1:N1} MB" -f $all.Count, (($all | Measure-Object Length -Sum).Sum / 1MB))
Write-Host "  Database : none - the tool creates an empty database at the first collection"
Write-Host "  Config   : example servers - list the Exchange servers, then run -Mode Discover (user guide, chapter 3)"
Write-Host ''
$all | Sort-Object FullName | ForEach-Object { '    {0,12:N0}  {1}' -f $_.Length, $_.FullName.Substring($Destination.Length + 1) }
