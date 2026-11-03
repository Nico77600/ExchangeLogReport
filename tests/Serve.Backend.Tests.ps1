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
            'System.Text.Encoding.Extensions', 'System.IO', 'System.Collections', 'System.Linq.Expressions', 'System.ComponentModel.Primitives', 'netstandard'
        )
    }
    if (-not ('ServeHttpTestClient' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Net.Http;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;

public sealed class ServeHttpTestClient : DelegatingHandler
{
    readonly int delay;
    public ServeHttpTestClient(int delay) : base(new HttpClientHandler()) { this.delay = delay; }
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancel)
    {
        await Task.Delay(delay, cancel).ConfigureAwait(false);
        return await base.SendAsync(request, cancel).ConfigureAwait(false);
    }

    public static SemaphoreSlim Admission(Task host)
    {
        // Observe the live semaphore without adding a production-only testing hook.
        const BindingFlags flags = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
        var stateField = host.GetType().GetField("StateMachine", flags);
        var state = stateField == null ? null : stateField.GetValue(host);
        if (state != null)
            foreach (var field in state.GetType().GetFields(flags))
            {
                if (field.FieldType.DeclaringType != state.GetType().DeclaringType) continue;
                var closure = field.GetValue(state);
                if (closure == null) continue;
                foreach (var captured in closure.GetType().GetFields(flags))
                    if (captured.FieldType == typeof(SemaphoreSlim))
                        return (SemaphoreSlim)captured.GetValue(closure);
            }
        throw new InvalidOperationException("The host admission semaphore was not found; saturation was not established.");
    }

    public static Task[] Workers(Task host)
    {
        const BindingFlags flags = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
        var state = host.GetType().GetField("StateMachine", flags).GetValue(host);
        foreach (var field in state.GetType().GetFields(flags))
            if (field.FieldType == typeof(System.Collections.Generic.List<Task>))
                return ((System.Collections.Generic.List<Task>)field.GetValue(state)).ToArray();
        throw new InvalidOperationException("The host worker inventory was not found.");
    }
}
'@
    }
    $script:Work = Join-Path $script:Root ('bin\t\s' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    # The folder of the report template: the page of the portal.
    $script:Web = Join-Path $script:Root 'templates'
    $script:Epoch = 1792000000000L
    $script:Period = 'from=2026-10-14T00%3A00%3A00Z&to=2026-10-16T00%3A00%3A00Z'
    $script:Hosts = [Collections.Generic.List[object]]::new()
    function New-ServeStore([string]$Name) { [ExchangeLogReport.Store]::new((Join-Path $script:Work "$Name.sqlite"), $false, 'synthetic') }
    function Write-Sql($Store, [string]$Sql, [hashtable]$Values = @{}) {
        $c = [ServeFixtures]::Connection($Store).CreateCommand()
        try {
            $c.CommandText = $Sql
            foreach ($key in $Values.Keys) {
                $value = $Values[$key]
                if ($null -eq $value) { $value = [DBNull]::Value }
                [void]$c.Parameters.AddWithValue("@$key", $value)
            }
            [void]$c.ExecuteNonQuery()
        } finally { $c.Dispose() }
    }
    function Reconcile($Store) {
        $tx = $Store.Begin()
        try { $Store.ReconcileMessageRollups($tx); $tx.Commit() } finally { $tx.Dispose() }
    }
    function Collect-Tracking($Store, [string]$Folder, [bool]$FailOnError = $true, [bool]$TriggersOff = $true, [string]$Kind = 'Tracking') {
        $o = [ExchangeLogReport.CollectorOptions]::new()
        $o.NowMs = $script:Epoch+86400000; $o.Parallelism = 1
        $o.DisableTriggersDuringApply = $TriggersOff
        $o.RunId = $Store.StartRun('Collect','synthetic','synthetic','test')
        $collector = [ExchangeLogReport.Collector]::new($Store,$o)
        $job = [ExchangeLogReport.SourceJob]::new()
        $job.Server='EX1'; $job.Kind=$Kind; $job.Folder=$Folder; $job.Recurse = $Kind -eq 'HttpProxy'
        $collector.Plan(@($job),[datetime]::MinValue)
        $run=$collector.Start(@($job)); [void]$run.Wait(-1)
        if($run.Error -and $FailOnError){throw $run.Error}
        if(-not $run.Error){[void]$collector.Complete()}
        return $run
    }
    function Add-Mail($Store) {
        Write-Sql $Store @"
INSERT INTO source_file(id,server,kind,path,offset,size,first_ms,last_ms,file_key) VALUES(1,'EX1','Tracking','synthetic.log',1234,5678,@t-86400000,@t+86400000,'SYNTHETIC');
INSERT INTO message_event(time_ms,server,event_id,message_id,log_id,sender,recipients,subject,recipient_count)
VALUES(@t,'EX1','RECEIVE','<Case@invalid>','a','alpha@invalid','one@invalid;two@invalid','=SUM(1)',2),
(@t+100,'EX1','DELIVER','<Case@invalid>','b','alpha@invalid','one@invalid',NULL,1),
(@t+200,'EX2','SEND','<Case@invalid>','c','alpha@invalid','two@invalid',NULL,1),
(@t+300,'EX2','FAIL','<Case@invalid>','d','alpha@invalid','two@invalid',NULL,1),
(@t+400,'EX1','DELIVER','<case@invalid>','e','beta@invalid','one@invalid',NULL,1),
(@t-172800000,'EX1','RECEIVE','<long@invalid>','f','alpha@invalid','one@invalid',NULL,1),
(@t+600,'EX2','DELIVER','<long@invalid>','g','alpha@invalid','one@invalid',NULL,1),
(@t-259200000,'EX1','RECEIVE','<outside@invalid>','h','alpha@invalid','one@invalid',NULL,1),
(@t+900,'EX1','RECEIVE','<scope@invalid>','j','alpha@invalid','one@invalid',NULL,1),
(@t+1000,'EX2','DELIVER','<scope@invalid>','k','beta@invalid','other@invalid',NULL,1);
INSERT INTO smtp_transaction(time_ms,server,direction,session_id,message_id,status,mail_from,rcpts,transcript,auth_user,auth_source,auth_result)
VALUES(@t-100,'EX1','Receive','smtp-case','<Case@invalid>','Accepted','alpha@invalid','one@invalid',@transcript,'proved@invalid','SameSession','Success'),
(@t+500,'EX1','Receive','smtp-refused',NULL,'Rejected','alpha@invalid','one@invalid',@transcript,NULL,NULL,NULL),
(@t+700,'EX1','Receive','smtp-outside','<outside@invalid>','Accepted','alpha@invalid','one@invalid',@transcript,NULL,NULL,NULL);
INSERT INTO client_session(id,skey,day,start_ms,end_ms,user,protocol,front_ends,back_ends,requests,successes,failures,slow,first_success_ms,last_success_ms,first_failure_ms,last_failure_ms,total_ms,max_ms,bytes_in,bytes_out,actions,statuses,auth_modes)
VALUES(1,'session','2026-10-14',@t+123,@t+999,'alpha@invalid','Mapi','EX1','EX2',1,1,0,0,@t+123,@t+123,0,0,2,2,0,0,@actions,@actions,'Negotiate=1');
INSERT INTO session_step(session_id,time_ms,data) VALUES(1,@t+123,@steps);
"@ @{ t = $script:Epoch; transcript = [ExchangeLogReport.Packed]::Pack("AUTH <redacted>`n250 synthetic"); actions = [ExchangeLogReport.Packed]::Adaptive(('Bind=1;' * 60)); steps = "[[$($script:Epoch+123),$($script:Epoch+999),`"EX1`",null,`"Bind`",200,1,2,2,0,`"ok`",`"req-1`",`"FE`",false,1,`"find-request`",null]]" }
        Reconcile $Store
    }
    # A failed request of the period whose IIS status row is read through a slow view: iis_status is not an object of the shape Serve requires, and
    # every list, count or scan of the requests that reads its fields runs for longer than a short deadline.
    function Add-SlowRequests($Store) {
        $Store.Exec("INSERT INTO access_event(time_ms,server,source,protocol,user,outcome,request_id) VALUES($script:Epoch,'EX1','Synthetic','Mapi','s@invalid','Slow','slow-1');" +
            "INSERT INTO iis_status(server,request_id,time_ms,status) VALUES('EX1','slow-1',$script:Epoch,500); ALTER TABLE iis_status RENAME TO iis_status_base;" +
            "CREATE VIEW iis_status AS SELECT b.* FROM iis_status_base b CROSS JOIN (WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<100000000) SELECT SUM(i) FROM n);")
    }
    function Add-ClientRows($Store) {
        Add-Mail $Store
        Write-Sql $Store @"
UPDATE smtp_transaction SET role='FrontEnd',connector='Default',remote_ep='198.51.100.10:25001',helo='client.invalid',tls='TLS1.2',
 auth_mechanism='LOGIN',auth_result='Succeeded',auth_attempt_result='Succeeded',auth_source='Direct' WHERE id=1;
INSERT INTO smtp_transaction(id,time_ms,server,direction,role,connector,session_id,remote_ep,helo,mail_from,rcpts,rcpt_count,message_id,status,auth_user,auth_mechanism,auth_result,auth_attempt_result,auth_source,transcript) VALUES
(10,@t+2000,'EX1','Receive','FrontEnd','Default','a2','198.51.100.10:25099','client.invalid','forged-from@invalid','r@invalid',1,'<a2@invalid>','Rejected','proved@invalid','LOGIN','Succeeded','Failed','Direct',@transcript),
(11,@t+3000,'EX1','Receive','FrontEnd','Default','a3','198.51.100.10:25100','client.invalid','forged-from@invalid','r@invalid',2,'<a3@invalid>','Deferred','proved@invalid','LOGIN','Succeeded','Succeeded','Direct',NULL),
(12,@t+4000,'EX1','Receive','Mailbox','Default','role','198.51.100.10:25101','client.invalid','s@invalid','r@invalid',1,'<role@invalid>','Accepted','proved@invalid','LOGIN','Succeeded','Succeeded','Direct',NULL),
(13,@t+5000,'EX2','Receive','FrontEnd','Default','server','198.51.100.10:25102','client.invalid','s@invalid','r@invalid',1,'<server@invalid>','Accepted','proved@invalid','LOGIN','Succeeded','Succeeded','Direct',NULL),
(14,@t+6000,'EX1','Receive','FrontEnd','Other','connector','198.51.100.10:25103','client.invalid','s@invalid','r@invalid',1,'<connector@invalid>','Accepted','proved@invalid','LOGIN','Succeeded','Succeeded','Direct',NULL),
(15,@t+7000,'EX1','Receive','FrontEnd','Default','helo','198.51.100.10:25104','other.invalid','s@invalid','r@invalid',1,'<helo@invalid>','Accepted','proved@invalid','LOGIN','Succeeded','Succeeded','Direct',NULL),
(16,@t+8000,'EX1','Receive','FrontEnd','Default','account','198.51.100.10:25105','client.invalid','s@invalid','r@invalid',1,'<account@invalid>','Accepted','other@invalid','LOGIN','Succeeded','Succeeded','Direct',NULL),
(17,@t+9000,'EX1','Receive','FrontEnd','Default','unknown-a',NULL,'client.invalid','s@invalid','r@invalid',1,NULL,'Rejected',NULL,NULL,NULL,NULL,'Missing',NULL),
(18,@t+10000,'EX1','Receive','FrontEnd','Default','unknown-b',NULL,'client.invalid','s@invalid','r@invalid',1,NULL,'Rejected',NULL,NULL,NULL,NULL,'Missing',NULL),
(19,@t+11000,'EX1','Receive','FrontEnd','Default','v6-a','[2001:db8::1]:30001','client.invalid','s@invalid','r@invalid',1,'<v6a@invalid>','Accepted','proved@invalid','LOGIN','Succeeded','Succeeded','FrontEndProxy',NULL),
(20,@t+12000,'EX1','Receive','FrontEnd','Default','v6-b','[2001:DB8::1]:30002','client.invalid','s@invalid','r@invalid',1,'<v6b@invalid>','Accepted','proved@invalid','LOGIN','Succeeded','Succeeded','FrontEndProxy',NULL),
(21,@t+13000,'EX1','Receive','FrontEnd','Default','retired','198.51.100.30:25','client.invalid','s@invalid','r@invalid',1,'<retired@invalid>','Accepted','RETIRED-IDENTITY@invalid','LOGIN','Succeeded','Succeeded','Overflow',NULL);
"@ @{t=$script:Epoch;transcript=[ExchangeLogReport.Packed]::Pack("12:00:00.000 C: AUTH LOGIN`n12:00:00.001 S: 334 SYNTHETICCHALLENGE`n12:00:00.002 C: SYNTHETICPAYLOAD`n12:00:00.003 S: 235 2.7.0 Authentication successful")}
        Reconcile $Store
    }
    # -Aggregate: deadline of the overview requests (default: the same as the other requests). -WebRoot: the folder of the report template
    # (default: the package's templates folder).
    function Start-ServeTest([string]$Path, [int]$Timeout = 5, [int]$Concurrency = 4,
        [Threading.CancellationToken]$Cancellation = [Threading.CancellationToken]::None, [int]$Aggregate = 0, [string]$WebRoot = (Join-Path $script:Root 'templates'),
        [TimeZoneInfo]$Zone = [TimeZoneInfo]::Utc) {
        $o = [ExchangeLogReport.ServeOptions]::new()
        $o.DatabasePath = $Path; $o.WebRoot = $WebRoot; $o.Port = 0; $o.NoBrowser = $true
        $o.ReadyFile = Join-Path $script:Work ([guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
        $o.ReadyFileWithToken = $true; $o.RequestTimeoutSeconds = $Timeout
        $o.AggregateTimeoutSeconds = if ($Aggregate -gt 0) { $Aggregate } else { $Timeout }
        $o.MaxConcurrency = $Concurrency
        # The days of the daily tables of the fixtures are UTC days unless -Zone names their zone.
        $o.Zone = $Zone
        $task = [ExchangeLogReport.ServeHost]::RunAsync($o,$Cancellation)
        $wait = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -LiteralPath $o.ReadyFile)) {
            if ($task.IsCompleted) { $task.GetAwaiter().GetResult(); throw 'Host stopped before ready.' }
            if ($wait.Elapsed.TotalSeconds -gt 10) { throw 'Ready timeout.' }
            Start-Sleep -Milliseconds 20
        }
        $ready = Get-Content -LiteralPath $o.ReadyFile -Raw | ConvertFrom-Json
        $hostInfo = [pscustomobject]@{ Options = $o; Task = $task; Url = $ready.url.TrimEnd('/'); Port = $ready.port; Token = $ready.token }
        $script:Hosts.Add($hostInfo)
        return $hostInfo
    }
    function Request($HostInfo, [string]$Path, [hashtable]$Headers = @{}, [string]$Method = 'GET') {
        $h = @{ 'X-Portal-Token' = $HostInfo.Token }
        foreach ($key in $Headers.Keys) { $h[$key] = $Headers[$key] }
        Invoke-WebRequest -Uri ($HostInfo.Url + $Path) -Headers $h -Method $Method -SkipHttpErrorCheck -TimeoutSec 15
    }
    function Downgrade($Store, [int]$Version) {
        [ServeFixtures]::ConvertToLegacySyntheticFixture($Store,$Version)
    }
    $script:HttpStore = New-ServeStore 'http'
    Add-Mail $script:HttpStore
    $script:Http = Start-ServeTest $script:HttpStore.FilePath
}

AfterAll {
    foreach ($h in $script:Hosts) {
        if (-not $h.Task.IsCompleted) {
            try { [void](Request $h '/api/shutdown' @{} 'POST') } catch { }
            if (-not $h.Task.Wait(10000)) { throw 'Serve did not stop cleanly.' }
        }
        $h.Task.GetAwaiter().GetResult()
    }
    if ($script:HttpStore) { $script:HttpStore.Dispose() }
    if ($script:Work) { Remove-Item -LiteralPath $script:Work -Recurse -Force }
}

Describe 'Serve schema and incremental publication' {
    It 'matches the existing Detailed journey status semantics without replacing Usage HTML' {
        $q = [ExchangeLogReport.ReportRequest]::new()
        $q.StartMs=$script:Epoch-86400000; $q.EndMs=$script:Epoch+86400000
        $q.OutputFolder=Join-Path $script:Work 'legacy-status'; $q.Detailed=$true
        $q.WriteHtml=$false; $q.WriteCsv=$true; $q.MemoryBudgetMB=64; $q.Parallelism=1
        $result=[ExchangeLogReport.ReportBuilder]::Build($script:HttpStore,$q)
        $messages=@(Import-Csv -LiteralPath ($result.Files | Where-Object Dataset -EQ 'messages').Path -Delimiter ';')
        foreach($row in $messages | Where-Object { $_.'Message ID' }){
            $expected=$script:HttpStore.Query("SELECT v.text FROM message_rollup r JOIN message_rollup_value v ON v.id=r.status WHERE r.kind=0 AND r.identity=@id COLLATE BINARY;",@{id=$row.'Message ID'}).Rows[0][0]
            $row.Status | Should -BeExactly $expected
        }
    }

    It 'gives the rollup the same labels as the Detailed report for lists, suppressed and handed-off mail' {
        $s=New-ServeStore 'status-labels'
        try {
            Write-Sql $s @"
INSERT INTO message_event(time_ms,server,event_id,message_id,log_id,sender,recipients,recipient_status,related_recipient) VALUES
(@t,'EX1','RECEIVE','<dl@invalid>','s1','a@invalid','list@invalid',NULL,NULL),
(@t+100,'EX1','EXPAND','<dl@invalid>','s2','a@invalid','m1@invalid;m2@invalid',NULL,'list@invalid'),
(@t+200,'EX1','DROP','<dl@invalid>','s3','a@invalid','list@invalid','250 2.1.5 RESOLVER.GRP.Expanded; distribution list expanded',NULL),
(@t+300,'EX1','DELIVER','<dl@invalid>','s4','a@invalid','m1@invalid;m2@invalid',NULL,NULL),
(@t,'EX1','RECEIVE','<empty@invalid>','s5','a@invalid','ping@invalid',NULL,NULL),
(@t+100,'EX1','EXPAND','<empty@invalid>','s6','a@invalid',NULL,NULL,'ping@invalid'),
(@t+200,'EX1','DROP','<empty@invalid>','s7','a@invalid','ping@invalid','250 2.1.5 RESOLVER.GRP.Expanded; distribution list expanded',NULL),
(@t,'EX1','RECEIVE','<oof@invalid>','s8','a@invalid','x@invalid',NULL,NULL),
(@t+100,'EX1','DROP','<oof@invalid>','s9','a@invalid','x@invalid','250 2.1.5 RESOLVER.OOF.IntToExt; out-of-office',NULL),
(@t,'EX1','RECEIVE','<relay@invalid>','s10','a@invalid','a@invalid;b@invalid',NULL,NULL),
(@t+100,'EX1','DELIVER','<relay@invalid>','s11','a@invalid','a@invalid',NULL,NULL),
(@t+200,'EX1','SEND','<relay@invalid>','s12','a@invalid','b@invalid',NULL,NULL);
"@ @{t=$script:Epoch}
            Reconcile $s
            $q = [ExchangeLogReport.ReportRequest]::new()
            $q.StartMs=$script:Epoch-86400000; $q.EndMs=$script:Epoch+86400000
            $q.OutputFolder=Join-Path $script:Work 'status-labels'; $q.Detailed=$true
            $q.WriteHtml=$false; $q.WriteCsv=$true; $q.MemoryBudgetMB=64; $q.Parallelism=1
            $result=[ExchangeLogReport.ReportBuilder]::Build($s,$q)
            $messages=@(Import-Csv -LiteralPath ($result.Files | Where-Object Dataset -EQ 'messages').Path -Delimiter ';')
            $messages.Count | Should -Be 4
            $expected=@{ '<dl@invalid>'='Delivered'; '<empty@invalid>'='Suppressed (by design)'; '<oof@invalid>'='Suppressed (by design)'; '<relay@invalid>'='Delivered and handed off' }
            foreach($row in $messages){
                $row.Status | Should -BeExactly $expected[$row.'Message ID']
                $s.Query("SELECT v.text FROM message_rollup r JOIN message_rollup_value v ON v.id=r.status WHERE r.kind=0 AND r.identity=@id COLLATE BINARY;",@{id=$row.'Message ID'}).Rows[0][0] | Should -BeExactly $row.Status
            }
        } finally { $s.Dispose() }
    }

    It 'serves the mail sent to external with the status of the static report: list, Status filter, overview counts and detail' {
        $s=New-ServeStore 'external'
        try {
            Write-Sql $s @"
INSERT INTO message_event(time_ms,server,event_id,message_id,log_id,sender,recipients,recipient_status,connector,server_ip) VALUES
(@t,'EX1','RECEIVE','<ext@invalid>','x1','a@invalid','partner@fabrikam.example',NULL,NULL,NULL),
(@t+100,'EX1','SENDEXTERNAL','<ext@invalid>','x2','a@invalid','partner@fabrikam.example','250 2.1.5 Ok','To Internet via Postfix','203.0.113.5'),
(@t+200,'EX1','RECEIVE','<extd@invalid>','x3','a@invalid','b@invalid;partner@fabrikam.example',NULL,NULL,NULL),
(@t+300,'EX1','DELIVER','<extd@invalid>','x4','a@invalid','b@invalid',NULL,NULL,NULL),
(@t+400,'EX1','SENDEXTERNAL','<extd@invalid>','x5','a@invalid','partner@fabrikam.example','250 2.1.5 Ok','To Internet via Postfix','203.0.113.5');
UPDATE metadata SET value='invalid' WHERE key='mailflow_accepted_domains';
"@ @{t=$script:Epoch}
            $path=$s.FilePath; $s.Dispose()
            # A new store reads the stored rules (the domains a collection would have learnt from the DELIVER).
            $s=[ExchangeLogReport.Store]::new($path,$false,'synthetic')
            Reconcile $s
            $s.VerifyServeRollups().Verified | Should -BeTrue
            $q = [ExchangeLogReport.ReportRequest]::new()
            $q.StartMs=$script:Epoch-86400000; $q.EndMs=$script:Epoch+86400000
            $q.OutputFolder=Join-Path $script:Work 'external-report'; $q.Detailed=$true
            $q.WriteHtml=$false; $q.WriteCsv=$true; $q.MemoryBudgetMB=64; $q.Parallelism=1
            $result=[ExchangeLogReport.ReportBuilder]::Build($s,$q)
            $csv=@{}; foreach ($row in Import-Csv -LiteralPath ($result.Files | Where-Object Dataset -EQ 'messages').Path -Delimiter ';') { $csv[$row.'Message ID'] = $row }
            $csv['<ext@invalid>'].Status | Should -BeExactly 'Sent to external'
            $csv['<extd@invalid>'].Status | Should -BeExactly 'Delivered and sent to external'
            $h = Start-ServeTest $path
            foreach ($status in 'Sent to external', 'Delivered and sent to external') {
                $list = (Request $h "/api/messages?$script:Period&status=$([Uri]::EscapeDataString($status))").Content | ConvertFrom-Json
                @($list.rows).Count | Should -Be 1 -Because $status
                $list.rows[0].cells[3] | Should -BeExactly $status
                $detail = (Request $h "/api/messages/$($list.rows[0].id)?$script:Period").Content | ConvertFrom-Json
                $detail.cells[3] | Should -BeExactly $status
                @($detail.cells[5]) -join '; ' | Should -BeExactly $csv[$detail.cells[15]].Recipients
            }
            $counts = (Request $h "/api/overview/counts?$script:Period").Content | ConvertFrom-Json
            $messages = @($counts.rows | Where-Object { $_.cells[0] -eq 'Messages' })
            foreach ($status in 'Sent to external', 'Delivered and sent to external') {
                [long](@($messages | Where-Object { $_.cells[1] -eq $status })[0].cells[2]) | Should -Be 1 -Because $status
            }
        } finally { $s.Dispose() }
    }

    It 'reconciles the production collector transaction, partial final lines and subsequent incremental reads' {
        $s=New-ServeStore 'production'
        $folder=Join-Path $script:Work 'tracking'; [void][IO.Directory]::CreateDirectory($folder)
        $file=Join-Path $folder 'tracking.log'
        [IO.File]::WriteAllLines($file,@(
            '#Fields: date-time,event-id,message-id,internal-message-id,log-id,sender-address,recipient-address'
            '2026-10-14T17:46:40.000Z,RECEIVE,<production@invalid>,1,p1,sender@invalid,r@invalid'
            '2026-10-14T17:46:41.000Z,AGENTINFO,<production@invalid>,1,p2,sender@invalid,r@invalid'
            '2026-10-14T17:46:42.000Z,NOTIFYMAPI,<production@invalid>,1,p3,sender@invalid,r@invalid'
        ))
        try{
            [IO.File]::AppendAllText($file,'2026-10-14T17:46:43.000Z,DELIVER,<production@invalid>,1,p4,sender@invalid,r@invalid')
            $run=Collect-Tracking $s $folder
            $s.Scalar('SELECT COUNT(*) FROM message_rollup_dirty;',$null) | Should -Be 0
            $s.Scalar('SELECT events_count FROM message_rollup;',$null) | Should -Be 3
            $s.Scalar('SELECT offset FROM source_file;',$null) | Should -BeLessThan (Get-Item -LiteralPath $file).Length
            [IO.File]::AppendAllText($file,"`r`n")
            [void](Collect-Tracking $s $folder)
            $s.Scalar('SELECT events_count FROM message_rollup;',$null) | Should -Be 4
            $s.Query('SELECT v.text FROM message_rollup r JOIN message_rollup_value v ON v.id=r.status;',$null).Rows[0][0] | Should -BeExactly 'Delivered'
            $s.Scalar('SELECT offset FROM source_file;',$null) | Should -Be (Get-Item -LiteralPath $file).Length
            $run.Statistics | Should -Match 'message rollups'
            $run.Statistics | Should -Match 'message rollups \d+[.,]\d s \([1-9]\d* keys\)'
        }finally{$s.Dispose()}
    }

    It 'rolls back source offsets, evidence and the dirty queue if production rollup reconciliation fails' {
        $s=New-ServeStore 'production-rollback'
        $folder=Join-Path $script:Work 'tracking-fail'; [void][IO.Directory]::CreateDirectory($folder)
        [IO.File]::WriteAllLines((Join-Path $folder 'tracking.log'),@(
            '#Fields: date-time,event-id,message-id,internal-message-id,log-id,sender-address,recipient-address'
            '2026-10-14T17:46:40.000Z,DELIVER,<rollback@invalid>,1,p1,sender@invalid,r@invalid'
        ))
        try{
            $s.Exec("CREATE TRIGGER reject_rollup BEFORE INSERT ON message_rollup BEGIN SELECT RAISE(ABORT,'synthetic rollup failure'); END;")
            $run=Collect-Tracking $s $folder $false $false   # triggers kept on: this failure is injected by a trigger
            $run.Error | Should -Not -BeNullOrEmpty
            $s.Scalar('SELECT COUNT(*) FROM message_event;',$null) | Should -Be 0
            $s.Scalar('SELECT COUNT(*) FROM source_file;',$null) | Should -Be 0
            $s.Scalar('SELECT COUNT(*) FROM message_rollup_dirty;',$null) | Should -Be 0
            $s.Exec('DROP TRIGGER reject_rollup;')
            [void](Collect-Tracking $s $folder)
            $s.Scalar('SELECT COUNT(*) FROM message_rollup;',$null) | Should -Be 1
        }finally{$s.Dispose()}
    }

    It 'rolls back source offsets, evidence, dictionary and the dirty queue if reconciliation fails while the apply connection runs without triggers' {
        $s=New-ServeStore 'production-rollback-notriggers'
        $folder=Join-Path $script:Work 'tracking-fail-notriggers'; [void][IO.Directory]::CreateDirectory($folder)
        [IO.File]::WriteAllLines((Join-Path $folder 'tracking.log'),@(
            '#Fields: date-time,event-id,message-id,internal-message-id,log-id,sender-address,recipient-address'
            '2026-10-14T17:46:40.000Z,DELIVER,<rollback@invalid>,1,p1,sender@invalid,r@invalid'
        ))
        try{
            # No trigger can inject this failure here: the stable-ID sequence is exhausted, so the first rollup INSERT fails (SQLITE_FULL).
            $s.Exec("INSERT INTO sqlite_sequence(name,seq) VALUES('message_rollup',9223372036854775807);")
            $run=Collect-Tracking $s $folder $false
            $run.Error | Should -Not -BeNullOrEmpty
            $s.Scalar('SELECT COUNT(*) FROM message_event;',$null) | Should -Be 0
            $s.Scalar('SELECT COUNT(*) FROM source_file;',$null) | Should -Be 0
            $s.Scalar('SELECT COUNT(*) FROM source_fields;',$null) | Should -Be 0
            $s.Scalar('SELECT COUNT(*) FROM message_rollup_dirty;',$null) | Should -Be 0
            # The failed run gave the connection its triggers back: a raw insert on it still queues its identity.
            $s.Exec("INSERT INTO message_event(time_ms,server,event_id,message_id,log_id) VALUES(1,'EX1','RECEIVE','<queued@invalid>','q');")
            $s.Scalar("SELECT COUNT(*) FROM message_rollup_dirty WHERE identity='<queued@invalid>';",$null) | Should -Be 1
            $s.Exec("DELETE FROM message_rollup_dirty; DELETE FROM message_event; UPDATE sqlite_sequence SET seq=0 WHERE name='message_rollup';")
            [void](Collect-Tracking $s $folder)
            $s.Scalar('SELECT COUNT(*) FROM message_rollup;',$null) | Should -Be 1
            $s.Scalar('SELECT COUNT(*) FROM source_fields;',$null) | Should -Be 1
            $s.Query("SELECT d.text FROM source_file f JOIN source_fields d ON d.id=f.fields_id;",$null).Rows[0][0] | Should -BeExactly '#Fields: date-time,event-id,message-id,internal-message-id,log-id,sender-address,recipient-address'
            $s.Scalar('SELECT COUNT(*) FROM source_file WHERE fields IS NOT NULL;',$null) | Should -Be 0
        }finally{$s.Dispose()}
    }

    It 'migrates schema <Version> losslessly and reopens idempotently' -ForEach @(@{Version=6},@{Version=7},@{Version=8},@{Version=9},@{Version=10}) {
        $s = New-ServeStore "migration$Version"
        Add-Mail $s
        Downgrade $s $Version
        $rawBaseline=[ServeFixtures]::RawBaseline($s)
        $tables = @('source_file','smtp_auth_fragment','session_step','client_session')
        # source_file is read through its logical columns: schema 10 adds fields_id and moves the header text to source_fields (message_rollup: schema 11 stores codes, compared decoded).
        $select = @{ source_file = 'SELECT s.id,s.server,s.kind,s.path,s.offset,s.size,s.last_write_ms,COALESCE(d.text,s.fields),s.first_ms,s.last_ms,s.lines,s.kept,s.noise,s.updated_ms,s.file_key FROM source_file s LEFT JOIN source_fields d ON d.id=s.fields_id ORDER BY 1;' }
        $selectOld = @{ source_file = 'SELECT id,server,kind,path,offset,size,last_write_ms,fields,first_ms,last_ms,lines,kept,noise,updated_ms,file_key FROM source_file ORDER BY 1;' }
        # client_session is read through the columns of the earlier schema: the fold adds auth_modes (NULL on every row it keeps).
        $sessionColumns = $s.Query("SELECT group_concat(name, ',') FROM pragma_table_info('client_session');", $null).Rows[0][0]
        $sessionColumns | Should -Not -Match 'auth_modes'
        $select.client_session = "SELECT $sessionColumns FROM client_session ORDER BY 1;"
        $baseline = @{}
        foreach ($name in $tables) { $baseline[$name] = $s.Query($(if ($selectOld[$name]) { $selectOld[$name] } else { "SELECT * FROM $name ORDER BY 1;" }), $null).Rows | ConvertTo-Json -Depth 30 -Compress }
        $msg = $s.Query('SELECT id,time_ms,server,event_id,message_id,log_id,sender,recipients,subject FROM message_event ORDER BY id;', $null).Rows | ConvertTo-Json -Depth 30 -Compress
        $smtp = $s.Query('SELECT id,time_ms,server,direction,session_id,message_id,status,transcript,auth_user,auth_source FROM smtp_transaction ORDER BY id;', $null).Rows | ConvertTo-Json -Depth 30 -Compress
        $path = $s.FilePath; $s.Dispose()
        $s = [ExchangeLogReport.Store]::new($path,$false,'synthetic')
        try {
            $s.Scalar("SELECT CAST(value AS INTEGER) FROM metadata WHERE key='schema_version';",$null) | Should -Be 13
            $s.Scalar("SELECT COUNT(*) FROM sqlite_master WHERE name='ix_smtp_latest';",$null) | Should -Be 0
            $s.Scalar("SELECT COUNT(*) FROM sqlite_master WHERE name IN('ix_msg_hash','ix_smtp_hash','ix_session_latest');",$null) | Should -Be 0
            [ServeFixtures]::RawBaseline($s) | Should -BeExactly $rawBaseline
            $s.Scalar("SELECT COUNT(*) FROM client_session WHERE auth_modes IS NOT NULL;", $null) | Should -Be 0
            $s.Scalar("SELECT COUNT(*) FROM pragma_table_info('access_client') WHERE name='auth_type' AND pk=7;", $null) | Should -Be 1
            foreach ($name in $tables) { ($s.Query($(if ($select[$name]) { $select[$name] } else { "SELECT * FROM $name ORDER BY 1;" }), $null).Rows | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $baseline[$name] }
            ($s.Query('SELECT id,time_ms,server,event_id,message_id,log_id,sender,recipients,subject FROM message_event ORDER BY id;',$null).Rows | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $msg
            ($s.Query('SELECT id,time_ms,server,direction,session_id,message_id,status,transcript,auth_user,auth_source FROM smtp_transaction ORDER BY id;',$null).Rows | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $smtp
            $rows = [ServeFixtures]::DecodedRollup($s)
            $s.VerifyServeRollups().Verified | Should -BeTrue
        } finally { $s.Dispose() }
        $s = [ExchangeLogReport.Store]::new($path,$false,'synthetic')
        try { ([ServeFixtures]::DecodedRollup($s)) | Should -BeExactly $rows }
        finally { $s.Dispose() }
    }

    It 'rolls back a failed schema-13 publication of a schema-7 database atomically' {
        $s = New-ServeStore 'rollback'; Add-Mail $s; Downgrade $s 7
        $s.Exec("CREATE TRIGGER fail_schema13 BEFORE UPDATE ON metadata WHEN NEW.key='schema_version' AND NEW.value='13' BEGIN SELECT RAISE(ABORT,'synthetic migration failure'); END;")
        $path = $s.FilePath; $s.Dispose()
        { [ExchangeLogReport.Store]::new($path,$false,'synthetic') } | Should -Throw '*synthetic migration failure*'
        $db = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$path;Mode=ReadOnly;Pooling=False"); $db.Open()
        try {
            $c = $db.CreateCommand()
            $c.CommandText = "SELECT value FROM metadata WHERE key='schema_version';"; $c.ExecuteScalar() | Should -BeExactly '7'
            $c.CommandText = "SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'message_rollup%' OR name LIKE 'smtp_client%' OR name IN('ix_smtp_client','ix_smtp_unknown_peer','ux_smtp_client');"; $c.ExecuteScalar() | Should -Be 0
            $c.CommandText = "SELECT COUNT(*) FROM pragma_table_info('smtp_transaction') WHERE name='client_id';"; $c.ExecuteScalar() | Should -Be 0
        } finally { $db.Dispose() }
    }

    It 'keeps exact binary identities under a forced nonunique hash collision' {
        $s = New-ServeStore 'collision'
        try {
            [ServeFixtures]::ForceHashCollision($s)
            Add-Mail $s
            $s.Scalar("SELECT COUNT(*) FROM message_rollup WHERE kind=0 AND msg_hash=17;",$null) | Should -Be 5
            $h = Start-ServeTest $s.FilePath
            $rows = (Request $h "/api/messages?$script:Period").Content | ConvertFrom-Json
            $case = @($rows.rows | Where-Object { $_.cells[15] -ceq '<Case@invalid>' })
            $case.Count | Should -Be 1
            $case[0].cells[3] | Should -BeExactly 'Partially failed'
            $detail = (Request $h "/api/messages/$($case[0].id)?$script:Period").Content | ConvertFrom-Json
            $detail.cells[15] | Should -BeExactly '<Case@invalid>'
            @($detail.cells[16] | Where-Object { $_[3] -eq 'DELIVER' }).Count | Should -Be 1
        } finally { $s.Dispose() }
    }

    It 'publishes late SMTP, changed IDs, deletes and retention only with the surrounding transaction' {
        $s = New-ServeStore 'changes'; Add-Mail $s
        try {
            $id = $s.Scalar("SELECT id FROM message_rollup WHERE identity='<Case@invalid>';",$null)
            $s.Exec("INSERT INTO smtp_transaction(time_ms,server,direction,session_id,message_id,status) VALUES(1792000005000,'EX1','Send','late','<Case@invalid>','Accepted');")
            $s.Scalar('SELECT COUNT(*) FROM message_rollup_dirty;',$null) | Should -BeGreaterThan 0
            Reconcile $s
            $s.Scalar("SELECT smtp_count FROM message_rollup WHERE id=$id;",$null) | Should -Be 2
            $tx = $s.Begin()
            try {
                $c = [ServeFixtures]::Connection($s).CreateCommand(); $c.Transaction = $tx
                $c.CommandText = "DELETE FROM message_event WHERE message_id='<Case@invalid>';"; [void]$c.ExecuteNonQuery()
                $s.ReconcileMessageRollups($tx)
            } finally { $tx.Dispose() }
            $s.Scalar("SELECT events_count FROM message_rollup WHERE id=$id;",$null) | Should -Be 4
            $s.Exec("UPDATE message_event SET message_id='<new@invalid>' WHERE message_id='<case@invalid>';")
            Reconcile $s
            $s.Scalar("SELECT COUNT(*) FROM message_rollup WHERE identity='<case@invalid>';",$null) | Should -Be 0
            $s.Scalar("SELECT COUNT(*) FROM message_rollup WHERE identity='<new@invalid>';",$null) | Should -Be 1
            [void]$s.Purge($script:Epoch+86400000,'2026-10-17',$script:Epoch+86400000)
            $s.Scalar('SELECT COUNT(*) FROM message_rollup;',$null) | Should -Be 0
            $s.Scalar('SELECT COUNT(*) FROM message_rollup_dirty;',$null) | Should -Be 0
        } finally { $s.Dispose() }
    }

    It 'keeps refused and incomplete missing-Message-ID SMTP transactions as separate stable identities' {
        $s=New-ServeStore 'missing-id'; Add-Mail $s
        try {
            $s.Exec("INSERT INTO smtp_transaction(id,time_ms,server,direction,session_id,status) VALUES(41,1792000002000,'EX1','Receive','incomplete',NULL),(42,1792000003000,'EX1','Receive','accepted-no-id','Accepted');")
            Reconcile $s
            $s.Scalar("SELECT COUNT(*) FROM message_rollup WHERE kind=1;",$null) | Should -Be 2
            $h=Start-ServeTest $s.FilePath
            $id=$s.Scalar("SELECT id FROM message_rollup WHERE kind=1 AND identity='41';",$null)
            $r=Request $h "/api/messages/$($id)?$script:Period"
            $d=$r.Content | ConvertFrom-Json
            $d.cells[3] | Should -BeExactly 'Not completed (SMTP)'
            $d.cells[18].Count | Should -Be 0
            $d.cells[19].Count | Should -Be 1
            $r.Content | Should -Not -Match 'smtp-case|smtp-refused|accepted-no-id'
            $s.Exec('UPDATE smtp_transaction SET time_ms=time_ms+1 WHERE id=41;')
            Reconcile $s
            $s.Scalar("SELECT id FROM message_rollup WHERE kind=1 AND identity='41';",$null) | Should -Be $id
        } finally {$s.Dispose()}
    }
}

Describe 'Serve actual HttpListener endpoints' {
    It 'starts on the real loopback listener and reports the exact supported schema' {
        $r = Request $script:Http '/api/meta'
        $r.StatusCode | Should -Be 200
        $m = $r.Content | ConvertFrom-Json
        $m.schemaVersion | Should -Be 13
        $m.supportedSchemaVersion | Should -Be 13
        $m.version | Should -BeExactly '3.0.0'
        $m.readOnly | Should -BeTrue
        $m.mode | Should -BeExactly 'Serve'
        $r.Headers['Cache-Control'] | Should -Contain 'no-store'
        $r.Headers.ContainsKey('Access-Control-Allow-Origin') | Should -BeFalse
        (Get-Acl $script:Http.Options.ReadyFile).AreAccessRulesProtected | Should -BeTrue
    }

    It 'requires the token and rejects cross-origin, hostile authorities and traversal' {
        (Request $script:Http '/api/meta' @{'X-Portal-Token'='bad'}).StatusCode | Should -Be 401
        (Request $script:Http '/api/meta' @{Origin='https://invalid.example'}).StatusCode | Should -Be 403
        (Request $script:Http '/api/meta' @{'Sec-Fetch-Site'='same-site'}).StatusCode | Should -Be 403
        (Request $script:Http '/api/meta' @{Origin=$script:Http.Url;'Sec-Fetch-Site'='same-origin'}).StatusCode | Should -Be 200
        [ServeFixtures]::RawGet($script:Http.Port,'/api/meta',"localhost:$($script:Http.Port)",$script:Http.Token) | Should -Match 'HTTP/1.1 (400|403)'
        [ServeFixtures]::RawGet($script:Http.Port,'/%2e%2e/config/secret.psd1',"127.0.0.1:$($script:Http.Port)",$script:Http.Token) | Should -Match 'HTTP/1.1 (400|403)'
        [ServeFixtures]::RawGet($script:Http.Port,'/%252e%252e/secret',"127.0.0.1:$($script:Http.Port)",$script:Http.Token) | Should -Match 'HTTP/1.1 400'
    }

    It 'serves the report page built from the template at / and its script at /report.js, nothing else, with every inline script hashed' {
        $page = Request $script:Http '/'
        $page.StatusCode | Should -Be 200
        $page.Headers['Content-Type'][0] | Should -Match '^text/html'
        $page.Content | Should -Match ([regex]::Escape('<script id="report-meta" type="application/json">{"served":true}</script>'))
        $page.Content | Should -Match ([regex]::Escape('<script src="report.js"></script>'))
        $page.Content | Should -Not -Match '%%[A-Z]+%%'
        $template = [IO.File]::ReadAllText((Join-Path $script:Root 'templates\Report.template.html'))
        $page.Content | Should -Match ([regex]::Escape(($template -split '<style>')[1].Substring(0, 400)))
        # script-src: 'self' and the hash of each inline script the browser runs (the theme and the data-file queue), none else.
        $policy = $page.Headers['Content-Security-Policy'][0]
        $inline = @([regex]::Matches($page.Content, '<script>([\s\S]*?)</script>') | ForEach-Object {
            "'sha256-" + [Convert]::ToBase64String([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($_.Groups[1].Value.Replace("`r`n", "`n")))) + "'" })
        $inline.Count | Should -Be 2
        $policy | Should -Match ("script-src 'self' " + [regex]::Escape($inline -join ' ') + ';')
        $policy | Should -Match "connect-src 'self'"
        $script = Request $script:Http '/report.js'
        $script.StatusCode | Should -Be 200
        $script.Headers['Content-Type'][0] | Should -Match '^text/javascript'
        $script.Content | Should -BeExactly ([IO.File]::ReadAllText((Join-Path $script:Root 'templates\Report.template.js')))
        (Request $script:Http '/' @{} 'HEAD').StatusCode | Should -Be 200
        foreach ($path in '/index.html', '/messages', '/sessions/1', '/main.js', '/Report.template.js', '/Report.template.html', '/unrecognized', '/report.js/x') {
            (Request $script:Http $path).StatusCode | Should -Be 404 -Because $path
        }
        (Request $script:Http '/api/not-found').StatusCode | Should -Be 404
        (Request $script:Http '/' @{} 'POST').StatusCode | Should -Be 405
    }

    It 'takes no parameter on the static paths but the theme of the page, never a token' {
        (Request $script:Http '/?scoutTheme=dark').StatusCode | Should -Be 200
        (Request $script:Http '/?scoutTheme=light').StatusCode | Should -Be 200
        foreach ($path in '/?scoutTheme=blue', '/?scoutTheme=dark&scoutTheme=light', '/?token=secret', "/?$script:Period", '/?tab=sessions', '/report.js?v=1', '/?x') {
            (Request $script:Http $path).StatusCode | Should -Be 400 -Because $path
        }
    }

    It 'refuses a web root without the report template, a compiled single-page portal included' {
        $empty = Join-Path $script:Work 'empty-web'; [void][IO.Directory]::CreateDirectory($empty)
        $spa = Join-Path $script:Work 'spa-web'; [void][IO.Directory]::CreateDirectory($spa)
        [IO.File]::WriteAllText((Join-Path $spa 'index.html'), '<!doctype html><script src="main.js"></script><p>Synthetic compiled portal</p>')
        [IO.File]::WriteAllText((Join-Path $spa 'main.js'), 'console.log("synthetic");')
        foreach ($root in $empty, $spa) {
            $o = [ExchangeLogReport.ServeOptions]::new(); $o.DatabasePath = $script:HttpStore.FilePath; $o.WebRoot = $root; $o.Port = 0; $o.NoBrowser = $true
            { [ExchangeLogReport.ServeHost]::Run($o) } | Should -Throw '*folder of the report template*' -Because $root
        }
    }

    It 'returns hourly UTC bins per server with exact binary message counts and explicit retained-access caveats' {
        $s=New-ServeStore 'hourly'
        [ServeFixtures]::ForceHashCollision($s)
        $hour=$script:Epoch-($script:Epoch%3600000)
        try {
            Write-Sql $s @"
INSERT INTO message_event(time_ms,server,event_id,message_id,log_id,sender,recipients) VALUES
(@h+1000,'EX1','RECEIVE','<Case@invalid>','h1','alpha@invalid','r@invalid'),
(@h+2000,'EX1','DELIVER','<Case@invalid>','h2','alpha@invalid','r@invalid'),
(@h+3000,'ex1','RECEIVE','<case@invalid>','h3','beta@invalid','r@invalid'),
(@h+3600500,'EX2','DELIVER','<Case@invalid>','h4','beta@invalid','r@invalid');
INSERT INTO smtp_transaction(time_ms,server,direction,session_id,message_id,status,mail_from,rcpts) VALUES
(@h+4000,'EX1','Receive','h1','<Case@invalid>','Accepted','alpha@invalid','r@invalid'),
(@h+5000,'EX1','Receive','h2',NULL,'Rejected','alpha@invalid','r@invalid'),
(@h+6000,'EX2','Receive','h3',NULL,'Deferred','beta@invalid','r@invalid'),
(@h+3600100,'EX2','Receive','h4','<incomplete@invalid>',NULL,'alpha@invalid','r@invalid');
INSERT INTO access_event(time_ms,server,source,user,outcome,request_id) VALUES
(@h+8000,'EX1','Synthetic','alpha@invalid','Failed','h1'),(@h+9000,'EX1','Synthetic','beta@invalid','OK','h2');
"@ @{h=$hour}
            Reconcile $s
            $h=Start-ServeTest $s.FilePath
            $period='from='+[Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($hour).ToString('O'))+
                '&to='+[Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($hour+7200000).ToString('O'))
            $p=(Request $h "/api/overview?$period").Content|ConvertFrom-Json
            $p.columns[0].kind | Should -BeExactly 'time'
            $p.rows.Count | Should -Be 3
            $bin=@($p.rows|Where-Object {$_.cells[1] -ieq 'EX1'})[0]
            ([DateTimeOffset]$bin.cells[0]).ToUnixTimeMilliseconds() | Should -Be $hour
            ($bin.cells[2..9] -join ',') | Should -BeExactly '3,2,2,1,1,0,0,2'
            $p.basis | Should -Match 'Daily access_usage cannot establish hourly'
            $scope=(Request $h "/api/overview?$period&server=ex1&user=alpha").Content|ConvertFrom-Json
            $scope.rows.Count | Should -Be 1
            ($scope.rows[0].cells[2..9] -join ',') | Should -BeExactly '2,1,2,1,1,0,0,1'
            $counts=(Request $h "/api/overview/counts?$period").Content|ConvertFrom-Json
            $counts.columns[0].name | Should -BeExactly 'Source'
        } finally {$s.Dispose()}
    }

    It 'preserves partial exclusive UTC hours and ordering across the Unix epoch at <Hour>' -ForEach @(
        @{Hour=1791997200000L},@{Hour=-3600000L},@{Hour=0L}
    ) {
        $s=New-ServeStore ('partial-hour-'+$Hour)
        try {
            Write-Sql $s @"
INSERT INTO message_event(time_ms,server,event_id,message_id,log_id,sender,recipients) VALUES
(@h-1,'EX1','RECEIVE','<outside@invalid>','p0','alpha@invalid','r@invalid'),
(@h+1000,'EX1','RECEIVE','<Case@invalid>','p1','alpha@invalid','r@invalid'),
(@h+2000,'EX1','DELIVER','<Case@invalid>','p2','alpha@invalid','r@invalid'),
(@h+3599999,'ex1','SEND','<case@invalid>','p3','alpha@invalid','r@invalid'),
(@h+3600000,'EX1','DELIVER','<Case@invalid>','p4','alpha@invalid','r@invalid'),
(@h+3602000,'EX1','DELIVER','<excluded@invalid>','p5','alpha@invalid','r@invalid');
INSERT INTO smtp_transaction(time_ms,server,direction,session_id,status,mail_from,rcpts) VALUES
(@h+1500,'EX1','Receive','p1','Accepted','alpha@invalid','r@invalid'),
(@h+3599999,'ex1','Receive','p2','Rejected','alpha@invalid','r@invalid'),
(@h+3600000,'EX1','Receive','p3',NULL,'alpha@invalid','r@invalid'),
(@h+3602000,'EX1','Receive','p4','Deferred','alpha@invalid','r@invalid');
INSERT INTO access_event(time_ms,server,source,user,mailbox,outcome,request_id) VALUES
(@h+1500,'EX1','Synthetic','other@invalid','alpha@invalid','OK','p1'),
(@h+3599999,'ex1','Synthetic','alpha@invalid',NULL,'Failed','p2'),
(@h+3600000,'EX1','Synthetic','alpha@invalid',NULL,'OK','p3'),
(@h+3601000,'EX2','Synthetic','alpha@invalid',NULL,'OK','p4'),
(@h+3602000,'EX1','Synthetic','alpha@invalid',NULL,'OK','p5');
"@ @{h=$Hour}
            Reconcile $s
            $h=Start-ServeTest $s.FilePath
            $period='from='+[Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($Hour+1500).ToString('O'))+
                '&to='+[Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($Hour+3602000).ToString('O'))
            $p=(Request $h "/api/overview?$period").Content|ConvertFrom-Json
            $p.rows.Count | Should -Be 3
            ($p.rows.id -join ',') | Should -BeExactly '1,2,3'
            ([DateTimeOffset]$p.rows[0].cells[0]).ToUnixTimeMilliseconds() | Should -Be ($Hour+3600000)
            $p.rows[0].cells[1] | Should -BeExactly 'EX1'
            ($p.rows[0].cells[2..9] -join ',') | Should -BeExactly '1,1,1,0,0,0,1,1'
            $p.rows[1].cells[1] | Should -BeExactly 'EX2'
            ($p.rows[1].cells[2..9] -join ',') | Should -BeExactly '0,0,0,0,0,0,0,1'
            ([DateTimeOffset]$p.rows[2].cells[0]).ToUnixTimeMilliseconds() | Should -Be $Hour
            ($p.rows[2].cells[2..9] -join ',') | Should -BeExactly '2,2,2,1,1,0,0,2'
            $scoped=(Request $h "/api/overview?$period&server=ex1&user=alpha").Content|ConvertFrom-Json
            $scoped.rows.Count | Should -Be 2
            ($scoped.rows[0].cells[2..9] -join ',') | Should -BeExactly '1,1,1,0,0,0,1,1'
            ($scoped.rows[1].cells[2..9] -join ',') | Should -BeExactly '2,2,2,1,1,0,0,2'
            $empty=(Request $h "/api/overview?$period&server=absent").Content|ConvertFrom-Json
            $empty.rows.Count | Should -Be 0
            $wide='from='+[Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($Hour-32L*86400000).ToString('O'))+
                '&to='+[Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($Hour+3602000).ToString('O'))
            $sparse=(Request $h "/api/overview?$wide&server=EX2").Content|ConvertFrom-Json
            $sparse.rows.Count | Should -Be 1
            ($sparse.rows[0].cells[2..9] -join ',') | Should -BeExactly '0,0,0,0,0,0,0,1'
        } finally {$s.Dispose()}
    }

    It 'rejects more than 10000 bins without partial success for a <Days>-day selection' -ForEach @(
        @{Days=1},@{Days=32}
    ) {
        $s=New-ServeStore "overview-limit-$Days"
        try {
            Write-Sql $s @"
WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<10001)
INSERT INTO access_event(time_ms,server,source,user,outcome,request_id)
SELECT @t,printf('EX%05d',i),'Synthetic','alpha@invalid','OK',printf('limit-%d',i) FROM n;
"@ @{t=$script:Epoch}
            $h=Start-ServeTest $s.FilePath
            $period='from='+[Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($script:Epoch).ToString('O'))+
                '&to='+[Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($script:Epoch+$Days*86400000L).ToString('O'))
            $response=Request $h "/api/overview?$period"
            $response.StatusCode | Should -Be 422
            $response.Content | Should -Match 'OverviewTooLarge'
            $selected=(Request $h "/api/overview?$period&server=EX00001").Content|ConvertFrom-Json
            $selected.rows.Count | Should -Be 1
            $selected.rows[0].cells[9] | Should -Be 1
        } finally {$s.Dispose()}
    }

    It 'groups SMTP peers across ephemeral ports without merging accounts, servers, roles, connectors or unknown endpoints' {
        $s=New-ServeStore 'clients';Add-ClientRows $s
        try {
            $h=Start-ServeTest $s.FilePath
            $response=Request $h "/api/smtp/clients?$script:Period"
            $p=$response.Content|ConvertFrom-Json
            $client=@($p.rows|Where-Object {$_.id -eq 1})[0]
            $client.cells[6] | Should -BeExactly '198.51.100.10'
            $client.cells[8] | Should -BeExactly 'proved@invalid'
            ($client.cells[9..13] -join ',') | Should -BeExactly '3,1,1,1,0'
            $client.cells[19] | Should -Contain 'Direct server log'
            @($p.rows|Where-Object {$_.id -in 12,13,14,15,16}).Count | Should -Be 5
            @($p.rows|Where-Object {$_.id -in 17,18}).Count | Should -Be 2
            $v6=@($p.rows|Where-Object {$_.cells[6] -eq '2001:db8::1'})[0]
            $v6.cells[9] | Should -Be 2
            $v6.cells[19] | Should -Contain 'Front end proxy'
            $retired=@($p.rows|Where-Object {$_.id -eq 21})[0]
            $retired.cells[8] | Should -BeExactly 'Not available'
            $retired.cells[19] | Should -Contain 'Missing'
            $response.Content | Should -Not -Match 'SYNTHETICCHALLENGE|SYNTHETICPAYLOAD|RETIRED-IDENTITY|forged-from'
            @($p.columns|Where-Object kind -EQ 'steps').Count | Should -Be 0
            $small=(Request $h "/api/smtp/clients?$script:Period&size=2").Content|ConvertFrom-Json
            $small.rows.Count | Should -Be 2
            $small.hasMore | Should -BeTrue
            $small.total | Should -BeNullOrEmpty
        } finally {$s.Dispose()}
    }

    It 'drills from a scoped SMTP client to paginated transactions and redacts only selected transaction detail' {
        $s=New-ServeStore 'client-details';Add-ClientRows $s
        try {
            $h=Start-ServeTest $s.FilePath
            $detail=(Request $h "/api/smtp/clients/1?$script:Period&server=EX1&user=proved").Content|ConvertFrom-Json
            $detail.title | Should -BeExactly 'SMTP client'
            $detail.cells[9] | Should -Be 3
            $detail.cells[-1] | Should -Match '^/api/smtp/clients/1/transactions\?'
            $page=(Request $h "/api/smtp/clients/1/transactions?$script:Period&server=EX1&user=proved&size=1").Content|ConvertFrom-Json
            $page.rows[0].id | Should -Be 11
            $page.hasMore | Should -BeTrue
            $next=(Request $h "/api/smtp/clients/1/transactions?$script:Period&server=EX1&user=proved&size=1&page=2").Content|ConvertFrom-Json
            $next.rows[0].id | Should -Be 10
            $rejected=(Request $h "/api/smtp/clients?$script:Period&server=EX1&user=proved&status=Rejected").Content|ConvertFrom-Json
            $rejected.rows.Count | Should -Be 1
            $rejected.rows[0].id | Should -Be 10
            $rejected.rows[0].cells[9] | Should -Be 1
            $scoped=(Request $h "/api/smtp/clients/10?$script:Period&server=EX1&user=proved&status=Rejected").Content|ConvertFrom-Json
            $scoped.cells[9] | Should -Be 1
            $scoped.cells[-1] | Should -Match 'status=Rejected'
            $single=Request $h "/api/smtp/transactions/10?$script:Period"
            $single.Content | Should -Match 'SMTP conversation|AUTH.*redacted'
            $single.Content | Should -Not -Match 'SYNTHETICCHALLENGE|SYNTHETICPAYLOAD'
            (Request $h "/api/smtp/clients/1?$script:Period&server=EX2").StatusCode | Should -Be 404
            (Request $h "/api/smtp/clients/1/transactions?$script:Period&user=other").StatusCode | Should -Be 404
            $unknown=(Request $h "/api/smtp/clients/17/transactions?$script:Period").Content|ConvertFrom-Json
            $unknown.rows.Count | Should -Be 1
            $unknown.rows[0].id | Should -Be 17
            $all=(Request $h "/api/smtp/transactions?$script:Period").Content|ConvertFrom-Json
            $all.rows.Count | Should -Be 15
            $csv=(Request $h "/api/export.csv?view=smtp&$script:Period").Content
            $csv | Should -Match 'Remote IP'
            $csv | Should -Not -Match 'SYNTHETICPAYLOAD'
            $txcsv=(Request $h "/api/export.csv?view=smtp-transactions&$script:Period").Content
            $txcsv | Should -Match 'Mail from'
        } finally {$s.Dispose()}
    }

    It 'rolls back a failed schema10 publication of a schema-8 database atomically (indexes, triggers and version)' {
        $s = New-ServeStore 'rollback9'; Add-Mail $s; Downgrade $s 8
        $s.Exec("CREATE TRIGGER fail_schema10 BEFORE UPDATE ON metadata WHEN NEW.key='schema_version' AND NEW.value='10' BEGIN SELECT RAISE(ABORT,'synthetic migration failure'); END;")
        $path = $s.FilePath; $s.Dispose()
        { [ExchangeLogReport.Store]::new($path,$false,'synthetic') } | Should -Throw '*synthetic migration failure*'
        $db = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$path;Mode=ReadOnly;Pooling=False"); $db.Open()
        try {
            $c = $db.CreateCommand()
            $c.CommandText = "SELECT value FROM metadata WHERE key='schema_version';"; $c.ExecuteScalar() | Should -BeExactly '8'
            $c.CommandText = "SELECT COUNT(*) FROM sqlite_master WHERE name IN('ix_msg_hash','ix_smtp_hash','ix_session_latest');"; $c.ExecuteScalar() | Should -Be 3
            $c.CommandText = "SELECT sql FROM sqlite_master WHERE name='ix_smtp_latest';"; $c.ExecuteScalar() | Should -BeExactly 'CREATE INDEX ix_smtp_latest ON smtp_transaction(time_ms DESC,id DESC)'
            $c.CommandText = "SELECT COUNT(*) FROM sqlite_master WHERE name='tr_smtp_transaction_rollup_update' AND sql LIKE '%auth_user%';"; $c.ExecuteScalar() | Should -Be 1
        } finally { $db.Dispose() }
    }

    It 'reads grouped SMTP clients from the hourly buckets and touches source rows only at the partial ends, and preserves exclusive bounds' {
        $s=New-ServeStore 'client-scan';Add-ClientRows $s
        try {
            $from=$script:Epoch-1000000L; $to=$script:Epoch+86400000L
            $full=[ExchangeLogReport.ServeDiagnostics]::ExplainSmtpClients($s.FilePath,$from,$to,$null,$null)|ConvertFrom-Json
            $empty=[ExchangeLogReport.ServeDiagnostics]::ExplainSmtpClients($s.FilePath,$from,$to,'','')|ConvertFrom-Json
            ($full -join "`n") | Should -BeExactly ($empty -join "`n")
            # A page is discovered hour by hour from the end in the covering bucket index, then only its candidates are aggregated through their primary keys.
            ($full -join "`n") | Should -Match '\[discover hour\] SEARCH h USING COVERING INDEX ix_smtp_client_hour \(hour_ms=\?\)'
            ($full -join "`n") | Should -Match '\[discover unknown\] SEARCH e USING INDEX ix_smtp_unknown_peer'
            ($full -join "`n") | Should -Match '\[aggregate hours\] SEARCH h USING PRIMARY KEY \(client_id=\? AND hour_ms>\? AND hour_ms<\?\)'
            ($full -join "`n") | Should -Match '\[aggregate edges\] (MULTI-INDEX OR \| INDEX 1 \| )?SEARCH e USING INDEX ix_smtp_client \(client_id=\? AND time_ms>\? AND time_ms<\?\)'
            ($full -join "`n") | Should -Not -Match 'ix_smtp_latest'
            ($full -join "`n") | Should -Not -Match 'SCAN e'
            $partial=[ExchangeLogReport.ServeDiagnostics]::ExplainSmtpClients($s.FilePath,$from,$script:Epoch+2000,$null,$null)|ConvertFrom-Json
            ($partial -join "`n") | Should -Match 'SEARCH e USING INDEX'
            $scoped=[ExchangeLogReport.ServeDiagnostics]::ExplainSmtpClients($s.FilePath,$from,$to,'EX1',$null)|ConvertFrom-Json
            ($scoped -join "`n") | Should -Match '\[discover hour\] SEARCH h USING COVERING INDEX ix_smtp_client_hour \(hour_ms=\?\) \| SEARCH c USING INTEGER PRIMARY KEY \(rowid=\?\)'
            # A user filter cannot use the buckets (substring LIKE): matching rows newest first, then the older rows of the candidates through ix_smtp_client.
            $user=[ExchangeLogReport.ServeDiagnostics]::ExplainSmtpClients($s.FilePath,$from,$to,$null,'proved')|ConvertFrom-Json
            ($user -join "`n") | Should -Match '\[newest\] SEARCH e USING INDEX ix_smtp_flow'
            # ix_smtp_flow has (server,direction,status) between time_ms and the rowid: only the id inside one millisecond is sorted (streaming, no full sort).
            ($user -join "`n") | Should -Not -Match '\[newest\][^\[]*USE TEMP B-TREE FOR ORDER BY'
            ($user -join "`n") | Should -Match '\[complete\] SEARCH e USING INDEX ix_smtp_client \(client_id=\? AND time_ms>\? AND time_ms<\?\)'
            $overview=[ExchangeLogReport.ServeDiagnostics]::ExplainOverview($s.FilePath,$from,$to,$null,$null)|ConvertFrom-Json
            ($overview -join "`n") | Should -Match 'COVERING INDEX ix_msg_flow'
            ($overview -join "`n") | Should -Match 'COVERING INDEX ix_smtp_flow'
            $h=Start-ServeTest $s.FilePath
            $period='from='+[Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($from).ToString('O'))+
                '&to='+[Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($to).ToString('O'))
            $all=(Request $h "/api/smtp/clients?$period").Content|ConvertFrom-Json
            ($all.rows | ForEach-Object {$_.cells[9]} | Measure-Object -Sum).Sum | Should -Be 15
            $end=[Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($script:Epoch+2000).ToString('O'))
            $partialPeriod=$period -replace '&to=.*$',"&to=$end"
            $selected=(Request $h "/api/smtp/clients?$partialPeriod").Content|ConvertFrom-Json
            ($selected.rows | ForEach-Object {$_.cells[9]} | Measure-Object -Sum).Sum | Should -Be 3
            @($selected.rows|Where-Object id -EQ 1)[0].cells[9] | Should -Be 1
        } finally {$s.Dispose()}
    }

    It 'interrupts expensive aggregate <View> queries instead of retrying or returning partial data' -ForEach @(@{View='clients'},@{View='operations'}) {
        $s=New-ServeStore "aggregate-$View"
        if($View -eq 'clients'){Add-ClientRows $s}else{Add-Mail $s}
        try {
            # Schema 11 reads the client list from smtp_client_hour / smtp_client_value / smtp_transaction: the value dictionary is read first, whatever the period.
            # The operations read access_action. Neither table is an object of the shape Serve requires: a view can take its place.
            $table=if($View -eq 'clients'){'smtp_client_value'}else{'access_action'}
            if($View -eq 'operations'){
                $day = [DateTimeOffset]::FromUnixTimeMilliseconds($script:Epoch).UtcDateTime.ToString('yyyy-MM-dd')
                $s.Exec("INSERT INTO access_action(day,server,protocol,action,requests,failures,slow,total_ms,max_ms) VALUES('$day','EX1','Mapi','Execute',1,0,0,1,1);")
            }
            $s.Exec("ALTER TABLE $table RENAME TO ${table}_base; CREATE VIEW $table AS SELECT e.* FROM ${table}_base e CROSS JOIN (WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<100000000) SELECT SUM(i) FROM n);")
            $h=Start-ServeTest $s.FilePath 1
            $path=if($View -eq 'clients'){"/api/smtp/clients?$script:Period"}else{"/api/operations?$script:Period"}
            $clock=[Diagnostics.Stopwatch]::StartNew()
            (Request $h $path).StatusCode | Should -Be 504
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 5
            (Request $h '/api/meta').StatusCode | Should -Be 200
        } finally {$s.Dispose()}
    }

    It 'rejects unknown/repeated parameters, oversized pages and offsetless timestamps' {
        # A list without page is a keyset list (size up to 2,000); page selects the offset list (size up to 500).
        foreach ($q in 'page=1&size=501','size=2001','page=0','page=500&size=100','unknown=x','size=1&size=2','from=2026-10-14T00:00:00','page=1&cursor=1.1') {
            (Request $script:Http "/api/messages?$q").StatusCode | Should -Be 400
        }
    }

    It 'returns bounded summary rows only and selects real membership for long journeys and SMTP-only dates' {
        $r = Request $script:Http "/api/messages?$script:Period&size=2"
        $p = $r.Content | ConvertFrom-Json
        $p.rows.Count | Should -Be 2
        $p.hasMore | Should -BeTrue
        $p.total | Should -BeNullOrEmpty
        @($p.columns | Where-Object kind -EQ 'steps').Count | Should -Be 0
        $r.Content | Should -Not -Match 'redacted|req-1|find-request'
        $all = (Request $script:Http "/api/messages?$script:Period").Content | ConvertFrom-Json
        @($all.rows | Where-Object { $_.cells[15] -ceq '<long@invalid>' }).Count | Should -Be 1
        @($all.rows | Where-Object { $_.cells[15] -ceq '<outside@invalid>' }).Count | Should -Be 1
        @($all.rows | Where-Object { $_.cells[16] -eq 'smtp' }).Count | Should -Be 1
        ([datetimeoffset]$all.rows[0].cells[0]).ToUnixTimeMilliseconds() | Should -BeGreaterThan 0
    }

    It 'uses literal escaped user substring and same-row server/user membership, including detail authorization' {
        $p = (Request $script:Http "/api/messages?$script:Period&server=ex1&user=beta").Content | ConvertFrom-Json
        @($p.rows | Where-Object { $_.cells[15] -ceq '<scope@invalid>' }).Count | Should -Be 0
        $id = $script:HttpStore.Scalar("SELECT id FROM message_rollup WHERE identity='<scope@invalid>';",$null)
        (Request $script:Http "/api/messages/$($id)?$script:Period&server=EX1&user=beta").StatusCode | Should -Be 404
        ((Request $script:Http "/api/messages?$script:Period&user=%25").Content | ConvertFrom-Json).rows.Count | Should -Be 0
    }

    It 'loads the exact selected route, redacted packed SMTP transcript and authentication facts only on detail' {
        $id = $script:HttpStore.Scalar("SELECT id FROM message_rollup WHERE identity='<Case@invalid>';",$null)
        $r = Request $script:Http "/api/messages/$($id)?$script:Period"
        $d = $r.Content | ConvertFrom-Json
        $d.cells[3] | Should -BeExactly 'Partially failed'
        $d.cells[16].Count | Should -Be 5
        # The Serve route has the same step shape as the report: submission number and UTC milliseconds after the detail.
        @($d.cells[16] | Where-Object { $_.Count -ne 7 -or $_[5] -lt 1 -or $_[6] -le 0 }).Count | Should -Be 0
        $d.cells[18].Count | Should -Be 4
        $d.cells[19].Count | Should -Be 1
        $r.Content | Should -Match 'internal_id|auth_evidence_id'
        $r.Content | Should -Match 'proved@invalid|AUTH.*redacted'
        $r.Content | Should -Not -Match 'smtp-refused|smtp-outside'
        $smtp = (Request $script:Http "/api/smtp/clients?$script:Period").Content | ConvertFrom-Json
        @($smtp.columns | Where-Object name -EQ 'Transcript').Count | Should -Be 0
    }

    It 'returns a full selected client timeline with request IDs, raw log references and UTC milliseconds' {
        $d = (Request $script:Http "/api/sessions/1?$script:Period").Content | ConvertFrom-Json
        $d.cells[25] | Should -BeExactly 'Negotiate'
        $d.cells[26].Count | Should -Be 1
        $d.cells[26][0][10] | Should -BeExactly 'req-1'
        $d.cells[26][0][11][0][3] | Should -BeExactly 'synthetic.log'
        ([DateTimeOffset]$d.cells[26][0][0]).ToUnixTimeMilliseconds() | Should -Be ($script:Epoch+123)
        $d.cells[27] | Should -BeExactly ('Bind=1;' * 60)
        $d.cells[28] | Should -BeExactly ('Bind=1;' * 60)
        ((Request $script:Http "/api/sessions?$script:Period").Content | ConvertFrom-Json).rows.Count | Should -Be 1
    }

    It 're-redacts legacy packed SMTP AUTH challenges and payloads on both selected detail routes' {
        $s=New-ServeStore 'legacy-secrets'; Add-Mail $s
        try {
            $raw="12:00:00.000 C: AUTH LOGIN`n12:00:00.001 S: 334 SYNTHETICCHALLENGE`n12:00:00.002 C: SYNTHETICPAYLOAD`n12:00:00.003 S: 235 2.7.0 Authentication successful"
            Write-Sql $s 'UPDATE smtp_transaction SET transcript=@v WHERE id=1;' @{v=[ExchangeLogReport.Packed]::Pack($raw)}
            $h=Start-ServeTest $s.FilePath
            $id=$s.Scalar("SELECT id FROM message_rollup WHERE identity='<Case@invalid>';",$null)
            foreach($route in "/api/messages/$($id)?$script:Period","/api/smtp/1?$script:Period"){
                $r=Request $h $route
                $r.StatusCode | Should -Be 200
                $r.Content | Should -Not -Match 'SYNTHETICCHALLENGE|SYNTHETICPAYLOAD'
            }
            $s.Query('SELECT transcript FROM smtp_transaction WHERE id=1;',$null).Rows[0][0] | Should -BeExactly $raw
        } finally {$s.Dispose()}
    }

    It 'exports every matching row, not a page, as BOM semicolon CSV with formula neutralization' {
        $r = Request $script:Http "/api/export.csv?view=messages&$script:Period"
        $r.StatusCode | Should -Be 200
        $r.Content | Should -Match "'=SUM"
        ($r.RawContentStream.ToArray()[0..2] -join ',') | Should -BeExactly '239,187,191'
        @($r.Content -split "`r?`n" | Where-Object Length -GT 0).Count | Should -Be 7
        $r.Headers.ContainsKey('X-Export-Completion') | Should -BeTrue
        (Request $script:Http "/api/export.csv?view=messages&$script:Period&size=1").StatusCode | Should -Be 400
    }

    It 'lists, counts, exports and opens the messages of the static report only: no SMTP transaction with a Message-ID and no tracking event' {
        $s = New-ServeStore 'tracked-or-refused'; Add-Mail $s
        try {
            # One received and accepted, one sent transaction with a Message-ID that no tracking event names (a server whose tracking logs are not collected).
            Write-Sql $s @"
INSERT INTO smtp_transaction(time_ms,end_ms,server,direction,session_id,message_id,status,mail_from,rcpts) VALUES
(@t+1100,@t+1150,'EX1','Receive','smtp-accepted-only','<accepted-only@invalid>','Accepted','gamma@invalid','one@invalid'),
(@t+1200,@t+1250,'EX2','Send','smtp-sent-only','<sent-only@invalid>','Sent','alpha@invalid','far@invalid');
"@ @{ t = $script:Epoch }
            Reconcile $s
            # The rollup keeps both identities, with the wording of their SMTP status, and verifies.
            $statuses = @{}
            foreach ($r in $s.Query("SELECT r.id,r.identity,v.text FROM message_rollup r JOIN message_rollup_value v ON v.id=r.status WHERE r.identity IN('<accepted-only@invalid>','<sent-only@invalid>');", $null).Rows) { $statuses[[string]$r[1]] = @([long]$r[0], [string]$r[2]) }
            $statuses['<accepted-only@invalid>'][1] | Should -BeExactly 'Accepted (SMTP)'
            $statuses['<sent-only@invalid>'][1] | Should -BeExactly 'Sent (SMTP)'
            $s.VerifyServeRollups().Verified | Should -BeTrue
            $h = Start-ServeTest $s.FilePath
            $list = (Request $h "/api/messages?$script:Period&size=500").Content | ConvertFrom-Json
            $identities = @($list.rows | ForEach-Object { $_.cells[15] })
            $identities | Should -Not -Contain '<accepted-only@invalid>'
            $identities | Should -Not -Contain '<sent-only@invalid>'
            @($list.rows | Where-Object { $_.cells[16] -eq 'smtp' }).Count | Should -Be 1 -Because 'the refused mail without Message-ID stays'
            @($list.rows | Where-Object { $_.cells[3] -match '^(Accepted|Sent|Not completed) \(SMTP\)$' }).Count | Should -Be 0
            foreach ($q in 'status=Accepted%20(SMTP)', 'status=Sent%20(SMTP)', 'server=EX2', 'user=alpha') {
                $scoped = (Request $h "/api/messages?$script:Period&$q").Content | ConvertFrom-Json
                @($scoped.rows | Where-Object { $_.cells[15] -in '<accepted-only@invalid>', '<sent-only@invalid>' }).Count | Should -Be 0 -Because $q
            }
            # The counts the page sizes the tab with are the rows of the list.
            $counts = (Request $h "/api/overview/counts?$script:Period").Content | ConvertFrom-Json
            $messages = @($counts.rows | Where-Object { $_.cells[0] -eq 'Messages' })
            ($messages | ForEach-Object { [long]$_.cells[2] } | Measure-Object -Sum).Sum | Should -Be $list.rows.Count
            @($messages | Where-Object { $_.cells[1] -match '^(Accepted|Sent) \(SMTP\)$' }).Count | Should -Be 0
            $export = Request $h "/api/export.csv?view=messages&$script:Period"
            $export.StatusCode | Should -Be 200
            $export.Content | Should -Not -Match 'accepted-only|sent-only'
            @($export.Content -split "`r?`n" | Where-Object Length -GT 0).Count | Should -Be ($list.rows.Count + 1)
            foreach ($key in $statuses.Keys) { (Request $h "/api/messages/$($statuses[$key][0])?$script:Period").StatusCode | Should -Be 404 -Because $key }
            # Their transactions stay in the SMTP lists.
            $smtp = (Request $h "/api/smtp/transactions?$script:Period&size=500").Content | ConvertFrom-Json
            @($smtp.rows | Where-Object { $_.cells[10] -in '<accepted-only@invalid>', '<sent-only@invalid>' }).Count | Should -Be 2
            # The static Detailed report of the same store and period has as many messages.
            $q = [ExchangeLogReport.ReportRequest]::new()
            $q.StartMs = [DateTimeOffset]::Parse('2026-10-14T00:00:00Z', [Globalization.CultureInfo]::InvariantCulture).ToUnixTimeMilliseconds()
            $q.EndMs = [DateTimeOffset]::Parse('2026-10-16T00:00:00Z', [Globalization.CultureInfo]::InvariantCulture).ToUnixTimeMilliseconds()
            $q.Detailed = $true; $q.WriteHtml = $false; $q.WriteCsv = $true; $q.Zone = [TimeZoneInfo]::Utc; $q.TimeZoneName = 'UTC'
            $q.ConfiguredServers = [string[]]@('EX1', 'EX2'); $q.MemoryBudgetMB = 64; $q.Parallelism = 1
            $q.OutputFolder = Join-Path $script:Work 'tracked-or-refused-report'
            $report = [ExchangeLogReport.ReportBuilder]::Build($s, $q)
            $csv = @(Import-Csv -LiteralPath ($report.Files | Where-Object Dataset -EQ 'messages').Path -Delimiter ';')
            $csv.Count | Should -Be $report.Counts['messages']
            # Same rows but one: <outside@invalid> is in the period through its SMTP transaction only (its tracking events are three days earlier).
            # Serve lists a journey with any member in the period; the static report starts from the tracking events of the period.
            $served = @($list.rows | Where-Object { $_.cells[15] -cne '<outside@invalid>' } | ForEach-Object { [string]$_.cells[15] } | Sort-Object -CaseSensitive)
            $static = @($csv | ForEach-Object { [string]$_.'Message ID' } | Sort-Object -CaseSensitive)
            ($served -join '|') | Should -BeExactly ($static -join '|')
            $report.Counts['messages'] | Should -Be ($list.rows.Count - 1)
        } finally { $s.Dispose() }
    }

    It 'does not migrate an older schema, write reports, or change source database bytes' {
        $s = New-ServeStore 'old'; Add-Mail $s; Downgrade $s 7
        $path = $s.FilePath; $s.Dispose()
        $before = (Get-FileHash -LiteralPath $path).Hash
        $files = @(Get-ChildItem -LiteralPath $script:Work -Recurse -File | Select-Object -ExpandProperty FullName)
        $h = Start-ServeTest $path
        ((Request $h '/api/meta').Content | ConvertFrom-Json).requiresMigration | Should -BeTrue
        (Request $h "/api/messages?$script:Period").StatusCode | Should -Be 422
        (Get-FileHash -LiteralPath $path).Hash | Should -BeExactly $before
        @(Get-ChildItem -LiteralPath $script:Work -Recurse -File | Where-Object { $_.FullName -notin $files -and $_.Extension -in '.html','.csv','.log' }).Count | Should -Be 0
        $missing = Start-ServeTest (Join-Path $script:Work 'missing.sqlite')
        ((Request $missing '/api/meta').Content | ConvertFrom-Json).schemaVersion | Should -Be 0
        (Request $missing "/api/sessions?$script:Period").StatusCode | Should -Be 422
        Test-Path -LiteralPath $missing.Options.DatabasePath | Should -BeFalse
    }

    It 'fails explicitly rather than serving stale data from a committed dirty queue' {
        $s = New-ServeStore 'dirty'; Add-Mail $s
        try {
            $s.Exec("UPDATE message_event SET event_id='FAIL' WHERE id=2;")
            $h = Start-ServeTest $s.FilePath
            $r = Request $h "/api/messages?$script:Period"
            $r.StatusCode | Should -Be 503
            $r.Content | Should -Match 'RollupPending'
            Reconcile $s
            (Request $h "/api/messages?$script:Period").StatusCode | Should -Be 200
        } finally { $s.Dispose() }
    }

    It 'preserves scoped membership, order and paging when rare filters exceed the bounded latest-row probe' {
        $s=New-ServeStore 'selectivity'; Add-Mail $s
        try {
            [ServeFixtures]::Populate($s,$script:Epoch+10000,600)
            Write-Sql $s "INSERT INTO message_event(time_ms,server,event_id,message_id,log_id,sender,recipients) VALUES(@t,'EX1','DELIVER','<literal@invalid>','literal',@sender,'r@invalid');" @{
                t=$script:Epoch+500; sender='under_%\literal@invalid'
            }
            Reconcile $s
            $h=Start-ServeTest $s.FilePath
            $rare=(Request $h "/api/messages?$script:Period&user=alpha%40invalid&server=ex1").Content | ConvertFrom-Json
            $rare.rows.Count | Should -Be 4
            $rare.hasMore | Should -BeFalse
            @($rare.rows | Where-Object {$_.cells[15] -ceq '<long@invalid>'}).Count | Should -Be 0
            $beta=(Request $h "/api/messages?$script:Period&user=beta%40invalid&server=EX1").Content | ConvertFrom-Json
            $beta.rows.Count | Should -Be 1
            $beta.rows[0].cells[15] | Should -BeExactly '<case@invalid>'
            $literal=[Uri]::EscapeDataString('under_%\literal')
            $escaped=(Request $h "/api/messages?$script:Period&user=$literal").Content | ConvertFrom-Json
            $escaped.rows.Count | Should -Be 1
            $escaped.rows[0].cells[15] | Should -BeExactly '<literal@invalid>'
            $fullFrom=$script:Epoch-7*86400000L; $fullTo=$script:Epoch+86400000L
            $fullPeriod='from='+[Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($fullFrom).ToString('O'))+
                '&to='+[Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($fullTo).ToString('O'))
            $whole=(Request $h "/api/messages?$fullPeriod&user=$literal").Content|ConvertFrom-Json
            $whole.rows.Count | Should -Be 1
            $whole.rows[0].cells[15] | Should -BeExactly '<literal@invalid>'
            $wholePlan=[ExchangeLogReport.ServeDiagnostics]::ExplainMessageList($s.FilePath,$fullFrom,$fullTo,$null,'under_%\literal',$null)|ConvertFrom-Json
            $wholePlan -join "`n" | Should -Match 'SCAN e'
            $one=(Request $h "/api/messages?$script:Period&user=%40&page=1&size=100").Content | ConvertFrom-Json
            $two=(Request $h "/api/messages?$script:Period&user=%40&page=2&size=100").Content | ConvertFrom-Json
            $one.hasMore | Should -BeTrue; $two.hasMore | Should -BeTrue
            @($one.rows.id | Where-Object {$_ -in $two.rows.id}).Count | Should -Be 0
            $tail=(Request $h "/api/messages?$script:Period&user=%40&page=2&size=500").Content | ConvertFrom-Json
            $tail.rows.Count | Should -Be 107
            $tail.hasMore | Should -BeFalse
            $csv=(Request $h "/api/export.csv?view=messages&$script:Period&user=beta%40invalid&server=EX1").Content
            $export=@(($csv -replace '^\uFEFF','') | ConvertFrom-Csv -Delimiter ';')
            $export.Count | Should -Be 1
            $export[0].'Message ID' | Should -BeExactly '<case@invalid>'
            $plan=[ExchangeLogReport.ServeDiagnostics]::ExplainMessageList($s.FilePath,$script:Epoch-86400000,$script:Epoch+86400000,'EX1','beta@invalid',$null) | ConvertFrom-Json
            $plan -join "`n" | Should -Match 'Bounded latest-candidate probe: 256'
            $plan -join "`n" | Should -Match 'LIST SUBQUERY'
        } finally {$s.Dispose()}
    }

    It 'does not merge binary identities in the noncorrelated membership set even when every hash collides' {
        $s=New-ServeStore 'set-collision'
        try {
            [ServeFixtures]::ForceHashCollision($s)
            Add-Mail $s; [ServeFixtures]::Populate($s,$script:Epoch+10000,600)
            $h=Start-ServeTest $s.FilePath
            $page=(Request $h "/api/messages?$script:Period&user=beta%40invalid&server=ex1").Content | ConvertFrom-Json
            $page.rows.Count | Should -Be 1
            $page.rows[0].cells[15] | Should -BeExactly '<case@invalid>'
            $page.rows[0].cells[3] | Should -BeExactly 'Delivered'
        } finally {$s.Dispose()}
    }

    It 'interrupts SQLite on the real request deadline and keeps subsequent requests responsive (scoped=<Scoped>)' -ForEach @(@{Scoped=$false},@{Scoped=$true}) {
        $s = New-ServeStore "deadline$Scoped"; Add-Mail $s
        try {
            Add-SlowRequests $s
            $h = Start-ServeTest $s.FilePath 1
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $selection="/api/requests?$script:Period" + $(if($Scoped){'&user=s%40invalid'}else{''})
            $r = Request $h $selection
            $r.StatusCode | Should -Be 504
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 5
            # Retryable: the pages read before the deadline are cached, one retry is cheaper.
            [string]$r.Headers['Retry-After'] | Should -BeExactly '2'
            $body = $r.Content | ConvertFrom-Json
            $body.error.code | Should -BeExactly 'Deadline'
            $body.error.retryable | Should -BeTrue
            $body.error.retryAfterSeconds | Should -Be 2
            $body.error.message | Should -BeLike 'The request exceeded its deadline of 1 s. The pages it read are now cached*'
            (Request $h '/api/meta').StatusCode | Should -Be 200
        } finally { $s.Dispose() }
    }

    It 'owns and reuses exactly <Concurrency> non-pool workers and joins them on cancellation' -ForEach @(@{Concurrency=1},@{Concurrency=4},@{Concurrency=8}) {
        $cancel=[Threading.CancellationTokenSource]::new()
        $h=Start-ServeTest $script:HttpStore.FilePath -Concurrency $Concurrency -Cancellation $cancel.Token
        try {
            $workers=@([ServeHttpTestClient]::Workers($h.Task))
            $workers.Count | Should -Be $Concurrency
            foreach($worker in $workers){
                ($worker.CreationOptions -band [Threading.Tasks.TaskCreationOptions]::LongRunning) | Should -Be ([Threading.Tasks.TaskCreationOptions]::LongRunning)
                $worker.IsCompleted | Should -BeFalse
            }
            foreach($i in 1..8){ (Request $h '/api/meta').StatusCode | Should -Be 200 }
            ([ServeHttpTestClient]::Workers($h.Task).Id -join ',') | Should -BeExactly ($workers.Id -join ',')
            $cancel.Cancel()
            $h.Task.Wait(3000) | Should -BeTrue
            @($workers | Where-Object { -not $_.IsCompleted }).Count | Should -Be 0
            Test-Path -LiteralPath $h.Options.ReadyFile | Should -BeFalse
        } finally {
            $cancel.Cancel()
            [void]$h.Task.Wait(3000)
            $cancel.Dispose()
        }
    }

    It 'bounds active SQLite requests and rejects excess work with an explicit retryable 429 (client startup=<ClientDelay>ms)' -ForEach @(@{ClientDelay=0},@{ClientDelay=500}) {
        $s = New-ServeStore "concurrency$ClientDelay"; Add-Mail $s
        $client=[Net.Http.HttpClient]::new([ServeHttpTestClient]::new($ClientDelay))
        try {
            Add-SlowRequests $s
            $h = Start-ServeTest $s.FilePath 2
            [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('X-Portal-Token',$h.Token)
            $slots=[ServeHttpTestClient]::Admission($h.Task)
            $clock=[Diagnostics.Stopwatch]::StartNew()
            $pending=@(1..4 | ForEach-Object {$client.GetAsync($h.Url+"/api/requests?$script:Period")})
            # A client task can still be queued locally; observe all four actual server admissions.
            while($slots.CurrentCount -ne 0){
                @($pending | Where-Object IsCompleted).Count | Should -Be 0
                $clock.Elapsed.TotalSeconds | Should -BeLessThan $h.Options.RequestTimeoutSeconds
                Start-Sleep -Milliseconds 1
            }
            @($pending | Where-Object IsCompleted).Count | Should -Be 0
            $busyClock=[Diagnostics.Stopwatch]::StartNew()
            $r=Request $h "/api/requests?$script:Period"
            $r.StatusCode | Should -Be 429
            $busyClock.Elapsed.TotalSeconds | Should -BeLessThan $h.Options.RequestTimeoutSeconds
            $r.Headers['Retry-After'][0] | Should -BeExactly '1'
            foreach($task in $pending) { $task.GetAwaiter().GetResult().StatusCode | Should -Be ([Net.HttpStatusCode]::GatewayTimeout) }
            (Request $h '/api/meta').StatusCode | Should -Be 200
        } finally {$client.Dispose();$s.Dispose()}
    }

    It 'cancels and joins all <Concurrency> saturated SQLite workers on external cancellation' -ForEach @(@{Concurrency=4},@{Concurrency=8}) {
        $s=New-ServeStore "cancel-saturated$Concurrency"; Add-Mail $s
        $client=[Net.Http.HttpClient]::new()
        $cancel=[Threading.CancellationTokenSource]::new()
        try {
            Add-SlowRequests $s
            $h=Start-ServeTest $s.FilePath 15 -Concurrency $Concurrency -Cancellation $cancel.Token
            [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('X-Portal-Token',$h.Token)
            $slots=[ServeHttpTestClient]::Admission($h.Task)
            $pending=@(1..$Concurrency | ForEach-Object {$client.GetAsync($h.Url+"/api/requests?$script:Period")})
            $clock=[Diagnostics.Stopwatch]::StartNew()
            while($slots.CurrentCount -ne 0){
                @($pending | Where-Object IsCompleted).Count | Should -Be 0
                $clock.Elapsed.TotalSeconds | Should -BeLessThan 3
                Start-Sleep -Milliseconds 1
            }
            $workers=@([ServeHttpTestClient]::Workers($h.Task))
            $clock.Restart()
            $cancel.Cancel()
            $h.Task.Wait(3000) | Should -BeTrue
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 3
            @($workers | Where-Object { -not $_.IsCompleted }).Count | Should -Be 0
            Test-Path -LiteralPath $h.Options.ReadyFile | Should -BeFalse
        } finally {
            $cancel.Cancel()
            $client.Dispose()
            $cancel.Dispose()
            $s.Dispose()
        }
    }

    It 'cancels an active SQLite request and exits promptly on authenticated shutdown' {
        $s=New-ServeStore 'shutdown-active'; Add-Mail $s
        $client=[Net.Http.HttpClient]::new()
        try {
            Add-SlowRequests $s
            $h=Start-ServeTest $s.FilePath 15
            [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('X-Portal-Token',$h.Token)
            $pending=$client.GetAsync($h.Url+"/api/requests?$script:Period")
            Start-Sleep -Milliseconds 100
            $pending.IsCompleted | Should -BeFalse
            $writerClock=[Diagnostics.Stopwatch]::StartNew()
            $tx=$s.Begin()
            try {
                $write=[ServeFixtures]::Connection($s).CreateCommand(); $write.Transaction=$tx
                $write.CommandText='UPDATE source_file SET offset=offset+1 WHERE id=1;'
                [void]$write.ExecuteNonQuery(); $s.ReconcileMessageRollups($tx); $tx.Commit()
            } finally {$tx.Dispose()}
            $writerClock.Elapsed.TotalMilliseconds | Should -BeLessThan 1000
            $pending.IsCompleted | Should -BeFalse
            $clock=[Diagnostics.Stopwatch]::StartNew()
            (Request $h '/api/shutdown' @{} 'POST').StatusCode | Should -Be 200
            $h.Task.Wait(3000) | Should -BeTrue
            [void]$h.Task.GetAwaiter().GetResult()
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 3
            Test-Path -LiteralPath $h.Options.ReadyFile | Should -BeFalse
            try {[void]$pending.GetAwaiter().GetResult()} catch {}
        } finally {$client.Dispose();$s.Dispose()}
    }

    It 'refuses to overwrite readiness evidence and requires authenticated empty shutdown' {
        (Request $script:Http '/api/shutdown' @{} 'GET').StatusCode | Should -Be 400
        (Request $script:Http '/api/shutdown?token=x' @{} 'POST').StatusCode | Should -Be 400
        $o = [ExchangeLogReport.ServeOptions]::new(); $o.DatabasePath = $script:HttpStore.FilePath
        $o.WebRoot=$script:Web; $o.ReadyFile=$script:Http.Options.ReadyFile; $o.Port=0; $o.NoBrowser=$true
        { [ExchangeLogReport.ServeHost]::RunAsync($o).GetAwaiter().GetResult() } | Should -Throw '*refusing to overwrite*'
    }

    It 'reports a blocked listener bind in a private readiness file without a token or configuration changes' {
        $o=[ExchangeLogReport.ServeOptions]::new()
        $o.DatabasePath=$script:HttpStore.FilePath; $o.WebRoot=$script:Web
        $o.Port=$script:Http.Port; $o.NoBrowser=$true; $o.ReadyFileWithToken=$true
        $o.ReadyFile=Join-Path $script:Work 'blocked-ready.json'
        try {
            { [ExchangeLogReport.ServeHost]::RunAsync($o).GetAwaiter().GetResult() } | Should -Throw '*No URL ACL, firewall or service setting was changed*'
            $signal=Get-Content -LiteralPath $o.ReadyFile -Raw | ConvertFrom-Json
            $signal.status | Should -BeExactly 'blocked'
            $signal.code | Should -BeIn 'HttpListenerBindFailed','HttpListenerAccessDenied'
            $signal.nativeErrorCode | Should -BeGreaterThan 0
            $signal.PSObject.Properties.Name | Should -Not -Contain 'token'
            (Get-Acl -LiteralPath $o.ReadyFile).AreAccessRulesProtected | Should -BeTrue
            (Request $script:Http '/api/meta').StatusCode | Should -Be 200
        } finally { if(Test-Path -LiteralPath $o.ReadyFile){Remove-Item -LiteralPath $o.ReadyFile -Force} }
    }

    It 'enters CLI Serve before configuration, mail, collection, locks and report output setup' {
        $ready=Join-Path $script:Work 'cli-ready.json'
        $out=Join-Path $script:Work 'must-not-exist'
        $start=[Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
        $start.UseShellExecute=$false; $start.CreateNoWindow=$true
        $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
        foreach($arg in @('-NoProfile','-File',(Join-Path $script:Root 'Invoke-ExchangeLogReport.ps1'),'-Mode','Serve',
            '-DatabasePath',$script:HttpStore.FilePath,'-ConfigPath',(Join-Path $script:Work 'missing-config.psd1'),
            '-Port','0','-NoBrowser','-ReadyFile',$ready,'-ReadyFileWithToken','-DevelopmentMode','-Collect','-SendMail','-OutputPath',$out)){
            $start.ArgumentList.Add($arg)
        }
        $process=[Diagnostics.Process]::Start($start)
        try {
            $clock=[Diagnostics.Stopwatch]::StartNew()
            while(-not(Test-Path -LiteralPath $ready)){
                if($process.HasExited){throw ($process.StandardError.ReadToEnd()+$process.StandardOutput.ReadToEnd())}
                if($clock.Elapsed.TotalSeconds -gt 15){throw 'CLI ready timeout.'}
                Start-Sleep -Milliseconds 30
            }
            $signal=Get-Content -LiteralPath $ready -Raw | ConvertFrom-Json
            Invoke-WebRequest -Uri ($signal.url.TrimEnd('/')+'/api/shutdown') -Method Post -Headers @{'X-Portal-Token'=$signal.token} | Out-Null
            $process.WaitForExit(10000) | Should -BeTrue
            $process.ExitCode | Should -Be 0
            Test-Path -LiteralPath $out | Should -BeFalse
            Test-Path -LiteralPath $ready | Should -BeFalse
            $process.StandardOutput.ReadToEnd() | Should -Not -Match $signal.token
        } finally {
            if(-not $process.HasExited){Stop-Process -Id $process.Id -Force}
            $process.Dispose()
        }
    }
}

Describe 'Serve covering indexes and span bounds' {
    BeforeAll {
        # Journeys and sessions that cross the period bounds by hours and days; the expected selections are computed with plain NOT INDEXED SQL.
        $script:Exact = New-ServeStore 'exact'
        Add-Mail $script:Exact
        $values = @(); $sessions = @()
        foreach ($i in 0..59) {
            $start = $script:Epoch - 4 * 86400000 + $i * 7200000 + ($i % 7) * 60000
            $span = @(0, 1800000, 7200000, 108000000, 259200000)[$i % 5]
            $values += "($start,'EX$(1 + $i % 2)','RECEIVE','<x$i@invalid>','x$i-a','s$i@invalid','r@invalid'),($($start + $span),'EX1','DELIVER','<x$i@invalid>','x$i-b','s$i@invalid','r@invalid')"
            $sessions += "('x$i','2026-10-14',$start,$($start + $span),'u$i@invalid','Mapi',$($i + 1),1,0,0,0,0,0,0,1,1,0,0)"
        }
        Write-Sql $script:Exact ("INSERT INTO message_event(time_ms,server,event_id,message_id,log_id,sender,recipients) VALUES " + ($values -join ',') + ";")
        Write-Sql $script:Exact ("INSERT INTO client_session(skey,day,start_ms,end_ms,user,protocol,requests,successes,failures,slow,first_success_ms,last_success_ms,first_failure_ms,last_failure_ms,total_ms,max_ms,bytes_in,bytes_out) VALUES " + ($sessions -join ',') + ";")
        Reconcile $script:Exact
        $script:ExactHost = Start-ServeTest $script:Exact.FilePath 30
        function Expected-Messages([long]$From, [long]$To) {
            @($script:Exact.Query("SELECT r.id FROM message_rollup r NOT INDEXED WHERE (r.kind=0 AND (EXISTS(SELECT 1 FROM message_event e WHERE e.msg_hash=r.msg_hash AND e.message_id=r.identity AND e.time_ms>=@f AND e.time_ms<@t) OR EXISTS(SELECT 1 FROM smtp_transaction e WHERE e.msg_hash=r.msg_hash AND e.message_id=r.identity AND e.time_ms>=@f AND e.time_ms<@t))) OR (r.kind=1 AND EXISTS(SELECT 1 FROM smtp_transaction e NOT INDEXED WHERE e.id=CAST(r.identity AS INTEGER) AND e.time_ms>=@f AND e.time_ms<@t)) ORDER BY r.member_last_ms DESC,r.id DESC;", @{ f = $From; t = $To }).Rows | ForEach-Object { [long]$_[0] })
        }
        function Expected-Sessions([long]$From, [long]$To) {
            @($script:Exact.Query("SELECT c.id FROM client_session c NOT INDEXED WHERE c.start_ms<@t AND c.end_ms>=@f ORDER BY c.start_ms DESC,c.id DESC;", @{ f = $From; t = $To }).Rows | ForEach-Object { [long]$_[0] })
        }
        function Period([long]$From, [long]$To) {
            'from=' + [Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($From).ToString('O')) + '&to=' + [Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($To).ToString('O'))
        }
    }

    AfterAll { if ($script:Exact) { $script:Exact.Dispose(); $script:Exact = $null } }

    It 'stores span bounds that cover the fixture and reads lists through the covering indexes' {
        [long]$script:Exact.Query("SELECT value FROM metadata WHERE key='rollup_max_span_ms';",$null).Rows[0][0] | Should -BeGreaterOrEqual (3 * 86400000)
        [long]$script:Exact.Query("SELECT value FROM metadata WHERE key='session_max_span_ms';",$null).Rows[0][0] | Should -Be (3 * 86400000)
        $plan = [ExchangeLogReport.ServeDiagnostics]::ExplainMessageList($script:Exact.FilePath, $script:Epoch, $script:Epoch + 86400000, $null, $null, $null) | ConvertFrom-Json
        ($plan -join "`n") | Should -Match 'USING (COVERING )?INDEX ix_rollup_last \(member_last_ms>\? AND member_last_ms<\?\)'
        $status = [ExchangeLogReport.ServeDiagnostics]::ExplainMessageList($script:Exact.FilePath, $script:Epoch, $script:Epoch + 86400000, $null, $null, 'Delivered') | ConvertFrom-Json
        ($status -join "`n") | Should -Match 'USING (COVERING )?INDEX ix_rollup_status_last \(status=\? AND member_last_ms>\? AND member_last_ms<\?\)'
        $sessionPlan = @($script:Exact.Query("EXPLAIN QUERY PLAN SELECT COUNT(*),COALESCE(SUM(c.requests),0) FROM client_session c WHERE c.start_ms<1 AND c.start_ms>=0 AND c.end_ms>=0;",$null).Rows | ForEach-Object { $_[3] }) -join "`n"
        $sessionPlan | Should -Match 'COVERING INDEX ix_session_time \(start_ms>\? AND start_ms<\?\)'
    }

    It 'raises both span bounds on the collector path, whose apply connection runs without triggers' {
        $s = New-ServeStore 'span-collector'
        try {
            # Rows inserted by SQL go through the span triggers: a journey of about 2 days, a session of under a second.
            Add-Mail $s
            $sqlRollup = [long]$s.Scalar('SELECT MAX(member_last_ms-member_first_ms) FROM message_rollup NOT INDEXED;',$null)
            $sqlSession = [long]$s.Scalar('SELECT MAX(end_ms-start_ms) FROM client_session NOT INDEXED;',$null)
            # A journey of 4 days, read by the collector.
            $tracking = Join-Path $script:Work 'span-tracking'; [void][IO.Directory]::CreateDirectory($tracking)
            [IO.File]::WriteAllLines((Join-Path $tracking 'tracking.log'), @(
                '#Fields: date-time,event-id,message-id,internal-message-id,log-id,sender-address,recipient-address'
                '2026-10-10T17:46:40.000Z,RECEIVE,<span-collector@invalid>,1,sc1,sender@invalid,r@invalid'
                '2026-10-14T17:46:40.000Z,DELIVER,<span-collector@invalid>,1,sc2,sender@invalid,r@invalid'
            ))
            [void](Collect-Tracking $s $tracking)
            # One Outlook session of 7 hours (a request every 20 minutes), read by the collector.
            $fields = 'DateTime,RequestId,MajorVersion,MinorVersion,BuildVersion,RevisionVersion,ClientRequestId,Protocol,UrlHost,UrlStem,ProtocolAction,AuthenticationType,IsAuthenticated,AuthenticatedUser,Organization,AnchorMailbox,UserAgent,ClientIpAddress,ServerHostName,HttpStatus,BackEndStatus,ErrorCode,Method,ProxyAction,TargetServer,TargetServerVersion,RoutingType,RoutingHint,BackEndCookie,ServerLocatorHost,ServerLocatorLatency,RequestBytes,ResponseBytes,TargetOutstandingRequests,AuthModulePerfContext,HttpPipelineLatency,CalculateTargetBackEndLatency,GlsLatencyBreakup,TotalGlsLatency,AccountForestLatencyBreakup,TotalAccountForestLatency,ResourceForestLatencyBreakup,TotalResourceForestLatency,ADLatency,SharedCacheLatencyBreakup,TotalSharedCacheLatency,ActivityContextLifeTime,ModuleToHandlerSwitchingLatency,ClientReqStreamLatency,BackendReqInitLatency,BackendReqStreamLatency,BackendProcessingLatency,BackendRespInitLatency,BackendRespStreamLatency,ClientRespStreamLatency,KerberosAuthHeaderLatency,HandlerCompletionLatency,RequestHandlerLatency,HandlerToModuleSwitchingLatency,ProxyTime,CoreLatency,RoutingLatency,HttpProxyOverhead,TotalRequestTime,RouteRefresherLatency,UrlQuery,BackEndGenericInfo,GenericInfo,GenericErrors,EdgeTraceId,DatabaseGuid,UserADObjectGuid,PartitionEndpointLookupLatency,RoutingStatus'
            $names = $fields.Split(',')
            $proxy = Join-Path $script:Work 'span-proxy'
            $lines = @('#Software: Microsoft Exchange Server', '#Version: 15.02.2562.045', '#Log-type: HttpProxy Logs', '#Date: 2026-10-14T09:00:00.000Z', "#Fields: $fields", $fields)
            foreach ($k in 0..21) {
                $v = @{ DateTime = [DateTimeOffset]::FromUnixTimeMilliseconds($script:Epoch - 8 * 3600000 + $k * 1200000).UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture)
                    RequestId = [guid]::NewGuid().ToString(); MajorVersion = 15; MinorVersion = 2; Protocol = 'Mapi'; UrlHost = 'mail.contoso.test'; UrlStem = '/mapi/emsmdb/'
                    AuthenticationType = 'Negotiate'; IsAuthenticated = 'True'; AuthenticatedUser = 'CONTOSO\alice'; AnchorMailbox = 'SMTP:alice@contoso.test'
                    UserAgent = 'Microsoft Office/16.0 (Windows NT 10.0; Microsoft Outlook 16.0.17928)'; ClientIpAddress = '10.1.1.10'; ServerHostName = 'EX1'
                    HttpStatus = 200; BackEndStatus = 200; Method = 'POST'; ProxyAction = 'Proxy'; TargetServer = 'ex2.contoso.test'; RoutingType = 'IntraForest'
                    RequestBytes = 1200; ResponseBytes = 5400; TotalRequestTime = 42 }
                $lines += (@(foreach ($n in $names) { $x = [string]$v[$n]; if ($x -match '[,"]') { '"' + $x.Replace('"', '""') + '"' } else { $x } }) -join ',')
            }
            [void][IO.Directory]::CreateDirectory((Join-Path $proxy 'Mapi'))
            [IO.File]::WriteAllText((Join-Path $proxy 'Mapi\HttpProxy_2026101409-1.LOG'), (($lines -join "`r`n") + "`r`n"), [Text.UTF8Encoding]::new($true))
            $run = Collect-Tracking $s $proxy $true $true 'HttpProxy'
            $run.Error | Should -BeNullOrEmpty
            $rollupMax = [long]$s.Scalar('SELECT MAX(member_last_ms-member_first_ms) FROM message_rollup NOT INDEXED;',$null)
            $sessionMax = [long]$s.Scalar('SELECT MAX(end_ms-start_ms) FROM client_session NOT INDEXED;',$null)
            $rollupMax | Should -BeGreaterThan $sqlRollup
            $sessionMax | Should -BeGreaterThan $sqlSession
            $sessionMax | Should -BeGreaterOrEqual (7 * 3600000)
            [long]$s.Scalar("SELECT value FROM metadata WHERE key='rollup_max_span_ms';",$null) | Should -Be $rollupMax
            [long]$s.Scalar("SELECT value FROM metadata WHERE key='session_max_span_ms';",$null) | Should -Be $sessionMax
            $s.VerifyServeRollups().Verified | Should -BeTrue
        } finally { $s.Dispose() }
    }

    It 'lists, counts and opens exactly the journeys and sessions of every period, whichever bound they cross' {
        $periods = @()
        foreach ($k in 0..11) { $from = $script:Epoch - 5 * 86400000 + $k * 13 * 3600000; $periods += ,@($from, ($from + @(3600000, 86400000, 259200000)[$k % 3])) }
        foreach ($p in $periods) {
            $q = Period $p[0] $p[1]
            $messages = (Request $script:ExactHost "/api/messages?$q&size=500").Content | ConvertFrom-Json
            $expectedMessages = @(Expected-Messages $p[0] $p[1])
            @($messages.rows | ForEach-Object { [long]$_.id }) -join ',' | Should -BeExactly ($expectedMessages -join ',') -Because $q
            $sessions = (Request $script:ExactHost "/api/sessions?$q&size=500").Content | ConvertFrom-Json
            $expectedSessions = @(Expected-Sessions $p[0] $p[1])
            @($sessions.rows | ForEach-Object { [long]$_.id }) -join ',' | Should -BeExactly ($expectedSessions -join ',') -Because $q
            $counts = (Request $script:ExactHost "/api/overview/counts?$q").Content | ConvertFrom-Json
            $messageTotal = (@($counts.rows | Where-Object { $_.cells[0] -eq 'Messages' } | ForEach-Object { [long]$_.cells[2] }) | Measure-Object -Sum).Sum
            [long]$messageTotal | Should -Be $expectedMessages.Count -Because $q
            [long](@($counts.rows | Where-Object { $_.cells[1] -eq 'Retained sessions' })[0].cells[2]) | Should -Be $expectedSessions.Count -Because $q
            foreach ($id in ($expectedMessages | Select-Object -First 3)) { (Request $script:ExactHost "/api/messages/${id}?$q").StatusCode | Should -Be 200 }
            foreach ($id in ($expectedSessions | Select-Object -First 3)) { (Request $script:ExactHost "/api/sessions/${id}?$q").StatusCode | Should -Be 200 }
        }
    }

    It 'refuses a schema-12 database written before the covering indexes with MigrationRequired and serves it after one writable open' {
        $s = New-ServeStore 'prerelease'; Add-Mail $s
        $path = $s.FilePath
        [ServeFixtures]::ConvertToPreReleaseSchema12($s)
        $s.Dispose()
        $h = Start-ServeTest $path
        $r = Request $h "/api/messages?$script:Period"
        $r.StatusCode | Should -Be 422
        $body = $r.Content | ConvertFrom-Json
        $body.error.code | Should -BeExactly 'MigrationRequired'
        $body.error.message | Should -Match 'Schema 13 is required'
        (Request $h '/api/meta').StatusCode | Should -Be 200
        $s = [ExchangeLogReport.Store]::new($path, $false, 'synthetic'); $s.Dispose()
        (Request $h "/api/messages?$script:Period").StatusCode | Should -Be 200
    }

    It 'refuses a schema-12 database without the authentication columns with MigrationRequired and serves it after one open, writable or read-only' {
        $s = New-ServeStore 'step3-auth'; Add-Mail $s
        $day = [DateTimeOffset]::FromUnixTimeMilliseconds($script:Epoch).UtcDateTime.ToString('yyyy-MM-dd')
        $s.Exec("INSERT INTO access_client(day,user,protocol,client_ip,user_agent,device_id,device_type,software,requests,failures,first_ms,last_ms,servers) VALUES('$day','alpha@invalid','Mapi','10.0.0.1','Outlook','',NULL,NULL,7,1,$($script:Epoch),$($script:Epoch + 1000),'EX1'),('$day','beta@invalid','Eas','10.0.0.2','iPhone','DEV','iPhone',NULL,3,0,$($script:Epoch),$($script:Epoch + 2000),'EX1');")
        [ServeFixtures]::ConvertToStep3Schema12($s)
        $path = $s.FilePath
        $s.Dispose()
        $other = Join-Path (Split-Path $path) 'step3-auth-readonly.sqlite'
        Copy-Item -LiteralPath $path -Destination $other
        $h = Start-ServeTest $path
        foreach ($api in '/api/sessions', '/api/users', '/api/authentication') {
            $r = Request $h "${api}?$script:Period"
            $r.StatusCode | Should -Be 422 -Because $api
            $body = $r.Content | ConvertFrom-Json
            $body.error.code | Should -BeExactly 'MigrationRequired' -Because $api
            $body.error.message | Should -Match 'Schema 13 is required'
        }
        $s = [ExchangeLogReport.Store]::new($path, $false, 'synthetic')
        try {
            @($s.Query("SELECT name FROM pragma_table_info('access_client') WHERE pk>0 ORDER BY pk;", $null).Rows | ForEach-Object { $_[0] }) -join ',' | Should -BeExactly 'day,user,protocol,client_ip,user_agent,device_id,auth_type'
            $s.Query("SELECT COUNT(*),SUM(requests),SUM(CASE WHEN auth_type='' THEN 1 ELSE 0 END) FROM access_client;", $null).Rows[0] -join ',' | Should -BeExactly '2,10,2'
            $s.Scalar("SELECT COUNT(*) FROM pragma_table_info('client_session') WHERE name='auth_modes';", $null) | Should -Be 1
            $s.Scalar("SELECT COUNT(*) FROM client_session WHERE auth_modes IS NOT NULL;", $null) | Should -Be 0
        } finally { $s.Dispose() }
        foreach ($api in '/api/sessions', '/api/users', '/api/authentication') { (Request $h "${api}?$script:Period").StatusCode | Should -Be 200 -Because $api }
        ((Request $h "/api/authentication?$script:Period").Content | ConvertFrom-Json).rows[0].cells[1] | Should -BeExactly 'Unknown'
        # A read-only open of the other copy folds it too (a report or -Mode Status on a test-build database).
        $s = [ExchangeLogReport.Store]::new($other, $true, 'synthetic')
        try {
            $s.Scalar("SELECT COUNT(*) FROM pragma_table_info('access_client') WHERE name='auth_type' AND pk=7;", $null) | Should -Be 1
            $s.Scalar("SELECT COUNT(*) FROM pragma_table_info('client_session') WHERE name='auth_modes';", $null) | Should -Be 1
        } finally { $s.Dispose() }
    }
}

Describe 'Serve deadlines per endpoint and day-by-day lists' {
    It 'gives the period aggregates their own deadline: an aggregate slower than the list deadline answers, a list as slow does not' {
        $s = New-ServeStore 'split-deadline'; Add-Mail $s
        try {
            # A recursive sum slow enough to exceed one second, calibrated on this computer.
            $n = 1000000
            do {
                $n *= 2
                $clock = [Diagnostics.Stopwatch]::StartNew()
                [void]$s.Scalar("WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<$n) SELECT SUM(i) FROM n;", $null)
            } while ($clock.Elapsed.TotalSeconds -lt 1.5 -and $n -lt 512000000)
            # The operations read access_action (a slow view here); the list of the requests reads the IIS status rows (a slow view in a second store).
            # Neither table is an object of the shape Serve requires.
            $list = New-ServeStore 'split-deadline-list'; Add-Mail $list; Add-SlowRequests $list
            $day = [DateTimeOffset]::FromUnixTimeMilliseconds($script:Epoch).UtcDateTime.ToString('yyyy-MM-dd')
            $s.Exec("INSERT INTO access_action(day,server,protocol,action,requests,failures,slow,total_ms,max_ms) VALUES('$day','EX1','Mapi','Execute',1,0,0,1,1); ALTER TABLE access_action RENAME TO access_action_base; CREATE VIEW access_action AS SELECT b.* FROM access_action_base b CROSS JOIN (WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<$n) SELECT SUM(i) FROM n);")
            $h = Start-ServeTest $s.FilePath 1 -Aggregate 60
            $hl = Start-ServeTest $list.FilePath 1 -Aggregate 60
            # The hour of the synthetic rows: the slow view is evaluated only when the period has a row.
            $start = $script:Epoch - ($script:Epoch % 3600000)
            $hour = 'from=' + [Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($start).ToString('O')) + '&to=' + [Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($start + 3600000).ToString('O'))
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $overview = Request $h "/api/operations?$hour"
            $overview.StatusCode | Should -Be 200 -Because $overview.Content
            $clock.Elapsed.TotalSeconds | Should -BeGreaterThan 1
            $list.Dispose()
            $list = Request $hl "/api/requests?$hour"
            $list.StatusCode | Should -Be 504
            ($list.Content | ConvertFrom-Json).error.message | Should -BeLike '*deadline of 1 s*'
        } finally { $s.Dispose() }
    }

    It 'lists every row of a period once, in the same order, when it is read one day at a time (<View>)' -ForEach @(@{View='messages'},@{View='sessions'},@{View='smtp/transactions'}) {
        $s = New-ServeStore ('slices-' + ($View -replace '/','-')); Add-Mail $s
        try {
            $values = @(); $sessions = @(); $smtp = @()
            foreach ($i in 0..47) {
                $start = $script:Epoch - 2 * 86400000 + $i * 3600000 + ($i % 5) * 61000
                $span = @(0, 1800000, 7200000, 108000000)[$i % 4]
                $values += "($start,'EX1','RECEIVE','<y$i@invalid>','y$i-a','s@invalid','r@invalid'),($($start + $span),'EX2','DELIVER','<y$i@invalid>','y$i-b','s@invalid','r@invalid')"
                $sessions += "('y$i','2026-10-14',$start,$($start + $span),'u@invalid','Mapi',1,1,0,0,0,0,0,0,1,1,0,0)"
                $smtp += "($start,'EX1','Receive','y$i','<y$i@invalid>','Accepted','s@invalid','r@invalid')"
            }
            Write-Sql $s ("INSERT INTO message_event(time_ms,server,event_id,message_id,log_id,sender,recipients) VALUES " + ($values -join ',') + ";")
            Write-Sql $s ("INSERT INTO client_session(skey,day,start_ms,end_ms,user,protocol,requests,successes,failures,slow,first_success_ms,last_success_ms,first_failure_ms,last_failure_ms,total_ms,max_ms,bytes_in,bytes_out) VALUES " + ($sessions -join ',') + ";")
            Write-Sql $s ("INSERT INTO smtp_transaction(time_ms,server,direction,session_id,message_id,status,mail_from,rcpts) VALUES " + ($smtp -join ',') + ";")
            Reconcile $s
            $h = Start-ServeTest $s.FilePath 30
            $iso = { param([long]$ms) [Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($ms).ToString('O')) }
            $from = $script:Epoch - 36 * 3600000; $to = $script:Epoch + 12 * 3600000
            $period = "from=$(& $iso $from)&to=$(& $iso $to)"
            function Get-All([string]$Query) {
                $ids = @(); $page = 1
                do {
                    $r = Request $h "/api/${View}?$Query&size=7&page=$page"
                    $r.StatusCode | Should -Be 200 -Because $r.Content
                    $body = $r.Content | ConvertFrom-Json
                    $ids += @($body.rows | ForEach-Object { [long]$_.id }); $page++
                } while ($body.hasMore)
                return ,$ids
            }
            $whole = Get-All $period
            $whole.Count | Should -BeGreaterThan 10
            # Days of 7 h, 24 h and 17 h, newest first: no upper bound on the newest, no lower bound on the oldest.
            $bounds = @($to, ($to - 7 * 3600000), ($to - 31 * 3600000), $from)
            $sliced = @()
            for ($k = 0; $k -lt 3; $k++) {
                $window = $(if ($k -lt 2) { "&orderFrom=$(& $iso $bounds[$k + 1])" } else { '' }) + $(if ($k -gt 0) { "&orderTo=$(& $iso $bounds[$k])" } else { '' })
                $sliced += Get-All ($period + $window)
            }
            ($sliced -join ',') | Should -BeExactly ($whole -join ',')
        } finally { $s.Dispose() }
    }

    It 'accepts the sort-key window only on the lists read day by day, and only as a non-empty window' {
        $p = $script:Period
        (Request $script:Http "/api/messages?$p&orderFrom=2026-10-15T00%3A00%3A00Z&orderTo=2026-10-15T00%3A00%3A00Z").StatusCode | Should -Be 400
        ((Request $script:Http "/api/messages?$p&orderFrom=2026-10-15T00%3A00%3A00Z&orderTo=2026-10-14T00%3A00%3A00Z").Content | ConvertFrom-Json).error.code | Should -BeExactly 'InvalidOrderWindow'
        (Request $script:Http "/api/sessions?$p&orderFrom=2026-10-15T00%3A00%3A00Z").StatusCode | Should -Be 200
        (Request $script:Http "/api/smtp/transactions?$p&orderTo=2026-10-15T00%3A00%3A00Z").StatusCode | Should -Be 200
        foreach ($path in '/api/overview', '/api/overview/counts', '/api/smtp/clients', '/api/export.csv', '/api/messages/1') {
            $query = "$p&orderFrom=2026-10-15T00%3A00%3A00Z" + $(if ($path -eq '/api/export.csv') { '&view=messages' } else { '' })
            $r = Request $script:Http "${path}?$query"
            $r.StatusCode | Should -Be 400 -Because $path
            ($r.Content | ConvertFrom-Json).error.code | Should -BeExactly 'InvalidParameter' -Because $path
        }
    }
}

Describe 'Serve report datasets (report-meta, overview servers, requests, users, operations)' {
    BeforeAll {
        # Client access rows of two UTC days next to the mail of Add-Mail; the static report and Serve read the same store.
        $script:Ds = New-ServeStore 'datasets'
        Add-Mail $script:Ds
        $t = $script:Epoch
        $script:DsDay = [DateTimeOffset]::FromUnixTimeMilliseconds($t).UtcDateTime.ToString('yyyy-MM-dd')
        $script:DsPrevious = [DateTimeOffset]::FromUnixTimeMilliseconds($t - 86400000).UtcDateTime.ToString('yyyy-MM-dd')
        $agent = 'Microsoft Office/16.0 (Windows NT 10.0; Microsoft Outlook 16.0.17928)'
        $failures = @(foreach ($i in 0..11) { "($($t + 100 + $i * 100),'EX1','HttpProxy','Owa','beta@invalid','10.0.0.2','Mozilla/5.0','POST','/owa/service.svc','GetItem',500,'ServerError','req-b-$i')" })
        Write-Sql $script:Ds @"
INSERT INTO access_usage(day,server,user,protocol,mailbox,requests,successes,client_errors,server_errors,bytes_in,bytes_out,total_ms,max_ms,first_ms,last_ms,last_success_ms,last_failure_ms,client_ip,user_agent) VALUES
(@d,'EX1','alpha@invalid','Mapi','alpha-box@invalid',10,8,1,1,100,200,1000,50,@t-1000,@t+5000,@t+5000,@t,'10.0.0.1',@agent),
(@d,'EX2','alpha@invalid','Ews','alpha-box@invalid',4,4,0,0,10,20,400,30,@t-500,@t+4000,@t+4000,0,'10.0.0.1',@agent),
(@d,'EX1','beta@invalid','Owa',NULL,15,2,0,13,10,20,300,40,@t-90000,@t+1300,@t-60000,@t+1300,'10.0.0.2','Mozilla/5.0'),
(@p,'EX1','gamma@invalid','Mapi',NULL,3,2,1,0,10,20,30,10,@t-86400000,@t-80000000,@t-80000000,@t-86400000,'10.0.0.3',@agent);
INSERT INTO access_event(time_ms,server,source,protocol,user,client_ip,user_agent,method,url,action,status,outcome,request_id,recovered_ms) VALUES
(@t+10,'EX1','HttpProxy','Mapi','alpha@invalid','10.0.0.1',@agent,'POST','/mapi/emsmdb/','Execute',400,'ClientError','req-a1',NULL),
(@t+20,'EX1','IIS','Owa','beta@invalid','10.0.0.2','Mozilla/5.0','POST','/owa/service.svc','GetItem',500,'ServerError','req-b1',NULL),
(@t+30,'EX2','HttpProxy','Ews','alpha@invalid','10.0.0.1',@agent,'POST','/EWS/Exchange.asmx','GetItem',200,'Slow','req-a2',NULL),
(@t+40,'EX1','HttpProxy','Mapi','alpha@invalid','10.0.0.1',@agent,'POST','/mapi/emsmdb/','Execute',200,'Success','req-a3',NULL),
(@t-86300000,'EX1','HttpProxy','Mapi','gamma@invalid','10.0.0.3',@agent,'POST','/mapi/emsmdb/','Execute',503,'ServerError','req-g1',@t-86295000);
INSERT INTO access_event(time_ms,server,source,protocol,user,client_ip,user_agent,method,url,action,status,outcome,request_id) VALUES $($failures -join ',');
INSERT INTO iis_status(server,request_id,time_ms,status,sub_status,win32,time_taken) VALUES('EX1','req-b1',@t+20,500,19,5,77);
INSERT INTO access_action(day,server,protocol,action,requests,failures,slow,total_ms,max_ms) VALUES
(@d,'EX1','Mapi','Execute',10,1,0,1000,50),(@d,'EX2','Ews','GetItem',4,0,1,400,30),(@d,'EX1','Owa','GetItem',15,13,0,300,40),(@p,'EX1','Mapi','Execute',3,1,0,30,10);
INSERT INTO access_client(day,user,protocol,client_ip,user_agent,device_id,device_type,software,requests,failures,first_ms,last_ms,servers,auth_type) VALUES
(@d,'alpha@invalid','Mapi','10.0.0.1',@agent,'',NULL,'Outlook 16.0',10,2,@t-1000,@t+5000,'EX1','Negotiate'),
(@d,'alpha@invalid','Mapi','10.0.0.1',@agent,'',NULL,'Outlook 16.0',2,0,@t-900,@t+100,'EX1','Basic'),
(@d,'alpha@invalid','Ews','10.0.0.1',@agent,'',NULL,'Outlook 16.0',4,0,@t-500,@t+4000,'EX2','OAuth'),
(@d,'beta@invalid','Owa','10.0.0.2','Mozilla/5.0','',NULL,NULL,15,13,@t-90000,@t+1300,'EX1','FBA'),
(@d,'beta@invalid','Eas','10.0.0.2','Apple-iPhone/1.0','BETAPHONE','iPhone',NULL,3,0,@t-80000,@t+1200,'EX1','Basic');
"@ @{ t = $t; d = $script:DsDay; p = $script:DsPrevious; agent = $agent }
        $script:DsFrom = $t - 2 * 86400000; $script:DsTo = $t + 86400000
        $script:DsPeriod = 'from=' + [Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($script:DsFrom).ToString('O')) + '&to=' + [Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($script:DsTo).ToString('O'))
        # The static Detailed report of the same store and period (UTC), as one HTML page and its CSV files.
        $q = [ExchangeLogReport.ReportRequest]::new()
        $q.StartMs = $script:DsFrom; $q.EndMs = $script:DsTo; $q.Detailed = $true; $q.WriteHtml = $true; $q.WriteCsv = $true
        $q.ConfiguredServers = [string[]]@('EX1', 'EX2'); $q.MemoryBudgetMB = 64; $q.Parallelism = 1; $q.HtmlLayout = 'SingleFile'
        $q.TemplatePath = Join-Path $script:Root 'templates\Report.template.html'
        $q.OutputFolder = Join-Path $script:Work 'datasets-report'
        $script:DsReport = [ExchangeLogReport.ReportBuilder]::Build($script:Ds, $q)
        $html = [IO.File]::ReadAllText($script:DsReport.HtmlPath)
        $script:DsReportMeta = [regex]::Match($html, '<script id="report-meta" type="application/json">(.*?)</script>', 'Singleline').Groups[1].Value | ConvertFrom-Json -Depth 50
        function Csv([string]$Set) { @(Import-Csv -LiteralPath ($script:DsReport.Files | Where-Object Dataset -EQ $Set).Path -Delimiter ';') }
        $script:DsHost = Start-ServeTest $script:Ds.FilePath 30
        function Json([string]$Path) {
            $r = Request $script:DsHost $Path
            $r.StatusCode | Should -Be 200 -Because "$Path $($r.Content)"
            return $r.Content | ConvertFrom-Json -Depth 50
        }
        function Status([string]$Path) { $r = Request $script:DsHost $Path; [pscustomobject]@{ Status = $r.StatusCode; Code = $(if ($r.StatusCode -ne 200) { ($r.Content | ConvertFrom-Json).error.code }) } }
        function UserKey([string]$Name) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Name)).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
        # An optional field of an answer (absent when it is null), under Set-StrictMode as well.
        function Prop($Object, [string]$Name) { $p = $Object.PSObject.Properties[$Name]; if ($p) { $p.Value } }
        # The SHA-256 of a database file that a connection may hold open.
        function Sha([string]$Path) { $s = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite'); try { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($s)) } finally { $s.Dispose() } }
    }

    AfterAll { if ($script:Ds) { $script:Ds.Dispose(); $script:Ds = $null } }

    It 'describes the datasets with the columns, kinds, grid flags and detail columns of the static report built from the same store' {
        $meta = Json "/api/report-meta?$script:DsPeriod"
        $meta.served | Should -BeTrue
        foreach ($set in 'servers', 'daily', 'users', 'operations', 'authentication', 'sessions', 'issues', 'messages') {
            $expected = $script:DsReportMeta.datasets.$set
            $actual = $meta.datasets.$set
            $expected | Should -Not -BeNullOrEmpty -Because $set
            @($actual.columns | ForEach-Object { "$($_.name):$($_.kind):$($_.grid)" }) -join '|' | Should -BeExactly (@($expected.columns | ForEach-Object { "$($_.name):$($_.kind):$($_.grid)" }) -join '|') -Because $set
            (@(Prop $actual 'detailColumns') -join ',') | Should -BeExactly (@(Prop $expected 'detailColumns') -join ',') -Because $set
        }
        # SMTP clients keep the Serve grouping (per server, connector and account): their columns are those of /api/smtp/clients.
        @($meta.datasets.smtpclients.columns.name) -join '|' | Should -BeExactly (@((Json "/api/smtp/clients?$script:DsPeriod").columns.name) -join '|')
        # The lists carry the dataset's columns but the detail ones; each list answers with exactly the declared list columns.
        @($meta.datasets.sessions.listColumns) -join '|' | Should -BeExactly (@($script:DsReportMeta.datasets.sessions.columns.name | Select-Object -First 26) -join '|')
        @($meta.datasets.users.listColumns) -join '|' | Should -BeExactly (@(@($script:DsReportMeta.datasets.users.columns.name | Select-Object -First 13) + 'Authentication') -join '|')
        @($meta.datasets.authentication.listColumns) -join '|' | Should -BeExactly (@($script:DsReportMeta.datasets.authentication.columns.name | Select-Object -First 12) -join '|')
        $meta.datasets.authentication.detail | Should -BeExactly '/api/authentication/{id}'
        $meta.datasets.authentication.PSObject.Properties.Name | Should -Not -Contain 'rows'
        foreach ($set in 'users', 'operations', 'authentication', 'sessions', 'issues', 'messages', 'smtpclients', 'smtp') {
            $list = Json ($meta.datasets.$set.list + "?$script:DsPeriod")
            @($list.columns.name) -join '|' | Should -BeExactly (@($meta.datasets.$set.listColumns) -join '|') -Because $set
        }
        $overview = Json "/api/overview/servers?$script:DsPeriod"
        @($overview.servers.columns.name) -join '|' | Should -BeExactly (@($meta.datasets.servers.columns.name) -join '|')
        @($overview.daily.columns.name) -join '|' | Should -BeExactly (@($meta.datasets.daily.columns.name) -join '|')
    }

    It 'gives the report''s figures for servers, daily, users, operations, failed and slow requests and client sessions' {
        $overview = Json "/api/overview/servers?$script:DsPeriod"
        $report = @($script:DsReport.ServerRows | ForEach-Object { (@($_[0..5]) + @($_[9..15])) -join '|' })
        @($overview.servers.rows | ForEach-Object { (@($_.cells[0..5]) + @($_.cells[9..15])) -join '|' }) -join "`n" | Should -BeExactly ($report -join "`n")
        @($overview.daily.rows | ForEach-Object { $_.cells -join '|' }) -join "`n" | Should -BeExactly (@(Csv 'daily' | ForEach-Object { @($_.PSObject.Properties.Value) -join '|' }) -join "`n")
        $users = Json "/api/users?$script:DsPeriod"
        $users.total | Should -Be $script:DsReport.Counts['users']
        # Serve lists the users in a total order (most requests first, then the user name, ordinal); the report has no order on ties.
        $expectedUsers = @(Csv 'users' | ForEach-Object { "$($_.User)|$($_.Clients)|$($_.Requests)|$($_.'Failed requests')|$($_.'Unresolved failures')|$($_.'Active days')|$($_.'Last client IP')" })
        @($users.rows | ForEach-Object { "$($_.cells[0])|$($_.cells[3])|$($_.cells[5])|$($_.cells[6])|$($_.cells[7])|$($_.cells[8])|$($_.cells[11])" }) -join "`n" | Should -BeExactly ($expectedUsers -join "`n")
        $operations = Json "/api/operations?$script:DsPeriod"
        $operations.total | Should -Be $script:DsReport.Counts['operations']
        @($operations.rows | ForEach-Object { "$($_.cells[0])|$($_.cells[1])|$($_.cells[2])|$($_.cells[4])|$($_.cells[9])" }) -join "`n" | Should -BeExactly (@(Csv 'operations' | ForEach-Object { "$($_.Protocol)|$($_.Operation)|$($_.Requests)|$($_.Failures)|$($_.Servers)" }) -join "`n")
        # Failed and slow requests: the same rows (newest first in Serve) with the same resolution.
        $requests = Json "/api/requests?$script:DsPeriod&size=2000"
        $requests.exhausted | Should -BeTrue
        Prop $requests 'nextCursor' | Should -BeNullOrEmpty
        $expected = @(Csv 'issues' | ForEach-Object { "$($_.'Request ID')|$($_.Outcome)|$($_.Resolution)|$($_.'Duration (ms)')" })
        [array]::Reverse($expected)
        @($requests.rows | ForEach-Object { "$($_.cells[22])|$($_.cells[19])|$($_.cells[20])|$($_.cells[18])" }) -join "`n" | Should -BeExactly ($expected -join "`n")
        @($requests.rows | Where-Object { $_.cells[22] -eq 'req-b1' })[0].cells[12] | Should -Be 19
        @($requests.rows | Where-Object { $_.cells[22] -eq 'req-g1' })[0].cells[20] | Should -BeExactly 'Recovered'
        # A user filter also lists the successes kept for that user, as a report filtered on users does.
        @((Json "/api/requests?$script:DsPeriod&user=alpha%40invalid").rows | ForEach-Object { $_.cells[22] }) -join ',' | Should -BeExactly 'req-a3,req-a2,req-a1'
        # Client sessions: the report's list columns, from client_session alone.
        $sessions = Json "/api/sessions?$script:DsPeriod"
        $row = @(Csv 'sessions')[0]
        $cells = $sessions.rows[0].cells
        "$($cells[2])|$($cells[3])|$($cells[4])|$($cells[5])|$($cells[6])|$($cells[10])|$($cells[11])|$($cells[24])|$($cells[25])" | Should -BeExactly "$($row.Duration)|$($row.Outcome)|$($row.User)|$($row.Protocol)|$($row.Client)|$($row.Requests)|$($row.Failures)|$($row.'Session ID')|$($row.Authentication)"
        $cells[25] | Should -BeExactly 'Negotiate'
        $cells.Count | Should -Be 26
    }

    It 'counts an authentication type logged in two spellings exactly: the clients of that protocol are read again, the other protocols are not' {
        $s = New-ServeStore 'auth-spellings'
        try {
            $t = $script:Epoch
            Write-Sql $s @"
INSERT INTO access_client(day,user,protocol,client_ip,user_agent,device_id,device_type,software,requests,failures,first_ms,last_ms,servers,auth_type) VALUES
(@d,'alpha@invalid','Mapi','10.0.0.1','agent-a','',NULL,NULL,10,1,@t-1000,@t+5000,'EX1','Negotiate'),
(@d,'alpha@invalid','Mapi','10.0.0.1','agent-a','',NULL,NULL,3,0,@t-900,@t+6000,'EX2','negotiate'),
(@d,'beta@invalid','Mapi','10.0.0.2','agent-b','DEV1','iPhone',NULL,4,2,@t-800,@t+100,'EX1','negotiate'),
(@p,'alpha@invalid','Mapi','10.0.0.1','agent-a','',NULL,NULL,2,0,@t-86400000,@t-86000000,'EX1','Negotiate'),
(@d,'alpha@invalid','Ews','10.0.0.1','agent-a','',NULL,NULL,5,0,@t-500,@t+4000,'EX2','OAuth'),
(@d,'beta@invalid','Ews','10.0.0.2','agent-b','',NULL,NULL,1,1,@t-400,@t+3000,'EX1','Basic');
"@ @{ t = $t; d = $script:DsDay; p = $script:DsPrevious }
            $h = Start-ServeTest $s.FilePath 30
            $r = Request $h "/api/authentication?$script:DsPeriod"
            $r.StatusCode | Should -Be 200 -Because $r.Content
            $rows = @(($r.Content | ConvertFrom-Json -Depth 50).rows)
            @($rows | ForEach-Object { "$($_.cells[0])|$($_.cells[1])" }) -join ',' | Should -BeExactly 'Ews|Basic,Ews|OAuth,Mapi|Negotiate'
            # Mapi Negotiate: two users, two clients and one device over two days, not the sums of the two spellings (3 users).
            $mapi = @($rows | Where-Object { $_.cells[0] -eq 'Mapi' })[0].cells
            @($mapi[3], $mapi[4], $mapi[5], $mapi[6], $mapi[7], $mapi[8], $mapi[11]) -join '|' | Should -BeExactly '2|2|1|19|3|2|EX1, EX2'
            # Every row of the list equals the row of its detail, which reads the clients behind it.
            foreach ($row in $rows) {
                $detail = (Request $h "/api/authentication/$($row.id)?$script:DsPeriod").Content | ConvertFrom-Json -Depth 50
                @($detail.cells[0..11]) -join '|' | Should -BeExactly (@($row.cells) -join '|') -Because "$($row.cells[0]) $($row.cells[1])"
            }
            # The diagnostics explain the statement of the list on this store too.
            $plans = @([ExchangeLogReport.ServeDiagnostics]::ExplainReportDatasets($s.FilePath, $script:DsFrom, $script:DsTo, $null, $null) | ConvertFrom-Json)
            @($plans | Where-Object { $_ -match 'access_client' }).Count | Should -BeGreaterThan 0
        } finally { $s.Dispose() }
    }

    It 'gives the report''s authentication rows, their users and devices, and the authentication types of the users' {
        $auth = Json "/api/authentication?$script:DsPeriod"
        $static = @(Csv 'authentication')
        $static.Count | Should -BeGreaterThan 3
        $auth.total | Should -Be $static.Count
        # Every cell but the times (Serve gives ISO times, the report the wall clock of its zone), in the same order.
        $timeless = 0..11 | Where-Object { $_ -notin 9, 10 }
        @($auth.rows | ForEach-Object { $c = $_.cells; @($timeless | ForEach-Object { [string]$c[$_] }) -join '|' }) -join "`n" |
            Should -BeExactly (@($static | ForEach-Object { $v = @($_.PSObject.Properties.Value); @($timeless | ForEach-Object { [string]$v[$_] }) -join '|' }) -join "`n")
        @($auth.rows | ForEach-Object { "$($_.cells[0])|$($_.cells[1])|$($_.cells[3])" }) -join ',' | Should -BeExactly 'Eas|Basic|1,Ews|OAuth|1,Mapi|Basic|1,Mapi|Negotiate|1,Owa|Forms|1'
        ($auth.rows | Where-Object { $_.cells[0] -eq 'Eas' }).cells[2] | Should -BeExactly 'Yes'
        @($auth.columns.name) -join '|' | Should -BeExactly (@($script:DsReportMeta.datasets.authentication.columns.name | Select-Object -First 12) -join '|')
        # The second answer comes from the result cache.
        (Json "/api/authentication?$script:DsPeriod").cached | Should -BeTrue
        # A row opens its clients: (Mapi, Negotiate) is alpha's Outlook.
        $id = ($auth.rows | Where-Object { $_.cells[0] -eq 'Mapi' -and $_.cells[1] -eq 'Negotiate' }).id
        $id | Should -BeExactly (UserKey "Mapi`nNegotiate")
        $detail = Json "/api/authentication/${id}?$script:DsPeriod"
        $detail.title | Should -BeExactly 'Authentication'
        @($detail.columns.name) -join '|' | Should -BeExactly (@($script:DsReportMeta.datasets.authentication.columns.name) -join '|')
        $clients = @($detail.cells[12])
        $clients.Count | Should -Be 1
        @($clients[0][0], $clients[0][4], $clients[0][5]) | Should -Be @('alpha@invalid', 'EX1', 10)
        $eas = Json "/api/authentication/$(UserKey "Eas`nBasic")?$script:DsPeriod"
        @($eas.cells[12])[0][3] | Should -BeExactly 'BETAPHONE'
        (Status "/api/authentication/$(UserKey "Mapi`nOAuth")?$script:DsPeriod").Status | Should -Be 404
        (Status "/api/authentication/$(UserKey 'Mapi')?$script:DsPeriod").Status | Should -Be 404
        (Status "/api/authentication/a.b?$script:DsPeriod").Status | Should -Be 404
        (Status "/api/authentication?$script:DsPeriod&status=x").Code | Should -BeExactly 'InvalidParameter'
        # A server filter: the clients seen on that server.
        @((Json "/api/authentication?$script:DsPeriod&server=EX2").rows | ForEach-Object { "$($_.cells[0])|$($_.cells[1])" }) -join ',' | Should -BeExactly 'Ews|OAuth'
        # The users list carries the authentication types of each user (in the fixed order of the types, Unknown last), the user detail too.
        $users = Json "/api/users?$script:DsPeriod"
        @($users.columns.name).Count | Should -Be 14
        $cell = ($users.rows | Where-Object { $_.cells[0] -eq 'alpha@invalid' }).cells[13]
        @($cell -split ', ' | Sort-Object) -join ', ' | Should -BeExactly 'Basic, Negotiate, OAuth'
        ($users.rows | Where-Object { $_.cells[0] -eq 'gamma@invalid' }).cells[13] | Should -BeNullOrEmpty
        @(Csv 'users' | Where-Object User -eq 'alpha@invalid').Authentication | Should -BeExactly $cell
        $alpha = Json "/api/users/$(UserKey 'alpha@invalid')?$script:DsPeriod"
        $alpha.cells[15] | Should -BeExactly $cell
        @($alpha.cells[14] | ForEach-Object { $_[9] }) -join ',' | Should -BeExactly 'Negotiate, Basic,OAuth'
    }

    It 'pages the failed and slow requests with a keyset cursor, both directions, and skip only inside an order window' {
        $all = @((Json "/api/requests?$script:DsPeriod&size=2000").rows | ForEach-Object { [long]$_.id })
        $all.Count | Should -BeGreaterThan 10
        $ids = @(); $cursor = $null; $pages = 0
        do {
            $page = Json ("/api/requests?$script:DsPeriod&size=4" + $(if ($cursor) { "&cursor=$cursor" } else { '' }))
            $ids += @($page.rows | ForEach-Object { [long]$_.id }); $cursor = Prop $page 'nextCursor'; $pages++
            $page.PSObject.Properties.Name | Should -Not -Contain 'page'
        } while ($cursor)
        $page.exhausted | Should -BeTrue
        ($ids -join ',') | Should -BeExactly ($all -join ',')
        $pages | Should -Be ([Math]::Ceiling($all.Count / 4))
        $ascending = @((Json "/api/requests?$script:DsPeriod&size=2000&dir=asc").rows | ForEach-Object { [long]$_.id })
        [array]::Reverse($ascending)
        ($ascending -join ',') | Should -BeExactly ($all -join ',')
        $window = '&orderFrom=' + [Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($script:DsFrom).ToString('O')) + '&orderTo=' + [Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($script:DsTo).ToString('O'))
        (@((Json "/api/requests?$script:DsPeriod$window&skip=3&size=2").rows | ForEach-Object { [long]$_.id }) -join ',') | Should -BeExactly (($all[3..4]) -join ',')
        (Status "/api/requests?$script:DsPeriod&skip=3").Code | Should -BeExactly 'SkipWindow'
        (Status "/api/requests?$script:DsPeriod$window&skip=10001").Status | Should -Be 400
        (Status "/api/requests?$script:DsPeriod&cursor=12.x").Code | Should -BeExactly 'InvalidCursor'
        (Status "/api/requests?$script:DsPeriod&dir=up").Code | Should -BeExactly 'InvalidDirection'
        (Status "/api/requests?$script:DsPeriod&page=1").Code | Should -BeExactly 'InvalidParameter'
        (Status "/api/requests?$script:DsPeriod&size=2000").Status | Should -Be 200
        (Status "/api/requests?$script:DsPeriod&size=2001").Status | Should -Be 400
        (Status "/api/sessions?$script:DsPeriod&page=1&cursor=1.1").Code | Should -BeExactly 'InvalidParameter'
    }

    It 'gives the Identifiers of a user (security identifiers of token requests) as the static report does, and none without identity_map' {
        $s = New-ServeStore 'identities'
        try {
            $t = $script:Epoch
            Write-Sql $s @"
INSERT INTO access_usage(day,server,user,protocol,mailbox,requests,successes,client_errors,server_errors,bytes_in,bytes_out,total_ms,max_ms,first_ms,last_ms,last_success_ms,last_failure_ms,client_ip,user_agent) VALUES
(@d,'EX1','contoso\hank','Ews','shared@invalid',6,6,0,0,10,20,60,10,@t-1000,@t+1000,@t+1000,0,'10.0.0.5','CapybaMail/1.0'),
(@d,'EX1','s-1-5-21-1-2-3-9999','Eas',NULL,2,2,0,0,10,20,60,10,@t-500,@t+500,@t+500,0,'10.0.0.6','Apple-iPhone/1.0');
INSERT INTO identity_map(sid,user,status,names,hints,lines,first_ms,last_ms,resolved_ms,applied_ms) VALUES
('s-1-5-21-1-2-3-1110','contoso\hank','resolved','anchor:contoso\hank=3;mapi-backend:hank@invalid=2;days:mapi-backend=20390-20391','hank@invalid=2',4,@t-1000,@t+1000,@t,@t),
('s-1-5-21-1-2-3-1120','contoso\hank','ambiguous','anchor:contoso\hank=3;anchor:contoso\jane=1',NULL,5,@t-1000,@t+1000,@t,@t),
('s-1-5-21-1-2-3-9999',NULL,'unresolved',NULL,'ghost@invalid=2',2,@t-500,@t+500,NULL,NULL);
"@ @{ t = $t; d = $script:DsDay }
            $q = [ExchangeLogReport.ReportRequest]::new()
            $q.StartMs = $script:DsFrom; $q.EndMs = $script:DsTo; $q.WriteHtml = $true; $q.WriteCsv = $true
            $q.ConfiguredServers = [string[]]@('EX1'); $q.MemoryBudgetMB = 64; $q.Parallelism = 1; $q.HtmlLayout = 'SingleFile'
            $q.TemplatePath = Join-Path $script:Root 'templates\Report.template.html'
            $q.OutputFolder = Join-Path $script:Work 'identities-report'
            $report = [ExchangeLogReport.ReportBuilder]::Build($s, $q)
            $staticMeta = [regex]::Match([IO.File]::ReadAllText($report.HtmlPath), '<script id="report-meta" type="application/json">(.*?)</script>', 'Singleline').Groups[1].Value | ConvertFrom-Json -Depth 50
            $h = Start-ServeTest $s.FilePath 30
            $get = { param($p) $r = Request $h $p; $r.StatusCode | Should -Be 200 -Because "$p $($r.Content)"; $r.Content | ConvertFrom-Json -Depth 50 }
            $meta = & $get "/api/report-meta?$script:DsPeriod"
            $users = $meta.datasets.users
            ($users.columns | Where-Object name -EQ 'Identifiers').grid | Should -BeFalse
            @($users.columns.name).IndexOf('Identifiers') | Should -Be 16
            @($users.detailColumns) -join ',' | Should -BeExactly '13,14,16'
            @($users.detailColumns) -join ',' | Should -BeExactly (@($staticMeta.datasets.users.detailColumns) -join ',')
            @((& $get "/api/users?$script:DsPeriod").columns.name).Count | Should -Be 14
            $hank = & $get "/api/users/$(UserKey 'contoso\hank')?$script:DsPeriod"
            @($hank.cells).Count | Should -Be 17
            $ids = @($hank.cells[16])
            $ids.Count | Should -Be 2
            # The days of the back-end evidence are not shown; a SID no longer resolved names the account its rows were merged with.
            @($ids[0][0..4]) -join '|' | Should -BeExactly 's-1-5-21-1-2-3-1110|resolved|anchor:contoso\hank=3;mapi-backend:hank@invalid=2|hank@invalid=2|4'
            @($ids[1][0..4]) -join '|' | Should -BeExactly 's-1-5-21-1-2-3-1120|ambiguous, merged with contoso\hank|anchor:contoso\hank=3;anchor:contoso\jane=1||5'
            $ghost = & $get "/api/users/$(UserKey 's-1-5-21-1-2-3-9999')?$script:DsPeriod"
            @(@($ghost.cells[16])[0][0..4]) -join '|' | Should -BeExactly 's-1-5-21-1-2-3-9999|unresolved||ghost@invalid=2|2'
            # The static report's Users CSV keeps its columns; the identifiers are a detail of the HTML page only.
            @(Import-Csv -LiteralPath ($report.Files | Where-Object Dataset -EQ 'users').Path -Delimiter ';')[0].PSObject.Properties.Name.Count | Should -Be 14
            # A database of an earlier 3.0 build has no identity_map: the user opens, with no identifiers.
            Write-Sql $s 'DROP TABLE identity_map;'
            $plain = & $get "/api/users/$(UserKey 'contoso\hank')?$script:DsPeriod"
            @($plain.cells[16]).Count | Should -Be 0
            $plans = @([ExchangeLogReport.ServeDiagnostics]::ExplainReportDatasets($script:Ds.FilePath, $script:DsFrom, $script:DsTo, $null, 'alpha') | ConvertFrom-Json)
            @($plans | Where-Object { $_ -match 'identity_map' }).Count | Should -Be 2
        } finally { $s.Dispose() }
    }

    It 'opens a user and a request only inside the selection, through an exact user' {
        $alpha = UserKey 'alpha@invalid'
        $user = Json "/api/users/${alpha}?$script:DsPeriod"
        $user.cells[0] | Should -BeExactly 'alpha@invalid'
        @($user.cells[13] | ForEach-Object { $_[0] }) -join ',' | Should -BeExactly 'Mapi,Ews'
        @($user.cells[14]).Count | Should -Be 2
        @($user.columns.name) -join '|' | Should -BeExactly (@($script:DsReportMeta.datasets.users.columns.name) -join '|')
        (Status "/api/users/${alpha}?$script:DsPeriod&server=EX2").Status | Should -Be 200
        (Status "/api/users/$(UserKey 'beta@invalid')?$script:DsPeriod&server=EX2").Status | Should -Be 404
        (Status "/api/users/${alpha}?$script:DsPeriod&user=gamma").Status | Should -Be 404
        $before = 'from=' + [Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($script:DsFrom).ToString('O')) + '&to=' + [Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($script:Epoch - ($script:Epoch % 86400000)).ToString('O'))
        (Status "/api/users/${alpha}?$before").Status | Should -Be 404
        (Status "/api/users/$(UserKey 'gamma@invalid')?$before").Status | Should -Be 200
        (Status "/api/users/AAAA?$script:DsPeriod").Status | Should -Be 404
        (Status "/api/users/a.b?$script:DsPeriod").Status | Should -Be 404
        $detail = Json "/api/requests/req-b1?$script:DsPeriod&user=beta%40invalid"
        @($detail.rows).Count | Should -Be 1
        $detail.rows[0].cells[20] | Should -BeExactly 'Unresolved'
        $detail.rows[0].cells[18] | Should -Be 77
        @($detail.columns.name) -join '|' | Should -BeExactly (@($script:DsReportMeta.datasets.issues.columns.name) -join '|')
        # Every outcome is kept for the step detail, successes included.
        (Status "/api/requests/req-a3?$script:DsPeriod&user=alpha%40invalid").Status | Should -Be 200
        (Status "/api/requests/req-b1?$script:DsPeriod&user=alpha%40invalid").Status | Should -Be 404
        (Status "/api/requests/req-b1?$script:DsPeriod&user=beta").Status | Should -Be 404
        (Status "/api/requests/req-b1?$before&user=beta%40invalid").Status | Should -Be 404
        (Status "/api/requests/req-b1?$script:DsPeriod").Code | Should -BeExactly 'UserRequired'
        (Status "/api/requests/req-b1?$script:DsPeriod&user=beta%40invalid&server=EX1").Code | Should -BeExactly 'InvalidParameter'
    }

    It 'accepts only the parameters of each new endpoint' {
        $window = '&orderFrom=' + [Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($script:Epoch - ($script:Epoch % 86400000)).ToString('O'))
        foreach ($path in "/api/report-meta?$script:DsPeriod$window", "/api/report-meta?$script:DsPeriod&size=5", "/api/overview/servers?$script:DsPeriod&status=OK",
            "/api/users?$script:DsPeriod&page=1", "/api/users?$script:DsPeriod&size=10", "/api/operations?$script:DsPeriod&user=alpha", "/api/operations?$script:DsPeriod&page=2",
            "/api/users/$(UserKey 'alpha@invalid')?$script:DsPeriod&status=x", "/api/requests?$script:DsPeriod&view=x", "/api/requests?$script:DsPeriod&server=EX1&server=EX2") {
            (Status $path).Code | Should -BeExactly 'InvalidParameter' -Because $path
        }
        foreach ($path in "/api/overview/servers?$script:DsPeriod$window", "/api/users?$script:DsPeriod$window&server=EX1", "/api/operations?$script:DsPeriod$window&server=EX1") {
            (Status $path).Status | Should -Be 200 -Because $path
        }
        # A day window narrows the days the daily tables are read for.
        $day = Json "/api/operations?$script:DsPeriod$window"
        @($day.rows | ForEach-Object { "$($_.cells[0])|$($_.cells[2])" }) -join ',' | Should -BeExactly 'Ews|4,Mapi|10,Owa|15'
        (Status "/api/report-meta").Status | Should -Be 200
        (Request $script:DsHost "/api/report-meta?$script:DsPeriod" @{ 'X-Portal-Token' = ('0' * 64) }).StatusCode | Should -Be 401
    }

    It 'lists one pack per period-aggregated dataset and one per day-sliced dataset and day, newest first, with exact counts only' {
        $meta = Json "/api/report-meta?$script:DsPeriod"
        $meta.clientRowsMax | Should -Be 50000
        $meta.scanBudgetMs | Should -Be 2000
        $meta.timeZone | Should -BeExactly 'UTC'
        @($meta.configuredServers) -join ',' | Should -BeExactly 'EX1'
        # The filter classes of the lists are in the Guide (the list layer), not in the description of the report.
        foreach ($set in 'sessions', 'issues', 'messages', 'smtp') { $meta.datasets.$set.PSObject.Properties.Name | Should -Not -Contain 'serverFilters' -Because $set }
        $meta.datasets.users.rows | Should -Be $script:DsReport.Counts['users']
        $meta.datasets.operations.rows | Should -Be $script:DsReport.Counts['operations']
        foreach ($set in 'sessions', 'issues', 'messages', 'smtp', 'servers', 'smtpclients') { $meta.datasets.$set.PSObject.Properties.Name | Should -Not -Contain 'rows' -Because $set }
        # The UTC days of the period, newest first (the period starts and ends within a day).
        $days = @(for ($ms = $script:DsTo - 1; $ms -ge $script:DsFrom - ($script:DsFrom % 86400000); $ms -= 86400000) { [DateTimeOffset]::FromUnixTimeMilliseconds($ms).UtcDateTime.ToString('yyyy-MM-dd') })
        $days.Count | Should -Be 4
        foreach ($set in 'sessions', 'issues', 'messages', 'smtp') {
            $packs = @($meta.data.files | Where-Object set -EQ $set)
            @($packs.day) -join ',' | Should -BeExactly ($days -join ',') -Because $set
            $packs[0].orderTo | Should -BeNullOrEmpty
            $packs[-1].orderFrom | Should -BeNullOrEmpty
            $packs | ForEach-Object { $_.PSObject.Properties.Name | Should -Not -Contain 'rows' }
        }
        # The pack URLs are the lists' own; the day packs of the requests hold every row of the period once, in list order.
        $ids = @(foreach ($p in @($meta.data.files | Where-Object set -EQ 'issues')) { (Json ($p.url + '&size=2000')).rows | ForEach-Object { [long]$_.id } })
        ($ids -join ',') | Should -BeExactly (@((Json "/api/requests?$script:DsPeriod&size=2000").rows | ForEach-Object { [long]$_.id }) -join ',')
        foreach ($p in @($meta.data.files)) { (Status $p.url).Status | Should -Be 200 -Because $p.url }
        # Filtered on a user: no operations (measured per server), with the report's note.
        $scoped = Json "/api/report-meta?$script:DsPeriod&user=alpha"
        $scoped.datasets.PSObject.Properties.Name | Should -Not -Contain 'operations'
        ($scoped.notes -join ' ') | Should -Match 'Operations are measured per server'
    }

    It 'never carries SMTP transcripts in the new lists' {
        foreach ($path in "/api/report-meta?$script:DsPeriod", "/api/overview/servers?$script:DsPeriod", "/api/users?$script:DsPeriod", "/api/operations?$script:DsPeriod",
            "/api/requests?$script:DsPeriod&size=2000", "/api/sessions?$script:DsPeriod") {
            $content = (Request $script:DsHost $path).Content
            $content | Should -Not -Match '250 synthetic|AUTH <redacted>|SYNTHETICPAYLOAD' -Because $path
        }
    }

    It 'reads every new statement through an index range, never a whole-table scan (<Scope>)' -ForEach @(@{Scope='unfiltered'; Server=$null; User=$null}, @{Scope='server and user'; Server='EX1'; User='alpha'}) {
        $plans = @([ExchangeLogReport.ServeDiagnostics]::ExplainReportDatasets($script:Ds.FilePath, $script:DsFrom, $script:DsTo, $Server, $User) | ConvertFrom-Json)
        $plans.Count | Should -BeGreaterThan 20
        foreach ($entry in $plans) {
            $plan = ($entry -split ' => ')[-1]
            $plan | Should -Match 'SEARCH \w+ USING (COVERING )?(INDEX \w+|PRIMARY KEY) \(' -Because $entry
            $plan | Should -Not -Match '\bSCAN (?!\()' -Because $entry
        }
        foreach ($entry in @($plans | Where-Object { $_ -like 'SELECT e.id,*FROM access_event e INDEXED BY ix_event_time*' })) {
            $entry | Should -Match 'SEARCH e USING INDEX ix_event_time \(time_ms>\? AND time_ms<\?\)'
            $entry | Should -Not -Match 'TEMP B-TREE FOR ORDER BY'
        }
        @($plans | Where-Object { $_ -like 'SELECT e.id,*INDEXED BY ix_event_user*' })[0] | Should -Match 'SEARCH e USING INDEX ix_event_user \(user=\? AND time_ms>\? AND time_ms<\?\)'
    }

    It 'stops the requests at the request deadline and gives the period aggregates their own deadline' {
        $s = New-ServeStore 'datasets-deadline'; Add-Mail $s
        try {
            $n = 1000000
            do {
                $n *= 2
                $clock = [Diagnostics.Stopwatch]::StartNew()
                [void]$s.Scalar("WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<$n) SELECT SUM(i) FROM n;", $null)
            } while ($clock.Elapsed.TotalSeconds -lt 1.5 -and $n -lt 512000000)
            $day = [DateTimeOffset]::FromUnixTimeMilliseconds($script:Epoch).UtcDateTime.ToString('yyyy-MM-dd')
            $s.Exec("INSERT INTO access_event(time_ms,server,source,protocol,user,outcome,request_id) VALUES($script:Epoch,'EX1','Synthetic','Mapi','s@invalid','Slow','slow-1');")
            $s.Exec("INSERT INTO access_usage(day,server,user,protocol,requests,successes,client_errors,server_errors,bytes_in,bytes_out,total_ms,max_ms,first_ms,last_ms,last_success_ms,last_failure_ms) VALUES('$day','EX1','s@invalid','Mapi',1,0,0,1,0,0,1,1,$script:Epoch,$script:Epoch,0,$script:Epoch);")
            # The IIS status rows joined to every listed request and the operations the period aggregate reads become slow views (neither is an object of the
            # shape Serve requires).
            $s.Exec("INSERT INTO iis_status(server,request_id,time_ms,status) VALUES('EX1','slow-1',$script:Epoch,500); ALTER TABLE iis_status RENAME TO iis_status_base; CREATE VIEW iis_status AS SELECT b.* FROM iis_status_base b CROSS JOIN (WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<$n) SELECT SUM(i) FROM n);")
            $s.Exec("INSERT INTO access_action(day,server,protocol,action,requests,failures,slow,total_ms,max_ms) VALUES('$day','EX1','Mapi','Execute',1,0,0,1,1); ALTER TABLE access_action RENAME TO access_action_base; CREATE VIEW access_action AS SELECT b.* FROM access_action_base b CROSS JOIN (WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<$n) SELECT SUM(i) FROM n);")
            $h = Start-ServeTest $s.FilePath 1 -Aggregate 60
            foreach ($path in "/api/requests?$script:Period", "/api/requests/slow-1?$script:Period&user=s%40invalid") {
                $r = Request $h $path
                $r.StatusCode | Should -Be 504 -Because $path
                ($r.Content | ConvertFrom-Json).error.message | Should -BeLike '*deadline of 1 s*'
            }
            foreach ($path in @("/api/operations?$script:Period")) {
                $clock = [Diagnostics.Stopwatch]::StartNew()
                $r = Request $h $path
                $r.StatusCode | Should -Be 200 -Because "$path $($r.Content)"
                $clock.Elapsed.TotalSeconds | Should -BeGreaterThan 1 -Because $path
            }
            (Request $h "/api/meta").StatusCode | Should -Be 200
        } finally { $s.Dispose() }
    }

    It 'leaves the source database bytes unchanged' {
        $before = Sha $script:Ds.FilePath
        $meta = Json "/api/report-meta?$script:DsPeriod"
        foreach ($p in @($meta.data.files)) { [void](Request $script:DsHost $p.url) }
        [void](Request $script:DsHost "/api/users/$(UserKey 'alpha@invalid')?$script:DsPeriod")
        [void](Request $script:DsHost "/api/requests/req-b1?$script:DsPeriod&user=beta%40invalid")
        Sha $script:Ds.FilePath | Should -BeExactly $before
    }
}

Describe 'Serve report datasets in the report time zone: days, cursors, outcomes, request details and whole rows' {
    BeforeAll {
        # A store collected in Romance Standard Time around the change of 25 October 2026 (a 25-hour day): the daily tables hold Paris days.
        $script:Rz = [TimeZoneInfo]::FindSystemTimeZoneById('Romance Standard Time')
        $inv = [Globalization.CultureInfo]::InvariantCulture
        function Ms([string]$Iso) { [DateTimeOffset]::Parse($Iso, [Globalization.CultureInfo]::InvariantCulture).ToUnixTimeMilliseconds() }
        $script:Zs = New-ServeStore 'zoned'
        Add-Mail $script:Zs
        $agent = 'Microsoft Office/16.0 (Windows NT 10.0; Microsoft Outlook 16.0.17928)'
        $w = 1800000
        # Sessions whose counters give each outcome of the list, one with back-end errors only (no timeline steps: the report reads the same counters).
        $s = @{ a = Ms '2026-10-24T08:00:00Z'; b = Ms '2026-10-25T09:00:00Z'; c = Ms '2026-10-26T10:00:00Z' }
        Write-Sql $script:Zs @"
INSERT INTO access_usage(day,server,user,protocol,mailbox,requests,successes,client_errors,server_errors,bytes_in,bytes_out,total_ms,max_ms,first_ms,last_ms,last_success_ms,last_failure_ms,client_ip,user_agent) VALUES
('2026-10-24','EX1','zed@invalid','Mapi','zed-box@invalid',10,9,1,0,1,1,100,10,@a,@a+3600000,@a+3600000,@a,'10.0.0.5',@agent),
('2026-10-25','EX1','zed@invalid','Mapi','zed-box@invalid',8,6,1,1,1,1,100,10,@b,@b+3600000,0,@b,'10.0.0.5',@agent),
('2026-10-26','EX2','zed@invalid','Mapi','zed-box@invalid',5,5,0,0,1,1,100,10,@c,@c+3600000,0,0,'10.0.0.6',@agent),
('2026-10-26','EX1','yod@invalid','Owa',NULL,4,0,0,4,1,1,100,10,@c,@c+600000,0,@c+600000,'10.0.0.7','Mozilla/5.0'),
('2026-10-27','EX1','zed@invalid','Mapi','zed-box@invalid',3,3,0,0,1,1,100,10,@d,@d+600000,@d+600000,0,'10.0.0.5',@agent);
INSERT INTO access_event(time_ms,server,source,protocol,user,client_ip,user_agent,method,url,action,status,outcome,request_id,recovered_ms) VALUES
(@e1,'EX1','HttpProxy','Mapi','zed@invalid','10.0.0.5',@agent,'POST','/mapi/emsmdb/','Execute',500,'ServerError','req-z1',NULL),
(@e2,'EX1','HttpProxy','Mapi','zed@invalid','10.0.0.5',@agent,'POST','/mapi/emsmdb/','Execute',400,'ClientError','req-z2',NULL),
(@e3,'EX1','IIS','Owa','yod@invalid','10.0.0.7','Mozilla/5.0','POST','/owa/service.svc','GetItem',500,'ServerError','req-y1',NULL),
(@e4,'EX1','IIS','Owa',NULL,'10.0.0.8','Mozilla/5.0','OPTIONS','/owa/','OPTIONS',403,'ClientError','req-null',NULL);
INSERT INTO access_action(day,server,protocol,action,requests,failures,slow,total_ms,max_ms) VALUES
('2026-10-24','EX1','Mapi','Execute',10,1,0,100,10),('2026-10-25','EX1','Mapi','Execute',8,2,0,100,10),('2026-10-26','EX2','Mapi','Execute',5,0,0,100,10);
INSERT INTO client_session(skey,day,start_ms,end_ms,user,protocol,front_ends,back_ends,requests,successes,failures,slow,first_success_ms,last_success_ms,first_failure_ms,last_failure_ms,total_ms,max_ms,bytes_in,bytes_out,backend) VALUES
('o1','2026-10-24',@a,@a+60000,'sess@invalid','Mapi','EX1','EX2',4,4,0,0,@a,@a+60000,0,0,40,10,0,0,NULL),
('o2','2026-10-24',@a+100000,@a+160000,'sess@invalid','Mapi','EX1','EX2',4,4,0,2,@a+100000,@a+160000,0,0,40,10,0,0,NULL),
('o3','2026-10-25',@b,@b+60000,'sess@invalid','Ews','EX1',NULL,2,0,2,0,0,0,@b,@b+60000,40,10,0,0,NULL),
('o4','2026-10-25',@b+100000,@b+160000,'sess@invalid','Ews','EX1',NULL,4,3,1,0,@b+100000,@b+120000,@b+160000,@b+160000,40,10,0,0,NULL),
('o5','2026-10-25',@b+200000,@b+200000+3*$w,'sess@invalid','Owa','EX1',NULL,8,5,3,0,@b+200000,@b+200000+3*$w,@b+300000,@b+300000+$w+60000,40,10,0,0,NULL),
('o6','2026-10-26',@c,@c+60000,'sess@invalid','Owa','EX2',NULL,4,3,1,0,@c,@c+60000,@c+10000,@c+10000,40,10,0,0,NULL),
('o7','2026-10-26',@c+100000,@c+160000,'sess@invalid','Mapi','EX2','EX1',4,3,0,0,@c+100000,@c+160000,0,0,40,10,0,0,'2|EX1');
"@ @{ a = $s.a; b = $s.b; c = $s.c; d = (Ms '2026-10-27T08:00:00Z'); agent = $agent; e1 = (Ms '2026-10-25T23:30:00Z'); e2 = (Ms '2026-10-25T12:00:00Z'); e3 = (Ms '2026-10-26T22:30:00Z'); e4 = (Ms '2026-10-25T15:00:00Z') }
        # The period: Paris 24 October 00:00 to 27 October 00:00 (73 hours).
        $script:ZFrom = Ms '2026-10-23T22:00:00Z'; $script:ZTo = Ms '2026-10-26T23:00:00Z'
        $script:ZPeriod = 'from=' + [Uri]::EscapeDataString('2026-10-23T22:00:00Z') + '&to=' + [Uri]::EscapeDataString('2026-10-26T23:00:00Z')
        $q = [ExchangeLogReport.ReportRequest]::new()
        $q.StartMs = $script:ZFrom; $q.EndMs = $script:ZTo; $q.Detailed = $true; $q.WriteHtml = $true; $q.WriteCsv = $true
        $q.Zone = $script:Rz; $q.TimeZoneName = 'Romance Standard Time'
        $q.ConfiguredServers = [string[]]@('EX1', 'EX2'); $q.MemoryBudgetMB = 64; $q.Parallelism = 1; $q.HtmlLayout = 'SingleFile'
        $q.TemplatePath = Join-Path $script:Root 'templates\Report.template.html'
        $q.OutputFolder = Join-Path $script:Work 'zoned-report'
        $script:ZReport = [ExchangeLogReport.ReportBuilder]::Build($script:Zs, $q)
        function ZCsv([string]$Set) { @(Import-Csv -LiteralPath ($script:ZReport.Files | Where-Object Dataset -EQ $Set).Path -Delimiter ';') }
        $script:ZHost = Start-ServeTest $script:Zs.FilePath 30 -Zone $script:Rz
        $script:UHost = Start-ServeTest $script:Zs.FilePath 30
        function ZJson([string]$Path, $HostInfo = $script:ZHost) {
            $r = Request $HostInfo $Path
            $r.StatusCode | Should -Be 200 -Because "$Path $($r.Content)"
            return $r.Content | ConvertFrom-Json -Depth 50
        }
        function ZStatus([string]$Path) { $r = Request $script:ZHost $Path; [pscustomobject]@{ Status = $r.StatusCode; Code = $(if ($r.StatusCode -ne 200) { ($r.Content | ConvertFrom-Json).error.code }) } }
        function Prop($Object, [string]$Name) { $p = $Object.PSObject.Properties[$Name]; if ($p) { $p.Value } }
        # A cell of an answer as the report's CSV writes it: wall-clock times of the report time zone, lists joined, the formula prefix.
        function CsvText($Value, [string]$Kind) {
            if ($null -eq $Value) { return '' }
            if ($Kind -eq 'time') {
                $at = if ($Value -is [datetime]) { [DateTimeOffset]::new($Value.ToUniversalTime()) } else { [DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture) }
                return [TimeZoneInfo]::ConvertTime($at, $script:Rz).ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
            }
            if ($Value -is [array]) { return ($Value -join '; ') }
            if ($Value -is [long] -or $Value -is [int] -or $Value -is [double] -or $Value -is [decimal]) { return [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture) }
            $text = [string]$Value
            if ($text.Length -gt 0 -and "=+-@`t`r".Contains($text[0])) { return "'" + $text }
            return $text
        }
        function Rows($Answer, $Csv, [string[]]$Names) {
            $kinds = @{}; foreach ($c in $Answer.columns) { $kinds[$c.name] = $c.kind }
            $served = @($Answer.rows | ForEach-Object { $cells = $_.cells; @(for ($k = 0; $k -lt $Names.Count; $k++) { CsvText $cells[$k] $kinds[$Names[$k]] }) -join '|' })
            $report = @($Csv | ForEach-Object { $row = $_; @($Names | ForEach-Object { [string]$row.$_ }) -join '|' })
            return $served, $report
        }
    }

    AfterAll { if ($script:Zs) { $script:Zs.Dispose(); $script:Zs = $null } }

    It 'reads the daily tables in the report time zone, as the static report built in that zone' {
        $overview = ZJson "/api/overview/servers?$script:ZPeriod"
        $overview.firstDay | Should -BeExactly '2026-10-24'
        $overview.lastDay | Should -BeExactly '2026-10-26'
        @($overview.daily.rows | ForEach-Object { $_.cells -join '|' }) -join "`n" | Should -BeExactly (@(ZCsv 'daily' | ForEach-Object { @($_.PSObject.Properties.Value) -join '|' }) -join "`n")
        @($overview.servers.rows | ForEach-Object { "$($_.cells[0])|$($_.cells[2])|$($_.cells[3])|$($_.cells[5])|$($_.cells[9])" }) -join "`n" |
            Should -BeExactly (@($script:ZReport.ServerRows | ForEach-Object { "$($_[0])|$($_[2])|$($_[3])|$($_[5])|$($_[9])" }) -join "`n")
        # A failure at 00:30 on 26 October in Paris (23:30 UTC the day before) is recovered by a success of 27 October, the next Paris day; read in UTC days,
        # the failure is of 25 October and 27 October is not looked at.
        $requests = ZJson "/api/requests?$script:ZPeriod&size=2000"
        $expected = @(ZCsv 'issues' | ForEach-Object { "$($_.'Request ID')|$($_.Resolution)|$($_.'Recovered after')" }); [array]::Reverse($expected)
        @($requests.rows | ForEach-Object { "$($_.cells[22])|$($_.cells[20])|$($_.cells[21])" }) -join "`n" | Should -BeExactly ($expected -join "`n")
        @($requests.rows | Where-Object { $_.cells[22] -eq 'req-z1' })[0].cells[20] | Should -BeExactly 'Recovered later'
        @((ZJson "/api/requests?$script:ZPeriod&size=2000" $script:UHost).rows | Where-Object { $_.cells[22] -eq 'req-z1' })[0].cells[20] | Should -BeExactly 'Unresolved'
        # Users and operations on every list column.
        $users = ZJson "/api/users?$script:ZPeriod"
        $names = @($users.columns.name); $names.Count | Should -Be 14
        $served, $report = Rows $users (ZCsv 'users') $names
        ($served -join "`n") | Should -BeExactly ($report -join "`n")
        $operations = ZJson "/api/operations?$script:ZPeriod"
        $served, $report = Rows $operations (ZCsv 'operations') @($operations.columns.name)
        ($served -join "`n") | Should -BeExactly ($report -join "`n")
        $meta = ZJson '/api/meta'
        $meta.timeZone | Should -BeExactly 'Romance Standard Time'
        $meta.timeZoneIana | Should -BeExactly 'Europe/Paris'
        $rm = ZJson "/api/report-meta?$script:ZPeriod"
        $rm.timeZone | Should -BeExactly 'Romance Standard Time'
        $rm.timeZoneIana | Should -BeExactly 'Europe/Paris'
        $rm.periodStart | Should -BeExactly '2026-10-24 00:00'
        $rm.periodEnd | Should -BeExactly '2026-10-27 00:00'
        ($rm.notes -join ' ') | Should -Match 'Outcome in the list of client sessions is computed from the session counters'
        ((ZJson "/api/report-meta?$script:ZPeriod&user=zed").notes -join ' ') | Should -Match 'User filter: the portal matches'
    }

    It 'gives every Paris day its own pack, the 25-hour day of the change included' {
        $rm = ZJson "/api/report-meta?$script:ZPeriod"
        foreach ($set in 'sessions', 'issues', 'messages') {
            $packs = @($rm.data.files | Where-Object set -EQ $set)
            @($packs.day) -join ',' | Should -BeExactly '2026-10-26,2026-10-25,2026-10-24' -Because $set
            $middle = $packs[1]
            ([DateTimeOffset]::Parse($middle.orderFrom, [Globalization.CultureInfo]::InvariantCulture)).ToUnixTimeMilliseconds() | Should -Be (Ms '2026-10-24T22:00:00Z')
            ([DateTimeOffset]::Parse($middle.orderTo, [Globalization.CultureInfo]::InvariantCulture)).ToUnixTimeMilliseconds() | Should -Be (Ms '2026-10-25T23:00:00Z')
            ([DateTimeOffset]::Parse($packs[0].orderFrom, [Globalization.CultureInfo]::InvariantCulture)).ToUnixTimeMilliseconds() | Should -Be (Ms '2026-10-25T23:00:00Z')
        }
    }

    It 'continues a cursor across two adjacent day windows, lists nothing for a cursor outside its window and skips inside a window after a cursor' {
        $all = @((ZJson "/api/requests?$script:ZPeriod&size=2000").rows | ForEach-Object { [long]$_.id })
        $all.Count | Should -Be 4
        $packs = @((ZJson "/api/report-meta?$script:ZPeriod").data.files | Where-Object set -EQ 'issues')
        $ids = @(); $last = $null
        foreach ($p in $packs) {
            $cursor = $null
            do {
                $page = ZJson ($p.url + '&size=1' + $(if ($cursor) { "&cursor=$cursor" } else { '' }))
                $ids += @($page.rows | ForEach-Object { [long]$_.id })
                $cursor = Prop $page 'nextCursor'
                if ($cursor) { $last = @{ Cursor = $cursor; Pack = $p } }
            } while ($cursor)
            $page.exhausted | Should -BeTrue
        }
        ($ids -join ',') | Should -BeExactly ($all -join ',')
        # A cursor of 25 October in the window of 24 October: an empty page.
        $middle = $packs[1]; $oldest = $packs[-1]
        $first = ZJson ($middle.url + '&size=1')
        $outside = ZJson ($oldest.url + '&size=5&cursor=' + (Prop $first 'nextCursor'))
        @($outside.rows).Count | Should -Be 0
        $outside.exhausted | Should -BeTrue
        # skip after a cursor, inside an explicit window: the rows after the cursor, the first one passed over.
        $window = '&orderFrom=' + [Uri]::EscapeDataString('2026-10-23T22:00:00Z') + '&orderTo=' + [Uri]::EscapeDataString('2026-10-26T23:00:00Z')
        $head = ZJson "/api/requests?$script:ZPeriod&size=1"
        $after = ZJson ("/api/requests?$script:ZPeriod$window&size=5&skip=1&cursor=" + (Prop $head 'nextCursor'))
        (@($after.rows | ForEach-Object { [long]$_.id }) -join ',') | Should -BeExactly (@($all[2..3]) -join ',')
    }

    It 'takes the Outcome of the session list and of its filter from one expression of the counters, as the report reads them' {
        $sessions = ZJson "/api/sessions?$script:ZPeriod&size=500"
        $mine = @($sessions.rows | Where-Object { $_.cells[4] -eq 'sess@invalid' })
        @($mine | ForEach-Object { $_.cells[3] }) -join ',' | Should -BeExactly 'Recovered,Recovered,Intermittent errors,Failed at end,Failed,OK (slow),OK'
        foreach ($outcome in 'OK', 'OK (slow)', 'Failed', 'Failed at end', 'Intermittent errors', 'Recovered') {
            $filtered = ZJson ("/api/sessions?$script:ZPeriod&size=500&status=" + [Uri]::EscapeDataString($outcome))
            @($filtered.rows | ForEach-Object { $_.cells[3] } | Select-Object -Unique) -join ',' | Should -BeExactly $outcome -Because $outcome
            @($filtered.rows).Count | Should -Be @($sessions.rows | Where-Object { $_.cells[3] -eq $outcome }).Count -Because $outcome
        }
        # Every list column of every session equals the report's CSV; the outcomes of the list and of the report differ on at most 1 % of the sessions.
        $names = @($sessions.columns.name); $names.Count | Should -Be 26
        $served, $report = Rows $sessions (ZCsv 'sessions') $names
        [array]::Reverse($report)
        ($served -join "`n") | Should -BeExactly ($report -join "`n")
        $csv = @(ZCsv 'sessions'); [array]::Reverse($csv)
        $differ = 0; for ($k = 0; $k -lt $csv.Count; $k++) { if ($sessions.rows[$k].cells[3] -ne $csv[$k].Outcome) { $differ++ } }
        $differ / [Math]::Max(1, $csv.Count) | Should -BeLessOrEqual 0.01
    }

    It 'finds the fields of a request stored without the session user inside a window of one hour, and only there' {
        $t = Ms '2026-10-25T15:00:00Z'
        $narrow = 'from=' + [Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($t - 60000).ToString('O')) + '&to=' + [Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($t + 60000).ToString('O'))
        $wide = 'from=' + [Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($t - 7200000).ToString('O')) + '&to=' + [Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($t + 7200000).ToString('O'))
        $found = ZJson "/api/requests/req-null?$narrow&user=sess%40invalid"
        @($found.rows).Count | Should -Be 1
        $found.rows[0].cells[9] | Should -BeExactly '/owa/'
        (ZStatus "/api/requests/req-null?$narrow").Status | Should -Be 200
        (ZStatus "/api/requests/req-null?$wide&user=sess%40invalid").Status | Should -Be 404
        (ZStatus "/api/requests/req-null?$wide").Code | Should -BeExactly 'UserRequired'
        (ZStatus "/api/requests/req-z2?$narrow&user=zed%40invalid").Status | Should -Be 404
    }

    It 'reads the servers over the whole period and narrows only the daily rows with a window' {
        $whole = ZJson "/api/overview/servers?$script:ZPeriod"
        $window = '&orderFrom=' + [Uri]::EscapeDataString('2026-10-24T22:00:00Z') + '&orderTo=' + [Uri]::EscapeDataString('2026-10-25T23:00:00Z')
        $day = ZJson "/api/overview/servers?$script:ZPeriod$window"
        $day.servers | Should -BeNullOrEmpty
        @($day.daily.rows | ForEach-Object { $_.cells[0] } | Select-Object -Unique) -join ',' | Should -BeExactly '2026-10-25'
        @($day.daily.rows | ForEach-Object { $_.cells -join '|' }) -join "`n" | Should -BeExactly (@($whole.daily.rows | Where-Object { $_.cells[0] -eq '2026-10-25' } | ForEach-Object { $_.cells -join '|' }) -join "`n")
        @($whole.servers.rows).Count | Should -BeGreaterThan 0
    }

    # Last of this block: it adds mail to the store.
    It 'lists and counts the messages of the static report built in the same zone and period, and the overview counts them as its card' {
        Write-Sql $script:Zs @"
INSERT INTO message_event(time_ms,server,event_id,message_id,log_id,sender,recipients,recipient_count) VALUES
(@a,'EX1','RECEIVE','<zm1@invalid>','zm1a','zed@invalid','one@invalid',1),(@a+100,'EX1','DELIVER','<zm1@invalid>','zm1b','zed@invalid','one@invalid',1),
(@b,'EX2','RECEIVE','<zm2@invalid>','zm2a','yod@invalid','far@invalid',1),(@b+200,'EX2','SEND','<zm2@invalid>','zm2b','yod@invalid','far@invalid',1);
INSERT INTO smtp_transaction(time_ms,end_ms,server,direction,session_id,message_id,status,mail_from,rcpts) VALUES
(@a-50,@a-10,'EX1','Receive','z-tracked','<zm1@invalid>','Accepted','zed@invalid','one@invalid'),
(@a+500,@a+550,'EX1','Receive','z-accepted','<zaccepted@invalid>','Accepted','zed@invalid','one@invalid'),
(@b+500,@b+550,'EX2','Send','z-sent','<zsent@invalid>','Sent','yod@invalid','far@invalid'),
(@b+900,@b+950,'EX1','Receive','z-refused',NULL,'Rejected','spam@invalid','one@invalid');
"@ @{ a = (Ms '2026-10-25T01:30:00Z'); b = (Ms '2026-10-26T10:00:00Z') }
        Reconcile $script:Zs
        $q = [ExchangeLogReport.ReportRequest]::new()
        $q.StartMs = $script:ZFrom; $q.EndMs = $script:ZTo; $q.Detailed = $true; $q.WriteHtml = $false; $q.WriteCsv = $true
        $q.Zone = $script:Rz; $q.TimeZoneName = 'Romance Standard Time'
        $q.ConfiguredServers = [string[]]@('EX1', 'EX2'); $q.MemoryBudgetMB = 64; $q.Parallelism = 1
        $q.OutputFolder = Join-Path $script:Work 'zoned-report-messages'
        $report = [ExchangeLogReport.ReportBuilder]::Build($script:Zs, $q)
        $csv = @(Import-Csv -LiteralPath ($report.Files | Where-Object Dataset -EQ 'messages').Path -Delimiter ';')
        $list = ZJson "/api/messages?$script:ZPeriod&size=500"
        $report.Counts['messages'] | Should -Be 3
        @($list.rows).Count | Should -Be $report.Counts['messages']
        (@($list.rows | ForEach-Object { "$($_.cells[15])|$($_.cells[3])" } | Sort-Object -CaseSensitive) -join "`n") |
            Should -BeExactly (@($csv | ForEach-Object { "$($_.'Message ID')|$($_.Status)" } | Sort-Object -CaseSensitive) -join "`n")
        $counts = ZJson "/api/overview/counts?$script:ZPeriod"
        (@($counts.rows | Where-Object { $_.cells[0] -eq 'Messages' }) | ForEach-Object { [long]$_.cells[2] } | Measure-Object -Sum).Sum | Should -Be $report.Counts['messages']
        # The overview card counts the tracked messages of each server (each of these is on one server): the list without the refused mail.
        $servers = ZJson "/api/overview/servers?$script:ZPeriod"
        $at = @($servers.servers.columns.name).IndexOf('Messages')
        ($servers.servers.rows | ForEach-Object { [long]$_.cells[$at] } | Measure-Object -Sum).Sum | Should -Be @($list.rows | Where-Object { $_.cells[16] -eq 'message' }).Count
    }
}

Describe 'Serve mail flow per hour, Messages per server from the rollup, aggregate admission and the result cache' {
    BeforeAll {
        function Ms([string]$Iso) { [DateTimeOffset]::Parse($Iso, [Globalization.CultureInfo]::InvariantCulture).ToUnixTimeMilliseconds() }
        function Iso([long]$Ms) { [Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($Ms).ToString('O')) }
        function Internal([string]$Name) { [ExchangeLogReport.Store].GetField($Name, [Reflection.BindingFlags]'Static,NonPublic,Public').GetValue($null) }
        # A period with a partial hour at each end (hh:10): 26 hours before the hour of the epoch to 5 hours after it.
        $h = $script:Epoch - ($script:Epoch % 3600000)
        $script:MfFrom = $h - 26 * 3600000 + 600000; $script:MfTo = $h + 5 * 3600000 + 600000
        $from = $script:MfFrom; $to = $script:MfTo; $t = $script:Epoch
        $events = [Collections.Generic.List[string]]::new(); $smtp = [Collections.Generic.List[string]]::new()
        function Ev([long]$At, [string]$Server, [string]$Event, $Id, $Internal) {
            $events.Add("($At,'$Server','$Event',$(if ($null -eq $Id) { 'NULL' } else { "'$Id'" }),$(if ($null -eq $Internal) { 'NULL' } else { "'$Internal'" }),'mf$($events.Count)','s@invalid','r@invalid')")
        }
        function Tx([long]$At, [string]$Server, [string]$Direction, $Id, $Status) {
            $smtp.Add("($At,'$Server','$Direction','mf$($smtp.Count)',$(if ($null -eq $Id) { 'NULL' } else { "'$Id'" }),$(if ($null -eq $Status) { 'NULL' } else { "'$Status'" }),'s@invalid','r@invalid')")
        }
        # A journey inside the period, one crossing its start, one crossing its end (another spelling of EX1), one crossing both.
        Ev $t 'EX1' 'RECEIVE' '<in@invalid>' $null; Ev ($t + 1000) 'EX2' 'DELIVER' '<in@invalid>' $null
        Ev ($from - 7200000) 'EX1' 'RECEIVE' '<cross-start@invalid>' $null; Ev ($from + 300000) 'EX2' 'DELIVER' '<cross-start@invalid>' $null
        Ev ($to - 300000) 'ex1' 'RECEIVE' '<cross-end@invalid>' $null; Ev ($to + 10800000) 'EX2' 'DELIVER' '<cross-end@invalid>' $null
        Ev ($from - 3600000) 'EX1' 'RECEIVE' '<span@invalid>' $null; Ev ($t + 5000) 'EX1' 'SEND' '<span@invalid>' $null; Ev ($to + 3600000) 'EX2' 'DELIVER' '<span@invalid>' $null
        # Tracking events without Message-ID: counted by internal_id, one of which is also a Message-ID of the same server in the period.
        Ev ($t + 2000) 'EX1' 'RECEIVE' $null '42'; Ev ($t + 3000) 'EX1' 'DELIVER' $null '42'; Ev ($t + 4000) 'EX2' 'FAIL' $null '43'
        Ev ($t + 6000) 'EX1' 'FAIL' $null '<in@invalid>'; Ev ($from + 60000) 'EX2' 'DELIVER' $null '44'
        # Outside the period, in the clock hours of its two ends; an event without any identity on a server of its own.
        Ev ($from - 60000) 'EX1' 'DELIVER' '<outside1@invalid>' $null; Ev ($to + 60000) 'EX1' 'DELIVER' '<outside2@invalid>' $null
        Ev ($t + 7000) 'EX3' 'DELIVER' $null $null
        # Journeys over every hour of the period, on two spellings of EX1, with SMTP transactions.
        foreach ($i in 0..30) {
            $at = $from + 30000 + $i * 3700000
            Ev $at @('EX1', 'ex1')[$i % 2] 'RECEIVE' "<m$i@invalid>" $null; Ev ($at + 2000) 'EX2' $(if ($i % 7 -eq 0) { 'DSN' } else { 'DELIVER' }) "<m$i@invalid>" $null
            Tx ($at - 500) 'EX1' 'Receive' "<m$i@invalid>" $(if ($i % 5 -eq 0) { 'Rejected' } else { 'Accepted' })
        }
        # SMTP: two spellings of EX1, a mail-only server with two spellings, rows in the partial hours and just outside the period.
        Tx ($t - 100) 'EX1' 'Receive' '<in@invalid>' 'Accepted'; Tx ($t + 200) 'ex1' 'Receive' $null 'Rejected'
        Tx ($from + 120000) 'EDGE1' 'Receive' $null 'Accepted'; Tx ($t + 300) 'edge1' 'Send' $null 'Accepted'; Tx ($to - 120000) 'EDGE1' 'Receive' $null 'Rejected'
        Tx ($from - 30000) 'EDGE1' 'Receive' $null 'Accepted'; Tx ($to + 30000) 'EX2' 'Send' $null 'Accepted'
        # Paris 25 October 2026 (a 25-hour day) and the days around it.
        $dst = Ms '2026-10-24T20:00:00Z'
        foreach ($i in 0..40) { $at = $dst + $i * 1500000; Ev $at @('EX1', 'EX2')[$i % 2] 'RECEIVE' "<d$i@invalid>" $null; Ev ($at + 900000) 'EX2' 'DELIVER' "<d$i@invalid>" $null; Tx ($at + 100) 'EDGE1' 'Receive' $null 'Accepted' }
        $script:Mf = New-ServeStore 'mailflow'
        Write-Sql $script:Mf @"
INSERT INTO source_file(id,server,kind,path,offset,size,first_ms,last_ms,file_key) VALUES(1,'EX1','Tracking','mf1.log',1,1,@a,@b,'MF1'),(2,'EX2','Tracking','mf2.log',1,1,@a,@b,'MF2');
INSERT INTO message_event(time_ms,server,event_id,message_id,internal_id,log_id,sender,recipients) VALUES $($events -join ',');
INSERT INTO smtp_transaction(time_ms,server,direction,session_id,message_id,status,mail_from,rcpts) VALUES $($smtp -join ',');
INSERT INTO access_usage(day,server,user,protocol,mailbox,requests,successes,client_errors,server_errors,bytes_in,bytes_out,total_ms,max_ms,first_ms,last_ms,last_success_ms,last_failure_ms) VALUES
('2026-10-13','EX1','alpha@invalid','Mapi',NULL,5,5,0,0,1,1,10,5,@a+3600000,@a+7200000,@a+7200000,0),('2026-10-14','EX1','alpha@invalid','Mapi',NULL,3,2,1,0,1,1,10,5,@t,@t+1000,@t+1000,@t);
"@ @{ a = $from - 86400000; b = $to + 86400000 * 12; t = $t }
        Reconcile $script:Mf
        # The static Detailed report of the same store: UTC with partial hours, whole days of a +05:30 zone, and the Paris days of the change.
        function Mf-Report([long]$From, [long]$To, [TimeZoneInfo]$Zone, [string]$Name) {
            $q = [ExchangeLogReport.ReportRequest]::new()
            $q.StartMs = $From; $q.EndMs = $To; $q.Detailed = $true; $q.WriteHtml = $false; $q.WriteCsv = $true
            $q.Zone = $Zone; $q.TimeZoneName = $Zone.Id
            $q.ConfiguredServers = [string[]]@('EX1', 'EX2'); $q.MemoryBudgetMB = 64; $q.Parallelism = 1
            $q.OutputFolder = Join-Path $script:Work "mailflow-$Name"
            [ExchangeLogReport.ReportBuilder]::Build($script:Mf, $q)
        }
        $script:Kz = [TimeZoneInfo]::FindSystemTimeZoneById('India Standard Time')
        $script:Pz = [TimeZoneInfo]::FindSystemTimeZoneById('Romance Standard Time')
        $script:MfCases = @(
            @{ Name = 'utc'; From = $from; To = $to; Zone = [TimeZoneInfo]::Utc },
            @{ Name = 'kolkata'; From = (Ms '2026-10-12T18:30:00Z'); To = (Ms '2026-10-14T18:30:00Z'); Zone = $script:Kz },
            @{ Name = 'paris'; From = (Ms '2026-10-23T22:00:00Z'); To = (Ms '2026-10-26T23:00:00Z'); Zone = $script:Pz })
        foreach ($case in $script:MfCases) {
            $case.Report = Mf-Report $case.From $case.To $case.Zone $case.Name
            $case.Host = Start-ServeTest $script:Mf.FilePath 30 -Zone $case.Zone
            $case.Query = "from=$(Iso $case.From)&to=$(Iso $case.To)"
        }
        function MfJson($HostInfo, [string]$Path) {
            $r = Request $HostInfo $Path
            $r.StatusCode | Should -Be 200 -Because "$Path $($r.Content)"
            return $r.Content | ConvertFrom-Json -Depth 50
        }
        # The cells of an answer as the report's CSV writes them (wall-clock times of the zone), and the CSV rows, joined per row.
        function MfRows($Answer, $Csv, [TimeZoneInfo]$Zone) {
            $names = @($Csv[0].PSObject.Properties.Name)
            $kinds = @{}; foreach ($c in $Answer.columns) { $kinds[$c.name] = $c.kind }
            $text = {
                param($Value, [string]$Kind)
                if ($null -eq $Value) { return '' }
                if ($Kind -eq 'time') {
                    $at = if ($Value -is [datetime]) { [DateTimeOffset]::new($Value.ToUniversalTime()) } else { [DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture) }
                    return [TimeZoneInfo]::ConvertTime($at, $Zone).ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
                }
                if ($Value -is [long] -or $Value -is [int] -or $Value -is [double] -or $Value -is [decimal]) { return [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture) }
                return [string]$Value
            }
            $served = @($Answer.rows | ForEach-Object { $cells = $_.cells; @(for ($k = 0; $k -lt $names.Count; $k++) { & $text $cells[$k] $kinds[$names[$k]] }) -join '|' })
            $report = @($Csv | ForEach-Object { $row = $_; @($names | ForEach-Object { [string]$row.$_ }) -join '|' })
            return ($served -join "`n"), ($report -join "`n")
        }
    }

    AfterAll { if ($script:Mf) { $script:Mf.Dispose(); $script:Mf = $null } }

    It 'creates the tables and the six triggers of the mail flow per hour on a fresh store, in their canonical form' {
        $s = New-ServeStore 'mailflow-fresh'
        try {
            foreach ($table in (Internal 'MailFlowTables')) { $s.Query("SELECT sql FROM sqlite_master WHERE type='table' AND name='$($table[0])';", $null).Rows[0][0] | Should -BeExactly $table[1] }
            $triggers = @(Internal 'MailFlowTriggers')
            $triggers.Count | Should -Be 6
            foreach ($trigger in $triggers) { $s.Query("SELECT sql FROM sqlite_master WHERE type='trigger' AND name='$($trigger[0])' AND tbl_name='$($trigger[1])';", $null).Rows[0][0] | Should -BeExactly $trigger[2] }
            foreach ($name in 'ix_msg_noid_flow', 'ix_event_resolution', 'ix_usage_day_success') { $s.Scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='$name';", $null) | Should -Be 1 }
            $s.Query("SELECT sql FROM sqlite_master WHERE name='ix_rollup_last';", $null).Rows[0][0] | Should -BeExactly 'CREATE INDEX ix_rollup_last ON message_rollup(member_last_ms,member_first_ms,status,events_count,kind,direction,servers)'
            $s.Query("SELECT sql FROM sqlite_master WHERE name='ix_rollup_status_last';", $null).Rows[0][0] | Should -BeExactly 'CREATE INDEX ix_rollup_status_last ON message_rollup(status,member_last_ms,member_first_ms,events_count,kind,direction,servers)'
        } finally { $s.Dispose() }
    }

    It 'keeps mail_flow_hour equal to the rows on the collector path, triggers off and on, with an empty queue' -ForEach @(@{ TriggersOff = $true }, @{ TriggersOff = $false }) {
        $s = New-ServeStore "mailflow-collector-$TriggersOff"
        try {
            $tracking = Join-Path $script:Work "mailflow-tracking-$TriggersOff"; [void][IO.Directory]::CreateDirectory($tracking)
            [IO.File]::WriteAllLines((Join-Path $tracking 'tracking.log'), @(
                '#Fields: date-time,event-id,message-id,internal-message-id,log-id,sender-address,recipient-address'
                '2026-10-14T05:10:00.000Z,RECEIVE,<c1@invalid>,1,c1a,sender@invalid,r@invalid'
                '2026-10-14T05:20:00.000Z,DELIVER,<c1@invalid>,1,c1b,sender@invalid,r@invalid'
                '2026-10-14T07:20:00.000Z,RECEIVE,,2,c2a,sender@invalid,r@invalid'
                '2026-10-14T07:21:00.000Z,FAIL,<c3@invalid>,3,c3a,sender@invalid,r@invalid'
            ))
            [void](Collect-Tracking $s $tracking $true $TriggersOff)
            $s.Scalar('SELECT COUNT(*) FROM mail_flow_dirty;', $null) | Should -Be 0
            $rows = $s.Query('SELECT hour_ms,server,tracking,deliveries,failures,messages FROM mail_flow_hour ORDER BY hour_ms;', $null).Rows
            @($rows | ForEach-Object { "$($_[0])|$($_[1])|$($_[2])|$($_[3])|$($_[4])|$($_[5])" }) -join ',' |
                Should -BeExactly "$(Ms '2026-10-14T05:00:00Z')|EX1|2|1|0|1,$(Ms '2026-10-14T07:00:00Z')|EX1|2|0|1|2"
            $receipt = $s.VerifyServeRollups()
            $receipt.MailFlowVerified | Should -BeTrue
            $receipt.MailFlowRows | Should -Be 2
        } finally { $s.Dispose() }
    }

    It 'queues the old and the new bucket of every external write and answers MailFlowPending until the reconciliation' {
        $s = New-ServeStore 'mailflow-external'; Add-Mail $s
        try {
            $h = Start-ServeTest $s.FilePath 30
            (Request $h "/api/overview/servers?$script:Period").StatusCode | Should -Be 200
            $hour = $script:Epoch - ($script:Epoch % 3600000)
            # A tracking event without Message-ID queues no rollup key: only its mail flow bucket waits.
            Write-Sql $s "INSERT INTO message_event(time_ms,server,event_id,internal_id,log_id) VALUES(@t,'EX1','DELIVER','77','ext-1');" @{ t = $script:Epoch + 7200000 }
            @($s.Query('SELECT hour_ms,server FROM mail_flow_dirty;', $null).Rows | ForEach-Object { "$($_[0])|$($_[1])" }) -join ',' | Should -BeExactly "$($hour + 7200000)|EX1"
            $r = Request $h "/api/overview/servers?$script:Period"
            $r.StatusCode | Should -Be 503
            ($r.Content | ConvertFrom-Json).error.code | Should -BeExactly 'MailFlowPending'
            $r.Headers['Retry-After'][0] | Should -BeExactly '1'
            Write-Sql $s "UPDATE message_event SET server='EX7',time_ms=@t WHERE log_id='ext-1';" @{ t = $script:Epoch + 3 * 3600000 }
            @($s.Query('SELECT hour_ms,server FROM mail_flow_dirty ORDER BY hour_ms;', $null).Rows | ForEach-Object { "$($_[0])|$($_[1])" }) -join ',' | Should -BeExactly "$($hour + 7200000)|EX1,$($hour + 10800000)|EX7"
            $tx = $s.Begin(); try { $s.ReconcileMailFlow($tx); $tx.Commit() } finally { $tx.Dispose() }
            $s.Scalar("SELECT COUNT(*) FROM mail_flow_hour WHERE server='EX7' AND tracking=1;", $null) | Should -Be 1
            (Request $h "/api/overview/servers?$script:Period").StatusCode | Should -Be 200
            Write-Sql $s "DELETE FROM message_event WHERE log_id='ext-1';"
            @($s.Query('SELECT hour_ms,server FROM mail_flow_dirty;', $null).Rows | ForEach-Object { "$($_[0])|$($_[1])" }) -join ',' | Should -BeExactly "$($hour + 10800000)|EX7"
            # SMTP transactions: an update of the server queues both buckets, a delete the old one (the other queues are drained by the same call).
            Write-Sql $s "UPDATE smtp_transaction SET server='EX5' WHERE session_id='smtp-case';"
            Write-Sql $s "DELETE FROM smtp_transaction WHERE session_id='smtp-refused';"
            $keys = @($s.Query('SELECT server FROM mail_flow_dirty ORDER BY server;', $null).Rows | ForEach-Object { $_[0] }) -join ','
            $keys | Should -BeExactly 'EX1,EX5,EX7'
            Reconcile $s
            $s.Scalar('SELECT COUNT(*) FROM mail_flow_dirty;', $null) | Should -Be 0
            $s.Scalar("SELECT COUNT(*) FROM mail_flow_hour WHERE server='EX7';", $null) | Should -Be 0
            $s.Scalar("SELECT smtp_in FROM mail_flow_hour WHERE server='EX5';", $null) | Should -Be 1
            $s.VerifyServeRollups().MailFlowVerified | Should -BeTrue
            (Request $h "/api/overview/servers?$script:Period").StatusCode | Should -Be 200
        } finally { $s.Dispose() }
    }

    It 'deletes the whole hours before the retention cutoff and recomputes the hour the cutoff cuts from what remains' {
        $s = New-ServeStore 'mailflow-retention'
        try {
            $hour = $script:Epoch - ($script:Epoch % 3600000)
            Write-Sql $s @"
INSERT INTO message_event(time_ms,server,event_id,message_id,log_id) VALUES(@h-10500000,'EX1','RECEIVE','<r1@invalid>','r1'),(@h-3000000,'EX1','DELIVER','<r2@invalid>','r2'),(@h-600000,'EX1','DELIVER','<r3@invalid>','r3'),(@h+60000,'EX1','DELIVER','<r4@invalid>','r4');
INSERT INTO smtp_transaction(time_ms,server,direction,session_id,status) VALUES(@h-2400000,'EX1','Receive','r-smtp','Accepted'),(@h-900000,'EX1','Send','r-smtp2','Accepted');
"@ @{ h = $hour }
            Reconcile $s
            $s.Scalar('SELECT COUNT(*) FROM mail_flow_hour;', $null) | Should -Be 3
            # The cutoff at hh:30 of the hour before the epoch's: the events at hh:10 and the SMTP transaction at hh:20 go, those at hh:45 and hh:50 stay.
            $cutoff = $hour - 1800000
            [void]$s.Purge($cutoff, '2000-01-01', $cutoff)
            $s.Scalar('SELECT COUNT(*) FROM mail_flow_dirty;', $null) | Should -Be 0
            @($s.Query('SELECT hour_ms,tracking,deliveries,messages,smtp_in,smtp_out FROM mail_flow_hour ORDER BY hour_ms;', $null).Rows | ForEach-Object { $_ -join '|' }) -join ',' |
                Should -BeExactly "$($hour - 3600000)|1|1|1|0|1,$hour|1|1|1|0|0"
            $s.VerifyServeRollups().MailFlowVerified | Should -BeTrue
        } finally { $s.Dispose() }
    }

    It 'answers the servers and daily datasets of the static report, cell for cell (<Name>)' -ForEach @(@{ Name = 'utc' }, @{ Name = 'kolkata' }, @{ Name = 'paris' }) {
        $case = $script:MfCases | Where-Object { $_.Name -eq $Name }
        $overview = MfJson $case.Host "/api/overview/servers?$($case.Query)"
        $csv = @(Import-Csv -LiteralPath ($case.Report.Files | Where-Object Dataset -EQ 'servers').Path -Delimiter ';')
        $served, $report = MfRows $overview.servers $csv $case.Zone
        $served | Should -BeExactly $report
        $csv = @(Import-Csv -LiteralPath ($case.Report.Files | Where-Object Dataset -EQ 'daily').Path -Delimiter ';')
        $served, $report = MfRows $overview.daily $csv $case.Zone
        $served | Should -BeExactly $report
        @($overview.daily.rows).Count | Should -BeGreaterThan 3
        # The same answer with the hourly table and with the live statements alone (a user filter matching every row reads the rows of the whole period).
        $live = MfJson $case.Host "/api/overview/servers?$($case.Query)&user=%40invalid"
        $whole = MfJson $case.Host "/api/overview/servers?$($case.Query)"
        $at = @($whole.servers.columns.name).IndexOf('Messages')
        @($live.servers.rows | ForEach-Object { @($_.cells[0], $_.cells[10..15]) -join '|' }) -join "`n" | Should -BeExactly (@($whole.servers.rows | ForEach-Object { @($_.cells[0], $_.cells[10..15]) -join '|' }) -join "`n")
        if ($Name -eq 'utc') {
            # The journeys crossing a bound count for the servers of their events inside the period only, an internal_id that is also a Message-ID once.
            $ex1 = @($whole.servers.rows | Where-Object { $_.cells[0] -eq 'EX1' })[0]
            [long]$ex1.cells[$at] | Should -Be (1 + 1 + 1 + 31 + 1)
            @($whole.servers.rows | ForEach-Object { $_.cells[0] }) -join ',' | Should -BeExactly 'EX1,EX2,EDGE1,EX3'
        }
    }

    It 'narrows the daily rows with a window and keeps the servers of the whole period' {
        $case = $script:MfCases | Where-Object { $_.Name -eq 'utc' }
        $whole = MfJson $case.Host "/api/overview/servers?$($case.Query)"
        $day = MfJson $case.Host "/api/overview/servers?$($case.Query)&orderFrom=$(Iso ($script:MfTo - 86400000))&orderTo=$(Iso $script:MfTo)"
        $day.servers | Should -BeNullOrEmpty
        @($day.daily.rows).Count | Should -BeGreaterThan 0
        @($day.daily.rows | ForEach-Object { $_.cells[0] } | Select-Object -Unique) -join ',' | Should -BeExactly '2026-10-13,2026-10-14'
        @($whole.daily.rows).Count | Should -BeGreaterOrEqual @($day.daily.rows).Count
    }

    It 'refuses a store of the step-2 shape with MigrationRequired, folds it at one writable open, then answers' {
        $s = New-ServeStore 'mailflow-step2'; Add-Mail $s
        $path = $s.FilePath
        $expected = (Request $script:Http "/api/overview/servers?$script:Period").Content
        [ServeFixtures]::ConvertToTrackedSchema12($s)
        $s.Dispose()
        $h = Start-ServeTest $path
        $r = Request $h "/api/overview/servers?$script:Period"
        $r.StatusCode | Should -Be 422
        ($r.Content | ConvertFrom-Json).error.code | Should -BeExactly 'MigrationRequired'
        $s = [ExchangeLogReport.Store]::new($path, $false, 'synthetic')
        try {
            $s.Query("SELECT sql FROM sqlite_master WHERE name='ix_rollup_last';", $null).Rows[0][0] | Should -BeExactly 'CREATE INDEX ix_rollup_last ON message_rollup(member_last_ms,member_first_ms,status,events_count,kind,direction,servers)'
            $s.Scalar("SELECT COUNT(*) FROM sqlite_master WHERE name IN('ix_msg_noid_flow','ix_event_resolution','ix_usage_day_success','mail_flow_hour','mail_flow_dirty') OR (type='trigger' AND name LIKE 'tr_%_flow_%');", $null) | Should -Be 11
            $s.VerifyServeRollups().MailFlowVerified | Should -BeTrue
        } finally { $s.Dispose() }
        $r = Request $h "/api/overview/servers?$script:Period"
        $r.StatusCode | Should -Be 200
        $r.Content | Should -BeExactly $expected
    }

    It 'reads the Messages per server of the rollup, the unresolved failures and the last successes of a request page from the index entries alone' {
        $plans = @([ExchangeLogReport.ServeDiagnostics]::ExplainReportDatasets($script:Mf.FilePath, $script:MfFrom, $script:MfTo, $null, $null) | ConvertFrom-Json)
        $inside = @($plans | Where-Object { $_ -like 'SELECT r.servers, COUNT(*) FROM message_rollup r INDEXED BY ix_rollup_last*' })
        $inside.Count | Should -Be 1
        $inside[0] | Should -Match 'SEARCH r USING COVERING INDEX ix_rollup_last \(member_last_ms>\? AND member_last_ms<\?\)'
        $inside[0] | Should -Not -Match 'TEMP B-TREE FOR ORDER BY'
        @($plans | Where-Object { $_ -like '*FROM mail_flow_hour*' }).Count | Should -Be 2
        foreach ($entry in @($plans | Where-Object { $_ -like '*FROM mail_flow_hour*' })) { $entry | Should -Match 'SEARCH mail_flow_hour USING PRIMARY KEY \(hour_ms>\? AND hour_ms<\?\)' }
        @($plans | Where-Object { $_ -like '*INDEXED BY ix_msg_noid_flow*' })[0] | Should -Match 'SEARCH e USING (COVERING )?INDEX ix_msg_noid_flow \(time_ms>\? AND time_ms<\?\)'
        @($plans | Where-Object { $_ -like 'SELECT e.time_ms,e.server,e.protocol,e.user,e.outcome,e.recovered_ms FROM access_event e INDEXED BY ix_event_resolution*' })[0] | Should -Match 'SEARCH e USING COVERING INDEX ix_event_resolution \(time_ms>\? AND time_ms<\?\)'
        @($plans | Where-Object { $_ -like 'SELECT user, protocol, day, last_success_ms FROM access_usage INDEXED BY ix_usage_day_success*' })[0] | Should -Match 'SEARCH access_usage USING COVERING INDEX ix_usage_day_success \(day>\? AND day<\?\)'
        # The resolution of each row of a page of the failed requests: one seek of the index entries per user, protocol and day, no row read.
        @($plans | Where-Object { $_ -like 'SELECT COALESCE(MAX(last_success_ms),0) FROM access_usage*' })[0] | Should -Match 'SEARCH access_usage USING COVERING INDEX ix_usage_day_success \(day=\? AND user=\? AND protocol=\?\)'
    }

    It 'answers a repeated aggregate from the result cache until another connection commits' {
        $s = New-ServeStore 'mailflow-cache'; Add-Mail $s
        try {
            $h = Start-ServeTest $s.FilePath 30
            foreach ($path in "/api/overview/servers?$script:Period", "/api/users?$script:Period", "/api/operations?$script:Period") {
                $first = Request $h $path; $second = Request $h $path
                $first.StatusCode | Should -Be 200; $second.StatusCode | Should -Be 200
                ($first.Content | ConvertFrom-Json).cached | Should -BeFalse -Because $path
                ($second.Content | ConvertFrom-Json).cached | Should -BeTrue -Because $path
                $second.Content.Replace('{"cached":true,', '{"cached":false,') | Should -BeExactly $first.Content
            }
            # The same parameters in another order are the same request.
            $reordered = 'to=' + ($script:Period -split '&to=')[1] + '&' + ($script:Period -split '&to=')[0]
            ((Request $h "/api/overview/servers?$reordered").Content | ConvertFrom-Json).cached | Should -BeTrue
            Write-Sql $s "INSERT INTO metadata(key,value) VALUES('cache-test','1');"
            ((Request $h "/api/overview/servers?$script:Period").Content | ConvertFrom-Json).cached | Should -BeFalse
            ((Request $h "/api/overview/servers?$script:Period").Content | ConvertFrom-Json).cached | Should -BeTrue
            # Lists and the report description are never cached.
            (Request $h "/api/messages?$script:Period").Content | Should -Not -Match '"cached"'
        } finally { $s.Dispose() }
    }

    It 'admits at most MaxConcurrency - 2 aggregate requests: a third one is 429 Busy while a list page still answers' {
        $s = New-ServeStore 'mailflow-admission'; Add-Mail $s
        $client = [Net.Http.HttpClient]::new()
        try {
            $n = 1000000
            do {
                $n *= 2
                $clock = [Diagnostics.Stopwatch]::StartNew()
                [void]$s.Scalar("WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<$n) SELECT SUM(i) FROM n;", $null)
            } while ($clock.Elapsed.TotalSeconds -lt 1.5 -and $n -lt 512000000)
            $day = [DateTimeOffset]::FromUnixTimeMilliseconds($script:Epoch).UtcDateTime.ToString('yyyy-MM-dd')
            $s.Exec("INSERT INTO access_action(day,server,protocol,action,requests,failures,slow,total_ms,max_ms) VALUES('$day','EX1','Mapi','Execute',1,0,0,1,1); ALTER TABLE access_action RENAME TO access_action_base; CREATE VIEW access_action AS SELECT b.* FROM access_action_base b CROSS JOIN (WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<$n) SELECT SUM(i) FROM n);")
            $h = Start-ServeTest $s.FilePath 60 -Concurrency 4
            [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('X-Portal-Token', $h.Token)
            $held = @(1, 2 | ForEach-Object { $client.GetAsync($h.Url + "/api/operations?from=2026-10-14T00%3A00%3A00Z&to=2026-10-1$($_ + 4)T00%3A00%3A00Z") })
            Start-Sleep -Milliseconds 700
            @($held | Where-Object IsCompleted).Count | Should -Be 0
            $busy = Request $h "/api/operations?$script:Period"
            $busy.StatusCode | Should -Be 429
            $busy.Headers['Retry-After'][0] | Should -BeExactly '1'
            ($busy.Content | ConvertFrom-Json).error.code | Should -BeExactly 'Busy'
            (Request $h "/api/authentication?$script:Period").StatusCode | Should -Be 429
            # The report description is a light request at admission: the page can start while two aggregates hold their workers.
            (Request $h "/api/report-meta?$script:Period").StatusCode | Should -Be 200
            $clock = [Diagnostics.Stopwatch]::StartNew()
            (Request $h "/api/messages?$script:Period").StatusCode | Should -Be 200
            (Request $h "/api/sessions?$script:Period").StatusCode | Should -Be 200
            @($held | Where-Object IsCompleted).Count | Should -Be 0 -Because 'the lists answered while both aggregates were held'
            foreach ($task in $held) { [int]$task.GetAwaiter().GetResult().StatusCode | Should -Be 200 }
            (Request $h "/api/operations?$script:Period").StatusCode | Should -Be 200
        } finally { $client.Dispose(); $s.Dispose() }
    }

    It 'keeps serving after a client leaves before the answer of an aggregate (<Case>)' -ForEach @(@{ Case = 'cancelled while it computes' }, @{ Case = 'closed while the answer is read' }) {
        $s = New-ServeStore ('mailflow-left-' + $Case.Split(' ')[0]); Add-Mail $s
        $client = [Net.Http.HttpClient]::new()
        try {
            $wait = 1
            if ($Case -like 'cancelled*') {
                # The operations read a slow view: the request is still computing when its client cancels it, and writes its answer afterwards.
                $n = 1000000
                do {
                    $n *= 2
                    $clock = [Diagnostics.Stopwatch]::StartNew()
                    [void]$s.Scalar("WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<$n) SELECT SUM(i) FROM n;", $null)
                } while ($clock.Elapsed.TotalSeconds -lt 1.5 -and $n -lt 512000000)
                $wait = [Math]::Ceiling($clock.Elapsed.TotalSeconds * 4) + 2
                $day = [DateTimeOffset]::FromUnixTimeMilliseconds($script:Epoch).UtcDateTime.ToString('yyyy-MM-dd')
                $s.Exec("INSERT INTO access_action(day,server,protocol,action,requests,failures,slow,total_ms,max_ms) VALUES('$day','EX1','Mapi','Execute',1,0,0,1,1); ALTER TABLE access_action RENAME TO access_action_base; CREATE VIEW access_action AS SELECT b.* FROM access_action_base b CROSS JOIN (WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<$n) SELECT SUM(i) FROM n);")
            }
            $h = Start-ServeTest $s.FilePath 60 -Concurrency 4
            [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('X-Portal-Token', $h.Token)
            if ($Case -like 'cancelled*') {
                $cancel = [Threading.CancellationTokenSource]::new()
                $pending = $client.GetAsync($h.Url + "/api/operations?$script:Period", $cancel.Token)
                Start-Sleep -Milliseconds 300
                $pending.IsCompleted | Should -BeFalse -Because 'the aggregate is still computing'
                $cancel.Cancel()
                try { [void]$pending.GetAwaiter().GetResult() } catch { }
            } else {
                $answer = $client.GetAsync($h.Url + "/api/users?$script:Period", [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                $answer.Dispose()
            }
            # The abandoned request ends (its answer finds the connection closed); the host answers the next requests.
            Start-Sleep -Seconds $wait
            $h.Task.IsCompleted | Should -BeFalse -Because 'one failed answer does not stop the host'
            (Request $h '/api/meta').StatusCode | Should -Be 200
            (Request $h "/api/messages?$script:Period").StatusCode | Should -Be 200
            (Request $h "/api/operations?$script:Period").StatusCode | Should -Be 200
        } finally { $client.Dispose(); $s.Dispose() }
    }

    It 'admits at most MaxConcurrency - 1 requests of the list layer, and ends the scans of clients that have gone at once' {
        $s = New-ServeStore 'lists-admission'; Add-Mail $s; Add-SlowRequests $s
        $client = [Net.Http.HttpClient]::new()
        $cancel = [Threading.CancellationTokenSource]::new()
        try {
            $h = Start-ServeTest $s.FilePath 15 -Concurrency 4
            [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('X-Portal-Token', $h.Token)
            $slots = [ServeHttpTestClient]::Admission($h.Task)
            # A count of the requests filtered on the sub-status scans the IIS status rows (a slow view): each one holds its worker.
            $day = '&orderFrom=2026-10-14T00%3A00%3A00Z&orderTo=2026-10-15T00%3A00%3A00Z'
            $scan = "/api/requests/count?$script:Period$day&f.Sub-status=%3E0"
            $held = @(1..3 | ForEach-Object { $client.GetAsync($h.Url + $scan, $cancel.Token) })
            $clock = [Diagnostics.Stopwatch]::StartNew()
            while ($slots.CurrentCount -ne 1) { $clock.Elapsed.TotalSeconds | Should -BeLessThan 5; Start-Sleep -Milliseconds 5 }
            foreach ($path in $scan, "/api/sessions/facets?$script:Period$day&columns=Protocol", "/api/sessions?$script:Period&f.User=alpha", "/api/messages?$script:Period&m.Status=Delivered") {
                $busy = Request $h $path
                $busy.StatusCode | Should -Be 429 -Because $path
                $busy.Headers['Retry-After'][0] | Should -BeExactly '1'
                $answer = ($busy.Content | ConvertFrom-Json).error
                $answer.code | Should -BeExactly 'Busy'
                $answer.message | Should -BeExactly 'Counts, value lists and filtered list pages are at their concurrency limit; retry explicitly.'
            }
            # One worker is left for the unfiltered pages, the details and the report description.
            foreach ($path in "/api/sessions?$script:Period", "/api/sessions/1?$script:Period", "/api/report-meta?$script:Period", '/api/meta') {
                # The worker of the previous answer is released just after its last byte: the next request waits for it, as a client that reads its answer does.
                $clock.Restart(); while ($slots.CurrentCount -ne 1) { $clock.Elapsed.TotalSeconds | Should -BeLessThan 5; Start-Sleep -Milliseconds 5 }
                (Request $h $path).StatusCode | Should -Be 200 -Because $path
            }
            @($held | Where-Object IsCompleted).Count | Should -Be 0
            # The clients leave: the scans end at the next look-up of their connections instead of reading on.
            $cancel.Cancel()
            foreach ($task in $held) { try { [void]$task.GetAwaiter().GetResult() } catch { } }
            $clock.Restart()
            while ($slots.CurrentCount -ne 4) { $clock.Elapsed.TotalSeconds | Should -BeLessThan 2 -Because 'a scan whose client has gone releases its worker'; Start-Sleep -Milliseconds 10 }
            $count = Request $h "/api/requests/count?$script:Period$day&f.URL=ews"
            $count.StatusCode | Should -Be 200
            $h.Task.IsCompleted | Should -BeFalse
        } finally { $cancel.Dispose(); $client.Dispose(); $s.Dispose() }
    }

    It 'ends the stream of an export when its client leaves, and when no page comes for the request deadline' {
        $s = New-ServeStore 'export-left'; Add-Mail $s; Add-SlowRequests $s
        $client = [Net.Http.HttpClient]::new()
        try {
            $h = Start-ServeTest $s.FilePath 5 -Concurrency 4
            $slots = [ServeHttpTestClient]::Admission($h.Task)
            # The failed requests of the period read the IIS status rows (a slow view): the first page of the export is still being read.
            $ticket = { (Invoke-WebRequest -Uri "$($h.Url)/api/export/ticket" -Method Post -Headers @{ 'X-Portal-Token' = $h.Token } -ContentType 'application/json' `
                -Body (@{ view = 'issues'; query = $script:Period } | ConvertTo-Json -Compress)).Content | ConvertFrom-Json }
            $t = & $ticket
            $answer = $client.GetAsync($h.Url + $t.url, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            [int]$answer.StatusCode | Should -Be 200
            $answer.Content.Headers.ContentType.MediaType | Should -BeExactly 'text/csv'
            $slots.CurrentCount | Should -Be 3 -Because 'the export holds one worker'
            # The client leaves: the export ends at the next look-up of its connection instead of reading on.
            $answer.Dispose()
            $clock = [Diagnostics.Stopwatch]::StartNew()
            while ($slots.CurrentCount -ne 4) { $clock.Elapsed.TotalSeconds | Should -BeLessThan 3 -Because 'an export whose client has gone releases its worker'; Start-Sleep -Milliseconds 10 }
            # A client that stays: no page for the deadline of 5 s (the stall watchdog), and the stream is cut, never completed.
            $t = & $ticket
            $answer = $client.GetAsync($h.Url + $t.url, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            $reader = [IO.StreamReader]::new($answer.Content.ReadAsStream())
            $clock.Restart()
            { [void]$reader.ReadToEnd() } | Should -Throw
            $clock.Elapsed.TotalSeconds | Should -BeGreaterThan 3
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 20
            $answer.Dispose()
            $clock.Restart()
            while ($slots.CurrentCount -ne 4) { $clock.Elapsed.TotalSeconds | Should -BeLessThan 3; Start-Sleep -Milliseconds 10 }
            $h.Task.IsCompleted | Should -BeFalse
            (Request $h '/api/meta').StatusCode | Should -Be 200
        } finally { $client.Dispose(); $s.Dispose() }
    }

    It 'streams one export at a time: a second download waits for its deadline and is refused, while the overview and the refusals of a download answer' {
        $s = New-ServeStore 'export-one'; Add-Mail $s
        # Failed requests whose IIS status rows are read through a view that takes about a quarter of a second for each statement: with pages of one
        # row, their export writes a page every moment and streams for longer than the deadline of a request without reaching its stall watchdog.
        $n = 100000
        do {
            $n *= 2
            $clock = [Diagnostics.Stopwatch]::StartNew()
            [void]$s.Scalar("WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<$n) SELECT SUM(i) FROM n;", $null)
        } while ($clock.Elapsed.TotalSeconds -lt 0.25 -and $n -lt 512000000)
        $events = @(foreach ($i in 1..40) { "($($script:Epoch + $i * 1000),'EX1','Synthetic','Mapi','s@invalid','Slow','one-$i')" }) -join ','
        $status = @(foreach ($i in 1..40) { "('EX1','one-$i',$($script:Epoch + $i * 1000),500)" }) -join ','
        $s.Exec("INSERT INTO access_event(time_ms,server,source,protocol,user,outcome,request_id) VALUES $events; INSERT INTO iis_status(server,request_id,time_ms,status) VALUES $status;" +
            "ALTER TABLE iis_status RENAME TO iis_status_base; CREATE VIEW iis_status AS SELECT b.* FROM iis_status_base b CROSS JOIN (WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<$n) SELECT SUM(i) FROM n);")
        $field = [ExchangeLogReport.ServeHost].GetField('ExportPageRows', [Reflection.BindingFlags]'Static,NonPublic,Public')
        $pageRows = $field.GetValue($null)
        $client = [Net.Http.HttpClient]::new()
        try {
            $field.SetValue($null, 1)
            $h = Start-ServeTest $s.FilePath 6 -Concurrency 4
            $ticket = { ((Invoke-WebRequest -Uri "$($h.Url)/api/export/ticket" -Method Post -Headers @{ 'X-Portal-Token' = $h.Token } -ContentType 'application/json' `
                -Body (@{ view = 'issues'; query = $script:Period } | ConvertTo-Json -Compress)).Content | ConvertFrom-Json).url }
            $a = & $ticket; $b = & $ticket
            $first = $client.GetAsync($h.Url + $a, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            [int]$first.StatusCode | Should -Be 200
            $read = $first.Content.ReadAsStringAsync()
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $second = $client.GetAsync($h.Url + $b)
            # Meanwhile an aggregate admission is free for the overview, and a download refused for its ticket or its origin is answered without waiting.
            (Request $h "/api/overview/servers?$script:Period").StatusCode | Should -Be 200
            $quick = [Diagnostics.Stopwatch]::StartNew()
            (Invoke-WebRequest -Uri "$($h.Url)/api/export/$('a' * 64).csv" -SkipHttpErrorCheck -TimeoutSec 15).StatusCode | Should -Be 404
            (Invoke-WebRequest -Uri ($h.Url + $b) -Headers @{ Origin = 'http://evil.example' } -SkipHttpErrorCheck -TimeoutSec 15).StatusCode | Should -Be 403
            $quick.Elapsed.TotalSeconds | Should -BeLessThan 2
            $refused = $second.GetAwaiter().GetResult()
            [int]$refused.StatusCode | Should -Be 429
            ($refused.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json).error.message | Should -BeExactly 'The export waited for the other requests of the portal: export the view again in a moment.'
            $clock.Elapsed.TotalSeconds | Should -BeGreaterThan 5.5
            $read.IsCompleted | Should -BeFalse -Because 'the first export still streams'
            @($read.GetAwaiter().GetResult().Substring(1) -split "`r`n" | Where-Object { $_ }).Count | Should -Be 41
            # The refused download spent nothing: once the first export has ended, the second ticket exports its selection.
            $again = $client.GetAsync($h.Url + $b).GetAwaiter().GetResult()
            [int]$again.StatusCode | Should -Be 200
            $again.Dispose(); $first.Dispose(); $refused.Dispose()
            $h.Task.IsCompleted | Should -BeFalse
        } finally { $field.SetValue($null, $pageRows); $client.Dispose(); $s.Dispose() }
    }

    It 'refuses a store whose mail flow trigger was dropped with ShapeRequired, rebuilds the table at one writable open, then answers' {
        $s = New-ServeStore 'mailflow-trigger'; Add-Mail $s
        $path = $s.FilePath
        $s.Exec('DROP TRIGGER tr_message_event_flow_insert;')
        # A tracking event without Message-ID queues no rollup key: with the trigger gone, nothing queues its hour.
        Write-Sql $s "INSERT INTO message_event(time_ms,server,event_id,internal_id,log_id) VALUES(@t,'EX1','DELIVER','78','gone-1');" @{ t = $script:Epoch + 100 }
        $s.Scalar('SELECT COUNT(*) FROM mail_flow_dirty;', $null) | Should -Be 0
        $s.Dispose()
        $h = Start-ServeTest $path
        $r = Request $h "/api/overview/servers?$script:Period"
        $r.StatusCode | Should -Be 422
        ($r.Content | ConvertFrom-Json).error.code | Should -BeExactly 'ShapeRequired'
        $s = [ExchangeLogReport.Store]::new($path, $false, 'synthetic')
        try {
            $s.Scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name LIKE 'tr_%_flow_%';", $null) | Should -Be 6
            $s.VerifyServeRollups().MailFlowVerified | Should -BeTrue
            $deliveries = [long]$s.Scalar("SELECT COUNT(*) FROM message_event WHERE server='EX1' COLLATE NOCASE AND event_id='DELIVER' AND time_ms>=@f AND time_ms<@t;", @{ f = [DateTimeOffset]::Parse('2026-10-14T00:00:00Z').ToUnixTimeMilliseconds(); t = [DateTimeOffset]::Parse('2026-10-16T00:00:00Z').ToUnixTimeMilliseconds() })
        } finally { $s.Dispose() }
        $r = Request $h "/api/overview/servers?$script:Period"
        $r.StatusCode | Should -Be 200
        $ex1 = @(($r.Content | ConvertFrom-Json).servers.rows | Where-Object { $_.cells[0] -eq 'EX1' })[0]
        [long]$ex1.cells[14] | Should -Be $deliveries
    }

    It 'names a server seen only in its tracking events by its smallest spelling, where the static report keeps the spelling it reads first' {
        $s = New-ServeStore 'mailflow-spelling'
        try {
            $t = $script:Epoch
            Write-Sql $s @"
INSERT INTO message_event(time_ms,server,event_id,message_id,log_id,sender,recipients) VALUES
(@t,'trk9','RECEIVE','<sp1@invalid>','sp1','s@invalid','r@invalid'),(@t+1000,'TRK9','DELIVER','<sp1@invalid>','sp2','s@invalid','r@invalid'),
(@t+2000,'TRK9','RECEIVE','<sp2@invalid>','sp3','s@invalid','r@invalid'),(@t+3000,'trk9','DELIVER','<sp2@invalid>','sp4','s@invalid','r@invalid');
"@ @{ t = $t }
            Reconcile $s
            $from = $t - ($t % 86400000); $to = $from + 86400000
            $q = [ExchangeLogReport.ReportRequest]::new()
            $q.StartMs = $from; $q.EndMs = $to; $q.Detailed = $true; $q.WriteHtml = $false; $q.WriteCsv = $true; $q.Zone = [TimeZoneInfo]::Utc; $q.TimeZoneName = 'UTC'
            $q.ConfiguredServers = [string[]]@('EX1'); $q.MemoryBudgetMB = 64; $q.Parallelism = 1; $q.OutputFolder = Join-Path $script:Work 'mailflow-spelling-report'
            $report = [ExchangeLogReport.ReportBuilder]::Build($s, $q)
            $h = Start-ServeTest $s.FilePath 30
            $overview = MfJson $h "/api/overview/servers?from=$(Iso $from)&to=$(Iso $to)"
            $csv = @(Import-Csv -LiteralPath ($report.Files | Where-Object Dataset -EQ 'servers').Path -Delimiter ';')
            $served = @($overview.servers.rows | Where-Object { $_.cells[0] -ieq 'trk9' })[0]
            $static = @($csv | Where-Object { $_.Server -ieq 'trk9' })[0]
            # The documented difference (Guide 15.2): the casing of the name only; every figure is the same.
            $served.cells[0] | Should -BeExactly 'TRK9'
            $static.Server | Should -BeExactly 'trk9'
            [string]$served.cells[13] | Should -BeExactly $static.Messages
            [string]$served.cells[14] | Should -BeExactly $static.Deliveries
        } finally { $s.Dispose() }
    }
}
Describe 'Serve keyset lists, counts, value lists and the filters of the page' {
    BeforeAll {
        # Two UTC days (13 and 14 October 2026) of client sessions (two per start time), messages (two tracking events each) and failed requests.
        $script:D0 = [DateTimeOffset]::Parse('2026-10-14T00:00:00Z', [Globalization.CultureInfo]::InvariantCulture).ToUnixTimeMilliseconds()
        $script:Ks = New-ServeStore 'keyset'
        Write-Sql $script:Ks @"
WITH RECURSIVE n(i) AS (VALUES(0) UNION ALL SELECT i+1 FROM n WHERE i<3999)
INSERT INTO client_session(skey,day,start_ms,end_ms,user,protocol,front_ends,back_ends,user_agent,client_ip,requests,successes,failures,slow,first_success_ms,last_success_ms,first_failure_ms,last_failure_ms,total_ms,max_ms,bytes_in,bytes_out,auth_modes)
SELECT 'k'||i,'2026-10-14',@a+(i/2)*86000,@a+(i/2)*86000+(i%7)*60000,CASE WHEN i%11=0 THEN 'USER'||(i%37) WHEN i%37=36 THEN char(304)||'STANBUL' ELSE 'user'||(i%37) END,
 CASE i%4 WHEN 0 THEN 'Mapi' WHEN 1 THEN 'Ews' WHEN 2 THEN 'Owa' ELSE 'Eas' END,CASE i%3 WHEN 0 THEN 'EX1' WHEN 1 THEN 'EX1,EX2' ELSE 'EX2' END,'EX3',
 CASE i%3 WHEN 0 THEN 'Microsoft Office/16.0 (Windows NT 10.0; Microsoft Outlook 16.0.17928)' WHEN 1 THEN 'Mozilla/5.0' ELSE 'Apple-iPhone/1.0' END,'10.0.0.'||(i%9),
 i%10,i%10-(CASE WHEN i%5=0 AND i%10>0 THEN 1 ELSE 0 END),CASE WHEN i%5=0 AND i%10>0 THEN 1 ELSE 0 END,CASE WHEN i%9=0 THEN 1 ELSE 0 END,
 @a+(i/2)*86000,@a+(i/2)*86000+1000,CASE WHEN i%5=0 THEN @a+(i/2)*86000+500 ELSE 0 END,CASE WHEN i%5=0 THEN @a+(i/2)*86000+500 ELSE 0 END,100,50,0,0,
 CASE WHEN i%20=0 THEN 'OAuth=5;Basic=1' WHEN i%4=3 THEN 'Basic='||(i%10+1) WHEN i%4=2 THEN 'FBA='||(i%10+1) WHEN i%13=1 THEN NULL ELSE 'Negotiate='||(i%10+1) END FROM n;
WITH RECURSIVE n(i) AS (VALUES(0) UNION ALL SELECT i+1 FROM n WHERE i<2999)
INSERT INTO message_event(time_ms,server,event_id,message_id,log_id,sender,recipients,subject,recipient_count)
SELECT @a+i*57000+500,'EX1','RECEIVE',CASE WHEN i=7 THEN '<M7@Invalid>' ELSE '<m'||i||'@invalid>' END,'a'||i,CASE WHEN i%17=0 THEN 'ALPHA'||(i%13)||'@invalid' ELSE 'alpha'||(i%13)||'@invalid' END,'r'||(i%5)||'@invalid;s@invalid','subject '||(i%23),(i%3)+1 FROM n
UNION ALL SELECT @a+i*57000+1500,'EX2',CASE WHEN i%9=0 THEN 'FAIL' ELSE 'DELIVER' END,CASE WHEN i=7 THEN '<M7@Invalid>' ELSE '<m'||i||'@invalid>' END,'b'||i,'alpha'||(i%13)||'@invalid','r'||(i%5)||'@invalid',NULL,1 FROM n;
WITH RECURSIVE n(i) AS (VALUES(0) UNION ALL SELECT i+1 FROM n WHERE i<2499)
INSERT INTO access_event(time_ms,server,source,protocol,user,client_ip,user_agent,method,url,action,status,outcome,request_id)
SELECT @a+i*69000+7,CASE i%2 WHEN 0 THEN 'EX1' ELSE 'EX2' END,'HttpProxy',CASE i%4 WHEN 0 THEN 'Mapi' WHEN 1 THEN 'Owa' WHEN 2 THEN 'Ews' ELSE 'Eas' END,'user'||(i%29),'10.0.0.1','Mozilla/5.0','POST',
 CASE i%3 WHEN 0 THEN '/owa/service.svc' WHEN 1 THEN '/EWS/Exchange.asmx' ELSE '/mapi/emsmdb/' END,'Execute',CASE i%4 WHEN 0 THEN 500 WHEN 1 THEN 400 WHEN 2 THEN 200 ELSE 503 END,
 CASE WHEN i%50=0 THEN 'Success' WHEN i%4=0 THEN 'ServerError' WHEN i%4=1 THEN 'ClientError' WHEN i%4=2 THEN 'Slow' ELSE 'ServerError' END,'q'||i FROM n;
"@ @{ a = $script:D0 - 86400000 }
        Reconcile $script:Ks
        function KSha([string]$Path) { $s = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite'); try { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($s)) } finally { $s.Dispose() } }
        $script:KsHash = KSha $script:Ks.FilePath
        $script:KsHost = Start-ServeTest $script:Ks.FilePath 30
        function KIso([long]$Ms) { [Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($Ms).ToString('O')) }
        $script:KsPeriod = "from=$(KIso ($script:D0 - 86400000))&to=$(KIso ($script:D0 + 86400000))"
        # The two day packs of the period: the older day open below, the newer open above.
        $script:KsDays = @("&orderFrom=$(KIso $script:D0)", "&orderTo=$(KIso $script:D0)")
        $script:KsPaths = @{ sessions = '/api/sessions'; messages = '/api/messages'; issues = '/api/requests' }
        $script:KsTables = @{ sessions = 'client_session c'; messages = 'message_rollup r'; issues = 'access_event e' }
        function KJson([string]$Path, $HostInfo = $script:KsHost) {
            $r = Request $HostInfo $Path
            $r.StatusCode | Should -Be 200 -Because "$Path $($r.Content)"
            return $r.Content | ConvertFrom-Json -Depth 50
        }
        function KStatus([string]$Path) { $r = Request $script:KsHost $Path; [pscustomobject]@{ Status = $r.StatusCode; Code = $(if ($r.StatusCode -ne 200) { ($r.Content | ConvertFrom-Json).error.code }); Message = $(if ($r.StatusCode -ne 200) { ($r.Content | ConvertFrom-Json).error.message }) } }
        function KProp($Object, [string]$Name) { $p = $Object.PSObject.Properties[$Name]; if ($p) { $p.Value } }
        # Every id of a list request, page after page (a scan that stops on its budget continues from nextCursor).
        function KAll([string]$Path, [string]$Query, [int]$Size = 97, $HostInfo = $script:KsHost) {
            $ids = [Collections.Generic.List[long]]::new(); $cursor = $null; $pages = 0
            do {
                $page = KJson ("${Path}?$Query&size=$Size" + $(if ($cursor) { "&cursor=$cursor" } else { '' })) $HostInfo
                foreach ($row in @($page.rows)) { $ids.Add([long]$row.id) }
                $cursor = KProp $page 'nextCursor'; $pages++
                if ($pages -gt 2000) { throw 'Too many pages.' }
            } while ($cursor)
            $page.exhausted | Should -BeTrue
            return ,$ids.ToArray()
        }
        function KQuery([hashtable]$Params) { (@($Params.Keys | Sort-Object | ForEach-Object { [Uri]::EscapeDataString($_) + '=' + [Uri]::EscapeDataString([string]$Params[$_]) })) -join '&' }
        # The exact count of every day pack with its histogram, a scan continued from scannedTo.
        function KCount([string]$Path, [string]$Query, $HostInfo = $script:KsHost) {
            $total = 0L; $partial = 0
            foreach ($day in $script:KsDays) {
                $cursor = $null
                do {
                    $c = KJson ("$Path/count?$Query$day" + $(if ($cursor) { "&cursor=$cursor" } else { '' })) $HostInfo
                    $sum = 0L; foreach ($b in @($c.buckets)) { $sum += [long]$b[1] }
                    $sum | Should -Be ([long]$c.total)
                    $total += [long]$c.total
                    $cursor = if ($c.complete) { $null } else { $partial++; $c.scannedTo }
                } while ($cursor)
            }
            return [pscustomobject]@{ Total = $total; Partial = $partial }
        }
        $script:Cases = @((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Serve.FilterCases.json') -Raw | ConvertFrom-Json -AsHashtable).cases)
        # An export ticket of a list for a query (POST /api/export/ticket with the token), and the download of a ticket's address (no token).
        function KTicket([string]$View, [string]$Query, $HostInfo = $script:KsHost, [string]$Token = $HostInfo.Token) {
            Invoke-WebRequest -Uri "$($HostInfo.Url)/api/export/ticket" -Method Post -Headers @{ 'X-Portal-Token' = $Token } -ContentType 'application/json' `
                -Body (@{ view = $View; query = $Query } | ConvertTo-Json -Compress) -SkipHttpErrorCheck -TimeoutSec 15
        }
        function KDownload([string]$Url, $HostInfo = $script:KsHost) { Invoke-WebRequest -Uri ($HostInfo.Url + $Url) -SkipHttpErrorCheck -TimeoutSec 60 }
        # The rows of an exported CSV (the byte order mark first, then the header line).
        function KCsvRows($Answer) {
            $text = [Text.Encoding]::UTF8.GetString($Answer.RawContentStream.ToArray())
            $text[0] | Should -Be ([char]0xFEFF)
            $text.EndsWith("`r`n") | Should -BeTrue
            @(($text.Substring(1) -split "`r`n") | Where-Object { $_ } | ConvertFrom-Csv -Delimiter ';')
        }
        if (-not ('ServeTicketClock' -as [type])) {
            Add-Type -TypeDefinition 'public static class ServeTicketClock { public static long Offset; public static long Now() { return System.Environment.TickCount64 + Offset; } }'
        }
        $script:TicketType = [ExchangeLogReport.ServeHost].Assembly.GetType('ExchangeLogReport.ServeExportTicket')
        $script:ExportRowsField = [ExchangeLogReport.ServeHost].GetField('ExportPageRows', [Reflection.BindingFlags]'Static,NonPublic,Public')
        # Three failed requests of 14 October whose IIS status rows are read through a slow view (a recursive sum that takes at least 300 ms on
        # this computer): every statement of a scan that reads their sub-status takes longer than the shortest budget of 100 ms, so a scan in
        # chunks of one row answers after each chunk, whatever the speed of the computer. The view is not an object of the shape Serve requires.
        $script:KsSlow = New-ServeStore 'keyset-slow'; Add-Mail $script:KsSlow
        $n = 500000
        do {
            $n *= 2
            $clock = [Diagnostics.Stopwatch]::StartNew()
            [void]$script:KsSlow.Scalar("WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<$n) SELECT SUM(i) FROM n;", $null)
        } while ($clock.Elapsed.TotalMilliseconds -lt 300 -and $n -lt 512000000)
        $script:KsSlow.Exec("INSERT INTO access_event(time_ms,server,source,protocol,user,outcome,request_id) VALUES($script:Epoch,'EX1','Synthetic','Mapi','s@invalid','ServerError','slow-1')," +
            "($($script:Epoch + 60000),'EX1','Synthetic','Ews','s@invalid','ServerError','slow-2'),($($script:Epoch + 120000),'EX2','Synthetic','Ews','s@invalid','Slow','slow-3');" +
            "INSERT INTO iis_status(server,request_id,time_ms,status,sub_status) VALUES('EX1','slow-1',$script:Epoch,500,2),('EX2','slow-3',$($script:Epoch + 120000),500,5);" +
            "ALTER TABLE iis_status RENAME TO iis_status_base;" +
            "CREATE VIEW iis_status AS SELECT b.* FROM iis_status_base b CROSS JOIN (WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<$n) SELECT SUM(i) FROM n);")
        $script:KsSlowHost = Start-ServeTest $script:KsSlow.FilePath 30
        # The requests of the slow view with a sub-status: slow-1 and slow-3, newest first.
        $script:KsSlowQuery = "$script:KsPeriod&f.Sub-status=%3E0&budgetMs=100"
        $script:KsSlowIds = @('slow-3', 'slow-1' | ForEach-Object { [long]$script:KsSlow.Scalar("SELECT id FROM access_event WHERE request_id='$_';", $null) })
    }

    AfterAll {
        if ($script:Ks) { $script:Ks.Dispose(); $script:Ks = $null }
        if ($script:KsSlow) { $script:KsSlow.Dispose(); $script:KsSlow = $null }
    }

    It 'pages <View> with a keyset cursor, newest and oldest first, across the day boundary and day by day' -ForEach @(@{ View = 'sessions' }, @{ View = 'messages' }, @{ View = 'issues' }) {
        $path = $script:KsPaths[$View]
        $f = $script:D0 - 86400000; $t = $script:D0 + 86400000
        $expected = @(switch ($View) {
            'sessions' { $script:Ks.Query('SELECT id FROM client_session NOT INDEXED WHERE start_ms<@t AND end_ms>=@f ORDER BY start_ms DESC,id DESC;', @{ f = $f; t = $t }).Rows | ForEach-Object { [long]$_[0] } }
            'messages' { $script:Ks.Query('SELECT id FROM message_rollup NOT INDEXED WHERE kind=0 AND events_count>0 AND member_last_ms>=@f AND member_first_ms<@t ORDER BY member_last_ms DESC,id DESC;', @{ f = $f; t = $t }).Rows | ForEach-Object { [long]$_[0] } }
            'issues' { $script:Ks.Query("SELECT id FROM access_event NOT INDEXED WHERE time_ms>=@f AND time_ms<@t AND outcome<>'Success' ORDER BY time_ms DESC,id DESC;", @{ f = $f; t = $t }).Rows | ForEach-Object { [long]$_[0] } }
        })
        $expected.Count | Should -BeGreaterThan 2000
        (KAll $path $script:KsPeriod) -join ',' | Should -BeExactly ($expected -join ',')
        $ascending = [long[]](KAll $path "$script:KsPeriod&dir=asc" 131); [array]::Reverse($ascending)
        $ascending -join ',' | Should -BeExactly ($expected -join ',')
        $byDay = @(); foreach ($day in $script:KsDays) { $byDay += KAll $path ($script:KsPeriod + $day) 500 }
        $byDay -join ',' | Should -BeExactly ($expected -join ',')
        # skip inside a window: the rows after the skipped ones, in order.
        $window = "&orderFrom=$(KIso $f)&orderTo=$(KIso $t)"
        (@((KJson "${path}?$script:KsPeriod$window&skip=1000&size=3").rows | ForEach-Object { [long]$_.id }) -join ',') | Should -BeExactly (($expected[1000..1002]) -join ',')
        $page = KJson "${path}?$script:KsPeriod$window&skip=1000&size=3"
        $page.skipped | Should -Be 1000
        $page.PSObject.Properties.Name | Should -Not -Contain 'page'
    }

    It 'refuses the parameters a keyset list, a count or value lists do not take' {
        $p = $script:KsPeriod
        (KStatus "/api/sessions?$p&skip=3").Code | Should -BeExactly 'SkipWindow'
        (KStatus "/api/messages?$p&page=1&cursor=1.1").Code | Should -BeExactly 'InvalidParameter'
        (KStatus "/api/sessions?$p&size=2001").Status | Should -Be 400
        (KStatus "/api/messages?$p&page=1&size=501").Status | Should -Be 400
        (KStatus "/api/sessions/count?$p").Code | Should -BeExactly 'WindowRequired'
        (KStatus "/api/requests/facets?$p").Code | Should -BeExactly 'WindowRequired'
        (KStatus "/api/sessions?$p&f.Nope=1").Code | Should -BeExactly 'InvalidParameter'
        (KStatus "/api/sessions?$p&f.User=a&f.User=b").Code | Should -BeExactly 'InvalidParameter'
        $bad = KStatus "/api/sessions?$p&f.Requests=abc"
        $bad.Code | Should -BeExactly 'InvalidFilter'
        $bad.Message | Should -BeExactly 'Requests: A number is expected: 5000, >5000, >=10, <3, <=3, 100..200, =0, !=0.'
        (KStatus "/api/sessions?$p&f.Start=2026-13-01").Message | Should -BeLike 'Start: A time is expected*'
        (KStatus "/api/sessions?$p&f.User=!").Message | Should -BeExactly 'User: Some text is expected after !.'
        (KStatus "/api/sessions?$p&x.Protocol=2").Code | Should -BeExactly 'InvalidFilter'
        (KStatus "/api/sessions/count?$p$($script:KsDays[0])&bucketMs=999").Status | Should -Be 400
        (KStatus "/api/sessions/facets?$p$($script:KsDays[0])&columns=Requests").Code | Should -BeExactly 'InvalidParameter'
        (KStatus "/api/sessions/facets?$p$($script:KsDays[0])&columns=Nope").Message | Should -BeExactly 'columns must name text or list columns of the view.'
        # The columns of value lists are checked by their names, not by a length: every text column of the sessions, named twice (more than 256 characters).
        $all = @('Duration','Outcome','User','Protocol','Client','Client IP','Front ends','Back ends','Operations','Last error','Software','Client mode','Device ID','Mailbox','First error','User agent') -join '|'
        ("$all|$all").Length | Should -BeGreaterThan 256
        (KStatus "/api/sessions/facets?$p$($script:KsDays[0])&columns=$([Uri]::EscapeDataString("$all|$all"))").Status | Should -Be 200
        # A window with one bound reads at most 25 hours of the period too: the newest day may omit orderTo, a longer part of the period is refused.
        $long = "from=$(KIso ($script:D0 - 6 * 86400000))&to=$(KIso ($script:D0 + 86400000))"
        (KStatus "/api/sessions/count?$long&orderFrom=$(KIso ($script:D0 - 5 * 86400000))").Code | Should -BeExactly 'WindowRequired'
        (KStatus "/api/messages/facets?$long&orderTo=$(KIso $script:D0)&columns=Status").Code | Should -BeExactly 'WindowRequired'
        (KStatus "/api/sessions/count?$long&orderFrom=$(KIso $script:D0)").Status | Should -Be 200
        (KStatus "/api/sessions/facets?$p$($script:KsDays[0])&cap=301").Status | Should -Be 400
        # A cursor outside its order window lists nothing.
        $empty = KJson "/api/sessions?$p$($script:KsDays[0])&cursor=$($script:D0 - 1000).1"
        @($empty.rows).Count | Should -Be 0
        $empty.exhausted | Should -BeTrue
    }

    It 'counts every day exactly, with a histogram whose buckets sum to the total, and the value lists of the rows' {
        foreach ($view in 'sessions', 'messages', 'issues') {
            $path = $script:KsPaths[$view]
            $count = KCount $path $script:KsPeriod
            $count.Total | Should -Be (KAll $path $script:KsPeriod 2000).Count -Because $view
            $count.Partial | Should -Be 0 -Because "an unfiltered $view count reads the index"
            foreach ($day in $script:KsDays) {
                $fine = KJson "$path/count?$script:KsPeriod$day&bucketMs=60000"
                $coarse = KJson "$path/count?$script:KsPeriod$day"
                $fine.total | Should -Be $coarse.total
                @($fine.buckets).Count | Should -BeGreaterThan @($coarse.buckets).Count
                foreach ($b in @($coarse.buckets)) { [long]$b[0] % 900000 | Should -Be 0 }
            }
        }
        # The Status list of the messages, from the index, day by day: summed over the days of the period, the status counts of the overview.
        $byStatus = @{}
        foreach ($day in $script:KsDays) {
            $status = KJson "/api/messages/facets?$script:KsPeriod$day&columns=Status|Direction"
            foreach ($v in @($status.columns.Status)) { $byStatus[$v[0]] = [long]$byStatus[$v[0]] + [long]$v[1] }
        }
        $overview = @((KJson "/api/overview/counts?$script:KsPeriod").rows | Where-Object { $_.cells[0] -eq 'Messages' } | ForEach-Object { "$($_.cells[1])=$($_.cells[2])" }) -join ','
        @($byStatus.Keys | Sort-Object | ForEach-Object { "$_=$($byStatus[$_])" }) -join ',' | Should -BeExactly $overview
        $byStatus.Count | Should -Be 2
        # Value lists from the cells: the parts of a joined list, a list over its cap in truncated.
        $facets = KJson "/api/sessions/facets?$script:KsPeriod$($script:KsDays[1])&columns=Protocol|Front ends|User"
        @($facets.columns.Protocol | ForEach-Object { $_[0] }) -join ',' | Should -BeExactly 'Eas,Ews,Mapi,Owa'
        # The authentication types of the sessions: each part of a joined cell counted once, the empty cell left out.
        $auth = KJson "/api/sessions/facets?$script:KsPeriod$($script:KsDays[1])&columns=Authentication"
        @($auth.columns.Authentication | ForEach-Object { $_[0] } | Sort-Object) -join ',' | Should -BeExactly 'Basic,Forms,Negotiate,OAuth'
        foreach ($v in @($auth.columns.Authentication)) {
            (KJson "/api/sessions/count?$script:KsPeriod$($script:KsDays[1])&m.Authentication=$([Uri]::EscapeDataString($v[0]))").total | Should -Be ([long]$v[1]) -Because $v[0]
        }
        @($facets.columns.'Front ends' | ForEach-Object { $_[0] }) -join ',' | Should -BeExactly 'EX1,EX2'
        @($facets.truncated) | Should -Contain 'User'
        $capped = KJson "/api/sessions/facets?$script:KsPeriod$($script:KsDays[1])&columns=Protocol&cap=3"
        @($capped.truncated) -join ',' | Should -BeExactly 'Protocol'
        $total = 0L; foreach ($v in @($facets.columns.Protocol)) { $total += [long]$v[1] }
        $total | Should -Be (KJson "/api/sessions/count?$script:KsPeriod$($script:KsDays[1])").total
    }

    It 'selects with each filter of the page the rows the template''s expressions select (<Name>)' -ForEach @(
        (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Serve.FilterCases.json') -Raw | ConvertFrom-Json -AsHashtable).cases | ForEach-Object { @{ Name = "$($_.view) $(($_.params.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')"; Case = $_ } }) {
        $view = $Case.view; $path = $script:KsPaths[$view]
        $base = [long[]](KAll $path $script:KsPeriod 2000)
        $alias = $script:KsTables[$view]
        $selected = [Collections.Generic.HashSet[long]]::new()
        foreach ($row in $script:Ks.Query("SELECT $($alias.Split(' ')[1]).id FROM $alias WHERE $($Case.sql);", $null).Rows) { [void]$selected.Add([long]$row[0]) }
        $expected = @($base | Where-Object { $selected.Contains($_) })
        $expected.Count | Should -BeGreaterThan 0 -Because 'every case selects some rows'
        $expected.Count | Should -BeLessThan $base.Count -Because 'every case leaves some rows out'
        $query = "$script:KsPeriod&" + (KQuery $Case.params)
        (KAll $path $query 500) -join ',' | Should -BeExactly ($expected -join ',')
        (KCount $path $query).Total | Should -Be $expected.Count
    }

    It 'scans under its budget: a count answers what it counted, and continues from scannedTo to the exact total' {
        $field = [ExchangeLogReport.ServeHost].Assembly.GetType('ExchangeLogReport.ServeRead').GetField('ChunkRows', [Reflection.BindingFlags]'Static,NonPublic,Public')
        $chunk = $field.GetValue($null)
        try {
            $field.SetValue($null, 1)
            $expected = [long]$script:Ks.Scalar("SELECT COUNT(*) FROM client_session WHERE instr(lower(user),'user1')>0 AND start_ms<@t AND end_ms>=@f;", @{ f = $script:D0 - 86400000; t = $script:D0 + 86400000 })
            $query = "$script:KsPeriod&f.User=user1&budgetMs=100"
            # In one answer or in several, the answers continued from scannedTo add up to the exact total.
            (KCount '/api/sessions' $query).Total | Should -Be $expected
            # Each chunk of one slow request takes longer than the budget: the count of 14 October answers after each of its three requests, and the
            # answers continued from scannedTo add up to the exact total.
            $count = KCount '/api/requests' $script:KsSlowQuery $script:KsSlowHost
            $count.Partial | Should -Be 3 -Because 'each chunk of one row takes longer than 100 ms'
            $count.Total | Should -Be 2
            $first = KJson "/api/requests/count?$script:KsSlowQuery$($script:KsDays[0])" $script:KsSlowHost
            $first.complete | Should -BeFalse
            $first.scannedTo | Should -Match '^\d+\.\d+$'
            $first.budgetMs | Should -Be 100
            # A list scan stops at its budget with fewer rows than its size and continues to the same rows as one answer.
            (KAll '/api/sessions' $query 2000).Count | Should -Be $expected
            $partial = KJson "/api/requests?$script:KsSlowQuery&size=2000" $script:KsSlowHost
            $partial.complete | Should -BeFalse
            $partial.nextCursor | Should -BeExactly $partial.scannedTo
            (KAll '/api/requests' $script:KsSlowQuery 2000 $script:KsSlowHost) -join ',' | Should -BeExactly ($script:KsSlowIds -join ',')
            # A filtered page without budgetMs has the budget of a page; a count keeps the budget of Serve.
            (KJson "/api/sessions?$script:KsPeriod&f.User=user1&size=1").budgetMs | Should -Be 500
            (KJson "/api/sessions/count?$script:KsPeriod$($script:KsDays[1])&f.User=user1&budgetMs=100").budgetMs | Should -Be 100
            # A page ends on its last row: its cursor is that row, the next one is read by the next page.
            $one = KJson "/api/sessions?$script:KsPeriod&f.User=user1&size=1"
            @($one.rows).Count | Should -Be 1
            $one.complete | Should -BeTrue
            $one.hasMore | Should -BeTrue
            $one.nextCursor | Should -BeExactly ("$([DateTimeOffset]::Parse($one.rows[0].cells[0], [Globalization.CultureInfo]::InvariantCulture).ToUnixTimeMilliseconds()).$($one.rows[0].id)")
            # Value lists stopped by their budget continue from scannedTo: summed over the answers, the lists of one complete answer, the columns
            # counted per group (Protocol) as the columns counted from the cells (Client IP).
            $sum = @{}; $cursor = $null; $answers = 0
            do {
                $f = KJson ("/api/sessions/facets?$script:KsPeriod$($script:KsDays[1])&columns=Protocol|Client%20IP&budgetMs=100" + $(if ($cursor) { "&cursor=$cursor" } else { '' }))
                foreach ($c in 'Protocol', 'Client IP') { foreach ($v in @($f.columns.$c)) { $sum["$c=$($v[0])"] = [long]$sum["$c=$($v[0])"] + [long]$v[1] } }
                $cursor = if ($f.complete) { $null } else { $f.scannedTo }
            } while ($cursor)
            # The value lists of the slow requests of 14 October answer after each chunk of one row, the fourth answer complete.
            $slowSum = @{}; $cursor = $null
            do {
                $f = KJson ("/api/requests/facets?$script:KsSlowQuery$($script:KsDays[0])&columns=Protocol|Server" + $(if ($cursor) { "&cursor=$cursor" } else { '' })) $script:KsSlowHost
                foreach ($c in 'Protocol', 'Server') { foreach ($v in @($f.columns.$c)) { $slowSum["$c=$($v[0])"] = [long]$slowSum["$c=$($v[0])"] + [long]$v[1] } }
                $cursor = if ($f.complete) { $null } else { $f.scannedTo }; $answers++
            } while ($cursor)
            $answers | Should -Be 4 -Because 'each chunk of one row takes longer than 100 ms'
            @($slowSum.Keys | Sort-Object | ForEach-Object { "$_ $($slowSum[$_])" }) -join ',' | Should -BeExactly 'Protocol=Ews 1,Protocol=Mapi 1,Server=EX1 1,Server=EX2 1'
        } finally { $field.SetValue($null, $chunk) }
        $whole = KJson "/api/sessions/facets?$script:KsPeriod$($script:KsDays[1])&columns=Protocol|Client%20IP"
        $whole.complete | Should -BeTrue
        $expected = @{}; foreach ($c in 'Protocol', 'Client IP') { foreach ($v in @($whole.columns.$c)) { $expected["$c=$($v[0])"] = [long]$v[1] } }
        @($sum.Keys | Sort-Object | ForEach-Object { "$_ $($sum[$_])" }) -join ',' | Should -BeExactly (@($expected.Keys | Sort-Object | ForEach-Object { "$_ $($expected[$_])" }) -join ',')
    }

    It 'reads the pages, the counts and the chunk boundaries through the key indexes, and the seek filters through their own index' {
        $q = $script:KsPeriod + $script:KsDays[1]
        foreach ($case in @(@{ View = 'sessions'; Index = 'ix_session_time' }, @{ View = 'messages'; Index = 'ix_rollup_last' }, @{ View = 'issues'; Index = 'ix_event_time' })) {
            $plans = @([ExchangeLogReport.ServeDiagnostics]::ExplainKeyset($script:Ks.FilePath, $case.View, $q + '&cursor=1792000000000.5') | ConvertFrom-Json)
            $plans.Count | Should -Be 3
            $plans[0] | Should -Match "SEARCH \w USING (COVERING )?INDEX $($case.Index) \("
            $plans[0] | Should -Not -Match 'TEMP B-TREE FOR ORDER BY'
            $plans[1] | Should -Match "SEARCH \w USING (COVERING )?INDEX $($case.Index) \("
            $plans[2] | Should -Match "SEARCH \w USING COVERING INDEX $($case.Index) \("
            $plans[2] | Should -Not -Match 'TEMP B-TREE'
        }
        ([ExchangeLogReport.ServeDiagnostics]::ExplainKeyset($script:Ks.FilePath, 'messages', $q + '&f.Message%20ID=%3D%3Cm5%40invalid%3E') | ConvertFrom-Json)[0] | Should -Match 'SEARCH r USING INDEX sqlite_autoindex_message_rollup_1 \(kind=\? AND identity=\?\)'
        ([ExchangeLogReport.ServeDiagnostics]::ExplainKeyset($script:Ks.FilePath, 'sessions', $q + '&m.User=user3') | ConvertFrom-Json)[0] | Should -Match 'SEARCH c USING INDEX ix_session_user \(user=\? AND start_ms>\? AND start_ms<\?\)'
        ([ExchangeLogReport.ServeDiagnostics]::ExplainKeyset($script:Ks.FilePath, 'issues', $q + '&m.User=user3') | ConvertFrom-Json)[0] | Should -Match 'SEARCH e USING INDEX ix_event_user \(user=\? AND time_ms>\? AND time_ms<\?\)'
        ([ExchangeLogReport.ServeDiagnostics]::ExplainKeyset($script:Ks.FilePath, 'messages', $q + '&m.Status=Failed') | ConvertFrom-Json)[1] | Should -Match 'COVERING INDEX ix_rollup_last'
    }

    It 'builds the cells it tests column by column exactly as the lists build their rows' {
        $f = $script:D0 - 86400000; $t = $script:D0 + 86400000
        @([ExchangeLogReport.ServeDiagnostics]::CompareListCells($script:Ks.FilePath, $f, $t, [TimeZoneInfo]::Utc) | ConvertFrom-Json) | Should -BeNullOrEmpty
        @([ExchangeLogReport.ServeDiagnostics]::CompareListCells($script:HttpStore.FilePath, $script:Epoch - 5 * 86400000, $script:Epoch + 86400000, [TimeZoneInfo]::Utc) | ConvertFrom-Json) | Should -BeNullOrEmpty
    }

    It 'keeps a complete count and value lists in the result cache, never a partial one' {
        $q = "/api/requests/count?$script:KsPeriod$($script:KsDays[0])&f.URL=ews"
        (KJson $q).cached | Should -BeFalse
        (KJson $q).cached | Should -BeTrue
        $v = "/api/sessions/facets?$script:KsPeriod$($script:KsDays[0])&columns=Protocol|Client%20IP"
        (KJson $v).complete | Should -BeTrue
        (KJson $v).cached | Should -BeTrue
        $field = [ExchangeLogReport.ServeHost].Assembly.GetType('ExchangeLogReport.ServeRead').GetField('ChunkRows', [Reflection.BindingFlags]'Static,NonPublic,Public')
        $chunk = $field.GetValue($null)
        try {
            $field.SetValue($null, 1)
            # The first chunk of one slow request takes longer than the budget: the count and the value lists are partial, and neither is kept.
            foreach ($p in "/api/requests/count?$script:KsSlowQuery$($script:KsDays[0])", "/api/requests/facets?$script:KsSlowQuery$($script:KsDays[0])&columns=Protocol") {
                $a = KJson $p $script:KsSlowHost; $b = KJson $p $script:KsSlowHost
                $a.complete | Should -BeFalse -Because $p
                $b.complete | Should -BeFalse -Because $p
                $b.cached | Should -BeFalse -Because $p
            }
        } finally { $field.SetValue($null, $chunk) }
    }

    It 'answers an exact Message-ID stored in no spelling with no row and exactMiss, and searches every row only when the request asks for it (anyCase)' {
        $p = "$script:KsPeriod&f.Message%20ID=$([Uri]::EscapeDataString('=<M7@INVALID>'))"
        foreach ($day in $script:KsDays) {
            $miss = KJson "/api/messages/count?$p$day"
            $miss.total | Should -Be 0
            $miss.exactMiss | Should -BeTrue
            $miss.complete | Should -BeTrue
        }
        $page = KJson "/api/messages?$p&size=10"
        @($page.rows).Count | Should -Be 0
        $page.exactMiss | Should -BeTrue
        $page.exhausted | Should -BeTrue
        # The stored spelling is <M7@Invalid>: the scan of every row finds it in any case, as the page does on the rows it holds.
        (KCount '/api/messages' "$p&anyCase=1").Total | Should -Be 1
        @(KAll '/api/messages' "$p&anyCase=1" 500).Count | Should -Be 1
        $found = KJson "/api/messages/count?$script:KsPeriod&f.Message%20ID=$([Uri]::EscapeDataString('=<m5@invalid>'))$($script:KsDays[1])"
        $found.PSObject.Properties.Name | Should -Not -Contain 'exactMiss'
        (KStatus "/api/messages?$p&anyCase=2").Code | Should -BeExactly 'InvalidParameter'
    }

    It 'streams the selection of a single-use export ticket day by day, in the list order, with the grid columns of the page (<Dir>)' -ForEach @(@{ Dir = 'desc' }, @{ Dir = 'asc' }) {
        $rows = $script:ExportRowsField.GetValue($null)
        try {
            # Pages of 97 rows: every day of the export is read in several keyset pages.
            $script:ExportRowsField.SetValue($null, 97)
            $query = "$script:KsPeriod&f.User=user1&dir=$Dir"
            $issued = KTicket 'sessions' $query
            $issued.StatusCode | Should -Be 200 -Because $issued.Content
            $t = $issued.Content | ConvertFrom-Json
            $t.ticket | Should -Match '^[0-9a-f]{64}$'
            $t.expiresInSeconds | Should -Be 60
            $t.url | Should -BeExactly "/api/export/$($t.ticket).csv"
            $answer = KDownload $t.url
            $answer.StatusCode | Should -Be 200
            $answer.Headers['Content-Type'][0] | Should -BeExactly 'text/csv; charset=utf-8'
            $answer.Headers['Content-Disposition'][0] | Should -BeExactly 'attachment; filename="sessions-2026-10-13-2026-10-14.csv"'
            $csv = KCsvRows $answer
            $grid = @((KJson "/api/report-meta?$script:KsPeriod").datasets.sessions.columns | Where-Object grid | ForEach-Object name)
            @($csv[0].PSObject.Properties.Name) -join '|' | Should -BeExactly ($grid -join '|')
            $expected = [long[]](KAll '/api/sessions' "$script:KsPeriod&f.User=user1" 500)
            if ($Dir -eq 'asc') { [array]::Reverse($expected) }
            @($csv | ForEach-Object { [long]($_.'Session ID' -replace ',', '') }) -join ',' | Should -BeExactly ($expected -join ',')
            @($csv | Where-Object { $_.User -notmatch 'user1' }).Count | Should -Be 0
            $first = KJson "/api/sessions/$($expected[0])?$script:KsPeriod"
            $start = [DateTimeOffset]::Parse($first.cells[$first.columns.name.IndexOf('Start')], [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
            $csv[0].Start | Should -BeExactly $start.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
            # Single use: the ticket is gone once presented.
            (KDownload $t.url).StatusCode | Should -Be 404
        } finally { $script:ExportRowsField.SetValue($null, $rows) }
    }

    It 'binds an export ticket to the query it was issued for, and refuses a query the list refuses' {
        $t = (KTicket 'issues' "$script:KsPeriod&f.Protocol=owa").Content | ConvertFrom-Json
        # Parameters on the download are refused, and so are another method and a body: none of them spends the ticket (a download manager that
        # probes the address with HEAD leaves it valid), and it exports the selection it was issued for, once.
        $other = KDownload "$($t.url)?f.Protocol=ews"
        $other.StatusCode | Should -Be 400
        ($other.Content | ConvertFrom-Json).error.code | Should -BeExactly 'InvalidParameter'
        (Invoke-WebRequest -Uri ($script:KsHost.Url + $t.url) -Method Head -SkipHttpErrorCheck -TimeoutSec 15).StatusCode | Should -Be 405
        (Invoke-WebRequest -Uri ($script:KsHost.Url + $t.url) -Method Post -Body 'x' -ContentType 'text/plain' -SkipHttpErrorCheck -TimeoutSec 15).StatusCode | Should -Be 405
        $csv = KCsvRows (KDownload $t.url)
        $csv.Count | Should -Be (KCount '/api/requests' "$script:KsPeriod&f.Protocol=owa").Total
        @($csv | Where-Object { $_.Protocol -ne 'Owa' }).Count | Should -Be 0
        (KDownload $t.url).StatusCode | Should -Be 404
        foreach ($bad in @(
            @{ View = 'sessions'; Query = 'f.User=user1'; Code = 'InvalidPeriod' },
            @{ View = 'sessions'; Query = ($script:KsPeriod -split '&')[0]; Code = 'InvalidPeriod' },
            @{ View = 'issues'; Query = "$script:KsPeriod&f.Status=abc"; Code = 'InvalidFilter' },
            @{ View = 'sessions'; Query = "$script:KsPeriod&cursor=1.1"; Code = 'InvalidParameter' },
            @{ View = 'sessions'; Query = "$script:KsPeriod&orderFrom=$(KIso $script:D0)"; Code = 'InvalidParameter' },
            @{ View = 'smtp'; Query = $script:KsPeriod; Code = 'InvalidView' })) {
            $r = KTicket $bad.View $bad.Query
            $r.StatusCode | Should -Be 400 -Because $bad.Query
            ($r.Content | ConvertFrom-Json).error.code | Should -BeExactly $bad.Code
        }
        (KTicket 'sessions' $script:KsPeriod -Token ('0' * 64)).StatusCode | Should -Be 401
        $get = Request $script:KsHost '/api/export/ticket'
        $get.StatusCode | Should -Be 400
        (Invoke-WebRequest -Uri "$($script:KsHost.Url)/api/export/ticket" -Method Post -Headers @{ 'X-Portal-Token' = $script:KsHost.Token } -ContentType 'application/json' -Body '{"view":"sessions","query":"","extra":1}' -SkipHttpErrorCheck).StatusCode | Should -Be 400
        (KDownload "/api/export/$('a' * 64).csv").StatusCode | Should -Be 404
    }

    It 'keeps at most 16 export tickets waiting, says so for the next one, and never prints a ticket on the console' {
        $none = "$script:KsPeriod&f.Protocol=zzzz"
        $waiting = @(foreach ($i in 1..16) { $r = KTicket 'issues' $none; $r.StatusCode | Should -Be 200; ($r.Content | ConvertFrom-Json).url })
        $next = KTicket 'issues' $none
        $next.StatusCode | Should -Be 429
        ($next.Content | ConvertFrom-Json).error.message | Should -BeExactly '16 exports are waiting to be downloaded: export the view again in a minute.'
        # A download frees its place at once.
        foreach ($url in $waiting) { (KDownload $url).StatusCode | Should -Be 200 }
        $last = KTicket 'issues' $none
        $last.StatusCode | Should -Be 200
        $url = ($last.Content | ConvertFrom-Json).url
        # The console lines of Serve that name a path (a 504, a client that left) print it without the name of a ticket.
        $logged = [ExchangeLogReport.ServeHost].GetMethod('Logged', [Reflection.BindingFlags]'Static,NonPublic')
        $logged.Invoke($null, [object[]]@($url)) | Should -BeExactly '/api/export/<ticket>.csv'
        $logged.Invoke($null, [object[]]@("$url/x")) | Should -BeExactly '/api/export/<ticket>.csv/x'
        $logged.Invoke($null, [object[]]@('/api/overview/servers')) | Should -BeExactly '/api/overview/servers'
        (KDownload $url).StatusCode | Should -Be 200
    }

    It 'expires an export ticket 60 seconds after it was issued' {
        $clock = $script:TicketType.GetField('Clock', [Reflection.BindingFlags]'Static,NonPublic,Public')
        $real = $clock.GetValue($null)
        try {
            [ServeTicketClock]::Offset = 0
            $clock.SetValue($null, [ServeTicketClock].GetMethod('Now').CreateDelegate([Func[long]]))
            $a = (KTicket 'sessions' $script:KsPeriod).Content | ConvertFrom-Json
            $b = (KTicket 'sessions' $script:KsPeriod).Content | ConvertFrom-Json
            [ServeTicketClock]::Offset = 59000
            (KDownload $a.url).StatusCode | Should -Be 200
            [ServeTicketClock]::Offset = 60000
            $late = KDownload $b.url
            $late.StatusCode | Should -Be 404
            ($late.Content | ConvertFrom-Json).error.message | Should -BeExactly 'This export ticket is unknown, used or expired: export the view again from the page.'
        } finally { $clock.SetValue($null, $real); [ServeTicketClock]::Offset = 0 }
    }

    It 'does not accept an export ticket as the token of the API' {
        $t = (KTicket 'sessions' $script:KsPeriod).Content | ConvertFrom-Json
        foreach ($path in '/api/meta', "/api/sessions?$script:KsPeriod", "/api/report-meta?$script:KsPeriod") {
            (Invoke-WebRequest -Uri ($script:KsHost.Url + $path) -Headers @{ 'X-Portal-Token' = $t.ticket } -SkipHttpErrorCheck).StatusCode | Should -Be 401 -Because $path
        }
        (KTicket 'sessions' $script:KsPeriod -Token $t.ticket).StatusCode | Should -Be 401
        (Invoke-WebRequest -Uri "$($script:KsHost.Url)/api/shutdown" -Method Post -Headers @{ 'X-Portal-Token' = $t.ticket } -SkipHttpErrorCheck).StatusCode | Should -Be 401
        (Invoke-WebRequest -Uri "$($script:KsHost.Url)/api/export/$($t.ticket).csv/x" -SkipHttpErrorCheck).StatusCode | Should -Be 401
        # The refusals spent nothing: the ticket still exports its selection, once.
        (KDownload $t.url).StatusCode | Should -Be 200
        $script:KsHost.Task.IsCompleted | Should -BeFalse
    }

    It 'refuses the download of an export ticket from an address that is not the loopback' {
        $t = (KTicket 'sessions' $script:KsPeriod).Content | ConvertFrom-Json
        $port = [int]$script:KsHost.Port; $origin = "http://127.0.0.1:$port"
        # The check of every request, the download of a ticket included: another address is refused for the exact authority of the portal.
        $check = [ExchangeLogReport.ServeHost].GetMethod('LocalRequest', [Reflection.BindingFlags]'Static,NonPublic', $null, [type[]]@([Net.IPEndPoint], [string], [string], [string], [int], [string]), $null)
        $refused = $null
        try { [void]$check.Invoke($null, @([Net.IPEndPoint]::new([Net.IPAddress]::Parse('192.0.2.10'), 50000), "127.0.0.1:$port", $null, 'none', 0, $origin)) } catch { $refused = $_.Exception.InnerException }
        $refused | Should -Not -BeNullOrEmpty
        $refused.GetType().Name | Should -BeExactly 'ServeError'
        $refused.GetType().GetField('Status', [Reflection.BindingFlags]'Instance,NonPublic').GetValue($refused) | Should -Be 403
        $refused.GetType().GetField('Code', [Reflection.BindingFlags]'Instance,NonPublic').GetValue($refused) | Should -BeExactly 'LocalOnly'
        [void]$check.Invoke($null, @([Net.IPEndPoint]::new([Net.IPAddress]::Loopback, 50000), "127.0.0.1:$port", $null, 'same-origin', 0, $origin))
        # Over the network: from an address of this computer that is not the loopback, the listener of 127.0.0.1 is not reached, or refuses.
        foreach ($address in @([Net.Dns]::GetHostAddresses([Net.Dns]::GetHostName()) | Where-Object { $_.AddressFamily -eq 'InterNetwork' -and -not [Net.IPAddress]::IsLoopback($_) })) {
            $tcp = [Net.Sockets.TcpClient]::new()
            try {
                $connected = $true
                try { $tcp.Connect($address, $port) } catch [Net.Sockets.SocketException] { $connected = $false }
                if ($connected) {
                    $stream = $tcp.GetStream()
                    $bytes = [Text.Encoding]::ASCII.GetBytes("GET $($t.url) HTTP/1.1`r`nHost: 127.0.0.1:$port`r`nConnection: close`r`n`r`n")
                    $stream.Write($bytes, 0, $bytes.Length)
                    $reader = [IO.StreamReader]::new($stream)
                    $reader.ReadLine() | Should -Match '^HTTP/1\.1 (403|400) ' -Because "a request from $address"
                }
            } finally { $tcp.Dispose() }
        }
        # A refused presentation from another address does not spend the ticket of the person on this computer.
        (KDownload $t.url).StatusCode | Should -Be 200
    }

    It 'leaves the source database bytes unchanged' {
        KSha $script:Ks.FilePath | Should -BeExactly $script:KsHash
    }
}
