#Requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Destination)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or -not $env:GITHUB_ENV) {
    throw 'Module download is permitted only on the disposable GitHub Actions runner.'
}
if (Test-Path -LiteralPath $Destination) { throw 'Use a new module destination.' }
[void][IO.Directory]::CreateDirectory($Destination)
Add-Type -AssemblyName System.IO.Compression.FileSystem

# The SHA-256 is that of the official .nupkg of the exact version on the PowerShell Gallery, checked against the SHA-512 the gallery publishes for it.
$modules = @(
    @{ Name = 'Pester'; Version = '6.1.0'; PackageSha256 = '0207a75ea09f81b27c1ded44898b2bb3c845bafa02045bd64a39e26a53ca41b4' }
    @{ Name = 'PSScriptAnalyzer'; Version = '1.25.0'; PackageSha256 = '14e634c828eb98efb9f40b2918ba90f139ed5eccdf663a2a747736d996995d60' }
)

function Install-PinnedModule {
    param([string]$Name, [string]$Version, [string]$PackageSha256, [string]$Package, [string]$Destination)
    $actual = (Get-FileHash -LiteralPath $Package -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -cne $PackageSha256) { throw "The downloaded $Name package does not match its pinned SHA-256." }
    $target = Join-Path $Destination ('{0}\{1}' -f $Name, $Version)
    [IO.Compression.ZipFile]::ExtractToDirectory($Package, $target)
    foreach ($part in '_rels', 'package') { Remove-Item -LiteralPath (Join-Path $target $part) -Recurse -Force }
    Remove-Item -LiteralPath (Join-Path $target '[Content_Types].xml') -Force
}

$downloads = Join-Path ([IO.Path]::GetTempPath()) ('ci-module-packages-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($downloads)
foreach ($module in $modules) {
    $package = Join-Path $downloads ('{0}.{1}.nupkg' -f $module.Name, $module.Version)
    Invoke-WebRequest -Uri ('https://www.powershellgallery.com/api/v2/package/{0}/{1}' -f $module.Name, $module.Version) -OutFile $package
    Install-PinnedModule -Name $module.Name -Version $module.Version -PackageSha256 $module.PackageSha256 -Package $package -Destination $Destination
}
Remove-Item -LiteralPath $downloads -Recurse -Force
$evidence = Join-Path $PSScriptRoot '..\..\artifacts\ci-evidence'
[void][IO.Directory]::CreateDirectory($evidence)
$inventory = foreach ($module in $modules) {
    $manifest = Join-Path $Destination ('{0}\{1}\{0}.psd1' -f $module.Name, $module.Version)
    if ((Import-PowerShellDataFile -LiteralPath $manifest).ModuleVersion -cne $module.Version) {
        throw "The downloaded $($module.Name) manifest does not match the exact version pin."
    }
    $moduleRoot = Split-Path $manifest -Parent
    @{
        name = $module.Name
        version = $module.Version
        packageSha256 = $module.PackageSha256
        hashPurpose = 'Files extracted from a package whose SHA-256 matched the reviewed pin'
        files = @(Get-ChildItem -LiteralPath $moduleRoot -File -Recurse | Sort-Object FullName | ForEach-Object {
            @{
                path = $_.FullName.Substring($moduleRoot.Length + 1).Replace('\', '/')
                sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        })
    }
}
ConvertTo-Json -InputObject @($inventory) -Depth 6 | Set-Content -LiteralPath (Join-Path $evidence 'module-inventory.json') -Encoding utf8
'CI_MODULE_PATH={0}' -f [IO.Path]::GetFullPath($Destination) |
    Out-File -LiteralPath $env:GITHUB_ENV -Encoding utf8 -Append
