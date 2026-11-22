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

Describe 'Owner signature on a server without the publisher root' {
    BeforeAll {
        $verifierAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Source 'src\Test-PackageIntegrity.ps1'), [ref]$null, [ref]$null)
        $function = $verifierAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-OwnerSignatureVerdict' }, $true)
        . ([scriptblock]::Create($function.Extent.Text))
        function New-Signature([string]$Status, [string]$Signer, [bool]$Stamped = $true) {
            [pscustomobject]@{ Status = $Status; SignerCertificate = $(if ($Signer) { [pscustomobject]@{ Thumbprint = $Signer } }); TimeStamperCertificate = $(if ($Stamped) { 'stamp' }) }
        }
        function New-TestCertificate([string]$Name) {
            $key = [Security.Cryptography.RSA]::Create(2048)
            $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new("CN=$Name", $key, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
            $usage = [Security.Cryptography.OidCollection]::new(); [void]$usage.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.3'))
            $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new([Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature, $true))
            $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($usage, $false))
            $self = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(2))
            return [Security.Cryptography.X509Certificates.X509Certificate2]::new($self.Export('Pfx', 't'), 't', 'Exportable')
        }
    }

    It 'judges <Name>' -ForEach @(
        @{ Name = 'a valid, timestamped signature of the owner'; Status = 'Valid'; Signer = 'Pinned'; Stamped = $true; Chain = @(); Accepted = $true; Relaxed = $false; Reason = 'Valid' }
        @{ Name = 'a valid signature without timestamp'; Status = 'Valid'; Signer = 'Pinned'; Stamped = $false; Chain = @(); Accepted = $false; Relaxed = $false; Reason = 'NotTimestamped' }
        @{ Name = 'a valid signature of another signer'; Status = 'Valid'; Signer = 'Other'; Stamped = $true; Chain = @(); Accepted = $false; Relaxed = $false; Reason = 'UnknownSigner' }
        @{ Name = 'a valid signature without certificate'; Status = 'Valid'; Signer = ''; Stamped = $true; Chain = @(); Accepted = $false; Relaxed = $false; Reason = 'UnknownSigner' }
        @{ Name = 'a signer in lower case'; Status = 'Valid'; Signer = 'PinnedLower'; Stamped = $true; Chain = @(); Accepted = $false; Relaxed = $false; Reason = 'UnknownSigner' }
        @{ Name = 'UnknownError with a missing root'; Status = 'UnknownError'; Signer = 'Pinned'; Stamped = $true; Chain = @('UntrustedRoot'); Accepted = $true; Relaxed = $true; Reason = 'RootNotTrusted' }
        @{ Name = 'UnknownError with a missing intermediate and no revocation source'; Status = 'UnknownError'; Signer = 'Pinned'; Stamped = $true; Chain = @('PartialChain', 'RevocationStatusUnknown', 'OfflineRevocation'); Accepted = $true; Relaxed = $true; Reason = 'RootNotTrusted' }
        @{ Name = 'UnknownError with a missing intermediate only'; Status = 'UnknownError'; Signer = 'Pinned'; Stamped = $true; Chain = @('PartialChain'); Accepted = $true; Relaxed = $true; Reason = 'RootNotTrusted' }
        @{ Name = 'UnknownError with no revocation source and nothing else'; Status = 'UnknownError'; Signer = 'Pinned'; Stamped = $true; Chain = @('RevocationStatusUnknown', 'OfflineRevocation'); Accepted = $false; Relaxed = $false; Reason = 'ChainStatus' }
        @{ Name = 'NotTrusted (a certificate that an administrator distrusts) with a missing root'; Status = 'NotTrusted'; Signer = 'Pinned'; Stamped = $true; Chain = @('UntrustedRoot'); Accepted = $false; Relaxed = $false; Reason = 'NotTrusted' }
        @{ Name = 'NotTrusted with a partial chain'; Status = 'NotTrusted'; Signer = 'Pinned'; Stamped = $true; Chain = @('PartialChain'); Accepted = $false; Relaxed = $false; Reason = 'NotTrusted' }
        @{ Name = 'a missing root and an expired signer, timestamped'; Status = 'UnknownError'; Signer = 'Pinned'; Stamped = $true; Chain = @('UntrustedRoot', 'NotTimeValid'); Accepted = $true; Relaxed = $true; Reason = 'RootNotTrusted' }
        @{ Name = 'a missing root and an expired signer, not timestamped'; Status = 'UnknownError'; Signer = 'Pinned'; Stamped = $false; Chain = @('UntrustedRoot', 'NotTimeValid'); Accepted = $false; Relaxed = $false; Reason = 'NotTimestamped' }
        @{ Name = 'a missing root without timestamp'; Status = 'UnknownError'; Signer = 'Pinned'; Stamped = $false; Chain = @('UntrustedRoot'); Accepted = $false; Relaxed = $false; Reason = 'NotTimestamped' }
        @{ Name = 'a missing root and another signer'; Status = 'UnknownError'; Signer = 'Other'; Stamped = $true; Chain = @('UntrustedRoot'); Accepted = $false; Relaxed = $false; Reason = 'UnknownSigner' }
        @{ Name = 'a revoked certificate'; Status = 'UnknownError'; Signer = 'Pinned'; Stamped = $true; Chain = @('UntrustedRoot', 'Revoked'); Accepted = $false; Relaxed = $false; Reason = 'ChainStatus' }
        @{ Name = 'an explicitly distrusted certificate in the chain'; Status = 'UnknownError'; Signer = 'Pinned'; Stamped = $true; Chain = @('PartialChain', 'ExplicitDistrust'); Accepted = $false; Relaxed = $false; Reason = 'ChainStatus' }
        @{ Name = 'an invalid chain signature'; Status = 'UnknownError'; Signer = 'Pinned'; Stamped = $true; Chain = @('NotSignatureValid'); Accepted = $false; Relaxed = $false; Reason = 'ChainStatus' }
        @{ Name = 'a certificate not valid for code signing'; Status = 'UnknownError'; Signer = 'Pinned'; Stamped = $true; Chain = @('NotValidForUsage'); Accepted = $false; Relaxed = $false; Reason = 'ChainStatus' }
        @{ Name = 'an error without any chain status'; Status = 'UnknownError'; Signer = 'Pinned'; Stamped = $true; Chain = @(); Accepted = $false; Relaxed = $false; Reason = 'ChainStatus' }
        @{ Name = 'a signature that does not match the file'; Status = 'HashMismatch'; Signer = 'Pinned'; Stamped = $true; Chain = @('UntrustedRoot'); Accepted = $false; Relaxed = $false; Reason = 'HashMismatch' }
        @{ Name = 'a file without signature'; Status = 'NotSigned'; Signer = ''; Stamped = $false; Chain = @(); Accepted = $false; Relaxed = $false; Reason = 'NotSigned' }
        @{ Name = 'an incompatible file'; Status = 'Incompatible'; Signer = 'Pinned'; Stamped = $true; Chain = @('UntrustedRoot'); Accepted = $false; Relaxed = $false; Reason = 'Incompatible' }
        @{ Name = 'an unsupported format'; Status = 'NotSupportedFileFormat'; Signer = ''; Stamped = $false; Chain = @(); Accepted = $false; Relaxed = $false; Reason = 'NotSupportedFileFormat' }
        @{ Name = 'a status in another case'; Status = 'unknownerror'; Signer = 'Pinned'; Stamped = $true; Chain = @('UntrustedRoot'); Accepted = $false; Relaxed = $false; Reason = 'unknownerror' }
    ) {
        $signer = switch ($Signer) { 'Pinned' { $script:Signer } 'PinnedLower' { $script:Signer.ToLowerInvariant() } 'Other' { '1' * 40 } default { '' } }
        $verdict = Get-OwnerSignatureVerdict -Signature (New-Signature $Status $signer $Stamped) -Pinned $script:Signer -ChainFlags $Chain
        $verdict.Accepted | Should -Be $Accepted
        $verdict.Relaxed | Should -Be $Relaxed
        $verdict.Reason | Should -BeExactly $Reason
    }

    It 'accepts only a valid, time-stamped signature of the pinned signer when the chain shows no failure' {
        $accepted = foreach ($status in 'Valid', 'UnknownError', 'NotTrusted', 'HashMismatch', 'NotSigned', 'Incompatible', 'NotSupportedFileFormat') {
            foreach ($signer in $script:Signer, ('1' * 40), '') {
                foreach ($stamped in $true, $false) {
                    $verdict = Get-OwnerSignatureVerdict -Signature (New-Signature $status $signer $stamped) -Pinned $script:Signer -ChainFlags @()
                    if ($verdict.Accepted) { [pscustomobject]@{ Status = $status; Signer = $signer; Stamped = $stamped } }
                }
            }
        }
        @($accepted).Count | Should -Be 1
        $accepted.Status | Should -Be 'Valid'
        $accepted.Signer | Should -Be $script:Signer
        $accepted.Stamped | Should -BeTrue
    }

    It 'keeps one text of the decision in the verifier, the module and both entry scripts, and reads no message text' {
        $texts = foreach ($relative in 'src\Test-PackageIntegrity.ps1', 'ExchangeLogReport.psm1', 'Invoke-ExchangeLogReport.ps1', 'Database-Storage.ps1') {
            $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Source $relative), [ref]$null, [ref]$null)
            $found = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-OwnerSignatureVerdict' }, $true))
            $found.Count | Should -Be 1 -Because $relative
            $found[0].Extent.Text.Replace("`r`n", "`n")
        }
        @($texts | Select-Object -Unique).Count | Should -Be 1
        $texts[0] | Should -Not -Match 'StatusMessage|StatusInformation'
    }

    It 'reads a signature whose root is missing as accepted, and the same file with one byte changed as refused' -ForEach @('.ps1', '.psm1', '.psd1') {
        $cert = New-TestCertificate 'Exchange Log Report test signer'
        try {
            $file = Join-Path $TestDrive "signed$_"
            [IO.File]::WriteAllText($file, $(if ($_ -eq '.psd1') { "@{ Value = 'original content of the file' }`r`n" } else { "'original content of the file'`r`n" }))
            [void](Set-AuthenticodeSignature -FilePath $file -Certificate $cert)
            $signature = Get-AuthenticodeSignature -LiteralPath $file
            if ($signature.Status -eq 'Valid') { Set-ItResult -Skipped -Because 'the test certificate is trusted on this computer'; return }
            # No time stamp authority is reachable offline: the certificate stands for the stamp, which the verdict only tests for presence.
            $stamp = { param($s) [pscustomobject]@{ Status = $s.Status; SignerCertificate = $s.SignerCertificate; TimeStamperCertificate = $s.SignerCertificate } }
            [string]$signature.Status | Should -BeIn 'UnknownError', 'NotTrusted'
            $verdict = Get-OwnerSignatureVerdict -Signature (& $stamp $signature) -Pinned $cert.Thumbprint
            $verdict.Accepted | Should -BeTrue
            $verdict.Reason | Should -Be 'RootNotTrusted'
            (Get-OwnerSignatureVerdict -Signature (& $stamp $signature) -Pinned $script:Signer).Accepted | Should -BeFalse
            $bytes = [IO.File]::ReadAllBytes($file)
            $at = [Text.Encoding]::ASCII.GetString($bytes).IndexOf('original')
            $bytes[$at] = [byte][char]'0'
            [IO.File]::WriteAllBytes($file, $bytes)
            $changed = Get-AuthenticodeSignature -LiteralPath $file
            [string]$changed.Status | Should -Be 'HashMismatch'
            $verdict = Get-OwnerSignatureVerdict -Signature (& $stamp $changed) -Pinned $cert.Thumbprint
            $verdict.Accepted | Should -BeFalse
            $verdict.Reason | Should -Be 'HashMismatch'
        } finally { $cert.Dispose() }
    }

    It 'starts the verifier with one warning for the whole package, and refuses every other state' {
        $cert = New-TestCertificate 'Exchange Log Report test signer'
        $other = New-TestCertificate 'Exchange Log Report other signer'
        $saved = @{ Mode = $env:EXL_TEST_SIGNATURE; Cert = $env:EXL_TEST_CERT }
        try {
            $cerPath = Join-Path $TestDrive 'signer.cer'; [IO.File]::WriteAllBytes($cerPath, $cert.RawData)
            $otherPath = Join-Path $TestDrive 'other.cer'; [IO.File]::WriteAllBytes($otherPath, $other.RawData)
            $fixture = Join-Path $TestDrive 'relaxed'
            Copy-Item -LiteralPath $script:Template -Destination $fixture -Recurse
            # The signature of every file is given by the test: the real verifier code runs, only the Windows answer is replaced.
            $text = [IO.File]::ReadAllText((Join-Path $script:Source 'src\Test-PackageIntegrity.ps1'))
            $text = $text.Replace("`$signer = '$($script:Signer)'", "`$signer = '$($cert.Thumbprint)'")
            $shim = 'Microsoft.PowerShell.Security\Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop'
            $text.IndexOf($shim) | Should -BeGreaterThan 0
            $text = $text.Substring(0, $text.IndexOf($shim)) + 'Get-TestSignature $Path' + $text.Substring($text.IndexOf($shim) + $shim.Length)
            $text = $text.Replace('$rootNotTrusted = $false', @'
$rootNotTrusted = $false
function Get-TestSignature($Path) {
    $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($env:EXL_TEST_CERT)
    [pscustomobject]@{ Status = $env:EXL_TEST_SIGNATURE; SignerCertificate = $certificate; TimeStamperCertificate = $certificate }
}
'@)
            [IO.File]::WriteAllText((Join-Path $fixture 'src\Test-PackageIntegrity.ps1'), $text, [Text.UTF8Encoding]::new($false))
            $signer = $cert.Thumbprint
            [void](Write-Manifest $fixture)
            $run = {
                param([string]$Mode, [string]$Certificate, [switch]$Suppress)
                $env:EXL_TEST_SIGNATURE = $Mode; $env:EXL_TEST_CERT = $Certificate
                $arguments = @{ Root = $fixture }
                if ($Suppress) { $arguments.SuppressTrustWarning = $true }
                $warnings = $null
                $result = & (Join-Path $fixture 'src\Test-PackageIntegrity.ps1') @arguments -WarningVariable warnings -WarningAction SilentlyContinue
                [pscustomobject]@{ Result = $result; Warnings = @($warnings) }
            }
            # A signature that Windows reports as Valid: nothing changes.
            $valid = & $run 'Valid' $cerPath
            $valid.Result.Status | Should -Be 'Valid (files only)'
            @($valid.Result.Warnings).Count | Should -Be 0
            $valid.Warnings.Count | Should -Be 0
            # The root is missing: accepted, one warning for the signed files and the manifest together, naming the reason.
            $missing = & $run 'UnknownError' $cerPath
            $missing.Result.Status | Should -Be 'Valid (files only)'
            @($missing.Result.Warnings).Count | Should -Be 1
            $missing.Result.Warnings[0] | Should -Match 'publisher root certificate is not trusted on this server'
            $missing.Warnings.Count | Should -Be 1
            $missing.Warnings[0].Message | Should -Match 'Package integrity: The publisher root certificate is not trusted'
            $quiet = & $run 'UnknownError' $cerPath -Suppress
            $quiet.Warnings.Count | Should -Be 0
            @($quiet.Result.Warnings).Count | Should -Be 1
            # Refused in every other state.
            foreach ($mode in 'HashMismatch', 'NotSigned', 'NotTrusted', 'Incompatible', 'NotSupportedFileFormat') {
                { & $run $mode $cerPath } | Should -Throw '*expected trusted, timestamped owner signature*'
            }
            { & $run 'UnknownError' $otherPath } | Should -Throw '*owner signature*UnknownSigner*'
        } finally { $env:EXL_TEST_SIGNATURE = $saved.Mode; $env:EXL_TEST_CERT = $saved.Cert; $cert.Dispose(); $other.Dispose() }
    }

    It 'lets the verifier ignore the work file of a credential being saved, and nothing else in config' {
        Reset-Fixture
        $config = Join-Path $script:Fixture 'config'
        [void][IO.Directory]::CreateDirectory($config)
        $name = '.ExchangeLogReport.mail.credential.0123456789abcdef0123456789abcdef.tmp'
        [IO.File]::WriteAllText((Join-Path $config $name), 'work')
        (Invoke-Guard).Status | Should -Be 'Valid (files only)'
        [IO.File]::Delete((Join-Path $config $name))
        foreach ($bad in '.ExchangeLogReport.mail.credential.0123456789ABCDEF0123456789ABCDEF.tmp', '.x.0123456789abcdef0123456789abcde.tmp', 'x.0123456789abcdef0123456789abcdef.tmp', '.x.0123456789abcdef0123456789abcdef.tmp.ps1', 'run.ps1') {
            [IO.File]::WriteAllText((Join-Path $config $bad), 'work')
            { Invoke-Guard } | Should -Throw '*unexpected stable file*'
            [IO.File]::Delete((Join-Path $config $bad))
        }
        # Only in config, and never under another folder.
        [IO.File]::WriteAllText((Join-Path $script:Fixture "src\$name"), 'work')
        { Invoke-Guard } | Should -Throw '*unexpected stable file*'
    }
}

Describe 'Refusal of the package in the Windows event log' {
    BeforeAll {
        function New-EventFixture([bool]$Enabled) {
            Reset-Fixture
            $verifier = Join-Path $script:Fixture 'src\Test-PackageIntegrity.ps1'
            $text = [IO.File]::ReadAllText($verifier)
            # The event log is replaced by a file: the real verifier code runs, only the last call changes.
            $write = "[Diagnostics.EventLog]::WriteEntry('ExchangeLogReport', `"Package refused: `$Message`", [Diagnostics.EventLogEntryType]::Error, 2000)"
            $text.Contains($write) | Should -BeTrue
            $text = $text.Replace($write, 'Add-Content -LiteralPath $env:EXL_TEST_EVENT -Value "2000|Error|Package refused: $Message"').Replace("[Diagnostics.EventLog]::SourceExists('ExchangeLogReport')", '$true')
            [IO.File]::WriteAllText($verifier, $text, [Text.UTF8Encoding]::new($false))
            [void](Write-Manifest $script:Fixture)
            $config = Join-Path $script:Fixture 'config\ExchangeLogReport.config.psd1'
            [IO.File]::WriteAllText($config, "@{ Logging = @{ EventLog = `$$Enabled } }")
            Edit-Protected (Join-Path $script:Fixture 'src\Engine.Text.cs')
        }
    }

    It 'writes event 2000 when the configuration asks for events, and the refusal goes on' {
        New-EventFixture $true
        $file = Join-Path $TestDrive 'event.txt'
        $env:EXL_TEST_EVENT = $file
        try { { Invoke-Guard } | Should -Throw '*SHA256 mismatch: src\Engine.Text.cs*' } finally { $env:EXL_TEST_EVENT = $null }
        $lines = @(Get-Content -LiteralPath $file)
        $lines.Count | Should -Be 1
        $lines[0] | Should -Match '^2000\|Error\|Package refused: Package integrity: SHA256 mismatch: src\\Engine\.Text\.cs'
    }

    It 'writes nothing when the events are off, the configuration is missing or is not readable' {
        foreach ($case in 'off', 'missing', 'broken') {
            New-EventFixture ($case -eq 'off' -and $false)
            $config = Join-Path $script:Fixture 'config\ExchangeLogReport.config.psd1'
            if ($case -eq 'missing') { [IO.File]::Delete($config) }
            if ($case -eq 'broken') { [IO.File]::WriteAllText($config, '@{ Logging = ') }
            $file = Join-Path $TestDrive "event-$case.txt"
            $env:EXL_TEST_EVENT = $file
            try { { Invoke-Guard } | Should -Throw '*SHA256 mismatch*' } finally { $env:EXL_TEST_EVENT = $null }
            Test-Path -LiteralPath $file | Should -BeFalse
        }
    }

    It 'does not hide an error of the event log: a failing write is a warning, the refusal stays the error' {
        New-EventFixture $true
        $verifier = Join-Path $script:Fixture 'src\Test-PackageIntegrity.ps1'
        [IO.File]::WriteAllText($verifier, [IO.File]::ReadAllText($verifier).Replace('Add-Content -LiteralPath $env:EXL_TEST_EVENT -Value "2000|Error|Package refused: $Message"', "throw 'no right to write'"), [Text.UTF8Encoding]::new($false))
        [void](Write-Manifest $script:Fixture)
        Edit-Protected (Join-Path $script:Fixture 'src\Engine.Text.cs')
        $warnings = $null
        { & $verifier -Root $script:Fixture -WarningVariable warnings -WarningAction SilentlyContinue } | Should -Throw '*SHA256 mismatch*'
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
            # A CI runner builds its own binaries and cannot seal a release package: the case runs where the owner seals one.
            Set-ItResult -Skipped -Because 'EXL_RELEASE_PACKAGE names no sealed release package folder (Build-Standalone.ps1 -Seal)'
            return
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
            $text | Should -Match ([regex]::Escape('"%~dp0powershell\pwsh.exe" -NoLogo -NoProfile%unattended% -File "%~dp0src\Test-PackageIntegrity.ps1" -Root "%~dp0." -Distribution -SuppressTrustWarning'))
            $text | Should -Not -Match 'DevelopmentMode'
            $text | Should -Not -Match 'host\\|collector\\|tools\\Test-PackageIntegrity'
            $text.IndexOf('Test-PackageIntegrity.ps1') | Should -BeLessThan $text.LastIndexOf('pwsh.exe')
        }
        [IO.File]::ReadAllText((Join-Path $script:Source 'Run-Collector.cmd')) | Should -Match '"%~dp0Invoke-ExchangeLogReport\.ps1"'
        [IO.File]::ReadAllText((Join-Path $script:Source 'Start-Portal.cmd')) | Should -Match '"%~dp0Invoke-ExchangeLogReport\.ps1" -Mode Serve %\*'
        [IO.File]::ReadAllText((Join-Path $script:Source 'Database-Storage.cmd')) | Should -Match '"%~dp0Database-Storage\.ps1" %\*'
        # A refused package says so and, when the window was opened by a double-click, waits for a key so the message can be read.
        $refusal = '-Distribution -SuppressTrustWarning\r\n(?:rem [^\r\n]*\r\n)?if not "%errorlevel%"=="0" \(\r\n  echo The package could not be verified\. Read the message above\.\r\n  more < "%~dp0[A-Za-z-]+\.ps1:Zone\.Identifier" >nul 2>&1 && echo [^\r\n]*Unblock-File\r\n'
        [IO.File]::ReadAllText((Join-Path $script:Source 'Start-Portal.cmd')) | Should -Match ($refusal + '  pause\r\n  exit /b 1\r\n\)')
        [IO.File]::ReadAllText((Join-Path $script:Source 'Run-Collector.cmd')) | Should -Match ($refusal + '  if "%~1"=="" pause\r\n  exit /b 1\r\n\)')
        [IO.File]::ReadAllText((Join-Path $script:Source 'Database-Storage.cmd')) | Should -Match ($refusal + '  exit /b 1\r\n\)')
        Test-Path -LiteralPath (Join-Path $script:Source 'Start-ExchangeLogReportAngular.cmd') | Should -BeFalse
    }
    It 'ends with a non-zero exit code and the Unblock-File command when the verifier fails and the files carry a download mark, in a folder whose path has parentheses' -ForEach @(
        @{ Launcher = 'Run-Collector.cmd'; Entry = 'Invoke-ExchangeLogReport.ps1' }
        @{ Launcher = 'Database-Storage.cmd'; Entry = 'Database-Storage.ps1' }
        @{ Launcher = 'Start-Portal.cmd'; Entry = 'Invoke-ExchangeLogReport.ps1' }
    ) {
        $folder = Join-Path $TestDrive "launcher (x86) $($Launcher -replace '\W', '')"
        [void][IO.Directory]::CreateDirectory((Join-Path $folder 'src'))
        # The bundled runtime is stood in for by the PowerShell that runs the tests.
        [void](New-Item -ItemType Junction -Path (Join-Path $folder 'powershell') -Target $PSHOME)
        try {
            Copy-Item -LiteralPath (Join-Path $script:Source $Launcher) -Destination $folder
            [IO.File]::WriteAllText((Join-Path $folder 'src\Test-PackageIntegrity.ps1'), 'param($Root, [switch]$Distribution, [switch]$SuppressTrustWarning) "verifier ran"; exit -1')
            [IO.File]::WriteAllText((Join-Path $folder $Entry), 'param($Mode) "entry ran"; exit 0')
            $empty = Join-Path $TestDrive 'launcher.in'
            [IO.File]::WriteAllText($empty, '')
            $run = {
                $out = Join-Path $TestDrive 'launcher.out'
                $process = Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList '/c', "`"$(Join-Path $folder $Launcher)`" -Mode Status" -WindowStyle Hidden -PassThru -Wait `
                    -RedirectStandardInput $empty -RedirectStandardOutput $out
                [pscustomobject]@{ Code = $process.ExitCode; Text = [IO.File]::ReadAllText($out) }
            }
            $plain = & $run
            $plain.Code | Should -Not -Be 0
            $plain.Text | Should -Match 'verifier ran'
            $plain.Text | Should -Match 'The package could not be verified\. Read the message above\.'
            $plain.Text | Should -Not -Match 'entry ran|Unblock-File'
            Set-Content -LiteralPath (Join-Path $folder $Entry) -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3"
            $marked = & $run
            $marked.Code | Should -Not -Be 0
            $marked.Text | Should -Not -Match 'entry ran'
            $marked.Text | Should -Match ([regex]::Escape('Get-ChildItem -LiteralPath "' + $folder + '\." -Recurse -File -Force | Unblock-File'))
        } finally { [IO.Directory]::Delete((Join-Path $folder 'powershell')) }
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
        $text | Should -Match "(?s)^@\{\r\n    SchemaVersion = 1\r\n    Algorithm = 'SHA256'\r\n    SignerThumbprint = '$($script:Signer)'\r\n    Version = '3\.1\.0'\r\n    Files = @\(.*\r\n    \)\r\n    DistributionFiles = @\(.*\r\n    \)\r\n\}\r\n$"
        $paths = @($script:Entries.Path)
        $paths | Should -Be @($paths | Sort-Object { $_ } -CaseSensitive)
    }
}

Describe 'Documentation standard' {
    It 'keeps the root presentation, exact disclaimer, SECURITY and local links aligned with the documentation standard' {
        $text = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'README.md')).Replace("`r`n", "`n")
        $headings = @([regex]::Matches($text, '(?m)^## ([^\n]+)$') | ForEach-Object { $_.Groups[1].Value })
        $headings | Should -Be @('Why', 'Get started', 'How it works', 'Noise removed before storage', 'Sessions and messages', 'Reports', 'Requirements',
            'Quick start', 'Package layout', 'Documentation', 'Tests', 'Data handling', 'License', 'Disclaimer')
        $steps = @([regex]::Matches($text, '(?m)^### ([^\n]+)$') | ForEach-Object { $_.Groups[1].Value })
        $steps | Should -Be @('Set up once · 1 to 4', 'A · Recurring reporting · 5 to 7', 'B · Troubleshooting · 5 to 7', 'C · Investigate in the browser · 5 to 7')
        $text | Should -Match 'Nicolas Fabert'
        $text | Should -Match '\*\*Version:\*\* 3\.1\.0'
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
            Should -BeExactly '39BE96855A2F58818E662B98629421FBE912454FE4A08A599295D4B76365A609'
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
        $text | Should -Match '\*\*Version:\*\* 3\.1\.0'
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
Describe 'Reparse points are judged by their tag' {
    # A symbolic link needs a privilege that an ordinary account may not hold; known at discovery, for -Skip.
    $canSymlink = $false
    $probeTarget = Join-Path ([IO.Path]::GetTempPath()) ('exl-symlink-probe-' + [guid]::NewGuid().ToString('N'))
    try {
        [void](New-Item -ItemType SymbolicLink -Path $probeTarget -Target $env:SystemRoot -ErrorAction Stop)
        $canSymlink = $true
        (Get-Item -LiteralPath $probeTarget -Force).Delete()
    } catch { $canSymlink = $false }
    BeforeAll {
        $script:HelperNames = 'Get-PathReparseTag', 'Test-ReparseTagAllowed', 'Get-RefusedReparseTag', 'Test-CloudReadErrorCode', 'Get-ReadFailureCode'
        $verifierAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Source 'src\Test-PackageIntegrity.ps1'), [ref]$null, [ref]$null)
        foreach ($name in $script:HelperNames) {
            $function = $verifierAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name }, $true)
            if ($null -eq $function) { throw "The verifier function $name is missing." }
            . ([scriptblock]::Create($function.Extent.Text))
        }
        # The verifier of a fixture, whose reparse tag reader is replaced by a fixed tag, and whose manifest is written again.
        function Set-FixtureVerifier([string]$Search, [string]$Replace) {
            $verifier = Join-Path $script:Fixture 'src\Test-PackageIntegrity.ps1'
            $text = [IO.File]::ReadAllText($verifier)
            if (-not $text.Contains($Search)) { throw "The anchor was not found in the verifier: $Search" }
            [IO.File]::WriteAllText($verifier, $text.Replace($Search, $Replace), [Text.UTF8Encoding]::new($false))
            $signer = $script:Signer; $product = $script:Product; $binaryFolders = @('powershell', 'sqlite-tools')
            [void](Write-Manifest $script:Fixture)
        }
        function Set-FixtureTag([uint32]$Tag) {
            $literal = '0x' + $Tag.ToString('X8') + 'u'
            Set-FixtureVerifier "Assert-PlainPath `$rootPath `$true`r`n" ('function Get-PathReparseTag { param($Path) [uint32]' + $literal + " }`r`nAssert-PlainPath `$rootPath `$true`r`n")
        }
        # templates\ becomes a junction to a copy of itself: a directory that is a reparse point and whose files keep their bytes.
        function New-TemplatesJunction {
            $link = Join-Path $script:Fixture 'templates'
            $copy = Join-Path $TestDrive ('templates-copy-{0:D4}' -f $script:FixtureNumber)
            Copy-Item -LiteralPath $link -Destination $copy -Recurse
            Remove-Item -LiteralPath $link -Recurse -Force
            [void](New-Item -ItemType Junction -Path $link -Target $copy)
            [pscustomobject]@{ Link = $link; Target = $copy }
        }
    }
    BeforeEach { Reset-Fixture }

    It 'judges the tag <Name> (0x<Tag>): accepted is <Accepted>' -ForEach @(
        @{ Name = 'symbolic link'; Tag = 'A000000C'; Accepted = $false }
        @{ Name = 'junction and mount point'; Tag = 'A0000003'; Accepted = $false }
        @{ Name = 'OneDrive cloud files'; Tag = '9000001A'; Accepted = $true }
        @{ Name = 'OneDrive cloud files, variant 1'; Tag = '9000101A'; Accepted = $true }
        @{ Name = 'OneDrive cloud files, variant 2'; Tag = '9000201A'; Accepted = $true }
        @{ Name = 'OneDrive cloud files, variant 7'; Tag = '9000701A'; Accepted = $true }
        @{ Name = 'OneDrive cloud files, variant F'; Tag = '9000F01A'; Accepted = $true }
        @{ Name = 'data deduplication'; Tag = '80000013'; Accepted = $true }
        @{ Name = 'WOF (CompactOS)'; Tag = '80000017'; Accepted = $true }
        @{ Name = 'a cloud tag that carries the name-surrogate bit'; Tag = 'B000001A'; Accepted = $false }
        @{ Name = 'an unknown tag with the name-surrogate bit (WSL symbolic link)'; Tag = 'A000001D'; Accepted = $false }
        @{ Name = 'the name-surrogate bit alone'; Tag = '20000000'; Accepted = $false }
        @{ Name = 'all bits set'; Tag = 'FFFFFFFF'; Accepted = $false }
        @{ Name = 'an unknown tag without the bit (app execution alias)'; Tag = '8000001B'; Accepted = $false }
        @{ Name = 'an unknown tag without the bit (hierarchical storage)'; Tag = 'C0000004'; Accepted = $false }
        @{ Name = 'an unknown Microsoft tag'; Tag = '80000023'; Accepted = $false }
        @{ Name = 'a cloud tag with another low byte'; Tag = '9000001B'; Accepted = $false }
        @{ Name = 'a cloud tag with a variant in the wrong nibble'; Tag = '9000011A'; Accepted = $false }
        @{ Name = 'a cloud tag with another high word'; Tag = '9001001A'; Accepted = $false }
        @{ Name = 'a deduplication tag with a variant'; Tag = '80001013'; Accepted = $false }
        @{ Name = 'a tag that is not set'; Tag = '00000000'; Accepted = $false }
        @{ Name = 'a non-Microsoft tag'; Tag = '00000011'; Accepted = $false }
    ) {
        Test-ReparseTagAllowed ([Convert]::ToUInt32($Tag, 16)) | Should -Be $Accepted
    }
    It 'reads no tag from a normal file or folder, and refuses to guess for a path that does not exist' {
        $file = Join-Path $script:Fixture 'README.md'
        Get-PathReparseTag $file | Should -BeNullOrEmpty
        Get-PathReparseTag $script:Fixture | Should -BeNullOrEmpty
        Get-RefusedReparseTag (Get-Item -LiteralPath $file -Force) | Should -BeNullOrEmpty
        { Get-PathReparseTag (Join-Path $script:Fixture 'missing.txt') } | Should -Throw -ExpectedMessage '*Windows error 2*'
    }
    It 'reads the tag of a junction without opening its target, from a path of more than 260 characters too' {
        $target = Join-Path $TestDrive 'tag-target'
        [void][IO.Directory]::CreateDirectory($target)
        $link = Join-Path $TestDrive 'tag-junction'
        [void](New-Item -ItemType Junction -Path $link -Target $target)
        try {
            '{0:X8}' -f (Get-PathReparseTag $link) | Should -Be 'A0000003'
            Get-RefusedReparseTag (Get-Item -LiteralPath $link -Force) | Should -Be 'A0000003'
            $deep = Join-Path $TestDrive ((1..4 | ForEach-Object { 'd' * 70 }) -join '\')
            [void][IO.Directory]::CreateDirectory('\\?\' + $deep)
            $deepLink = Join-Path $deep 'deep-junction'
            [void](New-Item -ItemType Junction -Path ('\\?\' + $deepLink) -Target $target)
            $deepLink.Length | Should -BeGreaterThan 260
            '{0:X8}' -f (Get-PathReparseTag $deepLink) | Should -Be 'A0000003'
            [IO.Directory]::Delete('\\?\' + $deepLink)
        }
        finally { (Get-Item -LiteralPath $link -Force).Delete() }
    }
    It 'reads the tag of a symbolic link to a file and to a folder' -Skip:(-not $canSymlink) {
        $target = Join-Path $TestDrive 'symlink-target'
        [void][IO.Directory]::CreateDirectory($target)
        $targetFile = Join-Path $target 'file.txt'
        Set-Content -LiteralPath $targetFile -Value 'x'
        $fileLink = Join-Path $TestDrive 'file-link'
        $folderLink = Join-Path $TestDrive 'folder-link'
        [void](New-Item -ItemType SymbolicLink -Path $fileLink -Target $targetFile)
        [void](New-Item -ItemType SymbolicLink -Path $folderLink -Target $target)
        try {
            '{0:X8}' -f (Get-PathReparseTag $fileLink) | Should -Be 'A000000C'
            '{0:X8}' -f (Get-PathReparseTag $folderLink) | Should -Be 'A000000C'
        }
        finally { (Get-Item -LiteralPath $fileLink -Force).Delete(); (Get-Item -LiteralPath $folderLink -Force).Delete() }
    }
    It 'keeps one text of the three tag functions in the verifier, the module and both entry scripts' {
        foreach ($name in 'Get-PathReparseTag', 'Test-ReparseTagAllowed', 'Get-RefusedReparseTag') {
            $texts = foreach ($relative in 'src\Test-PackageIntegrity.ps1', 'ExchangeLogReport.psm1', 'Invoke-ExchangeLogReport.ps1', 'Database-Storage.ps1') {
                $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Source $relative), [ref]$null, [ref]$null)
                $found = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name }, $true))
                $found.Count | Should -Be 1 -Because "$name in $relative"
                $found[0].Extent.Text.Replace("`r`n", "`n")
            }
            @($texts | Select-Object -Unique).Count | Should -Be 1 -Because $name
        }
    }
    It 'judges a path by its tag and not by the bare ReparsePoint attribute, in the four places that judge one' {
        foreach ($relative in 'src\Test-PackageIntegrity.ps1', 'ExchangeLogReport.psm1', 'Invoke-ExchangeLogReport.ps1', 'Database-Storage.ps1') {
            $text = [IO.File]::ReadAllText((Join-Path $script:Source $relative))
            ($text -split "`r?`n" | Where-Object { $_ -match '\$\w+\.Attributes -band \[IO\.FileAttributes\]::ReparsePoint' -and $_ -notmatch '\$Item\.Attributes' }).Count | Should -Be 0 -Because $relative
        }
    }

    It 'refuses a package whose ancestor folder is a junction, and names the tag' {
        $via = Join-Path $TestDrive 'via-junction'
        [void](New-Item -ItemType Junction -Path $via -Target $TestDrive)
        try {
            $linked = Join-Path $via (Split-Path $script:Fixture -Leaf)
            { & (Join-Path $linked 'src\Test-PackageIntegrity.ps1') -Root $linked 3> $null } | Should -Throw -ExpectedMessage '*reparse-point ancestor that is not accepted (tag 0xA0000003)*'
        }
        finally { (Get-Item -LiteralPath $via -Force).Delete() }
    }
    It 'refuses a junction in the package tree, whatever it points to' {
        $link = New-TemplatesJunction
        try { { Invoke-Guard } | Should -Throw -ExpectedMessage '*reparse-point ancestor that is not accepted (tag 0xA0000003)*templates*' }
        finally { (Get-Item -LiteralPath $link.Link -Force).Delete() }
    }
    It 'refuses a symbolic link to a file and to a folder of the package' -Skip:(-not $canSymlink) {
        $readme = Join-Path $script:Fixture 'README.md'
        $copy = Join-Path $TestDrive 'README.copy'
        Copy-Item -LiteralPath $readme -Destination $copy
        Remove-Item -LiteralPath $readme
        [void](New-Item -ItemType SymbolicLink -Path $readme -Target $copy)
        try { { Invoke-Guard } | Should -Throw -ExpectedMessage '*reparse point that is not accepted (tag 0xA000000C)*README.md*' }
        finally { (Get-Item -LiteralPath $readme -Force).Delete() }
        Reset-Fixture
        $link = Join-Path $script:Fixture 'docs'
        $folderCopy = Join-Path $TestDrive 'docs.copy'
        Copy-Item -LiteralPath $link -Destination $folderCopy -Recurse
        Remove-Item -LiteralPath $link -Recurse -Force
        [void](New-Item -ItemType SymbolicLink -Path $link -Target $folderCopy)
        try { { Invoke-Guard } | Should -Throw -ExpectedMessage '*reparse-point ancestor that is not accepted (tag 0xA000000C)*docs*' }
        finally { (Get-Item -LiteralPath $link -Force).Delete() }
    }
    It 'accepts a normal package' {
        (Invoke-Guard).Status | Should -Be 'Valid (files only)'
    }
    It 'accepts a folder whose tag is <Name> and verifies the files in it' -ForEach @(
        @{ Name = 'a OneDrive cloud placeholder'; Tag = 0x9000001Au }
        @{ Name = 'a OneDrive cloud placeholder, variant F'; Tag = 0x9000F01Au }
        @{ Name = 'a deduplicated item'; Tag = 0x80000013u }
        @{ Name = 'a WOF item'; Tag = 0x80000017u }
    ) {
        Set-FixtureTag $Tag
        $link = New-TemplatesJunction
        try { (Invoke-Guard).Status | Should -Be 'Valid (files only)' }
        finally { (Get-Item -LiteralPath $link.Link -Force).Delete() }
    }
    It 'refuses a folder whose tag is <Name>, even when the tag looks harmless' -ForEach @(
        @{ Name = 'a symbolic link'; Tag = 0xA000000Cu; Text = 'A000000C' }
        @{ Name = 'a junction'; Tag = 0xA0000003u; Text = 'A0000003' }
        @{ Name = 'unknown with the name-surrogate bit'; Tag = 0xA000001Du; Text = 'A000001D' }
        @{ Name = 'unknown without it'; Tag = 0x8000001Bu; Text = '8000001B' }
        @{ Name = 'a cloud tag with the surrogate bit'; Tag = 0xB000001Au; Text = 'B000001A' }
    ) {
        Set-FixtureTag $Tag
        $link = New-TemplatesJunction
        try { { Invoke-Guard } | Should -Throw -ExpectedMessage "*reparse-point ancestor that is not accepted (tag 0x$Text)*templates*" }
        finally { (Get-Item -LiteralPath $link.Link -Force).Delete() }
    }
    It 'refuses a folder that holds the package when its ancestor has a name-surrogate tag, and accepts one with a cloud tag' {
        $via = Join-Path $TestDrive 'via-cloud'
        [void](New-Item -ItemType Junction -Path $via -Target $TestDrive)
        try {
            foreach ($case in @(@{ Tag = 0x9000001Au; Accepted = $true }, @{ Tag = 0xA000000Cu; Accepted = $false })) {
                Reset-Fixture
                Set-FixtureTag $case.Tag
                $linked = Join-Path $via (Split-Path $script:Fixture -Leaf)
                $run = { & (Join-Path $linked 'src\Test-PackageIntegrity.ps1') -Root $linked 3> $null }
                if ($case.Accepted) { (& $run).Status | Should -Be 'Valid (files only)' }
                else { $run | Should -Throw -ExpectedMessage '*reparse-point ancestor that is not accepted (tag 0xA000000C)*' }
            }
        }
        finally { (Get-Item -LiteralPath $via -Force).Delete() }
    }
    It 'still refuses a changed file inside an accepted reparse point: the SHA256 decides' {
        Set-FixtureTag 0x9000001Au
        $link = New-TemplatesJunction
        try {
            (Invoke-Guard).Status | Should -Be 'Valid (files only)'
            [IO.File]::AppendAllText((Join-Path $link.Target 'Report.template.js'), "`r`n// synchronised change")
            { Invoke-Guard } | Should -Throw -ExpectedMessage '*SHA256 mismatch: templates\Report.template.js*'
        }
        finally { (Get-Item -LiteralPath $link.Link -Force).Delete() }
    }
    It 'accepts a file that Windows compressed with WOF (CompactOS) and keeps judging its bytes' {
        $readme = Join-Path $script:Fixture 'README.md'
        $null = & compact.exe /C /EXE:XPRESS4K /F $readme
        $compacted = $LASTEXITCODE -eq 0
        (Invoke-Guard).Status | Should -Be 'Valid (files only)'
        $tag = if ($compacted) { Get-PathReparseTag $readme }
        if ($null -eq $tag) { Set-ItResult -Skipped -Because 'this Windows build does not expose a reparse tag on a compacted file'; return }
        '{0:X8}' -f $tag | Should -Be '80000017'
        [IO.File]::WriteAllText($readme, ('# another content' * 2000))
        $null = & compact.exe /C /EXE:XPRESS4K /F $readme
        '{0:X8}' -f (Get-PathReparseTag $readme) | Should -Be '80000017'
        { Invoke-Guard } | Should -Throw -ExpectedMessage '*SHA256 mismatch: README.md*'
    }

    It 'maps the Windows error <Code> (<Name>) of a read to the cloud message: <Mapped>' -ForEach @(
        @{ Code = 362; Name = 'ERROR_CLOUD_FILE_PROVIDER_NOT_RUNNING'; Mapped = $true }
        @{ Code = 369; Name = 'ERROR_FILE_SYSTEM_VIRTUALIZATION_UNAVAILABLE'; Mapped = $true }
        @{ Code = 386; Name = 'ERROR_CLOUD_FILE_AUTHENTICATION_FAILED'; Mapped = $true }
        @{ Code = 388; Name = 'ERROR_CLOUD_FILE_NETWORK_UNAVAILABLE'; Mapped = $true }
        @{ Code = 389; Name = 'ERROR_CLOUD_FILE_UNSUCCESSFUL'; Mapped = $true }
        @{ Code = 393; Name = 'ERROR_CLOUD_FILE_REQUEST_ABORTED'; Mapped = $true }
        @{ Code = 398; Name = 'ERROR_CLOUD_FILE_REQUEST_CANCELED'; Mapped = $true }
        @{ Code = 404; Name = 'ERROR_CLOUD_FILE_PROVIDER_TERMINATED'; Mapped = $true }
        @{ Code = 426; Name = 'ERROR_CLOUD_FILE_REQUEST_TIMEOUT'; Mapped = $true }
        @{ Code = 395; Name = 'ERROR_CLOUD_FILE_ACCESS_DENIED'; Mapped = $false }
        @{ Code = 5; Name = 'ERROR_ACCESS_DENIED'; Mapped = $false }
        @{ Code = 32; Name = 'ERROR_SHARING_VIOLATION'; Mapped = $false }
        @{ Code = 2; Name = 'ERROR_FILE_NOT_FOUND'; Mapped = $false }
        @{ Code = 0; Name = 'no error'; Mapped = $false }
    ) {
        Test-CloudReadErrorCode $Code | Should -Be $Mapped
    }
    It 'reads the Windows error from a Win32 HRESULT, a Win32Exception or an inner exception, and ignores the message text' {
        Get-ReadFailureCode ([IO.IOException]::new('any text, in any language', [int]0x80070184)) | Should -Be 388
        Get-ReadFailureCode ([IO.IOException]::new('Le fournisseur de synchronisation du cloud n''a pas pu', [int]0x8007016A)) | Should -Be 362
        Get-ReadFailureCode ([ComponentModel.Win32Exception]::new(426)) | Should -Be 426
        Get-ReadFailureCode ([InvalidOperationException]::new('outer', [IO.IOException]::new('inner', [int]0x80070185))) | Should -Be 389
        Get-ReadFailureCode ([InvalidOperationException]::new('ERROR_CLOUD_FILE_NETWORK_UNAVAILABLE 388')) | Should -Be 0
        Get-ReadFailureCode ([IO.IOException]::new('not a Win32 HRESULT', [int]0x80004005)) | Should -Be 0
        Get-ReadFailureCode $null | Should -Be 0
    }
    It 'names a cloud file that cannot be downloaded, with the way out, when its read fails with <Code>' -ForEach @(
        @{ Code = 388; HResult = [int]0x80070184 }
        @{ Code = 362; HResult = [int]0x8007016A }
        @{ Code = 426; HResult = [int]0x800701AA }
    ) {
        Set-FixtureVerifier 'try { (Microsoft.PowerShell.Utility\Get-FileHash' "try { if (`$Path -like '*\README.md') { throw [IO.IOException]::new('texte localise', $HResult) }; (Microsoft.PowerShell.Utility\Get-FileHash"
        { Invoke-Guard } | Should -Throw -ExpectedMessage "*This cloud file (OneDrive) is not downloaded*Windows error $Code*README.md*Reconnect this computer to the network*outside OneDrive*"
    }
    It 'leaves the other read failures as they are' {
        Set-FixtureVerifier 'try { (Microsoft.PowerShell.Utility\Get-FileHash' "try { if (`$Path -like '*\README.md') { throw [IO.IOException]::new('texte localise', [int]0x80070005) }; (Microsoft.PowerShell.Utility\Get-FileHash"
        $message = try { Invoke-Guard; '' } catch { $_.Exception.Message }
        $message | Should -Match 'texte localise'
        $message | Should -Not -Match 'OneDrive'
    }
}
AfterAll { Remove-Module ExchangeLogReport -Force -ErrorAction SilentlyContinue }
