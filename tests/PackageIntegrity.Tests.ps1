#Requires -Version 7.4
# Package integrity: signatures (tagged RealSignature), SHA256 inventory, filesystem guards and the compiled-cache policy.
# Before signing, a private fixture substitutes the signature check (see the release preparation) and excludes the
# RealSignature tag; every other case runs unchanged. The CI of the signed source runs all cases with no substitution.
BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:Source = Join-Path $script:RepoRoot 'package'
    $script:Changelog = Join-Path $script:RepoRoot 'CHANGELOG.md'
    $script:FixtureNumber = 0
    $script:Fixture = $null
    $script:Pwsh = Join-Path $PSHOME 'pwsh.exe'
    function Reset-Fixture {
        Remove-Module ExchangeLogReport -Force -ErrorAction SilentlyContinue
        # Do not delete a just-copied tree while Windows still holds source-document image handles.
        $script:FixtureNumber++
        $script:Fixture = Join-Path $TestDrive ('runtime-{0:D4}' -f $script:FixtureNumber)
        if (Test-Path -LiteralPath $script:Fixture) { throw "Unexpected existing test fixture: $script:Fixture" }
        Copy-Item -LiteralPath $script:Source -Destination $script:Fixture -Recurse
        # A developer checkout may hold generated folders; the cases below start without them.
        foreach ($folder in 'bin', 'data', 'logs', 'reports') {
            Remove-Item -LiteralPath (Join-Path $script:Fixture $folder) -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    function Add-FixtureChangelog { Copy-Item -LiteralPath $script:Changelog -Destination (Join-Path $script:Fixture 'CHANGELOG.md') }
    function Invoke-Guard {
        param([switch]$Distribution)
        $verifier = Join-Path $script:Fixture 'src\Test-PackageIntegrity.ps1'
        if ($Distribution) { & $verifier -Root $script:Fixture -Distribution } else { & $verifier -Root $script:Fixture }
    }
    function Invoke-Child([string]$Command) {
        $output = & $script:Pwsh -NoProfile -NonInteractive -Command $Command 2>&1 | ForEach-Object { "$_" }
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = ($output -join "`n") }
    }
    function Edit-Protected([string]$Path) {
        if ([IO.Path]::GetExtension($Path) -in '.ps1', '.psm1', '.psd1') {
            [IO.File]::WriteAllText($Path, "# Evidence-only tamper`r`n" + [IO.File]::ReadAllText($Path), [Text.UTF8Encoding]::new($true))
        } else { [IO.File]::AppendAllText($Path, "`r`n# Evidence-only tamper") }
    }
    # Same as the main tests: the engine is loaded once per process from the real package; the fixtures only verify.
    Import-Module (Join-Path $script:Source 'ExchangeLogReport.psd1') -Force
    Initialize-ExlEngine -Root $script:Source
    $script:Entries = @((Import-PowerShellDataFile (Join-Path $script:Source 'PackageIntegrity.psd1')).Files)
}
Describe 'Authenticated source and distribution integrity' {
    BeforeEach { Reset-Fixture }
    It 'accepts the real source, a relocated byte-identical copy and a distribution with the changelog' {
        { & (Join-Path $script:Source 'src\Test-PackageIntegrity.ps1') -Root $script:Source } | Should -Not -Throw
        { Invoke-Guard } | Should -Not -Throw
        $script:Entries.Count | Should -Be 29
        { Invoke-Guard -Distribution } | Should -Throw
        Add-FixtureChangelog
        { Invoke-Guard -Distribution } | Should -Not -Throw
    }
    It 'inventories every distributed file except the editable configuration' {
        $required = @('Invoke-ExchangeLogReport.ps1', 'ExchangeLogReport.psm1', 'ExchangeLogReport.psd1', 'src\Test-PackageIntegrity.ps1', 'README.md', 'THIRD-PARTY-NOTICES.md',
            'templates\Report.template.html', 'docs\ExchangeLogReport-Guide.html', 'docs\ExchangeLogReport-UserGuide.html', 'src\Get-ExlExchangeSettings.ps1', 'CHANGELOG.md')
        foreach ($path in $required) { $script:Entries.Path | Should -Contain $path }
        $sources = @(Get-ChildItem (Join-Path $script:Source 'src') -Filter '*.cs' -File -Recurse)
        $libraries = @(Get-ChildItem (Join-Path $script:Source 'lib\sqlite') -Filter '*.dll' -File -Recurse)
        $sources.Count | Should -Be 12
        $libraries.Count | Should -Be 6
        @($script:Entries.Path | Where-Object { $_ -like 'src\*.cs' }).Count | Should -Be $sources.Count
        @($script:Entries.Path | Where-Object { $_ -like 'lib\sqlite\*.dll' }).Count | Should -Be $libraries.Count
        foreach ($file in @($sources) + @($libraries)) {
            $script:Entries.Path | Should -Contain ([IO.Path]::GetRelativePath($script:Source, $file.FullName))
        }
        @($script:Entries.Path | Select-Object -Unique).Count | Should -Be 29
        $script:Entries.Path | Should -Not -Contain 'config\ExchangeLogReport.config.psd1'
        $script:Entries.Path | Should -Not -Contain 'PackageIntegrity.psd1'
    }
    It 'keeps the verifier only in src and authenticates the package parent rather than src' {
        Test-Path -LiteralPath (Join-Path $script:Source 'Test-PackageIntegrity.ps1') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Fixture 'Test-PackageIntegrity.ps1') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Fixture 'src\Test-PackageIntegrity.ps1') | Should -BeTrue
        @($script:Entries | Where-Object Path -ceq 'src\Test-PackageIntegrity.ps1').Count | Should -Be 1
        $script:Entries.Path | Should -Not -Contain 'Test-PackageIntegrity.ps1'
        { Invoke-Guard } | Should -Not -Throw
        { & (Join-Path $script:Fixture 'src\Test-PackageIntegrity.ps1') -Root (Join-Path $script:Fixture 'src') } |
            Should -Throw -ExpectedMessage '*verifier must belong to this package root*'
    }
    It 'rejects a second verifier at the obsolete root path' {
        Copy-Item -LiteralPath (Join-Path $script:Fixture 'src\Test-PackageIntegrity.ps1') -Destination (Join-Path $script:Fixture 'Test-PackageIntegrity.ps1')
        { Invoke-Guard } | Should -Throw -ExpectedMessage '*unexpected stable file: Test-PackageIntegrity.ps1*'
        { Import-Module (Join-Path $script:Fixture 'ExchangeLogReport.psd1') -Force -ErrorAction Stop } | Should -Throw
    }
    It 'refuses execution of a verifier copied outside the authenticated src location' {
        $outside = Join-Path $TestDrive 'copied-verifier.ps1'
        Copy-Item -LiteralPath (Join-Path $script:Fixture 'src\Test-PackageIntegrity.ps1') -Destination $outside
        { & $outside -Root $script:Fixture } | Should -Throw -ExpectedMessage '*verifier must belong to this package root*'
    }
    It 'requires valid timestamped owner signatures on all five PowerShell files and the manifest' -Tag 'RealSignature' {
        foreach ($name in 'Invoke-ExchangeLogReport.ps1', 'ExchangeLogReport.psm1', 'ExchangeLogReport.psd1', 'src\Test-PackageIntegrity.ps1', 'src\Get-ExlExchangeSettings.ps1', 'PackageIntegrity.psd1') {
            $signature = Get-AuthenticodeSignature -LiteralPath (Join-Path $script:Fixture $name)
            [string]$signature.Status | Should -Be 'Valid'
            $signature.SignerCertificate.Thumbprint | Should -BeExactly '0F28E442889F17B5F4D251E8F96E7CC6E2C9C6D6'
            $signature.TimeStamperCertificate | Should -Not -BeNullOrEmpty
        }
    }
    It 'accepts editable configuration and generated folders, and never loads a compiled cache from bin' {
        Add-Content (Join-Path $script:Fixture 'config\ExchangeLogReport.config.psd1') '# Fictitious customization'
        Set-Content (Join-Path $script:Fixture 'config\ExchangeLogReport.paths.psd1') '@{}'
        Set-Content (Join-Path $script:Fixture 'config\ExchangeLogReport.mail.credential') '{}'
        foreach ($folder in 'bin', 'data', 'logs', 'reports') {
            [void][IO.Directory]::CreateDirectory((Join-Path $script:Fixture $folder))
            Set-Content (Join-Path $script:Fixture "$folder\generated.txt") 'generated'
        }
        { Invoke-Guard } | Should -Not -Throw
        $cache = Join-Path $script:Fixture 'bin\ExchangeLogReport.Engine.0123456789ABCDEF.dll'
        Set-Content $cache 'not an assembly'
        $before = (Get-FileHash $cache).Hash
        $run = Invoke-Child ("Import-Module '$(Join-Path $script:Fixture 'ExchangeLogReport.psd1')' -Force; Initialize-ExlEngine -Root '$script:Fixture'; " +
            "'LOCATION=[' + ('ExchangeLogReport.Store' -as [type]).Assembly.Location + ']'")
        $run.ExitCode | Should -Be 0
        $run.Text | Should -Match 'LOCATION=\[\]'
        (Get-FileHash $cache).Hash | Should -Be $before
    }
    It 'does not execute a valid but tampered compiled assembly planted in bin under the old cache name' {
        [void][IO.Directory]::CreateDirectory((Join-Path $script:Fixture 'bin'))
        $planted = Join-Path $script:Fixture 'bin\ExchangeLogReport.Engine.0123456789ABCDEF.dll'
        $build = Invoke-Child ("Add-Type -OutputAssembly '$planted' -OutputType Library -TypeDefinition 'namespace ExchangeLogReport { public class Store { public static string Marker = ""UNTRUSTED""; } }'")
        $build.ExitCode | Should -Be 0
        Test-Path -LiteralPath $planted | Should -BeTrue
        $before = (Get-FileHash $planted).Hash
        $run = Invoke-Child ("Import-Module '$(Join-Path $script:Fixture 'ExchangeLogReport.psd1')' -Force; Initialize-ExlEngine -Root '$script:Fixture'; " +
            "'MARKER=' + [bool][ExchangeLogReport.Store].GetField('Marker'); 'LOCATION=[' + ([ExchangeLogReport.Store].Assembly.Location) + ']'")
        $run.ExitCode | Should -Be 0
        $run.Text | Should -Match 'MARKER=False'
        $run.Text | Should -Match 'LOCATION=\[\]'
        (Get-FileHash $planted).Hash | Should -Be $before
    }
    It 'rejects mutations of every protected entry' {
        foreach ($entry in $script:Entries) {
            Reset-Fixture
            Add-FixtureChangelog
            Edit-Protected (Join-Path $script:Fixture $entry.Path)
            $message = if ($entry.Path -ceq 'src\Test-PackageIntegrity.ps1') { '*Package integrity:*' } else { "*SHA256 mismatch: $($entry.Path)*" }
            { Invoke-Guard -Distribution } | Should -Throw -ExpectedMessage $message
        }
    }
    It 'refuses a tampered verifier before the module is imported' {
        Edit-Protected (Join-Path $script:Fixture 'src\Test-PackageIntegrity.ps1')
        { Import-Module (Join-Path $script:Fixture 'ExchangeLogReport.psd1') -Force -ErrorAction Stop } | Should -Throw -ExpectedMessage '*Package integrity:*'
    }
    It 'rejects missing mandatory stable files' {
        foreach ($entry in $script:Entries) {
            Reset-Fixture
            Add-FixtureChangelog
            Remove-Item -LiteralPath (Join-Path $script:Fixture $entry.Path)
            if ($entry.Path -ceq 'src\Test-PackageIntegrity.ps1') {
                { Import-Module (Join-Path $script:Fixture 'ExchangeLogReport.psd1') -Force -ErrorAction Stop } | Should -Throw
            } else { { Invoke-Guard -Distribution } | Should -Throw }
        }
    }
    It 'rejects an absent manifest' {
        Remove-Item -LiteralPath (Join-Path $script:Fixture 'PackageIntegrity.psd1')
        { Invoke-Guard } | Should -Throw
    }
    It 'rejects an altered manifest before parsing it' -Tag 'RealSignature' {
        $path = Join-Path $script:Fixture 'PackageIntegrity.psd1'
        [IO.File]::WriteAllText($path, "# Changed`r`n" + [IO.File]::ReadAllText($path), [Text.UTF8Encoding]::new($true))
        { Invoke-Guard } | Should -Throw -ExpectedMessage '*expected trusted, timestamped owner signature*'
    }
    It 'rejects a valid owner-signed but wrong manifest schema' {
        Copy-Item -LiteralPath (Join-Path $script:Fixture 'ExchangeLogReport.psd1') -Destination (Join-Path $script:Fixture 'PackageIntegrity.psd1') -Force
        { Invoke-Guard } | Should -Throw -ExpectedMessage '*unsupported or incomplete manifest schema*'
    }
    It 'rejects a manifest that omits, duplicates, adds or retargets an entry' {
        $path = Join-Path $script:Fixture 'PackageIntegrity.psd1'
        $original = [IO.File]::ReadAllText($path)
        $variants = [ordered]@{
            omitted   = [regex]::Replace($original, "(?m)^\s*@\{ Path = 'README.md';.*\r?\n", '')
            duplicate = $original.Replace("@{ Path = 'README.md';", "@{ Path = 'THIRD-PARTY-NOTICES.md';")
            unlisted  = $original.Replace("Path = 'README.md'", "Path = 'src\Engine.Extra.cs'")
            traversal = $original.Replace("Path = 'README.md'", "Path = '..\README.md'")
            absolute  = $original.Replace("Path = 'README.md'", "Path = 'C:\Windows\win.ini'")
            wronghash = $original.Replace("Path = 'README.md'; Sha256 = '", "Path = 'README.md'; Sha256 = 'g")
        }
        foreach ($name in $variants.Keys) {
            [IO.File]::WriteAllText($path, $variants[$name], [Text.UTF8Encoding]::new($true))
            { Invoke-Guard } | Should -Throw -ExpectedMessage '*Package integrity:*'
        }
    }
    It 'rejects a cryptographically valid manifest with its timestamp removed' -Tag 'RealSignature' {
        Add-Type -AssemblyName System.Security.Cryptography.Pkcs
        $path = Join-Path $script:Fixture 'PackageIntegrity.psd1'
        $encoding = [Text.UTF8Encoding]::new($false, $true)
        $text = $encoding.GetString([IO.File]::ReadAllBytes($path))
        $match = [regex]::Match($text, '(?ms)^# SIG # Begin signature block\r?\n(?<Data>.*?)^# SIG # End signature block\r?\n?\z')
        $match.Success | Should -BeTrue
        $cms = [Security.Cryptography.Pkcs.SignedCms]::new()
        $cms.Decode([Convert]::FromBase64String((($match.Groups['Data'].Value -replace '(?m)^#\s?', '') -replace '\s', '')))
        foreach ($attribute in @($cms.SignerInfos[0].UnsignedAttributes)) {
            foreach ($value in $attribute.Values) {
                $cms.SignerInfos[0].RemoveUnsignedAttribute([Security.Cryptography.AsnEncodedData]::new($attribute.Oid, $value.RawData))
            }
        }
        $base64 = [Convert]::ToBase64String($cms.Encode())
        $lines = for ($i = 0; $i -lt $base64.Length; $i += 64) { '# ' + $base64.Substring($i, [Math]::Min(64, $base64.Length - $i)) }
        [IO.File]::WriteAllBytes($path, $encoding.GetBytes($text.Substring(0, $match.Index) +
            "# SIG # Begin signature block`r`n" + ($lines -join "`r`n") + "`r`n# SIG # End signature block`r`n"))
        $signature = Get-AuthenticodeSignature -LiteralPath $path
        [string]$signature.Status | Should -Be 'Valid'
        $signature.TimeStamperCertificate | Should -BeNullOrEmpty
        { Invoke-Guard } | Should -Throw -ExpectedMessage '*expected trusted, timestamped owner signature*'
    }
    It 'rejects unknown code, source, template and documentation names rather than allowing directories or extensions' {
        foreach ($relative in 'lib\sqlite\extra.dll', 'src\extra.cs', 'src\Engine.Extra.cs', 'src\extra.ps1', 'templates\extra.html', 'docs\extra.ps1', 'docs\extra.html',
            'docs\images\extra.png', 'config\extra.psd1', 'extra.ps1', 'extra.dll') {
            Reset-Fixture
            Set-Content (Join-Path $script:Fixture $relative) 'not executable'
            { Invoke-Guard } | Should -Throw -ExpectedMessage '*unexpected stable file*'
        }
    }
    It 'allows only the declared repository-only documents without requiring them in a distribution' {
        Remove-Item -LiteralPath (Join-Path $script:Fixture 'LICENSE')
        Remove-Item -LiteralPath (Join-Path $script:Fixture 'docs\ExchangeLogReport-Guide.md')
        Remove-Item -LiteralPath (Join-Path $script:Fixture 'docs\ExchangeLogReport-UserGuide.md')
        Remove-Item -LiteralPath (Join-Path $script:Fixture 'docs\images') -Recurse
        { Invoke-Guard } | Should -Not -Throw
        # 28 protected files + the manifest + the delivered configuration.
        @(Get-ChildItem $script:Fixture -Recurse -File).Count | Should -Be 30
    }
    It 'rejects junctions in protected, library and source-document subtrees' {
        $outside = Join-Path $TestDrive 'junction-target'
        [void][IO.Directory]::CreateDirectory($outside)
        foreach ($relative in 'src', 'lib\sqlite', 'templates', 'docs\images', 'config') {
            Reset-Fixture
            $link = Join-Path $script:Fixture $relative
            Remove-Item -LiteralPath $link -Recurse -Force
            New-Item -ItemType Junction -Path $link -Target $outside | Out-Null
            try { { Invoke-Guard } | Should -Throw }
            finally { (Get-Item -LiteralPath $link -Force).Delete() }
        }
    }
    It 'checks integrity again on warm initialization and refuses another engine root' {
        Import-Module (Join-Path $script:Fixture 'ExchangeLogReport.psd1') -Force
        Initialize-ExlEngine -Root $script:Fixture
        { Initialize-ExlEngine -Root $script:Source } | Should -Throw -ExpectedMessage '*engine root must be the imported package root*'
        Add-Content (Join-Path $script:Fixture 'src\Engine.Text.cs') '// Changed after initialization'
        { Initialize-ExlEngine -Root $script:Fixture } | Should -Throw -ExpectedMessage '*SHA256 mismatch*'
    }
    It 'refuses a direct Import-Module of a package whose C# source, DLL or template changed' {
        foreach ($relative in 'src\Engine.Store.cs', 'lib\sqlite\SQLitePCLRaw.core.dll', 'templates\Report.template.html') {
            Reset-Fixture
            Edit-Protected (Join-Path $script:Fixture $relative)
            { Import-Module (Join-Path $script:Fixture 'ExchangeLogReport.psd1') -Force -ErrorAction Stop } | Should -Throw -ExpectedMessage "*SHA256 mismatch: $relative*"
        }
    }
    It 'stops the entry script before any module, library or database work' {
        foreach ($relative in 'src\Engine.Text.cs', 'lib\sqlite\runtimes\win-x64\e_sqlite3.dll', 'src\Test-PackageIntegrity.ps1') {
            Reset-Fixture
            Edit-Protected (Join-Path $script:Fixture $relative)
            $run = Invoke-Child ("& '$(Join-Path $script:Fixture 'Invoke-ExchangeLogReport.ps1')' -Mode Status; 'EXIT=' + `$LASTEXITCODE")
            $run.Text | Should -Match 'Package integrity'
            Test-Path -LiteralPath (Join-Path $script:Fixture 'data') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $script:Fixture 'bin') | Should -BeFalse
        }
    }
    It 'refuses an arbitrary external template before writing a report' {
        Import-Module (Join-Path $script:Fixture 'ExchangeLogReport.psd1') -Force
        $settings = @{ Report = @{ TemplatePath = Join-Path $TestDrive 'untrusted.html' } }
        { New-ExlReport -Store @{} -Settings $settings -Period @{} } | Should -Throw -ExpectedMessage '*report template must belong to the authenticated package*'
    }
    It 'builds a distribution from a verified source without regenerating protected files, and refuses a changed source' {
        $repo = Join-Path $TestDrive 'repo'
        if (Test-Path -LiteralPath $repo) { Remove-Item -LiteralPath $repo -Recurse -Force }
        [void][IO.Directory]::CreateDirectory((Join-Path $repo 'tools'))
        Copy-Item -LiteralPath $script:Source -Destination (Join-Path $repo 'package') -Recurse
        foreach ($folder in 'bin', 'data', 'logs', 'reports') { Remove-Item -LiteralPath (Join-Path $repo "package\$folder") -Recurse -Force -ErrorAction SilentlyContinue }
        Copy-Item -LiteralPath $script:Changelog -Destination $repo
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'tools\New-ExchangeLogReportPackage.ps1') -Destination (Join-Path $repo 'tools')
        $destination = Join-Path $TestDrive 'distribution'
        $built = Invoke-Child ("& '$(Join-Path $repo 'tools\New-ExchangeLogReportPackage.ps1')' -Destination '$destination' | Out-Null; 'BUILT'")
        $built.Text | Should -Match 'BUILT'
        $built.ExitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path $destination 'src\Test-PackageIntegrity.ps1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $destination 'Test-PackageIntegrity.ps1') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $destination -Recurse -File).Count | Should -Be 31
        foreach ($entry in $script:Entries) {
            (Get-FileHash (Join-Path $destination $entry.Path)).Hash | Should -Be $entry.Sha256
        }
        foreach ($name in 'LICENSE', 'docs\ExchangeLogReport-Guide.md', 'docs\images', 'bin', 'data', 'tests', 'tools') {
            Test-Path -LiteralPath (Join-Path $destination $name) | Should -BeFalse
        }
        Edit-Protected (Join-Path $repo 'package\README.md')
        $changed = Invoke-Child ("& '$(Join-Path $repo 'tools\New-ExchangeLogReportPackage.ps1')' -Destination '$(Join-Path $TestDrive 'distribution-changed')' | Out-Null; 'BUILT'")
        $changed.Text | Should -Match 'SHA256 mismatch: README.md'
        $changed.Text | Should -Not -Match 'BUILT'
        Test-Path -LiteralPath (Join-Path $TestDrive 'distribution-changed') | Should -BeFalse
    }
}
AfterAll { Remove-Module ExchangeLogReport -Force -ErrorAction SilentlyContinue }
