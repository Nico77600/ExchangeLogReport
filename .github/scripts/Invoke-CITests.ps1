#Requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackageRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$PackageRoot = [IO.Path]::GetFullPath($PackageRoot).TrimEnd('\')
$product = Get-Content -LiteralPath (Join-Path $root 'product.json') -Raw | ConvertFrom-Json
$runtime = Join-Path $PackageRoot 'powershell'
if ([IO.Path]::GetFullPath($PSHOME).TrimEnd('\') -ine $runtime -or
    $PSVersionTable.PSVersion.ToString() -cne [string]$product.powerShell.version -or
    [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne 'X64') {
    throw 'Tests must run under the newly packaged, configured x64 PowerShell runtime.'
}
# The CI build carries the committed signed manifest. Its built folders (PowerShell runtime, SQLite tool) are assembled on the runner, so they
# are not compared with it here (-DevelopmentMode); the files and the PowerShell signatures are. The release package is verified
# with -Distribution. A tree without a committed manifest is reported, and the RealSignature tests refuse it.
if (Test-Path -LiteralPath (Join-Path $PackageRoot 'PackageIntegrity.psd1')) {
    & (Join-Path $PackageRoot 'src\Test-PackageIntegrity.ps1') -Root $PackageRoot -DevelopmentMode | Out-Null
} else {
    Write-Warning 'The package has no PackageIntegrity.psd1: its files and signatures were not verified.'
}
$env:PATH = $runtime + ';' + $env:PATH
if (-not $env:CI_MODULE_PATH) { throw 'The pinned CI module path is missing.' }
Import-Module (Join-Path $env:CI_MODULE_PATH 'Pester\6.1.0\Pester.psd1') -RequiredVersion 6.1.0 -Force
$testWork = Join-Path $root 'artifacts\ci-test-work'
[void][IO.Directory]::CreateDirectory($testWork)
$env:TEMP = $testWork
$env:TMP = $testWork
$tests = Join-Path $root 'tests'
$serveTests = @(Get-ChildItem -LiteralPath $tests -Filter 'Serve*.Tests.ps1' -File | Where-Object Name -NE 'Serve.Package.Tests.ps1')
if (-not $serveTests.Count) { throw 'The Serve regression tests are required before CI can pass.' }
$configuration = New-PesterConfiguration
$configuration.Run.Path = @(
    foreach ($name in 'ExchangeLogReport', 'SqliteOptimization', 'Serve.Backend', 'Serve.Initialization', 'Serve.MeasurementGate', 'Serve.Performance',
        'Serve.RollupVerification', 'Serve.SmtpClients', 'PackageIntegrity', 'Workflow') {
        Join-Path $tests ($name + '.Tests.ps1')
    }
)
$configuration.Run.Container = @(
    New-PesterContainer -Path (Join-Path $root 'tests\LegacyComparison.Tests.ps1') -Data @{
        WorkRoot = Join-Path $testWork ('legacy-comparison-' + [guid]::NewGuid().ToString('N'))
    }
)
# The storage tool compiles the engine together with the storage sources; a process holds one compiled shape, so its suite
# runs in a child process of the same packaged runtime.
$storageRun = & (Join-Path $runtime 'pwsh.exe') -NoLogo -NoProfile -Command "`$ErrorActionPreference = 'Stop'; Import-Module '$(Join-Path $env:CI_MODULE_PATH 'Pester\6.1.0\Pester.psd1')' -RequiredVersion 6.1.0; `$r = Invoke-Pester -Path '$(Join-Path $tests 'Storage.Tests.ps1')' -PassThru -Output Normal; Write-Output ('STORAGE ' + `$r.PassedCount + ' ' + `$r.FailedCount); exit [int](`$r.Result -ne 'Passed')"
$storageExit = $LASTEXITCODE
$storageRun | Write-Host
$configuration.Run.PassThru = $true
$configuration.Run.Exit = $false
$configuration.Output.Verbosity = 'Normal'
# The tests tagged Measurement measure the memory of fresh processes: they run last and alone, after every other test.
$configuration.Filter.ExcludeTag = 'Measurement'
$result = Invoke-Pester -Configuration $configuration
$measurement = New-PesterConfiguration
$measurement.Run.Path = $configuration.Run.Path.Value
$measurement.Filter.Tag = 'Measurement'
$measurement.Run.PassThru = $true
$measurement.Run.Exit = $false
$measurement.Output.Verbosity = 'Normal'
$measured = Invoke-Pester -Configuration $measurement
$evidence = Join-Path $root 'artifacts\ci-evidence'
[void][IO.Directory]::CreateDirectory($evidence)
# Do not upload test working directories, databases, ready files, tokens or raw logs.
@{
    result = $(if ([string]$measured.Result -ne 'Passed') { [string]$measured.Result } else { [string]$result.Result })
    passed = $result.PassedCount + $measured.PassedCount
    failed = $result.FailedCount + $measured.FailedCount
    skipped = $result.SkippedCount + $measured.SkippedCount
    total = $result.TotalCount
    powerShellVersion = $PSVersionTable.PSVersion.ToString()
    runtime = '.\powershell\pwsh.exe from the freshly built package'
    fixturePolicy = 'Synthetic fixtures only; no lab configuration or source database'
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $evidence 'validation-summary.json') -Encoding utf8
if ($storageExit -ne 0 -or $result.Result -ne 'Passed' -or $result.FailedCount -gt 0 -or $result.TotalCount -eq 0 -or
    $measured.Result -ne 'Passed' -or $measured.FailedCount -gt 0 -or $measured.PassedCount -eq 0) {
    throw 'Pester validation did not pass.'
}
