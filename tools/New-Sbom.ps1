#Requires -Version 7.4
<#
.SYNOPSIS
    Writes the SPDX 2.3 (JSON) software bill of materials of a built package, next to its ZIP.

.DESCRIPTION
    Reads product.json and PackageIntegrity.psd1 of the built package folder and lists what the ZIP ships: the package itself,
    the bundled PowerShell with its .NET runtime, the SQLite command-line tools, the SQLite library with Microsoft.Data.Sqlite and
    the SQLitePCLRaw packages. Every checksum is the SHA-256 of the shipped bytes, taken from the folder.
    Release build: each shipped file used here must equal its entry in the signed manifest and its pin in product.json, or the
    script stops. -Unsigned (continuous integration): the committed manifest is not authoritative and is not compared.
    The output is <zip name>.spdx.json by default; an existing file is never overwritten. The path written is returned.

.NOTES
    Author  : Nicolas Fabert
    Version : 3.1.0
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackageRoot,
    [Parameter(Mandatory)][string]$ZipPath,
    [string]$OutputPath,
    [switch]$Unsigned,
    [datetime]$Created = (Get-Date).ToUniversalTime()
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PackageRoot = [IO.Path]::GetFullPath($PackageRoot).TrimEnd('\')
$ZipPath = [IO.Path]::GetFullPath($ZipPath)
if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) { throw "The ZIP does not exist: $ZipPath" }
if (-not $OutputPath) { $OutputPath = "$ZipPath.spdx.json" }
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $OutputPath) { throw "The SBOM already exists; existing files are never overwritten: $OutputPath" }

$product = Get-Content -LiteralPath (Join-Path $PackageRoot 'product.json') -Raw | ConvertFrom-Json
$manifestPath = Join-Path $PackageRoot 'PackageIntegrity.psd1'
$manifest = $null
if (-not $Unsigned) {
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'The signed manifest PackageIntegrity.psd1 is missing from the package folder.' }
    $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
    if ([string]$manifest.Version -cne [string]$product.version) { throw 'The manifest version differs from product.json.' }
}
$manifestHashes = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
if ($manifest) {
    foreach ($entry in @($manifest.Files) + @($manifest.DistributionFiles)) { $manifestHashes[[string]$entry.Path] = ([string]$entry.Sha256).ToLowerInvariant() }
}

function Get-ShippedSha256([string]$Relative, [string]$Pinned) {
    $path = Join-Path $PackageRoot $Relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Shipped file missing from the package folder: $Relative" }
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($Pinned -and $hash -cne $Pinned.ToLowerInvariant()) { throw "Shipped file does not match its pin: $Relative" }
    if ($manifest) {
        if (-not $manifestHashes.ContainsKey($Relative)) { throw "Shipped file is not in the signed manifest: $Relative" }
        if ($manifestHashes[$Relative] -cne $hash) { throw "Shipped file does not match the signed manifest: $Relative" }
    }
    $hash
}
function ConvertTo-SpdxId([string]$Text) { 'SPDXRef-' + ($Text -replace '[^A-Za-z0-9.\-]', '-') }
function New-SpdxPackage {
    param(
        [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Name, [string]$Version, [string]$Supplier = 'NOASSERTION',
        [string]$DownloadLocation = 'NOASSERTION', [string]$Sha256, [string]$License = 'NOASSERTION', [string]$Purl, [string]$Cpe,
        [string]$Purpose = 'LIBRARY', [string]$Comment
    )
    $package = [ordered]@{ SPDXID = $Id; name = $Name }
    if ($Version) { $package['versionInfo'] = $Version }
    $package['supplier'] = $Supplier
    $package['downloadLocation'] = $DownloadLocation
    $package['filesAnalyzed'] = $false
    if ($Sha256) { $package['checksums'] = @([ordered]@{ algorithm = 'SHA256'; checksumValue = $Sha256 }) }
    $package['licenseConcluded'] = $License
    $package['licenseDeclared'] = $License
    $package['copyrightText'] = 'NOASSERTION'
    $package['primaryPackagePurpose'] = $Purpose
    $references = [Collections.Generic.List[object]]::new()
    if ($Purl) { $references.Add([ordered]@{ referenceCategory = 'PACKAGE-MANAGER'; referenceType = 'purl'; referenceLocator = $Purl }) }
    if ($Cpe) { $references.Add([ordered]@{ referenceCategory = 'SECURITY'; referenceType = 'cpe23Type'; referenceLocator = $Cpe }) }
    if ($references.Count) { $package['externalRefs'] = $references.ToArray() }
    if ($Comment) { $package['comment'] = $Comment }
    $package
}

$zipName = [IO.Path]::GetFileName($ZipPath)
$zipSha256 = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$version = [string]$product.version
$packages = [Collections.Generic.List[object]]::new()
$relationships = [Collections.Generic.List[object]]::new()
$rootId = 'SPDXRef-Package-' + $product.name
$download = if ($Unsigned) { 'NOASSERTION' } else { "https://github.com/Nico77600/ExchangeLogReport/releases/download/v$version/$zipName" }
$packages.Add((New-SpdxPackage -Id $rootId -Name ([string]$product.name) -Version $version -Supplier 'Person: Nico77600' -DownloadLocation $download `
    -Sha256 $zipSha256 -License 'MIT' -Purpose 'APPLICATION' -Purl "pkg:github/Nico77600/ExchangeLogReport@v$version" `
    -Comment $(if ($Unsigned) { 'Unsigned continuous-integration build; never a release.' } else { "Release ZIP $zipName; the file inventory and hashes are in the signed manifest PackageIntegrity.psd1 inside the ZIP." })))
$relationships.Add([ordered]@{ spdxElementId = 'SPDXRef-DOCUMENT'; relationshipType = 'DESCRIBES'; relatedSpdxElement = $rootId })

$pwshExe = Get-ShippedSha256 'powershell\pwsh.exe' $null
$powerShellId = 'SPDXRef-Package-PowerShell'
$packages.Add((New-SpdxPackage -Id $powerShellId -Name 'PowerShell' -Version ([string]$product.powerShell.version) -Supplier 'Organization: Microsoft Corporation' `
    -DownloadLocation ([string]$product.powerShell.url) -Sha256 ([string]$product.powerShell.sha256).ToLowerInvariant() -License 'MIT' -Purpose 'APPLICATION' `
    -Purl "pkg:github/PowerShell/PowerShell@v$($product.powerShell.version)" `
    -Cpe "cpe:2.3:a:microsoft:powershell:$($product.powerShell.version):*:*:*:*:*:*:*" `
    -Comment "Portable win-x64 archive extracted to powershell\; the checksum is the archive. pwsh.exe SHA-256 $pwshExe."))
$relationships.Add([ordered]@{ spdxElementId = $rootId; relationshipType = 'CONTAINS'; relatedSpdxElement = $powerShellId })

$coreLib = 'powershell\System.Private.CoreLib.dll'
$coreLibSha256 = Get-ShippedSha256 $coreLib $null
$runtimeVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $PackageRoot $coreLib)).ProductVersion
if ($runtimeVersion -cmatch '^(?<version>\d+\.\d+\.\d+)') { $runtimeVersion = $Matches['version'] }
else { throw "The .NET runtime version cannot be read from $coreLib." }
if ($product.powerShell.PSObject.Properties['dotNetRuntimeVersion'] -and [string]$product.powerShell.dotNetRuntimeVersion -cne $runtimeVersion) {
    throw "The .NET runtime of the package ($runtimeVersion) differs from powerShell.dotNetRuntimeVersion of product.json ($($product.powerShell.dotNetRuntimeVersion))."
}
$runtimeId = 'SPDXRef-Package-DotNetRuntime'
$packages.Add((New-SpdxPackage -Id $runtimeId -Name '.NET Runtime' -Version $runtimeVersion -Supplier 'Organization: Microsoft Corporation' -Sha256 $coreLibSha256 `
    -License 'MIT' -Purl "pkg:nuget/Microsoft.NETCore.App.Runtime.win-x64@$runtimeVersion" -Cpe "cpe:2.3:a:microsoft:.net:${runtimeVersion}:*:*:*:*:*:*:*" `
    -Comment "Self-contained runtime inside the PowerShell archive; the version is the product version of $coreLib and the checksum is that file."))
$relationships.Add([ordered]@{ spdxElementId = $powerShellId; relationshipType = 'CONTAINS'; relatedSpdxElement = $runtimeId })

$toolsExe = Get-ShippedSha256 'sqlite-tools\sqlite3.exe' ([string]$product.sqliteTools.executableSha256)
$toolsId = 'SPDXRef-Package-SQLiteTools'
$packages.Add((New-SpdxPackage -Id $toolsId -Name 'SQLite command-line tools' -Version ([string]$product.sqliteTools.version) -Supplier 'Organization: SQLite Development Team' `
    -DownloadLocation ([string]$product.sqliteTools.url) -Sha256 ([string]$product.sqliteTools.archiveSha256).ToLowerInvariant() -License 'LicenseRef-PublicDomain' `
    -Purpose 'APPLICATION' -Purl "pkg:generic/sqlite@$($product.sqliteTools.version)" -Cpe "cpe:2.3:a:sqlite:sqlite:$($product.sqliteTools.version):*:*:*:*:*:*:*" `
    -Comment "Official archive; the checksum is the archive. Shipped file sqlite-tools\sqlite3.exe SHA-256 $toolsExe."))
$relationships.Add([ordered]@{ spdxElementId = $rootId; relationshipType = 'CONTAINS'; relatedSpdxElement = $toolsId })

$directory = ([string]$product.sqliteLibraries.directory).Replace('/', '\')
foreach ($library in $product.sqliteLibraries.packages) {
    $files = foreach ($file in $library.files) {
        $relative = Join-Path $directory ([string]$file.path).Replace('/', '\')
        '{0} SHA-256 {1}' -f $relative, (Get-ShippedSha256 $relative ([string]$file.sha256))
    }
    $libraryId = ConvertTo-SpdxId ('Package-' + $library.id)
    $packages.Add((New-SpdxPackage -Id $libraryId -Name ([string]$library.id) -Version ([string]$library.version) -Supplier "Organization: $($library.supplier)" `
        -DownloadLocation ([string]$library.url) -Sha256 ([string]$library.packageSha256) -License ([string]$library.license) `
        -Purl "pkg:nuget/$($library.id)@$($library.version)" -Comment ('Official NuGet package; the checksum is the package. Shipped files: ' + ($files -join '; '))))
    $relationships.Add([ordered]@{ spdxElementId = $rootId; relationshipType = 'CONTAINS'; relatedSpdxElement = $libraryId })
    if ($library.PSObject.Properties['sqliteVersion']) {
        $engineId = 'SPDXRef-Package-SQLiteLibrary'
        $packages.Add((New-SpdxPackage -Id $engineId -Name 'SQLite (native library)' -Version ([string]$library.sqliteVersion) -Supplier 'Organization: SQLite Development Team' `
            -License 'LicenseRef-PublicDomain' -Purl "pkg:generic/sqlite@$($library.sqliteVersion)" -Cpe "cpe:2.3:a:sqlite:sqlite:$($library.sqliteVersion):*:*:*:*:*:*:*" `
            -Comment "Compiled into e_sqlite3.dll of $($library.id) $($library.version)."))
        $relationships.Add([ordered]@{ spdxElementId = $libraryId; relationshipType = 'CONTAINS'; relatedSpdxElement = $engineId })
    }
}

$document = [ordered]@{
    spdxVersion = 'SPDX-2.3'
    dataLicense = 'CC0-1.0'
    SPDXID = 'SPDXRef-DOCUMENT'
    name = [IO.Path]::GetFileNameWithoutExtension($zipName)
    documentNamespace = 'https://github.com/Nico77600/ExchangeLogReport/spdx/{0}-{1}' -f [IO.Path]::GetFileNameWithoutExtension($zipName), $zipSha256.Substring(0, 32)
    creationInfo = [ordered]@{
        created = $Created.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
        creators = @("Tool: ExchangeLogReport-New-Sbom-$version")
        comment = $(if ($Unsigned) { 'Generated from product.json of the built package folder.' } else { 'Generated from product.json and the signed manifest PackageIntegrity.psd1 of the built package folder.' })
    }
    packages = $packages.ToArray()
    hasExtractedLicensingInfos = @([ordered]@{
        licenseId = 'LicenseRef-PublicDomain'
        name = 'Public domain'
        extractedText = 'SQLite is in the public domain. See https://sqlite.org/copyright.html'
    })
    relationships = $relationships.ToArray()
}
$json = ConvertTo-Json -InputObject $document -Depth 10
[IO.File]::WriteAllText($OutputPath, ($json -replace "`r?`n", "`n") + "`n", [Text.UTF8Encoding]::new($false))
$OutputPath
