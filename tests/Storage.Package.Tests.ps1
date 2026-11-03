#Requires -Version 7.4
param(
    [Parameter(Mandatory)][string]$PackageRoot,
    [Parameter(Mandatory)][string]$LegacyDatabase,
    # A package built by CI is unsigned and its binaries are compared with the signed manifest only on the release build.
    [switch]$DevelopmentMode
)
BeforeAll {
    $script:Package = [IO.Path]::GetFullPath($PackageRoot)
    $script:Development = [bool]$DevelopmentMode
    $script:Source = [IO.Path]::GetFullPath($LegacyDatabase)
    $script:Pwsh = Join-Path $script:Package 'powershell\pwsh.exe'
    $script:Entry = Join-Path $script:Package 'Database-Storage.ps1'
    $script:Sqlite = Join-Path $script:Package 'sqlite-tools\sqlite3.exe'
    $script:SourceHash = (Get-FileHash -LiteralPath $script:Source -Algorithm SHA256).Hash
    $script:SavedPath = $env:PATH
    $script:SavedDotnet = $env:DOTNET_ROOT
    $script:SavedNoColor = $env:NO_COLOR
    $env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
    $env:DOTNET_ROOT = Join-Path $TestDrive 'no-installed-runtime'
    # The tool writes plain text whatever the terminal: a warning line keeps no color sequence before its WARNING: prefix.
    $env:NO_COLOR = '1'
    $script:NativeCall = 0
    function Run-Storage([string[]]$Arguments) {
        $script:NativeCall++
        $stderr = Join-Path $TestDrive "native-$script:NativeCall.stderr.txt"
        [string[]]$switches = if ($script:Development) { '-DevelopmentMode' } else { @() }
        $output = & $script:Pwsh -NoLogo -NoProfile -File $script:Entry @($switches + $Arguments) 2> $stderr
        $exit = $LASTEXITCODE
        # The JSON report is the output without the warning lines; a color sequence a host may still write is not part of a line.
        $lines = @($output | ForEach-Object { "$_" -replace "\x1B\[[0-9;?]*[A-Za-z]", '' })
        [pscustomobject]@{ ExitCode = $exit; Text = (@($lines | Where-Object { $_ -notlike 'WARNING:*' }) -join "`n"); Error = Get-Content -LiteralPath $stderr -Raw }
    }
    function Read-Scalar([string]$Path, [string]$Sql) {
        $value = & $script:Sqlite -safe -init NUL -readonly -batch $Path $Sql
        if ($LASTEXITCODE) { throw 'The packaged read-only SQLite probe failed.' }
        return $value -join "`n"
    }
    $script:SourceSchema = Read-Scalar $script:Source "SELECT value FROM metadata WHERE key='schema_version';"
    $script:BeforeCounts = Read-Scalar $script:Source @'
SELECT (SELECT count(*) FROM message_event)||'|'||
(SELECT count(*) FROM smtp_transaction)||'|'||
(SELECT count(*) FROM access_event)||'|'||
(SELECT count(DISTINCT message_id) FROM message_event)||'|'||
(SELECT coalesce(sum(offset),0) FROM source_file);
'@
}
AfterAll {
    $env:PATH = $script:SavedPath
    $env:DOTNET_ROOT = $script:SavedDotnet
    $env:NO_COLOR = $script:SavedNoColor
}
Describe 'Packaged lossless SQLite maintenance' {
    It 'measures real DBSTAT object sizes without source writes' {
        $result = Run-Storage @('--storage-audit', '--database', $script:Source)
        $result.ExitCode | Should -Be 0 -Because $result.Error
        $audit = $result.Text | ConvertFrom-Json
        $audit.dbstatAvailable | Should -BeTrue
        $audit.sqliteVersion | Should -Be '3.54.0'
        $audit.objects.name | Should -Contain 'message_event'
        $audit.objects.name | Should -Contain 'ix_msg_flow'
        $audit.pageSize | Should -Be 16384
        $audit.databaseBytes | Should -Be (Get-Item -LiteralPath $script:Source).Length
        $objectBytes = ($audit.objects | Measure-Object bytes -Sum).Sum
        ($objectBytes + $audit.freePageBytes + $audit.unaccountedBytes) | Should -Be ($audit.pageCount * $audit.pageSize)
        (Get-FileHash -LiteralPath $script:Source -Algorithm SHA256).Hash | Should -Be $script:SourceHash
    }
    It 'refuses an unconfirmed copy and never overwrites an existing destination' {
        $unconfirmed = Join-Path $TestDrive 'unconfirmed.sqlite'
        (Run-Storage @('--storage-copy', '--database', $script:Source, '--destination', $unconfirmed, '--output', (Join-Path $TestDrive 'unconfirmed.json'), '--vacuum')).ExitCode | Should -Not -Be 0
        Test-Path -LiteralPath $unconfirmed | Should -BeFalse
        $existing = Join-Path $TestDrive 'existing.sqlite'
        Copy-Item -LiteralPath $script:Source -Destination $existing
        $before = (Get-FileHash -LiteralPath $existing -Algorithm SHA256).Hash
        (Run-Storage @('--storage-copy', '--database', $script:Source, '--destination', $existing, '--output', (Join-Path $TestDrive 'existing.json'), '--confirm-copy', '--vacuum')).ExitCode | Should -Not -Be 0
        (Get-FileHash -LiteralPath $existing -Algorithm SHA256).Hash | Should -Be $before
    }
    It 'compacts a new copy without migrating the schema' {
        $script:VacuumCopy = Join-Path $TestDrive 'vacuum-only.sqlite'
        $result = Run-Storage @('--storage-copy', '--database', $script:Source, '--destination', $script:VacuumCopy,
            '--output', (Join-Path $TestDrive 'vacuum-only.json'), '--confirm-copy', '--vacuum')
        $result.ExitCode | Should -Be 0 -Because $result.Error
        Read-Scalar $script:VacuumCopy "SELECT value FROM metadata WHERE key='schema_version';" | Should -Be $script:SourceSchema
        Read-Scalar $script:VacuumCopy 'PRAGMA integrity_check;' | Should -Be 'ok'
        (Get-Item -LiteralPath $script:VacuumCopy).Length | Should -BeLessOrEqual (Get-Item -LiteralPath $script:Source).Length
        (Get-FileHash -LiteralPath $script:Source -Algorithm SHA256).Hash | Should -Be $script:SourceHash
    }
    It 'migrates and repacks only a new copy while retaining exact row and identity counts' {
        $script:OptimizedCopy = Join-Path $TestDrive 'optimized.sqlite'
        $result = Run-Storage @('--storage-copy', '--database', $script:Source, '--destination', $script:OptimizedCopy,
            '--output', (Join-Path $TestDrive 'optimized.json'), '--confirm-copy', '--migrate', '--repack', '--vacuum')
        $result.ExitCode | Should -Be 0 -Because $result.Error
        Read-Scalar $script:OptimizedCopy "SELECT value FROM metadata WHERE key='schema_version';" | Should -Be '13'
        Read-Scalar $script:OptimizedCopy 'PRAGMA integrity_check;' | Should -Be 'ok'
        $afterCounts = Read-Scalar $script:OptimizedCopy @'
SELECT (SELECT count(*) FROM message_event)||'|'||
(SELECT count(*) FROM smtp_transaction)||'|'||
(SELECT count(*) FROM access_event)||'|'||
(SELECT count(DISTINCT message_id) FROM message_event)||'|'||
(SELECT coalesce(sum(offset),0) FROM source_file);
'@
        $afterCounts | Should -Be $script:BeforeCounts
        [long](Read-Scalar $script:OptimizedCopy "SELECT count(*) FROM message_event WHERE message_id IS NOT NULL AND msg_hash IS NULL;") | Should -Be 0
        # Only texts of at least 200 bytes are packed: the report states that the repack ran, whatever the data holds.
        ($result.Text | ConvertFrom-Json).actions.repack | Should -BeTrue
        (Get-FileHash -LiteralPath $script:Source -Algorithm SHA256).Hash | Should -Be $script:SourceHash
    }
    It 'rejects source/destination aliasing without touching source bytes' {
        $result = Run-Storage @('--storage-copy', '--database', $script:Source, '--destination', $script:Source,
            '--output', (Join-Path $TestDrive 'alias.json'), '--confirm-copy', '--vacuum')
        $result.ExitCode | Should -Not -Be 0
        (Get-FileHash -LiteralPath $script:Source -Algorithm SHA256).Hash | Should -Be $script:SourceHash
    }
}
