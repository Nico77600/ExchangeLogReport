#Requires -Version 7.4
# Signature-dependent cases carry the RealSignature tag: they need the owner-signed files of a signed commit.
# The other cases run the real verifier on a fixture copy whose Authenticode checks are replaced by a no-op, so that the
# manifest, the inventory, the hashes and the folder rules are exercised before the owner signs.
BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:Source = Join-Path $script:RepoRoot 'package'
    $script:Disclaimer = "This Script is a Personal project.`nIt's provided `"AS-IS`". It's not an official Microsoft product so no support can be expected from Microsoft.`n`nAs any scripts you must read carefully the documentation and test it first in a Test environment before any run in Production."
    $script:Pwsh = Join-Path $PSHOME 'pwsh.exe'
    $script:Signer = '0F28E442889F17B5F4D251E8F96E7CC6E2C9C6D6'
    $script:FixtureNumber = 0
    $script:Fixture = $null
    $script:Product = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'product.json') -Raw | ConvertFrom-Json

    # The manifest writer of the package builder, used as is.
    $builderPath = Join-Path $script:RepoRoot 'tools\Build-Standalone.ps1'
    $ast = [Management.Automation.Language.Parser]::ParseFile($builderPath, [ref]$null, [ref]$null)
    foreach ($name in 'Get-RelativeFile', 'Write-Manifest') {
        $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name }, $true)
        if ($null -eq $function) { throw "The builder function $name is missing." }
        . ([scriptblock]::Create($function.Extent.Text))
    }
    $signer = $script:Signer
    $product = $script:Product
    $binaryFolders = @('powershell', 'sqlite-tools')

    function New-FixtureTemplate {
        $template = Join-Path $TestDrive 'template'
        Copy-Item -LiteralPath $script:Source -Destination $template -Recurse
        foreach ($folder in 'bin', 'data', 'logs', 'reports', 'powershell', 'sqlite-tools') {
            Remove-Item -LiteralPath (Join-Path $template $folder) -Recurse -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath (Join-Path $template 'PackageIntegrity.psd1') -ErrorAction SilentlyContinue
        # A release package holds the HTML guides only.
        Remove-Item -LiteralPath (Join-Path $template 'docs\images') -Recurse -Force
        Get-ChildItem -LiteralPath (Join-Path $template 'docs') -Filter '*.md' | Remove-Item
        foreach ($name in 'CHANGELOG.md', 'LICENSE', 'SECURITY.md', 'product.json') {
            Copy-Item -LiteralPath (Join-Path $script:RepoRoot $name) -Destination $template
        }
        foreach ($relative in 'sqlite-tools\NOTICE.txt') {
            $path = Join-Path $template $relative
            [void][IO.Directory]::CreateDirectory((Split-Path $path -Parent))
            Set-Content -LiteralPath $path -Value "synthetic $relative"
        }
        [void][IO.Directory]::CreateDirectory((Join-Path $template 'powershell'))
        Copy-Item -LiteralPath $script:Pwsh -Destination (Join-Path $template 'powershell\pwsh.exe')
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'lib\sqlite-tools\sqlite3.exe') -Destination (Join-Path $template 'sqlite-tools\sqlite3.exe')
        # The test copy of the verifier does not check Authenticode: everything else is the delivered code.
        $verifier = Join-Path $template 'src\Test-PackageIntegrity.ps1'
        $text = [IO.File]::ReadAllText($verifier)
        $stubbed = [regex]::Replace($text, '(?s)function Assert-OwnerSignature\(\[string\]\$Path\) \{.*?\r?\n\}\r?\n', "function Assert-OwnerSignature([string]`$Path) { }`r`n")
        if ($stubbed -ceq $text) { throw 'The owner-signature check was not found in the verifier.' }
        [IO.File]::WriteAllText($verifier, $stubbed, [Text.UTF8Encoding]::new($false))
        [void](Write-Manifest $template)
        $template
    }
    function Reset-Fixture([switch]$Source) {
        Remove-Module ExchangeLogReport -Force -ErrorAction SilentlyContinue
        $script:FixtureNumber++
        $script:Fixture = Join-Path $TestDrive ('package-{0:D4}' -f $script:FixtureNumber)
        Copy-Item -LiteralPath $script:Template -Destination $script:Fixture -Recurse
        if ($Source) {
            # A source checkout: no built folders, no files copied at build time.
            foreach ($folder in 'powershell', 'sqlite-tools') { Remove-Item -LiteralPath (Join-Path $script:Fixture $folder) -Recurse -Force }
            foreach ($name in 'CHANGELOG.md', 'LICENSE', 'SECURITY.md', 'product.json') { Remove-Item -LiteralPath (Join-Path $script:Fixture $name) }
        }
    }
    function Invoke-Guard([string[]]$Switch = @()) {
        $verifier = Join-Path $script:Fixture 'src\Test-PackageIntegrity.ps1'
        $arguments = @{ Root = $script:Fixture }
        foreach ($name in $Switch) { $arguments[$name] = $true }
        & $verifier @arguments 3> $null
    }
    function Invoke-Child([string]$Command) {
        $output = & $script:Pwsh -NoProfile -NonInteractive -Command $Command 2>&1 | ForEach-Object { "$_" }
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = ($output -join "`n") }
    }
    function Edit-Protected([string]$Path) {
        if ([IO.Path]::GetExtension($Path) -in '.ps1', '.psm1', '.psd1') {
            [IO.File]::WriteAllText($Path, "# Evidence-only tamper`r`n" + [IO.File]::ReadAllText($Path), [Text.UTF8Encoding]::new($true))
        } else { [IO.File]::AppendAllBytes($Path, [Text.Encoding]::ASCII.GetBytes("`r`n# Evidence-only tamper")) }
    }
    $script:Template = New-FixtureTemplate
    $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $script:Template 'PackageIntegrity.psd1')
    $script:Entries = @($manifest.Files)
    $script:BinaryEntries = @($manifest.DistributionFiles)
}

Describe 'Signed manifest and verifier' {
    BeforeEach { Reset-Fixture }
    It 'accepts the distribution, the same files as a source checkout, and each in its own mode' {
        (Invoke-Guard @('Distribution')).Status | Should -Be 'Valid'
        (Invoke-Guard).Status | Should -Be 'Valid (files only)'
        (Invoke-Guard @('DevelopmentMode')).Status | Should -Be 'Valid (binaries not verified: DevelopmentMode)'
        Reset-Fixture -Source
        (Invoke-Guard).Status | Should -Be 'Valid (files only)'
        (Invoke-Guard @('DevelopmentMode')).Status | Should -Be 'Valid (binaries not verified: DevelopmentMode)'
        { Invoke-Guard @('Distribution') } | Should -Throw
    }
    It 'refuses -Distribution together with -DevelopmentMode' {
        { Invoke-Guard @('Distribution', 'DevelopmentMode') } | Should -Throw -ExpectedMessage '*cannot be combined*'
    }
    It 'inventories exactly the protected files in two lists' {
        $script:Entries.Count | Should -Be 57
        @($script:Entries.Path | Select-Object -Unique).Count | Should -Be 57
        foreach ($path in 'Invoke-ExchangeLogReport.ps1', 'Database-Storage.ps1', 'ExchangeLogReport.psm1', 'ExchangeLogReport.psd1', 'src\Test-PackageIntegrity.ps1',
            'src\Get-ExlExchangeSettings.ps1', 'Run-Collector.cmd', 'Start-Portal.cmd', 'Database-Storage.cmd', 'README.md', 'THIRD-PARTY-NOTICES.md', 'CHANGELOG.md',
            'LICENSE', 'SECURITY.md', 'product.json', 'templates\Report.template.html', 'templates\Report.template.js', 'docs\ExchangeLogReport-Guide.html', 'docs\ExchangeLogReport-UserGuide.html',
            'sqlite-tools\NOTICE.txt') {
            $script:Entries.Path | Should -Contain $path
        }
        $script:Entries.Path | Should -Not -Contain 'Angular-THIRD-PARTY-LICENSES.txt'
        $sources = @(Get-ChildItem (Join-Path $script:Source 'src') -Filter '*.cs' -File -Recurse)
        $libraries = @(Get-ChildItem (Join-Path $script:Source 'lib\sqlite') -Filter '*.dll' -File -Recurse)
        @($sources | Where-Object Name -Like 'Engine.*').Count | Should -Be 24
        @($sources | Where-Object Name -Like 'Storage.*').Count | Should -Be 7
        $libraries.Count | Should -Be 6
        foreach ($file in @($sources) + @($libraries)) {
            $script:Entries.Path | Should -Contain ([IO.Path]::GetRelativePath($script:Source, $file.FullName))
        }
        $script:Entries.Path | Should -Not -Contain 'config\ExchangeLogReport.config.psd1'
        $script:Entries.Path | Should -Not -Contain 'PackageIntegrity.psd1'
        $script:BinaryEntries.Path | Should -Contain 'powershell\pwsh.exe'
        $script:BinaryEntries.Path | Should -Contain 'sqlite-tools\sqlite3.exe'
        @($script:BinaryEntries | Where-Object { $_.Path.Split('\')[0] -cnotin 'powershell', 'sqlite-tools' }).Count | Should -Be 0
        $script:BinaryEntries.Path | Should -Not -Contain 'sqlite-tools\NOTICE.txt'
    }
    It 'keeps the verifier only in src and authenticates the package parent rather than src' {
        Test-Path -LiteralPath (Join-Path $script:Source 'Test-PackageIntegrity.ps1') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Fixture 'src\Test-PackageIntegrity.ps1') | Should -BeTrue
        { & (Join-Path $script:Fixture 'src\Test-PackageIntegrity.ps1') -Root (Join-Path $script:Fixture 'src') } |
            Should -Throw -ExpectedMessage '*verifier must belong to this package root*'
    }
    It 'rejects a second verifier at the obsolete root path and one copied outside src' {
        $copy = Join-Path $script:Fixture 'Test-PackageIntegrity.ps1'
        Copy-Item -LiteralPath (Join-Path $script:Fixture 'src\Test-PackageIntegrity.ps1') -Destination $copy
        { Invoke-Guard @('Distribution') } | Should -Throw -ExpectedMessage '*unexpected stable file: Test-PackageIntegrity.ps1*'
        Remove-Item -LiteralPath $copy
        $outside = Join-Path $TestDrive 'copied-verifier.ps1'
        Copy-Item -LiteralPath (Join-Path $script:Fixture 'src\Test-PackageIntegrity.ps1') -Destination $outside
        { & $outside -Root $script:Fixture } | Should -Throw -ExpectedMessage '*verifier must belong to this package root*'
    }
    It 'accepts editable configuration and generated folders' {
        Add-Content (Join-Path $script:Fixture 'config\ExchangeLogReport.config.psd1') '# Fictitious customization'
        Set-Content (Join-Path $script:Fixture 'config\ExchangeLogReport.paths.psd1') '@{}'
        Set-Content (Join-Path $script:Fixture 'config\ExchangeLogReport.mail.credential') '{}'
        foreach ($folder in 'bin', 'data', 'logs', 'reports') {
            [void][IO.Directory]::CreateDirectory((Join-Path $script:Fixture $folder))
            Set-Content (Join-Path $script:Fixture "$folder\generated.txt") 'generated'
        }
        (Invoke-Guard @('Distribution')).Status | Should -Be 'Valid'
    }
    It 'rejects mutations of every protected entry, and of every binary in a distribution' {
        foreach ($entry in $script:Entries) {
            Reset-Fixture
            Edit-Protected (Join-Path $script:Fixture $entry.Path)
            { Invoke-Guard @('Distribution') } | Should -Throw -ExpectedMessage "*SHA256 mismatch: $($entry.Path)*"
            if ($entry.Path -cnotin 'CHANGELOG.md', 'LICENSE', 'SECURITY.md', 'product.json', 'sqlite-tools\NOTICE.txt') {
                { Invoke-Guard } | Should -Throw -ExpectedMessage "*SHA256 mismatch: $($entry.Path)*"
                { Invoke-Guard @('DevelopmentMode') } | Should -Throw -ExpectedMessage "*SHA256 mismatch: $($entry.Path)*"
            }
        }
        foreach ($entry in $script:BinaryEntries | Where-Object { $_.Path -cne 'powershell\pwsh.exe' }) {
            Reset-Fixture
            Edit-Protected (Join-Path $script:Fixture $entry.Path)
            { Invoke-Guard @('Distribution') } | Should -Throw -ExpectedMessage "*SHA256 mismatch: $($entry.Path)*"
            (Invoke-Guard @('DevelopmentMode')).Status | Should -BeLike 'Valid (binaries not verified*'
            (Invoke-Guard).Status | Should -Be 'Valid (files only)'
        }
    }
    It 'rejects a tampered launcher, entry script or storage entry script even though the launchers cannot be signed' {
        foreach ($relative in 'Run-Collector.cmd', 'Start-Portal.cmd', 'Database-Storage.cmd', 'Database-Storage.ps1', 'Invoke-ExchangeLogReport.ps1') {
            Reset-Fixture
            Edit-Protected (Join-Path $script:Fixture $relative)
            { Invoke-Guard } | Should -Throw -ExpectedMessage "*SHA256 mismatch: $relative*"
        }
    }
    It 'rejects missing mandatory stable files' {
        foreach ($entry in $script:Entries) {
            Reset-Fixture
            Remove-Item -LiteralPath (Join-Path $script:Fixture $entry.Path)
            { Invoke-Guard @('Distribution') } | Should -Throw
        }
        foreach ($entry in $script:BinaryEntries) {
            Reset-Fixture
            Remove-Item -LiteralPath (Join-Path $script:Fixture $entry.Path)
            { Invoke-Guard @('Distribution') } | Should -Throw
        }
    }
    It 'rejects an extra file in a built folder, a retired host or portal folder and any unknown stable file' {
        Set-Content (Join-Path $script:Fixture 'powershell\unreviewed.dll') 'extra'
        { Invoke-Guard @('Distribution') } | Should -Throw -ExpectedMessage '*unexpected stable file: powershell\unreviewed.dll*'
        Reset-Fixture
        [void][IO.Directory]::CreateDirectory((Join-Path $script:Fixture 'host'))
        Set-Content (Join-Path $script:Fixture 'host\ExchangeLogReportAngular.exe') 'retired'
        { Invoke-Guard @('Distribution') } | Should -Throw -ExpectedMessage '*unexpected stable file: host\*'
        # The compiled Angular portal and its notices are retired: a package that still holds them is refused in every mode.
        foreach ($relative in 'web\index.html', 'Angular-THIRD-PARTY-LICENSES.txt') {
            foreach ($mode in @(@(), @('DevelopmentMode'), @('Distribution'))) {
                Reset-Fixture
                [void][IO.Directory]::CreateDirectory((Split-Path (Join-Path $script:Fixture $relative) -Parent))
                Set-Content (Join-Path $script:Fixture $relative) 'retired'
                { Invoke-Guard $mode } | Should -Throw -ExpectedMessage "*unexpected stable file: $relative*" -Because "$relative $mode"
            }
        }
        foreach ($relative in 'lib\sqlite\extra.dll', 'src\extra.cs', 'src\Engine.Extra.cs', 'src\Storage.Extra.cs', 'src\extra.ps1', 'templates\extra.html', 'docs\extra.ps1',
            'docs\extra.html', 'docs\images\extra.png', 'config\extra.psd1', 'extra.ps1', 'extra.dll', 'extra.cmd', 'tools\Test-PackageIntegrity.ps1') {
            Reset-Fixture
            [void][IO.Directory]::CreateDirectory((Split-Path (Join-Path $script:Fixture $relative) -Parent))
            Set-Content (Join-Path $script:Fixture $relative) 'not executable'
            { Invoke-Guard } | Should -Throw -ExpectedMessage '*unexpected stable file*'
        }
    }
    It 'rejects a junction in a protected, built or source-document subtree' {
        $outside = Join-Path $TestDrive 'junction-target'
        [void][IO.Directory]::CreateDirectory($outside)
        foreach ($relative in 'src', 'lib\sqlite', 'templates', 'docs', 'config', 'powershell', 'sqlite-tools') {
            Reset-Fixture
            $link = Join-Path $script:Fixture $relative
            Remove-Item -LiteralPath $link -Recurse -Force
            New-Item -ItemType Junction -Path $link -Target $outside | Out-Null
            try { { Invoke-Guard } | Should -Throw }
            finally { (Get-Item -LiteralPath $link -Force).Delete() }
        }
    }
    It 'rejects an absent manifest and a manifest of the wrong shape' {
        Remove-Item -LiteralPath (Join-Path $script:Fixture 'PackageIntegrity.psd1')
        { Invoke-Guard } | Should -Throw -ExpectedMessage '*PackageIntegrity.psd1 is missing. Use the complete release ZIP (https://github.com/Nico77600/ExchangeLogReport/releases/latest)*-DevelopmentMode*'
        Reset-Fixture
        Copy-Item -LiteralPath (Join-Path $script:Fixture 'ExchangeLogReport.psd1') -Destination (Join-Path $script:Fixture 'PackageIntegrity.psd1') -Force
        { Invoke-Guard } | Should -Throw -ExpectedMessage '*unsupported or incomplete manifest schema*'
    }
    It 'rejects a manifest that omits, duplicates, adds or retargets an entry' {
        $path = Join-Path $script:Fixture 'PackageIntegrity.psd1'
        $original = [IO.File]::ReadAllText($path)
        $variants = [ordered]@{
            omitted      = [regex]::Replace($original, "(?m)^\s*@\{ Path = 'README.md';.*\r?\n", '')
            duplicate    = $original.Replace("@{ Path = 'README.md';", "@{ Path = 'THIRD-PARTY-NOTICES.md';")
            unlisted     = $original.Replace("Path = 'README.md'", "Path = 'src\Engine.Extra.cs'")
            traversal    = $original.Replace("Path = 'README.md'", "Path = '..\README.md'")
            absolute     = $original.Replace("Path = 'README.md'", "Path = 'C:\Windows\win.ini'")
            wronghash    = $original.Replace("Path = 'README.md'; Sha256 = '", "Path = 'README.md'; Sha256 = 'g")
            wrongsigner  = $original.Replace($script:Signer, '0' * 40)
            binaryoutside = $original.Replace("Path = 'sqlite-tools\sqlite3.exe'", "Path = 'src\sqlite3.exe'")
            binarydotdot = $original.Replace("Path = 'sqlite-tools\sqlite3.exe'", "Path = 'sqlite-tools\..\sqlite3.exe'")
            binaryretired = $original.Replace("Path = 'sqlite-tools\sqlite3.exe'", "Path = 'web\sqlite3.exe'")
            binarymissing = [regex]::Replace($original, "(?m)^\s*@\{ Path = 'powershell\\pwsh.exe';.*\r?\n", '')
            binaryduplicate = $original.Replace("Path = 'sqlite-tools\sqlite3.exe'", "Path = 'powershell\pwsh.exe'")
        }
        foreach ($name in $variants.Keys) {
            [IO.File]::WriteAllText($path, $variants[$name], [Text.UTF8Encoding]::new($true))
            { Invoke-Guard @('Distribution') } | Should -Throw -ExpectedMessage '*Package integrity:*' -Because $name
        }
    }
    It 'checks the microsoft signature of the bundled runtime and the pinned SQLite tool in a distribution' {
        [IO.File]::AppendAllBytes((Join-Path $script:Fixture 'sqlite-tools\sqlite3.exe'), [byte[]](0))
        $manifestPath = Join-Path $script:Fixture 'PackageIntegrity.psd1'
        $signer = $script:Signer; $product = $script:Product; $binaryFolders = @('powershell', 'sqlite-tools')
        [void](Write-Manifest $script:Fixture)
        { Invoke-Guard @('Distribution') } | Should -Throw -ExpectedMessage '*pinned SQLite command-line tool*'
        Reset-Fixture
        Set-Content (Join-Path $script:Fixture 'powershell\pwsh.exe') 'not a signed runtime'
        [void](Write-Manifest $script:Fixture)
        { Invoke-Guard @('Distribution') } | Should -Throw -ExpectedMessage '*pwsh.exe must carry a valid Microsoft signature*'
    }
}

Describe 'Integrity at the entry points' {
    BeforeEach { Reset-Fixture }
    It 'refuses to start the entry scripts and the module from a changed package, before any database or compiled work' {
        foreach ($relative in 'src\Engine.Text.cs', 'lib\sqlite\runtimes\win-x64\e_sqlite3.dll', 'src\Test-PackageIntegrity.ps1', 'ExchangeLogReport.psm1') {
            Reset-Fixture
            Edit-Protected (Join-Path $script:Fixture $relative)
            $run = Invoke-Child ("& '$(Join-Path $script:Fixture 'Invoke-ExchangeLogReport.ps1')' -Mode Status; 'EXIT=' + `$LASTEXITCODE")
            $run.Text | Should -Match 'Package integrity'
            $run.Text | Should -Not -Match 'Ready for the first collection|EXIT=0'
            $storage = Invoke-Child ("& '$(Join-Path $script:Fixture 'Database-Storage.ps1')' --storage-audit --database '$(Join-Path $TestDrive 'none.sqlite')'; 'EXIT=' + `$LASTEXITCODE")
            $storage.Text | Should -Match 'Package integrity'
            Test-Path -LiteralPath (Join-Path $script:Fixture 'data') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $script:Fixture 'bin') | Should -BeFalse
        }
    }
    It 'refuses a tampered verifier before the module is imported' {
        Edit-Protected (Join-Path $script:Fixture 'src\Test-PackageIntegrity.ps1')
        { Import-Module (Join-Path $script:Fixture 'ExchangeLogReport.psd1') -Force -ErrorAction Stop } | Should -Throw -ExpectedMessage '*Package integrity:*'
    }
    It 'does not run a verifier that lacks the owner signature, even from an otherwise correct package' {
        # The fixture verifier is unsigned: the module and the entry scripts must refuse it instead of executing it.
        { Import-Module (Join-Path $script:Fixture 'ExchangeLogReport.psd1') -Force -ErrorAction Stop } | Should -Throw -ExpectedMessage '*owner signature*'
        $run = Invoke-Child ("& '$(Join-Path $script:Fixture 'Invoke-ExchangeLogReport.ps1')' -Mode Status -DevelopmentMode; 'EXIT=' + `$LASTEXITCODE")
        $run.Text | Should -Match 'owner signature'
    }
    It 'accepts an unverified source checkout only with -DevelopmentMode' {
        Reset-Fixture -Source
        Remove-Item -LiteralPath (Join-Path $script:Fixture 'PackageIntegrity.psd1')
        $plain = Invoke-Child ("& '$(Join-Path $script:Fixture 'Invoke-ExchangeLogReport.ps1')' -Mode Status; 'EXIT=' + `$LASTEXITCODE")
        $plain.Text | Should -Match 'PackageIntegrity.psd1 is missing\. Use the complete release ZIP .*releases/latest.*-DevelopmentMode'
        $development = Invoke-Child ("& '$(Join-Path $script:Fixture 'Invoke-ExchangeLogReport.ps1')' -Mode Status -DevelopmentMode 3>&1 | Out-String")
        $development.Text | Should -Match 'DevelopmentMode: no package manifest'
        # One warning per process: the module does not repeat it at import, engine initialization or a later check.
        ([regex]::Matches($development.Text, 'no package manifest|no PackageIntegrity\.psd1')).Count | Should -Be 1
    }
}

Describe 'Owner signatures' -Tag 'RealSignature' {
    It 'requires valid timestamped owner signatures on the six PowerShell files and the manifest' {
        foreach ($name in 'Invoke-ExchangeLogReport.ps1', 'Database-Storage.ps1', 'ExchangeLogReport.psm1', 'ExchangeLogReport.psd1', 'src\Test-PackageIntegrity.ps1',
            'src\Get-ExlExchangeSettings.ps1', 'PackageIntegrity.psd1') {
            $path = Join-Path $script:Source $name
            Test-Path -LiteralPath $path | Should -BeTrue -Because "$name is committed"
            $signature = Get-AuthenticodeSignature -LiteralPath $path
            [string]$signature.Status | Should -Be 'Valid' -Because $name
            $signature.SignerCertificate.Thumbprint | Should -BeExactly $script:Signer
            $signature.TimeStamperCertificate | Should -Not -BeNullOrEmpty
        }
    }
    It 'accepts the committed package with the real verifier' {
        $result = & (Join-Path $script:Source 'src\Test-PackageIntegrity.ps1') -Root $script:Source
        $result.Status | Should -Be 'Valid (files only)'
    }
    It 'rejects an altered manifest before parsing it' {
        $fixture = Join-Path $TestDrive 'real-signature'
        Copy-Item -LiteralPath $script:Source -Destination $fixture -Recurse
        Remove-Item -LiteralPath (Join-Path $fixture 'bin'), (Join-Path $fixture 'data') -Recurse -Force -ErrorAction SilentlyContinue
        $path = Join-Path $fixture 'PackageIntegrity.psd1'
        [IO.File]::WriteAllText($path, "# Changed`r`n" + [IO.File]::ReadAllText($path), [Text.UTF8Encoding]::new($true))
        { & (Join-Path $fixture 'src\Test-PackageIntegrity.ps1') -Root $fixture } | Should -Throw -ExpectedMessage '*expected trusted, timestamped owner signature*'
    }
    It 'rejects a cryptographically valid manifest with its timestamp removed' {
        Add-Type -AssemblyName System.Security.Cryptography.Pkcs
        $fixture = Join-Path $TestDrive 'real-timestamp'
        Copy-Item -LiteralPath $script:Source -Destination $fixture -Recurse
        Remove-Item -LiteralPath (Join-Path $fixture 'bin'), (Join-Path $fixture 'data') -Recurse -Force -ErrorAction SilentlyContinue
        $path = Join-Path $fixture 'PackageIntegrity.psd1'
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
        [string](Get-AuthenticodeSignature -LiteralPath $path).Status | Should -Be 'Valid'
        (Get-AuthenticodeSignature -LiteralPath $path).TimeStamperCertificate | Should -BeNullOrEmpty
        { & (Join-Path $fixture 'src\Test-PackageIntegrity.ps1') -Root $fixture } | Should -Throw -ExpectedMessage '*expected trusted, timestamped owner signature*'
    }
    It 'starts the portal through Start-Portal.cmd on the sealed release package and refuses a copy with one changed byte' {
        # EXL_RELEASE_PACKAGE: the release package folder after Build-Standalone.ps1 -Seal (the launchers verify it with -Distribution).
        $package = $env:EXL_RELEASE_PACKAGE
        if (-not $package -or -not (Test-Path -LiteralPath (Join-Path $package 'PackageIntegrity.psd1'))) {
            throw 'Set EXL_RELEASE_PACKAGE to the sealed release package folder (Build-Standalone.ps1 -Seal).'
        }
        function Start-Launcher([string]$Root, [string[]]$Arguments, [string]$Name) {
            # An empty standard input: the pause of the refusal branch returns at once.
            $stdin = Join-Path $TestDrive "$Name.in"
            Set-Content -LiteralPath $stdin -Value ''
            $process = Start-Process -FilePath (Join-Path $Root 'Start-Portal.cmd') -ArgumentList $Arguments -WindowStyle Hidden -PassThru -RedirectStandardInput $stdin `
                -RedirectStandardOutput (Join-Path $TestDrive "$Name.out") -RedirectStandardError (Join-Path $TestDrive "$Name.err")
            $null = $process.Handle
            $process
        }
        function Stop-Launcher($Process) { if (-not $Process.HasExited) { & "$env:SystemRoot\System32\taskkill.exe" /PID $Process.Id /T /F | Out-Null } }
        $ready = Join-Path $TestDrive 'launcher-ready.json'
        $database = Join-Path $TestDrive 'launcher-none.sqlite'
        $signed = Start-Launcher $package @('-NoBrowser', '-Port', '0', '-DatabasePath', "`"$database`"", '-ReadyFile', "`"$ready`"", '-ReadyFileWithToken') 'signed'
        try {
            $deadline = [datetime]::UtcNow.AddSeconds(120)
            while (-not ((Test-Path -LiteralPath $ready) -and (Get-Item -LiteralPath $ready).Length -gt 0) -and -not $signed.HasExited -and [datetime]::UtcNow -lt $deadline) {
                Start-Sleep -Milliseconds 200
            }
            Test-Path -LiteralPath $ready | Should -BeTrue -Because ((Get-Content -LiteralPath (Join-Path $TestDrive 'signed.out') -Raw) + (Get-Content -LiteralPath (Join-Path $TestDrive 'signed.err') -Raw))
            $state = Get-Content -LiteralPath $ready -Raw | ConvertFrom-Json
            $state.status | Should -Be 'ready'
            Invoke-WebRequest -Uri ($state.url.TrimEnd('/') + '/api/shutdown') -Method Post -Headers @{ 'X-Portal-Token' = $state.token } | Out-Null
            $signed.WaitForExit(30000) | Should -BeTrue
            $signed.ExitCode | Should -Be 0
        } finally { Stop-Launcher $signed }
        $copy = Join-Path $TestDrive 'changed-release'
        Copy-Item -LiteralPath $package -Destination $copy -Recurse
        $page = Join-Path $copy 'templates\Report.template.html'
        $bytes = [IO.File]::ReadAllBytes($page)
        $bytes[0] = $bytes[0] -bxor 1
        [IO.File]::WriteAllBytes($page, $bytes)
        $changed = Start-Launcher $copy @('-NoBrowser', '-Port', '0', '-DatabasePath', "`"$database`"") 'changed'
        try {
            $changed.WaitForExit(120000) | Should -BeTrue
            $changed.ExitCode | Should -Be 1
            $text = (Get-Content -LiteralPath (Join-Path $TestDrive 'changed.out') -Raw) + (Get-Content -LiteralPath (Join-Path $TestDrive 'changed.err') -Raw)
            $text | Should -Match 'SHA256 mismatch: templates\\Report\.template\.html'
            $text | Should -Match 'The package could not be verified\. Read the message above\.'
            $text | Should -Not -Match 'Serve \(read-only\)'
        } finally { Stop-Launcher $changed }
    }
}

Describe 'Launchers and builder' {
    It 'verifies the package with -Distribution before every launcher starts anything, and never offers -DevelopmentMode' {
        foreach ($name in 'Run-Collector.cmd', 'Start-Portal.cmd', 'Database-Storage.cmd') {
            $text = [IO.File]::ReadAllText((Join-Path $script:Source $name))
            $text | Should -Match ([regex]::Escape('"%~dp0powershell\pwsh.exe" -NoLogo -NoProfile -File "%~dp0src\Test-PackageIntegrity.ps1" -Root "%~dp0." -Distribution'))
            $text | Should -Not -Match 'DevelopmentMode'
            $text | Should -Not -Match 'host\\|collector\\|tools\\Test-PackageIntegrity'
            $text.IndexOf('Test-PackageIntegrity.ps1') | Should -BeLessThan $text.LastIndexOf('pwsh.exe')
        }
        [IO.File]::ReadAllText((Join-Path $script:Source 'Run-Collector.cmd')) | Should -Match '"%~dp0Invoke-ExchangeLogReport\.ps1"'
        [IO.File]::ReadAllText((Join-Path $script:Source 'Start-Portal.cmd')) | Should -Match '"%~dp0Invoke-ExchangeLogReport\.ps1" -Mode Serve %\*'
        [IO.File]::ReadAllText((Join-Path $script:Source 'Database-Storage.cmd')) | Should -Match '"%~dp0Database-Storage\.ps1" %\*'
        # A refused package says so and, when the window was opened by a double-click, waits for a key so the message can be read.
        $refusal = '-Distribution\r\n(?:rem [^\r\n]*\r\n)?if errorlevel 1 \(\r\n  echo The package could not be verified\. Read the message above\.\r\n'
        [IO.File]::ReadAllText((Join-Path $script:Source 'Start-Portal.cmd')) | Should -Match ($refusal + '  pause\r\n  exit /b 1\r\n\)')
        [IO.File]::ReadAllText((Join-Path $script:Source 'Run-Collector.cmd')) | Should -Match ($refusal + '  if "%~1"=="" pause\r\n  exit /b 1\r\n\)')
        [IO.File]::ReadAllText((Join-Path $script:Source 'Database-Storage.cmd')) | Should -Match ($refusal + '  exit /b 1\r\n\)')
        Test-Path -LiteralPath (Join-Path $script:Source 'Start-ExchangeLogReportAngular.cmd') | Should -BeFalse
    }
    It 'builds a three-step release without dotnet, key material or the retired host' {
        $builder = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'tools\Build-Standalone.ps1'))
        $builder | Should -Not -Match 'dotnet|signtool|\.pfx|Cert:\\'
        $builder | Should -Match "Join-Path \`$root 'package'"
        $builder | Should -Match '\[switch\]\$Unsigned'
        $builder | Should -Match "ParameterSetName = 'Manifest'"
        $builder | Should -Match "ParameterSetName = 'Seal'"
        $builder | Should -Match "'Database-Storage\.ps1'"
        $builder | Should -Match "'templates\\Report\.template\.html', 'templates\\Report\.template\.js', 'powershell\\pwsh\.exe', 'Run-Collector\.cmd', 'Start-Portal\.cmd',"
        $builder | Should -Not -Match '(?i)angular|frontend|npm|THIRD-PARTY-LICENSES'
    }
    It 'writes a manifest that the verifier parses, with both lists in a stable order' {
        $text = [IO.File]::ReadAllText((Join-Path $script:Template 'PackageIntegrity.psd1'))
        $text | Should -Match "(?s)^@\{\r\n    SchemaVersion = 1\r\n    Algorithm = 'SHA256'\r\n    SignerThumbprint = '$($script:Signer)'\r\n    Version = '3\.0\.0'\r\n    Files = @\(.*\r\n    \)\r\n    DistributionFiles = @\(.*\r\n    \)\r\n\}\r\n$"
        $paths = @($script:Entries.Path)
        $paths | Should -Be @($paths | Sort-Object { $_ } -CaseSensitive)
    }
}

Describe 'Documentation standard' {
    It 'keeps the root presentation, exact disclaimer, SECURITY and local links aligned with the documentation standard' {
        $text = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'README.md')).Replace("`r`n", "`n")
        $headings = @([regex]::Matches($text, '(?m)^## ([^\n]+)$') | ForEach-Object { $_.Groups[1].Value })
        $headings | Should -Be @('Why', 'Get started', 'How it works', 'Noise removed before storage', 'Sessions and messages', 'Reports', 'Requirements',
            'Package layout', 'Documentation', 'Tests', 'Data handling', 'License', 'Disclaimer')
        $steps = @([regex]::Matches($text, '(?m)^### ([^\n]+)$') | ForEach-Object { $_.Groups[1].Value })
        $steps | Should -Be @('Set up once · 1 to 4', 'A · Recurring reporting · 5 to 7', 'B · Troubleshooting · 5 to 7', 'C · Investigate in the browser · 5 to 7')
        $text | Should -Match 'Nicolas Fabert'
        $text | Should -Match '\*\*Version:\*\* 3\.0\.0'
        $text | Should -Not -Match 'unreleased|experimental|pilot'
        $text.TrimEnd().EndsWith($script:Disclaimer, [StringComparison]::Ordinal) | Should -BeTrue
        $text | Should -Match '(?s)^<p align="center">\s*<picture>.*?prefers-color-scheme: dark.*?</picture>'
        [regex]::Matches($text, '<a href="#').Count | Should -BeGreaterOrEqual 3
        # The download block opens the document, before the first section.
        $text.IndexOf('Download the latest release') | Should -BeGreaterThan 0
        $text.IndexOf('Download the latest release') | Should -BeLessThan $text.IndexOf('## Why')
        $text.IndexOf('releases/latest') | Should -BeLessThan $text.IndexOf('## Why')
        $text | Should -Match 'Check the publisher first'
        foreach ($match in [regex]::Matches($text, '(?:src|srcset|href)="([^"#?]+)(?:\?[^"#]*)?"|\[[^\]\n]+\]\(([^)#\s]+)')) {
            $relative = if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value }
            if ($relative -match '^https?://') { continue }
            Test-Path -LiteralPath (Join-Path $script:RepoRoot $relative.Replace('/', '\')) | Should -BeTrue -Because $relative
        }
        $security = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'SECURITY.md')).TrimStart([char]0xFEFF).Replace("`r`n", "`n").TrimEnd()
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($security))) |
            Should -BeExactly '53E60B9EDFEEFCB085817ECA745DE00A62F7BD891386834366E1E3243D48972F'
    }
    It 'documents launcher lists without a space after the comma and keeps the disclaimer in both entry scripts' {
        # Run-Collector.cmd passes its arguments to pwsh -File: "-Server EXCH01, EXCH02" would bind EXCH02 to another parameter.
        foreach ($document in @((Join-Path $script:RepoRoot 'README.md'), (Join-Path $script:Source 'README.md')) + @(Get-ChildItem -LiteralPath (Join-Path $script:Source 'docs') -Filter '*.md' | ForEach-Object FullName)) {
            [IO.File]::ReadAllText($document) | Should -Not -Match '-(User|Server) [^\s`]+, ' -Because $document
        }
        foreach ($script in 'Invoke-ExchangeLogReport.ps1', 'Database-Storage.ps1') {
            $help = [regex]::Match([IO.File]::ReadAllText((Join-Path $script:Source $script)).Replace("`r`n", "`n"), '(?s)<#(.*?)#>').Groups[1].Value
            $lines = ($help -split "`n" | ForEach-Object { $_.Trim() }) -join "`n"
            $lines | Should -Match ([regex]::Escape($script:Disclaimer)) -Because $script
        }
    }
    It 'keeps the delivered runtime README aligned with the exact documentation contract' {
        $text = [IO.File]::ReadAllText((Join-Path $script:Source 'README.md')).Replace("`r`n", "`n")
        $headings = @([regex]::Matches($text, '(?m)^## ([^\n]+)$') | ForEach-Object { $_.Groups[1].Value })
        $headings | Should -Be @('Requirements', 'Quick start', 'Content', 'Documentation', 'Data handling', 'Disclaimer')
        $text | Should -Match 'Nicolas Fabert'
        $text | Should -Match '\*\*Version:\*\* 3\.0\.0'
        $text.TrimEnd().EndsWith($script:Disclaimer, [StringComparison]::Ordinal) | Should -BeTrue
        $text | Should -Not -Match 'unsigned|experimental|pilot|collector\\|host\\|README\.txt'
        foreach ($match in [regex]::Matches($text, '\[[^\]\n]+\]\(([^)#]+)')) {
            $target = $match.Groups[1].Value
            if ($target -match '^https?://') { continue }
            $inPackage = Join-Path $script:Source $target.Replace('/', '\')
            $atRoot = Join-Path $script:RepoRoot $target.Replace('/', '\')
            # CHANGELOG.md, SECURITY.md and LICENSE are copied from the repository root when the package is built.
            (Test-Path -LiteralPath $inPackage) -or ($target -in 'CHANGELOG.md', 'SECURITY.md', 'LICENSE' -and (Test-Path -LiteralPath $atRoot)) |
                Should -BeTrue -Because $target
        }
    }
    It 'documents the three ways to read the history in self-contained guides' {
        $docs = Join-Path $script:Source 'docs'
        $user = [IO.File]::ReadAllText((Join-Path $docs 'ExchangeLogReport-UserGuide.html'))
        $developer = [IO.File]::ReadAllText((Join-Path $docs 'ExchangeLogReport-Guide.html'))
        $user | Should -Match 'data-target="c-investigate-in-the-browser"'
        $user | Should -Match 'data-target="database-maintenance-rare"'
        foreach ($anchor in 'start-the-portal', 'pick-the-days-then-read-the-tabs', 'open-a-session-a-message-or-an-smtp-client', 'export-the-view-and-stop-the-portal', 'if-you-see-a-message') {
            $user | Should -Match ('id="' + $anchor + '"')
        }
        $developer | Should -Match 'data-target="the-portal"'
        $developer | Should -Match 'id="the-lifecycle-and-the-two-consumers"'
        $developer | Should -Match 'id="selection-concurrency-and-freshness"'
        foreach ($html in $user, $developer) {
            $html | Should -Not -Match 'src="\.\./|href="\.\./'
            ([regex]::Matches($html, '<img [^>]*src="(?!data:)')).Count | Should -Be 0
        }
        foreach ($image in 'portal-overview.png', 'portal-overview-dark.png', 'portal-sessions-remote.png', 'portal-server-selection.png', 'portal-session-timeline.png', 'portal-message-route.png', 'portal-authentication.png', 'portal-authentication-row.png', 'portal-export.png') {
            Test-Path -LiteralPath (Join-Path $docs "images\$image") -PathType Leaf | Should -BeTrue
        }
        $sourceNames = @(Get-ChildItem -LiteralPath (Join-Path $docs 'images') -File | ForEach-Object Name)
        $verifier = [IO.File]::ReadAllText((Join-Path $script:Source 'src\Test-PackageIntegrity.ps1'))
        foreach ($name in $sourceNames) { $verifier | Should -Match ([regex]::Escape("'docs\images\$name'")) -Because $name }
        @([regex]::Matches($verifier, "'docs\\images\\([^']+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object) | Should -Be @($sourceNames | Sort-Object)
    }
    It 'documents the export ticket of the portal: its two routes, its validity and the deadline of an export' {
        $markdown = [IO.File]::ReadAllText((Join-Path $script:Source 'docs\ExchangeLogReport-Guide.md'))
        $html = [IO.File]::ReadAllText((Join-Path $script:Source 'docs\ExchangeLogReport-Guide.html'))
        foreach ($text in 'POST /api/export/ticket', 'GET /api/export/&lt;ticket&gt;.csv', 'no total deadline', 'within 60 s of its issue', 'one export at a time') {
            $markdown | Should -Match ([regex]::Escape([Net.WebUtility]::HtmlDecode($text))) -Because "the Guide documents $text"
            $html | Should -Match ([regex]::Escape($text)) -Because "the HTML Guide documents $text"
        }
        $markdown | Should -Not -Match 'details and exports \(`-RequestTimeoutSeconds`\)'
    }
    It 'has a target for every in-page link of both HTML guides' {
        foreach ($name in 'ExchangeLogReport-Guide', 'ExchangeLogReport-UserGuide') {
            $html = [IO.File]::ReadAllText((Join-Path $script:Source "docs\$name.html"))
            $ids = [Collections.Generic.HashSet[string]]::new([string[]]@([regex]::Matches($html, '\sid="([^"]+)"') | ForEach-Object { $_.Groups[1].Value }), [StringComparer]::Ordinal)
            $links = @([regex]::Matches($html, 'href="#([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
            $links.Count | Should -BeGreaterThan 0 -Because $name
            $dead = @($links | Where-Object { -not $ids.Contains($_) })
            $dead | Should -BeNullOrEmpty -Because "$name.html links to #$($dead -join ', #')"
        }
    }
    It 'keeps the guides on the publisher check instead of blanket unblocking' {
        foreach ($name in 'ExchangeLogReport-Guide', 'ExchangeLogReport-UserGuide') {
            $markdown = [IO.File]::ReadAllText((Join-Path $script:Source "docs\$name.md"))
            $markdown | Should -Match 'Check the publisher first'
            $markdown | Should -Match 'Digital Signatures: `Nicolas Fabert`'
            $markdown | Should -Not -Match 'ExecutionPolicy\s+Bypass'
            $html = [IO.File]::ReadAllText((Join-Path $script:Source "docs\$name.html"))
            $html | Should -Match 'Check the publisher first'
        }
    }
    It 'keeps the front matter of both guides: title, version and author in the Markdown and the HTML' {
        $version = (Get-Content -LiteralPath (Join-Path $script:RepoRoot 'product.json') -Raw | ConvertFrom-Json).version
        $dot = [char]0x00B7
        foreach ($guide in @(@{ Name = 'ExchangeLogReport-Guide'; Subtitle = 'Developer guide' }, @{ Name = 'ExchangeLogReport-UserGuide'; Subtitle = 'User guide' })) {
            $markdown = [IO.File]::ReadAllText((Join-Path $script:Source "docs\$($guide.Name).md"))
            $markdown | Should -Match ('\A---\r?\ntitle: Exchange Log Report\r?\nsubtitle: ' + $guide.Subtitle + '\r?\n') -Because "$($guide.Name).md starts with its front matter"
            $markdown | Should -Match ('(?m)^version: ' + [regex]::Escape($version) + '\r?$')
            $markdown | Should -Match '(?m)^author: Nicolas Fabert\r?$'
            $html = [IO.File]::ReadAllText((Join-Path $script:Source "docs\$($guide.Name).html"))
            $html | Should -Match ([regex]::Escape("<title>Exchange Log Report - $($guide.Subtitle)</title>"))
            $html | Should -Match ([regex]::Escape("$($guide.Subtitle) $dot v$version"))
            $html | Should -Match ([regex]::Escape("Exchange Log Report $version $dot Nicolas Fabert $dot generated"))
        }
    }
    It 'regenerates the HTML guides from their Markdown sources without a difference' {
        $copy = Join-Path $TestDrive 'guides'
        [void][IO.Directory]::CreateDirectory($copy)
        foreach ($name in 'ExchangeLogReport-Guide', 'ExchangeLogReport-UserGuide') {
            Copy-Item -LiteralPath (Join-Path $script:Source "docs\$name.md") -Destination $copy
            Copy-Item -LiteralPath (Join-Path $script:Source 'docs\images') -Destination $copy -Recurse -ErrorAction SilentlyContinue
            & $script:Pwsh -NoProfile -File (Join-Path $script:RepoRoot 'tools\Build-Documentation.ps1') -Source (Join-Path $copy "$name.md") | Out-Null
            $stamp = '(?m)generated \d{4}-\d\d-\d\d \d\d:\d\d from'
            $fresh = [regex]::Replace([IO.File]::ReadAllText((Join-Path $copy "$name.html")), $stamp, 'generated from')
            $committed = [regex]::Replace([IO.File]::ReadAllText((Join-Path $script:Source "docs\$name.html")), $stamp, 'generated from')
            $fresh | Should -BeExactly $committed -Because "$name.html is generated from $name.md"
        }
    }
}
AfterAll { Remove-Module ExchangeLogReport -Force -ErrorAction SilentlyContinue }
