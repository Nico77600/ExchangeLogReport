#Requires -Version 7.4
param(
    [Parameter(Mandatory)][string]$PackageRoot,
    [Parameter(Mandatory)][string]$Database,
    # A package built by CI is unsigned and its binaries are compared with the signed manifest only on the release build.
    [switch]$DevelopmentMode
)
BeforeAll {
    $ErrorActionPreference = 'Stop'
    $script:Package = [IO.Path]::GetFullPath($PackageRoot)
    $script:Database = [IO.Path]::GetFullPath($Database)
    $script:SourceHash = (Get-FileHash -LiteralPath $script:Database).Hash
    $script:ReadyPath = Join-Path $TestDrive 'ready.json'
    $script:ResultFile = Join-Path $TestDrive 'http-timings.json'
    $saved = @{ PATH = $env:PATH; DOTNET_ROOT = $env:DOTNET_ROOT; DOTNET_MULTILEVEL_LOOKUP = $env:DOTNET_MULTILEVEL_LOOKUP }
    try {
        $env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
        $env:DOTNET_ROOT = Join-Path $TestDrive 'no-installed-runtime'
        $env:DOTNET_MULTILEVEL_LOOKUP = '0'
        $arguments = @('-NoLogo', '-NoProfile', '-File', "`"$(Join-Path $script:Package 'Invoke-ExchangeLogReport.ps1')`"",
            '-Mode', 'Serve', '-DatabasePath', "`"$script:Database`"",
            '-Port', '0', '-NoBrowser', '-ReadyFile', "`"$script:ReadyPath`"", '-ReadyFileWithToken')
        if ($DevelopmentMode) { $arguments += '-DevelopmentMode' }
        $script:Process = Start-Process -FilePath (Join-Path $script:Package 'powershell\pwsh.exe') -ArgumentList $arguments -WindowStyle Hidden `
            -PassThru -RedirectStandardOutput (Join-Path $TestDrive 'stdout.txt') -RedirectStandardError (Join-Path $TestDrive 'stderr.txt')
    } finally {
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    }
    $deadline = [datetime]::UtcNow.AddSeconds(60)
    while (-not (Test-Path -LiteralPath $script:ReadyPath) -and -not $script:Process.HasExited -and [datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path -LiteralPath $script:ReadyPath)) {
        throw "Portable Serve failed to start: $(Get-Content -LiteralPath (Join-Path $TestDrive 'stderr.txt') -Raw)"
    }
    $ready = Get-Content -LiteralPath $script:ReadyPath -Raw | ConvertFrom-Json
    if ($ready.status -ne 'ready') { throw "Serve is blocked: $($ready.message)" }
    $script:Url = $ready.url.TrimEnd('/')
    $script:Headers = @{ 'X-Portal-Token' = $ready.token }
    $meta = Invoke-RestMethod -Uri ($script:Url + '/api/meta') -Headers $script:Headers
    if ($meta.requiresMigration -or -not $meta.coveredFrom -or -not $meta.coveredTo) {
        throw 'Packaged Serve tests require a compatible synthetic database with recorded source coverage.'
    }
    $from = [DateTimeOffset]::Parse($meta.coveredFrom, [Globalization.CultureInfo]::InvariantCulture)
    $to = [DateTimeOffset]::Parse($meta.coveredTo, [Globalization.CultureInfo]::InvariantCulture).AddMilliseconds(1)
    $script:Filter = '?from=' + [Uri]::EscapeDataString($from.ToString('O')) +
        '&to=' + [Uri]::EscapeDataString($to.ToString('O'))
    function Serve-Request([string]$Path) {
        Invoke-WebRequest -Uri ($script:Url + $Path) -Headers $script:Headers -SkipHttpErrorCheck
    }
}
AfterAll {
    if ($script:Process -and -not $script:Process.HasExited) {
        try { Invoke-WebRequest -Uri ($script:Url + '/api/shutdown') -Method Post -Headers $script:Headers | Out-Null }
        finally { if (-not $script:Process.WaitForExit(15000)) { Stop-Process -Id $script:Process.Id } }
    }
}
Describe 'Packaged HttpListener Serve' {
    It 'uses the real portable runtime and serves the report page built from the template' {
        $manifestPath = Join-Path $script:Package 'PackageIntegrity.psd1'
        if (Test-Path -LiteralPath $manifestPath) {
            (Import-PowerShellDataFile -LiteralPath $manifestPath).Files.Path | Should -Contain 'README.md'
        } elseif (-not $DevelopmentMode) { throw 'A release package carries PackageIntegrity.psd1.' }
        $readme = Get-Content -LiteralPath (Join-Path $script:Package 'README.md') -Raw
        $readme | Should -Match '## Requirements'
        $readme | Should -Match '## Disclaimer'
        $html = Serve-Request '/'
        $html.StatusCode | Should -Be 200
        $html.Content | Should -Match ([regex]::Escape('<script id="report-meta" type="application/json">{"served":true}</script>'))
        $html.Content | Should -Match ([regex]::Escape('<script src="report.js"></script>'))
        $html.Headers['Content-Security-Policy'][0] | Should -Match "script-src 'self' 'sha256-[^']+' 'sha256-[^']+';"
        $script = Serve-Request '/report.js'
        $script.StatusCode | Should -Be 200
        $script.Content | Should -BeExactly ([IO.File]::ReadAllText((Join-Path $script:Package 'templates\Report.template.js')))
        $meta = (Serve-Request '/api/meta').Content | ConvertFrom-Json
        $meta.mode | Should -Be 'Serve'
        $meta.version | Should -Be '3.0.0'
        $meta.schemaVersion | Should -Be 13
        $meta.requiresMigration | Should -BeFalse
        @(Get-ChildItem -LiteralPath (Join-Path $script:Package 'lib') -Filter '*.dll' -Recurse -File |
            Where-Object FullName -Match '\\bin\\').Count | Should -Be 0
    }
    It 'serves / and /report.js only, and never exposes arbitrary files' {
        (Serve-Request '/messages').StatusCode | Should -Be 404
        (Serve-Request '/index.html').StatusCode | Should -Be 404
        (Serve-Request ('/' + $script:Filter)).StatusCode | Should -Be 400
        (Serve-Request '/api/not-a-route').StatusCode | Should -Be 404
        (Serve-Request '/config/ExchangeLogReport.config.psd1').StatusCode | Should -Not -Be 200
        (Invoke-WebRequest -Uri ($script:Url + '/api/meta') -SkipHttpErrorCheck).StatusCode | Should -Be 401
    }
    It 'loads only bounded list pages with no transcripts and measures the selected dataset honestly' {
        $timings = foreach ($view in @('messages', 'sessions', 'smtp/clients')) {
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $response = Serve-Request ("/api/$view" + $script:Filter + '&size=50&page=1')
            $watch.Stop()
            $response.StatusCode | Should -Be 200
            $body = $response.Content | ConvertFrom-Json
            @($body.rows).Count | Should -BeLessOrEqual 50
            $body.columns.name | Should -Not -Contain 'SMTP transcripts'
            [pscustomobject]@{ view = $view; milliseconds = $watch.Elapsed.TotalMilliseconds; rows = @($body.rows).Count }
        }
        $timings | ConvertTo-Json | Set-Content -LiteralPath $script:ResultFile -Encoding utf8
        foreach ($timing in $timings) { $timing.milliseconds | Should -BeLessThan 1000 -Because $timing.view }
    }
    It 'serves the hourly Overview from the delivered collector source' {
        $response = Serve-Request ('/api/overview' + $script:Filter)
        $response.StatusCode | Should -Be 200
        $body = $response.Content | ConvertFrom-Json
        $body.columns[0].name | Should -BeExactly 'Hour'
        $body.columns[9].name | Should -BeExactly 'Retained access requests'
        @($body.rows).Count | Should -BeGreaterThan 0
        @($body.rows).Count | Should -BeLessOrEqual 10000
        $body.basis | Should -Match 'exact BINARY Message-IDs distinct within each bin'
        (Get-FileHash -LiteralPath $script:Database).Hash | Should -Be $script:SourceHash
    }
    It 'loads a selected message detail without building any Detailed report file' {
        $page = (Serve-Request ('/api/messages' + $script:Filter + '&size=1&page=1')).Content | ConvertFrom-Json
        @($page.rows).Count | Should -Be 1
        $detail = (Serve-Request ("/api/messages/$($page.rows[0].id)" + $script:Filter)).Content | ConvertFrom-Json
        $detail.id | Should -Be $page.rows[0].id
        $detail.columns.name | Should -Contain 'Route'
        Test-Path -LiteralPath (Join-Path $script:Package 'reports') | Should -BeFalse
        (Get-FileHash -LiteralPath $script:Database).Hash | Should -Be $script:SourceHash
    }
}
