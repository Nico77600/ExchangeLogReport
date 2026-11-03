#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

BeforeAll {
    $script:Root = Join-Path (Split-Path $PSScriptRoot -Parent) 'package'
    $script:Module = Import-Module (Join-Path $script:Root 'ExchangeLogReport.psd1') -Force -PassThru
    $script:Work = Join-Path $script:Root ('bin\t\i' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void][IO.Directory]::CreateDirectory($script:Work)
    function Invoke-ServeChild([string]$Code) {
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Code))
        $output = & ([Environment]::ProcessPath) -NoProfile -NonInteractive -EncodedCommand $encoded 2>&1
        if ($LASTEXITCODE -ne 0) { throw ($output -join "`n") }
        return $output -join "`n"
    }
    # A fake verifier cannot pass: the module checks the owner signature of src\Test-PackageIntegrity.ps1 before running it.
    function Write-TestVerifier([string]$Code) {
        [void][IO.Directory]::CreateDirectory((Join-Path $script:Package 'src'))
        [IO.File]::WriteAllText((Join-Path $script:Package 'PackageIntegrity.psd1'), '@{}')
        [IO.File]::WriteAllText((Join-Path $script:Package 'src\Test-PackageIntegrity.ps1'), $Code)
    }
}
AfterAll {
    & $script:Module { param($Root) $script:ToolRoot = $Root } $script:Root
    if ($script:Work) { Remove-Item -LiteralPath $script:Work -Recurse -Force }
}

Describe 'Serve package preflight' {
    BeforeEach {
        $script:Package = Join-Path $script:Work ([guid]::NewGuid().ToString('N').Substring(0, 8))
        [void][IO.Directory]::CreateDirectory($script:Package)
        & $script:Module { param($Root) $script:ToolRoot = $Root } $script:Package
        $script:Order = Join-Path $script:Package 'order.log'
        Mock Initialize-ExlEngine -ModuleName ExchangeLogReport -MockWith ([scriptblock]::Create("Add-Content -LiteralPath '$script:Order' -Value 'initialize'; throw 'initialize-sentinel'"))
    }
    AfterEach {
        & $script:Module { param($Root) $script:ToolRoot = $Root } $script:Root
    }
    It 'requires explicit development acknowledgement when the manifest is absent' {
        { Start-ExlServe -DatabasePath 'synthetic.sqlite' -NoBrowser } | Should -Throw '*DevelopmentMode*'
        Should -Invoke Initialize-ExlEngine -ModuleName ExchangeLogReport -Times 0 -Exactly
    }
    It 'permits an explicitly acknowledged source checkout before initializing the engine' {
        { Start-ExlServe -DatabasePath 'synthetic.sqlite' -NoBrowser -DevelopmentMode -WarningAction SilentlyContinue } | Should -Throw '*initialize-sentinel*'
        Should -Invoke Initialize-ExlEngine -ModuleName ExchangeLogReport -Times 1 -Exactly
    }
    It 'does not let development mode bypass a present manifest with a missing verifier' {
        [IO.File]::WriteAllText((Join-Path $script:Package 'PackageIntegrity.psd1'), '@{}')
        { Start-ExlServe -DatabasePath 'synthetic.sqlite' -DevelopmentMode -NoBrowser } | Should -Throw '*verifier is missing*'
        Should -Invoke Initialize-ExlEngine -ModuleName ExchangeLogReport -Times 0 -Exactly
    }
    It 'does not interpret a manifest directory as an unmanifested development checkout' {
        [void][IO.Directory]::CreateDirectory((Join-Path $script:Package 'PackageIntegrity.psd1'))
        { Start-ExlServe -DatabasePath 'synthetic.sqlite' -DevelopmentMode -NoBrowser } | Should -Throw '*must be a file*'
        Should -Invoke Initialize-ExlEngine -ModuleName ExchangeLogReport -Times 0 -Exactly
    }
    It 'refuses a verifier without the owner signature before running it, even in development mode' {
        Write-TestVerifier 'param($Root) [IO.File]::WriteAllText((Join-Path $Root "executed"), "yes"); [pscustomobject]@{ Status = "Valid" }'
        { Start-ExlServe -DatabasePath 'synthetic.sqlite' -DevelopmentMode -NoBrowser } | Should -Throw '*owner signature*'
        Test-Path -LiteralPath (Join-Path $script:Package 'executed') | Should -BeFalse
        Should -Invoke Initialize-ExlEngine -ModuleName ExchangeLogReport -Times 0 -Exactly
    }
    It 'fails before initialization when the package verifier rejects its bytes' {
        Mock Assert-ExlPackageIntegrity -ModuleName ExchangeLogReport { throw 'synthetic-integrity-rejected' }
        { Start-ExlServe -DatabasePath 'synthetic.sqlite' -DevelopmentMode -NoBrowser } | Should -Throw '*synthetic-integrity-rejected*'
        Should -Invoke Initialize-ExlEngine -ModuleName ExchangeLogReport -Times 0 -Exactly
    }
    It 'passes the package root to the integrity check and completes it before initialization' {
        Mock Assert-ExlPackageIntegrity -ModuleName ExchangeLogReport -MockWith ([scriptblock]::Create("Add-Content -LiteralPath '$script:Order' -Value ('assert ' + `$Root + ' ' + `$RequireManifest.IsPresent)"))
        { Start-ExlServe -DatabasePath 'synthetic.sqlite' -NoBrowser } | Should -Throw '*initialize-sentinel*'
        @(Get-Content -LiteralPath $script:Order) | Should -Be @("assert $script:Package True", 'initialize')
        Should -Invoke Initialize-ExlEngine -ModuleName ExchangeLogReport -Times 1 -Exactly
    }
}
Describe 'In-memory engine initialization' {
    It 'verifies a present package manifest before loading SQLite or reusing any engine' {
        $package = Join-Path $script:Work 'direct'
        [void][IO.Directory]::CreateDirectory((Join-Path $package 'src'))
        [IO.File]::WriteAllText((Join-Path $package 'PackageIntegrity.psd1'), '@{}')
        [IO.File]::WriteAllText((Join-Path $package 'src\Test-PackageIntegrity.ps1'), 'param($Root) throw "direct-integrity-executed"')
        foreach ($root in @($package, ($package + '\'))) {
            { Initialize-ExlEngine -Root $root } | Should -Throw '*owner signature*'
        }
    }
    It 'ignores an untrusted hash-named cache and does not emit any executable engine cache' {
        $sources = @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'src') -Filter 'Engine.*.cs' -File | Sort-Object Name)
        $text = [Text.StringBuilder]::new()
        foreach ($file in $sources) { [void]$text.Append($file.Name).Append((Get-FileHash -LiteralPath $file.FullName).Hash) }
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text.ToString())))
        $cache = Join-Path $script:Root ('bin\ExchangeLogReport.Engine.' + $hash.Substring(0,16) + '.dll')
        $created = $false
        try {
            if (-not (Test-Path -LiteralPath $cache)) {
                $file = [IO.File]::Open($cache, [IO.FileMode]::CreateNew)
                try { $file.Write([Text.Encoding]::UTF8.GetBytes('Untrusted synthetic cache: never load this file.')) } finally { $file.Dispose() }
                $created = $true
            }
            $before = @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'bin') -File -Filter '*.dll' | ForEach-Object Name)
            $module = (Join-Path $script:Root 'ExchangeLogReport.psd1').Replace("'", "''")
            $code = "`$ErrorActionPreference='Stop'; Import-Module '$module'; Initialize-ExlEngine; Initialize-ExlEngine; if([ExchangeLogReport.Store].Assembly.Location){throw 'Disk engine was loaded'}; 'ENGINE_IN_MEMORY'"
            Invoke-ServeChild $code | Should -Match 'ENGINE_IN_MEMORY'
            @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'bin') -File -Filter '*.dll' | ForEach-Object Name) -join ';' | Should -BeExactly ($before -join ';')
        } finally { if ($created) { Remove-Item -LiteralPath $cache -Force } }
    }
    It 'rejects an already loaded file-backed engine instead of trusting its type name' {
        $dll = (Join-Path $script:Work 'preloaded.dll').Replace("'", "''")
        $module = (Join-Path $script:Root 'ExchangeLogReport.psd1').Replace("'", "''")
        $code = @"
`$ErrorActionPreference='Stop'
Add-Type -TypeDefinition 'namespace ExchangeLogReport { public class Store {} }' -OutputAssembly '$dll'
Add-Type -LiteralPath '$dll'
Import-Module '$module'
try { Initialize-ExlEngine; throw 'Unexpected reuse' }
catch { if(`$_.Exception.Message -notlike '*engine from disk*'){throw}; 'REJECTED_PRELOADED_DISK' }
"@
        Invoke-ServeChild $code | Should -Match 'REJECTED_PRELOADED_DISK'
    }
}
