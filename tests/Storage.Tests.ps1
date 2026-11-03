BeforeAll {
    $ErrorActionPreference = 'Stop'
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $script:Root = Join-Path $repoRoot 'package'
    $tool = Join-Path $repoRoot 'lib\sqlite-tools\sqlite3.exe'
    if (-not (Test-Path -LiteralPath $tool)) { throw 'Supply the reviewed dev lib\sqlite-tools\sqlite3.exe first.' }
    $work = Join-Path ([IO.Path]::GetTempPath()) ('exl-storage-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($work)
    # The engine and the storage sources are compiled in memory once; the fixtures build their databases with them in process.
    Import-Module (Join-Path $script:Root 'ExchangeLogReport.psd1') -Force
    Initialize-ExlEngine -Root $script:Root -WithStorage
    # The command line runs in a hidden child PowerShell, as Database-Storage.ps1 does (without the signed entry script).
    $runner = Join-Path $work 'storage-runner.ps1'
    Set-Content -LiteralPath $runner -Encoding utf8 -Value ((
        'param([string]$Root, [string]$Tool)',
        # The JSON report is the only standard output: the unverified-source-tree warning of the import is not written there.
        'Import-Module (Join-Path $Root ''ExchangeLogReport.psd1'') -Force 3>$null',
        'Initialize-ExlEngine -Root $Root -WithStorage 3>$null',
        'exit [ExchangeLogReport.Storage.StorageCli]::Run([string[]]@(ConvertFrom-Json -InputObject $env:EXL_STORAGE_ARGS), ''3.0.0'', $Tool)') -join "`n")
    . (Join-Path $PSScriptRoot 'Storage.Fixtures.ps1')
    $marker = 'SYNTHETIC_PRIVATE_PAYLOAD_NEVER_EMIT'
    # -StatusRules: two more messages whose tracking row differs between the schema 8-11 and the schema-12 recipient rules (a SEND without DELIVER).
    # -External: a message a Send connector handed to a mail server outside the organization (SENDEXTERNAL accepted for a foreign domain), with -StatusRules
    # (its DELIVER makes example.invalid a domain of ours). -Schema12: a genuine schema-12 database (its rows written without the external status).
    function New-Fixture([string]$Name, [switch]$Schema6, [switch]$Schema7, [switch]$Schema8, [switch]$Schema9, [switch]$Schema10, [switch]$Schema11, [switch]$Schema12, [switch]$StandaloneSmtp, [switch]$StatusRules, [switch]$SentSmtp, [switch]$External) {
        $path = Join-Path $work ($Name + '.sqlite')
        $store = [ExchangeLogReport.Store]::new($path, $false, 'synthetic-preserved-tool')
        try {
            $text = ($marker + ' repeated evidence ') * 100
            $packed = [Convert]::ToHexString([ExchangeLogReport.Packed]::Pack($text))
            $store.Exec("INSERT INTO metadata(key,value) VALUES('custom_setting','$marker');")
            $store.Exec("INSERT INTO source_file(id,server,kind,path,offset,size,file_key) VALUES(41,'synthetic-mail','SMTPReceive','synthetic-only',98307,100000,'synthetic-key');")
            # '#Fields' header texts, kept in the schema-10 dictionary (the legacy fixtures below turn them back into source_file.fields text).
            $store.Exec("INSERT INTO source_fields(id,text) VALUES(1,'#Fields: date-time,connector-id'),(2,'#Fields: ' || char(233) || char(30028) || ' tracking,' || char(13) || char(10));
UPDATE source_file SET fields_id=1 WHERE id=41;
INSERT INTO source_file(id,server,kind,path,offset,size,file_key,fields_id) VALUES(42,'synthetic-mail','SMTPSend','synthetic-two',7,8,'synthetic-key-2',1),(43,'synthetic-mail','Tracking','synthetic-three',9,10,'synthetic-key-3',2),(44,'synthetic-mail','Tracking','synthetic-four',0,0,'synthetic-key-4',NULL);")
            $store.Exec("INSERT INTO message_event(id,time_ms,server,message_id,event_id,log_id,subject) VALUES(101,1791979200000,'synthetic-mail','<Mixed@example.invalid>','RECEIVE','synthetic-101','$marker'),(102,1791979200000,'synthetic-mail','<mixed@example.invalid>','DELIVER','synthetic-102','$marker');")
            $store.Exec("INSERT INTO smtp_transaction(id,time_ms,server,direction,session_id,message_id,response,transcript) VALUES(201,1791979200000,'synthetic-mail','Receive','synthetic-session','<Mixed@example.invalid>','$text',X'$packed');")
            $store.Exec("INSERT INTO smtp_auth_fragment(id,source_file_id,source_key,first_offset,first_ms,last_ms,server,direction,session_id,observations) VALUES(301,41,'synthetic-key',98307,1791979200000,1791979200001,'synthetic-mail','Receive','synthetic-session','$text');")
            $store.Exec("INSERT INTO access_event(id,time_ms,server,source,outcome,url,errors) VALUES(401,1791979200000,'synthetic-mail','synthetic','Failure','$text','$text');")
            $store.Exec("CREATE TABLE synthetic_pages(id INTEGER PRIMARY KEY,payload BLOB); WITH RECURSIVE n(x) AS(VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<100) INSERT INTO synthetic_pages SELECT x,zeroblob(4096) FROM n; DELETE FROM synthetic_pages WHERE id>2; CREATE TABLE synthetic_ordered(value TEXT); INSERT INTO synthetic_ordered VALUES('first'),('second'); CREATE TABLE synthetic_opaque(id INTEGER PRIMARY KEY,value BLOB); INSERT INTO synthetic_opaque VALUES(1,X'002AFF'),(2,X'01FFFF00'),(3,'$marker'); CREATE TABLE synthetic_typed(id INTEGER PRIMARY KEY,value); INSERT INTO synthetic_typed VALUES(1,NULL),(2,123),(3,1.25),(4,'123'),(5,X'002AFF');")
            if ($StandaloneSmtp) {
                $store.Exec("INSERT INTO smtp_transaction(id,time_ms,server,direction,session_id,status,mail_from,rcpts) VALUES(202,1791979200000,'synthetic-mail','Receive','synthetic-null-rejected','Rejected','sender@example.invalid','recipient@example.invalid'),(203,1791979200000,'synthetic-mail','Receive','synthetic-null-accepted','Accepted','sender@example.invalid','recipient@example.invalid'),(204,1791979200000,'synthetic-mail','Send','synthetic-null-send','Rejected','sender@example.invalid','recipient@example.invalid');")
            }
            if ($StatusRules) {
                # <relay@...>: a delivered and a handed-off recipient; <out@...>: one handed-off recipient.
                $store.Exec("INSERT INTO message_event(id,time_ms,server,message_id,event_id,sender,recipients,log_id) VALUES(103,1791979300000,'synthetic-mail','<relay@example.invalid>','RECEIVE','sender@example.invalid','a@example.invalid;b@example.invalid','synthetic-103'),(104,1791979301000,'synthetic-mail','<relay@example.invalid>','DELIVER','sender@example.invalid','a@example.invalid','synthetic-104'),(105,1791979302000,'synthetic-mail','<relay@example.invalid>','SEND','sender@example.invalid','b@example.invalid','synthetic-105'),(106,1791979400000,'synthetic-mail','<out@example.invalid>','RECEIVE','sender@example.invalid','b@example.invalid','synthetic-106'),(107,1791979401000,'synthetic-mail','<out@example.invalid>','SEND','sender@example.invalid','b@example.invalid','synthetic-107');")
            }
            if ($External) {
                $store.Exec("INSERT INTO message_event(id,time_ms,server,message_id,event_id,sender,recipients,recipient_status,connector,server_host,server_ip,log_id) VALUES(108,1791979600000,'synthetic-mail','<external@example.invalid>','RECEIVE','sender@example.invalid','partner@fabrikam.example',NULL,NULL,NULL,NULL,'synthetic-108'),(109,1791979601000,'synthetic-mail','<external@example.invalid>','SENDEXTERNAL','sender@example.invalid','partner@fabrikam.example','250 2.1.5 Ok','To Internet via Postfix','203.0.113.5','203.0.113.5','synthetic-109');")
            }
            if ($SentSmtp) {
                # A sent and an accepted SMTP transaction with a Message-ID and no tracking event.
                $store.Exec("INSERT INTO smtp_transaction(id,time_ms,end_ms,server,direction,session_id,message_id,status,mail_from,rcpts) VALUES(205,1791979500000,1791979500100,'synthetic-mail','Send','synthetic-sent-only','<sent-only@example.invalid>','Sent','sender@example.invalid','far@example.invalid'),(206,1791979501000,1791979501100,'synthetic-mail','Receive','synthetic-accepted-only','<accepted-only@example.invalid>','Accepted','sender@example.invalid','a@example.invalid');")
            }
            if ($Schema8 -or $Schema9 -or $Schema10 -or $Schema11) {
                Complete-StorageFixture $store
                Set-LegacyStorageFixture ([ServeFixtures]::Connection($store)) $(if ($Schema8) { 8 } elseif ($Schema9) { 9 } elseif ($Schema10) { 10 } else { 11 }) -RollupVocabulary:$StatusRules
            } elseif ($Schema6 -or $Schema7) {
                Set-LegacyStorageFixture ([ServeFixtures]::Connection($store)) $(if ($Schema6) { 6 } else { 7 })
                $store.Exec("WITH RECURSIVE n(x) AS(VALUES(3) UNION ALL SELECT x+1 FROM n WHERE x<100) INSERT INTO synthetic_pages SELECT x,zeroblob(4096) FROM n; DELETE FROM synthetic_pages WHERE id>2;")
            } elseif ($Schema12) {
                Complete-StorageFixture $store
                [ServeFixtures]::ConvertToSchema12([ServeFixtures]::Connection($store))
            } else { Complete-StorageFixture $store }
            $store.Exec("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;")
        } finally { $store.Dispose() }
        return $path
    }
    # -UncachedReads: the child process verifies the rollups with a new command per statement (the reference path) instead of prepared statements.
    # -PointReads: the per-identity point reads (the reference path) instead of the merge scan.
    function Invoke-Storage([string[]]$Arguments, [switch]$NoTool, [switch]$UncachedReads, [switch]$PointReads) {
        $id = [guid]::NewGuid().ToString('N')
        $stdout = Join-Path $work ($id + '.stdout.log')
        $stderr = Join-Path $work ($id + '.stderr.log')
        $argsList = @($Arguments)
        if (-not $NoTool) { $argsList += @('--sqlite-tool', $tool) }
        $env:EXL_STORAGE_ARGS = ConvertTo-Json -InputObject @($argsList) -Compress
        if ($UncachedReads) { $env:EXCHANGELOGREPORT_STORAGE_VERIFICATION_UNCACHED = '1' }
        if ($PointReads) { $env:EXCHANGELOGREPORT_STORAGE_VERIFICATION_POINT = '1' }
        try {
            $p = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr `
                -ArgumentList @('-NoLogo', '-NoProfile', '-File', "`"$runner`"", '-Root', "`"$script:Root`"", '-Tool', "`"$tool`"")
        } finally {
            Remove-Item Env:\EXCHANGELOGREPORT_STORAGE_VERIFICATION_UNCACHED -ErrorAction SilentlyContinue
            Remove-Item Env:\EXCHANGELOGREPORT_STORAGE_VERIFICATION_POINT -ErrorAction SilentlyContinue
            Remove-Item Env:\EXL_STORAGE_ARGS -ErrorAction SilentlyContinue
        }
        if (-not $p.WaitForExit(60000)) { Stop-Process -Id $p.Id -Force; throw 'Storage CLI timed out.' }
        $text = Get-Content -LiteralPath $stdout -Raw
        $errorText = Get-Content -LiteralPath $stderr -Raw
        [pscustomobject]@{ Code = $p.ExitCode; Text = $text; Error = $errorText; Json = $(if ($text) { $text | ConvertFrom-Json }) }
    }
    function Read-Scalar([string]$Path, [string]$Sql) {
        $db = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$Path;Mode=ReadOnly;Pooling=False")
        try {
            $db.Open()
            $c = $db.CreateCommand()
            try { $c.CommandText = $Sql; return $c.ExecuteScalar() } finally { $c.Dispose() }
        } finally { $db.Dispose() }
    }
    function Shared-Hash([string]$Path) {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try { return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)) } finally { $stream.Dispose() }
    }
    function Write-FixtureSql([string]$Path, [string]$Sql) {
        $db = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$Path;Mode=ReadWrite;Pooling=False")
        try {
            $db.Open()
            $c = $db.CreateCommand()
            try { $c.CommandText = $Sql; [void]$c.ExecuteNonQuery() } finally { $c.Dispose() }
        } finally { $db.Dispose() }
    }
    $source = New-Fixture 'source6' -Schema6
    $source7 = New-Fixture 'source7' -Schema7
    $source8 = New-Fixture 'source8' -Schema8 -StatusRules
    # the CURRENT schema (13); $source9Genuine, $source10Genuine and $source11Genuine are genuine schema-9, -10 and -11 databases
    $source9 = New-Fixture 'source9' -StatusRules
    $source9Genuine = New-Fixture 'source9genuine' -Schema9 -StatusRules
    $source10Genuine = New-Fixture 'source10genuine' -Schema10 -StatusRules
    $source11Genuine = New-Fixture 'source11genuine' -Schema11 -StatusRules
    $sourceHash = (Get-FileHash -LiteralPath $source).Hash
    $source7Hash = (Get-FileHash -LiteralPath $source7).Hash
    $source8Hash = (Get-FileHash -LiteralPath $source8).Hash
    $source9Hash = (Get-FileHash -LiteralPath $source9).Hash
    $source9GenuineHash = (Get-FileHash -LiteralPath $source9Genuine).Hash
    $source10GenuineHash = (Get-FileHash -LiteralPath $source10Genuine).Hash
    $source11GenuineHash = (Get-FileHash -LiteralPath $source11Genuine).Hash
    # Decoded status of a tracking identity (text column of schemas 8 to 10, dictionary code of schemas 11 to 13).
    function Read-Status([string]$Path, [string]$Identity) {
        $codes = Read-Scalar $Path "SELECT count(*) FROM sqlite_schema WHERE name='message_rollup_value';"
        if ($codes -eq 1) { return Read-Scalar $Path "SELECT v.text FROM message_rollup r JOIN message_rollup_value v ON v.id=r.status WHERE r.kind=0 AND r.identity='$Identity';" }
        return Read-Scalar $Path "SELECT status FROM message_rollup WHERE kind='message' AND identity='$Identity';"
    }
    $rulesExclusion = 'message_rollup status, recipients, recipient_count, delivered, failed and events of tracking identities (kind 0) are recomputed by the schema-13 rules and verified by exact recomputation, not by equality with the source; sqlite_sequence.seq of message_rollup may advance (verified >= source and >= MAX(id))'
}

Describe 'Explicit copy-only SQLite storage maintenance' {
    It 'audits real dbstat through the pinned tool with integer sizes and no row values or web startup' {
        $output = Join-Path $work 'audit.json'
        $r = Invoke-Storage @('--storage-audit', '--database', $source, '--output', $output)
        $r.Code | Should -Be 0 -Because $r.Error
        $r.Json.sqliteVersion | Should -Be '3.54.0'
        $r.Json.nativeSqliteVersion | Should -Be '3.53.3'
        $r.Json.dbstatAvailable | Should -BeTrue
        $r.Json.objects.name | Should -Contain 'message_event'
        $r.Json.objects.name | Should -Contain 'ix_msg_flow'
        for ($i = 1; $i -lt $r.Json.objects.Count; $i++) {
            $r.Json.objects[$i - 1].bytes | Should -BeGreaterOrEqual $r.Json.objects[$i].bytes
            if ($r.Json.objects[$i - 1].bytes -eq $r.Json.objects[$i].bytes) {
                [string]::CompareOrdinal($r.Json.objects[$i - 1].name, $r.Json.objects[$i].name) | Should -BeLessOrEqual 0
            }
        }
        $r.Json.databaseBytes | Should -Be (Get-Item -LiteralPath $source).Length
        $r.Json.freelistBytes | Should -Be ($r.Json.freelistCount * $r.Json.pageSize)
        $r.Json.freePageBytes | Should -Be $r.Json.freelistBytes
        $r.Json.unaccountedBytes | Should -Be $r.Json.residualBytes
        $r.Json.elapsedMilliseconds | Should -Be $r.Json.durationMs
        $r.Json.recommendations.Count | Should -BeGreaterThan 0
        $r.Json.objectBytes | Should -BeGreaterThan 0
        $r.Json.residualBytes | Should -BeGreaterOrEqual 0
        $r.Text | Should -Not -Match ([regex]::Escape($marker))
        $r.Text | Should -Not -Match 'portal ready|Now listening'
        (Get-FileHash -LiteralPath $source).Hash | Should -Be $sourceHash
        Test-Path -LiteralPath $output | Should -BeTrue
    }

    It 'makes a verified coherent copy without implicit migration, repacking or vacuum' {
        $dest = Join-Path $work 'plain.sqlite'
        $output = Join-Path $work 'plain.json'
        $r = Invoke-Storage @('--storage-copy', '--database', $source, '--destination', $dest, '--confirm-copy', '--output', $output)
        $r.Code | Should -Be 0 -Because $r.Error
        $r.Json.success | Should -BeTrue
        $r.Json.actions.migrate | Should -BeFalse
        $r.Json.actions.vacuum | Should -BeFalse
        $r.Json.actions.repack | Should -BeFalse
        $r.Json.before.schemaVersion | Should -Be '6'
        $r.Json.after.schemaVersion | Should -Be '6'
        $r.Json.after.freelistCount | Should -Be $r.Json.before.freelistCount
        (Read-Scalar $dest "SELECT value FROM metadata WHERE key='tool_version';") | Should -Be 'synthetic-preserved-tool'
        (Read-Scalar $dest "SELECT offset FROM source_file WHERE id=41;") | Should -Be 98307
        (Read-Scalar $dest "SELECT count(*) FROM message_event WHERE id IN (101,102);") | Should -Be 2
        (Read-Scalar $dest "SELECT group_concat(kind,',') FROM (SELECT typeof(value) AS kind FROM synthetic_typed ORDER BY id);") | Should -Be 'null,integer,real,text,blob'
        $r.Json.vacuumCapacity | Should -BeNullOrEmpty
        (Get-FileHash -LiteralPath $source).Hash | Should -Be $sourceHash
        $r.Text | Should -Not -Match ([regex]::Escape($marker))
    }

    It 'runs full vacuum independently without changing schema or normalized rows' {
        $dest = Join-Path $work 'vacuum.sqlite'
        $output = Join-Path $work 'vacuum.json'
        $r = Invoke-Storage @('--storage-copy', '--database', $source, '--destination', $dest, '--confirm-copy', '--vacuum', '--output', $output)
        $r.Code | Should -Be 0 -Because $r.Error
        $r.Json.after.schemaVersion | Should -Be '6'
        $r.Json.actions.migrate | Should -BeFalse
        $r.Json.phases.stage | Should -Contain 'vacuumIntoSibling'
        # The rollup verification of the live source has a phase of its own, between the source audit and the fingerprint.
        $stages = @($r.Json.phases.stage)
        $stages.IndexOf('sourceRollupVerification') | Should -BeGreaterThan $stages.IndexOf('sourceAudit')
        $stages.IndexOf('sourceRollupVerification') | Should -BeLessThan $stages.IndexOf('sourceFingerprint')
        $r.Json.vacuumCapacity.tempStore | Should -Be 'FILE'
        $r.Json.vacuumCapacity.destinationVolume | Should -Not -BeNullOrEmpty
        $r.Json.vacuumCapacity.temporaryVolume | Should -Not -BeNullOrEmpty
        $r.Json.vacuumCapacity.destinationAvailableFreeBytes | Should -BeGreaterOrEqual $r.Json.vacuumCapacity.destinationRequiredFreeBytes
        $r.Json.vacuumCapacity.temporaryAvailableFreeBytes | Should -BeGreaterOrEqual $r.Json.vacuumCapacity.temporaryRequiredFreeBytes
        $r.Json.verification.before.sha256 | Should -Be $r.Json.verification.after.sha256
        $r.Json.sourceUnchanged | Should -BeTrue
        (Get-FileHash -LiteralPath $source).Hash | Should -Be $sourceHash
    }

    It 'copies, migrates and vacuums next to a destination whose staged copies have paths longer than 260 characters, and refuses one SQLite cannot open' {
        # The staged copies add 48 characters to the destination path (56 with their journal): the bundled audit tool and VACUUM INTO name them by
        # their extended path, as every connection does.
        $deep = Join-Path $work 'long-path'
        while ($deep.Length -lt 200) { $deep = Join-Path $deep ('d' * [Math]::Min(60, 200 - $deep.Length + 1)) }
        [void][IO.Directory]::CreateDirectory($deep)
        $dest = Join-Path $deep 'long-copy.sqlite'
        ($dest.Length + 48) | Should -BeGreaterThan 260
        $r = Invoke-Storage @('--storage-copy', '--database', $source, '--destination', $dest, '--confirm-copy', '--migrate', '--vacuum', '--output', (Join-Path $work 'long-copy.json'))
        $r.Code | Should -Be 0 -Because $r.Error
        $r.Json.success | Should -BeTrue
        $r.Json.after.schemaVersion | Should -Be '13'
        $r.Json.phases.stage | Should -Contain 'vacuumIntoSibling'
        @(Get-ChildItem -LiteralPath $deep -Force | ForEach-Object Name) -join ',' | Should -BeExactly 'long-copy.sqlite'
        (Get-FileHash -LiteralPath $source).Hash | Should -Be $sourceHash
        # A destination whose staged copy would pass the 1040 bytes of the SQLite Windows VFS is refused before any write, with the limit.
        $deeper = $deep
        while ($deeper.Length -lt 1000) { $deeper = Join-Path $deeper ('e' * 120) }
        [void][IO.Directory]::CreateDirectory($deeper)
        $refused = Invoke-Storage @('--storage-copy', '--database', $source, '--destination', (Join-Path $deeper 'too-long.sqlite'), '--confirm-copy', '--output', (Join-Path $work 'too-long.json'))
        $refused.Code | Should -Be 2
        $refused.Json.error | Should -Match '^The destination path is too long for the copy staged next to it: its name would take \d+ UTF-8 bytes, more than the 1040 that SQLite opens on Windows\.'
        @(Get-ChildItem -LiteralPath $deeper -Force).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $work 'too-long.json') | Should -BeFalse
    }

    It 'writes a new default evidence report when copy output is omitted' {
        $dest = Join-Path $work 'default-report.sqlite'
        $r = Invoke-Storage @('--storage-copy', '--database', $source, '--destination', $dest, '--confirm-copy')
        $r.Code | Should -Be 0 -Because $r.Error
        Test-Path -LiteralPath ($dest + '.maintenance.json') | Should -BeTrue
        $r.Json.after.schemaVersion | Should -Be '6'
        (Get-FileHash -LiteralPath $source).Hash | Should -Be $sourceHash
    }

    It 'migrates and repacks only the new copy and preserves metadata, offsets and auth evidence' {
        $dest = Join-Path $work 'optimized.sqlite'
        $output = Join-Path $work 'optimized.json'
        $r = Invoke-Storage @('--storage-copy', '--database', $source, '--destination', $dest, '--confirm-copy', '--migrate', '--repack', '--vacuum', '--output', $output)
        $r.Code | Should -Be 0 -Because $r.Error
        $r.Json.after.schemaVersion | Should -Be '13'
        $r.Json.verification.smtpClients.applicable | Should -BeTrue
        (Read-Scalar $dest "SELECT count(*) FROM pragma_table_info('smtp_transaction') WHERE name='client_id';") | Should -Be 1
        (Read-Scalar $dest "SELECT count(*) FROM sqlite_schema WHERE name='ix_smtp_latest';") | Should -Be 0
        $r.Json.verification.derivedRollups.validated | Should -BeTrue
        ($r.Json.verification.derivedRollups.tables -join ',') | Should -Be 'message_rollup,message_rollup_dirty'
        ($r.Json.verification.derivedRollups.newlyAddedTables -join ',') | Should -Be 'message_rollup,message_rollup_dirty'
        ($r.Json.verification.derivedRollups.newlyAddedBookkeepingTables -join ',') | Should -Be 'sqlite_sequence'
        (Read-Scalar $dest 'SELECT count(*) FROM message_rollup_dirty;') | Should -Be 0
        (Read-Scalar $dest "SELECT count(*) FROM message_rollup WHERE identity IN ('<Mixed@example.invalid>','<mixed@example.invalid>');") | Should -Be 2
        $r.Json.repackedCells | Should -Be 3
        (Read-Scalar $dest "SELECT value FROM metadata WHERE key='tool_version';") | Should -Be 'synthetic-preserved-tool'
        (Read-Scalar $dest "SELECT value FROM metadata WHERE key='custom_setting';") | Should -Be $marker
        (Read-Scalar $dest 'SELECT offset FROM source_file WHERE id=41;') | Should -Be 98307
        (Read-Scalar $dest 'SELECT first_offset FROM smtp_auth_fragment WHERE id=301;') | Should -Be 98307
        (Read-Scalar $dest 'SELECT typeof(observations) FROM smtp_auth_fragment WHERE id=301;') | Should -Be 'text'
        (Read-Scalar $dest 'SELECT typeof(response) FROM smtp_transaction WHERE id=201;') | Should -Be 'blob'
        (Read-Scalar $dest "SELECT hex(value) FROM synthetic_opaque WHERE id=1;") | Should -Be '002AFF'
        (Read-Scalar $dest "SELECT hex(value) FROM synthetic_opaque WHERE id=2;") | Should -Be '01FFFF00'
        (Get-FileHash -LiteralPath $source).Hash | Should -Be $sourceHash
        $r.Text | Should -Not -Match ([regex]::Escape($marker))
    }

    It 'can repack a current-schema copy without requesting migration or vacuum' {
        $dest = Join-Path $work 'repack9.sqlite'
        $r = Invoke-Storage @('--storage-copy', '--database', $source9, '--destination', $dest, '--confirm-copy', '--repack', '--output', (Join-Path $work 'repack9.json'))
        $r.Code | Should -Be 0 -Because $r.Error
        $r.Json.actions.migrate | Should -BeFalse
        $r.Json.actions.vacuum | Should -BeFalse
        $r.Json.repackedCells | Should -Be 3
        (Get-FileHash -LiteralPath $source9).Hash | Should -Be $source9Hash
    }

    It 'refuses to repack a schema-8 copy without explicit migration' {
        $dest = Join-Path $work 'repack8-refused.sqlite'
        $r = Invoke-Storage @('--storage-copy', '--database', $source8, '--destination', $dest, '--confirm-copy', '--repack', '--output', (Join-Path $work 'repack8-refused.json'))
        $r.Code | Should -Be 2
        Test-Path -LiteralPath $dest | Should -BeFalse
        (Get-FileHash -LiteralPath $source8).Hash | Should -Be $source8Hash
    }

    It 'counts two changed cells in a single access-event row' {
        $path = New-Fixture 'two-cells-one-row'
        $store = [ExchangeLogReport.Store]::new($path, $false, 'synthetic-preserved-tool')
        try { $store.Exec("UPDATE smtp_transaction SET response='short' WHERE id=201;") } finally { $store.Dispose() }
        $hash = (Get-FileHash -LiteralPath $path).Hash
        $dest = Join-Path $work 'two-cells-one-row-copy.sqlite'
        $r = Invoke-Storage @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy', '--repack', '--output', (Join-Path $work 'two-cells-one-row.json'))
        $r.Code | Should -Be 0 -Because $r.Error
        $r.Json.repackedCells | Should -Be 2
        (Read-Scalar $dest "SELECT typeof(url)||','||typeof(errors) FROM access_event WHERE id=401;") | Should -Be 'blob,blob'
        (Read-Scalar $dest 'SELECT typeof(observations) FROM smtp_auth_fragment WHERE id=301;') | Should -Be 'text'
        (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
    }

    It 'can migrate hashes independently without repacking or vacuum' {
        $dest = Join-Path $work 'hash-only.sqlite'
        $r = Invoke-Storage @('--storage-copy', '--database', $source, '--destination', $dest, '--confirm-copy', '--migrate', '--output', (Join-Path $work 'hash-only.json'))
        $r.Code | Should -Be 0 -Because $r.Error
        $r.Json.after.schemaVersion | Should -Be '13'
        $r.Json.actions.repack | Should -BeFalse
        $r.Json.actions.vacuum | Should -BeFalse
        $r.Json.measurements.stage | Should -Contain 'afterMigration'
        (Read-Scalar $dest "SELECT count(*) FROM message_event WHERE msg_hash IS NOT NULL;") | Should -Be 2
        (Get-FileHash -LiteralPath $source).Hash | Should -Be $sourceHash
    }

    It 'migrates genuine schema 7 without excluding existing hash metadata or hash columns' {
        (Read-Scalar $source7 "SELECT count(*) FROM sqlite_schema WHERE name IN ('message_rollup','message_rollup_dirty','sqlite_sequence');") | Should -Be 0
        $dest = Join-Path $work 'schema7-copy.sqlite'
        $r = Invoke-Storage @('--storage-copy', '--database', $source7, '--destination', $dest, '--confirm-copy', '--migrate')
        $r.Code | Should -Be 0 -Because $r.Error
        $r.Json.before.schemaVersion | Should -Be '7'
        $r.Json.after.schemaVersion | Should -Be '13'
        $r.Json.verification.derivedRollups.validated | Should -BeTrue
        $r.Json.verification.exclusions | Should -Contain 'metadata.schema_version'
        $r.Json.verification.exclusions | Should -Not -Contain 'metadata.message_hash_algorithm'
        $r.Json.verification.exclusions | Should -Not -Contain 'added msg_hash only'
        $r.Json.actions.repack | Should -BeFalse
        $r.Json.actions.vacuum | Should -BeFalse
        (Read-Scalar $dest "SELECT value FROM metadata WHERE key='message_hash_algorithm';") | Should -Be 'fnv1a64-utf8-v1'
        (Get-FileHash -LiteralPath $source7).Hash | Should -Be $source7Hash
    }

    It 'preserves every existing current-schema rollup ID and sequence in plain, migration and vacuum copies' {
        $path = New-Fixture 'existing-rollups'
        Write-FixtureSql $path 'UPDATE message_rollup SET id=id+900; UPDATE sqlite_sequence SET seq=1200 WHERE name=''message_rollup''; CREATE TABLE synthetic_existing_auto(id INTEGER PRIMARY KEY AUTOINCREMENT,value TEXT); INSERT INTO synthetic_existing_auto VALUES(42,''synthetic'');'
        $hash = (Get-FileHash -LiteralPath $path).Hash
        foreach ($mode in @('plain', 'migrate', 'vacuum')) {
            $dest = Join-Path $work ("existing-rollups-$mode.sqlite")
            $arguments = @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy')
            if ($mode -ne 'plain') { $arguments += "--$mode" }
            $r = Invoke-Storage $arguments
            $r.Code | Should -Be 0 -Because $r.Error
            $r.Json.verification.derivedRollups.validated | Should -BeTrue
            $r.Json.verification.derivedRollups.baselineTablesPreserved | Should -BeTrue
            @($r.Json.verification.derivedRollups.newlyAddedTables).Count | Should -Be 0
            @($r.Json.verification.exclusions).Count | Should -Be 0
            foreach ($table in @('message_rollup', 'message_rollup_dirty', 'sqlite_sequence')) {
                ($r.Json.verification.after | Where-Object name -EQ $table).sha256 |
                    Should -Be ($r.Json.verification.before | Where-Object name -EQ $table).sha256
            }
            (Read-Scalar $dest 'SELECT min(id) FROM message_rollup;') | Should -Be 901
            (Read-Scalar $dest "SELECT seq FROM sqlite_sequence WHERE name='message_rollup';") | Should -Be 1200
            (Read-Scalar $dest "SELECT seq FROM sqlite_sequence WHERE name='synthetic_existing_auto';") | Should -Be 42
            (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
        }
    }

    It 'migrates a genuine schema-8 copy to schema 13 changing only indexes, triggers, dictionaries, the SMTP client structures and the recipient-rule columns, with every other derived value (decoded) and ID identical and the sequence not lower' {
        (Read-Scalar $source8 "SELECT count(*) FROM sqlite_schema WHERE name IN ('ix_msg_hash','ix_smtp_hash','ix_session_latest');") | Should -Be 3
        $path = New-Fixture 'existing-rollups8' -Schema8 -StatusRules
        Write-FixtureSql $path 'UPDATE message_rollup SET id=id+900; UPDATE sqlite_sequence SET seq=1200 WHERE name=''message_rollup'';'
        $hash = (Get-FileHash -LiteralPath $path).Hash
        foreach ($mode in @('plain', 'migrate', 'migrate-vacuum')) {
            $dest = Join-Path $work ("schema8-$mode.sqlite")
            $arguments = @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy')
            if ($mode -ne 'plain') { $arguments += '--migrate' }
            if ($mode -eq 'migrate-vacuum') { $arguments += '--vacuum' }
            $r = Invoke-Storage $arguments
            $r.Code | Should -Be 0 -Because $r.Error
            $r.Json.before.schemaVersion | Should -Be '8'
            $r.Json.after.schemaVersion | Should -Be $(if ($mode -eq 'plain') { '8' } else { '13' })
            $r.Json.verification.derivedRollups.schemaVersion | Should -Be $(if ($mode -eq 'plain') { '8' } else { '13' })
            $r.Json.verification.derivedRollups.validated | Should -BeTrue
            $r.Json.verification.derivedRollups.baselineTablesPreserved | Should -BeTrue
            @($r.Json.verification.derivedRollups.newlyAddedTables).Count | Should -Be 0
            @($r.Json.verification.derivedRollups.newlyAddedBookkeepingTables).Count | Should -Be 0
            if ($mode -eq 'plain') { @($r.Json.verification.exclusions).Count | Should -Be 0 }
            else {
                $r.Json.verification.exclusions[0] | Should -Be 'metadata.schema_version'
                $r.Json.verification.exclusions | Should -Contain 'added source_fields table and source_file.fields_id column only (source_file.fields is compared as its logical dictionary text)'
                ($r.Json.verification.exclusions -join '|') | Should -Match 'message_rollup is compared through its decoded rows'
            }
            # The decoded message_rollup of a migrated copy has the very same logical digest as its schema-8 source (the codes are not compared, their texts are;
            # in migrate modes the recipient-rule columns of the tracking rows are left out on both sides and verified by recomputation).
            foreach ($table in @('message_rollup', 'message_rollup_dirty', 'sqlite_sequence')) {
                ($r.Json.verification.after | Where-Object name -EQ $table).sha256 |
                    Should -Be ($r.Json.verification.before | Where-Object name -EQ $table).sha256
            }
            (Read-Scalar $dest 'SELECT min(id) FROM message_rollup;') | Should -Be 901
            (Read-Scalar $dest 'SELECT max(id) FROM message_rollup;') | Should -Be (Read-Scalar $path 'SELECT max(id) FROM message_rollup;')
            if ($mode -eq 'plain') {
                (Read-Scalar $dest "SELECT seq FROM sqlite_sequence WHERE name='message_rollup';") | Should -Be 1200
                (Read-Status $dest '<out@example.invalid>') | Should -Be 'Relayed'
                @($r.Json.verification.exclusions) | Should -Not -Contain $rulesExclusion
            } else {
                (Read-Scalar $dest "SELECT seq FROM sqlite_sequence WHERE name='message_rollup';") | Should -BeGreaterOrEqual 1200
                (Read-Status $dest '<out@example.invalid>') | Should -Be 'Handed off outside collection'
                $r.Json.verification.exclusions | Should -Contain $rulesExclusion
            }
            $r.Json.verification.rollupRules.applicable | Should -Be ($mode -ne 'plain')
            (Read-Scalar $dest "SELECT count(*) FROM sqlite_schema WHERE name IN ('ix_msg_hash','ix_smtp_hash','ix_session_latest');") | Should -Be $(if ($mode -eq 'plain') { 3 } else { 0 })
            (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
        }
    }

    It 'migrates a genuine schema-9 copy to schema 13: narrowed identity indexes, fields dictionary compared as logical text, every derived value outside the recipient rules (decoded) and ID identical' {
        (Read-Scalar $source9Genuine "SELECT count(*) FROM sqlite_schema WHERE name IN ('source_fields');") | Should -Be 0
        (Read-Scalar $source9Genuine "SELECT sql FROM sqlite_schema WHERE name='ix_msg_identity_time';") | Should -Match 'message_id COLLATE BINARY,time_ms,id'
        $path = New-Fixture 'existing-rollups9' -Schema9 -StatusRules
        Write-FixtureSql $path 'UPDATE message_rollup SET id=id+900; UPDATE sqlite_sequence SET seq=1200 WHERE name=''message_rollup'';'
        $hash = (Get-FileHash -LiteralPath $path).Hash
        foreach ($mode in @('plain', 'migrate', 'migrate-vacuum')) {
            $dest = Join-Path $work ("schema9-$mode.sqlite")
            $arguments = @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy')
            if ($mode -ne 'plain') { $arguments += '--migrate' }
            if ($mode -eq 'migrate-vacuum') { $arguments += '--vacuum' }
            $r = Invoke-Storage $arguments
            $r.Code | Should -Be 0 -Because $r.Error
            $r.Json.before.schemaVersion | Should -Be '9'
            $r.Json.after.schemaVersion | Should -Be $(if ($mode -eq 'plain') { '9' } else { '13' })
            $r.Json.verification.derivedRollups.schemaVersion | Should -Be $(if ($mode -eq 'plain') { '9' } else { '13' })
            $r.Json.verification.derivedRollups.validated | Should -BeTrue
            $r.Json.verification.derivedRollups.baselineTablesPreserved | Should -BeTrue
            @($r.Json.verification.derivedRollups.newlyAddedTables).Count | Should -Be 0
            $r.Json.verification.fieldsDictionary.applicable | Should -Be ($mode -ne 'plain')
            foreach ($table in @('message_rollup', 'message_rollup_dirty', 'sqlite_sequence')) {
                ($r.Json.verification.after | Where-Object name -EQ $table).sha256 |
                    Should -Be ($r.Json.verification.before | Where-Object name -EQ $table).sha256
            }
            # The logical '#Fields' text of source_file is the same in the copy, whatever its storage form.
            $logical = "SELECT group_concat(id || ':' || hex(COALESCE(fields,'~')),',') FROM (SELECT s.id AS id,{0} AS fields FROM source_file s {1} ORDER BY s.id);"
            if ($mode -eq 'plain') {
                (Read-Scalar $dest ($logical -f 's.fields', '')) | Should -Be (Read-Scalar $path ($logical -f 's.fields', ''))
                (Read-Scalar $dest "SELECT sql FROM sqlite_schema WHERE name='ix_msg_identity_time';") | Should -Match 'message_id COLLATE BINARY,time_ms,id'
            } else {
                (Read-Scalar $dest ($logical -f 'COALESCE(d.text,s.fields)', 'LEFT JOIN source_fields d ON d.id=s.fields_id')) | Should -Be (Read-Scalar $path ($logical -f 's.fields', ''))
                (Read-Scalar $dest 'SELECT count(*) FROM source_file WHERE fields IS NOT NULL;') | Should -Be 0
                (Read-Scalar $dest 'SELECT count(*) FROM source_fields;') | Should -Be 2
                (Read-Scalar $dest "SELECT sql FROM sqlite_schema WHERE name='ix_msg_identity_time';") | Should -Be 'CREATE INDEX ix_msg_identity_time ON message_event(msg_hash,time_ms)'
                (Read-Scalar $dest "SELECT sql FROM sqlite_schema WHERE name='ix_smtp_identity_time';") | Should -Be 'CREATE INDEX ix_smtp_identity_time ON smtp_transaction(msg_hash,time_ms)'
            }
            (Read-Scalar $dest 'SELECT min(id) FROM message_rollup;') | Should -Be 901
            (Read-Scalar $dest 'SELECT max(id) FROM message_rollup;') | Should -Be (Read-Scalar $path 'SELECT max(id) FROM message_rollup;')
            if ($mode -eq 'plain') {
                (Read-Scalar $dest "SELECT seq FROM sqlite_sequence WHERE name='message_rollup';") | Should -Be 1200
                (Read-Status $dest '<out@example.invalid>') | Should -Be 'Relayed'
                @($r.Json.verification.exclusions) | Should -Not -Contain $rulesExclusion
            } else {
                (Read-Scalar $dest "SELECT seq FROM sqlite_sequence WHERE name='message_rollup';") | Should -BeGreaterOrEqual 1200
                (Read-Status $dest '<out@example.invalid>') | Should -Be 'Handed off outside collection'
                $r.Json.verification.exclusions | Should -Contain $rulesExclusion
            }
            $r.Json.verification.rollupRules.applicable | Should -Be ($mode -ne 'plain')
            (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
        }
    }

    It 'migrates a genuine schema-10 copy to schema 13: rollup codes and SMTP client structures verified, every derived value outside the recipient rules (decoded) and ID identical, source untouched' {
        (Read-Scalar $source10Genuine "SELECT count(*) FROM sqlite_schema WHERE name IN ('message_rollup_value','smtp_client','smtp_client_hour');") | Should -Be 0
        (Read-Scalar $source10Genuine "SELECT count(*) FROM sqlite_schema WHERE name='ix_smtp_latest';") | Should -Be 1
        $path = New-Fixture 'existing-rollups10' -Schema10 -StatusRules
        Write-FixtureSql $path 'UPDATE message_rollup SET id=id+900; UPDATE sqlite_sequence SET seq=1200 WHERE name=''message_rollup''; UPDATE smtp_transaction SET remote_ep=''198.51.100.7:2525'',helo=''client.invalid'',tls=''TLS1.2'',auth_user=''proved@invalid'',auth_source=''Direct'',auth_result=''Succeeded'' WHERE id=201;'
        $hash = (Get-FileHash -LiteralPath $path).Hash
        foreach ($mode in @('plain', 'migrate', 'migrate-vacuum')) {
            $dest = Join-Path $work ("schema10-$mode.sqlite")
            $arguments = @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy')
            if ($mode -ne 'plain') { $arguments += '--migrate' }
            if ($mode -eq 'migrate-vacuum') { $arguments += '--vacuum' }
            $r = Invoke-Storage $arguments
            $r.Code | Should -Be 0 -Because $r.Error
            $r.Json.before.schemaVersion | Should -Be '10'
            $r.Json.after.schemaVersion | Should -Be $(if ($mode -eq 'plain') { '10' } else { '13' })
            $r.Json.verification.derivedRollups.schemaVersion | Should -Be $(if ($mode -eq 'plain') { '10' } else { '13' })
            $r.Json.verification.derivedRollups.validated | Should -BeTrue
            $r.Json.verification.smtpClients.applicable | Should -Be ($mode -ne 'plain')
            @($r.Json.verification.derivedRollups.newlyAddedTables).Count | Should -Be 0
            foreach ($table in @('message_rollup', 'message_rollup_dirty', 'sqlite_sequence', 'smtp_transaction', 'source_file')) {
                ($r.Json.verification.after | Where-Object name -EQ $table).sha256 |
                    Should -Be ($r.Json.verification.before | Where-Object name -EQ $table).sha256
            }
            (Read-Scalar $dest 'SELECT min(id) FROM message_rollup;') | Should -Be 901
            (Read-Scalar $dest 'SELECT max(id) FROM message_rollup;') | Should -Be (Read-Scalar $path 'SELECT max(id) FROM message_rollup;')
            if ($mode -eq 'plain') {
                (Read-Scalar $dest "SELECT seq FROM sqlite_sequence WHERE name='message_rollup';") | Should -Be 1200
                (Read-Status $dest '<out@example.invalid>') | Should -Be 'Relayed'
                @($r.Json.verification.exclusions) | Should -Not -Contain $rulesExclusion
            } else {
                (Read-Scalar $dest "SELECT seq FROM sqlite_sequence WHERE name='message_rollup';") | Should -BeGreaterOrEqual 1200
                (Read-Status $dest '<out@example.invalid>') | Should -Be 'Handed off outside collection'
                $r.Json.verification.exclusions | Should -Contain $rulesExclusion
            }
            $r.Json.verification.rollupRules.applicable | Should -Be ($mode -ne 'plain')
            if ($mode -ne 'plain') {
                (Read-Scalar $dest 'SELECT count(*) FROM message_rollup_value;') | Should -BeGreaterThan 0
                (Read-Scalar $dest 'SELECT count(*) FROM smtp_client;') | Should -Be 1
                (Read-Scalar $dest 'SELECT count(*) FROM smtp_client_hour;') | Should -Be 1
                (Read-Scalar $dest 'SELECT client_id FROM smtp_transaction WHERE id=201;') | Should -Not -BeNullOrEmpty
                (Read-Scalar $dest "SELECT count(*) FROM sqlite_schema WHERE name='ix_smtp_latest';") | Should -Be 0
            } else {
                (Read-Scalar $dest "SELECT count(*) FROM sqlite_schema WHERE name='ix_smtp_latest';") | Should -Be 1
            }
            (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
        }
    }

    It 'migrates a genuine schema-11 copy to schema 13: tracking rows recomputed by the schema-13 rules, ids and smtp rows identical, dictionary rows preserved, sequence not lower, source untouched' {
        (Read-Scalar $source11Genuine "SELECT sql FROM sqlite_schema WHERE name='tr_message_event_rollup_update';") | Should -Not -Match 'recipient_status'
        $path = New-Fixture 'existing-rollups11' -Schema11 -StatusRules
        Write-FixtureSql $path 'UPDATE message_rollup SET id=id+900; UPDATE sqlite_sequence SET seq=1200 WHERE name=''message_rollup'';'
        $hash = (Get-FileHash -LiteralPath $path).Hash
        foreach ($mode in @('plain', 'migrate', 'migrate-vacuum')) {
            $dest = Join-Path $work ("schema11-$mode.sqlite")
            $arguments = @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy')
            if ($mode -ne 'plain') { $arguments += '--migrate' }
            if ($mode -eq 'migrate-vacuum') { $arguments += '--vacuum' }
            $r = Invoke-Storage $arguments
            $r.Code | Should -Be 0 -Because $r.Error
            $r.Json.before.schemaVersion | Should -Be '11'
            $r.Json.after.schemaVersion | Should -Be $(if ($mode -eq 'plain') { '11' } else { '13' })
            $r.Json.verification.derivedRollups.schemaVersion | Should -Be $(if ($mode -eq 'plain') { '11' } else { '13' })
            $r.Json.verification.derivedRollups.validated | Should -BeTrue
            $r.Json.verification.derivedRollups.rulesVersion | Should -Match $(if ($mode -eq 'plain') { 'frozen' } else { 'engine' })
            $r.Json.verification.smtpClients.applicable | Should -BeFalse
            $r.Json.verification.rollupRules.applicable | Should -Be ($mode -ne 'plain')
            @($r.Json.verification.derivedRollups.newlyAddedTables).Count | Should -Be 0
            foreach ($table in @('message_rollup', 'message_rollup_dirty', 'sqlite_sequence', 'message_rollup_value', 'smtp_transaction', 'source_file')) {
                ($r.Json.verification.after | Where-Object name -EQ $table).sha256 |
                    Should -Be ($r.Json.verification.before | Where-Object name -EQ $table).sha256
            }
            (Read-Scalar $dest 'SELECT min(id) FROM message_rollup;') | Should -Be 901
            (Read-Scalar $dest 'SELECT max(id) FROM message_rollup;') | Should -Be (Read-Scalar $path 'SELECT max(id) FROM message_rollup;')
            (Read-Scalar $dest 'SELECT count(*) FROM message_rollup_value;') | Should -BeGreaterOrEqual (Read-Scalar $path 'SELECT count(*) FROM message_rollup_value;')
            $dictionary = "SELECT group_concat(id || ':' || text, ',') FROM (SELECT id,text FROM message_rollup_value WHERE id <= $(Read-Scalar $path 'SELECT max(id) FROM message_rollup_value;') ORDER BY id);"
            (Read-Scalar $dest $dictionary) | Should -Be (Read-Scalar $path $dictionary)
            $trigger = Read-Scalar $dest "SELECT sql FROM sqlite_schema WHERE name='tr_message_event_rollup_update';"
            if ($mode -eq 'plain') {
                $trigger | Should -Not -Match 'recipient_status,related_recipient'
                (Read-Scalar $dest "SELECT seq FROM sqlite_sequence WHERE name='message_rollup';") | Should -Be 1200
                (Read-Status $dest '<out@example.invalid>') | Should -Be 'Relayed'
                (Read-Scalar $dest "SELECT recipients FROM message_rollup WHERE kind=0 AND identity='<out@example.invalid>';") | Should -Be '["b@example.invalid (Sent)"]'
                @($r.Json.verification.exclusions).Count | Should -Be 0
            } else {
                $trigger | Should -Match 'recipient_status,related_recipient'
                (Read-Scalar $dest "SELECT seq FROM sqlite_sequence WHERE name='message_rollup';") | Should -BeGreaterOrEqual 1200
                (Read-Status $dest '<out@example.invalid>') | Should -Be 'Handed off outside collection'
                (Read-Status $dest '<relay@example.invalid>') | Should -Be 'Delivered and handed off'
                (Read-Scalar $dest "SELECT recipients FROM message_rollup WHERE kind=0 AND identity='<out@example.invalid>';") | Should -Be '["b@example.invalid (Handed off)"]'
                $r.Json.verification.exclusions | Should -Contain 'metadata.schema_version'
                $r.Json.verification.exclusions | Should -Contain $rulesExclusion
                ($r.Json.verification.exclusions -join '|') | Should -Match 'message_rollup_value rows added by the schema-13 reconciliation \(ids above the source maximum \d+\) only'
                ($r.Json.verification.exclusions -join '|') | Should -Not -Match 'smtp_client_value'
                $r.Json.verification.rollupRules.valueDictionaryMaxSourceId | Should -Be (Read-Scalar $path 'SELECT max(id) FROM message_rollup_value;')
                $r.Json.verification.rollupRules.sequenceBefore | Should -Be 1200
                $r.Json.verification.rollupRules.sequenceAfter | Should -BeGreaterOrEqual 1200
            }
            (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
        }
    }

    It 'migrates a genuine schema-12 copy to schema 13: only the message that left the organization changes status, every id and the sequence kept; a plain copy is verified by the schema-12 rules' {
        $path = New-Fixture 'source12genuine' -Schema12 -StatusRules -External
        Write-FixtureSql $path 'UPDATE message_rollup SET id=id+900; UPDATE sqlite_sequence SET seq=1200 WHERE name=''message_rollup'';'
        $hash = (Get-FileHash -LiteralPath $path).Hash
        (Read-Scalar $path "SELECT value FROM metadata WHERE key='schema_version';") | Should -Be '12'
        (Read-Status $path '<external@example.invalid>') | Should -Be 'Handed off outside collection'
        $ids = "SELECT group_concat(id||'|'||kind||'|'||identity,';') FROM (SELECT id,kind,identity FROM message_rollup ORDER BY id);"
        $before = Read-Scalar $path $ids
        # Without --migrate: the schema-12 rules, without the external status.
        $plain = Join-Path $work 'source12genuine-plain.sqlite'
        $r = Invoke-Storage @('--storage-copy', '--database', $path, '--destination', $plain, '--confirm-copy')
        $r.Code | Should -Be 0 -Because $r.Error
        $r.Json.after.schemaVersion | Should -Be '12'
        $r.Json.verification.derivedRollups.rulesVersion | Should -Be 'schema-12 recipient rules (engine)'
        (Read-Status $plain '<external@example.invalid>') | Should -Be 'Handed off outside collection'
        $dest = Join-Path $work 'source12genuine-migrated.sqlite'
        $r = Invoke-Storage @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy', '--migrate')
        $r.Code | Should -Be 0 -Because $r.Error
        $r.Json.after.schemaVersion | Should -Be '13'
        $r.Json.verification.derivedRollups.schemaVersion | Should -Be '13'
        $r.Json.verification.exclusions | Should -Contain $rulesExclusion
        foreach ($key in 'metadata.schema_version', 'metadata.mailflow_accepted_domains', 'metadata.mailflow_rules') { $r.Json.verification.exclusions | Should -Contain $key }
        @($r.Json.verification.exclusions | Where-Object { $_ -like 'added mail_flow_hour*' -or $_ -like 'metadata.*max_span_ms' }).Count | Should -Be 0
        ($r.Json.verification.exclusions -join '|') | Should -Match 'message_rollup_value rows added by the schema-13 reconciliation \(ids above the source maximum \d+\) only'
        (Read-Status $dest '<external@example.invalid>') | Should -Be 'Sent to external'
        (Read-Scalar $dest "SELECT recipients FROM message_rollup WHERE kind=0 AND identity='<external@example.invalid>';") | Should -Be '["partner@fabrikam.example (Sent to external)"]'
        (Read-Status $dest '<out@example.invalid>') | Should -Be 'Handed off outside collection'
        (Read-Status $dest '<relay@example.invalid>') | Should -Be 'Delivered and handed off'
        (Read-Scalar $dest $ids) | Should -BeExactly $before
        (Read-Scalar $dest "SELECT seq FROM sqlite_sequence WHERE name='message_rollup';") | Should -BeGreaterOrEqual 1200
        (Read-Scalar $dest "SELECT value FROM metadata WHERE key='mailflow_accepted_domains';") | Should -BeExactly 'example.invalid'
        (Read-Scalar $dest "SELECT count(*) FROM sqlite_schema WHERE name='tr_message_event_rollup_update' AND sql LIKE '%,connector,server_ip,server_host ON message_event%';") | Should -Be 1
        (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
    }

    It 'verifies genuine schema-8, -9, -10 and -11 rows with the recipient rules they were written with' {
        foreach ($item in @(@{ Path = $source8; Hash = $source8Hash; Schema = '8' }, @{ Path = $source9Genuine; Hash = $source9GenuineHash; Schema = '9' },
                @{ Path = $source10Genuine; Hash = $source10GenuineHash; Schema = '10' }, @{ Path = $source11Genuine; Hash = $source11GenuineHash; Schema = '11' })) {
            (Read-Status $item.Path '<out@example.invalid>') | Should -Be 'Relayed'
            (Read-Status $item.Path '<relay@example.invalid>') | Should -Be 'Delivered and relayed'
            $dest = Join-Path $work ("frozen-rules-$($item.Schema).sqlite")
            $r = Invoke-Storage @('--storage-copy', '--database', $item.Path, '--destination', $dest, '--confirm-copy')
            $r.Code | Should -Be 0 -Because $r.Error
            $r.Json.after.schemaVersion | Should -Be $item.Schema
            $r.Json.verification.derivedRollups.schemaVersion | Should -Be $item.Schema
            $r.Json.verification.derivedRollups.rulesVersion | Should -Be 'schema 8 to 11 recipient rules (frozen in the host)'
            $r.Json.verification.rollupRules.applicable | Should -BeFalse
            (Read-Status $dest '<out@example.invalid>') | Should -Be 'Relayed'
            (Read-Status $dest '<relay@example.invalid>') | Should -Be 'Delivered and relayed'
            (Get-FileHash -LiteralPath $item.Path).Hash | Should -Be $item.Hash
        }
        # The current schema is verified by the engine rules.
        $dest = Join-Path $work 'engine-rules-13.sqlite'
        $r = Invoke-Storage @('--storage-copy', '--database', $source9, '--destination', $dest, '--confirm-copy')
        $r.Code | Should -Be 0 -Because $r.Error
        $r.Json.verification.derivedRollups.rulesVersion | Should -Be 'schema-13 recipient rules (engine, with the stored rules of the external status)'
        (Read-Status $dest '<out@example.invalid>') | Should -Be 'Handed off outside collection'
        (Get-FileHash -LiteralPath $source9).Hash | Should -Be $source9Hash
    }

    It 'rejects a schema-12 database relabelled 11 and an 11-shaped database relabelled 12' {
        foreach ($case in @(@{ Name = 'relabel-11'; Schema11 = $false; Value = '11' }, @{ Name = 'relabel-12'; Schema11 = $true; Value = '12' })) {
            $path = New-Fixture $case.Name -Schema11:$case.Schema11 -StatusRules
            Write-FixtureSql $path "UPDATE metadata SET value='$($case.Value)' WHERE key='schema_version';"
            $hash = (Get-FileHash -LiteralPath $path).Hash
            foreach ($migrate in @($false, $true)) {
                $dest = Join-Path $work ("$($case.Name)-$migrate-copy.sqlite")
                $arguments = @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy')
                if ($migrate) { $arguments += '--migrate' }
                $r = Invoke-Storage $arguments
                $r.Code | Should -Be 2
                $r.Json.success | Should -BeFalse
                $r.Error | Should -Match ("Schema-" + $case.Value + " derived rollup verification failed")
                Test-Path -LiteralPath $dest | Should -BeFalse
                Test-Path -LiteralPath ($dest + '.maintenance.json') | Should -BeFalse
                (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
            }
        }
    }

    It 'publishes no copy when the schema-12 reconciliation is aborted' {
        $path = New-Fixture 'abort12' -Schema11 -StatusRules
        Write-FixtureSql $path "CREATE TRIGGER fail12 BEFORE UPDATE ON metadata WHEN NEW.key='schema_version' AND NEW.value='12' BEGIN SELECT RAISE(ABORT,'synthetic'); END;"
        $hash = (Get-FileHash -LiteralPath $path).Hash
        $dest = Join-Path $work 'abort12-copy.sqlite'
        $output = Join-Path $work 'abort12.json'
        $r = Invoke-Storage @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy', '--migrate', '--output', $output)
        $r.Code | Should -Be 2
        $r.Json.success | Should -BeFalse
        Test-Path -LiteralPath $dest | Should -BeFalse
        Test-Path -LiteralPath $output | Should -BeFalse
        @(Get-ChildItem -LiteralPath $work -Filter '*abort12-copy*.stage.sqlite' -Force).Count | Should -Be 0
        (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
    }

    It 'publishes no copy when the dictionary migration cannot reproduce a header text exactly' {
        $path = New-Fixture 'dictionary-failure' -Schema9
        # The trigger alters the header text of a row right after the migration pointed it at the dictionary: the byte-for-byte check must refuse it.
        Write-FixtureSql $path "CREATE TRIGGER synthetic_bad_dictionary AFTER UPDATE ON source_file WHEN NEW.fields IS NOT NULL AND NEW.fields NOT LIKE '%!' BEGIN UPDATE source_file SET fields=NEW.fields || '!' WHERE id=NEW.id; END;"
        $hash = (Get-FileHash -LiteralPath $path).Hash
        $dest = Join-Path $work 'dictionary-failure-copy.sqlite'
        $r = Invoke-Storage @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy', '--migrate', '--output', (Join-Path $work 'dictionary-failure.json'))
        $r.Code | Should -Be 2
        $r.Json.success | Should -BeFalse
        $r.Error | Should -Match 'InvalidOperationException'   # the migration's own check; the host diagnostic does not echo exception text
        Test-Path -LiteralPath $dest | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $work 'dictionary-failure.json') | Should -BeFalse
        (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
        @(Get-ChildItem -LiteralPath $work -Filter '*dictionary-failure*.stage.sqlite' -Force).Count | Should -Be 0
    }

    It 'verifies SMTP-only rollups against exact raw transaction IDs without inventing accepted or send groups' {
        $path = New-Fixture 'standalone-smtp' -Schema7 -StandaloneSmtp
        $hash = (Get-FileHash -LiteralPath $path).Hash
        $dest = Join-Path $work 'standalone-smtp-copy.sqlite'
        $r = Invoke-Storage @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy', '--migrate')
        $r.Code | Should -Be 0 -Because $r.Error
        $r.Json.verification.derivedRollups.validated | Should -BeTrue
        (Read-Scalar $dest "SELECT group_concat(identity,',') FROM message_rollup WHERE kind=1;") | Should -Be '202'
        (Read-Scalar $dest 'SELECT count(*) FROM smtp_transaction WHERE id IN (202,203,204);') | Should -Be 3
        (Read-Scalar $dest 'SELECT count(*) FROM message_rollup_dirty;') | Should -Be 0
        (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
    }

    It 'migrates genuinely empty legacy stores with empty derived tables and no invented sequence value' {
        foreach ($schema in @(6, 7)) {
            $path = Join-Path $work ("empty-$schema.sqlite")
            $store = [ExchangeLogReport.Store]::new($path, $false, 'synthetic-preserved-tool')
            try {
                Set-LegacyStorageFixture ([ServeFixtures]::Connection($store)) $schema
                $store.Exec('PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;')
            } finally { $store.Dispose() }
            $hash = (Get-FileHash -LiteralPath $path).Hash
            $dest = Join-Path $work ("empty-$schema-copy.sqlite")
            $r = Invoke-Storage @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy', '--migrate')
            $r.Code | Should -Be 0 -Because $r.Error
            $r.Json.verification.derivedRollups.validated | Should -BeTrue
            (Read-Scalar $dest 'SELECT count(*) FROM message_rollup;') | Should -Be 0
            (Read-Scalar $dest "SELECT count(*) FROM sqlite_sequence WHERE name='message_rollup';") | Should -Be 0
            (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
        }
    }

    It 'rejects inconsistent rollups, dirty queues, missing groups and changed derived schemas without repairing sources' {
        $cases = [ordered]@{
            summary = 'UPDATE message_rollup SET events_count=999 WHERE id=1;'
            dirty = "INSERT INTO message_rollup_dirty VALUES('message','<untracked@example.invalid>',123);"
            missing = 'DELETE FROM message_rollup WHERE id=1;'
            identity = "UPDATE message_rollup SET identity='<untracked@example.invalid>' WHERE id=1;"
            schema = 'ALTER TABLE message_rollup ADD COLUMN unexpected TEXT;'
            dictionary = 'UPDATE source_file SET fields_id=999 WHERE id=41;'
            wideindex = 'DROP INDEX ix_msg_identity_time; CREATE INDEX ix_msg_identity_time ON message_event(msg_hash,message_id COLLATE BINARY,time_ms,id);'
            dictionarytable = 'DROP TABLE source_fields;'
            trigger = 'DROP TRIGGER tr_message_event_rollup_delete; CREATE TRIGGER tr_message_event_rollup_delete AFTER DELETE ON message_event BEGIN SELECT 1; END;'
            danglingstatus = 'UPDATE message_rollup SET status=99999 WHERE id=1;'
            clientorphan = "INSERT INTO smtp_client(server,direction,remote_host) VALUES('SYNTHETIC','Receive','198.51.100.9');"
            clientbucket = "INSERT INTO smtp_client(id,server,direction,remote_host) VALUES(7,'SYNTHETIC','Receive','198.51.100.9'); UPDATE smtp_transaction SET client_id=7 WHERE id=201;"
            clienttrigger = 'DROP TRIGGER tr_smtp_transaction_client_insert;'
            clientindex = 'DROP INDEX ix_smtp_client;'
            clientpending = 'INSERT INTO smtp_client_pending VALUES(201);'
            # A pre-12 label in a schema-12 file, and the schema-11 UPDATE trigger in a schema-12 file.
            rules = "INSERT OR IGNORE INTO message_rollup_value(text) VALUES('Relayed'); UPDATE message_rollup SET status=(SELECT id FROM message_rollup_value WHERE text='Relayed') WHERE kind=0 AND identity='<out@example.invalid>';"
            updatetrigger12 = 'DROP TRIGGER tr_message_event_rollup_update; CREATE TRIGGER tr_message_event_rollup_update AFTER UPDATE OF id,message_id,time_ms,server,event_id,sender,recipients,recipient_count,total_bytes,subject,directionality ON message_event BEGIN SELECT 1; END;'
            # Schema 12 covering indexes and span bounds: a partial pre-release shape, a missing trigger, a bound below a stored span (the
            # -StatusRules journeys span seconds), and the start_ms-only session index next to the covering rollup indexes.
            spanindex = 'DROP INDEX ix_rollup_last; CREATE INDEX ix_rollup_last ON message_rollup(member_last_ms);'
            spantrigger = 'DROP TRIGGER tr_rollup_span_insert;'
            spanlow = "UPDATE metadata SET value='0' WHERE key='rollup_max_span_ms';"
            sessionindex = 'DROP INDEX ix_session_time; CREATE INDEX ix_session_time ON client_session(start_ms);'
            # Schema 12 mail flow per hour: a non-canonical trigger, a counter the rows do not give, a queued bucket, a missing index of the shape.
            flowtrigger = "DROP TRIGGER tr_message_event_flow_delete; CREATE TRIGGER tr_message_event_flow_delete AFTER DELETE ON message_event BEGIN SELECT 1; END;"
            flowrow = 'UPDATE mail_flow_hour SET messages=messages+1 WHERE hour_ms=(SELECT MIN(hour_ms) FROM mail_flow_hour);'
            flowdirty = "INSERT INTO mail_flow_dirty VALUES(0,'SYNTHETIC');"
            flowindex = 'DROP INDEX ix_event_resolution;'
        }
        (Read-Scalar (New-Fixture 'span-check' -StatusRules) 'SELECT max(member_last_ms-member_first_ms) FROM message_rollup;') | Should -BeGreaterThan 0
        foreach ($case in $cases.Keys) {
            $path = New-Fixture ("invalid-rollups-$case") -StatusRules
            Write-FixtureSql $path $cases[$case]
            $hash = (Get-FileHash -LiteralPath $path).Hash
            $dest = Join-Path $work ("invalid-rollups-$case-copy.sqlite")
            $r = Invoke-Storage @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy', '--migrate')
            $r.Code | Should -Be 2
            $r.Json.success | Should -BeFalse
            $r.Error | Should -Match 'derived rollup verification failed'
            Test-Path -LiteralPath $dest | Should -BeFalse
            Test-Path -LiteralPath ($dest + '.maintenance.json') | Should -BeFalse
            (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
        }
    }

    It 'migrates a schema-12 copy of an earlier shape (<Shape>) with --migrate and keeps its shape without it' -ForEach @(
        @{ Shape = 'before the covering indexes'; Name = 'prerelease12'; Convert = 'ConvertToPreReleaseSchema12'; Spans = 0; OldStatus = 'Not completed (SMTP)'
            Exclusion = 'ix_rollup_last, ix_rollup_status_last and ix_session_time rebuilt as covering indexes; ix_msg_noid_flow, ix_event_resolution and ix_usage_day_success added; span-bound metadata and triggers added'
            Index = 'CREATE INDEX ix_rollup_last ON message_rollup(member_last_ms)' },
        @{ Shape = 'covering indexes without events_count and kind'; Name = 'covering12'; Convert = 'ConvertToCoveringSchema12'; Spans = 2; OldStatus = 'Not completed (SMTP)'
            Exclusion = 'ix_rollup_last and ix_rollup_status_last rebuilt with events_count, kind, direction and servers; ix_msg_noid_flow, ix_event_resolution and ix_usage_day_success added'
            Index = 'CREATE INDEX ix_rollup_last ON message_rollup(member_last_ms,member_first_ms,status)' },
        @{ Shape = 'rollup indexes without direction and servers, no mail flow per hour'; Name = 'tracked12'; Convert = 'ConvertToTrackedSchema12'; Spans = 2; OldStatus = 'Sent (SMTP)'
            Exclusion = 'ix_rollup_last and ix_rollup_status_last rebuilt with direction and servers; ix_msg_noid_flow, ix_event_resolution and ix_usage_day_success added'
            Index = 'CREATE INDEX ix_rollup_last ON message_rollup(member_last_ms,member_first_ms,status,events_count,kind)' }
    ) {
        $path = New-Fixture $Name -StatusRules -SentSmtp
        $db = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$path;Pooling=False"); $db.Open()
        try { [ServeFixtures]::$Convert($db) } finally { $db.Dispose() }
        $hash = (Get-FileHash -LiteralPath $path).Hash
        $status = "SELECT v.text FROM message_rollup r JOIN message_rollup_value v ON v.id=r.status WHERE r.identity='<sent-only@example.invalid>';"
        (Read-Scalar $path $status) | Should -BeExactly $OldStatus
        $dest = Join-Path $work "$Name-migrated.sqlite"
        $r = Invoke-Storage @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy', '--migrate')
        $r.Code | Should -Be 0 -Because $r.Error
        $r.Json.verification.exclusions | Should -Contain $Exclusion
        @($r.Json.verification.exclusions | Where-Object { $_ -like 'message_rollup status, recipients*kind 0 are verified by exact recomputation*Sent (SMTP)*' }).Count | Should -Be 1
        $r.Json.verification.exclusions | Should -Contain 'metadata.rollup_max_span_ms'
        (Read-Scalar $dest "SELECT sql FROM sqlite_schema WHERE name='ix_rollup_last';") | Should -BeExactly 'CREATE INDEX ix_rollup_last ON message_rollup(member_last_ms,member_first_ms,status,events_count,kind,direction,servers)'
        (Read-Scalar $dest "SELECT sql FROM sqlite_schema WHERE name='ix_rollup_status_last';") | Should -BeExactly 'CREATE INDEX ix_rollup_status_last ON message_rollup(status,member_last_ms,member_first_ms,events_count,kind,direction,servers)'
        # The mail flow per hour is built in the copy, proved by recomputation and named in the report.
        (Read-Scalar $dest "SELECT count(*) FROM sqlite_schema WHERE name IN('mail_flow_hour','mail_flow_dirty','ix_msg_noid_flow','ix_event_resolution','ix_usage_day_success') OR (type='trigger' AND name LIKE 'tr_%_flow_%');") | Should -Be 11
        (Read-Scalar $dest 'SELECT count(*) FROM mail_flow_hour;') | Should -BeGreaterThan 0
        $r.Json.verification.mailFlow.method | Should -BeExactly 'recomputation'
        $r.Json.verification.mailFlow.added | Should -BeTrue
        $r.Json.verification.mailFlow.applicable | Should -BeTrue
        $r.Json.verification.exclusions | Should -Contain 'added mail_flow_hour and mail_flow_dirty tables and their six triggers only (derived from the copied tracking events and SMTP transactions)'
        (Read-Scalar $dest "SELECT sql FROM sqlite_schema WHERE name='ix_session_time';") | Should -BeExactly 'CREATE INDEX ix_session_time ON client_session(start_ms,end_ms,requests)'
        (Read-Scalar $dest "SELECT CAST(value AS INTEGER) FROM metadata WHERE key='rollup_max_span_ms';") | Should -Be (Read-Scalar $dest 'SELECT max(member_last_ms-member_first_ms) FROM message_rollup;')
        (Read-Scalar $dest "SELECT count(*) FROM sqlite_schema WHERE type='trigger' AND name LIKE 'tr_%_span_%';") | Should -Be 4
        (Read-Scalar $dest $status) | Should -BeExactly 'Sent (SMTP)'
        # Without --migrate the source shape is accepted and kept (Serve refuses that copy with ShapeRequired until a writable open).
        $plain = Join-Path $work "$Name-plain.sqlite"
        $r = Invoke-Storage @('--storage-copy', '--database', $path, '--destination', $plain, '--confirm-copy')
        $r.Code | Should -Be 0 -Because $r.Error
        $r.Json.verification.exclusions | Should -Not -Contain $Exclusion
        (Read-Scalar $plain "SELECT sql FROM sqlite_schema WHERE name='ix_rollup_last';") | Should -BeExactly $Index
        (Read-Scalar $plain "SELECT count(*) FROM metadata WHERE key LIKE '%max_span_ms';") | Should -Be $Spans
        (Read-Scalar $plain $status) | Should -BeExactly $OldStatus
        (Read-Scalar $plain "SELECT count(*) FROM sqlite_schema WHERE name IN('mail_flow_hour','mail_flow_dirty');") | Should -Be 0
        $r.Json.verification.mailFlow.applicable | Should -BeFalse
        # A repack opens the copy writable, which would change its shape: it requires --migrate.
        $repack = Invoke-Storage @('--storage-copy', '--database', $path, '--destination', (Join-Path $work "$Name-repack.sqlite"), '--confirm-copy', '--repack')
        $repack.Code | Should -Be 2
        $repack.Error | Should -Match 'requires the current schema or explicit --migrate'
        (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
    }

    It 'migrates a schema-12 copy without the authentication columns with --migrate, keeps its shape without it, and refuses --repack alone' {
        $path = New-Fixture 'step3' -StatusRules -SentSmtp
        Write-FixtureSql $path @"
INSERT INTO access_client(day,user,protocol,client_ip,user_agent,device_id,device_type,software,requests,failures,first_ms,last_ms,servers,auth_type) VALUES
('2026-10-14','alpha@example.invalid','Eas','10.0.0.1','Apple-iPhone','DEV1','iPhone',NULL,7,1,1791979200000,1791979205000,'synthetic-mail','Basic'),
('2026-10-14','alpha@example.invalid','Ews','10.0.0.1','MacOutlook','',NULL,NULL,3,0,1791979200000,1791979201000,'synthetic-mail','OAuth');
INSERT INTO client_session(skey,day,start_ms,end_ms,user,protocol,requests,successes,failures,slow,first_success_ms,last_success_ms,first_failure_ms,last_failure_ms,total_ms,max_ms,bytes_in,bytes_out,auth_modes) VALUES
('2026-10-14|alpha@example.invalid|k','2026-10-14',1791979200000,1791979205000,'alpha@example.invalid','Eas',7,6,1,0,1791979200000,1791979205000,1791979201000,1791979201000,70,20,1,1,'Basic=7');
"@
        $db = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$path;Pooling=False"); $db.Open()
        try { [ServeFixtures]::ConvertToStep3Schema12($db) } finally { $db.Dispose() }
        $hash = (Get-FileHash -LiteralPath $path).Hash
        $key = "SELECT group_concat(name,',') FROM (SELECT name FROM pragma_table_info('access_client') WHERE pk>0 ORDER BY pk);"
        $dest = Join-Path $work 'step3-migrated.sqlite'
        $r = Invoke-Storage @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy', '--migrate')
        $r.Code | Should -Be 0 -Because $r.Error
        $r.Json.verification.exclusions | Should -Contain "access_client rebuilt with the key column auth_type (every copied row has ''); client_session.auth_modes added (NULL); no row of any other table changes"
        # The authentication columns and the schema-13 step change only: the recipient rules of the tracking rows, no new mail flow, the span bounds kept.
        @($r.Json.verification.exclusions | Where-Object { $_ -like 'added mail_flow_hour*' -or $_ -like 'metadata.*max_span_ms' }).Count | Should -Be 0
        $r.Json.verification.exclusions | Should -Contain $rulesExclusion
        $r.Json.verification.rollupRules.applicable | Should -BeTrue
        $r.Json.verification.mailFlow.applicable | Should -BeTrue
        $r.Json.verification.mailFlow.added | Should -BeFalse
        (Read-Scalar $dest $key) | Should -BeExactly 'day,user,protocol,client_ip,user_agent,device_id,auth_type'
        (Read-Scalar $dest 'SELECT count(*) FROM access_client;') | Should -Be 2
        (Read-Scalar $dest "SELECT count(*) FROM access_client WHERE auth_type<>'';") | Should -Be 0
        (Read-Scalar $dest 'SELECT sum(requests) FROM access_client;') | Should -Be 10
        (Read-Scalar $dest "SELECT count(*) FROM pragma_table_info('client_session') WHERE name='auth_modes';") | Should -Be 1
        (Read-Scalar $dest 'SELECT count(*) FROM client_session WHERE auth_modes IS NOT NULL;') | Should -Be 0
        (Read-Scalar $dest "SELECT count(*) FROM sqlite_schema WHERE type='index' AND name='ix_client_user';") | Should -Be 1
        # Without --migrate the source shape is kept (Serve answers ShapeRequired on that copy until a writable open).
        $plain = Join-Path $work 'step3-plain.sqlite'
        $r = Invoke-Storage @('--storage-copy', '--database', $path, '--destination', $plain, '--confirm-copy')
        $r.Code | Should -Be 0 -Because $r.Error
        @($r.Json.verification.exclusions | Where-Object { $_ -like 'access_client rebuilt*' }).Count | Should -Be 0
        (Read-Scalar $plain $key) | Should -BeExactly 'day,user,protocol,client_ip,user_agent,device_id'
        (Read-Scalar $plain "SELECT count(*) FROM pragma_table_info('client_session') WHERE name='auth_modes';") | Should -Be 0
        # A repack opens the copy writable, which would fold it: it requires --migrate.
        $repack = Invoke-Storage @('--storage-copy', '--database', $path, '--destination', (Join-Path $work 'step3-repack.sqlite'), '--confirm-copy', '--repack')
        $repack.Code | Should -Be 2
        $repack.Error | Should -Match 'requires the current schema or explicit --migrate'
        (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
    }

    It 'adds the identity_map table, empty, to a copy opened writable whose source has none, and only then' {
        $identityExclusion = 'added identity_map table and its index only (empty, verified COUNT(*) = 0)'
        $legacy = New-Fixture 'noidentity8' -Schema8
        Write-FixtureSql $legacy 'DROP TABLE identity_map;'
        $hash = (Get-FileHash -LiteralPath $legacy).Hash
        $migrated = Join-Path $work 'noidentity8-migrated.sqlite'
        $r = Invoke-Storage @('--storage-copy', '--database', $legacy, '--destination', $migrated, '--confirm-copy', '--migrate')
        $r.Code | Should -Be 0 -Because $r.Error
        $r.Json.verification.exclusions | Should -Contain $identityExclusion
        (Read-Scalar $migrated 'SELECT count(*) FROM identity_map;') | Should -Be 0
        (Read-Scalar $migrated "SELECT count(*) FROM sqlite_schema WHERE type='index' AND name='ix_identity_user';") | Should -Be 1
        # Without --migrate the copy keeps the tables of its source.
        $plain = Join-Path $work 'noidentity8-plain.sqlite'
        $r = Invoke-Storage @('--storage-copy', '--database', $legacy, '--destination', $plain, '--confirm-copy')
        $r.Code | Should -Be 0 -Because $r.Error
        $r.Json.verification.exclusions | Should -Not -Contain $identityExclusion
        (Read-Scalar $plain "SELECT count(*) FROM sqlite_schema WHERE name='identity_map';") | Should -Be 0
        (Get-FileHash -LiteralPath $legacy).Hash | Should -Be $hash
        # A current-schema source of an earlier 3.0 build: a repack opens the copy writable and adds the table.
        $current = New-Fixture 'noidentity12'
        Write-FixtureSql $current 'DROP TABLE identity_map;'
        $repacked = Join-Path $work 'noidentity12-repack.sqlite'
        $r = Invoke-Storage @('--storage-copy', '--database', $current, '--destination', $repacked, '--confirm-copy', '--repack')
        $r.Code | Should -Be 0 -Because $r.Error
        $r.Json.verification.exclusions | Should -Contain $identityExclusion
        (Read-Scalar $repacked 'SELECT count(*) FROM identity_map;') | Should -Be 0
        # A source that has the table (with rows) keeps them, compared like every other table.
        $kept = New-Fixture 'identity12'
        Write-FixtureSql $kept "INSERT INTO identity_map(sid,user,status,names,lines,first_ms,last_ms) VALUES('s-1-5-21-1-2-3-1110','contoso\hank','resolved','anchor:contoso\hank=3',4,1791979200000,1791979200000);"
        $copy = Join-Path $work 'identity12-copy.sqlite'
        $r = Invoke-Storage @('--storage-copy', '--database', $kept, '--destination', $copy, '--confirm-copy', '--repack')
        $r.Code | Should -Be 0 -Because $r.Error
        $r.Json.verification.exclusions | Should -Not -Contain $identityExclusion
        (Read-Scalar $copy "SELECT user FROM identity_map WHERE sid='s-1-5-21-1-2-3-1110';") | Should -Be 'contoso\hank'
    }

    It 'folds the authentication columns into a migrated legacy copy (schema <Schema>) with every client row kept' -ForEach @(@{ Schema = 7; Source = 'source7' }, @{ Schema = 11; Source = 'source11Genuine' }) {
        $source = Get-Variable -Name $Source -ValueOnly
        (Read-Scalar $source "SELECT count(*) FROM pragma_table_info('client_session') WHERE name='auth_modes';") | Should -Be 0
        $dest = Join-Path $work "auth-legacy-$Schema.sqlite"
        $r = Invoke-Storage @('--storage-copy', '--database', $source, '--destination', $dest, '--confirm-copy', '--migrate')
        $r.Code | Should -Be 0 -Because $r.Error
        $r.Json.verification.exclusions | Should -Contain "access_client rebuilt with the key column auth_type (every copied row has ''); client_session.auth_modes added (NULL)"
        (Read-Scalar $dest "SELECT count(*) FROM pragma_table_info('access_client') WHERE name='auth_type' AND pk=7;") | Should -Be 1
        (Read-Scalar $dest "SELECT count(*) FROM pragma_table_info('client_session') WHERE name='auth_modes';") | Should -Be 1
    }

    It 'gives the same results with the merge scan, with a new command per statement and with per-identity point reads' {
        $smtp = New-Fixture 'equivalence-smtp' -StandaloneSmtp
        $summary = New-Fixture 'equivalence-summary' -StatusRules
        Write-FixtureSql $summary 'UPDATE message_rollup SET events_count=999 WHERE id=1;'
        $missing = New-Fixture 'equivalence-missing' -StatusRules
        Write-FixtureSql $missing 'DELETE FROM message_rollup WHERE id=1;'
        $rules = New-Fixture 'equivalence-rules' -StatusRules
        Write-FixtureSql $rules "INSERT OR IGNORE INTO message_rollup_value(text) VALUES('Relayed'); UPDATE message_rollup SET status=(SELECT id FROM message_rollup_value WHERE text='Relayed') WHERE kind=0 AND identity='<out@example.invalid>';"
        $cases = @(
            @{ Name = 'current'; Path = $source9; Migrate = $false; Success = $true },
            @{ Name = 'schema8'; Path = $source8; Migrate = $false; Success = $true },
            @{ Name = 'schema11'; Path = $source11Genuine; Migrate = $false; Success = $true },
            @{ Name = 'schema11-migrate'; Path = $source11Genuine; Migrate = $true; Success = $true },
            @{ Name = 'smtp-migrate'; Path = $smtp; Migrate = $true; Success = $true },
            @{ Name = 'summary'; Path = $summary; Migrate = $true; Success = $false },
            @{ Name = 'missing'; Path = $missing; Migrate = $true; Success = $false },
            @{ Name = 'rules'; Path = $rules; Migrate = $false; Success = $false })
        foreach ($case in $cases) {
            $hash = (Get-FileHash -LiteralPath $case.Path).Hash
            $results = foreach ($mode in @(@{ Uncached = $false; Point = $false }, @{ Uncached = $true; Point = $false }, @{ Uncached = $false; Point = $true })) {
                $dest = Join-Path $work ("equivalence-$($case.Name)-$($mode.Uncached)-$($mode.Point).sqlite")
                $arguments = @('--storage-copy', '--database', $case.Path, '--destination', $dest, '--confirm-copy')
                if ($case.Migrate) { $arguments += '--migrate' }
                $r = Invoke-Storage $arguments -UncachedReads:$mode.Uncached -PointReads:$mode.Point
                [pscustomobject]@{ Result = $r; Dest = $dest; Uncached = $mode.Uncached; Point = $mode.Point }
            }
            $cached, $reference, $point = $results[0], $results[1], $results[2]
            foreach ($other in $reference, $point) {
                $cached.Result.Code | Should -Be $other.Result.Code -Because $case.Name
                $cached.Result.Error | Should -Be $other.Result.Error -Because $case.Name
            }
            if ($case.Success) {
                $cached.Result.Json.verification.derivedRollups.method | Should -BeExactly 'merge-scan'
                $point.Result.Json.verification.derivedRollups.method | Should -BeExactly 'per-identity'
                ($cached.Result.Json.verification.after | ConvertTo-Json -Compress -Depth 5) | Should -Be ($point.Result.Json.verification.after | ConvertTo-Json -Compress -Depth 5) -Because $case.Name
            }
            $cached.Result.Code | Should -Be $reference.Result.Code -Because $case.Name
            $cached.Result.Error | Should -Be $reference.Result.Error -Because $case.Name
            $cached.Result.Json.success | Should -Be $reference.Result.Json.success -Because $case.Name
            if ($case.Success) {
                $cached.Result.Code | Should -Be 0 -Because $cached.Result.Error
                $cached.Result.Json.verification.derivedRollups.preparedStatements | Should -BeTrue
                $reference.Result.Json.verification.derivedRollups.preparedStatements | Should -BeFalse
                ($cached.Result.Json.verification.after | ConvertTo-Json -Compress -Depth 5) | Should -Be ($reference.Result.Json.verification.after | ConvertTo-Json -Compress -Depth 5) -Because $case.Name
                ($cached.Result.Json.verification.before | ConvertTo-Json -Compress -Depth 5) | Should -Be ($reference.Result.Json.verification.before | ConvertTo-Json -Compress -Depth 5) -Because $case.Name
                $cached.Result.Json.verification.derivedRollups.rulesVersion | Should -Be $reference.Result.Json.verification.derivedRollups.rulesVersion
            } else {
                $cached.Result.Code | Should -Be 2
                $cached.Result.Error | Should -Match 'derived rollup verification failed'
                foreach ($item in $results) { Test-Path -LiteralPath $item.Dest | Should -BeFalse }
            }
            (Get-FileHash -LiteralPath $case.Path).Hash | Should -Be $hash
        }
    }

    It 'rejects disguised schema-7 databases that retain any schema-8 derived objects' {
        $path = New-Fixture 'disguised-legacy'
        Write-FixtureSql $path "UPDATE metadata SET value='7' WHERE key='schema_version';"
        $hash = (Get-FileHash -LiteralPath $path).Hash
        $dest = Join-Path $work 'disguised-legacy-copy.sqlite'
        $r = Invoke-Storage @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy', '--migrate')
        $r.Code | Should -Be 2
        $r.Error | Should -Match 'reserved schema-8 derived objects'
        Test-Path -LiteralPath $dest | Should -BeFalse
        (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
    }

    It 'rejects duplicate, missing, stale and incorrectly typed existing schema-8 rollup sequences without repairing them' {
        $cases = [ordered]@{
            duplicate = "INSERT INTO sqlite_sequence(name,seq) SELECT name,seq FROM sqlite_sequence WHERE name='message_rollup';"
            missing = "DELETE FROM sqlite_sequence WHERE name='message_rollup';"
            stale = "UPDATE sqlite_sequence SET seq=0 WHERE name='message_rollup';"
            type = "UPDATE sqlite_sequence SET seq='2' WHERE name='message_rollup';"
        }
        foreach ($case in $cases.Keys) {
            $path = New-Fixture ("existing-sequence-$case")
            Write-FixtureSql $path $cases[$case]
            $hash = (Get-FileHash -LiteralPath $path).Hash
            $dest = Join-Path $work ("existing-sequence-$case-copy.sqlite")
            $r = Invoke-Storage @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy', '--migrate')
            $r.Code | Should -Be 2
            $r.Json.success | Should -BeFalse
            $r.Error | Should -Match 'derived rollup verification failed'
            Test-Path -LiteralPath $dest | Should -BeFalse
            Test-Path -LiteralPath ($dest + '.maintenance.json') | Should -BeFalse
            (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
        }
    }

    It 'allows only the new rollup sequence row and preserves every other AUTOINCREMENT value' {
        foreach ($mode in @('preserve', 'other-sequence', 'rollup-sequence', 'extra-sequence')) {
            $path = New-Fixture ("sequence-$mode") -Schema7
            if ($mode -ne 'extra-sequence') {
                Write-FixtureSql $path 'CREATE TABLE synthetic_auto(id INTEGER PRIMARY KEY AUTOINCREMENT,value TEXT); INSERT INTO synthetic_auto VALUES(42,''synthetic'');'
            }
            if ($mode -ne 'preserve') {
                $body = switch ($mode) {
                    'other-sequence' { "UPDATE sqlite_sequence SET seq=999 WHERE name='synthetic_auto';" }
                    'rollup-sequence' { "UPDATE sqlite_sequence SET seq=999 WHERE name='message_rollup';" }
                    'extra-sequence' { "INSERT INTO sqlite_sequence VALUES('unapproved_sequence',999);" }
                }
                Write-FixtureSql $path "CREATE TRIGGER synthetic_bad_sequence AFTER UPDATE OF value ON metadata WHEN NEW.key='schema_version' AND NEW.value='13' BEGIN $body END;"
            }
            $hash = (Get-FileHash -LiteralPath $path).Hash
            $dest = Join-Path $work ("sequence-$mode-copy.sqlite")
            $r = Invoke-Storage @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy', '--migrate')
            if ($mode -eq 'preserve') {
                $r.Code | Should -Be 0 -Because $r.Error
                (Read-Scalar $dest "SELECT seq FROM sqlite_sequence WHERE name='synthetic_auto';") | Should -Be 42
                @($r.Json.verification.derivedRollups.newlyAddedBookkeepingTables).Count | Should -Be 0
            } else {
                $r.Code | Should -Be 2
                $r.Json.success | Should -BeFalse
                Test-Path -LiteralPath $dest | Should -BeFalse
                Test-Path -LiteralPath ($dest + '.maintenance.json') | Should -BeFalse
            }
            (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
        }
    }

    It 'refuses existing destinations, hardlink aliases, existing reports and missing confirmation' {
        $existing = Join-Path $work 'existing.sqlite'
        [IO.File]::WriteAllText($existing, 'existing synthetic file')
        $existingHash = (Get-FileHash -LiteralPath $existing).Hash
        $r = Invoke-Storage @('--storage-copy', '--database', $source, '--destination', $existing, '--confirm-copy', '--output', (Join-Path $work 'refused.json'))
        $r.Code | Should -Be 2
        (Get-FileHash -LiteralPath $existing).Hash | Should -Be $existingHash
        $alias = Join-Path $work 'source-alias.sqlite'
        [void](New-Item -ItemType HardLink -Path $alias -Target $source)
        (Invoke-Storage @('--storage-copy', '--database', $source, '--destination', $alias, '--confirm-copy', '--output', (Join-Path $work 'alias.json'))).Code | Should -Be 2
        (Invoke-Storage @('--storage-copy', '--database', $source, '--destination', (Join-Path $work 'no-confirm.sqlite'), '--output', (Join-Path $work 'no-confirm.json'))).Code | Should -Be 2
        (Invoke-Storage @('--storage-copy', '--database', $source, '--destination', (Join-Path $work 'existing-report.sqlite'), '--confirm-copy', '--output', (Join-Path $work 'audit.json'))).Code | Should -Be 2
        (Get-FileHash -LiteralPath $source).Hash | Should -Be $sourceHash
    }

    It 'rejects reparse-directory aliases rather than following them' {
        $target = Join-Path $work 'junction-target'
        $junction = Join-Path $work 'junction'
        [void][IO.Directory]::CreateDirectory($target)
        [void](New-Item -ItemType Junction -Path $junction -Target $target)
        try {
            $r = Invoke-Storage @('--storage-copy', '--database', $source, '--destination', (Join-Path $junction 'copy.sqlite'), '--confirm-copy', '--output', (Join-Path $work 'junction.json'))
            $r.Code | Should -Be 2
            Test-Path -LiteralPath (Join-Path $target 'copy.sqlite') | Should -BeFalse
        } finally { Remove-Item -LiteralPath $junction -Force }
    }

    It 'rejects active writers before any copy or output report is published' {
        $path = New-Fixture 'held-writer'
        $writer = [ExchangeLogReport.Store]::new($path, $false, 'synthetic-preserved-tool')
        try {
            $hash = Shared-Hash $path
            $dest = Join-Path $work 'held-copy.sqlite'
            $r = Invoke-Storage @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy', '--output', (Join-Path $work 'held.json'))
            $r.Code | Should -Be 2
            Test-Path -LiteralPath $dest | Should -BeFalse
            (Shared-Hash $path) | Should -Be $hash
        } finally { $writer.Dispose() }
    }

    It 'copies committed WAL contents through BackupDatabase and preserves source bytes' {
        $path = New-Fixture 'wal'
        $writer = [ExchangeLogReport.Store]::new($path, $false, 'synthetic-preserved-tool')
        $reader = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$path;Mode=ReadOnly;Pooling=False")
        $tx = $null
        try {
            $writer.Exec("PRAGMA wal_autocheckpoint=0; INSERT INTO synthetic_ordered VALUES('committed-in-wal');")
            $reader.Open()
            $tx = $reader.BeginTransaction($true)
            $c = $reader.CreateCommand()
            try { $c.Transaction = $tx; $c.CommandText = 'SELECT count(*) FROM synthetic_ordered;'; $c.ExecuteScalar() | Should -Be 3 } finally { $c.Dispose() }
            $writer.Dispose()
            Test-Path -LiteralPath ($path + '-wal') | Should -BeTrue
            $mainHash = Shared-Hash $path
            $walHash = Shared-Hash ($path + '-wal')
            $dest = Join-Path $work 'wal-copy.sqlite'
            $r = Invoke-Storage @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy', '--output', (Join-Path $work 'wal-copy.json'))
            $r.Code | Should -Be 0 -Because $r.Error
            (Read-Scalar $dest 'SELECT count(*) FROM synthetic_ordered;') | Should -Be 3
            (Shared-Hash $path) | Should -Be $mainHash
            (Shared-Hash ($path + '-wal')) | Should -Be $walHash
        } finally { if ($tx) { $tx.Dispose() }; $reader.Dispose(); $writer.Dispose() }
    }

    It 'fails explicitly for missing SQLite tooling and future schemas without publishing destinations' {
        $missing = Join-Path $work 'sqlite3.exe'
        $r = Invoke-Storage @('--storage-audit', '--database', $source, '--sqlite-tool', $missing) -NoTool
        $r.Code | Should -Be 2
        $r.Json.success | Should -BeFalse
        $r.Error | Should -Match 'unavailable'
        $future = New-Fixture 'future'
        $s = [ExchangeLogReport.Store]::new($future, $false, 'synthetic-preserved-tool')
        try { $s.Exec("UPDATE metadata SET value='99' WHERE key='schema_version';") } finally { $s.Dispose() }
        $hash = (Get-FileHash -LiteralPath $future).Hash
        $dest = Join-Path $work 'future-copy.sqlite'
        (Invoke-Storage @('--storage-copy', '--database', $future, '--destination', $dest, '--confirm-copy', '--migrate', '--output', (Join-Path $work 'future.json'))).Code | Should -Be 2
        Test-Path -LiteralPath $dest | Should -BeFalse
        (Get-FileHash -LiteralPath $future).Hash | Should -Be $hash
    }

    It 'refuses unpinned tool bytes before invoking the executable' {
        $folder = Join-Path $work 'untrusted-tool'
        [void][IO.Directory]::CreateDirectory($folder)
        $fake = Join-Path $folder 'sqlite3.exe'
        [IO.File]::WriteAllText($fake, 'Synthetic non-executable pin mismatch fixture.')
        $r = Invoke-Storage @('--storage-audit', '--database', $source, '--sqlite-tool', $fake) -NoTool
        $r.Code | Should -Be 2
        $r.Json.success | Should -BeFalse
        $r.Error | Should -Match 'SHA-256 does not match'
        $r.Error | Should -Match 'not executed'
        (Get-FileHash -LiteralPath $source).Hash | Should -Be $sourceHash
    }

    It 'fails closed when staged migration changes non-bookkeeping logical values' {
        $path = New-Fixture 'verification-failure' -Schema6
        $db = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$path;Pooling=False")
        try {
            $db.Open()
            $c = $db.CreateCommand()
            try {
                $c.CommandText = "CREATE TRIGGER synthetic_bad_update AFTER UPDATE OF msg_hash ON message_event BEGIN UPDATE metadata SET value='SYNTHETIC_CHANGED_VALUE' WHERE key='custom_setting'; END;"
                [void]$c.ExecuteNonQuery()
            } finally { $c.Dispose() }
        } finally { $db.Dispose() }
        $hash = (Get-FileHash -LiteralPath $path).Hash
        $dest = Join-Path $work 'unverified.sqlite'
        $r = Invoke-Storage @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy', '--migrate', '--output', (Join-Path $work 'unverified.json'))
        $r.Code | Should -Be 2
        $r.Json.success | Should -BeFalse
        $r.Error | Should -Match 'logical contents'
        Test-Path -LiteralPath $dest | Should -BeFalse
        (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
        @(Get-ChildItem -LiteralPath $work -Filter '*.stage.sqlite' -Force).Count | Should -Be 0
    }

    It 'rejects TEXT-to-valid-Packed-BLOB conversions outside the approved slots' {
        $packed = [Convert]::ToHexString([ExchangeLogReport.Packed]::Pack($marker))
        foreach ($target in @('metadata', 'opaque')) {
            $path = New-Fixture ('type-loss-' + $target) -Schema6
            $body = if ($target -eq 'metadata') {
                "UPDATE metadata SET value=X'$packed' WHERE key='custom_setting';"
            } else {
                "UPDATE synthetic_opaque SET value=X'$packed' WHERE id=3;"
            }
            $db = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$path;Pooling=False")
            try {
                $db.Open()
                $c = $db.CreateCommand()
                try {
                    $c.CommandText = "CREATE TRIGGER synthetic_type_loss AFTER UPDATE OF msg_hash ON message_event BEGIN $body END;"
                    [void]$c.ExecuteNonQuery()
                } finally { $c.Dispose() }
            } finally { $db.Dispose() }
            $hash = (Get-FileHash -LiteralPath $path).Hash
            $dest = Join-Path $work ('type-loss-copy-' + $target + '.sqlite')
            $output = Join-Path $work ('type-loss-' + $target + '.json')
            $r = Invoke-Storage @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy', '--migrate', '--output', $output)
            $r.Code | Should -Be 2
            $r.Json.success | Should -BeFalse
            $r.Error | Should -Match 'logical contents'
            Test-Path -LiteralPath $dest | Should -BeFalse
            Test-Path -LiteralPath $output | Should -BeFalse
            (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
        }
    }

    It 'preserves NULL and numeric SQLite types even in approved packed slots' {
        $type = [ExchangeLogReport.Store].Assembly.GetType('ExchangeLogReport.Storage.StorageFingerprint', $true)
        $normalize = $type.GetMethod('Normalize', [Reflection.BindingFlags]'NonPublic,Static')
        foreach ($value in @([DBNull]::Value, [long]42, [double]1.25)) {
            $result = $normalize.Invoke($null, [object[]]@('smtp_transaction', 'response', $value))
            $result.GetType() | Should -Be $value.GetType()
            $result | Should -Be $value
        }
        $path = New-Fixture 'slot-null-loss' -Schema6
        $db = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$path;Pooling=False")
        try {
            $db.Open()
            $c = $db.CreateCommand()
            try {
                $c.CommandText = "UPDATE smtp_transaction SET response=NULL WHERE id=201; CREATE TRIGGER synthetic_slot_type_loss AFTER UPDATE OF msg_hash ON message_event BEGIN UPDATE smtp_transaction SET response='' WHERE id=201; END;"
                [void]$c.ExecuteNonQuery()
            } finally { $c.Dispose() }
        } finally { $db.Dispose() }
        $hash = (Get-FileHash -LiteralPath $path).Hash
        $dest = Join-Path $work 'slot-null-loss-copy.sqlite'
        $output = Join-Path $work 'slot-null-loss.json'
        $r = Invoke-Storage @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy', '--migrate', '--output', $output)
        $r.Code | Should -Be 2
        $r.Error | Should -Match 'logical contents'
        Test-Path -LiteralPath $dest | Should -BeFalse
        Test-Path -LiteralPath $output | Should -BeFalse
        (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
    }
}

AfterAll {
    if ($work -and (Test-Path -LiteralPath $work)) { Remove-Item -LiteralPath $work -Recurse -Force }
}
