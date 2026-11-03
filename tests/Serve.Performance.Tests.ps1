#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }
Describe 'Serve bounded synthetic performance gate' {
    It 'keeps first and warm HTTP list requests below one second with an indexed order and a concurrent writer' {
        $path = & (Join-Path $PSScriptRoot 'Serve.Measure.ps1') -Messages 12000
        $evidence = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $evidence.scale24GBProven | Should -BeFalse
        $evidence.osCacheCold | Should -BeFalse
        $evidence.messageRows | Should -Be 12000
        $evidence.trackingEvents | Should -Be 24000
        $evidence.gatePassed | Should -BeTrue
        $evidence.rollupVerification.Verified | Should -BeTrue
        $evidence.rollupVerification.RowsVerified | Should -Be 12000
        $evidence.rollupVerification.SourceHashesVerified | Should -BeTrue
        $evidence.overview.maxMilliseconds | Should -BeLessThan 1000
        $evidence.unfilteredPlan -join "`n" | Should -Match 'INDEX ix_rollup_last \(member_last_ms>\? AND member_last_ms<\?\)'
        # Rows sharing one member_last_ms are put in id order by a block sort of that group only (the index continues with member_first_ms): no full sort.
        $evidence.unfilteredPlan -join "`n" | Should -Not -Match 'USE TEMP B-TREE FOR ORDER BY'
        $evidence.statusPlan -join "`n" | Should -Match 'INDEX ix_rollup_status_last \(status=\? AND member_last_ms>\? AND member_last_ms<\?\)'
        $evidence.statusPlan -join "`n" | Should -Not -Match 'USE TEMP B-TREE FOR ORDER BY'
        # A period in the middle of the data: bounded by the pages of its own index range plus the rows of one page, not by the rows after it.
        $evidence.middleList.rows | Should -Be 100
        $evidence.middleList.milliseconds | Should -BeLessThan 1000
        $evidence.middleList.cacheMissPages | Should -BeLessOrEqual $evidence.middleList.pageBound
        foreach ($case in $evidence.lists) {
            $case.firstRequestMilliseconds | Should -BeLessThan 1000
            $case.warmP95Milliseconds | Should -BeLessThan 1000
            $case.maxMilliseconds | Should -BeLessThan 1000
        }
        $evidence.writerCommittedDuringHttpStream | Should -BeTrue
        $evidence.writerCommitDuringHttpStreamMilliseconds | Should -BeLessThan 1000
        $evidence.rollupVerification.DeadlineSeconds | Should -Be 86400
        $evidence.rollupVerification.EstimatedSeconds | Should -Be 300
        $evidence.rollupVerification.Method | Should -BeExactly 'merge-scan'
        $evidence.rollupVerification.DeadlineExplicit | Should -BeFalse
        $evidence.rollupVerificationSeconds | Should -BeGreaterThan 0
    }
}

Describe 'Serve rollup verification performance target' {
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
    }
    # The five-minute target on the fixed-size reference fixture (100,000 messages, the size of serve-static-verification-100k.json);
    # it is a performance gate of its own, separate from the deadline a verification computes from the rows of a store.
    It 'verifies the 100,000-message reference fixture in under five minutes' {
        $out = Join-Path $script:Root 'bin\t'
        [void][IO.Directory]::CreateDirectory($out)
        $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $path = Join-Path $out "serve-verify-$id.sqlite"
        $store = [ExchangeLogReport.Store]::new($path, $false, 'synthetic-benchmark')
        try {
            [ServeFixtures]::Populate($store, 1792000000000L, 100000)
            $r = $store.VerifyServeRollups()
            $pages = $store.Scalar('PRAGMA page_count;',$null)
        } finally { $store.Dispose() }
        try {
            [ordered]@{ fixture = $path; messages = 100000; measuredAtUtc = [DateTimeOffset]::UtcNow.ToString('O'); targetSeconds = 300
                seconds = $r.ElapsedMilliseconds / 1000; pageCount = $pages; cacheMissPages = $r.CacheMissPages; identitiesPerSecond = $r.IdentitiesPerSecond; verification = $r } |
                ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $out "serve-rollup-verification-$id.json") -Encoding utf8
            $r.Verified | Should -BeTrue
            $r.RowsVerified | Should -BeGreaterOrEqual 100000
            $r.DeadlineExplicit | Should -BeFalse
            $r.IdentitiesPerSecond | Should -BeGreaterThan 0
            $r.ElapsedMilliseconds | Should -BeLessThan 300000
            # Disk-independent I/O bound: about one pass over the file (the per-identity path reads several pages per identity).
            $r.Method | Should -BeExactly 'merge-scan'
            $r.CacheMissPages | Should -BeLessOrEqual ([long][Math]::Ceiling(1.3 * $pages))
        } finally { Remove-Item -LiteralPath $path, ($path + '-wal'), ($path + '-shm') -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Serve overview of a week from the mail flow per hour' {
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
    }
    # 40,000 journeys over 7 days (RECEIVE on EX1, DELIVER on EX2, an SMTP transaction each): the hourly table answers the week, the live
    # statements (a user filter) read every event of it; both give the same mail flow.
    It 'answers the servers and daily figures of a week from mail_flow_hour and the rollup index, with the figures of the rows' {
        $out = Join-Path $script:Root 'bin\t'
        [void][IO.Directory]::CreateDirectory($out)
        $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $path = Join-Path $out "serve-overview-$id.sqlite"
        $epoch = 1792000000000L - (1792000000000L % 86400000L)
        $store = [ExchangeLogReport.Store]::new($path, $false, 'synthetic-benchmark')
        try {
            $tx = [ServeFixtures]::Connection($store).BeginTransaction()
            $c = [ServeFixtures]::Connection($store).CreateCommand(); $c.Transaction = $tx
            $c.CommandText = @"
WITH RECURSIVE n(i) AS (VALUES(0) UNION ALL SELECT i+1 FROM n WHERE i<39999)
INSERT INTO message_event(time_ms,server,event_id,message_id,log_id,sender,recipients) SELECT @t+i*15120,'EX1','RECEIVE','<w'||i||'@invalid>','wr'||i,'s@invalid','r@invalid' FROM n;
INSERT INTO message_event(time_ms,server,event_id,message_id,log_id,sender,recipients) SELECT time_ms+2000,'EX2',CASE WHEN id%9=0 THEN 'FAIL' ELSE 'DELIVER' END,message_id,'wd'||id,sender,recipients FROM message_event WHERE event_id='RECEIVE';
INSERT INTO smtp_transaction(time_ms,server,direction,session_id,message_id,status,mail_from,rcpts) SELECT time_ms+300,'EX1','Receive','ws'||id,message_id,CASE WHEN id%11=0 THEN 'Rejected' ELSE 'Accepted' END,sender,recipients FROM message_event WHERE event_id='RECEIVE';
"@
            [void]$c.Parameters.AddWithValue('@t', $epoch)
            [void]$c.ExecuteNonQuery(); $c.Dispose()
            $store.ReconcileMessageRollups($tx); $tx.Commit(); $tx.Dispose()
            $store.Scalar('SELECT COUNT(*) FROM mail_flow_hour;', $null) | Should -Be (7 * 24 * 2)
            $plans = @([ExchangeLogReport.ServeDiagnostics]::ExplainReportDatasets($path, $epoch, $epoch + 7 * 86400000, $null, $null) | ConvertFrom-Json)
        } finally { $store.Dispose() }
        try {
            $inside = @($plans | Where-Object { $_ -like 'SELECT r.servers, COUNT(*) FROM message_rollup r INDEXED BY ix_rollup_last*' })[0]
            $inside | Should -Match 'SEARCH r USING COVERING INDEX ix_rollup_last \(member_last_ms>\? AND member_last_ms<\?\)'
            $inside | Should -Not -Match 'TEMP B-TREE FOR ORDER BY'
            foreach ($entry in @($plans | Where-Object { $_ -like '*FROM mail_flow_hour*' })) { $entry | Should -Match 'SEARCH mail_flow_hour USING PRIMARY KEY \(hour_ms>\? AND hour_ms<\?\)' }
            # The protocol x authentication type statements of the Authentication dataset read the days of the period through the key of access_client.
            $auth = @($plans | Where-Object { $_ -like 'SELECT protocol, auth_type,*FROM access_client WHERE day >= @d0*' })
            $auth.Count | Should -BeGreaterOrEqual 2
            foreach ($entry in $auth) { $entry | Should -Match 'SEARCH access_client USING PRIMARY KEY \(day>\? AND day<\?\)' }
            $o = [ExchangeLogReport.ServeOptions]::new()
            $o.DatabasePath = $path; $o.WebRoot = Join-Path $script:Root 'templates'; $o.Port = 0; $o.NoBrowser = $true; $o.Zone = [TimeZoneInfo]::Utc
            $o.ReadyFile = Join-Path $out "serve-overview-$id.json"; $o.ReadyFileWithToken = $true; $o.RequestTimeoutSeconds = 60; $o.AggregateTimeoutSeconds = 60
            $task = [ExchangeLogReport.ServeHost]::RunAsync($o, [Threading.CancellationToken]::None)
            $wait = [Diagnostics.Stopwatch]::StartNew()
            while (-not (Test-Path -LiteralPath $o.ReadyFile)) { if ($task.IsCompleted) { $task.GetAwaiter().GetResult() }; if ($wait.Elapsed.TotalSeconds -gt 30) { throw 'Serve not ready.' }; Start-Sleep -Milliseconds 20 }
            $ready = Get-Content -LiteralPath $o.ReadyFile -Raw | ConvertFrom-Json
            $headers = @{ 'X-Portal-Token' = $ready.token }
            $week = 'from=' + [Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($epoch).ToString('O')) + '&to=' + [Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($epoch + 7 * 86400000).ToString('O'))
            try {
                $times = foreach ($k in 1..3) {
                    # A server filter that matches every row keeps the hourly path and gives every sample its own answer (no result cache).
                    $clock = [Diagnostics.Stopwatch]::StartNew()
                    $r = Invoke-WebRequest -Uri ($ready.url.TrimEnd('/') + "/api/overview/servers?$week" + $(if ($k -gt 1) { "&server=EX$($k - 1)" } else { '' })) -Headers $headers -SkipHttpErrorCheck
                    $r.StatusCode | Should -Be 200
                    $clock.Elapsed.TotalMilliseconds
                }
                $hourly = Invoke-WebRequest -Uri ($ready.url.TrimEnd('/') + "/api/overview/servers?$week") -Headers $headers | ForEach-Object Content | ConvertFrom-Json
                $live = Invoke-WebRequest -Uri ($ready.url.TrimEnd('/') + "/api/overview/servers?$week&user=%40invalid") -Headers $headers | ForEach-Object Content | ConvertFrom-Json
                foreach ($ms in $times) { $ms | Should -BeLessThan 1000 }
                @($hourly.servers.rows | ForEach-Object { @($_.cells[0], $_.cells[7..15]) -join '|' }) -join "`n" | Should -BeExactly (@($live.servers.rows | ForEach-Object { @($_.cells[0], $_.cells[7..15]) -join '|' }) -join "`n")
                @($hourly.daily.rows | ForEach-Object { @($_.cells[0], $_.cells[1], $_.cells[5..7]) -join '|' }) -join "`n" | Should -BeExactly (@($live.daily.rows | ForEach-Object { @($_.cells[0], $_.cells[1], $_.cells[5..7]) -join '|' }) -join "`n")
                [long](@($hourly.servers.rows | Where-Object { $_.cells[0] -eq 'EX1' })[0].cells[13]) | Should -Be 40000
            } finally {
                try { Invoke-WebRequest -Uri ($ready.url.TrimEnd('/') + '/api/shutdown') -Method Post -Headers $headers -SkipHttpErrorCheck | Out-Null } catch { }
                [void]$task.Wait(15000)
            }
        } finally { Remove-Item -LiteralPath $path, ($path + '-wal'), ($path + '-shm') -Force -ErrorAction SilentlyContinue }
    }
}