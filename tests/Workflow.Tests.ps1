#Requires -Version 7.4
BeforeAll {
    Set-StrictMode -Version Latest
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:Workflows = Join-Path $script:Root '.github\workflows'
    $script:Ci = Get-Content -LiteralPath (Join-Path $script:Workflows 'ci.yml') -Raw | ConvertFrom-Json
    $script:Codeql = Get-Content -LiteralPath (Join-Path $script:Workflows 'codeql.yml') -Raw | ConvertFrom-Json
    $script:Attestation = Get-Content -LiteralPath (Join-Path $script:Workflows 'attest-release.yml') -Raw
}

Describe 'Public workflow contracts' {
    It 'declares the public release identity' {
        $product = Get-Content -LiteralPath (Join-Path $script:Root 'product.json') -Raw | ConvertFrom-Json
        $product.visibility | Should -BeExactly 'public'
        $product.status | Should -BeExactly 'release'
        $product.name | Should -BeExactly 'ExchangeLogReport'
        $product.version | Should -BeExactly '3.0.0'
    }

    It 'declares the actual package runtime and existing validation paths without inventing required checks' {
        $profile = Get-Content -LiteralPath (Join-Path $script:Root '.github\ci.json') -Raw | ConvertFrom-Json
        $profile.runtimeRoot | Should -BeExactly 'package'
        $profile.testMode | Should -BeExactly 'pester'
        $profile.packageBuilder | Should -BeExactly 'tools/Build-Standalone.ps1'
        $profile.packageEntry | Should -BeExactly 'Invoke-ExchangeLogReport.ps1'
        foreach ($path in @($profile.tests) + @($profile.packageBuilder, "$($profile.runtimeRoot)/$($profile.packageEntry)")) {
            Test-Path -LiteralPath (Join-Path $script:Root $path.Replace('/', '\')) | Should -BeTrue -Because $path
        }
        # The two -PackageRoot suites and the legacy comparison need a built package or a measured baseline, the browser suite (Serve.Page, tag Browser)
        # needs Microsoft Edge: they run on demand.
        $onDemand = @('Serve.Package.Tests.ps1', 'Storage.Package.Tests.ps1', 'LegacyComparison.Tests.ps1', 'Serve.Page.Tests.ps1')
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $script:Root 'tests') -Filter '*.Tests.ps1' -File | Where-Object { $_.Name -cnotin $onDemand }) {
            $profile.tests | Should -Contain ('tests/' + $file.Name)
        }
    }

    It 'uses only the existing four reviewed full action SHAs' {
        $allowed = @{
            'actions/checkout' = '11d5960a326750d5838078e36cf38b85af677262'
            'actions/upload-artifact' = 'ea165f8d65b6e75b540449e92b4886f43607fa02'
            'github/codeql-action/init' = '24c54180a607b1449ed407dd24f251e4e9147c8d'
            'github/codeql-action/analyze' = '24c54180a607b1449ed407dd24f251e4e9147c8d'
            'actions/attest' = '1e69f48acb82d1966a394da916b4c1698aa569d6'
        }
        $text = (Get-ChildItem -LiteralPath $script:Workflows -Filter '*.yml' -File |
            ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
        $uses = [regex]::Matches($text, '(?m)["'']?uses["'']?\s*:\s*["'']?([^@\s"'']+)@([^\s"'']+)')
        $uses.Count | Should -BeGreaterThan 0
        foreach ($use in $uses) {
            $allowed.ContainsKey($use.Groups[1].Value) | Should -BeTrue
            $use.Groups[2].Value | Should -BeExactly $allowed[$use.Groups[1].Value]
        }
        $text | Should -Not -Match 'pull_request_target|secrets\.'
    }

    It 'limits CI to the intended public repository with read-only permissions' {
        $script:Ci.permissions.contents | Should -Be 'read'
        @($script:Ci.permissions.PSObject.Properties).Count | Should -Be 1
        $script:Ci.jobs.validate.'runs-on' | Should -Be 'windows-2022'
        $script:Ci.jobs.validate.if | Should -Match "github.repository_owner == 'Nico77600'"
        $script:Ci.jobs.validate.if | Should -Match "github.repository == 'Nico77600/ExchangeLogReport'"
        $script:Ci.jobs.validate.if | Should -Match 'github.event.repository.private == false'
        ($script:Ci.jobs.validate.steps | Where-Object { $_.PSObject.Properties['uses'] -and $_.uses -like 'actions/checkout@*' }).with.'persist-credentials' | Should -BeFalse
    }

    It 'builds the portal from the report template only: no Node.js, npm or Angular step, tool or source' {
        $validate = $script:Ci.jobs.validate
        $validate.PSObject.Properties.Name | Should -Not -Contain 'env'
        $steps = @($validate.steps)
        $text = ($steps | ConvertTo-Json -Depth 8)
        $text | Should -Not -Match '(?i)\bnpm\b|\bnode\b|angular|frontend|NG_CLI|working-directory'
        @($steps | Where-Object { $_.PSObject.Properties['run'] } | ForEach-Object run)[0] | Should -Match 'Initialize-CIModules\.ps1'
        Test-Path -LiteralPath (Join-Path $script:Root '.github\scripts\Test-NodeEngine.ps1') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Root 'frontend') | Should -BeFalse
        foreach ($name in 'package.json', 'package-lock.json', 'dependabot.yml') {
            @(Get-ChildItem -LiteralPath $script:Root -Filter $name -File -Recurse -Depth 2 -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notlike '*\artifacts\*' }).Count | Should -Be 0 -Because $name
        }
    }

    It 'creates the new module destination before the pinned downloads without executing them in this regression' {
        $initializer = [IO.File]::ReadAllText((Join-Path $script:Root '.github\scripts\Initialize-CIModules.ps1'))
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($initializer, [ref]$tokens, [ref]$errors)
        $create = @($ast.EndBlock.Statements | Where-Object {
            $_.Extent.Text -ceq '[void][IO.Directory]::CreateDirectory($Destination)'
        })
        $download = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Save-Module'
        }, $true))
        $create.Count | Should -Be 1
        $download.Count | Should -Be 2
        $create[0].Extent.StartOffset | Should -BeLessThan $download[0].Extent.StartOffset
        $initializer.IndexOf('if (Test-Path -LiteralPath $Destination)') |
            Should -BeLessThan $create[0].Extent.StartOffset
        $download[0].Extent.Text |
            Should -BeExactly 'Save-Module -Name Pester -RequiredVersion 6.1.0 -Repository PSGallery -Path $Destination -ErrorAction Stop'
        $download[1].Extent.Text |
            Should -BeExactly 'Save-Module -Name PSScriptAnalyzer -RequiredVersion 1.25.0 -Repository PSGallery -Path $Destination -ErrorAction Stop'
        $Destination = Join-Path $TestDrive 'new-module-parent\ci-modules'
        Test-Path -LiteralPath $Destination | Should -BeFalse
        . ([scriptblock]::Create($create[0].Extent.Text))
        Test-Path -LiteralPath $Destination -PathType Container | Should -BeTrue
    }

    It 'analyzes, builds and verifies the standalone package without publishing it' {
        $runs = @($script:Ci.jobs.validate.steps | Where-Object { $_.PSObject.Properties['run'] } | ForEach-Object run) -join "`n"
        $runs | Should -Not -Match 'dotnet (build|publish)'
        $runs | Should -Match 'Invoke-CI\.ps1 -Stage Analyze'
        $runs | Should -Match 'Build-Standalone\.ps1'
        $runs | Should -Match '-Unsigned'
        $runs | Should -Match "Join-Path .package 'src\\Test-PackageIntegrity\.ps1'"
        $runs | Should -Match '-Root \$package -DevelopmentMode'
        $runs | Should -Not -Match 'git push|gh release|npm publish'
        $upload = $script:Ci.jobs.validate.steps | Where-Object { $_.PSObject.Properties['uses'] -and $_.uses -like 'actions/upload-artifact@*' }
        $upload.with.path | Should -Not -Match '\*\*|\.zip|\.sqlite|\.log|ready'
        $testRunner = Get-Content -LiteralPath (Join-Path $script:Root '.github\scripts\Invoke-CITests.ps1') -Raw
        $testRunner | Should -Match "Join-Path .root 'tests'"
        $testRunner | Should -Match "LiteralPath .tests -Filter 'Serve\*\.Tests\.ps1'"
        $testRunner | Should -Match "'PackageIntegrity', 'Workflow'"
        $testRunner | Should -Match "Storage\.Tests\.ps1"
        $testRunner | Should -Match 'New-PesterContainer -Path'
        $testRunner | Should -Match 'tests\\LegacyComparison\.Tests\.ps1'
        $testRunner | Should -Match 'src\\Test-PackageIntegrity\.ps1'
        $testRunner | Should -Match 'PSVersionTable.PSVersion.ToString\(\)'
        $testRunner | Should -Match 'product.powerShell.version'
        $testRunner | Should -Match 'GetFullPath\(\$PSHOME\)'
        $runs | Should -Match "Join-Path .package 'powershell\\pwsh\.exe'"
        $runs | Should -Match 'Invoke-CITests.ps1 -PackageRoot \$package'
        $steps = @($script:Ci.jobs.validate.steps)
        $packageStep = $steps | Where-Object name -EQ 'Build and verify the standalone package'
        $testStep = $steps | Where-Object name -Like '*tests under the packaged runtime'
        $analyzeStep = $steps | Where-Object name -EQ 'Analyze PowerShell sources'
        [array]::IndexOf($steps, $analyzeStep) | Should -BeGreaterOrEqual 0
        [array]::IndexOf($steps, $packageStep) | Should -BeLessThan ([array]::IndexOf($steps, $testStep))
    }

    It 'keeps the module downloads exact and the package free of the removed host' {
        $initializer = [IO.File]::ReadAllText((Join-Path $script:Root '.github\scripts\Initialize-CIModules.ps1'))
        $initializer | Should -Match 'GITHUB_ACTIONS'
        $builder = [IO.File]::ReadAllText((Join-Path $script:Root 'tools\Build-Standalone.ps1'))
        $builder | Should -Not -Match 'dotnet'
        $builder | Should -Match "Join-Path \`$root 'package'"
        $builder | Should -Not -Match 'collector\\|host\\'
        $builder | Should -Not -Match '(?i)frontend|npm|angular|\bweb\b'
        $profile = Get-Content -LiteralPath (Join-Path $script:Root '.github\ci.json') -Raw | ConvertFrom-Json
        $profile.tests | Should -Contain 'tests/Storage.Tests.ps1'
    }

    It 'excludes development-only paths from the GitHub source archive and keeps the package in it' {
        $lines = @(Get-Content -LiteralPath (Join-Path $script:Root '.gitattributes') | Where-Object { $_ -match '\bexport-ignore\b' })
        $paths = @($lines | ForEach-Object { ($_ -split '\s+')[0] })
        $paths | Should -Be @('.github/', '.gitattributes', '.gitignore', 'AGENTS.md', 'lib/', 'tests/', 'tools/')
        $paths | Should -Not -Contain 'package/'
        foreach ($kept in 'README.md', 'LICENSE', 'SECURITY.md', 'CHANGELOG.md', 'PROVENANCE.md', 'product.json') { $paths | Should -Not -Contain $kept }
        $attributes = Get-Content -LiteralPath (Join-Path $script:Root '.gitattributes') -Raw
        $attributes | Should -Match '(?m)^package/docs/\*\.html\s+linguist-generated'
        $attributes | Should -Match '(?m)^package/lib/\*\*\s+linguist-vendored'
    }
    It 'keeps CodeQL advisory, limited to the intended repositories, and covers C#, the report page script and workflows' {
        @($script:Codeql.on.PSObject.Properties.Name) | Should -Be @('pull_request', 'push', 'schedule', 'workflow_dispatch')
        $script:Codeql.name | Should -Match 'advisory'
        $script:Codeql.jobs.analyze.if | Should -Match 'Nico77600/ExchangeLogReport'
        $script:Codeql.jobs.analyze.if | Should -Match "github.ref == 'refs/heads/main'"
        $languages = @($script:Codeql.jobs.analyze.strategy.matrix.include.language)
        $languages | Should -Contain 'csharp'
        $languages | Should -Contain 'javascript-typescript'
        $languages | Should -Contain 'actions'
        $javascript = @($script:Codeql.jobs.analyze.strategy.matrix.include | Where-Object language -EQ 'javascript-typescript')
        $javascript.Count | Should -Be 1
        @($javascript[0].config.paths) | Should -Be @('package/templates')
        @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'package\templates') -Filter '*.js' -File).Count | Should -BeGreaterThan 0
        ($script:Codeql.jobs.analyze.steps | Where-Object { $_.PSObject.Properties['uses'] -and $_.uses -like 'actions/checkout@*' }).with.'persist-credentials' | Should -BeFalse
        $script:Codeql.jobs.analyze.permissions.'security-events' | Should -Be 'write'
    }
    It 'requires actual stable release ZIPs and never builds or checks out attestation subjects' {
        $script:Attestation | Should -Match "github.repository_owner == 'Nico77600'"
        $script:Attestation | Should -Match "github.repository == 'Nico77600/ExchangeLogReport'"
        $script:Attestation | Should -Match 'github.event.repository.private == false'
        $script:Attestation | Should -Match 'repository_metadata\.get\("private"\) is not False'
        $script:Attestation | Should -Match 'github.event.repository.default_branch'
        $script:Attestation | Should -Match 'no source archive fallback'
        $script:Attestation | Should -Match 'Release ZIP assets changed during download'
        $script:Attestation | Should -Match 'The release tag changed during verification'
        $script:Attestation | Should -Match "subject-path: 'dist/\*\.zip'"
        $script:Attestation | Should -Not -Match 'uses: actions/checkout|dotnet build|npm ci|gh release create|gh release upload'
    }

    It 'syntax-parses every CI PowerShell helper without executing it' {
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $script:Root '.github\scripts') -Filter '*.ps1' -File) {
            $tokens = $null
            $errors = $null
            [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
            @($errors).Count | Should -Be 0 -Because $file.Name
        }
    }

    It 'refuses to run backend tests outside the newly packaged configured runtime' {
        {
            & (Join-Path $script:Root '.github\scripts\Invoke-CITests.ps1') -PackageRoot (Join-Path $TestDrive 'not-a-package')
        } | Should -Throw '*newly packaged, configured x64 PowerShell runtime*'
    }

    It 'accepts only complete hash-verified packages with the report page in synthetic in-memory ZIPs' {
        $python = Get-Command python -ErrorAction Stop
        $test = @'
import hashlib
import io
import json
from pathlib import Path
import re
import sys
import zipfile

text = Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(r"(?ms)^          import hashlib\r?\n.*?^          PY\r?$", text)
assert match, "The reviewed inline verifier must remain inspectable"
lines = match.group(0).splitlines()
source = "\n".join(line[10:] for line in lines[:-1])
compile(source, "attest-release.yml", "exec")
namespace = {}
exec(compile(source.split("# Runtime entrypoint:")[0], "verifier", "exec"), namespace)
verify = namespace["verify_bundle"]

signature = b"\r\n# SIG # Begin signature block\r\n# synthetic\r\n# SIG # End signature block\r\n"
SCRIPTS = ["Invoke-ExchangeLogReport.ps1", "Database-Storage.ps1", "ExchangeLogReport.psm1", "ExchangeLogReport.psd1",
           "src/Test-PackageIntegrity.ps1", "src/Get-ExlExchangeSettings.ps1"]
PAGE = "templates/Report.template.html"
MAIN = "templates/Report.template.js"
base = {
    PAGE: b'<script>var t;</script>%%CHUNKS%%<script id="report-meta" type="application/json">%%META%%</script><script>\n%%SCRIPT%%</script>',
    MAIN: b"console.log('synthetic');",
    "src/Engine.Serve.cs": b"// synthetic source placeholder",
    "powershell/pwsh.exe": b"synthetic executable placeholder",
    "sqlite-tools/sqlite3.exe": b"synthetic sqlite tool",
    "config/ExchangeLogReport.config.psd1": b"@{Synthetic=$true}",
    "product.json": json.dumps({"name": "ExchangeLogReport", "version": "3.0.0"}).encode(),
}
for script in SCRIPTS:
    base[script] = b"# synthetic script" + signature
MUTABLE = "config/ExchangeLogReport.config.psd1"
BINARY = ("powershell/", "sqlite-tools/")

def manifest_text(files, *, bad_schema=False, thumbprint="0F28E442889F17B5F4D251E8F96E7CC6E2C9C6D6", version="3.0.0", sign=True, unix_inventory=False, traversal=False):
    lines = ["@{", f"    SchemaVersion = {2 if bad_schema else 1}", "    Algorithm = 'SHA256'",
             f"    SignerThumbprint = '{thumbprint}'", f"    Version = '{version}'"]
    entries = [(name, data) for name, data in files.items() if name != MUTABLE]
    for list_name, binary in (("Files", False), ("DistributionFiles", True)):
        lines.append(f"    {list_name} = @(")
        for name, data in entries:
            if name.startswith(BINARY) != binary:
                continue
            shown = name.replace("/", "\\")
            if unix_inventory and name == PAGE:
                shown = name
            if traversal and name == PAGE:
                shown = "..\\Report.template.html"
            lines.append(f"        @{{ Path = '{shown}'; Sha256 = '{hashlib.sha256(data).hexdigest().upper()}' }}")
        lines.append("    )")
    lines.append("}")
    text = "\r\n".join(lines) + "\r\n"
    if sign:
        text += "\r\n# SIG # Begin signature block\r\n# synthetic\r\n# SIG # End signature block\r\n"
    return text.encode()

def make_zip(files=None, *, prefix="release/", manifest=True, changed=False, extra=False, traversal=False, bad_schema=False, duplicate=False, unsigned_manifest=False, wrong_signer=False, unix_inventory=False, unsigned_script=False, wrong_version=False):
    files = dict(base if files is None else files)
    if unsigned_script:
        files["Database-Storage.ps1"] = b"# synthetic script without a signature"
    manifest_bytes = manifest_text(files, bad_schema=bad_schema, sign=not unsigned_manifest, unix_inventory=unix_inventory, traversal=traversal,
                                   thumbprint="0000000000000000000000000000000000000000" if wrong_signer else "0F28E442889F17B5F4D251E8F96E7CC6E2C9C6D6",
                                   version="3.0.1" if wrong_version else "3.0.0")
    result = io.BytesIO()
    with zipfile.ZipFile(result, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, data in files.items():
            archive.writestr(prefix + name, data)
        if manifest:
            archive.writestr(prefix + "PackageIntegrity.psd1", manifest_bytes)
        if changed:
            # Listed bytes differ from the stored bytes: rewrite the script after the manifest was computed.
            archive.writestr(prefix + MAIN, b"console.log('tampered!');")
        if extra:
            archive.writestr(prefix + "unlisted.txt", b"not in manifest")
        if duplicate:
            archive.writestr(prefix + "TEMPLATES/report.TEMPLATE.JS", b"case collision")
    result.seek(0)
    return result

def make_changed():
    files = dict(base)
    manifest_bytes = manifest_text(files)
    files[MAIN] = b"console.log('tampered!');"
    result = io.BytesIO()
    with zipfile.ZipFile(result, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, data in files.items():
            archive.writestr("release/" + name, data)
        archive.writestr("release/PackageIntegrity.psd1", manifest_bytes)
    result.seek(0)
    return result

assert verify(make_zip(), expected_version="3.0.0")["report_script_bytes"] == len(base[MAIN])
assert verify(make_zip(prefix=""))["verified_files"] == len(base) - 1
missing_script = {name: data for name, data in base.items() if name != MAIN}
missing_page = {name: data for name, data in base.items() if name != PAGE}
unbound_page = dict(base, **{PAGE: b"<script>var t;</script>%%CHUNKS%%%%META%%"})
closing_script = dict(base, **{MAIN: b"document.write('</SCRIPT>');"})
generated_cache = dict(base, **{"bin/poisoned.dll": b"synthetic cache"})
old_host = dict(base, **{"host/ExchangeLogReportAngular.exe": b"removed host"})
retired_web = dict(base, **{"web/index.html": b"<app-root></app-root>"})
cases = [
    make_zip(manifest=False), make_changed(), make_zip(extra=True),
    make_zip(traversal=True), make_zip(bad_schema=True), make_zip(duplicate=True),
    make_zip(missing_script), make_zip(missing_page), make_zip(unbound_page), make_zip(closing_script),
    make_zip(unsigned_manifest=True), make_zip(wrong_signer=True), make_zip(unix_inventory=True),
    make_zip(generated_cache), make_zip(unsigned_script=True), make_zip(wrong_version=True), make_zip(old_host), make_zip(retired_web),
]
for number, fixture in enumerate(cases):
    try:
        verify(fixture, expected_version="3.0.0")
    except (SystemExit, ValueError, zipfile.BadZipFile):
        continue
    raise AssertionError(f"Invalid bundle fixture {number} was accepted")
try:
    verify(make_zip(), expected_version="2.0.0")
except SystemExit:
    pass
else:
    raise AssertionError("Wrong release version was accepted")
print("2 complete bundles accepted; 19 incomplete, tampered, unsigned, unsafe, noncanonical, state-polluted, retired-folder or wrong-version bundles rejected; no network or disk fixtures")
'@
        $output = & $python.Source -c $test (Join-Path $script:Workflows 'attest-release.yml') 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
    }
}
