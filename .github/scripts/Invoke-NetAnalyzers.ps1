#Requires -Version 7.4
<#
Runs the Microsoft.CodeAnalysis.NetAnalyzers security rules (category Security: CA2100, CA3xxx, CA5xxx) over the production C# sources.
Informational only: the script reports and always exits 0, so that it can never fail a job. The package is pinned by version and SHA-256 in
.github\codeql\build.json. It is downloaded and read as data (its analyzer assemblies are loaded by the compiler only), nothing is restored,
and the output stays outside the runtime package.
#>
[CmdletBinding()]
param([string]$OutputDirectory)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
try {
    $configuration = Get-Content (Join-Path $root '.github\codeql\build.json') -Raw | ConvertFrom-Json
    $analyzer = $configuration.netAnalyzers
    $sourceRoot = [IO.Path]::GetFullPath((Join-Path $root $configuration.productionSourceRoot))
    if ($sourceRoot -notin @((Join-Path $root 'package\src'), (Join-Path $root 'src'))) { throw 'Only the production src directory is supported.' }
    if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root '.github\codeql\out\netanalyzers' }
    $OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
    $allowed = Join-Path $root '.github\codeql\out'
    if (-not ($OutputDirectory -ceq $allowed -or $OutputDirectory.StartsWith($allowed + '\', [StringComparison]::OrdinalIgnoreCase) -or
            -not $OutputDirectory.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase))) {
        throw 'Analysis outputs must not enter the runtime package.'
    }
    if (Test-Path -LiteralPath $OutputDirectory) { throw "Use a new output directory: $OutputDirectory" }
    [void][IO.Directory]::CreateDirectory($OutputDirectory)

    $archive = Join-Path $OutputDirectory ('{0}.{1}.nupkg' -f $analyzer.package, $analyzer.version)
    Invoke-WebRequest -Uri $analyzer.url -OutFile $archive
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$analyzer.sha256) {
        throw "The analyzer package does not match its pinned SHA-256: $($analyzer.package) $($analyzer.version)"
    }
    $analyzerRoot = Join-Path $OutputDirectory 'package'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($archive, $analyzerRoot)

    $arguments = @(
        'msbuild', (Join-Path $root '.github\codeql\Analyzers.proj'), '-nologo', '-verbosity:minimal',
        "-property:ProductionSourceRoot=$($configuration.productionSourceRoot)",
        "-property:PowerShellHome=$PSHOME",
        "-property:RequiresSqlite=$($configuration.requiresSqlite.ToString().ToLowerInvariant())",
        "-property:AnalyzerRoot=$analyzerRoot",
        "-property:OutputDirectory=$OutputDirectory"
    )
    & dotnet @arguments *>&1 | Tee-Object -FilePath (Join-Path $OutputDirectory 'netanalyzers-build.log')
    if ($LASTEXITCODE) { throw "The analyzer compilation ended with exit code $LASTEXITCODE; the findings below are incomplete." }

    $sarifPath = Join-Path $OutputDirectory 'netanalyzers.sarif'
    $results = @()
    if (Test-Path -LiteralPath $sarifPath) {
        $sarif = Get-Content -LiteralPath $sarifPath -Raw | ConvertFrom-Json
        $results = @($sarif.runs | ForEach-Object { $_.results } | Where-Object { $_ -and $_.ruleId -match '^CA(2100|3\d{3}|5\d{3})$' })
    }
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("Informational: .NET security analyzers ($($analyzer.package) $($analyzer.version)), category Security, over $($configuration.productionSourceRoot).")
    if (-not $results.Count) { $lines.Add('No finding.') }
    foreach ($group in $results | Group-Object ruleId | Sort-Object Name) {
        $lines.Add(('{0}: {1} finding(s)' -f $group.Name, $group.Count))
        foreach ($result in $group.Group | Select-Object -First 10) {
            $location = $result.locations[0].physicalLocation
            $uri = [Uri]::UnescapeDataString([string]$location.artifactLocation.uri)
            $lines.Add(('  {0}:{1} {2}' -f $uri.Substring($uri.LastIndexOf('/') + 1), $location.region.startLine, $result.message.text))
        }
    }
    $lines | Set-Content -LiteralPath (Join-Path $OutputDirectory 'netanalyzers-summary.txt') -Encoding utf8
    $lines | ForEach-Object { Write-Output $_ }
    if ($env:GITHUB_STEP_SUMMARY) {
        (@('### .NET security analyzers (informational)', '', '```') + $lines + '```') | Out-File -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
    }
} catch {
    Write-Warning "The informational .NET security analysis did not complete: $($_.Exception.Message)"
}
$global:LASTEXITCODE = 0
exit 0
