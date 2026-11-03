#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

BeforeAll {
    $script:Root = Join-Path (Split-Path $PSScriptRoot -Parent) 'package'
    Import-Module (Join-Path $script:Root 'ExchangeLogReport.psd1') -Force
    Initialize-ExlEngine -Root $script:Root
    if (-not ('ServeFixtures' -as [type])) {
        Add-Type -LiteralPath (Join-Path $PSScriptRoot 'ServeFixtures.cs') -IgnoreWarnings -WarningAction SilentlyContinue -ReferencedAssemblies @(
            (Join-Path $script:Root 'lib\sqlite\Microsoft.Data.Sqlite.dll'),
            'System.Runtime', 'System.Data.Common', 'System.Reflection', 'System.Net.Sockets', 'System.Net.Primitives',
            'System.Text.Encoding.Extensions', 'System.IO', 'System.Collections', 'System.Linq.Expressions', 'System.ComponentModel.Primitives', 'netstandard')
    }
    $script:Work = Join-Path $script:Root ('bin\t\v' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void][IO.Directory]::CreateDirectory($script:Work)
    function Get-SchemaMaster($Store) {
        # Every object name and every index/trigger definition, plus the table definitions this schema changed. The other table definitions are not
        # compared: the synthetic schema-6 fixture drops and re-adds msg_hash, which legitimately moves the column in the stored CREATE TABLE text.
        ($Store.Query("SELECT type,name,tbl_name,CASE WHEN type<>'table' OR name IN('source_file','source_fields','message_rollup','message_rollup_dirty','message_rollup_value','smtp_client_value','smtp_client','smtp_client_hour','smtp_client_pending','smtp_client_dirty') THEN sql END FROM sqlite_master ORDER BY type,name;",$null).Rows | ForEach-Object { $_ -join '|' }) -join "`n"
    }
    function Get-SchemaObjects($Store) {
        ($Store.Query("SELECT type,name,tbl_name,sql FROM sqlite_master WHERE type IN('index','trigger') ORDER BY type,name;",$null).Rows | ForEach-Object { $_ -join '|' }) -join "`n"
    }
    function New-VerificationStore {
        $s=[ExchangeLogReport.Store]::new((Join-Path $script:Work ([guid]::NewGuid().ToString('N').Substring(0,8)+'.sqlite')),$false,'synthetic')
        $s.Exec(@"
INSERT INTO message_event(time_ms,server,event_id,message_id,log_id,sender,recipients,recipient_count,total_bytes,subject) VALUES
(1792000000000,'EX1','RECEIVE','<Case@invalid>','a','alpha@invalid','one@invalid;two@invalid',2,8192,'subject'),
(1792000000100,'EX1','DELIVER','<Case@invalid>','b','alpha@invalid','one@invalid',1,8192,NULL),
(1792000000200,'EX2','FAIL','<Case@invalid>','c','alpha@invalid','two@invalid',1,8192,NULL),
(1792000000300,'EX1','DELIVER','<case@invalid>','d','beta@invalid','one@invalid',1,4096,'case-sensitive'),
(1792000000400,'EX1','NOTIFYMAPI','<é😀@invalid>','e','beta@invalid','one@invalid',1,1024,'Unicode'),
(1791900000000,'EX1','RECEIVE','<long@invalid>','f','beta@invalid','one@invalid',1,1024,'long');
INSERT INTO smtp_transaction(time_ms,end_ms,server,direction,session_id,message_id,status,mail_from,rcpts) VALUES
(1791999999000,1792000000000,'EX1','Receive','case','<Case@invalid>','Accepted','alpha@invalid','one@invalid'),
(1792000000500,1792000000600,'EX1','Receive','only','<smtp-only@invalid>','Rejected','gamma@invalid','one@invalid'),
(1792000000700,1792000000800,'EX1','Receive','long','<long@invalid>','Accepted','beta@invalid','one@invalid'),
(1792000000900,1792000001000,'EX1','Receive','rejected',NULL,'Rejected','gamma@invalid','one@invalid'),
(1792000001100,NULL,'EX1','Receive','incomplete',NULL,NULL,'gamma@invalid','one@invalid'),
(1792000001200,NULL,'EX1','Receive','accepted',NULL,'Accepted','gamma@invalid','one@invalid'),
(1792000001300,NULL,'EX1','Send','send',NULL,'Rejected','gamma@invalid','one@invalid');
"@)
        $tx=$s.Begin()
        try { $s.ReconcileMessageRollups($tx); $tx.Commit() } finally { $tx.Dispose() }
        return $s
    }
}

AfterAll {
    if ($script:Work) { Remove-Item -LiteralPath $script:Work -Recurse -Force }
}

Describe 'Serve exact derived-rollup verification' {
    It 'recomputes every identity, canonical source hash and field without changing any retained rows' {
        $s=New-VerificationStore
        try {
            $before=[ServeFixtures]::RawBaseline($s)
            $derived=[ServeFixtures]::DecodedRollup($s)
            $result=$s.VerifyServeRollups()
            $result.Verified | Should -BeTrue
            $result.SchemaVersion | Should -Be 13
            $result.SmtpClientsVerified | Should -BeTrue
            # The fixture's SMTP transactions have no observed endpoint: each one is a group of its own and none is aggregated.
            $result.SmtpClientRows | Should -Be 0
            $result.SmtpClientHourRows | Should -Be 0
            $result.MailFlowVerified | Should -BeTrue
            $result.RowsVerified | Should -Be 7
            $result.TrackingIdentities | Should -Be 4
            $result.SmtpOnlyIdentities | Should -Be 1
            $result.MissingMessageIdSmtpIdentities | Should -Be 2
            $result.SourceHashGroupsVerified | Should -Be 7
            $result.SourceHashesVerified | Should -BeTrue
            $result.SchemaObjectsVerified | Should -BeTrue
            $result.ReadOnlySnapshot | Should -BeTrue
            $result.CacheKilobytes | Should -Be 65536
            [ServeFixtures]::RawBaseline($s) | Should -BeExactly $before
            ([ServeFixtures]::DecodedRollup($s)) | Should -BeExactly $derived
            foreach ($table in 'message_event','smtp_transaction') {
                # Schema 10: the identity indexes hold (msg_hash,time_ms), so the exact-identity grouping of the verifier is one table scan with a sorter (allowed).
                $plan=$s.Query("EXPLAIN QUERY PLAN SELECT msg_hash,message_id FROM $table NOT INDEXED WHERE message_id IS NOT NULL GROUP BY msg_hash,message_id COLLATE BINARY ORDER BY msg_hash,message_id COLLATE BINARY;",$null)
                ($plan.Rows | ForEach-Object {$_[3]}) -join "`n" | Should -Match "SCAN $table(\r?\n|$)"
            }
            $path=$s.FilePath; $s.Dispose()
            $hash=(Get-FileHash -LiteralPath $path).Hash
            $s=[ExchangeLogReport.Store]::new($path,$true,'synthetic')
            $s.VerifyServeRollups().RowsVerified | Should -Be 7
            (Get-FileHash -LiteralPath $path).Hash | Should -BeExactly $hash
        } finally { $s.Dispose() }
    }

    It 'migrates a schema-8 database to schema 13 in place: derived rows (decoded) and the sequence stay identical, ids are kept, the SMTP client structures are derived' {
        $s=New-VerificationStore
        try {
            $rollups=[ServeFixtures]::DecodedRollup($s)
            $sequence=$s.Scalar("SELECT seq FROM sqlite_sequence WHERE name='message_rollup';",$null)
            $raw=[ServeFixtures]::RawBaseline($s)
            $fresh=Get-SchemaObjects $s
            [ServeFixtures]::ConvertToLegacySyntheticFixture($s,8)
            $s.Scalar("SELECT COUNT(*) FROM sqlite_master WHERE name IN('ix_msg_hash','ix_smtp_hash','ix_session_latest');",$null) | Should -Be 3
            $s.Query("SELECT value FROM metadata WHERE key='schema_version';",$null).Rows[0][0] | Should -Be '8'
            $path=$s.FilePath; $s.Dispose()
            $s=[ExchangeLogReport.Store]::new($path,$false,'synthetic')
            $s.Query("SELECT value FROM metadata WHERE key='schema_version';",$null).Rows[0][0] | Should -Be '13'
            Get-SchemaObjects $s | Should -BeExactly $fresh
            ([ServeFixtures]::DecodedRollup($s)) | Should -BeExactly $rollups
            $s.Scalar("SELECT seq FROM sqlite_sequence WHERE name='message_rollup';",$null) | Should -BeGreaterOrEqual $sequence
            $s.Scalar('SELECT COUNT(*) FROM message_rollup_dirty;',$null) | Should -Be 0
            [ServeFixtures]::RawBaseline($s) | Should -BeExactly $raw
            $s.VerifyServeRollups().Verified | Should -BeTrue
            $s.Dispose()
            $s=[ExchangeLogReport.Store]::new($path,$false,'synthetic')
            $s.VerifyServeRollups().Verified | Should -BeTrue
        } finally {$s.Dispose()}
    }

    It 'ends schema-6, 7, 8, 9, 10, 11 and 12 databases in the same schema-13 sqlite_master as a fresh one, without hash-only indexes and without ix_smtp_latest' {
        $s=New-VerificationStore
        try { $fresh=Get-SchemaObjects $s; $freshMaster=Get-SchemaMaster $s } finally {$s.Dispose()}
        foreach ($version in 6,7,8,9,10,11,12) {
            $s=New-VerificationStore
            try {
                [ServeFixtures]::ConvertToLegacySyntheticFixture($s,$version)
                $path=$s.FilePath; $s.Dispose()
                $s=[ExchangeLogReport.Store]::new($path,$false,'synthetic')
                Get-SchemaObjects $s | Should -BeExactly $fresh
                Get-SchemaMaster $s | Should -BeExactly $freshMaster
                $s.Query("SELECT value FROM metadata WHERE key='schema_version';",$null).Rows[0][0] | Should -Be '13'
                $s.Scalar("SELECT COUNT(*) FROM sqlite_master WHERE name IN('ix_msg_hash','ix_smtp_hash','ix_session_latest','ix_smtp_latest');",$null) | Should -Be 0
                $s.VerifyServeRollups().Verified | Should -BeTrue
            } finally {$s.Dispose()}
        }
    }

    It 'leaves the dirty queue empty and the rollups verified when UPDATE touches only a column the rollup is not derived from (<Table>.<Column>)' -ForEach @(
        @{Table='message_event';Column='source';Value='changed'}, @{Table='message_event';Column='internal_id';Value='changed'},
        @{Table='message_event';Column='client_ip';Value='changed'},
        @{Table='message_event';Column='client_host';Value='changed'}, @{Table='message_event';Column='source_context';Value='changed'},
        @{Table='message_event';Column='reference';Value='changed'},
        @{Table='smtp_transaction';Column='role';Value='changed'}, @{Table='smtp_transaction';Column='connector';Value='changed'},
        @{Table='smtp_transaction';Column='remote_ep';Value='changed'}, @{Table='smtp_transaction';Column='local_ep';Value='changed'},
        @{Table='smtp_transaction';Column='helo';Value='changed'}, @{Table='smtp_transaction';Column='tls';Value='changed'},
        @{Table='smtp_transaction';Column='auth';Value='changed'}, @{Table='smtp_transaction';Column='rcpt_count';Value=77},
        @{Table='smtp_transaction';Column='auth_user';Value='changed@invalid'}
    ) {
        $s=New-VerificationStore
        try {
            $before=[ServeFixtures]::DecodedRollup($s)
            $c=[ServeFixtures]::Connection($s).CreateCommand()
            try {
                $c.CommandText="UPDATE $Table SET $Column=@value;"
                [void]$c.Parameters.AddWithValue('@value',$Value); [void]$c.ExecuteNonQuery()
            } finally {$c.Dispose()}
            $s.Scalar('SELECT COUNT(*) FROM message_rollup_dirty;',$null) | Should -Be 0
            if ($Table -eq 'smtp_transaction' -and $Column -in 'role','connector','remote_ep','helo','tls','rcpt_count','auth_user') {
                # These columns are part of the SMTP client key or of its buckets (schema 11): the update trigger queues them for ReconcileSmtpClients.
                $s.Scalar('SELECT COUNT(*) FROM smtp_client_pending;',$null) | Should -BeGreaterThan 0
                { $s.VerifyServeRollups() } | Should -Throw '*unreconciled*'
                [ServeFixtures]::RefreshServeRollups($s)
                $s.Scalar('SELECT COUNT(*) FROM smtp_client_pending;',$null) + $s.Scalar('SELECT COUNT(*) FROM smtp_client_dirty;',$null) | Should -Be 0
            } else {
                $s.Scalar('SELECT COUNT(*) FROM smtp_client_pending;',$null) + $s.Scalar('SELECT COUNT(*) FROM smtp_client_dirty;',$null) | Should -Be 0
            }
            if ($Table -eq 'message_event' -and $Column -eq 'internal_id') {
                # internal_id is the identity of a tracking event without Message-ID in the mail flow per hour: its bucket is queued for ReconcileMailFlow.
                $s.Scalar('SELECT COUNT(*) FROM mail_flow_dirty;',$null) | Should -BeGreaterThan 0
                { $s.VerifyServeRollups() } | Should -Throw '*unreconciled mail flow*'
                [ServeFixtures]::RefreshServeRollups($s)
            }
            $s.Scalar('SELECT COUNT(*) FROM mail_flow_dirty;',$null) | Should -Be 0
            $s.VerifyServeRollups().Verified | Should -BeTrue
            ([ServeFixtures]::DecodedRollup($s)) | Should -BeExactly $before
        } finally { $s.Dispose() }
    }

    It 'marks the identity dirty when UPDATE touches a column the rollup is derived from (<Table>.<Column>)' -ForEach @(
        @{Table='message_event';Column='message_id';Value='<moved@invalid>'}, @{Table='message_event';Column='time_ms';Value=1792000000050},
        @{Table='message_event';Column='server';Value='EX9'}, @{Table='message_event';Column='event_id';Value='FAIL'},
        @{Table='message_event';Column='sender';Value='changed@invalid'}, @{Table='message_event';Column='recipients';Value='changed@invalid'},
        @{Table='message_event';Column='recipient_count';Value=77}, @{Table='message_event';Column='total_bytes';Value=99999},
        @{Table='message_event';Column='subject';Value='changed'}, @{Table='message_event';Column='directionality';Value='Originating'},
        @{Table='message_event';Column='recipient_status';Value='changed'}, @{Table='message_event';Column='related_recipient';Value='changed'},
        @{Table='message_event';Column='connector';Value='changed'}, @{Table='message_event';Column='server_host';Value='changed'},
        @{Table='message_event';Column='server_ip';Value='192.0.2.9'},
        @{Table='smtp_transaction';Column='message_id';Value='<moved@invalid>'}, @{Table='smtp_transaction';Column='time_ms';Value=1792000000050},
        @{Table='smtp_transaction';Column='end_ms';Value=1792009999999}, @{Table='smtp_transaction';Column='server';Value='EX9'},
        @{Table='smtp_transaction';Column='direction';Value='Send'}, @{Table='smtp_transaction';Column='mail_from';Value='changed@invalid'},
        @{Table='smtp_transaction';Column='rcpts';Value='changed@invalid'}, @{Table='smtp_transaction';Column='status';Value='Deferred'}
    ) {
        $s=New-VerificationStore
        try {
            $c=[ServeFixtures]::Connection($s).CreateCommand()
            try {
                $c.CommandText="UPDATE $Table SET $Column=@value WHERE id=(SELECT MIN(id) FROM $Table);"
                [void]$c.Parameters.AddWithValue('@value',$Value); [void]$c.ExecuteNonQuery()
            } finally {$c.Dispose()}
            $s.Scalar('SELECT COUNT(*) FROM message_rollup_dirty;',$null) | Should -BeGreaterThan 0
            [ServeFixtures]::RefreshServeRollups($s)
            $s.VerifyServeRollups().Verified | Should -BeTrue
        } finally { $s.Dispose() }
    }

    It 'migrates a schema-11 database to schema 13: the update trigger watches the two status columns and the columns of the external status, every tracking identity is reconciled, ids are kept' {
        $s=New-VerificationStore
        try {
            $s.Exec(@"
INSERT INTO message_event(time_ms,server,event_id,message_id,log_id,sender,recipients,recipient_status,related_recipient) VALUES
(1792000002000,'EX1','RECEIVE','<dl@invalid>','s1','a@invalid','ping@invalid',NULL,NULL),
(1792000002100,'EX1','EXPAND','<dl@invalid>','s2','a@invalid',NULL,NULL,'ping@invalid'),
(1792000002200,'EX1','DROP','<dl@invalid>','s3','a@invalid','ping@invalid','250 2.1.5 RESOLVER.GRP.Expanded; distribution list expanded',NULL),
(1792000002300,'EX1','RECEIVE','<relay@invalid>','s4','a@invalid','a@invalid;b@invalid',NULL,NULL),
(1792000002400,'EX1','DELIVER','<relay@invalid>','s5','a@invalid','a@invalid',NULL,NULL),
(1792000002500,'EX1','SEND','<relay@invalid>','s6','a@invalid','b@invalid',NULL,NULL);
"@)
            $tx=$s.Begin()
            try { $s.ReconcileMessageRollups($tx); $tx.Commit() } finally { $tx.Dispose() }
            $rollups=[ServeFixtures]::DecodedRollup($s)
            ($rollups -join "`n") | Should -Match 'Suppressed \(by design\)'
            ($rollups -join "`n") | Should -Match 'Delivered and handed off'
            $sequence=$s.Scalar("SELECT seq FROM sqlite_sequence WHERE name='message_rollup';",$null)
            $raw=[ServeFixtures]::RawBaseline($s)
            $fresh=Get-SchemaObjects $s
            [ServeFixtures]::ConvertToLegacySyntheticFixture($s,11)
            $s.Query("SELECT value FROM metadata WHERE key='schema_version';",$null).Rows[0][0] | Should -Be '11'
            $s.Scalar("SELECT COUNT(*) FROM sqlite_master WHERE name='tr_message_event_rollup_update' AND sql LIKE '%recipient_status%';",$null) | Should -Be 0
            # What a schema-11 file holds: the labels of the former vocabulary.
            $s.Exec("UPDATE message_rollup_value SET text='Relayed' WHERE text='Delivered and handed off'; UPDATE message_rollup_value SET text='Expanded' WHERE text='Suppressed (by design)';")
            $path=$s.FilePath; $s.Dispose()
            $s=[ExchangeLogReport.Store]::new($path,$false,'synthetic')
            $s.Query("SELECT value FROM metadata WHERE key='schema_version';",$null).Rows[0][0] | Should -Be '13'
            Get-SchemaObjects $s | Should -BeExactly $fresh
            ([ServeFixtures]::DecodedRollup($s)) | Should -BeExactly $rollups
            $s.Scalar("SELECT seq FROM sqlite_sequence WHERE name='message_rollup';",$null) | Should -BeGreaterOrEqual $sequence
            $s.Scalar('SELECT COUNT(*) FROM message_rollup_dirty;',$null) | Should -Be 0
            [ServeFixtures]::RawBaseline($s) | Should -BeExactly $raw
            $s.VerifyServeRollups().Verified | Should -BeTrue
            $cookie=$s.Scalar('PRAGMA schema_version;',$null)
            $s.Dispose()
            $s=[ExchangeLogReport.Store]::new($path,$false,'synthetic')
            $s.Scalar('PRAGMA schema_version;',$null) | Should -Be $cookie
            $s.VerifyServeRollups().Verified | Should -BeTrue
        } finally {$s.Dispose()}
    }

    It 'rolls back a failed schema-12 migration of a schema-11 database: version, triggers, rollup rows and the dirty queue are unchanged' {
        $s=New-VerificationStore
        try {
            $s.Exec(@"
INSERT INTO message_event(time_ms,server,event_id,message_id,log_id,sender,recipients,recipient_status,related_recipient) VALUES
(1792000002000,'EX1','RECEIVE','<rb@invalid>','r1','a@invalid','a@invalid',NULL,NULL),
(1792000002100,'EX1','DELIVER','<rb@invalid>','r2','a@invalid','a@invalid',NULL,NULL);
"@)
            $tx=$s.Begin()
            try { $s.ReconcileMessageRollups($tx); $tx.Commit() } finally { $tx.Dispose() }
            [ServeFixtures]::ConvertToLegacySyntheticFixture($s,11)
            $s.Exec("UPDATE message_rollup_value SET text='Relayed' WHERE text='Delivered';")
            $before=@($s.Query("SELECT id,kind,identity FROM message_rollup ORDER BY id;",$null).Rows | ForEach-Object { '{0}|{1}|{2}' -f $_[0],$_[1],$_[2] })
            $values=$s.Query("SELECT group_concat(text,'|') FROM (SELECT text FROM message_rollup_value ORDER BY text);",$null).Rows[0][0]
            $s.Exec("CREATE TRIGGER fail_schema12 BEFORE UPDATE ON metadata WHEN NEW.key='schema_version' AND NEW.value='12' BEGIN SELECT RAISE(ABORT,'synthetic migration failure'); END;")
            $path=$s.FilePath; $s.Dispose()
            { [ExchangeLogReport.Store]::new($path,$false,'synthetic') } | Should -Throw '*synthetic migration failure*'
            $db=[Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$path;Mode=ReadOnly;Pooling=False"); $db.Open()
            try {
                $c=$db.CreateCommand()
                $c.CommandText="SELECT value FROM metadata WHERE key='schema_version';"; $c.ExecuteScalar() | Should -BeExactly '11'
                $c.CommandText="SELECT COUNT(*) FROM sqlite_master WHERE name='tr_message_event_rollup_update' AND sql LIKE '%recipient_status%';"; $c.ExecuteScalar() | Should -Be 0
                $c.CommandText="SELECT COUNT(*) FROM message_rollup_dirty;"; $c.ExecuteScalar() | Should -Be 0
                $c.CommandText="SELECT group_concat(id||'|'||kind||'|'||identity,';') FROM (SELECT id,kind,identity FROM message_rollup ORDER BY id);"
                $c.ExecuteScalar() | Should -BeExactly ($before -join ';')
                $c.CommandText="SELECT group_concat(text,'|') FROM (SELECT text FROM message_rollup_value ORDER BY text);"; $c.ExecuteScalar() | Should -BeExactly $values
            } finally { $db.Dispose() }
        } finally { if ($s) { try { $s.Dispose() } catch {} } }
    }

    It 'migrates a schema-12 database to schema 13: only the identities with a SENDEXTERNAL event are reconciled, every id is kept, an interrupted migration leaves schema 12' {
        $s=New-VerificationStore
        try {
            $s.Exec(@"
INSERT INTO message_event(time_ms,server,event_id,message_id,log_id,sender,recipients,recipient_status,connector,server_host,server_ip) VALUES
(1792000003000,'EX1','RECEIVE','<out@invalid>','x1','a@invalid','partner@fabrikam.example',NULL,NULL,NULL,NULL),
(1792000003100,'EX1','SENDEXTERNAL','<out@invalid>','x2','a@invalid','partner@fabrikam.example','250 2.1.5 Ok','To Internet via Postfix',NULL,'203.0.113.5'),
(1792000003200,'EX1','SENDEXTERNAL','<edge@invalid>','x3','a@invalid','one@invalid','250 2.6.0 Queued','EdgeSync - Inbound to Site',NULL,'203.0.113.6'),
(1792000003300,'EX1','SEND','<send@invalid>','x4','a@invalid','partner@fabrikam.example','250 2.1.5 Ok','To Internet via Postfix','smarthost.example',NULL);
"@)
            [ServeFixtures]::RefreshServeRollups($s)
            $fresh=Get-SchemaObjects $s
            [ServeFixtures]::ConvertToSchema12($s)
            $s.Query("SELECT value FROM metadata WHERE key='schema_version';",$null).Rows[0][0] | Should -Be '12'
            $s.Scalar("SELECT COUNT(*) FROM metadata WHERE key LIKE 'mailflow_%';",$null) | Should -Be 0
            $before=[ServeFixtures]::DecodedRollup($s) -split "`n"
            $sequence=$s.Scalar("SELECT seq FROM sqlite_sequence WHERE name='message_rollup';",$null)
            $raw=[ServeFixtures]::RawBaseline($s)
            # An interrupted migration: the database stays at schema 12, unchanged.
            $s.Exec("CREATE TRIGGER fail_schema13 BEFORE UPDATE ON metadata WHEN NEW.key='schema_version' AND NEW.value='13' BEGIN SELECT RAISE(ABORT,'synthetic migration failure'); END;")
            $path=$s.FilePath; $s.Dispose()
            { [ExchangeLogReport.Store]::new($path,$false,'synthetic') } | Should -Throw '*synthetic migration failure*'
            $s=$null
            $db=[Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$path;Pooling=False"); $db.Open()
            try {
                $c=$db.CreateCommand()
                $c.CommandText="SELECT value FROM metadata WHERE key='schema_version';"; $c.ExecuteScalar() | Should -BeExactly '12'
                $c.CommandText="SELECT COUNT(*) FROM metadata WHERE key LIKE 'mailflow_%';"; $c.ExecuteScalar() | Should -Be 0
                $c.CommandText="SELECT COUNT(*) FROM sqlite_master WHERE name='tr_message_event_rollup_update' AND sql LIKE '%server_host%';"; $c.ExecuteScalar() | Should -Be 0
                $c.CommandText="SELECT COUNT(*) FROM message_rollup_dirty;"; $c.ExecuteScalar() | Should -Be 0
                $c.CommandText="DROP TRIGGER fail_schema13;"; [void]$c.ExecuteNonQuery()
            } finally { $db.Dispose() }
            $s=[ExchangeLogReport.Store]::new($path,$false,'synthetic')
            $s.Query("SELECT value FROM metadata WHERE key='schema_version';",$null).Rows[0][0] | Should -Be '13'
            Get-SchemaObjects $s | Should -BeExactly $fresh
            $s.Query("SELECT value FROM metadata WHERE key='mailflow_accepted_domains';",$null).Rows[0][0] | Should -BeExactly 'invalid'
            @(($s.Query("SELECT value FROM metadata WHERE key='mailflow_rules';",$null).Rows[0][0] | ConvertFrom-Json).servers) | Should -Be @('ex1','ex2')
            $after=[ServeFixtures]::DecodedRollup($s) -split "`n"
            $after.Count | Should -Be $before.Count
            $changed=@(for ($i=0; $i -lt $before.Count; $i++) { if ($before[$i] -cne $after[$i]) { $after[$i] } })
            # The one message that left the organization: same id, its status and recipients only.
            $changed.Count | Should -Be 1
            $changed[0] | Should -Match '\|String:13:<out@invalid>\|'
            $changed[0] | Should -Match '\|String:16:Sent to external\|'
            $changed[0] | Should -Match 'partner@fabrikam.example \(Sent to external\)'
            ($changed[0] -split '\|')[0] | Should -BeExactly ((@($before | Where-Object { $_ -match '\|String:13:<out@invalid>\|' })[0]) -split '\|')[0]
            $s.Scalar("SELECT seq FROM sqlite_sequence WHERE name='message_rollup';",$null) | Should -BeGreaterOrEqual $sequence
            [ServeFixtures]::RawBaseline($s) | Should -BeExactly $raw
            $s.Scalar('SELECT COUNT(*) FROM message_rollup_dirty;',$null) | Should -Be 0
            $s.VerifyServeRollups().Verified | Should -BeTrue
        } finally { if ($s) { try { $s.Dispose() } catch {} } }
    }

    It 'migrates a schema-9 database to schema 13: narrowed identity indexes, exact fields dictionary, no source or (decoded) rollup row changes, idempotent' {
        $texts = @('#Fields: date-time,a', ('#Fields: ' + ('x,' * 2500)), '', ' padded ', "line`r`nbreak", 'Case', 'case', ([string][char]0xE9 + [char]::ConvertFromUtf32(0x1F600) + [char]0x754C))
        $s=New-VerificationStore
        try {
            $rollups=[ServeFixtures]::DecodedRollup($s)
            $sequence=$s.Scalar("SELECT seq FROM sqlite_sequence WHERE name='message_rollup';",$null)
            $fresh=Get-SchemaObjects $s; $freshMaster=Get-SchemaMaster $s
            [ServeFixtures]::ConvertToLegacySyntheticFixture($s,9)
            $c=[ServeFixtures]::Connection($s).CreateCommand()
            try {
                $c.CommandText="INSERT INTO source_file(server,kind,path,file_key,offset,size,fields) VALUES('EX1','Tracking',@p,@p,10,20,@f);"
                $pp=$c.Parameters.Add('@p',[Microsoft.Data.Sqlite.SqliteType]::Text); $pf=$c.Parameters.Add('@f',[Microsoft.Data.Sqlite.SqliteType]::Text)
                $n=0
                foreach ($round in 1..3) { foreach ($t in $texts) { $pp.Value="p$((++$n))"; $pf.Value=$t; [void]$c.ExecuteNonQuery() } }
                $pp.Value='p-null'; $pf.Value=[DBNull]::Value; [void]$c.ExecuteNonQuery()
                $c.CommandText="INSERT INTO source_file(server,kind,path,offset,size,fields) VALUES('EX1','Tracking','blob-row',1,2,X'00FF');"
                [void]$c.ExecuteNonQuery()
            } finally {$c.Dispose()}
            $beforeRows=($s.Query("SELECT id,server,kind,path,file_key,offset,size,last_write_ms,typeof(fields),hex(fields),first_ms,last_ms,lines,kept,noise,updated_ms FROM source_file ORDER BY id;",$null).Rows | ConvertTo-Json -Depth 5 -Compress)
            $s.Scalar("SELECT COUNT(*) FROM sqlite_master WHERE name IN('source_fields');",$null) | Should -Be 0
            $path=$s.FilePath; $s.Dispose()
            $s=[ExchangeLogReport.Store]::new($path,$false,'synthetic')
            $s.Query("SELECT value FROM metadata WHERE key='schema_version';",$null).Rows[0][0] | Should -Be '13'
            Get-SchemaObjects $s | Should -BeExactly $fresh
            Get-SchemaMaster $s | Should -BeExactly $freshMaster
            $s.Scalar('SELECT COUNT(*) FROM source_fields;',$null) | Should -Be $texts.Count
            # The dictionary holds each distinct text once, byte for byte; every text row points at it and does not repeat the text.
            foreach ($t in $texts) { $s.Scalar('SELECT COUNT(*) FROM source_fields WHERE hex(text)=@h;',@{h=[Convert]::ToHexString([Text.Encoding]::UTF8.GetBytes($t))}) | Should -Be 1 }
            $s.Scalar("SELECT COUNT(*) FROM source_file WHERE fields_id IS NOT NULL AND fields IS NULL;",$null) | Should -Be ($texts.Count * 3)
            $s.Scalar("SELECT COUNT(*) FROM source_file WHERE fields_id IS NULL AND fields IS NULL;",$null) | Should -Be 1
            $s.Scalar("SELECT COUNT(*) FROM source_file WHERE fields_id IS NULL AND fields IS NOT NULL AND typeof(fields)='blob';",$null) | Should -Be 1
            $afterRows=($s.Query("SELECT s.id,s.server,s.kind,s.path,s.file_key,s.offset,s.size,s.last_write_ms,typeof(COALESCE(d.text,s.fields)),hex(COALESCE(d.text,s.fields)),s.first_ms,s.last_ms,s.lines,s.kept,s.noise,s.updated_ms FROM source_file s LEFT JOIN source_fields d ON d.id=s.fields_id ORDER BY s.id;",$null).Rows | ConvertTo-Json -Depth 5 -Compress)
            $afterRows | Should -BeExactly $beforeRows
            # KnownFiles hands the collector the same logical text.
            $known=$s.KnownFiles()
            $known.Count | Should -Be ($texts.Count * 3 + 1)
            $s.Scalar("SELECT COUNT(*) FROM source_file WHERE file_key IS NOT NULL;",$null) | Should -Be ($texts.Count * 3 + 1)
            foreach ($k in $known.Keys) { $v=$known[$k]; if ($v.Path -ne 'p-null') { @($texts | Where-Object { $_ -ceq $v.Fields }).Count | Should -Be 1 } else { $v.Fields | Should -BeNullOrEmpty } }
            @($known.Values | Where-Object { $_.Fields -ceq '' }).Count | Should -Be 3
            ([ServeFixtures]::DecodedRollup($s)) | Should -BeExactly $rollups
            $s.Scalar("SELECT seq FROM sqlite_sequence WHERE name='message_rollup';",$null) | Should -BeGreaterOrEqual $sequence
            $s.Scalar('SELECT COUNT(*) FROM message_rollup_dirty;',$null) | Should -Be 0
            $s.VerifyServeRollups().Verified | Should -BeTrue
            $cookie=$s.Scalar('PRAGMA schema_version;',$null)
            $s.Dispose()
            # A second open changes no schema object and no row (the SQLite schema cookie counts every DDL change).
            $s=[ExchangeLogReport.Store]::new($path,$false,'synthetic')
            $s.Scalar('PRAGMA schema_version;',$null) | Should -Be $cookie
            Get-SchemaMaster $s | Should -BeExactly $freshMaster
            ($s.Query("SELECT s.id,COALESCE(d.text,s.fields) FROM source_file s LEFT JOIN source_fields d ON d.id=s.fields_id ORDER BY s.id;",$null).Rows | ConvertTo-Json -Depth 5 -Compress) | Should -Not -BeNullOrEmpty
        } finally {$s.Dispose()}
    }

    It 'rolls back a failed schema-10 publication of a schema-9 database atomically (indexes, dictionary, header text and version)' {
        $s=New-VerificationStore
        [ServeFixtures]::ConvertToLegacySyntheticFixture($s,9)
        $s.Exec("INSERT INTO source_file(server,kind,path,file_key,fields) VALUES('EX1','Tracking','a','A','#Fields: one'),('EX1','Tracking','b','B','#Fields: one');")
        $s.Exec("CREATE TRIGGER fail_schema10 BEFORE UPDATE ON metadata WHEN NEW.key='schema_version' AND NEW.value='10' BEGIN SELECT RAISE(ABORT,'synthetic migration failure'); END;")
        $path=$s.FilePath; $s.Dispose()
        { [ExchangeLogReport.Store]::new($path,$false,'synthetic') } | Should -Throw '*synthetic migration failure*'
        $db=[Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$path;Mode=ReadOnly;Pooling=False"); $db.Open()
        try {
            $c=$db.CreateCommand()
            $c.CommandText="SELECT value FROM metadata WHERE key='schema_version';"; $c.ExecuteScalar() | Should -BeExactly '9'
            $c.CommandText="SELECT COUNT(*) FROM sqlite_master WHERE name='source_fields';"; $c.ExecuteScalar() | Should -Be 0
            $c.CommandText="SELECT COUNT(*) FROM pragma_table_info('source_file') WHERE name='fields_id';"; $c.ExecuteScalar() | Should -Be 0
            $c.CommandText="SELECT COUNT(*) FROM source_file WHERE fields='#Fields: one';"; $c.ExecuteScalar() | Should -Be 2
            $c.CommandText="SELECT sql FROM sqlite_master WHERE name='ix_msg_identity_time';"; $c.ExecuteScalar() | Should -Match 'message_id COLLATE BINARY,time_ms,id'
        } finally { $db.Dispose() }
    }

    It 'looks identities up through the narrowed hash index with the exact BINARY compare on the row and no sorter (schema 10)' {
        $s=New-VerificationStore
        try {
            $s.Query("SELECT sql FROM sqlite_master WHERE name='ix_msg_identity_time';",$null).Rows[0][0] | Should -BeExactly 'CREATE INDEX ix_msg_identity_time ON message_event(msg_hash,time_ms)'
            $s.Query("SELECT sql FROM sqlite_master WHERE name='ix_smtp_identity_time';",$null).Rows[0][0] | Should -BeExactly 'CREATE INDEX ix_smtp_identity_time ON smtp_transaction(msg_hash,time_ms)'
            foreach ($table in 'message_event','smtp_transaction') {
                $plan=($s.Query("EXPLAIN QUERY PLAN SELECT time_ms FROM $table WHERE msg_hash=1 AND message_id='<Case@invalid>' COLLATE BINARY ORDER BY time_ms,id;",$null).Rows | ForEach-Object {$_[3]}) -join "`n"
                $plan | Should -Match "SEARCH $table USING INDEX ix_(msg|smtp)_identity_time \(msg_hash=\?\)"
                $plan | Should -Not -Match 'TEMP B-TREE'
                $plan=($s.Query("EXPLAIN QUERY PLAN SELECT 1 FROM $table e WHERE e.msg_hash=1 AND e.message_id='<Case@invalid>' COLLATE BINARY AND e.time_ms>=0 AND e.time_ms<5 LIMIT 1;",$null).Rows | ForEach-Object {$_[3]}) -join "`n"
                $plan | Should -Match "SEARCH e USING INDEX ix_(msg|smtp)_identity_time \(msg_hash=\? AND time_ms>\? AND time_ms<\?\)"
            }
            # The exact identity still decides: a forced hash collision between differently-cased IDs is separated by the row compare.
            [ServeFixtures]::ForceHashCollision($s)
            $s.Exec("UPDATE message_event SET msg_hash=0;")   # the repair trigger now stores 17 for every row
            $s.Scalar("SELECT COUNT(*) FROM message_event WHERE msg_hash=17;",$null) | Should -BeGreaterThan 4
            $s.Scalar("SELECT COUNT(*) FROM message_event WHERE msg_hash=17 AND message_id='<Case@invalid>' COLLATE BINARY;",$null) | Should -Be 3
            $s.Scalar("SELECT COUNT(*) FROM message_event WHERE msg_hash=17 AND message_id='<case@invalid>' COLLATE BINARY;",$null) | Should -Be 1
        } finally {$s.Dispose()}
    }

    It 'verifies an empty schema9 store without requiring an allocated sequence row' {
        $s=[ExchangeLogReport.Store]::new((Join-Path $script:Work 'empty.sqlite'),$false,'synthetic')
        try { $s.VerifyServeRollups().RowsVerified | Should -Be 0 } finally { $s.Dispose() }
    }

    It 'publishes raw synthetic fixture inserts only after an explicit transactional refresh' {
        $s=New-VerificationStore
        try {
            $s.Exec("INSERT INTO message_event(time_ms,server,event_id,message_id,log_id,sender,recipients) VALUES(1792000001500,'EX1','DELIVER','<fixture@invalid>','fixture','s@invalid','r@invalid');")
            { $s.VerifyServeRollups() } | Should -Throw '*unreconciled*'
            [ServeFixtures]::RefreshServeRollups($s)
            $s.VerifyServeRollups().RowsVerified | Should -Be 8
        } finally {$s.Dispose()}
    }

    It 'converts a synthetic connection to real legacy objects while preserving raw source values' {
        $s=New-VerificationStore
        try {
            $before=[ServeFixtures]::RawBaseline($s)
            [ServeFixtures]::ConvertToLegacySyntheticFixture([ServeFixtures]::Connection($s),7)
            $s.Scalar("SELECT COUNT(*) FROM sqlite_master WHERE name IN('message_rollup','message_rollup_dirty','ix_msg_identity_time','ix_smtp_identity_time','ix_smtp_latest','ix_session_latest') OR name GLOB 'tr_*_rollup_*';",$null) | Should -Be 0
            [ServeFixtures]::RawBaseline($s) | Should -BeExactly $before
            $path=$s.FilePath; $s.Dispose()
            $s=[ExchangeLogReport.Store]::new($path,$false,'synthetic')
            $s.VerifyServeRollups().RowsVerified | Should -Be 7
            [ServeFixtures]::ConvertToLegacySyntheticFixture($s,6)
            [ServeFixtures]::RawBaseline($s) | Should -BeExactly $before
            $s.Scalar("SELECT COUNT(*) FROM pragma_table_info('message_event') WHERE name='msg_hash';",$null) | Should -Be 0
        } finally {$s.Dispose()}
    }

    It 'keeps all derived rows and sequence identical after safe repacking and an explicit empty refresh' {
        $s=New-VerificationStore
        try {
            $text='synthetic compressible safe text ' * 100
            $opaque='opaque synthetic evidence; deliberately not JSON ' * 80
            $c=[ServeFixtures]::Connection($s).CreateCommand()
            try {
                $c.CommandText=@"
INSERT INTO access_event(time_ms,server,source,protocol,url,errors,outcome,request_id)
VALUES(1792000000000,'EX1','Synthetic','Mapi',@text,@text,'OK','safe-request');
INSERT INTO client_session(skey,day,start_ms,end_ms,user,protocol,requests,successes,failures,slow,first_success_ms,last_success_ms,first_failure_ms,last_failure_ms,total_ms,max_ms,bytes_in,bytes_out,actions,statuses)
VALUES('safe-session','2026-10-14',1792000000000,1792000000001,'s@invalid','Mapi',1,1,0,0,1792000000000,1792000000001,0,0,1,1,0,0,@text,@text);
UPDATE smtp_transaction SET response=@text,transcript=@opaque WHERE session_id='case';
INSERT INTO smtp_auth_fragment(source_key,first_offset,first_ms,last_ms,server,direction,session_id,observations)
VALUES('SYNTHETIC',0,1792000000000,1792000000001,'EX1','Receive','opaque',@opaque);
"@
                [void]$c.Parameters.AddWithValue('@text',$text)
                [void]$c.Parameters.AddWithValue('@opaque',$opaque)
                [void]$c.ExecuteNonQuery()
            } finally {$c.Dispose()}
            $s.Scalar('SELECT COUNT(*) FROM message_rollup_dirty;',$null) | Should -Be 0
            $before=[ServeFixtures]::DecodedRollup($s)
            $sequence=$s.Scalar("SELECT seq FROM sqlite_sequence WHERE name='message_rollup';",$null)
            $s.RepackSafeText() | Should -Be 5
            $s.Scalar('SELECT COUNT(*) FROM message_rollup_dirty;',$null) | Should -Be 0
            $s.RefreshServeRollups()
            ([ServeFixtures]::DecodedRollup($s)) | Should -BeExactly $before
            $s.Scalar("SELECT seq FROM sqlite_sequence WHERE name='message_rollup';",$null) | Should -Be $sequence
            $s.Query("SELECT typeof(observations),observations FROM smtp_auth_fragment WHERE session_id='opaque';",$null).Rows[0][0] | Should -BeExactly 'text'
            $s.Query("SELECT observations FROM smtp_auth_fragment WHERE session_id='opaque';",$null).Rows[0][0] | Should -BeExactly $opaque
            $s.Query("SELECT transcript FROM smtp_transaction WHERE session_id='case';",$null).Rows[0][0] | Should -BeExactly $opaque
            $path=$s.FilePath; $s.Dispose()
            $s=[ExchangeLogReport.Store]::new($path,$false,'synthetic')
            $s.Query("SELECT observations FROM smtp_auth_fragment WHERE session_id='opaque';",$null).Rows[0][0] | Should -BeExactly $opaque
            $s.VerifyServeRollups().Verified | Should -BeTrue
        } finally {$s.Dispose()}
    }

    It 'preserves opaque TEXT auth observations across schema6 migration and rejects read-only refresh' {
        $s=New-VerificationStore
        try {
            $opaque='synthetic opaque evidence, not JSON'
            $s.Exec("INSERT INTO smtp_auth_fragment(source_key,first_offset,first_ms,last_ms,server,direction,session_id,observations) VALUES('SYNTHETIC',0,1792000000000,1792000000001,'EX1','Receive','opaque','$opaque');")
            [ServeFixtures]::ConvertToLegacySyntheticFixture($s,6)
            $path=$s.FilePath; $s.Dispose()
            $s=[ExchangeLogReport.Store]::new($path,$false,'synthetic')
            $s.Query("SELECT typeof(observations),observations FROM smtp_auth_fragment WHERE session_id='opaque';",$null).Rows[0][0] | Should -BeExactly 'text'
            $s.Query("SELECT observations FROM smtp_auth_fragment WHERE session_id='opaque';",$null).Rows[0][0] | Should -BeExactly $opaque
            $s.Dispose(); $s=[ExchangeLogReport.Store]::new($path,$true,'synthetic')
            { $s.RefreshServeRollups() } | Should -Throw '*writable store*'
        } finally {$s.Dispose()}
    }

    It 'rejects corruption in derived column <Column>' -ForEach @(
        @{Column='kind';Value=1}, @{Column='identity';Value='<corrupt@invalid>'},
        @{Column='msg_hash';Value=0}, @{Column='first_ms';Value=0}, @{Column='last_ms';Value=0},
        @{Column='member_first_ms';Value=0}, @{Column='member_last_ms';Value=0},
        @{Column='status';Value=99999}, @{Column='sender';Value='corrupt@invalid'},
        @{Column='recipients';Value='["corrupt@invalid"]'}, @{Column='recipient_count';Value=0},
        @{Column='delivered';Value=999}, @{Column='failed';Value=999},
        @{Column='subject';Value='corrupt'}, @{Column='size_kb';Value=0},
        @{Column='direction';Value=99999}, @{Column='servers';Value=99999},
        @{Column='events';Value=99999}, @{Column='events_count';Value=0}, @{Column='smtp_count';Value=0}
    ) {
        $s=New-VerificationStore
        try {
            $c=[ServeFixtures]::Connection($s).CreateCommand()
            try {
                $c.CommandText="UPDATE message_rollup SET $Column=@value WHERE kind=0 AND identity='<Case@invalid>';"
                [void]$c.Parameters.AddWithValue('@value',$Value); [void]$c.ExecuteNonQuery()
            } finally {$c.Dispose()}
            { $s.VerifyServeRollups() } | Should -Throw '*InvalidServeRollup*'
        } finally { $s.Dispose() }
    }

    It 'gives the same result and the same errors with the merge scan and the per-identity path, with commands reused or not' {
        $flags = [Reflection.BindingFlags]'Static,NonPublic,Public'
        $cachedField = [ExchangeLogReport.Store].GetField('CachedVerificationReads', $flags)
        $mergeField = [ExchangeLogReport.Store].GetField('MergeVerification', $flags)
        $cachedField.GetValue($null) | Should -BeTrue
        $mergeField.GetValue($null) | Should -BeTrue
        $properties = 'Verified','SchemaVersion','RowsVerified','TrackingIdentities','SmtpOnlyIdentities','MissingMessageIdSmtpIdentities','SourceHashGroupsVerified',
            'SourceHashesVerified','SchemaObjectsVerified','SmtpClientsVerified','SmtpClientRows','SmtpClientHourRows','MailFlowVerified','MailFlowRows','ReadOnlySnapshot','CallerSnapshotUsed','DeadlineSeconds','DeadlineExplicit','FileBytes','EstimatedSeconds'
        $modes = @(@{ Merge = $true; Cached = $true }, @{ Merge = $true; Cached = $false }, @{ Merge = $false; Cached = $true }, @{ Merge = $false; Cached = $false })
        function Invoke-Mode($Store, $Mode) {
            $mergeField.SetValue($null, $Mode.Merge); $cachedField.SetValue($null, $Mode.Cached)
            try { [void]$Store.VerifyServeRollups(); 'verified' } catch { $_.Exception.InnerException.Message ?? $_.Exception.Message }
        }
        $s=New-VerificationStore
        try {
            try {
                $results = foreach ($mode in $modes) {
                    $mergeField.SetValue($null, $mode.Merge); $cachedField.SetValue($null, $mode.Cached)
                    $r = $s.VerifyServeRollups()
                    $r.Method | Should -BeExactly $(if ($mode.Merge) { 'merge-scan' } else { 'per-identity' })
                    if ($mode.Merge) { $r.SourceRowsScanned | Should -Be $s.Scalar('SELECT (SELECT COUNT(*) FROM message_event)+(SELECT COUNT(*) FROM smtp_transaction);',$null); $r.CacheKilobytes | Should -Be 65536 }
                    else { $r.SourceRowsScanned | Should -Be 0; $r.CacheKilobytes | Should -Be 16384 }
                    ($properties | ForEach-Object { "$_=$($r.$_)" }) -join ';'
                }
                @($results | Select-Object -Unique).Count | Should -Be 1
                $results[0] | Should -Match 'Verified=True;.*RowsVerified=7;.*TrackingIdentities=4;SmtpOnlyIdentities=1;MissingMessageIdSmtpIdentities=2;SourceHashGroupsVerified=7;'
                # The same message on every path: corrupted derived columns of a tracking and of an SMTP-only identity, a missing SMTP row, a wrong hash on one
                # event row, a NULL Message-ID with a hash, an SMTP-only identity that gained an event without reconciliation.
                $changes = @(
                    "UPDATE message_rollup SET sender='corrupt@invalid' WHERE kind=0 AND identity='<case@invalid>';",
                    "UPDATE message_rollup SET smtp_count=9 WHERE kind=0 AND identity='<smtp-only@invalid>';",
                    "DELETE FROM message_rollup WHERE kind=1 AND id=(SELECT MAX(id) FROM message_rollup WHERE kind=1);",
                    "COLLIDE:UPDATE message_event SET msg_hash=17 WHERE id=(SELECT MIN(id) FROM message_event WHERE message_id='<Case@invalid>');",
                    "NULLHASH:UPDATE smtp_transaction SET msg_hash=17 WHERE message_id IS NULL;",
                    "INSERT INTO message_event(time_ms,server,event_id,message_id,log_id,sender,recipients) VALUES(1792000000550,'EX1','DELIVER','<smtp-only@invalid>','gain','gamma@invalid','one@invalid'); DELETE FROM message_rollup_dirty;")
                foreach ($change in $changes) {
                    $copy = New-VerificationStore
                    try {
                        # The hash triggers repair a written msg_hash: a test-only hash function makes them store a noncanonical one.
                        if ($change.StartsWith('COLLIDE:')) { [ServeFixtures]::ForceHashCollision($copy) }
                        if ($change.StartsWith('NULLHASH:')) { [ServeFixtures]::ForceInvalidNullHash($copy) }
                        $c=[ServeFixtures]::Connection($copy).CreateCommand()
                        try { $c.CommandText=($change -replace '^(COLLIDE|NULLHASH):',''); [void]$c.ExecuteNonQuery() } finally { $c.Dispose() }
                        $errors = @(foreach ($mode in $modes) { Invoke-Mode $copy $mode })
                        $errors[0] | Should -Match 'InvalidServeRollup|InvalidSourceHash' -Because $change
                        @($errors | Select-Object -Unique).Count | Should -Be 1 -Because "$change => $($errors -join ' | ')"
                    } finally { $copy.Dispose() }
                }
                # A stored identity without source rows: the merge scan names it (extra), the per-identity path reports the count difference.
                $copy = New-VerificationStore
                try {
                    $copy.Exec("INSERT INTO message_rollup(kind,identity,msg_hash,first_ms,last_ms,member_first_ms,member_last_ms,status,sender,recipients,recipient_count,delivered,failed,subject,size_kb,direction,servers,events,events_count,smtp_count) SELECT kind,'<orphan@invalid>',msg_hash,first_ms,last_ms,member_first_ms,member_last_ms,status,sender,recipients,recipient_count,delivered,failed,subject,size_kb,direction,servers,events,events_count,smtp_count FROM message_rollup WHERE identity='<Case@invalid>';")
                    $errors = @(foreach ($mode in $modes) { Invoke-Mode $copy $mode })
                    $errors[0] | Should -BeExactly 'InvalidServeRollup: extra derived identity.'
                    $errors[2] | Should -BeExactly 'InvalidServeRollup: extra or missing derived identities.'
                    foreach ($e in $errors) { $e | Should -Match 'extra' }
                } finally { $copy.Dispose() }
            } finally { $mergeField.SetValue($null, $true); $cachedField.SetValue($null, $true) }
        } finally { $s.Dispose() }
    }

    It 'classifies extra, missing and duplicate stored identities in BINARY order' {
        $classify = [ExchangeLogReport.Store].GetNestedType('RollupMergeScan', [Reflection.BindingFlags]'NonPublic').GetMethod('Classify', [Reflection.BindingFlags]'Static,NonPublic')
        $classify.Invoke($null, @([string[]]@('<a>','<b>'), [string[]]@('<a>','<b>'))) | Should -BeExactly 'verified'
        $classify.Invoke($null, @([string[]]@('<a>','<b>'), [string[]]@('<a>','<a>','<b>'))) | Should -BeExactly 'duplicate'
        $classify.Invoke($null, @([string[]]@('<b>'), [string[]]@('<a>','<b>'))) | Should -BeExactly 'extra'
        $classify.Invoke($null, @([string[]]@('<a>','<b>'), [string[]]@('<a>'))) | Should -BeExactly 'missing'
        $classify.Invoke($null, @([string[]]@('<a>'), [string[]]@('<a>','<c>'))) | Should -BeExactly 'extra'
        # U+10000 sorts after U+FFFD in BINARY (UTF-8) order, unlike UTF-16 ordinal order.
        $high = [char]::ConvertFromUtf32(0x10000); $low = [string][char]0xFFFD
        $classify.Invoke($null, @([string[]]@($low,$high), [string[]]@($low,$high))) | Should -BeExactly 'verified'
    }

    It 'reads each source table once in identity order and the rollup through its UNIQUE index' {
        $s=New-VerificationStore
        try {
            $scan = [ExchangeLogReport.Store].GetNestedType('RollupMergeScan', [Reflection.BindingFlags]'NonPublic')
            foreach ($name in 'EventsSql','SmtpSql','StoredSql') {
                $sql = $scan.GetField($name, [Reflection.BindingFlags]'Static,NonPublic').GetValue($null)
                $plan = @($s.Query("EXPLAIN QUERY PLAN $sql", $null).Rows | ForEach-Object { $_[3] }) -join "`n"
                switch ($name) {
                    'EventsSql' { $plan | Should -Match 'SCAN message_event'; $plan | Should -Match 'USE TEMP B-TREE FOR ORDER BY' }
                    'SmtpSql' { $plan | Should -Match 'SCAN smtp_transaction'; $plan | Should -Match 'USE TEMP B-TREE FOR ORDER BY' }
                    'StoredSql' { $plan | Should -Match 'SEARCH r USING INDEX sqlite_autoindex_message_rollup_1 \(kind=\?\)'; $plan | Should -Not -Match 'TEMP B-TREE' }
                }
            }
        } finally { $s.Dispose() }
    }

    It 'stops a verification that makes no progress and lets a slow but steady one finish' {
        $flags = [Reflection.BindingFlags]'Static,NonPublic'
        $stall = [ExchangeLogReport.Store].GetField('VerificationStallSeconds', $flags)
        $hook = [ExchangeLogReport.Store].GetField('VerificationIdentityHook', $flags)
        $s=New-VerificationStore
        try {
            $stall.SetValue($null, 2)
            $hook.SetValue($null, [Action[long]]{ param($n) if ($n -eq 3) { Start-Sleep -Seconds 3 } })
            $clock = [Diagnostics.Stopwatch]::StartNew()
            try { [void]$s.VerifyServeRollups(); throw 'Unexpected verification success.' }
            catch { $_.Exception.GetBaseException().Message + ' ' + $_.Exception.InnerException.Message | Should -Match 'made no progress for 2 s \(last progress after 3 identities' }
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 20
            $hook.SetValue($null, [Action[long]]{ param($n) Start-Sleep -Milliseconds 50 })
            $r = $s.VerifyServeRollups()
            $r.Verified | Should -BeTrue
            $r.StallSeconds | Should -Be 2
        } finally { $hook.SetValue($null, $null); $stall.SetValue($null, 600); $s.Dispose() }
    }
    It 'keeps a verification alive through its heartbeats: identities each shorter than the limit, and one statement that steps for longer' {
        $static = [Reflection.BindingFlags]'Static,NonPublic'
        $instance = [Reflection.BindingFlags]'Instance,NonPublic'
        $stall = [ExchangeLogReport.Store].GetField('VerificationStallSeconds', $static)
        $hook = [ExchangeLogReport.Store].GetField('VerificationIdentityHook', $static)
        $s=New-VerificationStore
        try {
            $stall.SetValue($null, 2)
            # Two pauses of 1 s with an identity between them: progress each time, never 2 s without it.
            $hook.SetValue($null, [Action[long]]{ param($n) if ($n -eq 2 -or $n -eq 3) { Start-Sleep -Seconds 1 } })
            $r = $s.VerifyServeRollups()
            $r.Verified | Should -BeTrue
            $r.MaxProgressGapMs | Should -BeGreaterOrEqual 900
            $r.MaxProgressGapMs | Should -BeLessThan 2000
            $hook.SetValue($null, $null)
            # One statement on a verification connection (16 MiB cache) that runs for longer than the limit without a verified identity: the SQLite
            # progress handler is its only heartbeat, and the watchdog must not stop it.
            $readType = [ExchangeLogReport.Store].Assembly.GetType('ExchangeLogReport.ServeRead', $true)
            $watchType = [ExchangeLogReport.Store].GetNestedType('VerificationWatch', [Reflection.BindingFlags]'NonPublic')
            $options = [ExchangeLogReport.ServeOptions]::new(); $options.DatabasePath = $s.FilePath; $options.MmapMB = 0
            $deadline = [Threading.CancellationTokenSource]::new()
            $read = [Activator]::CreateInstance($readType, $instance, $null, @($options, $deadline.Token), $null)
            try {
                $watch = [Activator]::CreateInstance($watchType, $instance, $null, @($read, $deadline, [int]2), $null)
                try {
                    $steps = 20000000L; $seconds = 0.0
                    # The statement must outlast the limit on this machine: the count of steps grows until it does.
                    while ($seconds -le 3) {
                        $command = $readType.GetMethod('Command', $instance).Invoke($read, @("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<$steps) SELECT COUNT(*) FROM n;"))
                        $clock = [Diagnostics.Stopwatch]::StartNew()
                        try { [long]$command.ExecuteScalar() | Should -Be $steps } finally { $command.Dispose() }
                        $seconds = $clock.Elapsed.TotalSeconds
                        $steps *= 2
                    }
                    $watchType.GetProperty('Stalled', $instance).GetValue($watch) | Should -BeFalse
                    $deadline.IsCancellationRequested | Should -BeFalse
                    $watchType.GetProperty('MaxProgressGapMs', $instance).GetValue($watch) | Should -BeLessThan 2000
                } finally { $watch.Dispose() }
            } finally { $read.Dispose(); $deadline.Dispose() }
        } finally { $hook.SetValue($null, $null); $stall.SetValue($null, 600); $s.Dispose() }
    }
    It 'reports the largest total size of the sort files the watchdog saw (SortPeakBytes)' {
        $instance = [Reflection.BindingFlags]'Instance,NonPublic'
        $s=New-VerificationStore
        try {
            $readType = [ExchangeLogReport.Store].Assembly.GetType('ExchangeLogReport.ServeRead', $true)
            $watchType = [ExchangeLogReport.Store].GetNestedType('VerificationWatch', [Reflection.BindingFlags]'NonPublic')
            $options = [ExchangeLogReport.ServeOptions]::new(); $options.DatabasePath = $s.FilePath; $options.MmapMB = 0
            $deadline = [Threading.CancellationTokenSource]::new()
            $read = [Activator]::CreateInstance($readType, $instance, $null, @($options, $deadline.Token), $null)
            $sort = Join-Path $script:Work ('sort-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            [void][IO.Directory]::CreateDirectory($sort)
            try {
                $watch = [Activator]::CreateInstance($watchType, $instance, $null, @($read, $deadline, [int]600), $null)
                try {
                    [IO.File]::WriteAllBytes((Join-Path $sort 'etilqs_a'), [byte[]]::new(1000))
                    [IO.File]::WriteAllBytes((Join-Path $sort 'etilqs_b'), [byte[]]::new(500))
                    [IO.File]::WriteAllBytes((Join-Path $sort 'other.tmp'), [byte[]]::new(9999))
                    $sample = $watchType.GetMethod('SampleSortFiles', $instance)
                    $peak = $watchType.GetProperty('SortPeakBytes', $instance)
                    [void]$sample.Invoke($watch, @())
                    $peak.GetValue($watch) | Should -Be 0 -Because 'no folder is sampled before the merge scan sets it'
                    $watchType.GetProperty('SortDirectory', $instance).SetValue($watch, $sort)
                    [void]$sample.Invoke($watch, @())
                    $peak.GetValue($watch) | Should -Be 1500
                    Remove-Item -LiteralPath (Join-Path $sort 'etilqs_b')
                    [void]$sample.Invoke($watch, @())
                    $peak.GetValue($watch) | Should -Be 1500
                    [IO.File]::WriteAllBytes((Join-Path $sort 'etilqs_c'), [byte[]]::new(3000))
                    [void]$sample.Invoke($watch, @())
                    $peak.GetValue($watch) | Should -Be 4000
                } finally { $watch.Dispose() }
            } finally { $read.Dispose(); $deadline.Dispose(); Remove-Item -LiteralPath $sort -Recurse -Force }
        } finally { $s.Dispose() }
    }
    It 'rejects missing or extra identities and never repairs them implicitly' {
        $s=New-VerificationStore
        try {
            $s.Exec("INSERT INTO message_rollup(kind,identity,msg_hash,first_ms,last_ms,member_first_ms,member_last_ms,status,sender,recipients,recipient_count,delivered,failed,subject,size_kb,direction,servers,events,events_count,smtp_count) SELECT kind,'<orphan@invalid>',msg_hash,first_ms,last_ms,member_first_ms,member_last_ms,status,sender,recipients,recipient_count,delivered,failed,subject,size_kb,direction,servers,events,events_count,smtp_count FROM message_rollup WHERE identity='<Case@invalid>';")
            { $s.VerifyServeRollups() } | Should -Throw '*extra*derived identit*'
            $s.Scalar('SELECT COUNT(*) FROM message_rollup;',$null) | Should -Be 8
            $s.Exec("DELETE FROM message_rollup WHERE identity='<orphan@invalid>'; DELETE FROM message_rollup WHERE identity='<Case@invalid>';")
            { $s.VerifyServeRollups() } | Should -Throw '*missing derived identity*'
            $s.Scalar('SELECT COUNT(*) FROM message_rollup;',$null) | Should -Be 6
        } finally { $s.Dispose() }
    }

    It 'rejects nonpositive URL IDs and invalid or duplicated stable-ID sequence state' {
        $s=New-VerificationStore
        try {
            $id=$s.Scalar("SELECT id FROM message_rollup WHERE identity='<Case@invalid>';",$null)
            $s.Exec("UPDATE message_rollup SET id=-1 WHERE id=$id;")
            { $s.VerifyServeRollups() } | Should -Throw '*positive INTEGER*'
            $s.Exec("UPDATE message_rollup SET id=$id WHERE id=-1; UPDATE sqlite_sequence SET seq=0 WHERE name='message_rollup';")
            { $s.VerifyServeRollups() } | Should -Throw '*InvalidServeRollupSequence*'
            $s.Exec("UPDATE sqlite_sequence SET seq=100 WHERE name='message_rollup'; INSERT INTO sqlite_sequence(name,seq) VALUES('message_rollup',100);")
            { $s.VerifyServeRollups() } | Should -Throw '*InvalidServeRollupSequence*'
        } finally { $s.Dispose() }
    }

    It 'refuses pending invalidations and verifies again after normal transactional reconciliation' {
        $s=New-VerificationStore
        try {
            $s.Exec("UPDATE message_event SET event_id='SEND' WHERE log_id='b';")
            { $s.VerifyServeRollups() } | Should -Throw '*unreconciled*'
            $tx=$s.Begin()
            try {$s.ReconcileMessageRollups($tx);$tx.Commit()}finally{$tx.Dispose()}
            $s.VerifyServeRollups().Verified | Should -BeTrue
        } finally { $s.Dispose() }
    }

    It 'rejects noncanonical added source hashes instead of certifying an incompatible accelerator' {
        $s=New-VerificationStore
        try {
            [ServeFixtures]::ForceHashCollision($s)
            $s.Exec("UPDATE message_event SET msg_hash=17 WHERE log_id='d';")
            { $s.VerifyServeRollups() } | Should -Throw '*InvalidSourceHash*'
        } finally {$s.Dispose()}
        $s=New-VerificationStore
        try {
            [ServeFixtures]::ForceInvalidNullHash($s)
            $s.Exec("UPDATE smtp_transaction SET msg_hash=17 WHERE message_id IS NULL;")
            { $s.VerifyServeRollups() } | Should -Throw '*InvalidSourceHash*'
        } finally {$s.Dispose()}
    }

    It 'does not accept a different hash algorithm merely because synthetic collisions were injected' {
        $s=New-VerificationStore
        try {
            [ServeFixtures]::ForceHashCollision($s)
            $s.Exec("UPDATE message_event SET msg_hash=17; UPDATE smtp_transaction SET msg_hash=17 WHERE message_id IS NOT NULL;")
            { $s.VerifyServeRollups() } | Should -Throw '*InvalidSourceHash*'
        } finally {$s.Dispose()}
    }

    It 'does not certify a committed snapshot while its caller has an active collection transaction' {
        $s=New-VerificationStore
        try {
            $tx=$s.Begin()
            try { { $s.VerifyServeRollups() } | Should -Throw } finally {$tx.Dispose()}
        } finally {$s.Dispose()}
    }

    It 'interrupts verification at its explicit deadline and preserves source evidence' {
        $s=New-VerificationStore
        try {
            [ServeFixtures]::Populate($s,1792100000000L,20000)
            $before=[ServeFixtures]::RawBaseline($s)
            # The merge scan verifies this fixture in well under a second: a test hook makes every identity take a millisecond.
            $hook = [ExchangeLogReport.Store].GetField('VerificationIdentityHook', [Reflection.BindingFlags]'Static,NonPublic')
            $hook.SetValue($null, [Action[long]]{ param($n) [Threading.Thread]::Sleep(1) })
            try {
                $clock=[Diagnostics.Stopwatch]::StartNew()
                { $s.VerifyServeRollupsWithDeadline(1,[Threading.CancellationToken]::None) } | Should -Throw '*explicit deadline*'
                $clock.Elapsed.TotalSeconds | Should -BeLessThan 5
            } finally { $hook.SetValue($null, $null) }
            [ServeFixtures]::RawBaseline($s) | Should -BeExactly $before
            $s.VerifyServeRollups().Verified | Should -BeTrue
        } finally {$s.Dispose()}
    }

    It 'rejects missing, changed or extra canonical schema objects (<Change>)' -ForEach @(
        @{Change='missing-index';Sql='DROP INDEX ix_rollup_last;'},
        @{Change='changed-index';Sql='DROP INDEX ix_rollup_last; CREATE INDEX ix_rollup_last ON message_rollup(id,member_last_ms);'},
        @{Change='schema8-desc-index';Sql='DROP INDEX ix_rollup_last; CREATE INDEX ix_rollup_last ON message_rollup(member_last_ms DESC,id DESC);'},
        @{Change='schema10-nocase-status-index';Sql='DROP INDEX ix_rollup_status_last; CREATE INDEX ix_rollup_status_last ON message_rollup(status COLLATE NOCASE,member_last_ms);'},
        @{Change='obsolete-smtp-latest-index';Sql='CREATE INDEX ix_smtp_latest ON smtp_transaction(time_ms);'},
        @{Change='missing-smtp-client-index';Sql='DROP INDEX ix_smtp_client;'},
        @{Change='changed-smtp-client-index';Sql='DROP INDEX ix_smtp_client; CREATE INDEX ix_smtp_client ON smtp_transaction(client_id);'},
        @{Change='missing-unknown-peer-index';Sql='DROP INDEX ix_smtp_unknown_peer;'},
        @{Change='missing-client-key';Sql='DROP INDEX ux_smtp_client;'},
        @{Change='missing-hour-index';Sql='DROP INDEX ix_smtp_client_hour;'},
        @{Change='missing-client-trigger';Sql='DROP TRIGGER tr_smtp_transaction_client_update;'},
        @{Change='changed-client-trigger';Sql='DROP TRIGGER tr_smtp_transaction_client_delete; CREATE TRIGGER tr_smtp_transaction_client_delete AFTER DELETE ON smtp_transaction BEGIN SELECT 1; END;'},
        @{Change='extra-client-table-index';Sql='CREATE INDEX unapproved_client_index ON smtp_client(server);'},
        @{Change='changed-client-table';Sql='ALTER TABLE smtp_client ADD COLUMN unapproved TEXT;'},
        @{Change='changed-rollup-value-table';Sql='ALTER TABLE message_rollup_value ADD COLUMN unapproved TEXT;'},
        @{Change='obsolete-message-hash-index';Sql='CREATE INDEX ix_msg_hash ON message_event(msg_hash);'},
        @{Change='obsolete-smtp-hash-index';Sql='CREATE INDEX ix_smtp_hash ON smtp_transaction(msg_hash);'},
        @{Change='obsolete-session-index';Sql='CREATE INDEX ix_session_latest ON client_session(start_ms DESC,id DESC);'},
        @{Change='schema8-wide-update-trigger';Sql='DROP TRIGGER tr_smtp_transaction_rollup_update; CREATE TRIGGER tr_smtp_transaction_rollup_update AFTER UPDATE OF id,message_id,time_ms,end_ms,server,direction,role,mail_from,rcpts,status,auth_user ON smtp_transaction BEGIN SELECT 1; END;'},
        @{Change='rollup-trigger';Sql='DROP TRIGGER tr_message_event_rollup_insert; CREATE TRIGGER tr_message_event_rollup_insert AFTER INSERT ON message_event BEGIN SELECT 1; END;'},
        @{Change='hash-trigger';Sql='DROP TRIGGER tr_message_event_hash_update; CREATE TRIGGER tr_message_event_hash_update AFTER UPDATE ON message_event BEGIN SELECT 1; END;'},
        @{Change='extra-derived-index';Sql='CREATE INDEX unapproved_rollup_index ON message_rollup(sender);'},
        @{Change='changed-table';Sql='ALTER TABLE message_rollup ADD COLUMN unapproved TEXT;'},
        @{Change='pre-covering-rollup-index';Sql='DROP INDEX ix_rollup_last; CREATE INDEX ix_rollup_last ON message_rollup(member_last_ms);'},
        @{Change='pre-covering-status-index';Sql='DROP INDEX ix_rollup_status_last; CREATE INDEX ix_rollup_status_last ON message_rollup(status,member_last_ms);'},
        @{Change='covering-rollup-index-without-membership';Sql='DROP INDEX ix_rollup_last; CREATE INDEX ix_rollup_last ON message_rollup(member_last_ms,member_first_ms,status);'},
        @{Change='covering-status-index-without-membership';Sql='DROP INDEX ix_rollup_status_last; CREATE INDEX ix_rollup_status_last ON message_rollup(status,member_last_ms,member_first_ms);'},
        @{Change='pre-covering-session-index';Sql='DROP INDEX ix_session_time; CREATE INDEX ix_session_time ON client_session(start_ms);'},
        @{Change='missing-span-trigger';Sql='DROP TRIGGER tr_rollup_span_insert;'},
        @{Change='missing-session-span-trigger';Sql='DROP TRIGGER tr_session_span_update;'},
        @{Change='changed-span-trigger';Sql='DROP TRIGGER tr_rollup_span_update; CREATE TRIGGER tr_rollup_span_update AFTER UPDATE ON message_rollup BEGIN SELECT 1; END;'},
        @{Change='missing-span-key';Sql="DELETE FROM metadata WHERE key='session_max_span_ms';"},
        @{Change='noncanonical-span-key';Sql="UPDATE metadata SET value='12x' WHERE key='rollup_max_span_ms';"},
        @{Change='negative-span-key';Sql="UPDATE metadata SET value='-1' WHERE key='rollup_max_span_ms';"}
    ) {
        $s=New-VerificationStore
        try {
            $s.Exec($Sql)
            { $s.VerifyServeRollups() } | Should -Throw '*InvalidServeSchema*'
        } finally {$s.Dispose()}
    }

    It 'creates the covering indexes, the span triggers and exact span bounds in a new store' {
        $s=New-VerificationStore
        try {
            $s.Query("SELECT sql FROM sqlite_master WHERE name='ix_rollup_last';",$null).Rows[0][0] | Should -BeExactly 'CREATE INDEX ix_rollup_last ON message_rollup(member_last_ms,member_first_ms,status,events_count,kind,direction,servers)'
            $s.Query("SELECT sql FROM sqlite_master WHERE name='ix_rollup_status_last';",$null).Rows[0][0] | Should -BeExactly 'CREATE INDEX ix_rollup_status_last ON message_rollup(status,member_last_ms,member_first_ms,events_count,kind,direction,servers)'
            $s.Query("SELECT sql FROM sqlite_master WHERE name='ix_session_time';",$null).Rows[0][0] | Should -BeExactly 'CREATE INDEX ix_session_time ON client_session(start_ms,end_ms,requests)'
            $s.Scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name IN('tr_rollup_span_insert','tr_rollup_span_update','tr_session_span_insert','tr_session_span_update');",$null) | Should -Be 4
            $span=$s.Scalar('SELECT MAX(member_last_ms-member_first_ms) FROM message_rollup;',$null)
            $span | Should -BeGreaterThan 0
            $s.Query("SELECT value FROM metadata WHERE key='rollup_max_span_ms';",$null).Rows[0][0] | Should -BeExactly ([string]$span)
            $s.Query("SELECT value FROM metadata WHERE key='session_max_span_ms';",$null).Rows[0][0] | Should -BeExactly '0'
        } finally {$s.Dispose()}
    }

    It 'raises the span bounds when a longer journey or session is written and never lowers them' {
        $s=New-VerificationStore
        try {
            $before=[long]$s.Query("SELECT value FROM metadata WHERE key='rollup_max_span_ms';",$null).Rows[0][0]
            $s.Exec("INSERT INTO message_event(time_ms,server,event_id,message_id,log_id,sender,recipients) VALUES(1791000000000,'EX1','RECEIVE','<span@invalid>','sp1','a@invalid','b@invalid'),(1792000005000,'EX1','DELIVER','<span@invalid>','sp2','a@invalid','b@invalid');")
            [ServeFixtures]::RefreshServeRollups($s)
            $s.Query("SELECT value FROM metadata WHERE key='rollup_max_span_ms';",$null).Rows[0][0] | Should -BeExactly '1000005000'
            $s.Exec("INSERT INTO client_session(skey,day,start_ms,end_ms,user,protocol,requests,successes,failures,slow,first_success_ms,last_success_ms,first_failure_ms,last_failure_ms,total_ms,max_ms,bytes_in,bytes_out) VALUES('span','2026-10-14',1792000000000,1792000090000,'u@invalid','Mapi',1,1,0,0,0,0,0,0,1,1,0,0);")
            $s.Query("SELECT value FROM metadata WHERE key='session_max_span_ms';",$null).Rows[0][0] | Should -BeExactly '90000'
            $s.Exec("UPDATE client_session SET end_ms=1792000120000 WHERE skey='span';")
            $s.Query("SELECT value FROM metadata WHERE key='session_max_span_ms';",$null).Rows[0][0] | Should -BeExactly '120000'
            # Removing the longest journey and session leaves the bounds high (still correct: an upper bound) and the store verifies.
            $s.Exec("DELETE FROM message_event WHERE message_id='<span@invalid>'; DELETE FROM client_session WHERE skey='span';")
            [ServeFixtures]::RefreshServeRollups($s)
            $s.Query("SELECT value FROM metadata WHERE key='rollup_max_span_ms';",$null).Rows[0][0] | Should -BeExactly '1000005000'
            $s.Query("SELECT value FROM metadata WHERE key='session_max_span_ms';",$null).Rows[0][0] | Should -BeExactly '120000'
            $before | Should -BeLessThan 1000005000
            $s.VerifyServeRollups().Verified | Should -BeTrue
        } finally {$s.Dispose()}
    }

    It 'rejects a span bound lower than a stored <Kind> span' -ForEach @(
        @{Kind='journey';Sql="UPDATE metadata SET value='0' WHERE key='rollup_max_span_ms';";Message='*rollup_max_span_ms is lower than a stored journey span*'},
        @{Kind='session';Sql="INSERT INTO client_session(skey,day,start_ms,end_ms,user,protocol,requests,successes,failures,slow,first_success_ms,last_success_ms,first_failure_ms,last_failure_ms,total_ms,max_ms,bytes_in,bytes_out) VALUES('low','2026-10-14',1792000000000,1792000090000,'u@invalid','Mapi',1,1,0,0,0,0,0,0,1,1,0,0); UPDATE metadata SET value='5' WHERE key='session_max_span_ms';";Message='*session_max_span_ms is lower than a stored client session span*'}
    ) {
        $s=New-VerificationStore
        try {
            $s.Exec($Sql)
            { $s.VerifyServeRollups() } | Should -Throw $Message
        } finally {$s.Dispose()}
    }

    It 'gives a schema-12 database of an earlier shape (<Shape>) the final shape and the current SMTP status at one writable open, and only then' -ForEach @(
        @{Shape='before the covering indexes'; Convert='ConvertToPreReleaseSchema12'; SpanKeys=0; OldStatus='Not completed (SMTP)'},
        @{Shape='covering indexes without events_count and kind'; Convert='ConvertToCoveringSchema12'; SpanKeys=2; OldStatus='Not completed (SMTP)'},
        @{Shape='rollup indexes without direction and servers, no mail flow per hour'; Convert='ConvertToTrackedSchema12'; SpanKeys=2; OldStatus='Sent (SMTP)'}
    ) {
        $s=New-VerificationStore
        try {
            # A sent SMTP transaction with a Message-ID and no tracking event: 'Sent (SMTP)' in schema 12 and later, 'Not completed (SMTP)' in the earlier shapes.
            $s.Exec("INSERT INTO smtp_transaction(time_ms,end_ms,server,direction,session_id,message_id,status,mail_from,rcpts) VALUES(1792000001400,1792000001500,'EX1','Send','sent','<sent-only@invalid>','Sent','gamma@invalid','far@invalid');")
            [ServeFixtures]::RefreshServeRollups($s)
            $status="SELECT v.text FROM message_rollup r JOIN message_rollup_value v ON v.id=r.status WHERE r.identity='<sent-only@invalid>';"
            $s.Query($status,$null).Rows[0][0] | Should -BeExactly 'Sent (SMTP)'
            $fresh=Get-SchemaObjects $s
            $spans=$s.Query("SELECT group_concat(key||'='||value,',') FROM (SELECT key,value FROM metadata WHERE key LIKE '%max_span_ms' ORDER BY key);",$null).Rows[0][0]
            $rollups=[ServeFixtures]::DecodedRollup($s); $raw=[ServeFixtures]::RawBaseline($s)
            [ServeFixtures]::$Convert($s)
            $s.Query($status,$null).Rows[0][0] | Should -BeExactly $OldStatus
            $s.Scalar("SELECT COUNT(*) FROM sqlite_master WHERE name IN('mail_flow_hour','mail_flow_dirty','ix_msg_noid_flow','ix_event_resolution','ix_usage_day_success') OR name LIKE 'tr_%_flow_%';",$null) | Should -Be 0
            { $s.VerifyServeRollups() } | Should -Throw '*Schema 13 is required*'
            $path=$s.FilePath; $s.Dispose()
            # A file of an older schema is upgraded once by its first open, read-only too (the report of a database not collected since the update).
            $s=[ExchangeLogReport.Store]::new($path,$true,'synthetic')
            $s.Query("SELECT value FROM metadata WHERE key='schema_version';",$null).Rows[0][0] | Should -Be '13'
            $s.Dispose()
            $s=[ExchangeLogReport.Store]::new($path,$false,'synthetic')
            Get-SchemaObjects $s | Should -BeExactly $fresh
            $s.Query("SELECT group_concat(key||'='||value,',') FROM (SELECT key,value FROM metadata WHERE key LIKE '%max_span_ms' ORDER BY key);",$null).Rows[0][0] | Should -BeExactly $spans
            ([ServeFixtures]::DecodedRollup($s)) | Should -BeExactly $rollups
            [ServeFixtures]::RawBaseline($s) | Should -BeExactly $raw
            $s.Query($status,$null).Rows[0][0] | Should -BeExactly 'Sent (SMTP)'
            $receipt=$s.VerifyServeRollups()
            $receipt.Verified | Should -BeTrue
            $receipt.MailFlowVerified | Should -BeTrue
            $receipt.MailFlowRows | Should -BeGreaterThan 0
            $cookie=$s.Scalar('PRAGMA schema_version;',$null)
            $s.Dispose()
            $s=[ExchangeLogReport.Store]::new($path,$false,'synthetic')
            $s.Scalar('PRAGMA schema_version;',$null) | Should -Be $cookie
        } finally {$s.Dispose()}
    }

    It 'folds a schema-12 database without the authentication columns at one open, writable or read-only, keeping every client row' -ForEach @(@{Open='writable'; ReadOnly=$false}, @{Open='read-only'; ReadOnly=$true}) {
        $s=New-VerificationStore
        try {
            $s.Exec(@"
INSERT INTO access_client(day,user,protocol,client_ip,user_agent,device_id,device_type,software,requests,failures,first_ms,last_ms,servers,auth_type) VALUES
('2026-10-01','alpha@invalid','Eas','10.0.0.1','Apple-iPhone','DEV1','iPhone',NULL,7,1,1792000000000,1792000005000,'EX1','Basic'),
('2026-10-01','alpha@invalid','Ews','10.0.0.1','MacOutlook','',NULL,NULL,3,0,1792000000000,1792000001000,'EX1,EX2','OAuth'),
('2026-10-02','beta@invalid','Mapi','10.0.0.2','Outlook','',NULL,NULL,5,0,1792086400000,1792086401000,'EX2','Negotiate');
INSERT INTO client_session(skey,day,start_ms,end_ms,user,protocol,requests,successes,failures,slow,first_success_ms,last_success_ms,first_failure_ms,last_failure_ms,total_ms,max_ms,bytes_in,bytes_out,auth_modes) VALUES
('2026-10-01|alpha@invalid|k','2026-10-01',1792000000000,1792000005000,'alpha@invalid','Eas',7,6,1,0,1792000000000,1792000005000,1792000001000,1792000001000,70,20,1,1,'Basic=7');
"@)
            [ServeFixtures]::ConvertToStep3Schema12($s)
            $s.Scalar("SELECT COUNT(*) FROM pragma_table_info('access_client') WHERE name='auth_type';",$null) | Should -Be 0
            $s.Scalar("SELECT COUNT(*) FROM pragma_table_info('client_session') WHERE name='auth_modes';",$null) | Should -Be 0
            $counts=$s.Query("SELECT COUNT(*),SUM(requests),SUM(failures) FROM access_client;",$null).Rows[0] -join ','
            $rows=($s.Query("SELECT day,user,protocol,client_ip,user_agent,device_id,device_type,requests,failures,first_ms,last_ms,servers FROM access_client ORDER BY day,user,protocol;",$null).Rows | ForEach-Object { $_ -join '|' }) -join "`n"
            { $s.VerifyServeRollups() } | Should -Throw '*Schema 13 is required*'
            $path=$s.FilePath; $s.Dispose()
            $s=[ExchangeLogReport.Store]::new($path,$ReadOnly,'synthetic')
            $s.ReadOnly | Should -Be $ReadOnly
            @($s.Query("SELECT name FROM pragma_table_info('access_client') WHERE pk>0 ORDER BY pk;",$null).Rows | ForEach-Object { $_[0] }) -join ',' | Should -BeExactly 'day,user,protocol,client_ip,user_agent,device_id,auth_type'
            $s.Scalar("SELECT COUNT(*) FROM access_client WHERE auth_type<>'';",$null) | Should -Be 0
            $s.Query("SELECT COUNT(*),SUM(requests),SUM(failures) FROM access_client;",$null).Rows[0] -join ',' | Should -BeExactly $counts
            ($s.Query("SELECT day,user,protocol,client_ip,user_agent,device_id,device_type,requests,failures,first_ms,last_ms,servers FROM access_client ORDER BY day,user,protocol;",$null).Rows | ForEach-Object { $_ -join '|' }) -join "`n" | Should -BeExactly $rows
            $s.Scalar("SELECT COUNT(*) FROM client_session WHERE auth_modes IS NOT NULL;",$null) | Should -Be 0
            $s.Scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='ix_client_user' AND tbl_name='access_client';",$null) | Should -Be 1
            $s.Scalar("SELECT COUNT(*) FROM sqlite_master WHERE name='access_client_old';",$null) | Should -Be 0
            $receipt=$s.VerifyServeRollups()
            $receipt.Verified | Should -BeTrue
            $s.Dispose()
            # A store that has the shape is not changed by the next writable open.
            $s=[ExchangeLogReport.Store]::new($path,$false,'synthetic')
            $cookie=$s.Scalar('PRAGMA schema_version;',$null)
            $s.Dispose()
            $s=[ExchangeLogReport.Store]::new($path,$false,'synthetic')
            $s.Scalar('PRAGMA schema_version;',$null) | Should -Be $cookie
        } finally {$s.Dispose()}
    }

    It 'refuses a store whose access_client has no authentication key column, and only that, in the exact schema check' {
        $s=New-VerificationStore
        try {
            $current=$s.Query("SELECT sql FROM sqlite_master WHERE name='tr_message_event_rollup_update';",$null).Rows[0][0]
            [ServeFixtures]::ConvertToStep3Schema12($s)
            # The current schema and its trigger again: only the access_client key differs from the current shape.
            $s.Exec("ALTER TABLE client_session ADD COLUMN auth_modes TEXT; DROP TRIGGER tr_message_event_rollup_update; $current; UPDATE metadata SET value='13' WHERE key='schema_version';")
            { $s.VerifyServeRollups() } | Should -Throw '*InvalidServeSchema: access_client.auth_type is missing or is not the seventh key column.*'
        } finally {$s.Dispose()}
    }

    It 'proves the mail flow per hour by recomputation and refuses <Case>' -ForEach @(
        @{Case='a changed counter'; Sql="UPDATE mail_flow_hour SET deliveries=deliveries+1 WHERE hour_ms=(SELECT MIN(hour_ms) FROM mail_flow_hour);"; Message='*InvalidMailFlow: mail_flow_hour differs from the rows*'},
        @{Case='an hour the rows do not justify'; Sql="INSERT INTO mail_flow_hour VALUES(0,'EX9',1,0,0,1,0,0,0,0,0,NULL,NULL);"; Message='*InvalidMailFlow: mail_flow_hour differs from the rows*'},
        @{Case='a missing hour'; Sql="DELETE FROM mail_flow_hour WHERE hour_ms=(SELECT MIN(hour_ms) FROM mail_flow_hour);"; Message='*InvalidMailFlow: mail_flow_hour differs from the rows*'},
        @{Case='another spelling of a server'; Sql="UPDATE mail_flow_hour SET server=lower(server) WHERE server='EX1';"; Message='*InvalidMailFlow: mail_flow_hour differs from the rows*'},
        @{Case='a stale queued bucket'; Sql="INSERT INTO mail_flow_dirty VALUES(0,'EX1');"; Message='*InvalidMailFlow: unreconciled mail flow work is queued*'},
        @{Case='a missing trigger'; Sql="DROP TRIGGER tr_smtp_transaction_flow_update;"; Message='*InvalidServeSchema: missing or noncanonical object: tr_smtp_transaction_flow_update*'}
    ) {
        $s=New-VerificationStore
        try {
            $receipt=$s.VerifyServeRollups()
            $receipt.MailFlowVerified | Should -BeTrue
            # The fixture: tracking events and SMTP transactions of three hours on EX1 and EX2.
            $receipt.MailFlowRows | Should -Be ([long]$s.Scalar("SELECT COUNT(*) FROM (SELECT DISTINCT time_ms/3600000,upper(server) FROM (SELECT time_ms,server FROM message_event UNION ALL SELECT time_ms,server FROM smtp_transaction));",$null))
            $s.Exec($Sql)
            { $s.VerifyServeRollups() } | Should -Throw $Message
        } finally { $s.Dispose() }
    }

    It 'verifies statically without Store construction or modifying caller connection settings, transaction or lifetime' {
        $s=New-VerificationStore
        $path=$s.FilePath; $s.Dispose()
        $before=(Get-FileHash -LiteralPath $path).Hash
        $db=[Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$path;Mode=ReadOnly;Pooling=False")
        $db.Open()
        try {
            $c=$db.CreateCommand(); $c.CommandText='PRAGMA query_only=ON; PRAGMA cache_size=-2048; PRAGMA mmap_size=1048576;'
            [void]$c.ExecuteNonQuery();$c.Dispose()
            $tx=$db.BeginTransaction($true)
            try {
                $receipt=[ExchangeLogReport.Store]::VerifyServeRollups($db)
                $receipt.Verified | Should -BeTrue
                $receipt.SchemaObjectsVerified | Should -BeTrue
                $receipt.RowsVerified | Should -Be 7
                $receipt.CallerSnapshotUsed | Should -BeFalse
                $receipt.CacheKilobytes | Should -Be 65536
                $db.State | Should -Be ([Data.ConnectionState]::Open)
                $c=$db.CreateCommand();$c.Transaction=$tx
                try {
                    foreach($pragma in @{cache_size=-2048;mmap_size=1048576;query_only=1}.GetEnumerator()){
                        $c.CommandText="PRAGMA $($pragma.Key);"
                        $c.ExecuteScalar() | Should -Be $pragma.Value
                    }
                } finally {$c.Dispose()}
            } finally {$tx.Dispose()}
            (Get-FileHash -LiteralPath $path).Hash | Should -BeExactly $before
        } finally {$db.Dispose()}
    }

    It 'rejects writable or closed caller connections and never migrates an old schema in the static entrypoint' {
        $s=New-VerificationStore
        try { { [ExchangeLogReport.Store]::VerifyServeRollups([ServeFixtures]::Connection($s)) } | Should -Throw '*open read-only*' }
        finally {$s.Dispose()}
        $path=Join-Path $script:Work 'static-old.sqlite'
        $db=[Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$path;Pooling=False");$db.Open()
        try {
            $c=$db.CreateCommand();$c.CommandText="CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT); INSERT INTO metadata VALUES('schema_version','7');"
            [void]$c.ExecuteNonQuery();$c.Dispose()
        } finally {$db.Dispose()}
        $before=(Get-FileHash -LiteralPath $path).Hash
        $db=[Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$path;Mode=ReadOnly;Pooling=False")
        try {
            { [ExchangeLogReport.Store]::VerifyServeRollups($db) } | Should -Throw '*open read-only*'
            $db.Open()
            { [ExchangeLogReport.Store]::VerifyServeRollups($db) } | Should -Throw '*Schema 13 is required*'
            (Get-FileHash -LiteralPath $path).Hash | Should -BeExactly $before
        } finally {$db.Dispose()}
    }

    It 'honors explicit cancellation and bounds selectable deadlines' {
        $s=New-VerificationStore
        $cancel=[Threading.CancellationTokenSource]::new()
        try {
            $cancel.Cancel()
            try { $s.VerifyServeRollupsWithDeadline(10,$cancel.Token); throw 'Unexpected verification success.' }
            catch { $_.Exception.GetBaseException().GetType().Name | Should -BeExactly 'OperationCanceledException' }
            foreach ($seconds in 0,86401) {
                { $s.VerifyServeRollupsWithDeadline($seconds,[Threading.CancellationToken]::None) } | Should -Throw '*timeoutSeconds*'
            }
            $s.VerifyServeRollupsWithDeadline(86400,[Threading.CancellationToken]::None).DeadlineSeconds | Should -Be 86400
        } finally {$cancel.Dispose();$s.Dispose()}
    }

    It 'estimates the run from the file size: 3 x the bytes at 20 MB/s, at least 300 s and at most 24 hours' {
        $rule = [ExchangeLogReport.Store].GetMethod('VerificationEstimateSeconds', [Reflection.BindingFlags]'Static,NonPublic')
        $rule.Invoke($null, @([long]0)) | Should -Be 300
        $rule.Invoke($null, @([long]2000000000)) | Should -Be 300
        $rule.Invoke($null, @([long]2100000000)) | Should -Be 315
        $rule.Invoke($null, @([long]20000000000)) | Should -Be 3000
        $rule.Invoke($null, @([long]1000000000000)) | Should -Be 86400
    }

    It 'reports the 24 h cap, the stall limit and the estimate of a default run, and lets an explicit deadline win' {
        $s=New-VerificationStore
        try {
            $bytes = $s.Scalar('SELECT (SELECT page_count FROM pragma_page_count())*(SELECT page_size FROM pragma_page_size());',$null)
            $r = $s.VerifyServeRollups()
            $r.Verified | Should -BeTrue
            $r.DeadlineSeconds | Should -Be 86400
            $r.DeadlineExplicit | Should -BeFalse
            $r.EstimatedSeconds | Should -Be 300
            $r.FileBytes | Should -Be $bytes
            $r.StallSeconds | Should -Be 600
            $r.IdentitiesPerSecond | Should -BeGreaterThan 0
            $r.CacheMissPages | Should -BeGreaterThan 0
            $r.TempDirectory | Should -BeExactly (Split-Path $s.FilePath -Parent)
            $r.TempFreeBytes | Should -BeGreaterThan 0
            $r.SortPeakBytes | Should -BeGreaterOrEqual 0
            $r.MaxProgressGapMs | Should -BeGreaterOrEqual 0
            $r.MaxProgressGapMs | Should -BeLessThan ($r.StallSeconds * 1000)
            $e = $s.VerifyServeRollupsWithDeadline(7,[Threading.CancellationToken]::None)
            $e.Verified | Should -BeTrue
            $e.DeadlineSeconds | Should -Be 7
            $e.DeadlineExplicit | Should -BeTrue
            $e.EstimatedSeconds | Should -Be 300
            $c = $s.VerifySmtpClients()
            $c.DeadlineSeconds | Should -Be 86400
            $c.EstimatedSeconds | Should -Be 300
            $c.FileBytes | Should -Be $bytes
            $c.StallSeconds | Should -Be 600
            # The static entry point applies the same rule to the same file.
            $path=$s.FilePath; $s.Dispose(); $s=$null
            $db=[Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$path;Mode=ReadOnly;Pooling=False"); $db.Open()
            try {
                $receipt=[ExchangeLogReport.Store]::VerifyServeRollups($db)
                $receipt.DeadlineSeconds | Should -Be 86400
                $receipt.DeadlineExplicit | Should -BeFalse
                $receipt.FileBytes | Should -Be $bytes
            } finally {$db.Dispose()}
        } finally { if ($s) {$s.Dispose()} }
    }

    It 'says in a timeout message which deadline was exceeded, the estimate and how far the verification went' {
        $flags = [Reflection.BindingFlags]'Static,NonPublic'
        $message = [ExchangeLogReport.Store].GetMethod('VerificationTimeoutMessage', $flags)
        $cap = $message.Invoke($null, @([int]86400, $false, [long]958244, [double]2303.4, [int]3000, [long]20000000000))
        $cap | Should -BeLike '*deadline of 86,400 s (24 h cap; estimated 3,000 s from 20.0 GB at 20 MB/s) after verifying 958,244 identities in 2,303 s (416 identities/s)*'
        $cap | Should -BeLike '*no database changes were made. Run it when no collection is running, or pass a longer deadline to VerifyServeRollupsWithDeadline.'
        $explicit = $message.Invoke($null, @([int]7, $true, [long]12, [double]7.1, [int]300, [long]1000000))
        $explicit | Should -BeLike '*deadline of 7 s (explicit deadline; estimated 300 s from 0.0 GB at 20 MB/s) after verifying 12 identities in 7 s*'
        $stall = [ExchangeLogReport.Store].GetMethod('VerificationStallMessage', $flags).Invoke($null, @('Serve rollup verification', [int]600, [long]5, [double]700.2))
        $stall | Should -BeExactly 'Serve rollup verification made no progress for 600 s (last progress after 5 identities, 700 s into the run); the disk or the database file is not responding. No verification result was published and no database changes were made.'
    }}
