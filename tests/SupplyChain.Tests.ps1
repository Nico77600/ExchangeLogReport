#Requires -Version 7.4
# Build and supply-chain controls: the SQLite assemblies and their upstream pins, the SBOM, the CI module pins and the informational
# .NET security analyzers. Nothing here uses the network or the owner's signing key.
BeforeAll {
    Set-StrictMode -Version Latest
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:Product = Get-Content -LiteralPath (Join-Path $script:Root 'product.json') -Raw | ConvertFrom-Json
    $script:SqliteTool = Join-Path $script:Root 'tools\Test-SqliteLibraries.ps1'
    $script:SbomTool = Join-Path $script:Root 'tools\New-Sbom.ps1'
    $script:BuilderText = [IO.File]::ReadAllText((Join-Path $script:Root 'tools\Build-Standalone.ps1'))
    $script:Codeql = Get-Content -LiteralPath (Join-Path $script:Root '.github\workflows\codeql.yml') -Raw | ConvertFrom-Json
    $script:Analyzers = Get-Content -LiteralPath (Join-Path $script:Root '.github\codeql\build.json') -Raw | ConvertFrom-Json
    $script:FixtureNumber = 0
    $script:StandInRuntime = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $script:Root 'package\lib\sqlite\Microsoft.Data.Sqlite.dll')).ProductVersion

    function New-SqliteFixture {
        $script:FixtureNumber++
        $path = Join-Path $TestDrive ('sqlite-fixture-{0}' -f $script:FixtureNumber)
        [void][IO.Directory]::CreateDirectory((Join-Path $path 'lib'))
        Copy-Item -LiteralPath (Join-Path $script:Root 'package\lib\sqlite') -Destination (Join-Path $path 'lib\sqlite') -Recurse
        $path
    }
    function New-SbomFixture {
        $script:FixtureNumber++
        $path = Join-Path $TestDrive ('sbom-fixture-{0}' -f $script:FixtureNumber)
        foreach ($folder in 'powershell', 'sqlite-tools', 'lib') { [void][IO.Directory]::CreateDirectory((Join-Path $path $folder)) }
        # The stand-in runtime library below carries the product version of Microsoft.Data.Sqlite.dll.
        [IO.File]::WriteAllText((Join-Path $path 'product.json'), ([IO.File]::ReadAllText((Join-Path $script:Root 'product.json')) -replace '"dotNetRuntimeVersion": "[^"]+"', ('"dotNetRuntimeVersion": "' + $script:StandInRuntime + '"')))
        [IO.File]::WriteAllText((Join-Path $path 'powershell\pwsh.exe'), 'synthetic executable placeholder')
        Copy-Item -LiteralPath (Join-Path $script:Root 'package\lib\sqlite\Microsoft.Data.Sqlite.dll') -Destination (Join-Path $path 'powershell\System.Private.CoreLib.dll')
        Copy-Item -LiteralPath (Join-Path $script:Root 'lib\sqlite-tools\sqlite3.exe') -Destination (Join-Path $path 'sqlite-tools\sqlite3.exe')
        Copy-Item -LiteralPath (Join-Path $script:Root 'package\lib\sqlite') -Destination (Join-Path $path 'lib\sqlite') -Recurse
        $files = [Collections.Generic.List[string]]::new()
        $distribution = [Collections.Generic.List[string]]::new()
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $path 'lib\sqlite') -Recurse -File) {
            $files.Add("        @{ Path = '$($file.FullName.Substring($path.Length + 1))'; Sha256 = '$((Get-FileHash -LiteralPath $file.FullName).Hash)' }")
        }
        foreach ($relative in 'powershell\pwsh.exe', 'powershell\System.Private.CoreLib.dll', 'sqlite-tools\sqlite3.exe') {
            $distribution.Add("        @{ Path = '$relative'; Sha256 = '$((Get-FileHash -LiteralPath (Join-Path $path $relative)).Hash)' }")
        }
        $manifest = @('@{', "    Version = '$($script:Product.version)'", '    Files = @(') + $files + @('    )', '    DistributionFiles = @(') + $distribution + @('    )', '}')
        [IO.File]::WriteAllText((Join-Path $path 'PackageIntegrity.psd1'), ($manifest -join "`r`n"))
        $zip = Join-Path $TestDrive ('sbom-fixture-{0}.zip' -f $script:FixtureNumber)
        [IO.File]::WriteAllText($zip, "synthetic zip $script:FixtureNumber")
        [pscustomobject]@{ Package = $path; Zip = $zip }
    }
}

Describe 'SQLite assemblies: declaration and upstream pins' {
    It 'pins every package by exact version, official nuget.org URL and lowercase SHA-256' {
        $packages = @($script:Product.sqliteLibraries.packages)
        $packages.Count | Should -Be 5
        foreach ($package in $packages) {
            $package.version | Should -Match '^\d+\.\d+\.\d+$'
            $package.url | Should -BeExactly ('https://www.nuget.org/api/v2/package/{0}/{1}' -f $package.id, $package.version)
            $package.packageSha256 | Should -Match '^[0-9a-f]{64}$'
            foreach ($file in $package.files) {
                $file.sha256 | Should -Match '^[0-9a-f]{64}$'
                $file.packagePath | Should -Not -BeNullOrEmpty
            }
        }
        @($packages.id) | Should -Be @('Microsoft.Data.Sqlite.Core', 'SQLitePCLRaw.core', 'SQLitePCLRaw.provider.e_sqlite3', 'SQLitePCLRaw.bundle_e_sqlite3', 'SQLitePCLRaw.lib.e_sqlite3')
    }

    It 'accepts the committed assemblies and pins every one of them' {
        $results = @(& $script:SqliteTool -PackageRoot (Join-Path $script:Root 'package'))
        $committed = @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'package\lib\sqlite') -Recurse -File)
        $results.Count | Should -Be $committed.Count
    }

    It 'refuses a modified, an unpinned and a missing file' {
        $modified = New-SqliteFixture
        $target = Join-Path $modified 'lib\sqlite\SQLitePCLRaw.core.dll'
        $bytes = [IO.File]::ReadAllBytes($target)
        $bytes[$bytes.Length - 1] = $bytes[$bytes.Length - 1] -bxor 0xFF
        [IO.File]::WriteAllBytes($target, $bytes)
        { & $script:SqliteTool -PackageRoot $modified } | Should -Throw '*does not match its upstream SHA-256 pin*'

        $extra = New-SqliteFixture
        [IO.File]::WriteAllText((Join-Path $extra 'lib\sqlite\extra.dll'), 'x')
        { & $script:SqliteTool -PackageRoot $extra } | Should -Throw '*Unpinned file*'

        $missing = New-SqliteFixture
        Remove-Item -LiteralPath (Join-Path $missing 'lib\sqlite\runtimes\win-arm64\e_sqlite3.dll')
        { & $script:SqliteTool -PackageRoot $missing } | Should -Throw '*is missing*'
    }

    It 'keeps the pin of sqlite3.exe held by the storage code and by the package verifier in step with product.json' {
        $audit = [IO.File]::ReadAllText((Join-Path $script:Root 'package\src\Storage.Audit.cs'))
        $audit | Should -Match ('private const string ToolSha256 = "{0}";' -f $script:Product.sqliteTools.executableSha256.ToUpperInvariant())
        $audit | Should -Match ('reviewed {0} executable' -f [regex]::Escape($script:Product.sqliteTools.version))
        $notice = [IO.File]::ReadAllText((Join-Path $script:Root 'lib\sqlite-tools\NOTICE.txt'))
        $notice | Should -Match ('SQLite command-line shell {0} ' -f [regex]::Escape($script:Product.sqliteTools.version))
        $notice | Should -Match $script:Product.sqliteTools.executableSha256
        (Get-FileHash -LiteralPath (Join-Path $script:Root 'lib\sqlite-tools\sqlite3.exe') -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $script:Product.sqliteTools.executableSha256
        $nativeVersion = @($script:Product.sqliteLibraries.packages | Where-Object { $_.PSObject.Properties['sqliteVersion'] })[0].sqliteVersion
        $notice | Should -Match ('e_sqlite3 library \({0}\)' -f [regex]::Escape($nativeVersion))
    }

    It 'never rewrites a pin' {
        $text = [IO.File]::ReadAllText($script:SqliteTool)
        $text | Should -Not -Match 'Set-Content|WriteAllText|Out-File'
    }

    It 'runs in every builder phase on the folder that phase handles' {
        $script:BuilderText | Should -Match 'Assert-SqliteLibraries \$Manifest'
        $script:BuilderText | Should -Match 'Assert-SqliteLibraries \$Seal'
        $script:BuilderText | Should -Match 'Assert-SqliteLibraries \$source'
        $script:BuilderText | Should -Match 'Assert-SqliteLibraries \$destination'
    }

    It 'declares the same packages and versions as the pins, as a NuGet declaration outside the package' {
        $declaration = Join-Path $script:Root 'lib\sqlite\packages.config'
        $xml = [xml][IO.File]::ReadAllText($declaration)
        $declared = @($xml.packages.package | ForEach-Object { '{0} {1}' -f $_.id, $_.version })
        $pinned = @($script:Product.sqliteLibraries.packages | ForEach-Object { '{0} {1}' -f $_.id, $_.version })
        $declared | Should -Be $pinned
        Test-Path -LiteralPath (Join-Path $script:Root 'package\lib\sqlite\packages.config') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:Root -Recurse -File -Include '*.csproj', '*.vbproj', '*.fsproj', 'Directory.Build.*', 'nuget.config' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notlike '*\artifacts\*' -and $_.FullName -notlike '*\.git\*' }).Count | Should -Be 0
    }

    It 'declares the versions that the committed assemblies carry' {
        $libraries = Join-Path $script:Root 'package\lib\sqlite'
        $version = { param($name) [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $libraries $name)).ProductVersion }
        foreach ($package in $script:Product.sqliteLibraries.packages) {
            foreach ($file in $package.files | Where-Object { $_.path -like '*.dll' -and $_.path -notlike 'runtimes/*' }) {
                (& $version $file.path) | Should -BeExactly $package.version -Because $file.path
            }
        }
    }
}

Describe 'SBOM generator' {
    BeforeAll {
        $script:Fixture = New-SbomFixture
        $script:SbomPath = & $script:SbomTool -PackageRoot $script:Fixture.Package -ZipPath $script:Fixture.Zip
        $script:Sbom = Get-Content -LiteralPath $script:SbomPath -Raw | ConvertFrom-Json
    }

    It 'writes the SBOM next to the ZIP, named as the ZIP plus .spdx.json, and returns that path' {
        $script:SbomPath | Should -BeExactly ($script:Fixture.Zip + '.spdx.json')
        Test-Path -LiteralPath $script:SbomPath | Should -BeTrue
    }

    It 'is a well-formed SPDX 2.3 document' {
        $script:Sbom.spdxVersion | Should -BeExactly 'SPDX-2.3'
        $script:Sbom.dataLicense | Should -BeExactly 'CC0-1.0'
        $script:Sbom.SPDXID | Should -BeExactly 'SPDXRef-DOCUMENT'
        $script:Sbom.documentNamespace | Should -Match '^https://[^#\s]+$'
        [IO.File]::ReadAllText($script:SbomPath) | Should -Match '"created": "\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"'
        @($script:Sbom.creationInfo.creators).Count | Should -BeGreaterThan 0
        $ids = @($script:Sbom.packages.SPDXID)
        @($ids | Select-Object -Unique).Count | Should -Be $ids.Count
        foreach ($package in $script:Sbom.packages) {
            $package.SPDXID | Should -Match '^SPDXRef-[A-Za-z0-9.\-]+$'
            $package.name | Should -Not -BeNullOrEmpty
            $package.downloadLocation | Should -Not -BeNullOrEmpty
            $package.filesAnalyzed | Should -BeFalse
        }
        foreach ($relationship in $script:Sbom.relationships) {
            ($ids + 'SPDXRef-DOCUMENT') | Should -Contain $relationship.spdxElementId
            $ids | Should -Contain $relationship.relatedSpdxElement
            $relationship.relationshipType | Should -BeIn @('DESCRIBES', 'CONTAINS')
        }
        @($script:Sbom.relationships | Where-Object relationshipType -EQ 'DESCRIBES').Count | Should -Be 1
    }

    It 'lists the package, PowerShell with its .NET runtime, the SQLite tools and the SQLite library packages with versions and SHA-256' {
        $byName = @{}
        foreach ($package in $script:Sbom.packages) { $byName[$package.name] = $package }
        foreach ($name in $script:Product.name, 'PowerShell', '.NET Runtime', 'SQLite command-line tools', 'SQLite (native library)') { $byName.Keys | Should -Contain $name }
        $byName['PowerShell'].versionInfo | Should -BeExactly $script:Product.powerShell.version
        $byName['PowerShell'].checksums[0].checksumValue | Should -BeExactly $script:Product.powerShell.sha256
        $byName['SQLite command-line tools'].versionInfo | Should -BeExactly $script:Product.sqliteTools.version
        $byName['SQLite (native library)'].versionInfo | Should -BeExactly (@($script:Product.sqliteLibraries.packages | Where-Object { $_.PSObject.Properties['sqliteVersion'] })[0].sqliteVersion)
        $byName['.NET Runtime'].versionInfo | Should -Match '^\d+\.\d+\.\d+$'
        $byName[$script:Product.name].checksums[0].checksumValue | Should -BeExactly (Get-FileHash -LiteralPath $script:Fixture.Zip).Hash.ToLowerInvariant()
        foreach ($package in $script:Product.sqliteLibraries.packages) {
            $byName[$package.id].versionInfo | Should -BeExactly $package.version
            $byName[$package.id].checksums[0].checksumValue | Should -BeExactly $package.packageSha256
            $byName[$package.id].externalRefs[0].referenceLocator | Should -BeExactly ('pkg:nuget/{0}@{1}' -f $package.id, $package.version)
        }
        foreach ($package in $script:Sbom.packages) {
            if ($package.PSObject.Properties['checksums']) { foreach ($checksum in @($package.checksums)) { $checksum.checksumValue | Should -Match '^[0-9a-f]{64}$' } }
        }
    }

    It 'refuses to overwrite and derives its namespace from the ZIP bytes' {
        { & $script:SbomTool -PackageRoot $script:Fixture.Package -ZipPath $script:Fixture.Zip } | Should -Throw '*never overwritten*'
        $other = New-SbomFixture
        $otherPath = & $script:SbomTool -PackageRoot $other.Package -ZipPath $other.Zip
        (Get-Content -LiteralPath $otherPath -Raw | ConvertFrom-Json).documentNamespace | Should -Not -BeExactly $script:Sbom.documentNamespace
    }

    It 'stops when a shipped file differs from the signed manifest or from its pin' {
        $tampered = New-SbomFixture
        [IO.File]::AppendAllText((Join-Path $tampered.Package 'sqlite-tools\sqlite3.exe'), 'x')
        { & $script:SbomTool -PackageRoot $tampered.Package -ZipPath $tampered.Zip } | Should -Throw '*does not match its pin*'

        $manifestMismatch = New-SbomFixture
        $manifestFile = Join-Path $manifestMismatch.Package 'PackageIntegrity.psd1'
        $manifestText = [IO.File]::ReadAllText($manifestFile)
        $first = [regex]::Match($manifestText, "Path = 'powershell\\pwsh\.exe'; Sha256 = '([0-9A-F]{64})'").Groups[1].Value
        [IO.File]::WriteAllText($manifestFile, $manifestText.Replace($first, ('0' * 64)))
        { & $script:SbomTool -PackageRoot $manifestMismatch.Package -ZipPath $manifestMismatch.Zip } | Should -Throw '*does not match the signed manifest*'

        $version = New-SbomFixture
        $versionFile = Join-Path $version.Package 'PackageIntegrity.psd1'
        [IO.File]::WriteAllText($versionFile, [IO.File]::ReadAllText($versionFile).Replace("Version = '$($script:Product.version)'", "Version = '0.0.0'"))
        { & $script:SbomTool -PackageRoot $version.Package -ZipPath $version.Zip } | Should -Throw '*manifest version*'
    }

    It 'stops when the runtime of the package is not the one product.json records' {
        $fixture = New-SbomFixture
        $productFile = Join-Path $fixture.Package 'product.json'
        [IO.File]::WriteAllText($productFile, ([IO.File]::ReadAllText($productFile) -replace '"dotNetRuntimeVersion": "[^"]+"', '"dotNetRuntimeVersion": "1.2.3"'))
        { & $script:SbomTool -PackageRoot $fixture.Package -ZipPath $fixture.Zip -Unsigned } | Should -Throw '*differs from powerShell.dotNetRuntimeVersion*'
    }

    It 'requires the signed manifest for a release build and not for a continuous-integration build' {
        $fixture = New-SbomFixture
        Remove-Item -LiteralPath (Join-Path $fixture.Package 'PackageIntegrity.psd1')
        { & $script:SbomTool -PackageRoot $fixture.Package -ZipPath $fixture.Zip } | Should -Throw '*manifest*missing*'
        $path = & $script:SbomTool -PackageRoot $fixture.Package -ZipPath $fixture.Zip -Unsigned
        $document = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $document.packages[0].downloadLocation | Should -BeExactly 'NOASSERTION'
    }

    It 'is written by the builder next to the sealed ZIP and next to the continuous-integration ZIP' {
        $script:BuilderText | Should -Match 'Compress-Archive -LiteralPath \$Seal -DestinationPath \$zip[^\r\n]*\r?\n\s*\$sbom = Write-Sbom \$Seal \$zip'
        $script:BuilderText | Should -Match 'Write-Sbom \$destination \$zip -UnsignedBuild'
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($script:SbomTool, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
        [IO.File]::ReadAllText($script:SbomTool) | Should -Match '\$OutputPath = "\$ZipPath\.spdx\.json"'
    }
}

Describe 'CI module pins' {
    BeforeAll {
        $script:InitializerText = [IO.File]::ReadAllText((Join-Path $script:Root '.github\scripts\Initialize-CIModules.ps1'))
        $ast = [Management.Automation.Language.Parser]::ParseInput($script:InitializerText, [ref]$null, [ref]$null)
        $script:InstallFunction = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Install-PinnedModule'
        }, $true).Extent.Text
        $script:ModuleTable = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$modules'
        }, $true).Extent.Text
    }

    It 'pins the exact version and the SHA-256 of Pester and PSScriptAnalyzer' {
        . ([scriptblock]::Create($script:ModuleTable))
        @($modules).Count | Should -Be 2
        $pester = $modules | Where-Object Name -EQ 'Pester'
        $analyzer = $modules | Where-Object Name -EQ 'PSScriptAnalyzer'
        $pester.Version | Should -BeExactly '6.1.0'
        $analyzer.Version | Should -BeExactly '1.25.0'
        $pester.PackageSha256 | Should -BeExactly '0207a75ea09f81b27c1ded44898b2bb3c845bafa02045bd64a39e26a53ca41b4'
        $analyzer.PackageSha256 | Should -BeExactly '14e634c828eb98efb9f40b2918ba90f139ed5eccdf663a2a747736d996995d60'
        $script:InitializerText | Should -Not -Match 'Save-Module|Install-Module|Install-PSResource|Save-PSResource'
    }

    It 'matches the hash before it extracts anything and fails on a mismatch' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        . ([scriptblock]::Create($script:InstallFunction))
        $work = Join-Path $TestDrive 'module-pin'
        $source = Join-Path $work 'source'
        [void][IO.Directory]::CreateDirectory((Join-Path $source '_rels'))
        [void][IO.Directory]::CreateDirectory((Join-Path $source 'package'))
        [IO.File]::WriteAllText((Join-Path $source '_rels\.rels'), 'rels')
        [IO.File]::WriteAllText((Join-Path $source '[Content_Types].xml'), 'types')
        [IO.File]::WriteAllText((Join-Path $source 'package\core.psmdcp'), 'core')
        [IO.File]::WriteAllText((Join-Path $source 'Synthetic.psd1'), "@{ ModuleVersion = '1.0.0' }")
        $package = Join-Path $work 'Synthetic.1.0.0.nupkg'
        [IO.Compression.ZipFile]::CreateFromDirectory($source, $package)
        $hash = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash.ToLowerInvariant()

        $refused = Join-Path $work 'refused'
        { Install-PinnedModule -Name Synthetic -Version 1.0.0 -PackageSha256 ('0' * 64) -Package $package -Destination $refused } |
            Should -Throw '*does not match its pinned SHA-256*'
        Test-Path -LiteralPath $refused | Should -BeFalse

        $accepted = Join-Path $work 'accepted'
        Install-PinnedModule -Name Synthetic -Version 1.0.0 -PackageSha256 $hash -Package $package -Destination $accepted
        Test-Path -LiteralPath (Join-Path $accepted 'Synthetic\1.0.0\Synthetic.psd1') | Should -BeTrue
        foreach ($removed in '_rels', 'package', '[Content_Types].xml') {
            Test-Path -LiteralPath (Join-Path $accepted "Synthetic\1.0.0\$removed") | Should -BeFalse
        }
    }

    It 'keeps the module layout that the CI runner imports' {
        $runner = [IO.File]::ReadAllText((Join-Path $script:Root '.github\scripts\Invoke-CITests.ps1'))
        $runner | Should -Match 'Pester\\6\.1\.0\\Pester\.psd1'
        $script:InitializerText | Should -Match "'\{0\}\\\{1\}' -f \`$Name, \`$Version"
    }
}

Describe 'Informational .NET security analyzers' {
    It 'pins the analyzer package by exact version, official URL and SHA-256' {
        $analyzer = $script:Analyzers.netAnalyzers
        $analyzer.package | Should -BeExactly 'Microsoft.CodeAnalysis.NetAnalyzers'
        $analyzer.version | Should -Match '^\d+\.\d+\.\d+$'
        $analyzer.url | Should -BeExactly ('https://www.nuget.org/api/v2/package/{0}/{1}' -f $analyzer.package, $analyzer.version)
        $analyzer.sha256 | Should -Match '^[0-9a-f]{64}$'
    }

    It 'runs before CodeQL starts tracing, only for C#, and can never fail the job' {
        $steps = @($script:Codeql.jobs.analyze.steps)
        $names = @($steps.name)
        $step = $steps | Where-Object name -Like 'Run .NET security analyzers*'
        @($step).Count | Should -Be 1
        $step.'continue-on-error' | Should -BeTrue
        $step.if | Should -Match "matrix.language == 'csharp'"
        $step.run | Should -Match 'Invoke-NetAnalyzers\.ps1'
        [array]::IndexOf($names, $step.name) | Should -BeLessThan ([array]::IndexOf($names, 'Initialize language-specific analysis'))
        $upload = $steps | Where-Object { $_.PSObject.Properties['uses'] -and $_.uses -like 'actions/upload-artifact@*' }
        $upload.with.path | Should -Match 'netanalyzers/netanalyzers\.sarif'
    }

    It 'enables only the Security category as warnings, outside the production compilation' {
        $config = [IO.File]::ReadAllText((Join-Path $script:Root '.github\codeql\security-analyzers.globalconfig'))
        $config | Should -Match '(?m)^is_global = true'
        $config | Should -Match '(?m)^dotnet_analyzer_diagnostic\.severity = none'
        $config | Should -Match '(?m)^dotnet_analyzer_diagnostic\.category-Security\.severity = warning'
        $project = [IO.File]::ReadAllText((Join-Path $script:Root '.github\codeql\Analyzers.proj'))
        $project | Should -Match 'TreatWarningsAsErrors="false"'
        $project | Should -Not -Match 'PackageReference|Restore|Sdk='
        [IO.File]::ReadAllText((Join-Path $script:Root '.github\codeql\Production.proj')) | Should -Not -Match 'Analyzer'
    }

    It 'reports and exits 0 even when it cannot complete' {
        $existing = Join-Path $TestDrive 'existing-analysis-output'
        [void][IO.Directory]::CreateDirectory($existing)
        $script = Join-Path $script:Root '.github\scripts\Invoke-NetAnalyzers.ps1'
        $output = & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -File $script -OutputDirectory $existing 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $output | Should -Match 'did not complete'
        $text = [IO.File]::ReadAllText($script)
        $text | Should -Match '(?m)^exit 0\s*$'
    }

    It 'refuses an output folder inside the runtime package, without failing' {
        $script = Join-Path $script:Root '.github\scripts\Invoke-NetAnalyzers.ps1'
        $inside = Join-Path $script:Root 'package\netanalyzers-should-not-exist'
        $output = & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -File $script -OutputDirectory $inside 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $output | Should -Match 'must not enter the runtime package'
        Test-Path -LiteralPath $inside | Should -BeFalse
    }
}

Describe 'Release ZIP comparison with the tagged source' {
    BeforeAll {
        $script:Python = (Get-Command python -ErrorAction Stop).Source
        $script:Comparer = Join-Path $script:Root '.github\scripts\compare_release_source.py'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $utf8 = [Text.UTF8Encoding]::new($false)
        $signedNames = 'Invoke-ExchangeLogReport.ps1', 'Database-Storage.ps1', 'ExchangeLogReport.psm1', 'ExchangeLogReport.psd1', 'src/Test-PackageIntegrity.ps1',
            'src/Get-ExlExchangeSettings.ps1', 'PackageIntegrity.psd1'
        $script:SignedNames = $signedNames
        function Write-Bytes([string]$Path, [byte[]]$Bytes) {
            [void][IO.Directory]::CreateDirectory((Split-Path $Path -Parent))
            [IO.File]::WriteAllBytes($Path, $Bytes)
        }
        function Write-Text([string]$Path, [string]$Text) { Write-Bytes $Path $utf8.GetBytes($Text) }
        function Get-Sha([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
        function Invoke-Git([string]$Repository, [string[]]$Arguments) {
            $output = & git -C $Repository -c core.autocrlf=false -c user.name=fixture -c user.email=fixture@example.invalid @Arguments 2>&1
            if ($LASTEXITCODE) { throw "git $($Arguments -join ' ') failed: $output" }
        }
        function ConvertTo-Crlf([string]$Path) { Write-Text $Path (([IO.File]::ReadAllText($Path) -replace "`r`n", "`n") -replace "`n", "`r`n") }

        $work = Join-Path $TestDrive 'release-comparison'
        $script:Work = $work
        $source = Join-Path $work 'source'
        $script:Source = $source
        [void][IO.Directory]::CreateDirectory($source)

        $archiveFolder = Join-Path $work 'powershell-archive-source'
        Write-Text (Join-Path $archiveFolder 'pwsh.exe') 'synthetic pwsh'
        Write-Text (Join-Path $archiveFolder 'System.Private.CoreLib.dll') 'synthetic runtime'
        Write-Text (Join-Path $archiveFolder 'pwsh.pdb') 'symbols removed by the builder'
        Write-Text (Join-Path $archiveFolder 'Modules\Sample\Sample.psd1') '@{ ModuleVersion = ''1.0'' }'
        $script:PowerShellArchive = Join-Path $work 'PowerShell.zip'
        [IO.Compression.ZipFile]::CreateFromDirectory($archiveFolder, $script:PowerShellArchive)

        $script:DllBytes = [byte[]](0x4D, 0x5A, 0x00, 0x01, 0x0A, 0x02)
        Write-Bytes (Join-Path $source 'package\lib\sqlite\Pinned.dll') $script:DllBytes
        Write-Text (Join-Path $source 'lib\sqlite-tools\sqlite3.exe') 'synthetic sqlite tool'
        Write-Text (Join-Path $source 'lib\sqlite-tools\NOTICE.txt') "notice`nsecond line`n"
        $product = [ordered]@{
            name = 'ExchangeLogReport'; version = '9.9.9'
            sqliteTools = @{ executableSha256 = Get-Sha (Join-Path $source 'lib\sqlite-tools\sqlite3.exe') }
            sqliteLibraries = @{ packages = @(@{ files = @(@{ path = 'Pinned.dll'; sha256 = Get-Sha (Join-Path $source 'package\lib\sqlite\Pinned.dll') }) }) }
            powerShell = @{ url = 'https://invalid.example/PowerShell.zip'; sha256 = Get-Sha $script:PowerShellArchive }
        }
        Write-Text (Join-Path $source 'product.json') ((ConvertTo-Json $product -Depth 6) + "`n")
        foreach ($name in 'LICENSE', 'SECURITY.md', 'CHANGELOG.md') { Write-Text (Join-Path $source $name) "$name text`nsecond line`n" }
        foreach ($name in $signedNames) {
            Write-Text (Join-Path $source ('package\' + $name.Replace('/', '\'))) "# $name`r`nbody`r`n`r`n# SIG # Begin signature block`r`n# c2lnbmF0dXJlQQ==`r`n# SIG # End signature block`r`n"
        }
        Write-Text (Join-Path $source 'package\src\Engine.A.cs') "class A { }`n"
        Write-Text (Join-Path $source 'package\config\ExchangeLogReport.config.psd1') "@{ A = 1 }`n"
        Write-Text (Join-Path $source 'package\templates\Report.template.html') "<html>`n</html>`n"
        Write-Text (Join-Path $source 'package\docs\Guide.html') "<p>guide</p>`n"
        Write-Text (Join-Path $source 'package\docs\Guide.md') "guide source`n"
        Write-Text (Join-Path $source 'package\docs\images\shot.png') 'image'
        Write-Text (Join-Path $source '.gitattributes') "package/src/Engine.*.cs -text`n"
        & git init --quiet $source
        Invoke-Git $source @('config', 'core.autocrlf', 'false')
        Invoke-Git $source @('add', '--all')
        Invoke-Git $source @('commit', '--quiet', '-m', 'release')
        Invoke-Git $source @('tag', 'v9.9.9')

        # What the builder packs: the working tree of a machine whose core.autocrlf turns lone LF into CRLF, minus the builder exclusions.
        $package = Join-Path $work 'package-template\ExchangeLogReport-9.9.9-win-x64'
        $script:PackageTemplate = $package
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $source 'package') -Recurse -File) {
            $relative = $file.FullName.Substring((Join-Path $source 'package').Length + 1)
            if ($relative -like 'docs\*.md' -or $relative -like 'docs\images\*') { continue }
            $target = Join-Path $package $relative
            [void][IO.Directory]::CreateDirectory((Split-Path $target -Parent))
            Copy-Item -LiteralPath $file.FullName -Destination $target
        }
        foreach ($name in 'config\ExchangeLogReport.config.psd1', 'templates\Report.template.html', 'docs\Guide.html') { ConvertTo-Crlf (Join-Path $package $name) }
        foreach ($name in 'product.json', 'LICENSE', 'SECURITY.md', 'CHANGELOG.md') {
            Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $package $name)
            ConvertTo-Crlf (Join-Path $package $name)
        }
        Write-Bytes (Join-Path $package 'sqlite-tools\sqlite3.exe') ([IO.File]::ReadAllBytes((Join-Path $source 'lib\sqlite-tools\sqlite3.exe')))
        Write-Text (Join-Path $package 'sqlite-tools\NOTICE.txt') "notice`r`nsecond line`r`n"
        [IO.Compression.ZipFile]::ExtractToDirectory($script:PowerShellArchive, (Join-Path $package 'powershell'))
        Remove-Item -LiteralPath (Join-Path $package 'powershell\pwsh.pdb')

        function New-ReleaseZip {
            param([scriptblock]$Mutate)
            $script:FixtureNumber++
            $copy = Join-Path $script:Work ('copy-{0}' -f $script:FixtureNumber)
            Copy-Item -LiteralPath (Split-Path $script:PackageTemplate -Parent) -Destination $copy -Recurse
            $folder = Join-Path $copy 'ExchangeLogReport-9.9.9-win-x64'
            if ($Mutate) { & $Mutate $folder }
            $zip = Join-Path $script:Work ('release-{0}.zip' -f $script:FixtureNumber)
            [IO.Compression.ZipFile]::CreateFromDirectory($folder, $zip, [IO.Compression.CompressionLevel]::Optimal, $true)
            $zip
        }
        function Invoke-Comparison([string]$Zip, [string]$SourcePath = $script:Source) {
            $output = & $script:Python $script:Comparer --zip $Zip --source $SourcePath --tag v9.9.9 --powershell-archive $script:PowerShellArchive 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
        }
    }

    It 'accepts the exact tagged source and pinned binaries, with the builder line-ending conversion' {
        $result = Invoke-Comparison (New-ReleaseZip)
        $result.ExitCode | Should -Be 0 -Because $result.Output
        $report = ($result.Output -split "`r?`n" | Where-Object { $_ -like '{*' } | Select-Object -First 1) | ConvertFrom-Json
        $report.line_ending_conversions | Should -BeGreaterThan 0
        $report.from_powershell_archive | Should -Be 3
        $result.Output | Should -Not -Match 'FAILED'
    }

    It 'refuses a modified file of the repository' {
        $zip = New-ReleaseZip { param($folder) Add-Content -LiteralPath (Join-Path $folder 'templates\Report.template.html') -Value '<script>evil()</script>' }
        $result = Invoke-Comparison $zip
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'File differs from the tag: templates/Report.template.html'
    }

    It 'refuses a file that is in neither the tag nor the pins' {
        foreach ($mutation in @(
                { param($folder) Write-Text (Join-Path $folder 'extra.txt') 'x' },
                { param($folder) Write-Text (Join-Path $folder 'powershell\evil.dll') 'x' },
                { param($folder) Write-Text (Join-Path $folder 'docs\Guide.md') 'guide source' },
                { param($folder) Write-Text (Join-Path $folder 'lib\sqlite\Unpinned.dll') 'x' },
                { param($folder) Write-Text (Join-Path $folder 'powershell\pwsh.pdb') 'symbols' })) {
            $result = Invoke-Comparison (New-ReleaseZip $mutation)
            $result.ExitCode | Should -Not -Be 0
            $result.Output | Should -Match 'in neither the tag nor the pins'
        }
    }

    It 'refuses a missing file' {
        $result = Invoke-Comparison (New-ReleaseZip { param($folder) Remove-Item -LiteralPath (Join-Path $folder 'docs\Guide.html') })
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'missing from the ZIP: docs/Guide.html'
    }

    It 'refuses a modified third-party binary' {
        foreach ($case in @(
                @{ Path = 'powershell\pwsh.exe'; Expected = 'powershell/pwsh.exe' },
                @{ Path = 'sqlite-tools\sqlite3.exe'; Expected = 'sqlite-tools/sqlite3.exe' },
                @{ Path = 'lib\sqlite\Pinned.dll'; Expected = 'lib/sqlite/Pinned.dll' })) {
            $script:Relative = $case.Path
            $result = Invoke-Comparison (New-ReleaseZip { param($folder) [IO.File]::AppendAllText((Join-Path $folder $script:Relative), 'tampered') })
            $result.ExitCode | Should -Not -Be 0
            $result.Output | Should -Match ('differs from its pin: ' + [regex]::Escape($case.Expected))
        }
    }

    It 'treats a file that must keep its bytes as exact, however its line endings look' {
        $result = Invoke-Comparison (New-ReleaseZip { param($folder) ConvertTo-Crlf (Join-Path $folder 'src\Engine.A.cs') })
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'File differs from the tag: src/Engine.A.cs'
    }

    It 'allows only the Authenticode signature block to differ in a signed file and in the manifest' {
        foreach ($name in $script:SignedNames) {
            $relative = $name.Replace('/', '\')
            $script:Relative = $relative
            $resigned = New-ReleaseZip { param($folder)
                $path = Join-Path $folder $script:Relative
                Write-Text $path (([IO.File]::ReadAllText($path)).Replace('# c2lnbmF0dXJlQQ==', '# c2lnbmF0dXJlQg=='))
            }
            $result = Invoke-Comparison $resigned
            $result.ExitCode | Should -Be 0 -Because "$name $($result.Output)"
            $result.Output | Should -Match ([regex]::Escape($name))

            $tampered = New-ReleaseZip { param($folder)
                $path = Join-Path $folder $script:Relative
                Write-Text $path (([IO.File]::ReadAllText($path)).Replace('body', 'body; Invoke-Evil'))
            }
            $result = Invoke-Comparison $tampered
            $result.ExitCode | Should -Not -Be 0
            $result.Output | Should -Match 'before the signature block differs'
        }
        $unsigned = New-ReleaseZip { param($folder) Write-Text (Join-Path $folder 'Database-Storage.ps1') "# Database-Storage.ps1`r`nbody`r`n" }
        $result = Invoke-Comparison $unsigned
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'carries no Authenticode signature block'
    }

    It 'accepts only a well-formed signature block: nothing after it, nothing but signature data inside it, and on its own line' {
        $path = 'Invoke-ExchangeLogReport.ps1'
        $cases = @(
            @{ Mutate = { param($text) $text + "Invoke-Evil`r`n" }; Expected = 'text after the signature block' },
            @{ Mutate = { param($text) $text.Replace('# c2lnbmF0dXJlQQ==', '# not base64 data!') }; Expected = 'not signature data' },
            @{ Mutate = { param($text) $text.Replace("# SIG # End signature block`r`n", '') }; Expected = 'not terminated' },
            @{ Mutate = { param($text) $text.Replace("`r`n`r`n# SIG # Begin signature block", '; x # SIG # Begin signature block') }; Expected = 'does not start on its own line' })
        foreach ($case in $cases) {
            $script:Case = $case
            $zip = New-ReleaseZip { param($folder)
                $file = Join-Path $folder 'Invoke-ExchangeLogReport.ps1'
                Write-Text $file (& $script:Case.Mutate ([IO.File]::ReadAllText($file)))
            }
            $result = Invoke-Comparison $zip
            $result.ExitCode | Should -Not -Be 0 -Because $case.Expected
            $result.Output | Should -Match ([regex]::Escape($case.Expected))
        }
    }

    It 'refuses a source folder that is not the exact tag' {
        $moved = Join-Path $script:Work 'moved-source'
        & git clone --quiet $script:Source $moved 2>&1 | Out-Null
        Write-Text (Join-Path $moved 'SECURITY.md') "changed`n"
        Invoke-Git $moved @('add', '--all')
        Invoke-Git $moved @('commit', '--quiet', '-m', 'after the tag')
        & git -C $moved fetch --quiet --tags 2>&1 | Out-Null
        $result = Invoke-Comparison (New-ReleaseZip) $moved
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'not the exact tag'
    }

    It 'keeps the builder rules it mirrors in step with Build-Standalone.ps1' {
        $text = [IO.File]::ReadAllText($script:Comparer)
        $folders = [regex]::Match($text, 'BUILDER_EXCLUDED_TOP_FOLDERS = \(([^)]*)\)').Groups[1].Value
        $builderFolders = [regex]::Match($script:BuilderText, "-not \(\`$top -cin @\(([^)]*)\)\)").Groups[1].Value
        (($folders -split ',' | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ }) -join ',') |
            Should -BeExactly (($builderFolders -split ',' | ForEach-Object { $_.Trim().Trim("'") } | Where-Object { $_ }) -join ',')
        foreach ($name in 'product.json', 'LICENSE', 'SECURITY.md', 'CHANGELOG.md') { $text | Should -Match ('"' + [regex]::Escape($name) + '"') }
        $script:BuilderText | Should -Match "-clike 'docs\\\*\.md'"
        $script:BuilderText | Should -Match "-clike 'docs\\images\\\*'"
        $script:BuilderText | Should -Match "'lib\\sqlite-tools\\NOTICE\.txt'"
        $signed = [regex]::Match($script:BuilderText, '\$signedScripts = @\(([^)]*)\)').Groups[1].Value
        foreach ($name in $script:SignedNames | Where-Object { $_ -ne 'PackageIntegrity.psd1' }) { $signed | Should -Match ([regex]::Escape($name.Replace('/', '\'))) }
    }
}

Describe 'Attestation workflow: source comparison and SBOM' {
    BeforeAll {
        $script:Attest = [IO.File]::ReadAllText((Join-Path $script:Root '.github\workflows\attest-release.yml')) -replace "`r`n", "`n"
        $split = $script:Attest.IndexOf("`n  attest:`n")
        $script:CompareJob = $script:Attest.Substring(0, $split)
        $script:AttestJob = $script:Attest.Substring($split)
    }

    It 'compares the ZIPs with the tag in a separate read-only job with no secret, no token right and no build' {
        $script:CompareJob | Should -Match '(?m)^  compare:$'
        $script:CompareJob | Should -Match '(?ms)^    permissions:\n      contents: read\n    outputs:'
        $script:CompareJob | Should -Not -Match 'id-token|attestations:|actions/attest|contents: write|secrets\.|npm|dotnet'
        $script:CompareJob | Should -Match 'compare_release_source\.py'
        $script:CompareJob | Should -Match '--tag "\$RELEASE_TAG"'
        $script:CompareJob | Should -Match 'git -C tagged-source rev-parse HEAD'
        @([regex]::Matches($script:CompareJob, 'uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262')).Count | Should -Be 2
        @([regex]::Matches($script:CompareJob, 'persist-credentials: false')).Count | Should -Be 2
        $script:CompareJob | Should -Match 'ref: \$\{\{ github\.sha \}\}'
        $script:CompareJob | Should -Match 'sparse-checkout: \.github/scripts/compare_release_source\.py'
        $script:CompareJob | Should -Match 'ref: refs/tags/\$\{\{ github\.event\.release\.tag_name \|\| inputs\.tag \}\}'
        $script:CompareJob | Should -Not -Match 'curl|raw\.githubusercontent'
        $script:CompareJob | Should -Match 'time\.sleep\(5 \* 2 \*\* attempt\)'
    }

    It 'lets the attest job run only after the comparison, with nothing of the repository run in it, and re-checks what was compared' {
        $script:AttestJob | Should -Match '(?m)^    needs: compare$'
        $script:AttestJob | Should -Match '(?m)^      id-token: write$'
        $script:AttestJob | Should -Not -Match 'uses: actions/checkout|compare_release_source|workflow-source|tagged-source|sparse-checkout|actions/download-artifact'
        $script:AttestJob | Should -Match 'COMPARED_COMMIT: \$\{\{ needs\.compare\.outputs\.commit \}\}'
        $script:AttestJob | Should -Match 'COMPARED_ZIPS: \$\{\{ needs\.compare\.outputs\.zips \}\}'
        $script:AttestJob | Should -Match 'The commit of the release tag is not the commit that was compared with the ZIPs'
        $script:AttestJob | Should -Match 'The ZIP bytes to attest are not the bytes that were compared with the tagged source'
        $compared = $script:AttestJob.IndexOf('is not the commit that was compared')
        $zipAttestation = $script:AttestJob.IndexOf('name: Generate attestation for the verified distributed ZIP bytes')
        $compared | Should -BeGreaterThan -1
        $compared | Should -BeLessThan $zipAttestation
        $script:AttestJob.IndexOf('name: Generate attestation for the verified distributed ZIP bytes') | Should -BeLessThan $script:AttestJob.IndexOf('name: Generate attestation for the verified SPDX SBOM')
    }

    It 'says in the run summary that a failed release is published and not attested, and what to do' {
        foreach ($job in $script:CompareJob, $script:AttestJob) {
            $job | Should -Match "if: \$\{\{ failure\(\) \}\}"
            $job | Should -Match 'published but NOT attested'
            $job | Should -Match 'run it manually from the default branch with the exact tag'
            $job | Should -Match 'treat the release as suspect'
        }
        $agents = [IO.File]::ReadAllText((Join-Path $script:Root 'AGENTS.md'))
        $agents | Should -Match 'separate read-only job'
        $agents | Should -Match 'published but not attested'
    }

    It 'attests the SBOM asset as its own subject only when the release carries one' {
        $script:Attest | Should -Match "if: \$\{\{ steps\.verify\.outputs\.sbom_count != '0' \}\}"
        $script:Attest | Should -Match "subject-path: 'dist-sbom/\*\.spdx\.json'"
        $script:Attest | Should -Match 'sbom_count='
        $script:Attest | Should -Match '"SPDX-2\.3"'
        $script:Attest | Should -Not -Match '(?i)cyclonedx'
        $script:Attest | Should -Match 'An SBOM asset has no matching ZIP asset'
        $script:Attest | Should -Match 'The SBOM does not describe the ZIP bytes and version of this release'
    }

    It 'keeps the comparer a stdlib-only script that builds and executes nothing from the tag' {
        $text = [IO.File]::ReadAllText((Join-Path $script:Root '.github\scripts\compare_release_source.py'))
        $text | Should -Not -Match 'import (requests|yaml)|os\.system|shell=True|exec\(|eval\('
    }
}
