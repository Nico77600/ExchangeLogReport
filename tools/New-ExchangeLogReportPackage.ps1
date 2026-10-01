#Requires -Version 7.4
<#
.SYNOPSIS
    Copies the files needed to run Exchange Log Report into a separate folder, ready to be zipped.

.DESCRIPTION
    The package contains only what Invoke-ExchangeLogReport.ps1 needs at run time, plus the HTML guide and
    the licence notice of the SQLite binaries:
        Invoke-ExchangeLogReport.ps1, ExchangeLogReport.psd1, ExchangeLogReport.psm1, config\, src\,
        templates\, lib\sqlite\, docs\ExchangeLogReport-Guide.html, README.md, CHANGELOG.md, THIRD-PARTY-NOTICES.md
    The HTML guide is rebuilt first from docs\ExchangeLogReport-Guide.md (tools\Build-Documentation.ps1):
    it is self-contained (images inline), so the Markdown source and the images are not copied.
    It never copies data\, reports\, logs\, bin\ or tests\: there is no database in the package, the
    tool creates an empty one at the first collection.

    The configuration is copied as delivered (example server names). The script checks that no
    database, report or log file is in the package.

.PARAMETER Destination
    Package folder. Default: package\ExchangeLogReport-<version>, next to the tool folder.

.PARAMETER Force
    Replace the destination folder if it already contains a package. A folder that contains a data\
    sub-folder (a package that has been run) is never replaced.

.EXAMPLE
    .\tools\New-ExchangeLogReportPackage.ps1
    Creates ..\package\ExchangeLogReport-1.4.0.

.NOTES
    Author  : Nicolas Fabert
    Version : 1.4.0
#>
[CmdletBinding()]
param(
    [string]$Destination,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$version = (Import-PowerShellDataFile (Join-Path $root 'ExchangeLogReport.psd1')).ModuleVersion
if (-not $Destination) { $Destination = Join-Path (Split-Path $root -Parent) "package\ExchangeLogReport-$version" }
$Destination = [IO.Path]::GetFullPath($Destination, (Get-Location).Path).TrimEnd('\')

$rootPrefix = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
if (($Destination + '\').StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -or $rootPrefix.StartsWith($Destination + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "The destination must be outside the tool folder: $Destination"
}
if (Test-Path -LiteralPath $Destination) {
    if (-not $Force) { throw "The destination already exists: $Destination. Use -Force to replace it." }
    if (-not (Test-Path -LiteralPath (Join-Path $Destination 'Invoke-ExchangeLogReport.ps1'))) { throw "The destination is not an Exchange Log Report package, it is not replaced: $Destination" }
    if (Test-Path -LiteralPath (Join-Path $Destination 'data')) { throw "The destination contains a data folder (a database may be in it), it is not replaced: $Destination" }
    Remove-Item -LiteralPath $Destination -Recurse -Force
}

# ---- HTML guide, rebuilt from the Markdown source -------------------------------------------------
& (Join-Path $PSScriptRoot 'Build-Documentation.ps1') | Out-Null

# ---- Files needed at run time -------------------------------------------------------------------
$files = [Collections.Generic.List[string]]::new()
foreach ($f in 'Invoke-ExchangeLogReport.ps1', 'ExchangeLogReport.psd1', 'ExchangeLogReport.psm1', 'README.md', 'CHANGELOG.md', 'THIRD-PARTY-NOTICES.md',
    'config\ExchangeLogReport.config.psd1', 'templates\Report.template.html', 'docs\ExchangeLogReport-Guide.html') { $files.Add($f) }
foreach ($folder in 'src', 'lib\sqlite') {
    Get-ChildItem -LiteralPath (Join-Path $root $folder) -Recurse -File | ForEach-Object { $files.Add($_.FullName.Substring($rootPrefix.Length)) }
}
foreach ($f in $files) {
    $source = Join-Path $root $f
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
foreach ($f in 'src\Engine.Text.cs', 'src\Engine.Store.cs', 'src\Engine.Collector.cs', 'src\Engine.Sessions.cs', 'src\Engine.Report.cs', 'src\Engine.ReportSessions.cs', 'src\Get-ExlExchangeSettings.ps1', 'lib\sqlite\runtimes\win-x64\e_sqlite3.dll', 'docs\ExchangeLogReport-Guide.html') {
    if (-not (Test-Path -LiteralPath (Join-Path $Destination $f))) { $problems.Add("Missing in the package: $f") }
}
if ($problems.Count) { throw ("Package not valid ($Destination):`n - " + ($problems -join "`n - ")) }

$all = Get-ChildItem -LiteralPath $Destination -Recurse -File
Write-Host ''
Write-Host "  Exchange Log Report $version - package ready" -ForegroundColor Green
Write-Host "  Folder   : $Destination"
Write-Host ("  Content  : {0} files, {1:N1} MB" -f $all.Count, (($all | Measure-Object Length -Sum).Sum / 1MB))
Write-Host "  Database : none - the tool creates an empty database at the first collection"
Write-Host "  Config   : example servers - list the Exchange servers, then run -Mode Discover (guide, chapter 6)"
Write-Host ''
$all | Sort-Object FullName | ForEach-Object { '    {0,12:N0}  {1}' -f $_.Length, $_.FullName.Substring($Destination.Length + 1) }
