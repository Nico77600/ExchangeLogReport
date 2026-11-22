#Requires -Version 7.4
<#
.SYNOPSIS
    Verifies the SQLite assemblies of a package folder against the upstream SHA-256 pins of product.json.

.DESCRIPTION
    Default: every file listed under sqliteLibraries in product.json must exist in <PackageRoot>\lib\sqlite with the pinned
    SHA-256, and no other file may be there. Nothing is downloaded.
    -Upstream: additionally downloads each official package from nuget.org into a new scratch folder, checks the package SHA-256,
    reads each pinned entry from the package and checks that its SHA-256 is the pinned one. Use it when a pin is added or changed.
    The folder, the packages and their entries are data: nothing downloaded is executed or loaded.
    Any difference stops with an error. A pin is never rewritten by this script.

.NOTES
    Author  : Nicolas Fabert
    Version : 3.1.0
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackageRoot,
    [string]$ProductFile = (Join-Path (Split-Path $PSScriptRoot -Parent) 'product.json'),
    [switch]$Upstream,
    [string]$WorkRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Sha256Text([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

$PackageRoot = [IO.Path]::GetFullPath($PackageRoot).TrimEnd('\')
$product = Get-Content -LiteralPath $ProductFile -Raw | ConvertFrom-Json
$pins = $product.sqliteLibraries
if ($null -eq $pins -or -not @($pins.packages).Count) { throw 'product.json has no sqliteLibraries pins.' }
$libraryRoot = Join-Path $PackageRoot ([string]$pins.directory).Replace('/', '\')
if (-not (Test-Path -LiteralPath $libraryRoot -PathType Container)) { throw "The SQLite library folder is missing: $libraryRoot" }

$pinned = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($package in $pins.packages) {
    foreach ($file in $package.files) {
        $relative = ([string]$file.path).Replace('/', '\')
        if ($pinned.ContainsKey($relative)) { throw "Duplicate SQLite library pin: $relative" }
        if (([string]$file.sha256) -cnotmatch '^[0-9a-f]{64}$') { throw "The SQLite library pin is not a lowercase SHA-256: $relative" }
        $pinned[$relative] = [string]$file.sha256
    }
}

$present = @(Get-ChildItem -LiteralPath $libraryRoot -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($libraryRoot.Length + 1) })
foreach ($relative in $present) {
    if (-not $pinned.ContainsKey($relative)) { throw "Unpinned file in the SQLite library folder: $relative" }
}
$results = foreach ($relative in $pinned.Keys) {
    $path = Join-Path $libraryRoot $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Pinned SQLite library file is missing: $relative" }
    $actual = Get-Sha256Text $path
    if ($actual -cne $pinned[$relative]) { throw "SQLite library does not match its upstream SHA-256 pin: $relative" }
    [pscustomobject]@{ Path = $relative; Sha256 = $actual; Source = 'pin' }
}

if ($Upstream) {
    $ownsWork = -not $WorkRoot
    if ($ownsWork) { $WorkRoot = Join-Path ([IO.Path]::GetTempPath()) ('exl-sqlite-upstream-' + [guid]::NewGuid().ToString('N')) }
    $WorkRoot = [IO.Path]::GetFullPath($WorkRoot)
    if (Test-Path -LiteralPath $WorkRoot) { throw "Use a new scratch folder: $WorkRoot" }
    [void][IO.Directory]::CreateDirectory($WorkRoot)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    try {
        $results = foreach ($package in $pins.packages) {
            $archive = Join-Path $WorkRoot ('{0}.{1}.nupkg' -f $package.id, $package.version)
            Invoke-WebRequest -Uri $package.url -OutFile $archive
            if ((Get-Sha256Text $archive) -cne [string]$package.packageSha256) {
                throw "The official package does not match its pinned SHA-256: $($package.id) $($package.version)"
            }
            $zip = [IO.Compression.ZipFile]::OpenRead($archive)
            try {
                foreach ($file in $package.files) {
                    $entry = $zip.GetEntry([string]$file.packagePath)
                    if ($null -eq $entry) { throw "Entry not found in $($package.id): $($file.packagePath)" }
                    $stream = $entry.Open()
                    try {
                        $hash = [BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($stream)).Replace('-', '').ToLowerInvariant()
                    } finally { $stream.Dispose() }
                    if ($hash -cne [string]$file.sha256) {
                        throw "The upstream file does not match its pin: $($package.id) $($file.packagePath)"
                    }
                    [pscustomobject]@{ Path = ([string]$file.path).Replace('/', '\'); Sha256 = $hash; Source = "$($package.id) $($package.version)" }
                }
            } finally { $zip.Dispose() }
        }
    } finally {
        if ($ownsWork -and (Test-Path -LiteralPath $WorkRoot)) { Remove-Item -LiteralPath $WorkRoot -Recurse -Force }
    }
}
$results
