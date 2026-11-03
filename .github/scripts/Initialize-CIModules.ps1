#Requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Destination)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or -not $env:GITHUB_ENV) {
    throw 'Module download is permitted only on the disposable GitHub Actions runner.'
}
if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) {
    throw 'PSGallery is not registered. Review the runner configuration; no repository is registered automatically.'
}
if (Test-Path -LiteralPath $Destination) { throw 'Use a new module destination.' }
[void][IO.Directory]::CreateDirectory($Destination)
Save-Module -Name Pester -RequiredVersion 6.1.0 -Repository PSGallery -Path $Destination -ErrorAction Stop
Save-Module -Name PSScriptAnalyzer -RequiredVersion 1.25.0 -Repository PSGallery -Path $Destination -ErrorAction Stop
$evidence = Join-Path $PSScriptRoot '..\..\artifacts\ci-evidence'
[void][IO.Directory]::CreateDirectory($evidence)
$inventory = foreach ($module in @(@{ Name = 'Pester'; Version = '6.1.0' }, @{ Name = 'PSScriptAnalyzer'; Version = '1.25.0' })) {
    $manifest = Join-Path $Destination ('{0}\{1}\{0}.psd1' -f $module.Name, $module.Version)
    if ((Import-PowerShellDataFile -LiteralPath $manifest).ModuleVersion -cne $module.Version) {
        throw "The downloaded $($module.Name) manifest does not match the exact version pin."
    }
    $moduleRoot = Split-Path $manifest -Parent
    @{
        name = $module.Name
        version = $module.Version
        hashPurpose = 'Observed downloaded-file inventory, not an independently trusted package checksum'
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
